import Foundation
import Observation

enum MobileSFTPError: LocalizedError {
    case notConnected
    case fileTooLarge(UInt64)
    case incompleteTransfer(expected: UInt64, received: UInt64)

    var errorDescription: String? {
        switch self {
        case .notConnected: "请先连接 SSH Session。"
        case .fileTooLarge(let bytes): "文件超过移动端预览上限（\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))）。"
        case .incompleteTransfer(let expected, let received):
            "传输不完整（应为 \(expected) 字节，实际 \(received) 字节）。"
        }
    }
}

struct MobileRemoteFile: Identifiable, Sendable, Equatable {
    var id: String { path }
    let name: String
    let path: String
    let size: UInt64?
    let permissions: UInt32?
    let modifiedAt: Date?
    let createdAt: Date?

    init(
        name: String,
        path: String,
        size: UInt64?,
        permissions: UInt32?,
        modifiedAt: Date?,
        createdAt: Date? = nil
    ) {
        self.name = name
        self.path = path
        self.size = size
        self.permissions = permissions
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
    }

    var isDirectory: Bool {
        guard let permissions else { return false }
        return permissions & 0o170000 == 0o040000
    }
}

struct MobileTransfer: Identifiable {
    enum Direction { case upload, download }
    enum State { case running, paused, completed, failed, stopped }
    let id: UUID
    let name: String
    let direction: Direction
    let source: String
    let destination: String
    let startedAt: Date
    var finishedAt: Date?
    var transferred: Int64
    var total: Int64
    var state: State
    var message: String?

    func elapsed(at date: Date = Date()) -> TimeInterval {
        max((finishedAt ?? date).timeIntervalSince(startedAt), 0)
    }

    func bytesPerSecond(at date: Date = Date()) -> Double {
        let seconds = elapsed(at: date)
        return seconds > 0 ? Double(transferred) / seconds : 0
    }
}

@MainActor
@Observable
final class MobileSFTPBrowser {
    private static let previewMaximumSize: UInt64 = 10 * 1_024 * 1_024
    private static let previewExtensions: Set<String> = ["log", "txt", "plist"]

    private struct RemoteTreeEntry: Sendable {
        let remotePath: String
        let relativePath: String
        let isDirectory: Bool
        let size: Int64
    }

    private struct LocalTreeEntry: Sendable {
        let url: URL
        let relativePath: String
        let isDirectory: Bool
        let size: Int64
    }

    var currentPath = "."
    var pathInput = "."
    var focusedPath: String?
    var entries: [MobileRemoteFile] = []
    var isLoading = false
    var errorMessage: String?
    var preview: MobileFilePreview?
    var transfers: [MobileTransfer] = []
    private(set) var sortField: MobileFileSortField
    private(set) var sortAscending: Bool

    @ObservationIgnored private let ssh: MobileSSHController
    @ObservationIgnored private let remoteID: UUID
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = UUID()
    @ObservationIgnored private var transferTasks: [UUID: Task<Void, Never>] = [:]

    init(
        ssh: MobileSSHController,
        remoteID: UUID,
        defaultPath: String = ""
    ) {
        self.ssh = ssh
        self.remoteID = remoteID
        let remembered = Self.rememberedPath(for: remoteID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let configured = defaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialPath = !remembered.isEmpty
            ? remembered
            : (!configured.isEmpty ? configured : ".")
        currentPath = initialPath
        pathInput = initialPath
        sortField = MobileFileSortField(
            rawValue: UserDefaults.standard.string(forKey: "mobileRemoteSortField.\(remoteID.uuidString)") ?? ""
        ) ?? .name
        sortAscending = UserDefaults.standard.object(
            forKey: "mobileRemoteSortAscending.\(remoteID.uuidString)"
        ) as? Bool ?? true
    }

    func refresh(path: String? = nil) {
        refreshTask?.cancel()
        let generation = UUID()
        refreshGeneration = generation
        let requested = path ?? currentPath
        let preservedFocus = path == nil ? focusedPath : nil
        isLoading = true
        errorMessage = nil
        refreshTask = Task {
            do {
                let (resolved, listed) = try await ssh.sftpList(at: requested)
                try Task.checkCancellation()
                currentPath = resolved
                rememberCurrentPath()
                entries = listed.sorted(by: compare)
                if let preservedFocus, listed.contains(where: { $0.path == preservedFocus }) {
                    focusedPath = preservedFocus
                    pathInput = preservedFocus
                } else {
                    focusedPath = nil
                    pathInput = resolved
                }
            } catch is CancellationError {
            } catch {
                if refreshGeneration == generation {
                    errorMessage = error.localizedDescription
                }
            }
            if refreshGeneration == generation {
                isLoading = false
                refreshTask = nil
            }
        }
    }

    func navigateToPathInput() {
        navigate(to: pathInput)
    }

    func restorePath(_ path: String) {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        currentPath = value.isEmpty ? "." : value
        pathInput = currentPath
        rememberCurrentPath()
    }

    func navigate(to requestedPath: String) {
        refreshTask?.cancel()
        let generation = UUID()
        refreshGeneration = generation
        let requested = requestedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoading = true
        errorMessage = nil
        refreshTask = Task {
            do {
                let target = try await ssh.sftpResolvedPathAndKind(at: requested.isEmpty ? "." : requested)
                try Task.checkCancellation()
                if target.isDirectory {
                    let (resolved, listed) = try await ssh.sftpList(at: target.path)
                    try Task.checkCancellation()
                    currentPath = resolved
                    rememberCurrentPath()
                    pathInput = resolved
                    focusedPath = nil
                    entries = listed.sorted(by: compare)
                } else {
                    let parent = (target.path as NSString).deletingLastPathComponent
                    let (resolved, listed) = try await ssh.sftpList(at: parent.isEmpty ? "/" : parent)
                    try Task.checkCancellation()
                    currentPath = resolved
                    rememberCurrentPath()
                    pathInput = target.path
                    entries = listed.sorted(by: compare)
                    focusedPath = target.path
                }
            } catch is CancellationError {
            } catch {
                if refreshGeneration == generation {
                    errorMessage = error.localizedDescription
                }
            }
            if refreshGeneration == generation {
                isLoading = false
                refreshTask = nil
            }
        }
    }

    func setSortField(_ field: MobileFileSortField) {
        sortField = field
        UserDefaults.standard.set(field.rawValue, forKey: "mobileRemoteSortField.\(remoteID.uuidString)")
        entries.sort(by: compare)
    }

    func toggleSortDirection() {
        sortAscending.toggle()
        UserDefaults.standard.set(sortAscending, forKey: "mobileRemoteSortAscending.\(remoteID.uuidString)")
        entries.sort(by: compare)
    }

    func open(_ file: MobileRemoteFile) {
        if file.isDirectory { refresh(path: file.path); return }
        guard canPreview(file) else {
            errorMessage = "此文件不会自动预览，请下载到本地后打开。"
            return
        }
        let id = beginTransfer(
            name: file.name,
            direction: .download,
            source: file.path,
            destination: "文件预览",
            total: Int64(file.size ?? 0)
        )
        transferTasks[id] = Task {
            do {
                let data = try await ssh.sftpDownload(
                    path: file.path,
                    maximumSize: Self.previewMaximumSize,
                    progress: { transferred, total in
                    self.updateTransfer(id, transferred: transferred, total: total)
                    },
                    waitIfPaused: { try await self.waitUntilResumed(id) }
                )
                preview = MobileFilePreview(file: file, data: data)
                finishTransfer(id)
            } catch is CancellationError {
                stopTransferState(id)
            } catch {
                errorMessage = error.localizedDescription
                failTransfer(id, message: error.localizedDescription)
            }
            transferTasks[id] = nil
        }
    }

    func canPreview(_ file: MobileRemoteFile) -> Bool {
        guard !file.isDirectory,
              let size = file.size,
              size < Self.previewMaximumSize else { return false }
        let pathExtension = (file.name as NSString).pathExtension.lowercased()
        return Self.previewExtensions.contains(pathExtension)
    }

    func download(_ file: MobileRemoteFile, to localBrowser: MobileLocalFileBrowser) {
        let destination = localBrowser.collisionFreeURL(
            for: file.name,
            isDirectory: file.isDirectory
        )
        let displayedDestination = localBrowser.displayPath == "/"
            ? "/\(destination.lastPathComponent)"
            : "\(localBrowser.displayPath)/\(destination.lastPathComponent)"
        let id = beginTransfer(
            name: file.name,
            direction: .download,
            source: file.path,
            destination: displayedDestination,
            total: Int64(file.size ?? 0)
        )
        transferTasks[id] = Task {
            do {
                var completed: Int64 = 0
                for try await entry in remoteManifestStream(for: file, transferID: id) {
                    try Task.checkCancellation()
                    try await waitUntilResumed(id)
                    let localURL = entry.relativePath.isEmpty
                        ? destination
                        : destination.appendingPathComponent(entry.relativePath, isDirectory: entry.isDirectory)
                    if entry.isDirectory {
                        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
                    } else {
                        let completedBeforeFile = completed
                        try await ssh.sftpDownload(
                            path: entry.remotePath,
                            to: localURL,
                            progress: { transferred, _ in
                                self.updateTransfer(
                                    id,
                                    transferred: completedBeforeFile + transferred
                                )
                            },
                            waitIfPaused: { try await self.waitUntilResumed(id) }
                        )
                        completed += entry.size
                    }
                }
                localBrowser.refresh()
                finishTransfer(id)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: destination)
                stopTransferState(id)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                errorMessage = error.localizedDescription
                failTransfer(id, message: error.localizedDescription)
            }
            transferTasks[id] = nil
        }
    }

    func upload(localFiles: [MobileLocalFile], cleanupRoot: URL? = nil) {
        guard !localFiles.isEmpty else { return }
        let id = beginTransfer(
            name: localFiles.count == 1 ? localFiles[0].name : "上传 \(localFiles.count) 个项目",
            direction: .upload,
            source: localFiles.count == 1
                ? localFiles[0].url.path : "\(localFiles.count) 个本地项目",
            destination: currentPath,
            total: localFiles.compactMap(\.size).reduce(0, +)
        )
        transferTasks[id] = Task {
            defer {
                if let cleanupRoot { try? FileManager.default.removeItem(at: cleanupRoot) }
            }
            let totalTask = Task.detached(priority: .utility) {
                try localFiles.reduce(Int64(0)) { total, file in
                    try Task.checkCancellation()
                    return total + (try Self.localManifest(for: file)).reduce(Int64(0)) {
                        $0 + ($1.isDirectory ? 0 : $1.size)
                    }
                }
            }
            let totalUpdateTask = Task { [weak self] in
                guard let total = try? await totalTask.value,
                      !Task.isCancelled else { return }
                self?.setTransferTotal(id, total: total)
            }
            defer {
                totalUpdateTask.cancel()
                totalTask.cancel()
            }
            do {
                var completed: Int64 = 0
                var reservedNames = Set(entries.map(\.name))
                for source in localFiles {
                    let rootName = collisionFreeRemoteName(
                        source.name,
                        isDirectory: source.isDirectory,
                        reserved: reservedNames
                    )
                    reservedNames.insert(rootName)
                    let remoteRoot = joined(rootName)
                    for try await entry in Self.localManifestStream(for: source) {
                        try Task.checkCancellation()
                        try await waitUntilResumed(id)
                        let remotePath = entry.relativePath.isEmpty
                            ? remoteRoot
                            : Self.joinRemotePath(remoteRoot, entry.relativePath)
                        if entry.isDirectory {
                            try await ssh.sftpCreateDirectory(at: remotePath)
                        } else {
                            let completedBeforeFile = completed
                            try await ssh.sftpUpload(
                                fileURL: entry.url,
                                to: remotePath,
                                progress: { transferred, _ in
                                    self.updateTransfer(
                                        id,
                                        transferred: completedBeforeFile + transferred
                                    )
                                },
                                waitIfPaused: { try await self.waitUntilResumed(id) }
                            )
                            completed += entry.size
                        }
                    }
                }
                let total = try await totalTask.value
                setTransferTotal(id, total: total)
                finishTransfer(id)
                refresh()
            } catch is CancellationError {
                stopTransferState(id)
            } catch {
                errorMessage = error.localizedDescription
                failTransfer(id, message: error.localizedDescription)
            }
            transferTasks[id] = nil
        }
    }

    func goToParent() {
        guard currentPath != "/" else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        refresh(path: parent.isEmpty ? "/" : parent)
    }

    func upload(data: Data, named name: String) {
        upload(files: [(name, data)])
    }

    func upload(files: [(String, Data)]) {
        var reservedNames = Set(entries.map(\.name))
        let uploads = files.map { file -> (sourceName: String, remoteName: String, data: Data) in
            let remoteName = collisionFreeRemoteName(
                file.0,
                isDirectory: false,
                reserved: reservedNames
            )
            reservedNames.insert(remoteName)
            return (file.0, remoteName, file.1)
        }
        let total = files.reduce(Int64(0)) { $0 + Int64($1.1.count) }
        let id = beginTransfer(
            name: files.count == 1 ? files[0].0 : "上传 \(files.count) 个文件",
            direction: .upload,
            source: files.count == 1 ? files[0].0 : "\(files.count) 个导入文件",
            destination: uploads.count == 1
                ? joined(uploads[0].remoteName) : currentPath,
            total: total
        )
        transferTasks[id] = Task {
            do {
                var completed: Int64 = 0
                for upload in uploads {
                    try Task.checkCancellation()
                    let completedBeforeFile = completed
                    try await ssh.sftpUpload(data: upload.data, to: joined(upload.remoteName), progress: { transferred, _ in
                        self.updateTransfer(id, transferred: completedBeforeFile + transferred, total: total)
                    }, waitIfPaused: { try await self.waitUntilResumed(id) })
                    completed += Int64(upload.data.count)
                }
                finishTransfer(id)
                refresh()
            } catch is CancellationError {
                stopTransferState(id)
            } catch {
                errorMessage = error.localizedDescription
                failTransfer(id, message: error.localizedDescription)
            }
            transferTasks[id] = nil
        }
    }

    func createDirectory(named name: String) {
        guard let normalized = MobileFileNameValidator.normalized(name) else {
            errorMessage = "文件名不能为空，不能是 . 或 ..，也不能包含 /。"
            return
        }
        isLoading = true
        Task {
            do {
                try await ssh.sftpCreateDirectory(at: joined(normalized))
                refresh()
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    func rename(_ file: MobileRemoteFile, to name: String) {
        guard let normalized = MobileFileNameValidator.normalized(name) else {
            errorMessage = "文件名不能为空，不能是 . 或 ..，也不能包含 /。"
            return
        }
        guard normalized != file.name else { return }
        isLoading = true
        Task {
            do {
                try await ssh.sftpRename(from: file.path, to: joined(normalized))
                refresh()
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    func delete(_ file: MobileRemoteFile) {
        delete([file])
    }

    func delete(_ files: [MobileRemoteFile]) {
        isLoading = true
        Task {
            do {
                for file in files {
                    try Task.checkCancellation()
                    try await ssh.sftpDelete(file)
                }
                refresh()
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func joined(_ name: String) -> String {
        currentPath == "/" ? "/\(name)" : "\(currentPath)/\(name)"
    }

    private func rememberCurrentPath() {
        var paths = UserDefaults.standard.dictionary(forKey: "mobileRemotePaths")
            as? [String: String] ?? [:]
        paths[remoteID.uuidString] = currentPath
        UserDefaults.standard.set(paths, forKey: "mobileRemotePaths")
    }

    private static func rememberedPath(for remoteID: UUID) -> String {
        let paths = UserDefaults.standard.dictionary(forKey: "mobileRemotePaths")
            as? [String: String]
        return paths?[remoteID.uuidString] ?? ""
    }

    private func compare(_ lhs: MobileRemoteFile, _ rhs: MobileRemoteFile) -> Bool {
        if sortField == .modifiedAt || sortField == .createdAt {
            let leftDate = sortField == .modifiedAt ? lhs.modifiedAt : lhs.createdAt
            let rightDate = sortField == .modifiedAt ? rhs.modifiedAt : rhs.createdAt
            if (leftDate == nil) != (rightDate == nil) {
                return leftDate != nil
            }
        }
        let order: ComparisonResult
        switch sortField {
        case .name:
            order = lhs.name.localizedStandardCompare(rhs.name)
        case .modifiedAt:
            order = compareOptional(lhs.modifiedAt, rhs.modifiedAt)
        case .createdAt:
            order = compareOptional(lhs.createdAt, rhs.createdAt)
        case .size:
            let left = lhs.size ?? 0
            let right = rhs.size ?? 0
            order = left == right ? .orderedSame
                : (left < right ? .orderedAscending : .orderedDescending)
        }
        if order == .orderedSame {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return sortAscending ? order == .orderedAscending : order == .orderedDescending
    }

    private func compareOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        case (nil, nil): .orderedSame
        case (nil, _): .orderedAscending
        case (_, nil): .orderedDescending
        }
    }

    func cancelRefresh() {
        refreshGeneration = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        isLoading = false
    }

    func stopTransfer(_ id: UUID) {
        transferTasks[id]?.cancel()
        transferTasks[id] = nil
        stopTransferState(id)
    }

    func pauseTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }),
              transfers[index].state == .running else { return }
        transfers[index].state = .paused
    }

    func resumeTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }),
              transfers[index].state == .paused else { return }
        transfers[index].state = .running
    }

    func clearCompletedTransfers() {
        transfers.removeAll { $0.state == .completed }
    }

    private func beginTransfer(
        name: String,
        direction: MobileTransfer.Direction,
        source: String,
        destination: String,
        total: Int64
    ) -> UUID {
        let id = UUID()
        transfers.insert(MobileTransfer(
            id: id,
            name: name,
            direction: direction,
            source: source,
            destination: destination,
            startedAt: Date(),
            finishedAt: nil,
            transferred: 0,
            total: total,
            state: .running,
            message: nil
        ), at: 0)
        return id
    }
    private func updateTransfer(_ id: UUID, transferred: Int64, total: Int64) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].transferred = transferred
        if total > 0 { transfers[index].total = total }
    }
    private func updateTransfer(_ id: UUID, transferred: Int64) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].transferred = transferred
    }
    private func setTransferTotal(_ id: UUID, total: Int64) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].total = total
    }
    private func finishTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].transferred = transfers[index].total
        transfers[index].state = .completed
        transfers[index].finishedAt = Date()
    }
    private func failTransfer(_ id: UUID, message: String) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = .failed
        transfers[index].message = message
        transfers[index].finishedAt = Date()
    }
    private func stopTransferState(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = .stopped
        transfers[index].finishedAt = Date()
    }


    private func waitUntilResumed(_ id: UUID) async throws {
        while transfers.first(where: { $0.id == id })?.state == .paused {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
    }

    private func remoteManifestStream(
        for root: MobileRemoteFile,
        transferID: UUID
    ) -> AsyncThrowingStream<RemoteTreeEntry, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                do {
                    var discoveredTotal: Int64 = 0
                    func walk(
                        _ file: MobileRemoteFile,
                        relativePath: String
                    ) async throws {
                        try Task.checkCancellation()
                        let size = file.isDirectory ? 0 : Int64(file.size ?? 0)
                        discoveredTotal += size
                        await setTransferTotal(transferID, total: discoveredTotal)
                        continuation.yield(RemoteTreeEntry(
                            remotePath: file.path,
                            relativePath: relativePath,
                            isDirectory: file.isDirectory,
                            size: size
                        ))
                        guard file.isDirectory else { return }
                        let (_, children) = try await ssh.sftpList(at: file.path)
                        for child in children {
                            let childRelative = relativePath.isEmpty
                                ? child.name
                                : "\(relativePath)/\(child.name)"
                            try await walk(child, relativePath: childRelative)
                        }
                    }
                    try await walk(root, relativePath: "")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    nonisolated private static func localManifest(for root: MobileLocalFile) throws -> [LocalTreeEntry] {
        var result: [LocalTreeEntry] = []
        func walk(url: URL, relativePath: String) throws {
            try Task.checkCancellation()
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ]
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { return }
            let isDirectory = values.isDirectory == true
            guard isDirectory || values.isRegularFile == true else { return }
            result.append(LocalTreeEntry(
                url: url,
                relativePath: relativePath,
                isDirectory: isDirectory,
                size: isDirectory ? 0 : Int64(values.fileSize ?? 0)
            ))
            guard isDirectory else { return }
            let children = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: []
            ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for child in children {
                let childRelative = relativePath.isEmpty
                    ? child.lastPathComponent
                    : "\(relativePath)/\(child.lastPathComponent)"
                try walk(url: child, relativePath: childRelative)
            }
        }
        try walk(url: root.url, relativePath: "")
        return result
    }

    nonisolated private static func localManifestStream(
        for root: MobileLocalFile
    ) -> AsyncThrowingStream<LocalTreeEntry, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task.detached(priority: .userInitiated) {
                do {
                    func walk(url: URL, relativePath: String) throws {
                        try Task.checkCancellation()
                        let keys: Set<URLResourceKey> = [
                            .isDirectoryKey, .isRegularFileKey,
                            .isSymbolicLinkKey, .fileSizeKey
                        ]
                        let values = try url.resourceValues(forKeys: keys)
                        guard values.isSymbolicLink != true else { return }
                        let isDirectory = values.isDirectory == true
                        guard isDirectory || values.isRegularFile == true else { return }
                        continuation.yield(LocalTreeEntry(
                            url: url,
                            relativePath: relativePath,
                            isDirectory: isDirectory,
                            size: isDirectory ? 0 : Int64(values.fileSize ?? 0)
                        ))
                        guard isDirectory else { return }
                        let children = try FileManager.default.contentsOfDirectory(
                            at: url,
                            includingPropertiesForKeys: Array(keys),
                            options: []
                        ).sorted {
                            $0.lastPathComponent.localizedStandardCompare(
                                $1.lastPathComponent
                            ) == .orderedAscending
                        }
                        for child in children {
                            let childRelative = relativePath.isEmpty
                                ? child.lastPathComponent
                                : "\(relativePath)/\(child.lastPathComponent)"
                            try walk(url: child, relativePath: childRelative)
                        }
                    }
                    try walk(url: root.url, relativePath: "")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    private func collisionFreeRemoteName(
        _ name: String,
        isDirectory: Bool,
        reserved: Set<String>
    ) -> String {
        guard !reserved.contains(name) else {
            let pathExtension = isDirectory ? "" : (name as NSString).pathExtension
            let base = isDirectory ? name : (name as NSString).deletingPathExtension
            for index in 1...10_000 {
                let candidate = pathExtension.isEmpty
                    ? "\(base) (\(index))"
                    : "\(base) (\(index)).\(pathExtension)"
                if !reserved.contains(candidate) { return candidate }
            }
            return "\(UUID().uuidString)-\(name)"
        }
        return name
    }

    nonisolated private static func joinRemotePath(_ parent: String, _ child: String) -> String {
        parent == "/" ? "/\(child)" : "\(parent)/\(child)"
    }
}

struct MobileFilePreview: Identifiable {
    let id = UUID()
    let file: MobileRemoteFile
    let data: Data

    var text: String? { String(data: data, encoding: .utf8) }
}
