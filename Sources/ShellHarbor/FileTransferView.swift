import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let shellHarborFileEntries = UTType(
        exportedAs: "com.shellharbor.file-entries"
    )
}

struct FileDragPayload: Codable, Sendable, Transferable {
    enum Location: String, Codable, Sendable {
        case local
        case remote
    }

    struct Item: Codable, Sendable {
        let name: String
        let path: String
        let isDirectory: Bool
        let size: Int64

        var fileEntry: FileEntry {
            FileEntry(
                name: name,
                path: path,
                isDirectory: isDirectory,
                size: size,
                modifiedAt: nil
            )
        }
    }

    let location: Location
    let items: [Item]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .shellHarborFileEntries)
    }
}

enum FileDragItemProvider {
    static func make(_ payload: FileDragPayload) -> NSItemProvider {
        guard let data = try? JSONEncoder().encode(payload) else {
            return NSItemProvider()
        }
        let provider: NSItemProvider
        if
            payload.location == .local,
            let firstItem = payload.items.first
        {
            let localURL = URL(fileURLWithPath: firstItem.path)
                .standardizedFileURL
            provider = NSItemProvider(object: localURL as NSURL)
            provider.suggestedName = firstItem.name
        } else {
            provider = NSItemProvider()
        }
        provider.registerDataRepresentation(
            forTypeIdentifier:
                UTType.shellHarborFileEntries.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    @discardableResult
    static func receive(
        _ providers: [NSItemProvider],
        onPayload: @escaping @MainActor (FileDragPayload) -> Void
    ) -> Bool {
        let matching = providers.filter {
            $0.hasItemConformingToTypeIdentifier(
                UTType.shellHarborFileEntries.identifier
            )
        }
        guard !matching.isEmpty else { return false }

        for provider in matching {
            provider.loadDataRepresentation(
                forTypeIdentifier:
                    UTType.shellHarborFileEntries.identifier
            ) { data, _ in
                guard
                    let data,
                    let payload = try? JSONDecoder().decode(
                        FileDragPayload.self,
                        from: data
                    )
                else {
                    return
                }
                Task { @MainActor in
                    onPayload(payload)
                }
            }
        }
        return true
    }
}

enum TransferRecentDirectoryResolver {
    static let maximumCount = 10

    static func localDirectories(
        from transfers: [TransferItem]
    ) -> [String] {
        uniqueDirectories(
            transfers.map { item in
                let path = item.direction == .upload
                    ? item.source
                    : item.destination
                return URL(fileURLWithPath: path)
                    .deletingLastPathComponent()
                    .standardizedFileURL.path
            }
        )
    }

    static func remoteDirectories(
        from transfers: [TransferItem]
    ) -> [String] {
        uniqueDirectories(
            transfers.map { item in
                RemoteFileService.parent(
                    of: item.direction == .upload
                        ? item.destination
                        : item.source
                )
            }
        )
    }

    private static func uniqueDirectories(
        _ directories: [String]
    ) -> [String] {
        var seen = Set<String>()
        return directories.compactMap { path in
            guard seen.insert(path).inserted else { return nil }
            return path
        }
        .prefix(maximumCount)
        .map { $0 }
    }
}

enum FileEntrySorter {
    static func sorted(
        _ entries: [FileEntry],
        by column: FileSortColumn,
        ascending: Bool
    ) -> [FileEntry] {
        entries.sorted { lhs, rhs in
            if column == .modified || column == .created {
                let leftDate = column == .modified
                    ? lhs.modifiedAt
                    : lhs.createdAt
                let rightDate = column == .modified
                    ? rhs.modifiedAt
                    : rhs.createdAt
                if (leftDate == nil) != (rightDate == nil) {
                    return leftDate != nil && rightDate == nil
                }
            }

            let comparison: ComparisonResult = switch column {
            case .name:
                lhs.name.localizedStandardCompare(rhs.name)
            case .size:
                if lhs.size == rhs.size {
                    .orderedSame
                } else {
                    lhs.size < rhs.size ? .orderedAscending : .orderedDescending
                }
            case .modified:
                if lhs.modifiedAt == rhs.modifiedAt {
                    .orderedSame
                } else if let left = lhs.modifiedAt, let right = rhs.modifiedAt {
                    left < right ? .orderedAscending : .orderedDescending
                } else {
                    .orderedSame
                }
            case .created:
                if lhs.createdAt == rhs.createdAt {
                    .orderedSame
                } else if let left = lhs.createdAt, let right = rhs.createdAt {
                    left < right ? .orderedAscending : .orderedDescending
                } else {
                    .orderedSame
                }
            }

            if comparison == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return ascending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
    }
}

struct FileTransferView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var workspace: SessionWorkspace
    let isAutoRefreshActive: Bool

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let dividerWidth: CGFloat = 1
                let paneWidth = max(
                    0,
                    (geometry.size.width - dividerWidth) / 2
                )

                HStack(spacing: 0) {
                    LocalFilePane(workspace: workspace)
                        .frame(
                            width: paneWidth,
                            height: geometry.size.height
                        )
                        .clipped()

                    Divider()
                        .frame(width: dividerWidth)

                    RemoteFilePane(workspace: workspace)
                        .frame(
                            width: paneWidth,
                            height: geometry.size.height
                        )
                        .clipped()
                }
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .leading
                )
                .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            Divider()

            VStack(spacing: 0) {
                HStack {
                    Button {
                        withAnimation { workspace.showTransfers.toggle() }
                    } label: {
                        Image(systemName: workspace.showTransfers ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    Text("传输队列")
                        .font(.subheadline.weight(.semibold))
                    if !workspace.showTransfers {
                        collapsedTransferSummary
                    }
                    Spacer()
                    Button("清除已完成") {
                        workspace.transfers.removeAll { $0.status == .finished }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Color(nsColor: .controlBackgroundColor))

                if workspace.showTransfers {
                    Divider()
                    TransferQueueView(workspace: workspace)
                        .frame(height: 160)
                }
            }
        }
        .task(id: isAutoRefreshActive) {
            guard isAutoRefreshActive else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await state.automaticallyRefreshFiles(in: workspace)
            }
        }
    }

    @ViewBuilder
    private var collapsedTransferSummary: some View {
        let running = workspace.transfers.filter { $0.status == .running }
        let pausedCount = workspace.transfers.filter {
            $0.status == .paused
        }.count
        let finishedCount = workspace.transfers.filter {
            $0.status == .finished
        }.count

        if !running.isEmpty {
            Text("\(running.count) 进行中")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.blue, in: Capsule())

            if let summary = aggregateProgress(for: running) {
                Text("已传 \(summary.sizeLabel)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                ProgressView(value: summary.fraction)
                    .frame(width: 76)

                Text("\(Int((summary.fraction * 100).rounded()))%")
                    .font(.caption2.monospacedDigit().weight(.medium))

                if summary.bytesPerSecond > 0 {
                    let speedLabel = ByteCountFormatter.string(
                        fromByteCount: Int64(
                            summary.bytesPerSecond.rounded()
                        ),
                        countStyle: .file
                    )
                    Text("\(speedLabel)/秒")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("正在传输")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if pausedCount > 0 {
            Text("\(pausedCount) 已暂停")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.orange, in: Capsule())
        } else if finishedCount > 0 {
            Text("\(finishedCount) 已完成")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.green, in: Capsule())
            if
                let latestFinished = workspace.transfers.first(where: {
                    $0.status == .finished
                }),
                let size = latestFinished.transferredSizeLabel,
                let duration = latestFinished.durationLabel
            {
                Text("\(size) · \(duration)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else if !workspace.transfers.isEmpty {
            Text("\(workspace.transfers.count) 等待中")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
    }

    private func aggregateProgress(
        for transfers: [TransferItem]
    ) -> (
        fraction: Double,
        sizeLabel: String,
        bytesPerSecond: Double
    )? {
        let measurable = transfers.filter {
            ($0.totalBytes ?? 0) > 0
        }
        guard !measurable.isEmpty else { return nil }

        let totalBytes = measurable.reduce(Int64(0)) {
            $0 + ($1.totalBytes ?? 0)
        }
        guard totalBytes > 0 else { return nil }

        let transferredBytes = measurable.reduce(Int64(0)) {
            $0 + min($1.transferredBytes, $1.totalBytes ?? 0)
        }
        let bytesPerSecond = measurable.reduce(0.0) {
            $0 + $1.bytesPerSecond
        }
        let transferredLabel = ByteCountFormatter.string(
            fromByteCount: transferredBytes,
            countStyle: .file
        )
        let totalLabel = ByteCountFormatter.string(
            fromByteCount: totalBytes,
            countStyle: .file
        )

        return (
            min(
                max(Double(transferredBytes) / Double(totalBytes), 0),
                1
            ),
            "\(transferredLabel) / \(totalLabel)",
            bytesPerSecond
        )
    }
}

enum FinderFileDropDecoder {
    static func fileURL(from data: Data) -> URL? {
        if
            let url = URL(
                dataRepresentation: data,
                relativeTo: nil
            ),
            url.isFileURL
        {
            return url.standardizedFileURL
        }
        guard
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let url = URL(string: value),
            url.isFileURL
        else {
            return nil
        }
        return url.standardizedFileURL
    }
}

struct FilePathSuggestion: Identifiable, Equatable {
    let path: String
    let isDirectory: Bool

    var id: String { path }
}

enum FilePathCompletion {
    static let maximumSuggestions = 8

    static func local(
        input: String,
        currentDirectory: URL
    ) -> [FilePathSuggestion] {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw != currentDirectory.path else { return [] }

        let expanded = (raw as NSString).expandingTildeInPath
        let candidate = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : currentDirectory.appendingPathComponent(expanded)
        let directory: URL
        let prefix: String
        if raw.hasSuffix("/") {
            directory = candidate.standardizedFileURL
            prefix = ""
        } else {
            directory = candidate.deletingLastPathComponent()
                .standardizedFileURL
            prefix = candidate.lastPathComponent
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            return []
        }
        return children.compactMap { url -> FilePathSuggestion? in
            guard
                prefix.isEmpty ||
                matchesPrefix(url.lastPathComponent, prefix: prefix)
            else {
                return nil
            }
            let isDirectory = (
                try? url.resourceValues(forKeys: keys).isDirectory
            ) ?? false
            return FilePathSuggestion(
                path: url.standardizedFileURL.path,
                isDirectory: isDirectory
            )
        }
        .sorted(by: suggestionOrder)
        .prefix(maximumSuggestions)
        .map { $0 }
    }

    static func remote(
        input: String,
        currentDirectory: String,
        entries: [FileEntry]
    ) -> [FilePathSuggestion] {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw != currentDirectory else { return [] }

        let directory: String
        let prefix: String
        if raw.hasSuffix("/") {
            directory = String(raw.dropLast())
            prefix = ""
        } else if raw.contains("/") {
            directory = RemoteFileService.parent(of: raw)
            prefix = (raw as NSString).lastPathComponent
        } else {
            directory = currentDirectory
            prefix = raw
        }

        guard normalizedRemotePath(directory) ==
                normalizedRemotePath(currentDirectory)
        else {
            return []
        }
        return entries.compactMap { entry in
            guard
                prefix.isEmpty ||
                matchesPrefix(entry.name, prefix: prefix)
            else {
                return nil
            }
            return FilePathSuggestion(
                path: entry.path,
                isDirectory: entry.isDirectory
            )
        }
        .sorted(by: suggestionOrder)
        .prefix(maximumSuggestions)
        .map { $0 }
    }

    private static func normalizedRemotePath(_ path: String) -> String {
        if path == "/" { return path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func matchesPrefix(
        _ value: String,
        prefix: String
    ) -> Bool {
        value.range(
            of: prefix,
            options: [.caseInsensitive, .anchored],
            locale: .current
        ) != nil
    }

    private static func suggestionOrder(
        _ lhs: FilePathSuggestion,
        _ rhs: FilePathSuggestion
    ) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }
        return lhs.path.localizedStandardCompare(rhs.path) ==
            .orderedAscending
    }
}

private struct LocalFilePane: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var workspace: SessionWorkspace

    var body: some View {
        FilePane(
            title: "本地",
            icon: "desktopcomputer",
            path: workspace.localPath.path,
            entries: workspace.localEntries,
            selection: $workspace.selectedLocalIDs,
            sortColumn: $workspace.localSortColumn,
            sortAscending: $workspace.localSortAscending,
            isLoading: workspace.isLoadingLocal,
            primaryActionTitle: "上传",
            primaryActionIcon: "arrow.up.circle.fill",
            primaryDisabled: workspace.selectedLocalIDs.isEmpty,
            onParent: state.localParent,
            onRefresh: state.refreshLocal,
            onPathSubmit: {
                state.navigateLocal(to: $0, in: workspace)
            },
            onChoosePath: state.chooseLocalDirectory,
            onPrimaryAction: state.uploadSelected,
            onOpen: state.openLocal,
            onRename: {
                state.renameLocal($0, to: $1, in: workspace)
            },
            dragLocation: .local,
            contextTransferTitle: "上传",
            contextTransferIcon: "arrow.up.circle",
            onContextTransfer: {
                state.upload($0, in: workspace)
            },
            contextDeleteTitle: "删除",
            onContextDelete: {
                state.moveLocalItemsToTrash($0, in: workspace)
            },
            trailingAction: {
                state.moveLocalItemsToTrash(
                    workspace.localEntries.filter {
                        workspace.selectedLocalIDs.contains($0.id)
                    },
                    in: workspace
                )
            },
            trailingActionHelp: "删除所选本地项目",
            pathSuggestions: {
                FilePathCompletion.local(
                    input: $0,
                    currentDirectory: workspace.localPath
                )
            },
            recentPaths: TransferRecentDirectoryResolver.localDirectories(
                from: workspace.transfers
            ),
            onRecentPathSelect: {
                state.navigateLocal(to: $0, in: workspace)
            },
            onFileDrop: { payloads, _ in
                let entries = payloads
                    .filter { $0.location == .remote }
                    .flatMap(\.items)
                    .map(\.fileEntry)
                guard !entries.isEmpty else { return false }
                state.download(entries, in: workspace)
                return true
            }
        )
    }
}

private struct RemoteFilePane: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var workspace: SessionWorkspace
    @State private var showingNewFolder = false
    @State private var showingDeleteConfirmation = false
    @State private var folderName = ""
    @State private var isUploadDropTarget = false

    var body: some View {
        FilePane(
            title: "远程",
            icon: "server.rack",
            path: workspace.remotePath,
            entries: workspace.remoteEntries,
            selection: $workspace.selectedRemoteIDs,
            sortColumn: $workspace.remoteSortColumn,
            sortAscending: $workspace.remoteSortAscending,
            isLoading: workspace.isLoadingRemote,
            primaryActionTitle: "下载",
            primaryActionIcon: "arrow.down.circle.fill",
            primaryDisabled: workspace.selectedRemoteIDs.isEmpty,
            onParent: state.remoteParent,
            onRefresh: { Task { await state.refreshRemote(in: workspace) } },
            onPathSubmit: {
                state.navigateRemote(to: $0, in: workspace)
            },
            onChoosePath: { showingNewFolder = true },
            onPrimaryAction: state.downloadSelected,
            onOpen: state.openRemote,
            onRename: {
                state.renameRemote($0, to: $1, in: workspace)
            },
            dragLocation: .remote,
            contextTransferTitle: "下载",
            contextTransferIcon: "arrow.down.circle",
            onContextTransfer: {
                state.download($0, in: workspace)
            },
            choosePathIcon: "folder.badge.plus",
            choosePathHelp: "新建远程文件夹",
            trailingAction: { showingDeleteConfirmation = true },
            trailingActionHelp: "永久删除所选远程项目",
            pathSuggestions: {
                FilePathCompletion.remote(
                    input: $0,
                    currentDirectory: workspace.remotePath,
                    entries: workspace.remoteEntries
                )
            },
            recentPaths: TransferRecentDirectoryResolver.remoteDirectories(
                from: workspace.transfers
            ),
            onRecentPathSelect: {
                state.navigateRemote(to: $0, in: workspace)
            },
            onFileDrop: { payloads, destinationEntry in
                receiveLocalFiles(
                    payloads,
                    destinationEntry: destinationEntry
                )
            },
            onFinderFileDrop: { providers, destinationEntry in
                receiveFinderFiles(
                    providers,
                    destinationEntry: destinationEntry
                )
            }
        )
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.shellHarborFileEntries, UTType.fileURL],
            isTargeted: $isUploadDropTarget,
            perform: { receiveUploadProviders($0) }
        )
        .overlay {
            if isUploadDropTarget {
                ZStack {
                    Color.accentColor.opacity(0.08)
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(
                                lineWidth: 3,
                                dash: [8, 5]
                            )
                        )
                        .padding(5)
                    Label(
                        "上传到 \(workspace.remotePath)",
                        systemImage: "arrow.up.doc.fill"
                    )
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: Capsule())
                }
                .allowsHitTesting(false)
            }
        }
        .alert("新建远程文件夹", isPresented: $showingNewFolder) {
            TextField("文件夹名称", text: $folderName)
            Button("取消", role: .cancel) { folderName = "" }
            Button("创建") {
                let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    state.createRemoteDirectory(name: name)
                }
                folderName = ""
            }
        } message: {
            Text("将在 \(workspace.remotePath) 中创建。")
        }
        .confirmationDialog(
            "确定删除所选远程项目？",
            isPresented: $showingDeleteConfirmation
        ) {
            Button("永久删除", role: .destructive) {
                state.deleteSelectedRemote()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("远程删除无法撤销。文件夹及其中内容会被递归删除。")
        }
    }

    private func receiveLocalFiles(
        _ payloads: [FileDragPayload],
        destinationEntry: FileEntry? = nil
    ) -> Bool {
        let entries = payloads
            .filter { $0.location == .local }
            .flatMap(\.items)
            .map(\.fileEntry)
        guard !entries.isEmpty else { return false }
        state.upload(
            entries,
            to: destinationEntry?.path ?? workspace.remotePath,
            in: workspace
        )
        return true
    }

    private func receiveUploadProviders(
        _ providers: [NSItemProvider]
    ) -> Bool {
        let acceptedInternal = FileDragItemProvider.receive(
            providers
        ) { payload in
            _ = receiveLocalFiles([payload])
        }
        if acceptedInternal { return true }
        return receiveFinderFiles(providers)
    }

    private func receiveFinderFiles(
        _ providers: [NSItemProvider],
        destinationEntry: FileEntry? = nil
    ) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(
                UTType.fileURL.identifier
            )
        }
        guard !fileProviders.isEmpty else { return false }

        for provider in fileProviders {
            provider.loadDataRepresentation(
                forTypeIdentifier: UTType.fileURL.identifier
            ) { data, _ in
                guard
                    let data,
                    let fileURL = FinderFileDropDecoder.fileURL(from: data)
                else {
                    return
                }
                Task { @MainActor in
                    state.uploadDroppedFiles(
                        [fileURL],
                        to: destinationEntry?.path ??
                            workspace.remotePath,
                        in: workspace
                    )
                }
            }
        }
        return true
    }
}

private struct FilePane: View {
    let title: String
    let icon: String
    let path: String
    let entries: [FileEntry]
    @Binding var selection: Set<FileEntry.ID>
    @Binding var sortColumn: FileSortColumn
    @Binding var sortAscending: Bool
    let isLoading: Bool
    let primaryActionTitle: String
    let primaryActionIcon: String
    let primaryDisabled: Bool
    let onParent: () -> Void
    let onRefresh: () -> Void
    let onPathSubmit: (String) -> Void
    let onChoosePath: () -> Void
    let onPrimaryAction: () -> Void
    let onOpen: (FileEntry) -> Void
    let onRename: (FileEntry, String) -> Void
    let dragLocation: FileDragPayload.Location
    var contextTransferTitle: String? = nil
    var contextTransferIcon: String? = nil
    var onContextTransfer: (([FileEntry]) -> Void)? = nil
    var contextDeleteTitle: String? = nil
    var onContextDelete: (([FileEntry]) -> Void)? = nil
    var choosePathIcon = "folder"
    var choosePathHelp = "选择本地目录"
    var trailingAction: (() -> Void)?
    var trailingActionHelp = "删除所选项目"
    var pathSuggestions: (String) -> [FilePathSuggestion] = { _ in [] }
    var recentPaths: [String] = []
    var onRecentPathSelect: ((String) -> Void)?
    var onFileDrop: (([FileDragPayload], FileEntry?) -> Bool)?
    var onFinderFileDrop: (([NSItemProvider], FileEntry?) -> Bool)?
    @State private var pathDraft = ""
    @State private var selectionAnchorID: FileEntry.ID?
    @State private var lastClickedEntryID: FileEntry.ID?
    @State private var lastEntryClickTime: TimeInterval = 0
    @State private var renamingEntry: FileEntry?
    @State private var renameDraft = ""
    @State private var showingRename = false
    @State private var dropTargetEntryID: FileEntry.ID?
    @State private var isFinderListDropTarget = false
    @FocusState private var pathFieldFocused: Bool

    private var sortedEntries: [FileEntry] {
        FileEntrySorter.sorted(
            entries,
            by: sortColumn,
            ascending: sortAscending
        )
    }

    private var completions: [FilePathSuggestion] {
        guard pathFieldFocused else { return [] }
        return pathSuggestions(pathDraft)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                recentPathsMenu
                Button(action: onParent) {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .help("上级目录")

                TextField("路径", text: $pathDraft)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .textFieldStyle(.plain)
                    .focused($pathFieldFocused)
                    .onSubmit {
                        onPathSubmit(pathDraft)
                        pathFieldFocused = false
                    }
                    .onKeyPress(.tab) {
                        guard let completion = completions.first else {
                            return .ignored
                        }
                        pathDraft = completion.path +
                            (completion.isDirectory ? "/" : "")
                        return .handled
                    }
                    .onExitCommand {
                        pathDraft = path
                        pathFieldFocused = false
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新")
                Button(action: onChoosePath) {
                    Image(systemName: choosePathIcon)
                }
                .buttonStyle(.borderless)
                .help(choosePathHelp)
                if let trailingAction {
                    Button(role: .destructive, action: trailingAction) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selection.isEmpty)
                    .help(trailingActionHelp)
                }
                Button(action: onPrimaryAction) {
                    Label(primaryActionTitle, systemImage: primaryActionIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(primaryDisabled)
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(.bar)

            if !completions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("补全")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(completions) { completion in
                            Button {
                                pathDraft = completion.path
                                pathFieldFocused = false
                                onPathSubmit(completion.path)
                            } label: {
                                Label(
                                    (completion.path as NSString)
                                        .lastPathComponent,
                                    systemImage: completion.isDirectory
                                        ? "folder"
                                        : "doc"
                                )
                                .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help(completion.path)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(height: 30)
                .background(.bar)
            }

            Divider()

            HStack {
                sortHeader(
                    "名称",
                    column: .name,
                    trailing: false
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                sortHeader(
                    "大小",
                    column: .size,
                    trailing: true
                )
                .frame(width: 62, alignment: .trailing)
                sortHeader(
                    "修改时间",
                    column: .modified,
                    trailing: true
                )
                .frame(width: 110, alignment: .trailing)
                sortHeader(
                    "创建时间",
                    column: .created,
                    trailing: true
                )
                .frame(width: 110, alignment: .trailing)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 27)
            .background(Color(nsColor: .controlBackgroundColor))

            fileList
        }
        .onAppear {
            pathDraft = path
        }
        .onChange(of: path) { _, newPath in
            pathDraft = newPath
        }
        .onChange(of: entries.map(\.id)) { _, entryIDs in
            selection.formIntersection(Set(entryIDs))
            if
                let selectionAnchorID,
                !entryIDs.contains(selectionAnchorID)
            {
                self.selectionAnchorID = nil
            }
        }
        .onChange(of: showingRename) { _, isShowing in
            if isShowing {
                positionRenameCaret()
            }
        }
        .sheet(isPresented: $showingRename) {
            if let renamingEntry {
                FileRenameSheet(
                    entry: renamingEntry,
                    name: $renameDraft,
                    onCancel: {
                        showingRename = false
                    },
                    onRename: {
                        onRename(renamingEntry, renameDraft)
                        showingRename = false
                    }
                )
            }
        }
        .onChange(of: showingRename) { _, isShowing in
            guard !isShowing else { return }
            renamingEntry = nil
            renameDraft = ""
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .clipped()
    }

    private var fileList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sortedEntries) { entry in
                        fileRow(for: entry)
                        Divider()
                            .padding(.leading, 38)
                    }
                }
            }
            .overlay {
                fileListOverlay
            }
            .onDrop(
                of: supportedDropTypes,
                isTargeted: $isFinderListDropTarget
            ) { providers in
                receiveDropProviders(providers)
            }
            .onChange(of: selection) { _, selectedIDs in
                scrollToSingleSelection(
                    selectedIDs,
                    using: proxy
                )
            }
        }
    }

    private func scrollToSingleSelection(
        _ selectedIDs: Set<FileEntry.ID>,
        using proxy: ScrollViewProxy
    ) {
        guard
            selectedIDs.count == 1,
            let selectedID = selectedIDs.first,
            sortedEntries.contains(where: { $0.id == selectedID })
        else {
            return
        }
        proxy.scrollTo(selectedID, anchor: .center)
    }

    @ViewBuilder
    private var fileListOverlay: some View {
        if entries.isEmpty && !isLoading {
            ContentUnavailableView(
                "目录为空",
                systemImage: "folder",
                description: Text("此目录中没有可显示的项目。")
            )
        }
        if
            isFinderListDropTarget,
            dropTargetEntryID == nil,
            onFinderFileDrop != nil
        {
            finderListDropOverlay
        }
    }

    private var finderListDropOverlay: some View {
        ZStack {
            Color.accentColor.opacity(0.10)
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(
                        lineWidth: 2,
                        dash: [7, 4]
                    )
                )
                .padding(4)
            Label(
                "上传到当前目录",
                systemImage: "arrow.up.doc.fill"
            )
            .font(.headline)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: Capsule())
        }
        .allowsHitTesting(false)
    }

    private var recentPathsMenu: some View {
        Menu {
            if recentPaths.isEmpty {
                Text("暂无传输目录")
            } else {
                ForEach(recentPaths, id: \.self) { recentPath in
                    Button {
                        onRecentPathSelect?(recentPath)
                    } label: {
                        Label(
                            recentPath,
                            systemImage: "clock.arrow.circlepath"
                        )
                    }
                }
            }
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("最近传输目录")
    }

    private func sortHeader(
        _ title: String,
        column: FileSortColumn,
        trailing: Bool
    ) -> some View {
        Button {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = true
            }
        } label: {
            HStack(spacing: 4) {
                if trailing {
                    Spacer(minLength: 0)
                }
                Text(title)
                if sortColumn == column {
                    Image(
                        systemName: sortAscending
                            ? "chevron.up"
                            : "chevron.down"
                    )
                    .font(.system(size: 8, weight: .bold))
                }
                if !trailing {
                    Spacer(minLength: 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("按\(title)\(sortColumn == column && sortAscending ? "降序" : "升序")排列")
    }

    private func fileRow(for entry: FileEntry) -> some View {
        let destinationEntry = entry.isDirectory ? entry : nil
        let finderTarget = Binding(
            get: {
                dropTargetEntryID == entry.id
            },
            set: { isTargeted in
                updateDropTarget(entry.id, isTargeted: isTargeted)
            }
        )
        let visualRow = FileEntryRow(entry: entry)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .id(entry.id)
            .contentShape(Rectangle())
            .background(
                dropTargetEntryID == entry.id
                    ? Color.accentColor.opacity(0.38)
                    : selection.contains(entry.id)
                    ? Color.accentColor.opacity(0.22)
                    : Color.clear
            )
            .onTapGesture {
                handleEntryClick(entry)
            }
            .onDrag {
                FileDragItemProvider.make(
                    dragPayload(for: entry)
                )
            } preview: {
                dragPreview(for: entry)
            }
        let dropRow = visualRow.onDrop(
            of: supportedDropTypes,
            isTargeted: finderTarget
        ) { providers in
            receiveDropProviders(
                providers,
                destinationEntry: destinationEntry
            )
        }
        return dropRow.contextMenu {
            entryContextMenu(for: entry)
        }
    }

    private func updateDropTarget(
        _ entryID: FileEntry.ID,
        isTargeted: Bool
    ) {
        if isTargeted {
            dropTargetEntryID = entryID
        } else if dropTargetEntryID == entryID {
            dropTargetEntryID = nil
        }
    }

    private var supportedDropTypes: [UTType] {
        var types = [UTType.shellHarborFileEntries]
        if onFinderFileDrop != nil {
            types.append(.fileURL)
        }
        return types
    }

    private func receiveDropProviders(
        _ providers: [NSItemProvider],
        destinationEntry: FileEntry? = nil
    ) -> Bool {
        if onFileDrop != nil {
            let acceptedInternal = FileDragItemProvider.receive(
                providers
            ) { payload in
                _ = onFileDrop?([payload], destinationEntry)
            }
            if acceptedInternal { return true }
        }
        return onFinderFileDrop?(providers, destinationEntry) ?? false
    }

    @ViewBuilder
    private func entryContextMenu(for entry: FileEntry) -> some View {
        if dragLocation == .local {
            Button {
                openLocalEntries(actionEntries(for: entry))
            } label: {
                Label("打开", systemImage: "arrow.up.forward.app")
            }
            Button {
                revealLocalEntries(actionEntries(for: entry))
            } label: {
                Label("在 Finder 中显示", systemImage: "finder")
            }
            Divider()
        }
        if let contextTransferTitle, let onContextTransfer {
            Button {
                onContextTransfer(actionEntries(for: entry))
            } label: {
                Label(
                    contextTransferTitle,
                    systemImage: contextTransferIcon ??
                        "arrow.down.circle"
                )
            }
            Divider()
        }
        Button {
            renamingEntry = entry
            renameDraft = entry.name
            showingRename = true
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Divider()
        Button {
            copyFullPath(entry.path)
        } label: {
            Label(
                "复制完整路径",
                systemImage: "document.on.document"
            )
        }
        if let contextDeleteTitle, let onContextDelete {
            Divider()
            Button(role: .destructive) {
                onContextDelete(actionEntries(for: entry))
            } label: {
                Label(contextDeleteTitle, systemImage: "trash")
            }
        }
    }

    private func actionEntries(for entry: FileEntry) -> [FileEntry] {
        guard selection.contains(entry.id) else { return [entry] }
        return sortedEntries.filter { selection.contains($0.id) }
    }

    private func dragPayload(for entry: FileEntry) -> FileDragPayload {
        FileDragPayload(
            location: dragLocation,
            items: actionEntries(for: entry).map {
                FileDragPayload.Item(
                    name: $0.name,
                    path: $0.path,
                    isDirectory: $0.isDirectory,
                    size: $0.size
                )
            }
        )
    }

    private func dragPreview(for entry: FileEntry) -> some View {
        let draggedEntries = actionEntries(for: entry)
        return HStack(spacing: 8) {
            Image(
                systemName: draggedEntries.count > 1
                    ? "doc.on.doc.fill"
                    : (entry.isDirectory ? "folder.fill" : "doc.fill")
            )
            Text(
                draggedEntries.count > 1
                    ? "\(draggedEntries.count) 个项目"
                    : entry.name
            )
            .lineLimit(1)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
    }

    private func handleEntryClick(_ entry: FileEntry) {
        let now = ProcessInfo.processInfo.systemUptime
        let isDoubleClick =
            lastClickedEntryID == entry.id &&
            now - lastEntryClickTime <= NSEvent.doubleClickInterval
        let modifiers = NSApp.currentEvent?.modifierFlags.intersection([
            .command, .shift
        ]) ?? []

        if modifiers.contains(.shift),
           let selectionAnchorID,
           let anchorIndex = sortedEntries.firstIndex(where: {
               $0.id == selectionAnchorID
           }),
           let clickedIndex = sortedEntries.firstIndex(where: {
               $0.id == entry.id
           })
        {
            let range = min(anchorIndex, clickedIndex)...max(
                anchorIndex,
                clickedIndex
            )
            selection = Set(range.map { sortedEntries[$0].id })
        } else if modifiers.contains(.command) {
            if selection.contains(entry.id) {
                selection.remove(entry.id)
            } else {
                selection.insert(entry.id)
            }
            selectionAnchorID = entry.id
        } else {
            selection = [entry.id]
            selectionAnchorID = entry.id
        }

        if isDoubleClick {
            lastClickedEntryID = nil
            lastEntryClickTime = 0
            onOpen(entry)
        } else {
            lastClickedEntryID = entry.id
            lastEntryClickTime = now
        }
    }

    private func copyFullPath(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    private func openLocalEntries(_ entries: [FileEntry]) {
        for entry in entries {
            NSWorkspace.shared.open(
                URL(
                    fileURLWithPath: entry.path,
                    isDirectory: entry.isDirectory
                )
            )
        }
    }

    private func revealLocalEntries(_ entries: [FileEntry]) {
        let urls = entries.map {
            URL(
                fileURLWithPath: $0.path,
                isDirectory: $0.isDirectory
            )
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func positionRenameCaret() {
        guard let renamingEntry else { return }
        let location = FileNameEditing.renameCaretOffset(
            for: renameDraft,
            isDirectory: renamingEntry.isDirectory
        )
        let expectedText = renameDraft

        Task { @MainActor in
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(60))
                guard showingRename else { return }
                guard
                    let editor = NSApp.keyWindow?.firstResponder
                        as? NSTextView,
                    editor.string == expectedText
                else {
                    continue
                }
                let range = NSRange(location: location, length: 0)
                editor.setSelectedRange(range)
                editor.scrollRangeToVisible(range)
                return
            }
        }
    }
}

private struct FileRenameSheet: View {
    let entry: FileEntry
    @Binding var name: String
    let onCancel: () -> Void
    let onRename: () -> Void
    @FocusState private var nameIsFocused: Bool

    private var normalizedName: String? {
        FileNameValidator.normalized(name)
    }

    private var canRename: Bool {
        guard let normalizedName else { return false }
        return normalizedName != entry.name
    }

    private var preferredWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let textWidth = (name as NSString).size(
            withAttributes: [.font: font]
        ).width
        let availableWidth = max(
            480,
            (NSScreen.main?.visibleFrame.width ?? 900) - 160
        )
        return min(max(480, ceil(textWidth) + 72), availableWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry.isDirectory ? "重命名文件夹" : "重命名文件")
                .font(.headline)

            TextField("新名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .focused($nameIsFocused)
                .onSubmit {
                    guard canRename else { return }
                    onRename()
                }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("重命名", action: onRename)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRename)
            }
        }
        .padding(20)
        .frame(width: preferredWidth)
        .onAppear {
            nameIsFocused = true
        }
    }
}

private struct FileEntryRow: View {
    let entry: FileEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder.fill" : fileIcon)
                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                .frame(width: 18)
            Text(entry.name)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.sizeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
            Text(entry.modifiedLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 110, alignment: .trailing)
            Text(entry.createdLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private var fileIcon: String {
        let ext = (entry.name as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) {
            return "photo"
        }
        if ["zip", "gz", "bz2", "xz", "tar"].contains(ext) {
            return "archivebox"
        }
        if ["swift", "py", "js", "ts", "go", "rs", "c", "cpp", "h"].contains(ext) {
            return "chevron.left.forwardslash.chevron.right"
        }
        return "doc"
    }
}

private struct TransferQueueView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var workspace: SessionWorkspace

    var body: some View {
        if workspace.transfers.isEmpty {
            ContentUnavailableView(
                "暂无传输",
                systemImage: "arrow.left.arrow.right",
                description: Text("选择文件后使用上传或下载按钮。")
            )
        } else {
            List(workspace.transfers) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.direction.symbol)
                        .foregroundStyle(item.direction == .upload ? .orange : .blue)
                        .frame(width: 22, height: 22)
                        .background(.quaternary, in: Circle())
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(item.fileName)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            transferControls(for: item)
                            Text(item.status.label)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    statusColor(item.status),
                                    in: Capsule()
                                )
                                .help(item.log)
                        }
                        Text("\(item.source)  →  \(item.destination)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let completionSummary = item.completionSummaryLabel {
                            Text(completionSummary)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else if let progress = item.progressFraction {
                            ProgressView(value: progress)
                            HStack {
                                Text(item.progressLabel ?? "")
                                Spacer()
                                if let speed = item.speedLabel {
                                    Text(speed)
                                }
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        } else if item.status == .running {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(
                                    item.isDirectory
                                        ? "正在统计目录大小并上传…"
                                        : "正在计算任务进度…"
                                )
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func transferControls(
        for item: TransferItem
    ) -> some View {
        switch item.status {
        case .running:
            Button {
                state.pauseTransfer(item.id, in: workspace)
            } label: {
                Image(systemName: "pause.fill")
            }
            .buttonStyle(.borderless)
            .help("暂停传输")
            stopButton(for: item)
        case .paused:
            Button {
                state.resumeTransfer(item.id, in: workspace)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("继续传输")
            stopButton(for: item)
        case .queued:
            stopButton(for: item)
        case .finished, .failed, .cancelled:
            EmptyView()
        }
    }

    private func stopButton(for item: TransferItem) -> some View {
        Button {
            state.stopTransfer(item.id, in: workspace)
        } label: {
            Image(systemName: "stop.fill")
        }
        .buttonStyle(.borderless)
        .help("停止传输")
    }

    private func statusColor(_ status: TransferStatus) -> Color {
        switch status {
        case .finished: .green
        case .failed: .red
        case .running: .blue
        case .paused: .orange
        case .queued: .secondary
        case .cancelled: .orange
        }
    }
}
