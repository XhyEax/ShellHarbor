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
        case let .pipeFailure(code):
            "无法创建安全密码管道（errno \(code)）。"
        case let .processFailure(path, code):
            "无法启动 \(path)（errno \(code)）。"
        }
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
    public let privateKeyPath: String?
    public let hostKeyPolicy: String?
    public let keepAliveSeconds: Int?
    public let remoteGroup: String?
    public let jumpRemoteID: UUID?
    public let sshJumpMode: String?
    public let proxyType: String?
    public let proxyHost: String?
    public let proxyPort: Int?

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
        guard profile.usesPassword else { return profile }
        guard let storedPassword = profile.password, !storedPassword.isEmpty else {
            throw SHCLIError.passwordUnavailable(profile.name)
        }
        var result = profile
        if SHPasswordCipher.isEncrypted(storedPassword) {
            do {
                result.password = try SHPasswordCipher.decrypt(storedPassword)
            } catch {
                throw SHCLIError.passwordUnavailable(profile.name)
            }
        }
        return result
    }
}

private enum SHPasswordCipher {
    static let prefix = "rsa:v1:"
    private static let algorithm: SecKeyAlgorithm = .rsaEncryptionOAEPSHA256

    private struct Envelope: Decodable {
        let encryptedKey: Data
        let sealedPassword: Data
    }

    static func isEncrypted(_ value: String) -> Bool {
        value.hasPrefix(prefix)
    }

    static func decrypt(_ ciphertext: String) throws -> String {
        let keyURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("ShellHarbor", isDirectory: true)
        .appendingPathComponent("password-rsa-private.der")
        guard let keyData = try? Data(contentsOf: keyURL) else {
            throw SHCLIError.privateKeyUnavailable
        }
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
        jumpPasswordDescriptor: Int32?
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
        arguments.append("-tt")
        arguments.append("\(profile.resolvedUsername)@\(profile.resolvedHost)")
        arguments.append(Self.interactiveLoginCommand)

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
        let keepAlive = profile.keepAliveSeconds ?? 30
        if keepAlive > 0 {
            arguments += [
                "-o", "ServerAliveInterval=\(keepAlive)",
                "-o", "ServerAliveCountMax=3"
            ]
        }
        if
            profile.resolvedAuthentication == "privateKey",
            let keyPath = profile.privateKeyPath,
            !keyPath.isEmpty
        {
            arguments += [
                "-i",
                NSString(string: keyPath).expandingTildeInPath
            ]
        }
        return arguments
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
        let host = (profile.proxyHost ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let defaultPort = type == "socks5" ? 1_080 : 8_080
        let port = profile.proxyPort ?? defaultPort
        guard
            !host.isEmpty,
            (1...65_535).contains(port),
            type == "socks5" || type == "httpConnect"
        else {
            throw SHCLIError.invalidProxy(profile.name)
        }
        let endpoint = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        let protocolName = type == "socks5" ? "5" : "connect"
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
