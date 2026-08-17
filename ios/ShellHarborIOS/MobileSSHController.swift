@preconcurrency import Citadel
import Crypto
import Darwin
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Observation

enum MobileSSHState: Equatable {
    case idle
    case connecting
    case connected
    case disconnected
    case failed(String)

    var title: String {
        switch self {
        case .idle: "未连接"
        case .connecting: "正在连接"
        case .connected: "在线"
        case .disconnected: "已断开"
        case .failed: "连接失败"
        }
    }
}

private struct MobilePendingTerminalInput {
    private(set) var text = ""
    private(set) var isReliable = true
    private var cursorOffset = 0

    mutating func restore(_ value: String?) {
        text = value ?? ""
        cursorOffset = text.count
        isReliable = true
    }

    mutating func record(_ bytes: [UInt8]) {
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x1B {
                if let consumed = handleEscapeSequence(Array(bytes[index...])) {
                    index += consumed
                } else {
                    isReliable = false
                    index += 1
                }
                continue
            }
            switch byte {
            case 0x0A, 0x0D, 0x03:
                clear()
                index += 1
            case 0x7F, 0x08:
                removeBeforeCursor()
                index += 1
            case 0x01:
                cursorOffset = 0
                index += 1
            case 0x05:
                cursorOffset = text.count
                index += 1
            case 0x04:
                removeAtCursor()
                index += 1
            case 0x15:
                clear()
                index += 1
            case 0x17:
                removePreviousWord()
                index += 1
            case 0x09:
                isReliable = false
                index += 1
            case 0x00...0x1F:
                index += 1
            default:
                let start = index
                while index < bytes.count,
                      bytes[index] >= 0x20,
                      bytes[index] != 0x7F,
                      bytes[index] != 0x1B {
                    index += 1
                }
                insert(String(decoding: bytes[start..<index], as: UTF8.self))
            }
        }
    }

    private mutating func handleEscapeSequence(_ bytes: [UInt8]) -> Int? {
        if bytes.starts(with: [0x1B, 0x5B, 0x44]) {
            moveCursor(by: -1)
            return 3
        }
        if bytes.starts(with: [0x1B, 0x5B, 0x43]) {
            moveCursor(by: 1)
            return 3
        }
        if bytes.starts(with: [0x1B, 0x5B, 0x48]) {
            cursorOffset = 0
            return 3
        }
        if bytes.starts(with: [0x1B, 0x5B, 0x46]) {
            cursorOffset = text.count
            return 3
        }
        if bytes.starts(with: [0x1B, 0x5B, 0x33, 0x7E]) {
            removeAtCursor()
            return 4
        }
        if bytes.starts(with: [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) ||
            bytes.starts(with: [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]) {
            return 6
        }
        if bytes.starts(with: [0x1B, 0x5B, 0x41]) ||
            bytes.starts(with: [0x1B, 0x5B, 0x42]) {
            isReliable = false
            return 3
        }
        return nil
    }

    private mutating func insert(_ value: String) {
        let index = text.index(text.startIndex, offsetBy: cursorOffset)
        text.insert(contentsOf: value, at: index)
        cursorOffset += value.count
    }

    private mutating func moveCursor(by offset: Int) {
        cursorOffset = min(max(cursorOffset + offset, 0), text.count)
    }

    private mutating func removeBeforeCursor() {
        guard cursorOffset > 0 else { return }
        let index = text.index(text.startIndex, offsetBy: cursorOffset - 1)
        text.remove(at: index)
        cursorOffset -= 1
    }

    private mutating func removeAtCursor() {
        guard cursorOffset < text.count else { return }
        text.remove(at: text.index(text.startIndex, offsetBy: cursorOffset))
    }

    private mutating func removePreviousWord() {
        while cursorOffset > 0, characterBeforeCursor?.isWhitespace == true {
            removeBeforeCursor()
        }
        while cursorOffset > 0, characterBeforeCursor?.isWhitespace == false {
            removeBeforeCursor()
        }
    }

    private var characterBeforeCursor: Character? {
        guard cursorOffset > 0 else { return nil }
        return text[text.index(text.startIndex, offsetBy: cursorOffset - 1)]
    }

    private mutating func clear() {
        text = ""
        cursorOffset = 0
        isReliable = true
    }
}

enum MobileSSHError: LocalizedError {
    case missingPassword
    case missingIdentity
    case unreadableIdentity
    case unsupportedIdentity
    case unavailableSSHAgent

    var errorDescription: String? {
        switch self {
        case .missingPassword: "该 Remote 使用密码认证，但尚未填写密码。请编辑 Remote 后重试。"
        case .missingIdentity: "该 Remote 尚未选择私钥。"
        case .unreadableIdentity: "无法读取所选私钥。"
        case .unsupportedIdentity: "目前终端支持 RSA 和 ED25519 OpenSSH 私钥。"
        case .unavailableSSHAgent: "iOS 无法访问 macOS 的 SSH Agent；请为此 Remote 选择已导入的私钥或密码。"
        }
    }
}

struct MobileHostKeyPrompt: Identifiable, Equatable {
    let id = UUID()
    let endpoint: String
    let algorithm: String
    let fingerprint: String
    let key: String
    let isChanged: Bool
}

private final class MobileHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private struct Rejected: LocalizedError {
        var errorDescription: String? { "已取消主机密钥确认。" }
    }
    let endpoint: String
    let trustedKey: String?
    let requestDecision: @Sendable (String, String, String, String, Bool, @escaping @Sendable (Bool) -> Void) -> Void

    init(
        endpoint: String,
        trustedKey: String?,
        requestDecision: @escaping @Sendable (String, String, String, String, Bool, @escaping @Sendable (Bool) -> Void) -> Void
    ) {
        self.endpoint = endpoint
        self.trustedKey = trustedKey
        self.requestDecision = requestDecision
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let key = String(openSSHPublicKey: hostKey)
        if trustedKey == key {
            validationCompletePromise.succeed(())
            return
        }
        let parts = key.split(separator: " ", maxSplits: 1)
        let algorithm = parts.first.map(String.init) ?? "SSH"
        let keyData = parts.count > 1 ? Data(base64Encoded: String(parts[1])) ?? Data(key.utf8) : Data(key.utf8)
        let digest = SHA256.hash(data: keyData)
        let fingerprint = "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        requestDecision(endpoint, algorithm, fingerprint, key, trustedKey != nil) { accepted in
            if accepted {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(Rejected())
            }
        }
    }
}

private final class MobileHostTrustBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedKey: String?

    init(_ key: String?) {
        storedKey = key
    }

    var key: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedKey
    }

    func set(_ key: String) {
        lock.lock()
        storedKey = key
        lock.unlock()
    }
}

@MainActor
@Observable
final class MobileSSHController {
    private(set) var state = MobileSSHState.idle {
        didSet {
            if Self.connectionIntent(for: state) != Self.connectionIntent(for: oldValue) {
                onRestorationChanged?()
            }
        }
    }
    private(set) var hostKeyPrompt: MobileHostKeyPrompt?
    private(set) var clearRequestID = UUID()
    private(set) var searchRequestID = UUID()
    private(set) var keyboardToggleRequestID = UUID()
    private(set) var searchTerm = ""
    private(set) var searchForward = true
    private(set) var searchFound: Bool?
    private(set) var shouldClearSearch = false
    var title = "" {
        didSet { if title != oldValue { onRestorationChanged?() } }
    }
    var lastDirectory: String? {
        didSet { if lastDirectory != oldValue { onRestorationChanged?() } }
    }
    @ObservationIgnored var onRestorationChanged: (() -> Void)?

    func findTerminalText(_ term: String, forward: Bool) {
        guard !term.isEmpty else {
            clearTerminalSearch()
            return
        }
        searchTerm = term
        searchForward = forward
        shouldClearSearch = false
        searchRequestID = UUID()
    }

    func clearTerminalSearch() {
        searchTerm = ""
        searchFound = nil
        shouldClearSearch = true
        searchRequestID = UUID()
    }

    func toggleTerminalKeyboard() {
        keyboardToggleRequestID = UUID()
    }

    func updateSearchResult(found: Bool) {
        searchFound = found
    }

    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?
    @ObservationIgnored private var client: SSHClient?
    @ObservationIgnored private var jumpClient: SSHClient?
    @ObservationIgnored private var fileClient: SSHClient?
    @ObservationIgnored private var fileJumpClient: SSHClient?
    @ObservationIgnored private var sftpClient: SFTPClient?
    @ObservationIgnored private var writer: TTYStdinWriter?
    @ObservationIgnored private var moshTransport: MobileMoshTransport?
    @ObservationIgnored private var moshEncodedState = Data()
    @ObservationIgnored private var moshServerPort: Int?
    @ObservationIgnored private var moshKey: String?
    @ObservationIgnored private var outputHandler: (@MainActor ([UInt8]) -> Void)?
    @ObservationIgnored private var outputHistory: [UInt8] = []
    @ObservationIgnored private var pendingInput = MobilePendingTerminalInput()
    @ObservationIgnored private var restoredPendingCommand: String?
    @ObservationIgnored private var restoredInputTask: Task<Void, Never>?
    @ObservationIgnored private var startupCommandTask: Task<Void, Never>?
    @ObservationIgnored private var lastOutputAt = ContinuousClock.now
    @ObservationIgnored private var hasReceivedLiveOutput = false
    @ObservationIgnored private var pendingHostKeyDecision: (@Sendable (Bool) -> Void)?
    @ObservationIgnored private var pendingStartupCommand: String?
    @ObservationIgnored private var lastTerminalSize:
        (cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int)?
    @ObservationIgnored private let configuredStartupCommand: String?
    @ObservationIgnored private let trustHostKey: @MainActor (String) -> Void
    @ObservationIgnored private let trustJumpHostKey: @MainActor (String) -> Void
    @ObservationIgnored private let autoTrustNewHosts: Bool
    @ObservationIgnored nonisolated private let tailscaleProxyManager: MobileTailscaleProxyManager?

    nonisolated let remote: MobileRemoteProfile
    nonisolated private let identityURL: URL?
    nonisolated private let jumpRemote: MobileRemoteProfile?
    nonisolated private let jumpIdentityURL: URL?
    nonisolated private let hostTrust: MobileHostTrustBox
    nonisolated private let jumpHostTrust: MobileHostTrustBox

    init(
        remote: MobileRemoteProfile,
        identityURL: URL?,
        jumpRemote: MobileRemoteProfile?,
        jumpIdentityURL: URL?,
        trustedHostKey: String?,
        trustedJumpHostKey: String?,
        trustHostKey: @escaping @MainActor (String) -> Void,
        trustJumpHostKey: @escaping @MainActor (String) -> Void,
        autoTrustNewHosts: Bool = false,
        tailscaleProxyManager: MobileTailscaleProxyManager? = nil,
        restoredOutputHistory: Data = Data(),
        restoredPendingCommand: String? = nil,
        restoredDirectory: String? = nil,
        restoredMoshState: Data = Data(),
        restoredMoshServerPort: Int? = nil,
        restoredMoshKey: String? = nil,
        startupCommand: String? = nil
    ) {
        self.remote = remote
        self.identityURL = identityURL
        self.jumpRemote = jumpRemote
        self.jumpIdentityURL = jumpIdentityURL
        hostTrust = MobileHostTrustBox(trustedHostKey)
        jumpHostTrust = MobileHostTrustBox(trustedJumpHostKey)
        self.trustHostKey = trustHostKey
        self.trustJumpHostKey = trustJumpHostKey
        self.autoTrustNewHosts = autoTrustNewHosts
        self.tailscaleProxyManager = tailscaleProxyManager
        outputHistory = Array(restoredOutputHistory.suffix(Self.maximumRestorationBytes))
        self.restoredPendingCommand = restoredPendingCommand
        pendingInput.restore(restoredPendingCommand)
        let requestedDirectory = (restoredDirectory ?? remote.remoteStartPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lastDirectory = requestedDirectory.isEmpty ? nil : requestedDirectory
        moshEncodedState = restoredMoshState
        moshServerPort = restoredMoshServerPort
        moshKey = restoredMoshKey
        var startup: [String] = []
        if !requestedDirectory.isEmpty {
            startup.append(Self.changeDirectoryCommand(requestedDirectory))
        }
        if let startupCommand,
           !startupCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            startup.append(startupCommand)
        }
        let configuredStartup = startup.isEmpty ? nil : startup.joined(separator: " && ")
        configuredStartupCommand = configuredStartup
        pendingStartupCommand = configuredStartup
    }

    func restorationOutputHistory() -> Data {
        Data(outputHistory.suffix(Self.maximumRestorationBytes))
    }

    func restorationPendingCommand() -> String? {
        guard pendingInput.isReliable, !pendingInput.text.isEmpty else { return nil }
        return pendingInput.text
    }

    func restorationMoshState() -> Data { moshEncodedState }
    func restorationMoshServerPort() -> Int? { moshServerPort }
    func restorationMoshKey() -> String? { moshKey }

    var hasConnectionIntent: Bool {
        Self.connectionIntent(for: state)
    }

    private static func connectionIntent(for state: MobileSSHState) -> Bool {
        switch state {
        case .idle, .disconnected:
            false
        case .connecting, .connected, .failed:
            true
        }
    }

    func connect(output: @escaping @MainActor ([UInt8]) -> Void) {
        outputHandler = output
        if !outputHistory.isEmpty { output(outputHistory) }
        guard connectionTask == nil else { return }
        if pendingStartupCommand == nil {
            pendingStartupCommand = configuredStartupCommand
        }
        hasReceivedLiveOutput = false
        lastOutputAt = .now
        state = .connecting
        let generation = UUID()
        connectionGeneration = generation
        connectionTask = Task { [weak self] in
            guard let self else { return }
            var retry = 0
            while !Task.isCancelled {
                do {
                    try await self.runConnection()
                    if self.connectionGeneration == generation {
                        self.state = .disconnected
                    }
                    break
                } catch is CancellationError {
                    if self.connectionGeneration == generation {
                        self.state = .disconnected
                    }
                    break
                } catch {
                    guard self.connectionGeneration == generation else { break }
                    if retry < 3, Self.isTransientConnectionError(error) {
                        retry += 1
                        await self.resetConnectionResourcesForRetry()
                        self.state = .connecting
                        do {
                            try await Task.sleep(for: .seconds(retry))
                        } catch { break }
                        continue
                    }
                    self.state = .failed(self.connectionFailureMessage(for: error))
                    break
                }
            }
            guard self.connectionGeneration == generation else { return }
            self.writer = nil
            self.keepAliveTask?.cancel()
            self.keepAliveTask = nil
            self.client = nil
            self.jumpClient = nil
            self.connectionTask = nil
        }
    }

    func disconnect() {
        connectionGeneration = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        restoredInputTask?.cancel()
        restoredInputTask = nil
        startupCommandTask?.cancel()
        startupCommandTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        writer = nil
        moshTransport?.stop()
        moshTransport = nil
        let activeClient = client
        let activeJumpClient = jumpClient
        let activeFileClient = fileClient
        let activeFileJumpClient = fileJumpClient
        let activeSFTPClient = sftpClient
        client = nil
        jumpClient = nil
        fileClient = nil
        fileJumpClient = nil
        sftpClient = nil
        state = .disconnected
        Task {
            try? await activeSFTPClient?.close()
            try? await activeClient?.close()
            try? await activeJumpClient?.close()
            try? await activeFileClient?.close()
            try? await activeFileJumpClient?.close()
        }
    }

    func sftpList(at path: String) async throws -> (String, [MobileRemoteFile]) {
        let sftp = try await activeSFTPClient()
        let resolved = try await sftp.getRealPath(atPath: path.isEmpty ? "." : path)
        let responses = try await sftp.listDirectory(atPath: resolved)
        let creationDates = (try? await remoteCreationDates(in: resolved)) ?? [:]
        let entries = responses.flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { component in
                MobileRemoteFile(
                    name: component.filename,
                    path: Self.joinRemotePath(resolved, component.filename),
                    size: component.attributes.size,
                    permissions: component.attributes.permissions,
                    modifiedAt: component.attributes.accessModificationTime?.modificationTime,
                    createdAt: creationDates[component.filename]
                )
            }
            .sorted {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        return (resolved, entries)
    }

    private func remoteCreationDates(in directory: String) async throws -> [String: Date] {
        let command = """
        cd -- \(Self.shellQuote(directory)) && \
        { setopt NULL_GLOB 2>/dev/null || true; } && \
        if stat -f '%B' . >/dev/null 2>&1; then stat_style=bsd; else stat_style=gnu; fi; \
        for f in .[^.]* *; do \
          [ "$f" = "." ] && continue; [ "$f" = ".." ] && continue; \
          [ -e "$f" ] || [ -L "$f" ] || continue; \
          if [ "$stat_style" = bsd ]; then c=$(stat -f '%B' "$f" 2>/dev/null || printf '0'); \
          else c=$(stat -c '%W' -- "$f" 2>/dev/null || printf '0'); fi; \
          printf '%s\\t%s\\n' "$c" "$f"; \
        done
        """
        let output = try await executeInspectionCommand(command)
        return output.split(separator: "\n").reduce(into: [:]) { result, line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let timestamp = TimeInterval(parts[0]),
                  timestamp > 0 else { return }
            result[String(parts[1])] = Date(timeIntervalSince1970: timestamp)
        }
    }

    func sftpResolvedPathAndKind(at path: String) async throws -> (path: String, isDirectory: Bool) {
        let sftp = try await activeSFTPClient()
        let requested = path.isEmpty ? "." : path
        let resolved = try await sftp.getRealPath(atPath: requested)
        let attributes = try await sftp.getAttributes(at: resolved)
        let isDirectory = (attributes.permissions ?? 0) & 0o170000 == 0o040000
        return (resolved, isDirectory)
    }

    func sftpDownload(
        path: String,
        maximumSize: UInt64 = 25_000_000,
        progress: (@MainActor (Int64, Int64) -> Void)? = nil,
        waitIfPaused: (@MainActor () async throws -> Void)? = nil
    ) async throws -> Data {
        let sftp = try await activeSFTPClient()
        let attributes = try await sftp.getAttributes(at: path)
        if let size = attributes.size, size > maximumSize {
            throw MobileSFTPError.fileTooLarge(size)
        }
        return try await sftp.withFile(filePath: path, flags: .read) { file in
            let total = Int64(attributes.size ?? 0)
            var offset: UInt64 = 0
            var result = Data()
            let expectedSize = attributes.size
            let readLimit = min(expectedSize ?? maximumSize, maximumSize)
            while offset < readLimit {
                try Task.checkCancellation()
                try await waitIfPaused?()
                let length = UInt32(min(256 * 1024, Int(readLimit - offset)))
                let buffer = try await file.read(from: offset, length: length)
                guard buffer.readableBytes > 0 else { break }
                result.append(contentsOf: buffer.readableBytesView)
                offset += UInt64(buffer.readableBytes)
                await progress?(Int64(offset), total)
            }
            if let expectedSize, offset != expectedSize {
                throw MobileSFTPError.incompleteTransfer(expected: expectedSize, received: offset)
            }
            if expectedSize == nil, offset == maximumSize {
                throw MobileSFTPError.fileTooLarge(offset)
            }
            return result
        }
    }

    func sftpDownload(
        path: String,
        to destination: URL,
        progress: (@MainActor (Int64, Int64) -> Void)? = nil,
        waitIfPaused: (@MainActor () async throws -> Void)? = nil
    ) async throws {
        let sftp = try await activeSFTPClient()
        let attributes = try await sftp.getAttributes(at: path)
        let total = Int64(attributes.size ?? 0)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        do {
            try await sftp.withFile(filePath: path, flags: .read) { file in
                var offset: UInt64 = 0
                while true {
                    if let expected = attributes.size, offset >= expected { break }
                    try Task.checkCancellation()
                    try await waitIfPaused?()
                    let remaining = attributes.size.map { Int($0 - offset) } ?? 256 * 1024
                    let length = UInt32(min(256 * 1024, remaining))
                    let buffer = try await file.read(from: offset, length: length)
                    guard buffer.readableBytes > 0 else { break }
                    let data = Data(buffer.readableBytesView)
                    try output.write(contentsOf: data)
                    offset += UInt64(data.count)
                    await progress?(Int64(offset), total)
                }
                if let expected = attributes.size, offset != expected {
                    throw MobileSFTPError.incompleteTransfer(expected: expected, received: offset)
                }
            }
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func sftpUpload(
        data: Data,
        to path: String,
        progress: (@MainActor (Int64, Int64) -> Void)? = nil,
        waitIfPaused: (@MainActor () async throws -> Void)? = nil
    ) async throws {
        let sftp = try await activeSFTPClient()
        try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                try await waitIfPaused?()
                let end = min(offset + 256 * 1024, data.count)
                var buffer = ByteBufferAllocator().buffer(capacity: end - offset)
                buffer.writeBytes(data[offset..<end])
                try await file.write(buffer, at: UInt64(offset))
                offset = end
                await progress?(Int64(offset), Int64(data.count))
            }
        }
    }

    func sftpUpload(
        fileURL: URL,
        to path: String,
        progress: (@MainActor (Int64, Int64) -> Void)? = nil,
        waitIfPaused: (@MainActor () async throws -> Void)? = nil
    ) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let total = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let input = try FileHandle(forReadingFrom: fileURL)
        let sftp = try await activeSFTPClient()
        do {
            try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
                var offset: UInt64 = 0
                while true {
                    try Task.checkCancellation()
                    try await waitIfPaused?()
                    guard let data = try input.read(upToCount: 256 * 1024), !data.isEmpty else { break }
                    var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                    buffer.writeBytes(data)
                    try await file.write(buffer, at: offset)
                    offset += UInt64(data.count)
                    await progress?(Int64(offset), total)
                }
            }
            try input.close()
        } catch {
            try? input.close()
            throw error
        }
    }

    func sftpCreateDirectory(at path: String) async throws {
        try await activeSFTPClient().createDirectory(atPath: path)
    }

    func sftpRename(from oldPath: String, to newPath: String) async throws {
        try await activeSFTPClient().rename(at: oldPath, to: newPath)
    }

    func sftpDelete(_ file: MobileRemoteFile) async throws {
        let sftp = try await activeSFTPClient()
        try await sftpDelete(file, using: sftp)
    }

    func executeInspectionCommand(_ command: String) async throws -> String {
        guard state == .connected else { throw MobileSFTPError.notConnected }
        let ssh: SSHClient
        if let client, client.isConnected {
            ssh = client
        } else if let fileClient, fileClient.isConnected {
            ssh = fileClient
        } else {
            ssh = try await openFileSSHClient()
        }
        let response = try await ssh.executeCommand(command, maxResponseSize: 128_000)
        return String(decoding: response.readableBytesView, as: UTF8.self)
    }

    func loadCommandHistory() async throws -> [MobileCommandHistoryEntry] {
        let output = try await executeInspectionCommand(MobileRemoteHistoryService.script)
        return MobileRemoteHistoryService.parse(output)
    }

    func insertTerminalText(_ text: String) {
        guard state == .connected else { return }
        let bytes = Array(text.utf8)
        send(bytes[...])
    }

    func insertRemotePaths(_ paths: [String]) {
        let text = paths
            .filter { !$0.isEmpty }
            .map(Self.shellQuote)
            .joined(separator: " ")
        insertTerminalText(text)
    }

    private func sftpDelete(_ file: MobileRemoteFile, using sftp: SFTPClient) async throws {
        try Task.checkCancellation()
        guard file.isDirectory else {
            try await sftp.remove(at: file.path)
            return
        }
        let children = try await sftp.listDirectory(atPath: file.path)
            .flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
        for child in children {
            let nested = MobileRemoteFile(
                name: child.filename,
                path: Self.joinRemotePath(file.path, child.filename),
                size: child.attributes.size,
                permissions: child.attributes.permissions,
                modifiedAt: child.attributes.accessModificationTime?.modificationTime
            )
            try await sftpDelete(nested, using: sftp)
        }
        try await sftp.rmdir(at: file.path)
    }

    func reconnect() {
        guard let outputHandler else { return }
        restoredPendingCommand = restorationPendingCommand()
        disconnect()
        connect(output: outputHandler)
    }

    func acceptHostKey() {
        guard let prompt = hostKeyPrompt, let decision = pendingHostKeyDecision else { return }
        if prompt.endpoint == remote.hostKeyEndpoint {
            hostTrust.set(prompt.key)
            trustHostKey(prompt.key)
        } else {
            jumpHostTrust.set(prompt.key)
            trustJumpHostKey(prompt.key)
        }
        hostKeyPrompt = nil
        pendingHostKeyDecision = nil
        decision(true)
    }

    func rejectHostKey() {
        let decision = pendingHostKeyDecision
        hostKeyPrompt = nil
        pendingHostKeyDecision = nil
        decision?(false)
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        pendingInput.record(Array(bytes))
        onRestorationChanged?()
        sendWithoutTracking(bytes)
    }

    private func sendWithoutTracking(_ bytes: ArraySlice<UInt8>) {
        if let moshTransport {
            moshTransport.send(Array(bytes))
            return
        }
        guard let writer else { return }
        let copy = Array(bytes)
        Task {
            var buffer = ByteBufferAllocator().buffer(capacity: copy.count)
            buffer.writeBytes(copy)
            try? await writer.write(buffer)
        }
    }

    func sendInterrupt() {
        guard state == .connected else { return }
        let interrupt: [UInt8] = [0x03]
        send(interrupt[...])
    }

    func startLocalPortForward(
        bindHost: String,
        listenPort: Int,
        targetHost: String,
        targetPort: Int
    ) async throws -> Channel {
        guard state == .connected, let client, client.isConnected else {
            throw MobilePortForwardError.sessionNotConnected
        }
        let sshClient = client
        return try await ServerBootstrap(group: sshClient.eventLoop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { localChannel in
                localChannel.eventLoop.makeFutureWithTask {
                    let origin: SocketAddress
                    if let remoteAddress = localChannel.remoteAddress {
                        origin = remoteAddress
                    } else {
                        origin = try SocketAddress(
                            ipAddress: "127.0.0.1",
                            port: 0
                        )
                    }
                    let (localGlue, sshGlue) = MobilePortForwardGlue.matchedPair()
                    let sshChannel = try await sshClient.createDirectTCPIPChannel(
                        using: SSHChannelType.DirectTCPIP(
                            targetHost: targetHost,
                            targetPort: targetPort,
                            originatorAddress: origin
                        )
                    ) { channel in
                        channel.pipeline.addHandler(sshGlue)
                    }
                    try await localChannel.pipeline.addHandler(localGlue).get()
                    try await localChannel.setOption(
                        ChannelOptions.autoRead,
                        value: true
                    ).get()
                    try await sshChannel.setOption(
                        ChannelOptions.autoRead,
                        value: true
                    ).get()
                }
            }
            .bind(host: bindHost, port: listenPort)
            .get()
    }

    func clearLocalBuffer() {
        outputHistory.removeAll(keepingCapacity: true)
        clearRequestID = UUID()
    }

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        guard cols > 0, rows > 0 else { return }
        lastTerminalSize = (cols, rows, pixelWidth, pixelHeight)
        if let moshTransport {
            moshTransport.resize(cols: cols, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            return
        }
        guard let writer else { return }
        Task {
            try? await writer.changeSize(
                cols: cols,
                rows: rows,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        }
    }

    nonisolated private func runConnection() async throws {
        if remote.connectionMethod != .ssh,
           let restoredPort = await currentMoshServerPort(),
           let restoredKey = await currentMoshKey(),
           !(await currentMoshState()).isEmpty {
            let endpointProfile: MobileRemoteProfile
            if remote.connectionMethod == .jumpMosh {
                guard let jumpRemote else { throw MobileMoshError.missingJumpRemote }
                endpointProfile = jumpRemote
            } else {
                endpointProfile = remote
            }
            try await startMoshTransport(
                endpointProfile: endpointProfile,
                serverPort: restoredPort,
                key: restoredKey
            )
            return
        }
        let auth = try authenticationMethod(for: remote, identityURL: identityURL)
        let connectedClient: SSHClient
        if remote.connectionMethod == .jumpMosh {
            guard let jumpRemote else { throw MobileMoshError.missingJumpRemote }
            let jumpEndpoint = try await connectionEndpoint(for: jumpRemote)
            let jumpAuth = try authenticationMethod(for: jumpRemote, identityURL: jumpIdentityURL)
            let origin = try await SSHClient.connect(
                host: jumpEndpoint.host,
                port: jumpEndpoint.port,
                authenticationMethod: jumpAuth,
                hostKeyValidator: hostKeyValidator(for: jumpRemote, trust: jumpHostTrust),
                reconnect: .never
            )
            await setJumpClient(origin)
            try await runJumpMosh(using: origin, jumpProfile: jumpRemote)
            return
        }
        if let jumpRemote {
            let jumpEndpoint = try await connectionEndpoint(for: jumpRemote)
            let jumpAuth = try authenticationMethod(for: jumpRemote, identityURL: jumpIdentityURL)
            let origin = try await SSHClient.connect(
                host: jumpEndpoint.host,
                port: jumpEndpoint.port,
                authenticationMethod: jumpAuth,
                hostKeyValidator: hostKeyValidator(for: jumpRemote, trust: jumpHostTrust),
                reconnect: .never
            )
            await setJumpClient(origin)
            let settings = SSHClientSettings(
                host: remote.host.isEmpty ? "127.0.0.1" : remote.host,
                port: remote.port,
                authenticationMethod: { auth },
                hostKeyValidator: hostKeyValidator(for: remote, trust: hostTrust)
            )
            connectedClient = try await origin.jump(to: settings)
        } else {
            let endpoint = try await connectionEndpoint(for: remote)
            connectedClient = try await SSHClient.connect(
                host: endpoint.host,
                port: endpoint.port,
                authenticationMethod: auth,
                hostKeyValidator: hostKeyValidator(for: remote, trust: hostTrust),
                reconnect: .never
            )
        }
        await setClient(connectedClient)

        if remote.connectionMethod == .mosh {
            try await runMosh(using: connectedClient)
            return
        }

        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([.ECHO: 1])
        )
        try await connectedClient.withPTY(request) { [weak self] inbound, outbound in
            guard let self else { return }
            await self.activate(outbound)
            for try await event in inbound {
                try Task.checkCancellation()
                let bytes: [UInt8]
                switch event {
                case .stdout(let buffer), .stderr(let buffer):
                    bytes = Array(buffer.readableBytesView)
                }
                await self.deliver(bytes)
            }
        }
    }

    nonisolated private func runJumpMosh(
        using jumpClient: SSHClient,
        jumpProfile: MobileRemoteProfile
    ) async throws {
        let configuredForSession = remote.jumpMoshServerCommand
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredServer = configuredForSession.isEmpty
            ? jumpProfile.moshServerCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            : configuredForSession
        let executable = configuredServer.isEmpty ? "mosh-server" : configuredServer
        let requestedPort = remote.moshUDPPort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !requestedPort.isEmpty,
           requestedPort.range(of: #"^\d{1,5}(:\d{1,5})?$"#, options: .regularExpression) == nil {
            throw MobileMoshError.bootstrapFailed
        }
        let targetHost = remote.host.isEmpty ? "127.0.0.1" : remote.host
        let target = "\(remote.username)@\(targetHost)"
        let targetCommand = ["ssh", "-tt", "-p", String(remote.port), target]
            .map(Self.shellQuote)
            .joined(separator: " ")
        var command = "\(executable) new -s -c 256 -l LANG=en_US.UTF-8"
        if !requestedPort.isEmpty { command += " -p \(requestedPort)" }
        command += " -- \(targetCommand) 2>/dev/null"
        let response = try await jumpClient.executeCommand(command, maxResponseSize: 32_768)
        let text = String(decoding: response.readableBytesView, as: UTF8.self)
        guard let parameters = Self.parseMoshConnect(text),
              let serverPort = Int(parameters.port) else {
            throw MobileMoshError.invalidBootstrapResponse
        }
        try? await jumpClient.close()
        try await startMoshTransport(
            endpointProfile: jumpProfile,
            serverPort: serverPort,
            key: parameters.key
        )
    }

    nonisolated private func runMosh(using connectedClient: SSHClient) async throws {
        let server = remote.moshServerCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = server.isEmpty ? "mosh-server" : server
        let requestedPort = remote.moshUDPPort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !requestedPort.isEmpty,
           requestedPort.range(of: #"^\d{1,5}(:\d{1,5})?$"#, options: .regularExpression) == nil {
            throw MobileMoshError.bootstrapFailed
        }
        var command = "\(executable) new -s -c 256 -l LANG=en_US.UTF-8"
        if !requestedPort.isEmpty { command += " -p \(requestedPort)" }
        command += " 2>/dev/null"
        let response = try await connectedClient.executeCommand(command, maxResponseSize: 32_768)
        let text = String(decoding: response.readableBytesView, as: UTF8.self)
        guard let parameters = Self.parseMoshConnect(text) else {
            throw MobileMoshError.invalidBootstrapResponse
        }
        guard let serverPort = Int(parameters.port) else {
            throw MobileMoshError.invalidBootstrapResponse
        }
        try? await connectedClient.close()
        try await startMoshTransport(
            endpointProfile: remote,
            serverPort: serverPort,
            key: parameters.key
        )
    }

    nonisolated private func startMoshTransport(
        endpointProfile: MobileRemoteProfile,
        serverPort: Int,
        key: String
    ) async throws {
        let moshEndpoint: (host: String, port: Int)
        if let tailscaleProxyManager {
            let forwarded = try await tailscaleProxyManager.forwardedMoshEndpoint(
                for: endpointProfile,
                serverPort: serverPort
            )
            moshEndpoint = (try Self.numericHost(forwarded.host), forwarded.port)
        } else {
            let host = endpointProfile.host.isEmpty ? "127.0.0.1" : endpointProfile.host
            moshEndpoint = (
                try Self.numericHost(host),
                serverPort
            )
        }
        let transport = MobileMoshTransport()
        await setMoshTransport(transport, serverPort: serverPort, key: key)
        try await transport.run(
            host: moshEndpoint.host,
            port: String(moshEndpoint.port),
            key: key,
            restoredState: await currentMoshState(),
            onStarted: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.state = .connected
                    self?.runStartupCommandIfNeeded()
                    self?.scheduleRestoredInputIfNeeded()
                }
            },
            onOutput: { [weak self] bytes in
                // The pipe reader invokes this callback serially. Preserve
                // that byte order with the main dispatch queue's FIFO rather
                // than creating independent Tasks, whose execution order is
                // unspecified. Mosh emits cursor-addressed screen diffs, so
                // even one reordered chunk corrupts nested SSH and command
                // output with missing characters and shifted columns.
                DispatchQueue.main.async { [weak self] in
                    self?.deliver(bytes)
                }
            },
            onState: { [weak self] state in
                Task { @MainActor [weak self] in self?.moshEncodedState = state }
            }
        )
    }

    nonisolated private static func parseMoshConnect(_ output: String) -> (port: String, key: String)? {
        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 4, parts[0] == "MOSH", parts[1] == "CONNECT",
               Int(parts[2]) != nil, !parts[3].isEmpty {
                return (String(parts[2]), String(parts[3]))
            }
        }
        return nil
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    nonisolated private static func changeDirectoryCommand(_ path: String) -> String {
        if path == "~" { return "cd -- \"$HOME\"" }
        if path.hasPrefix("~/") {
            return "cd -- \"$HOME\"/\(shellQuote(String(path.dropFirst(2))))"
        }
        return "cd -- \(shellQuote(path))"
    }

    nonisolated private static func numericHost(_ host: String) throws -> String {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return host }
        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return host }

        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, nil, &addresses) == 0, let first = addresses else {
            throw MobileMoshError.unresolvedHost(host)
        }
        defer { freeaddrinfo(first) }
        var fallback: String?
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current?.pointee {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                info.ai_addr,
                info.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let value = String(decoding: bytes, as: UTF8.self)
                if info.ai_family == AF_INET { return value }
                if fallback == nil, info.ai_family == AF_INET6 { fallback = value }
            }
            current = info.ai_next
        }
        guard let fallback else { throw MobileMoshError.unresolvedHost(host) }
        return fallback
    }

    nonisolated private func connectionEndpoint(
        for profile: MobileRemoteProfile
    ) async throws -> (host: String, port: Int) {
        if let tailscaleProxyManager {
            return try await tailscaleProxyManager.forwardedEndpoint(for: profile)
        }
        return (profile.host.isEmpty ? "127.0.0.1" : profile.host, profile.port)
    }

    nonisolated private func authenticationMethod(
        for profile: MobileRemoteProfile,
        identityURL: URL?
    ) throws -> SSHAuthenticationMethod {
        switch profile.authentication {
        case .password:
            let password = try MobilePasswordCipher.decrypt(profile.password)
            guard !password.isEmpty else { throw MobileSSHError.missingPassword }
            return .passwordBased(username: profile.username, password: password)
        case .agent:
            // iOS has no macOS-style ssh-agent. When exactly one imported key
            // exists, ImportedKeyStore supplies it for a nil identity ID, so
            // an imported macOS Agent profile can retain its intent and still
            // connect without requiring a manual profile edit.
            guard identityURL != nil else {
                throw MobileSSHError.unavailableSSHAgent
            }
        case .privateKey:
            break
        }
        guard let identityURL else { throw MobileSSHError.missingIdentity }
        guard let data = try? Data(contentsOf: identityURL),
              let text = String(data: data, encoding: .utf8) else {
            throw MobileSSHError.unreadableIdentity
        }
        let type = try SSHKeyDetection.detectPrivateKeyType(from: text)
        switch type {
        case .rsa:
            return .custom(try RSASHA256AuthenticationDelegate(username: profile.username, openSSH: data))
        case .ed25519:
            return .ed25519(username: profile.username, privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: data))
        default:
            throw MobileSSHError.unsupportedIdentity
        }
    }

    nonisolated private func hostKeyValidator(
        for profile: MobileRemoteProfile,
        trust: MobileHostTrustBox
    ) -> SSHHostKeyValidator {
        let validator = MobileHostKeyValidator(
            endpoint: profile.hostKeyEndpoint,
            trustedKey: trust.key
        ) { [weak self] endpoint, algorithm, fingerprint, key, changed, decision in
            Task { @MainActor [weak self] in
                self?.presentHostKeyPrompt(
                    endpoint: endpoint,
                    algorithm: algorithm,
                    fingerprint: fingerprint,
                    key: key,
                    changed: changed,
                    policy: profile.hostKeyPolicy,
                    decision: decision
                )
            }
        }
        return .custom(validator)
    }

    private func presentHostKeyPrompt(
        endpoint: String,
        algorithm: String,
        fingerprint: String,
        key: String,
        changed: Bool,
        policy: MobileHostKeyPolicy,
        decision: @escaping @Sendable (Bool) -> Void
    ) {
        if policy == .strict {
            decision(false)
            return
        }
        if (policy == .acceptNew || autoTrustNewHosts), !changed {
            if endpoint == remote.hostKeyEndpoint {
                hostTrust.set(key)
                trustHostKey(key)
            } else {
                jumpHostTrust.set(key)
                trustJumpHostKey(key)
            }
            decision(true)
            return
        }
        pendingHostKeyDecision?(false)
        pendingHostKeyDecision = decision
        hostKeyPrompt = MobileHostKeyPrompt(
            endpoint: endpoint,
            algorithm: algorithm,
            fingerprint: fingerprint,
            key: key,
            isChanged: changed
        )
    }

    private func deliver(_ bytes: [UInt8]) {
        hasReceivedLiveOutput = true
        lastOutputAt = .now
        outputHistory.append(contentsOf: bytes)
        if outputHistory.count > Self.maximumRestorationBytes {
            outputHistory.removeFirst(outputHistory.count - Self.maximumRestorationBytes)
        }
        outputHandler?(bytes)
        onRestorationChanged?()
    }

    private func setClient(_ client: SSHClient) {
        self.client = client
    }

    private func setJumpClient(_ client: SSHClient) {
        jumpClient = client
    }

    private func setMoshTransport(
        _ transport: MobileMoshTransport,
        serverPort: Int,
        key: String
    ) {
        moshTransport = transport
        moshServerPort = serverPort
        moshKey = key
    }

    private func currentMoshState() -> Data { moshEncodedState }
    private func currentMoshServerPort() -> Int? { moshServerPort }
    private func currentMoshKey() -> String? { moshKey }

    private func activate(_ writer: TTYStdinWriter) {
        self.writer = writer
        state = .connected
        startKeepAliveIfNeeded()
        runStartupCommandIfNeeded()
        scheduleRestoredInputIfNeeded()
    }

    private func startKeepAliveIfNeeded() {
        keepAliveTask?.cancel()
        guard remote.connectionMethod == .ssh, remote.keepAliveSeconds > 0 else { return }
        let interval = UInt64(remote.keepAliveSeconds) * 1_000_000_000
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self, self.state == .connected,
                      let client = self.client, client.isConnected else { continue }
                _ = try? await client.executeCommand(":", maxResponseSize: 1_024)
            }
        }
    }

    private func runStartupCommandIfNeeded() {
        guard pendingStartupCommand != nil, startupCommandTask == nil else { return }
        // SSH channel activation is earlier than login-shell readiness. Wait
        // for real terminal output and then for a quiet window, which means
        // shell rc files and prompt drawing have settled. A bounded fallback
        // still supports shells that intentionally print no prompt.
        startupCommandTask = Task { [weak self] in
            defer { self?.startupCommandTask = nil }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(8))
            while !Task.isCancelled {
                guard let self, self.state == .connected else { return }
                let quietLongEnough = clock.now - self.lastOutputAt >= .seconds(1)
                if (self.hasReceivedLiveOutput && quietLongEnough) || clock.now >= deadline {
                    guard let command = self.pendingStartupCommand else { return }
                    self.pendingStartupCommand = nil
                    self.sendWithoutTracking(Array(command.utf8)[...])
                    do { try await Task.sleep(for: .milliseconds(120)) }
                    catch { return }
                    guard self.state == .connected else { return }
                    self.sendWithoutTracking([0x0D][...])
                    do { try await Task.sleep(for: .milliseconds(650)) }
                    catch { return }
                    guard self.state == .connected,
                          let size = self.lastTerminalSize else { return }
                    // tmux becomes the foreground process after the startup
                    // command is submitted, so re-send the current PTY size.
                    self.resize(
                        cols: size.cols,
                        rows: size.rows,
                        pixelWidth: size.pixelWidth,
                        pixelHeight: size.pixelHeight
                    )
                    return
                }
                do { try await Task.sleep(for: .milliseconds(150)) }
                catch { return }
            }
        }
    }

    private func scheduleRestoredInputIfNeeded() {
        guard restoredInputTask == nil,
              let command = restoredPendingCommand,
              !command.isEmpty else { return }
        restoredInputTask = Task { [weak self] in
            defer { self?.restoredInputTask = nil }
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            guard let self, self.state == .connected else { return }
            self.sendWithoutTracking(Array(command.utf8)[...])
            self.restoredPendingCommand = nil
        }
    }

    private static let maximumRestorationBytes = 16_777_216

    private func activeSFTPClient() async throws -> SFTPClient {
        guard state == .connected else { throw MobileSFTPError.notConnected }
        if let sftpClient, sftpClient.isActive { return sftpClient }
        let ssh: SSHClient
        if let client, client.isConnected {
            ssh = client
        } else if let fileClient, fileClient.isConnected {
            ssh = fileClient
        } else {
            ssh = try await openFileSSHClient()
        }
        let opened = try await ssh.openSFTP()
        sftpClient = opened
        return opened
    }

    private func openFileSSHClient() async throws -> SSHClient {
        let auth = try authenticationMethod(for: remote, identityURL: identityURL)
        let connected: SSHClient
        if let jumpRemote {
            let jumpEndpoint = try await connectionEndpoint(for: jumpRemote)
            let jumpAuth = try authenticationMethod(for: jumpRemote, identityURL: jumpIdentityURL)
            let origin = try await SSHClient.connect(
                host: jumpEndpoint.host,
                port: jumpEndpoint.port,
                authenticationMethod: jumpAuth,
                hostKeyValidator: hostKeyValidator(for: jumpRemote, trust: jumpHostTrust),
                reconnect: .never
            )
            fileJumpClient = origin
            let settings = SSHClientSettings(
                host: remote.host.isEmpty ? "127.0.0.1" : remote.host,
                port: remote.port,
                authenticationMethod: { auth },
                hostKeyValidator: hostKeyValidator(for: remote, trust: hostTrust)
            )
            connected = try await origin.jump(to: settings)
        } else {
            let endpoint = try await connectionEndpoint(for: remote)
            connected = try await SSHClient.connect(
                host: endpoint.host,
                port: endpoint.port,
                authenticationMethod: auth,
                hostKeyValidator: hostKeyValidator(for: remote, trust: hostTrust),
                reconnect: .never
            )
        }
        fileClient = connected
        return connected
    }

    private static func joinRemotePath(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/\(name)" : "\(parent)/\(name)"
    }

    private func connectionFailureMessage(for error: Error) -> String {
        let endpoint = remote.host.isEmpty ? "127.0.0.1" : remote.host
        var route = "目标：\(remote.username)@\(endpoint):\(remote.port)"
        if remote.proxyType == .tailscale || remote.savedProxyID != nil {
            route += "（SSH over Tailscale）"
        } else if let jumpRemote {
            route += "（经跳板 \(jumpRemote.name)）"
        }
        return route + "\n" + Self.detailedMessage(for: error)
    }

    static func detailedMessage(for error: Error) -> String {
        let nsError = error as NSError
        var parts: [String] = []
        let localized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !localized.isEmpty { parts.append(localized) }
        parts.append("错误类型：\(String(reflecting: type(of: error)))")
        parts.append("错误域：\(nsError.domain)，代码：\(nsError.code)")
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("底层错误：\(underlying.domain) \(underlying.code) · \(underlying.localizedDescription)")
        }
        return Array(NSOrderedSet(array: parts))
            .compactMap { $0 as? String }
            .joined(separator: "\n")
    }

    private func resetConnectionResourcesForRetry() async {
        writer = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        moshTransport?.stop()
        moshTransport = nil
        let activeClient = client
        let activeJumpClient = jumpClient
        client = nil
        jumpClient = nil
        try? await activeClient?.close()
        try? await activeJumpClient?.close()
    }

    private static func isTransientConnectionError(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        let value = String(reflecting: error).lowercased() + " " +
            error.localizedDescription.lowercased()
        return [
            "channelerror", "nioconnectionerror", "ssherror",
            "connection reset", "connection closed", "timed out",
            "timeout", "network is unreachable", "not connected",
            "socket is not connected", "error 0"
        ].contains { value.contains($0) }
    }
}
