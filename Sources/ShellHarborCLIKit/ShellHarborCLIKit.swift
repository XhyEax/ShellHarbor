import CryptoKit
import Darwin
import Foundation
import Security

public enum SHCLIError: LocalizedError {
    case configurationMissing(String)
    case invalidConfiguration
    case remoteNotFound(String)
    case ambiguousRemote(String, [String])
    case invalidRemote(String)
    case jumpRemoteNotFound(String)
    case passwordUnavailable(String)
    case privateKeyUnavailable
    case sshpassUnavailable
    case invalidProxy(String)
    case tailscaleHelperUnavailable
    case tailscaleStartupFailed(String)
    case scpDirectionRequired(String, String)
    case pipeFailure(Int32)
    case processFailure(String, Int32)

    public var errorDescription: String? {
        switch self {
        case let .configurationMissing(path):
            "找不到 ShellHarbor 配置：\(path)"
        case .invalidConfiguration:
            "无法解析 ShellHarbor Remote 配置。"
        case let .remoteNotFound(selector):
            "找不到 Remote：\(selector)"
        case let .ambiguousRemote(selector, names):
            "Remote 选择不唯一：\(selector)（\(names.joined(separator: ", "))）"
        case let .invalidRemote(name):
            "Remote 配置无效：\(name)"
        case let .jumpRemoteNotFound(name):
            "Remote \(name) 配置的跳板不存在。"
        case let .passwordUnavailable(name):
            "无法读取 Remote \(name) 的本地加密密码。"
        case .privateKeyUnavailable:
            "找不到 ShellHarbor 本地 RSA 私钥。"
        case .sshpassUnavailable:
            "未找到 sshpass。请先安装 sshpass。"
        case let .invalidProxy(name):
            "Remote \(name) 的 Proxy 配置无效。"
        case .tailscaleHelperUnavailable:
            "找不到 ShellHarbor 内置 Tailscale helper。"
        case let .tailscaleStartupFailed(message):
            "Tailscale Proxy 启动失败：\(message)"
        case let .scpDirectionRequired(source, destination):
            "from 和 to 在本地都存在，无法自动判断 SCP 方向：\(source) → \(destination)。请在交互终端中重新执行并选择方向。"
        case let .pipeFailure(code):
            "无法创建安全密码管道（errno \(code)）。"
        case let .processFailure(path, code):
            "无法启动 \(path)（errno \(code)）。"
        }
    }
}

public enum SHCLIConnectionOverride: Equatable {
    case configured
    case ssh
    case mosh
}

public struct SHCLIConnectionRequest: Equatable {
    public let selector: String
    public let connectionOverride: SHCLIConnectionOverride
    public let remoteCommand: [String]

    public init(
        selector: String,
        connectionOverride: SHCLIConnectionOverride,
        remoteCommand: [String] = []
    ) {
        self.selector = selector
        self.connectionOverride = connectionOverride
        self.remoteCommand = remoteCommand
    }

    /// Accepts both `c <remote> [command ...]` and the shorthand form.
    public static func parse(_ arguments: [String]) -> Self? {
        var values = arguments
        if values.first == "c" || values.first == "connect" {
            values.removeFirst()
        }
        var connectionOverride = SHCLIConnectionOverride.configured
        var didSetOverride = false

        while let flag = values.first, flag == "--mosh" || flag == "--ssh" {
            guard !didSetOverride else { return nil }
            connectionOverride = flag == "--mosh" ? .mosh : .ssh
            didSetOverride = true
            values.removeFirst()
        }
        guard let selector = values.first, !selector.hasPrefix("-") else {
            return nil
        }
        values.removeFirst()
        while let flag = values.first, flag == "--mosh" || flag == "--ssh" {
            guard !didSetOverride else { return nil }
            connectionOverride = flag == "--mosh" ? .mosh : .ssh
            didSetOverride = true
            values.removeFirst()
        }
        if values.first == "--" {
            values.removeFirst()
        }
        return Self(
            selector: selector,
            connectionOverride: connectionOverride,
            remoteCommand: values
        )
    }
}

private final class SHRelayResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<String, Error>?

    func set(_ value: Result<String, Error>) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Result<String, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

public final class SHTailscaleProxyProcess {
    private struct Ready: Decodable {
        let type: String
        let host: String
        let port: Int
        let controlPort: Int
    }

    private let process: Process
    public let port: Int
    private let controlPort: Int

    private init(process: Process, port: Int, controlPort: Int) {
        self.process = process
        self.port = port
        self.controlPort = controlPort
    }

    deinit {
        if process.isRunning {
            process.terminate()
        }
    }

    public static func startIfNeeded(
        profile: SHRemoteProfile
    ) throws -> SHTailscaleProxyProcess? {
        guard profile.usesTailscaleProxy else { return nil }
        guard
            let key = profile.tailscaleAuthKey?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !key.isEmpty
        else {
            throw SHCLIError.invalidProxy(profile.name)
        }
        let executable = try helperURL()
        let stateDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("ShellHarbor/Tailscale", isDirectory: true)
        .appendingPathComponent(profile.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = [
            "--hostname", profile.resolvedTailscaleHostname,
            "--state-dir", stateDirectory.path,
            "--listen-start", "15040",
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
            "--login-server", profile.tailscaleLoginServer ?? ""
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data("\(key)\n".utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.availableData
        guard
            let ready = try? JSONDecoder().decode(Ready.self, from: data),
            ready.type == "ready",
            ready.host == "127.0.0.1",
            (15_040...65_535).contains(ready.port)
        else {
            let detail = String(
                decoding: errors.fileHandleForReading.availableData,
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if process.isRunning { process.terminate() }
            throw SHCLIError.tailscaleStartupFailed(
                detail.isEmpty ? "helper 未返回就绪状态" : detail
            )
        }
        return SHTailscaleProxyProcess(
            process: process,
            port: ready.port,
            controlPort: ready.controlPort
        )
    }

    public func prepareMoshRelay(target: String) throws -> String {
        struct Request: Encodable { let target: String }
        struct Response: Decodable { let start: Int; let end: Int }
        let url = URL(string: "http://127.0.0.1:\(controlPort)/udp-relay")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(target: target))
        let semaphore = DispatchSemaphore(value: 0)
        let result = SHRelayResultBox()
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result.set(.failure(error))
                return
            }
            guard
                (response as? HTTPURLResponse)?.statusCode == 200,
                let data,
                let relay = try? JSONDecoder().decode(Response.self, from: data)
            else {
                result.set(.failure(
                    SHCLIError.tailscaleStartupFailed("无法创建 Mosh UDP relay")
                ))
                return
            }
            result.set(.success("\(relay.start):\(relay.end)"))
        }.resume()
        semaphore.wait()
        return try result.get()!.get()
    }

    public func configureMoshClient(target: String) throws -> String {
        guard
            let executable = Bundle.main.executableURL
        else { throw SHCLIError.tailscaleHelperUnavailable }
        let client = executable.resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("tailscale-proxy-helper")
        guard FileManager.default.isExecutableFile(atPath: client.path) else {
            throw SHCLIError.tailscaleHelperUnavailable
        }
        setenv(
            "SHELLHARBOR_TAILSCALE_CONTROL_PORT",
            String(controlPort),
            1
        )
        setenv("SHELLHARBOR_TAILSCALE_TARGET", target, 1)
        setenv("SHELLHARBOR_HELPER_MODE", "mosh-client", 1)
        return client.path
    }

    private static func helperURL() throws -> URL {
        let fileManager = FileManager.default
        if let executable = Bundle.main.executableURL {
            let sibling = executable.resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .appendingPathComponent("tailscale-proxy-helper")
            if fileManager.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
        }
        let development = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(".build/tailscale-proxy-helper")
        guard fileManager.isExecutableFile(atPath: development.path) else {
            throw SHCLIError.tailscaleHelperUnavailable
        }
        return development
    }
}

public struct SHRemoteProfile: Decodable, Identifiable {
    public let id: UUID
    public let name: String
    public let host: String?
    public let port: Int?
    public let username: String?
    public let authentication: String?
    public var password: String?
    public var tailscaleAuthKey: String?
    public let privateKeyPath: String?
    public let hostKeyPolicy: String?
    public let keepAliveSeconds: Int?
    public let remoteGroup: String?
    public let jumpRemoteID: UUID?
    public let sshJumpMode: String?
    public let savedProxyID: UUID?
    public let proxyType: String?
    public let proxyHost: String?
    public var proxyPort: Int?
    public let tailscaleLoginServer: String?
    public let tailscaleHostname: String?
    public let terminalConnectionMethod: String?
    public let moshCommand: String?
    public let moshServerCommand: String?

    public var resolvedHost: String {
        let value = (host ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if value.isEmpty || value.caseInsensitiveCompare("localhost") == .orderedSame {
            return "127.0.0.1"
        }
        return value
    }

    public var resolvedPort: Int { port ?? 22 }

    public var resolvedUsername: String {
        (username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var resolvedAuthentication: String {
        authentication ?? "agent"
    }

    public var resolvedGroup: String {
        let value = (remoteGroup ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return value.isEmpty ? "未分组" : value
    }

    public var endpoint: String {
        "\(resolvedUsername)@\(resolvedHost):\(resolvedPort)"
    }

    public var isConnectable: Bool {
        !resolvedUsername.isEmpty && (1...65_535).contains(resolvedPort)
    }

    public var usesPassword: Bool {
        resolvedAuthentication == "password"
    }

    public var usesTailscaleProxy: Bool {
        proxyType == "tailscale"
    }

    public var prefersMosh: Bool {
        terminalConnectionMethod == "mosh"
    }

    public var resolvedTailscaleHostname: String {
        let value = (tailscaleHostname ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return value.isEmpty
            ? "shellharbor-\(id.uuidString.lowercased().prefix(8))"
            : value
    }
}

public enum SHRemoteStore {
    public static var defaultConfigurationURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("ShellHarbor", isDirectory: true)
        .appendingPathComponent("sessions.json")
    }

    public static func load(
        from url: URL = defaultConfigurationURL
    ) throws -> [SHRemoteProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SHCLIError.configurationMissing(url.path)
        }
        do {
            return try JSONDecoder().decode(
                [SHRemoteProfile].self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw SHCLIError.invalidConfiguration
        }
    }

    public static func resolve(
        _ selector: String,
        in profiles: [SHRemoteProfile]
    ) throws -> SHRemoteProfile {
        let normalized = selector.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if let index = Int(normalized), (1...profiles.count).contains(index) {
            return profiles[index - 1]
        }
        let folded = normalized.lowercased()
        let matches = profiles.filter { profile in
            profile.id.uuidString.lowercased() == folded ||
                profile.id.uuidString.lowercased().hasPrefix(folded) ||
                profile.name.caseInsensitiveCompare(normalized) == .orderedSame
        }
        guard !matches.isEmpty else {
            throw SHCLIError.remoteNotFound(selector)
        }
        guard matches.count == 1 else {
            throw SHCLIError.ambiguousRemote(
                selector,
                matches.map { "\($0.name) [\($0.id.uuidString.prefix(8))]" }
            )
        }
        return matches[0]
    }

    public static func decrypted(
        _ profile: SHRemoteProfile
    ) throws -> SHRemoteProfile {
        var result = profile
        if profile.usesPassword {
            guard let storedPassword = profile.password,
                !storedPassword.isEmpty else {
                throw SHCLIError.passwordUnavailable(profile.name)
            }
            if SHPasswordCipher.isEncrypted(storedPassword) {
                do {
                    result.password = try SHPasswordCipher.decrypt(storedPassword)
                } catch {
                    throw SHCLIError.passwordUnavailable(profile.name)
                }
            }
        }
        if profile.usesTailscaleProxy,
            let storedKey = profile.tailscaleAuthKey,
            SHPasswordCipher.isEncrypted(storedKey) {
            do {
                result.tailscaleAuthKey = try SHPasswordCipher.decrypt(storedKey)
            } catch {
                throw SHCLIError.passwordUnavailable(profile.name)
            }
        }
        return result
    }
}

public enum SHPasswordCipher {
    static let prefix = "rsa:v1:"
    private static let algorithm: SecKeyAlgorithm = .rsaEncryptionOAEPSHA256

    private struct Envelope: Decodable {
        let encryptedKey: Data
        let sealedPassword: Data
    }

    public static func isEncrypted(_ value: String) -> Bool {
        value.hasPrefix(prefix)
    }

    public static func decrypt(_ ciphertext: String) throws -> String {
        let keyURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("ShellHarbor", isDirectory: true)
        .appendingPathComponent("password-rsa-private.der")
        guard let keyData = try? Data(contentsOf: keyURL) else {
            throw SHCLIError.privateKeyUnavailable
        }
        return try decrypt(ciphertext, privateKeyData: keyData)
    }

    public static func decrypt(
        _ ciphertext: String,
        privateKeyData keyData: Data
    ) throws -> String {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2_048
        ]
        guard
            let privateKey = SecKeyCreateWithData(
                keyData as CFData,
                attributes as CFDictionary,
                nil
            ),
            let encoded = Data(
                base64Encoded: String(ciphertext.dropFirst(prefix.count))
            ),
            let envelope = try? JSONDecoder().decode(
                Envelope.self,
                from: encoded
            )
        else {
            throw SHCLIError.privateKeyUnavailable
        }
        var error: Unmanaged<CFError>?
        guard let rawKey = SecKeyCreateDecryptedData(
            privateKey,
            algorithm,
            envelope.encryptedKey as CFData,
            &error
        ) as Data? else {
            throw SHCLIError.privateKeyUnavailable
        }
        let box = try AES.GCM.SealedBox(combined: envelope.sealedPassword)
        let plaintext = try AES.GCM.open(
            box,
            using: SymmetricKey(data: rawKey)
        )
        guard let value = String(data: plaintext, encoding: .utf8) else {
            throw SHCLIError.privateKeyUnavailable
        }
        return value
    }
}

public final class SHPasswordPipe {
    public let readDescriptor: Int32

    public init(password: String) throws {
        var descriptors: [Int32] = [0, 0]
        guard Darwin.pipe(&descriptors) == 0 else {
            throw SHCLIError.pipeFailure(errno)
        }
        readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        _ = fcntl(readDescriptor, F_SETFD, 0)

        let bytes = Array((password + "\n").utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    writeDescriptor,
                    buffer.baseAddress!.advanced(by: written),
                    bytes.count - written
                )
            }
            guard count > 0 else {
                Darwin.close(writeDescriptor)
                Darwin.close(readDescriptor)
                throw SHCLIError.pipeFailure(errno)
            }
            written += count
        }
        Darwin.close(writeDescriptor)
    }

    deinit {
        Darwin.close(readDescriptor)
    }
}

public struct SHSSHInvocation {
    public let executablePath: String
    public let arguments: [String]

    public init(executablePath: String, arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }
}

public struct SHSCPTransfer: Equatable {
    public enum Direction: Equatable {
        case upload
        case download
    }

    public let localPaths: [String]
    public let remotePath: String
    public let direction: Direction

    public var localPath: String {
        localPaths.first ?? ""
    }

    public init(localPath: String, remotePath: String, direction: Direction) {
        self.localPaths = [localPath]
        self.remotePath = remotePath
        self.direction = direction
    }

    public init(
        localPaths: [String],
        remotePath: String,
        direction: Direction
    ) {
        self.localPaths = localPaths
        self.remotePath = remotePath
        self.direction = direction
    }

    public static func containsGlob(_ path: String) -> Bool {
        path.contains("*") || path.contains("?") || path.contains("[")
    }

    public static func expandedLocalPaths(
        for patterns: [String],
        fileManager: FileManager = .default
    ) -> [String]? {
        var paths: [String] = []
        for pattern in patterns {
            let expanded = NSString(string: pattern).expandingTildeInPath
            if fileManager.fileExists(atPath: expanded) {
                paths.append(expanded)
                continue
            }
            guard containsGlob(expanded) else { return nil }
            var result = glob_t()
            defer { globfree(&result) }
            guard Darwin.glob(expanded, 0, nil, &result) == 0 else {
                return nil
            }
            for index in 0..<Int(result.gl_pathc) {
                guard let value = result.gl_pathv[index] else { continue }
                paths.append(String(cString: value))
            }
        }
        return paths.isEmpty ? nil : paths
    }

    public static func bothEndpointsExistLocally(
        from source: String,
        to destination: String,
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(
            atPath: NSString(string: source).expandingTildeInPath
        ) && fileManager.fileExists(
            atPath: NSString(string: destination).expandingTildeInPath
        )
    }

    public static func make(
        from source: String,
        to destination: String,
        direction: Direction
    ) -> SHSCPTransfer {
        switch direction {
        case .upload:
            SHSCPTransfer(
                localPath: NSString(string: source).expandingTildeInPath,
                remotePath: destination,
                direction: .upload
            )
        case .download:
            SHSCPTransfer(
                localPath: collisionFreeDownloadPath(
                    remotePath: source,
                    requestedLocalPath: destination
                ),
                remotePath: source,
                direction: .download
            )
        }
    }

    public static func detect(
        from source: String,
        to destination: String?,
        fileManager: FileManager = .default,
        currentDirectory: String? = nil
    ) -> SHSCPTransfer {
        guard let destination else {
            let directory = currentDirectory ?? fileManager.currentDirectoryPath
            if containsGlob(source) {
                return SHSCPTransfer(
                    localPath: directory,
                    remotePath: source,
                    direction: .download
                )
            }
            let remoteName = NSString(
                string: source.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ).lastPathComponent
            let localName = uniqueLocalName(
                remoteName.isEmpty ? "download" : remoteName,
                in: directory,
                fileManager: fileManager
            )
            return SHSCPTransfer(
                localPath: (directory as NSString)
                    .appendingPathComponent(localName),
                remotePath: source,
                direction: .download
            )
        }
        let expandedSource = NSString(string: source).expandingTildeInPath
        if fileManager.fileExists(atPath: expandedSource) {
            return SHSCPTransfer(
                localPath: expandedSource,
                remotePath: destination,
                direction: .upload
            )
        }
        return SHSCPTransfer(
            localPath: collisionFreeDownloadPath(
                remotePath: source,
                requestedLocalPath: destination,
                fileManager: fileManager
            ),
            remotePath: source,
            direction: .download
        )
    }

    private static func collisionFreeDownloadPath(
        remotePath: String,
        requestedLocalPath: String,
        fileManager: FileManager = .default
    ) -> String {
        let expanded = NSString(string: requestedLocalPath).expandingTildeInPath
        if containsGlob(remotePath) {
            return expanded
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            return expanded
        }
        if isDirectory.boolValue {
            let remoteName = (remotePath as NSString).lastPathComponent
            let name = uniqueLocalName(
                remoteName.isEmpty ? "download" : remoteName,
                in: expanded,
                fileManager: fileManager
            )
            return (expanded as NSString).appendingPathComponent(name)
        }
        let parent = (expanded as NSString).deletingLastPathComponent
        let name = uniqueLocalName(
            (expanded as NSString).lastPathComponent,
            in: parent,
            fileManager: fileManager
        )
        return (parent as NSString).appendingPathComponent(name)
    }

    private static func uniqueLocalName(
        _ name: String,
        in directory: String,
        fileManager: FileManager
    ) -> String {
        let original = name as NSString
        let fileExtension = original.pathExtension
        let stem = fileExtension.isEmpty
            ? name
            : original.deletingPathExtension
        var candidate = name
        var suffix = 1
        while fileManager.fileExists(
            atPath: (directory as NSString).appendingPathComponent(candidate)
        ) {
            candidate = fileExtension.isEmpty
                ? "\(stem) (\(suffix))"
                : "\(stem) (\(suffix)).\(fileExtension)"
            suffix += 1
        }
        return candidate
    }
}

public enum SHSSHCommandBuilder {
    public static func sshpassPath(
        fileManager: FileManager = .default
    ) -> String? {
        [
            "/opt/homebrew/bin/sshpass",
            "/usr/local/bin/sshpass",
            "/opt/local/bin/sshpass"
        ].first(where: fileManager.isExecutableFile(atPath:))
    }

    public static func build(
        profile: SHRemoteProfile,
        jumpProfile: SHRemoteProfile?,
        targetPasswordDescriptor: Int32?,
        jumpPasswordDescriptor: Int32?,
        remoteCommand: [String] = []
    ) throws -> SHSSHInvocation {
        guard profile.isConnectable else {
            throw SHCLIError.invalidRemote(profile.name)
        }
        var arguments = commonArguments(for: profile)
        arguments += try routeArguments(
            profile: profile,
            jumpProfile: jumpProfile,
            jumpPasswordDescriptor: jumpPasswordDescriptor
        )
        arguments.append("\(profile.resolvedUsername)@\(profile.resolvedHost)")
        if remoteCommand.isEmpty {
            arguments.insert("-tt", at: arguments.count - 1)
            arguments.append(Self.interactiveLoginCommand)
        } else {
            arguments += remoteCommand
        }

        guard profile.usesPassword else {
            return SHSSHInvocation(
                executablePath: "/usr/bin/ssh",
                arguments: arguments
            )
        }
        guard
            let targetPasswordDescriptor,
            let sshpass = sshpassPath()
        else {
            throw SHCLIError.sshpassUnavailable
        }
        return SHSSHInvocation(
            executablePath: sshpass,
            arguments: [
                "-d", String(targetPasswordDescriptor),
                "/usr/bin/ssh"
            ] + arguments
        )
    }

    public static func buildMosh(
        profile: SHRemoteProfile,
        jumpProfile: SHRemoteProfile?,
        targetPasswordDescriptor: Int32?,
        jumpPasswordDescriptor: Int32?,
        tailscaleClientPath: String?
    ) throws -> SHSSHInvocation {
        guard profile.isConnectable else {
            throw SHCLIError.invalidRemote(profile.name)
        }
        var sshArguments = commonArguments(for: profile)
        sshArguments += try routeArguments(
            profile: profile,
            jumpProfile: jumpProfile,
            jumpPasswordDescriptor: jumpPasswordDescriptor
        )
        var ssh = ["/usr/bin/ssh"] + sshArguments
        if profile.usesPassword {
            guard
                let targetPasswordDescriptor,
                let sshpass = sshpassPath()
            else { throw SHCLIError.sshpassUnavailable }
            ssh = [sshpass, "-d", String(targetPasswordDescriptor)] + ssh
        }
        let sshCommand = ssh.map(shellQuote).joined(separator: " ")
        let configuredMosh = (profile.moshCommand ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let mosh = configuredMosh.isEmpty ? "/opt/homebrew/bin/mosh" : configuredMosh
        var arguments = [
            "--experimental-remote-ip=remote",
            "--ssh=\(sshCommand)"
        ]
        if let tailscaleClientPath {
            arguments.append("--client=\(tailscaleClientPath)")
        }
        let configuredServer = (profile.moshServerCommand ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredServer.isEmpty {
            arguments.append("--server=\(configuredServer)")
        }
        arguments += ["--", "\(profile.resolvedUsername)@\(profile.resolvedHost)"]
        return SHSSHInvocation(executablePath: mosh, arguments: arguments)
    }

    public static func buildSCP(
        profile: SHRemoteProfile,
        jumpProfile: SHRemoteProfile?,
        transfer: SHSCPTransfer,
        targetPasswordDescriptor: Int32?,
        jumpPasswordDescriptor: Int32?
    ) throws -> SHSSHInvocation {
        guard profile.isConnectable else {
            throw SHCLIError.invalidRemote(profile.name)
        }
        var arguments = ["-P", String(profile.resolvedPort)]
        arguments += hostKeyArguments(for: profile)
        arguments += authenticationArguments(for: profile)
        arguments += try routeArguments(
            profile: profile,
            jumpProfile: jumpProfile,
            jumpPasswordDescriptor: jumpPasswordDescriptor
        )
        let keepAlive = profile.keepAliveSeconds ?? 30
        if keepAlive > 0 {
            arguments += ["-o", "ServerAliveInterval=\(keepAlive)"]
        }
        arguments.append("-r")
        let remote = "\(profile.resolvedUsername)@\(profile.resolvedHost):\(transfer.remotePath)"
        switch transfer.direction {
        case .upload:
            arguments += transfer.localPaths + [remote]
        case .download:
            arguments += [remote, transfer.localPath]
        }

        guard profile.usesPassword else {
            return SHSSHInvocation(
                executablePath: "/usr/bin/scp",
                arguments: arguments
            )
        }
        guard
            let targetPasswordDescriptor,
            let sshpass = sshpassPath()
        else {
            throw SHCLIError.sshpassUnavailable
        }
        return SHSSHInvocation(
            executablePath: sshpass,
            arguments: [
                "-d", String(targetPasswordDescriptor),
                "/usr/bin/scp"
            ] + arguments
        )
    }

    /// Bash login shells do not normally source ~/.bashrc. shcli explicitly
    /// loads it for bash while retaining the account's configured shell.
    static let interactiveLoginCommand = """
    shell=${SHELL:-/bin/sh}; case ${shell##*/} in bash) [ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"; exec "$shell" -i ;; *) exec "$shell" -l ;; esac
    """

    private static func commonArguments(
        for profile: SHRemoteProfile
    ) -> [String] {
        var arguments = ["-p", String(profile.resolvedPort)]
        arguments += hostKeyArguments(for: profile)
        arguments += authenticationArguments(for: profile)
        let keepAlive = profile.keepAliveSeconds ?? 30
        if keepAlive > 0 {
            arguments += [
                "-o", "ServerAliveInterval=\(keepAlive)",
                "-o", "ServerAliveCountMax=3"
            ]
        }
        return arguments
    }

    private static func authenticationArguments(
        for profile: SHRemoteProfile
    ) -> [String] {
        if profile.usesPassword {
            return [
                "-o", "IdentitiesOnly=yes",
                "-o", "PubkeyAuthentication=no",
                "-o", "PasswordAuthentication=yes",
                "-o", "KbdInteractiveAuthentication=yes",
                "-o", "PreferredAuthentications=password,keyboard-interactive"
            ]
        }
        if
            profile.resolvedAuthentication == "privateKey",
            let keyPath = profile.privateKeyPath,
            !keyPath.isEmpty
        {
            return [
                "-i",
                NSString(string: keyPath).expandingTildeInPath
            ]
        }
        return []
    }

    private static func hostKeyArguments(
        for profile: SHRemoteProfile
    ) -> [String] {
        let configured = SHSSHConfigResolver.hostKeyPolicy(for: profile)?
            .lowercased()
        if let configured, configured != "ask" {
            if ["false", "no", "off"].contains(configured) {
                return [
                    "-o", "StrictHostKeyChecking=no",
                    "-o", "UserKnownHostsFile=/dev/null",
                    "-o", "LogLevel=ERROR"
                ]
            }
            return []
        }
        if profile.hostKeyPolicy == "strict" {
            return ["-o", "StrictHostKeyChecking=yes"]
        }
        if profile.hostKeyPolicy == "acceptNew" {
            return [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "LogLevel=ERROR"
            ]
        }
        return []
    }

    private static func routeArguments(
        profile: SHRemoteProfile,
        jumpProfile: SHRemoteProfile?,
        jumpPasswordDescriptor: Int32?
    ) throws -> [String] {
        guard let jumpProfile else {
            return try proxyArguments(for: profile)
        }
        guard jumpProfile.isConnectable else {
            throw SHCLIError.invalidRemote(jumpProfile.name)
        }
        if
            (profile.sshJumpMode ?? "sshJump") == "sshJump",
            !jumpProfile.usesPassword,
            (jumpProfile.proxyType ?? "none") == "none"
        {
            var destination = "\(jumpProfile.resolvedUsername)@\(jumpProfile.resolvedHost)"
            if jumpProfile.resolvedPort != 22 {
                destination += ":\(jumpProfile.resolvedPort)"
            }
            return ["-J", destination]
        }
        var jumpArguments = commonArguments(for: jumpProfile)
        jumpArguments += try proxyArguments(for: jumpProfile)
        jumpArguments += [
            "-o", "ExitOnForwardFailure=yes",
            "-W", "%h:%p",
            "\(jumpProfile.resolvedUsername)@\(jumpProfile.resolvedHost)"
        ]
        var command = ["/usr/bin/ssh"] + jumpArguments
        if jumpProfile.usesPassword {
            guard
                let jumpPasswordDescriptor,
                let sshpass = sshpassPath()
            else {
                throw SHCLIError.sshpassUnavailable
            }
            command = [
                sshpass,
                "-d", String(jumpPasswordDescriptor),
                "/usr/bin/ssh"
            ] + jumpArguments
        }
        let proxyCommand = command.map(shellQuote).joined(separator: " ")
        return ["-o", "ProxyCommand=\(proxyCommand)"]
    }

    private static func proxyArguments(
        for profile: SHRemoteProfile
    ) throws -> [String] {
        let type = profile.proxyType ?? "none"
        guard type != "none" else { return [] }
        let host = type == "tailscale"
            ? "127.0.0.1"
            : (profile.proxyHost ?? "").trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        let defaultPort = type == "socks5"
            ? 1_080
            : (type == "tailscale" ? 15_040 : 8_080)
        let port = profile.proxyPort ?? defaultPort
        guard
            !host.isEmpty,
            (1...65_535).contains(port),
            type == "socks5" || type == "httpConnect" || type == "tailscale"
        else {
            throw SHCLIError.invalidProxy(profile.name)
        }
        let endpoint = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        let protocolName = type == "socks5" || type == "tailscale"
            ? "5"
            : "connect"
        let command = [
            "/usr/bin/nc", "-x", endpoint,
            "-X", protocolName, "%h", "%p"
        ]
        return [
            "-o",
            "ProxyCommand=\(command.map(shellQuote).joined(separator: " "))"
        ]
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

private enum SHSSHConfigResolver {
    static func hostKeyPolicy(for profile: SHRemoteProfile) -> String? {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-G", "-p", String(profile.resolvedPort),
            "\(profile.resolvedUsername)@\(profile.resolvedHost)"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard
            process.terminationStatus == 0,
            let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
            .split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix("stricthostkeychecking ") })?
            .split(separator: " ", maxSplits: 1)
            .last
            .map(String.init)
    }
}

public enum SHProcessExecutor {
    public static func replaceCurrentProcess(
        with invocation: SHSSHInvocation
    ) throws -> Never {
        let values = [invocation.executablePath] + invocation.arguments
        var pointers: [UnsafeMutablePointer<CChar>?] = values.map {
            strdup($0)
        }
        pointers.append(nil)
        defer {
            for pointer in pointers.dropLast() {
                free(pointer)
            }
        }
        let result = invocation.executablePath.withCString { path in
            execv(path, &pointers)
        }
        throw SHCLIError.processFailure(
            invocation.executablePath,
            result == -1 ? errno : result
        )
    }
}
