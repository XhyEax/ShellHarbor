@preconcurrency import Citadel
import Crypto
import Darwin
import Foundation
import NIOCore
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

enum MobileSSHError: LocalizedError {
    case missingIdentity
    case unreadableIdentity
    case unsupportedIdentity

    var errorDescription: String? {
        switch self {
        case .missingIdentity: "该 Remote 尚未选择私钥。"
        case .unreadableIdentity: "无法读取所选私钥。"
        case .unsupportedIdentity: "目前终端支持 RSA 和 ED25519 OpenSSH 私钥。"
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
    private(set) var state = MobileSSHState.idle
    private(set) var hostKeyPrompt: MobileHostKeyPrompt?
    var title = ""
    var lastDirectory: String?

    @ObservationIgnored private var connectionTask: Task<Void, Never>?
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
    @ObservationIgnored private var pendingHostKeyDecision: (@Sendable (Bool) -> Void)?
    @ObservationIgnored private var pendingStartupCommand: String?
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
        outputHistory = Array(restoredOutputHistory.suffix(4_000_000))
        lastDirectory = restoredDirectory
        moshEncodedState = restoredMoshState
        moshServerPort = restoredMoshServerPort
        moshKey = restoredMoshKey
        pendingStartupCommand = startupCommand
    }

    func restorationOutputHistory() -> Data {
        Data(outputHistory.suffix(4_000_000))
    }

    func restorationMoshState() -> Data { moshEncodedState }
    func restorationMoshServerPort() -> Int? { moshServerPort }
    func restorationMoshKey() -> String? { moshKey }

    func connect(output: @escaping @MainActor ([UInt8]) -> Void) {
        outputHandler = output
        if !outputHistory.isEmpty { output(outputHistory) }
        guard connectionTask == nil else { return }
        state = .connecting
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runConnection()
                if !Task.isCancelled { self.state = .disconnected }
            } catch is CancellationError {
                self.state = .disconnected
            } catch {
                self.state = .failed(Self.safeMessage(for: error))
            }
            self.writer = nil
            self.client = nil
            self.jumpClient = nil
            self.connectionTask = nil
        }
    }

    func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
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
        let entries = responses.flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { component in
                MobileRemoteFile(
                    name: component.filename,
                    path: Self.joinRemotePath(resolved, component.filename),
                    size: component.attributes.size,
                    permissions: component.attributes.permissions,
                    modifiedAt: component.attributes.accessModificationTime?.modificationTime
                )
            }
            .sorted {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        return (resolved, entries)
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

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        if let moshTransport {
            moshTransport.resize(cols: cols, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            return
        }
        guard let writer, cols > 0, rows > 0 else { return }
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
        let configuredServer = jumpProfile.moshServerCommand
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
                }
            },
            onOutput: { [weak self] bytes in
                Task { @MainActor [weak self] in self?.deliver(bytes) }
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
        if profile.authentication == .password {
            let password = try MobilePasswordCipher.decrypt(profile.password)
            return .passwordBased(username: profile.username, password: password)
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
        decision: @escaping @Sendable (Bool) -> Void
    ) {
        if autoTrustNewHosts, !changed {
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
        outputHistory.append(contentsOf: bytes)
        if outputHistory.count > 4_000_000 {
            outputHistory.removeFirst(outputHistory.count - 4_000_000)
        }
        outputHandler?(bytes)
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
        runStartupCommandIfNeeded()
    }

    private func runStartupCommandIfNeeded() {
        guard let command = pendingStartupCommand else { return }
        pendingStartupCommand = nil
        send(Array("\(command)\r".utf8)[...])
    }

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

    private static func safeMessage(for error: Error) -> String {
        let message = error.localizedDescription
        return message.isEmpty ? "SSH 连接失败" : message
    }
}
