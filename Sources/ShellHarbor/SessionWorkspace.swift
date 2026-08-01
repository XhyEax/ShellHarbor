import Combine
import Foundation

enum TerminalMultiplexer: String, Codable, CaseIterable {
    case tmux
    case zellij

    func startupCommand(sessionName: String) -> String {
        let quoted = SSHCommandBuilder.shellQuote(sessionName)
        switch self {
        case .tmux:
            return "tmux new-session -A -s \(quoted)"
        case .zellij:
            return "zellij attach --create \(quoted)"
        }
    }
}

enum WorkspaceMode: String, Codable, CaseIterable, Identifiable {
    case terminal
    case files
    case workspace
    case inspection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspace: "工作台"
        case .terminal: "终端"
        case .files: "文件"
        case .inspection: "巡检日志"
        }
    }

    var icon: String {
        switch self {
        case .workspace: "rectangle.split.2x1"
        case .terminal: "terminal"
        case .files: "arrow.left.arrow.right"
        case .inspection: "waveform.path.ecg"
        }
    }
}

@MainActor
final class SessionWorkspace: ObservableObject, Identifiable {
    let id: UUID
    let remoteID: UUID
    @Published private(set) var profile: SessionProfile
    @Published private(set) var jumpProfile: SessionProfile?
    let sessionNumber: Int
    let multiplexer: TerminalMultiplexer?
    let terminal = TerminalController()

    var displayName: String {
        "\(profile.name) · \(sessionLabel)"
    }

    var sessionLabel: String {
        customName ?? String(sessionNumber)
    }

    @Published private(set) var customName: String?
    @Published var mode: WorkspaceMode = .terminal
    @Published var localPath: URL
    @Published var remotePath: String
    @Published var localEntries: [FileEntry] = []
    @Published var remoteEntries: [FileEntry] = []
    @Published var localSortColumn: FileSortColumn
    @Published var localSortAscending: Bool
    @Published var remoteSortColumn: FileSortColumn
    @Published var remoteSortAscending: Bool
    @Published var selectedLocalIDs = Set<FileEntry.ID>()
    @Published var selectedRemoteIDs = Set<FileEntry.ID>()
    @Published var transfers: [TransferItem] = []
    @Published var isLoadingLocal = false
    @Published var isLoadingRemote = false
    @Published var commandHistory: [CommandHistoryEntry] = []
    @Published var commandHistorySearch = ""
    @Published var showingCommandHistory = false
    @Published var isLoadingCommandHistory = false
    @Published var showTransfers = false

    private var terminalCancellable: AnyCancellable?
    private var hasLoadedLocalDirectory = false
    private var localLoadGeneration = UUID()

    init(
        profile: SessionProfile,
        jumpProfile: SessionProfile? = nil,
        sessionNumber: Int = 1,
        multiplexer: TerminalMultiplexer? = nil,
        id: UUID = UUID()
    ) {
        self.id = id
        remoteID = profile.id
        self.profile = profile
        self.jumpProfile = jumpProfile
        self.sessionNumber = sessionNumber
        self.multiplexer = multiplexer
        let defaultLocalPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
        if let savedLocalPath = profile.lastLocalPath {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: savedLocalPath,
                isDirectory: &isDirectory
            )
            localPath = exists && isDirectory.boolValue
                ? URL(fileURLWithPath: savedLocalPath, isDirectory: true)
                    .standardizedFileURL
                : defaultLocalPath
        } else {
            localPath = defaultLocalPath
        }
        let savedRemotePath = profile.lastRemotePath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let savedRemotePath, !savedRemotePath.isEmpty {
            remotePath = savedRemotePath
        } else {
            remotePath = profile.resolvedRemoteFilePath
        }
        mode = profile.lastWorkspaceMode
            .flatMap(WorkspaceMode.init(rawValue:)) ?? .terminal
        localSortColumn = profile.lastLocalSortColumn
            .flatMap(FileSortColumn.init(rawValue:)) ?? .name
        localSortAscending = profile.lastLocalSortAscending ?? true
        remoteSortColumn = profile.lastRemoteSortColumn
            .flatMap(FileSortColumn.init(rawValue:)) ?? .name
        remoteSortAscending = profile.lastRemoteSortAscending ?? true
        terminalCancellable = terminal.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func updateProfile(_ profile: SessionProfile) {
        guard profile.id == remoteID else { return }
        self.profile = profile
    }

    func updateJumpProfile(_ profile: SessionProfile?) {
        jumpProfile = profile
    }

    func applyRestoration(_ snapshot: RestorableSessionSnapshot) {
        customName = snapshot.customName
        mode = profile.isLocalConnection ? .terminal : snapshot.mode
        remotePath = snapshot.remotePath

        var isDirectory: ObjCBool = false
        if
            FileManager.default.fileExists(
                atPath: snapshot.localPath,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        {
            localPath = URL(
                fileURLWithPath: snapshot.localPath,
                isDirectory: true
            ).standardizedFileURL
        }
        terminal.prepareRestoration(
            buffer: snapshot.terminalBuffer,
            pendingCommand: snapshot.pendingCommand,
            directory: snapshot.terminalDirectory
        )
    }

    func prepareIfNeeded() {
        guard !hasLoadedLocalDirectory else { return }
        reloadLocal()
    }

    func rename(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        customName = trimmed.isEmpty ? nil : trimmed
    }

    func reloadLocal(
        selectingPath: String? = nil,
        preservingSelection: Bool = false
    ) {
        hasLoadedLocalDirectory = true
        let path = localPath
        let selectedPaths: Set<String>? =
            if let selectingPath {
                [selectingPath]
            } else if preservingSelection {
                Set(
                    localEntries.lazy
                        .filter { self.selectedLocalIDs.contains($0.id) }
                        .map(\.path)
                )
            } else {
                nil
            }
        let generation = UUID()
        localLoadGeneration = generation
        isLoadingLocal = true

        Task {
            let entries = await Task.detached(priority: .userInitiated) {
                Self.readLocalDirectory(at: path)
            }.value
            guard generation == localLoadGeneration, path == localPath else {
                return
            }
            localEntries = entries
            if let selectedPaths {
                selectedLocalIDs = Set(
                    entries.lazy
                        .filter { selectedPaths.contains($0.path) }
                        .map(\.id)
                )
            } else {
                selectedLocalIDs.removeAll()
            }
            isLoadingLocal = false
        }
    }

    nonisolated private static func readLocalDirectory(at path: URL) -> [FileEntry] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .isHiddenKey
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: path,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            return []
        }
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: keys)
            return FileEntry(
                name: url.lastPathComponent,
                path: url.path,
                isDirectory: values?.isDirectory ?? false,
                size: Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate,
                createdAt: values?.creationDate
            )
        }
    }
}
