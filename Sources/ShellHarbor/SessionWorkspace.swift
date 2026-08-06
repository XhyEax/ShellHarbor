import Combine
import Foundation

enum TerminalMultiplexer: String, Codable, CaseIterable {
    case tmux
    case zellij

    func startupCommand(sessionName: String) -> String {
        let quoted = SSHCommandBuilder.shellQuote(sessionName)
        switch self {
        case .tmux:
            // tmux owns the complete history of its alternate screen. Enable
            // mouse only for this ShellHarbor session so wheel gestures enter
            // tmux copy-mode without changing the user's global tmux.conf.
            return "tmux has-session -t \(quoted) 2>/dev/null || tmux new-session -d -s \(quoted); tmux set-option -t \(quoted) mouse on && exec tmux attach-session -t \(quoted)"
        case .zellij:
            return "zellij attach --create \(quoted)"
        }
    }
}

struct RemoteMultiplexerSession: Identifiable, Equatable, Sendable {
    let multiplexer: TerminalMultiplexer
    let name: String

    var id: String { "\(multiplexer.rawValue):\(name)" }
}

enum RemoteMultiplexerSessionService {
    static let listingCommand = """
    tmux_bin=$(command -v tmux 2>/dev/null || true)
    for candidate in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do [ -n "$tmux_bin" ] || [ ! -x "$candidate" ] || tmux_bin=$candidate; done
    if [ -n "$tmux_bin" ]; then "$tmux_bin" list-sessions -F '__SHELLHARBOR_TMUX__#{session_name}' 2>/dev/null || true; fi
    zellij_bin=$(command -v zellij 2>/dev/null || true)
    for candidate in /opt/homebrew/bin/zellij /usr/local/bin/zellij "$HOME/.cargo/bin/zellij"; do [ -n "$zellij_bin" ] || [ ! -x "$candidate" ] || zellij_bin=$candidate; done
    if [ -n "$zellij_bin" ]; then
      { "$zellij_bin" list-sessions --short --no-formatting 2>/dev/null || "$zellij_bin" list-sessions --short 2>/dev/null || true; } | sed 's/^/__SHELLHARBOR_ZELLIJ__/'
    fi
    """

    static func parse(_ output: String) -> [RemoteMultiplexerSession] {
        var seen = Set<String>()
        return output.split(whereSeparator: \Character.isNewline).compactMap {
            line in
            let value = String(line)
            let item: RemoteMultiplexerSession?
            if value.hasPrefix("__SHELLHARBOR_TMUX__") {
                item = RemoteMultiplexerSession(
                    multiplexer: .tmux,
                    name: String(value.dropFirst("__SHELLHARBOR_TMUX__".count))
                        .replacingOccurrences(of: "\\t", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            } else if value.hasPrefix("__SHELLHARBOR_ZELLIJ__") {
                item = RemoteMultiplexerSession(
                    multiplexer: .zellij,
                    name: String(value.dropFirst("__SHELLHARBOR_ZELLIJ__".count))
                        .replacingOccurrences(of: "\\t", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            } else {
                item = nil
            }
            guard let item, !item.name.isEmpty, seen.insert(item.id).inserted else {
                return nil
            }
            return item
        }
    }
}

enum WorkspaceMode: String, Codable, CaseIterable, Identifiable {
    case terminal
    case files
    case workspace
    case inspection
    case forwarding

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspace: "工作台"
        case .terminal: "终端"
        case .files: "文件"
        case .inspection: "巡检日志"
        case .forwarding: "端口转发"
        }
    }

    var icon: String {
        switch self {
        case .workspace: "rectangle.split.2x1"
        case .terminal: "terminal"
        case .files: "arrow.left.arrow.right"
        case .inspection: "waveform.path.ecg"
        case .forwarding: "point.3.connected.trianglepath.dotted"
        }
    }
}

@MainActor
final class SessionWorkspace: ObservableObject, Identifiable {
    let id: UUID
    let remoteID: UUID
    @Published private(set) var profile: SessionProfile
    @Published private(set) var jumpProfile: SessionProfile?
    private(set) var connectionProfile: SessionProfile
    private(set) var connectionJumpProfile: SessionProfile?
    let sessionNumber: Int
    let multiplexer: TerminalMultiplexer?
    private var hasIssuedMultiplexerStartup = false
    let terminal = TerminalController()
    let portForwards = PortForwardController()
    @Published var portForwardRules: [PortForwardRule] = []

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
    private(set) var hasLoadedRemoteDirectory = false
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
        connectionProfile = profile
        connectionJumpProfile = jumpProfile
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
        if profile.isLocalConnection {
            self.profile = profile
            connectionProfile = profile
            return
        }
        self.profile.name = profile.name
        self.profile.accentHex = profile.accentHex
        self.profile.remoteIcon = profile.remoteIcon
        self.profile.remoteGroup = profile.remoteGroup
    }

    func updateJumpProfile(_ profile: SessionProfile?) {
        guard
            let profile,
            profile.id == jumpProfile?.id
        else { return }
        jumpProfile?.name = profile.name
        jumpProfile?.accentHex = profile.accentHex
        jumpProfile?.remoteIcon = profile.remoteIcon
        jumpProfile?.remoteGroup = profile.remoteGroup
    }

    func updateConnectionRouting(
        profile: SessionProfile,
        jumpProfile: SessionProfile?
    ) {
        connectionProfile = profile
        connectionJumpProfile = jumpProfile
    }

    /// Quick launch is a one-shot connection bootstrap. Reconnecting the same
    /// workspace must not inject the tmux/zellij command into the new shell.
    func consumeMultiplexerStartupCommand() -> String? {
        guard
            !hasIssuedMultiplexerStartup,
            let multiplexer
        else { return nil }
        hasIssuedMultiplexerStartup = true
        return multiplexer.startupCommand(sessionName: sessionLabel)
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

    func markRemoteDirectoryLoaded() {
        hasLoadedRemoteDirectory = true
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
