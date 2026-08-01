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

    var isDirectory: Bool {
        guard let permissions else { return false }
        return permissions & 0o170000 == 0o040000
    }
}

struct MobileTransfer: Identifiable {
    enum State { case running, paused, completed, failed, stopped }
    let id: UUID
    let name: String
    let startedAt: Date
    var transferred: Int64
    var total: Int64
    var state: State
    var message: String?
}

@MainActor
@Observable
final class MobileSFTPBrowser {
    var currentPath = "."
    var entries: [MobileRemoteFile] = []
    var isLoading = false
    var errorMessage: String?
    var preview: MobileFilePreview?
    var transfers: [MobileTransfer] = []

    @ObservationIgnored private let ssh: MobileSSHController
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var transferTasks: [UUID: Task<Void, Never>] = [:]

    init(ssh: MobileSSHController) {
        self.ssh = ssh
    }

    func refresh(path: String? = nil) {
        refreshTask?.cancel()
        let requested = path ?? currentPath
        isLoading = true
        errorMessage = nil
        refreshTask = Task {
            do {
                let (resolved, listed) = try await ssh.sftpList(at: requested)
                try Task.checkCancellation()
                currentPath = resolved
                entries = listed
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func open(_ file: MobileRemoteFile) {
        if file.isDirectory { refresh(path: file.path); return }
        let id = beginTransfer(name: file.name, total: Int64(file.size ?? 0))
        transferTasks[id] = Task {
            do {
                let data = try await ssh.sftpDownload(path: file.path, progress: { transferred, total in
                    self.updateTransfer(id, transferred: transferred, total: total)
                }, waitIfPaused: { try await self.waitUntilResumed(id) })
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

    func goToParent() {
        guard currentPath != "/" else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        refresh(path: parent.isEmpty ? "/" : parent)
    }

    func upload(data: Data, named name: String) {
        upload(files: [(name, data)])
    }

    func upload(files: [(String, Data)]) {
        let total = files.reduce(Int64(0)) { $0 + Int64($1.1.count) }
        let id = beginTransfer(name: files.count == 1 ? files[0].0 : "上传 \(files.count) 个文件", total: total)
        transferTasks[id] = Task {
            do {
                var completed: Int64 = 0
                for (name, data) in files {
                    try Task.checkCancellation()
                    let completedBeforeFile = completed
                    try await ssh.sftpUpload(data: data, to: joined(name), progress: { transferred, _ in
                        self.updateTransfer(id, transferred: completedBeforeFile + transferred, total: total)
                    }, waitIfPaused: { try await self.waitUntilResumed(id) })
                    completed += Int64(data.count)
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
        isLoading = true
        Task {
            do {
                try await ssh.sftpCreateDirectory(at: joined(name))
                refresh()
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    func rename(_ file: MobileRemoteFile, to name: String) {
        isLoading = true
        Task {
            do {
                try await ssh.sftpRename(from: file.path, to: joined(name))
                refresh()
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    func delete(_ file: MobileRemoteFile) {
        isLoading = true
        Task {
            do {
                try await ssh.sftpDelete(file)
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

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
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

    func clearFinishedTransfers() {
        transfers.removeAll { $0.state != .running && $0.state != .paused }
    }

    private func beginTransfer(name: String, total: Int64) -> UUID {
        let id = UUID()
        transfers.insert(MobileTransfer(id: id, name: name, startedAt: Date(), transferred: 0,
            total: total, state: .running, message: nil), at: 0)
        return id
    }
    private func updateTransfer(_ id: UUID, transferred: Int64, total: Int64) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].transferred = transferred
        if total > 0 { transfers[index].total = total }
    }
    private func finishTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].transferred = transfers[index].total
        transfers[index].state = .completed
    }
    private func failTransfer(_ id: UUID, message: String) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = .failed
        transfers[index].message = message
    }
    private func stopTransferState(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = .stopped
    }


    private func waitUntilResumed(_ id: UUID) async throws {
        while transfers.first(where: { $0.id == id })?.state == .paused {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
    }
}

struct MobileFilePreview: Identifiable {
    let id = UUID()
    let file: MobileRemoteFile
    let data: Data

    var text: String? { String(data: data, encoding: .utf8) }
}
