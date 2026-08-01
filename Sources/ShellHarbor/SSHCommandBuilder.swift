import Foundation

struct SSHInvocation {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let displayCommand: String
    var currentDirectory: String? = nil
}

enum SSHHostKeyPolicyArguments {
    static func resolve(
        appPolicy: HostKeyPolicy,
        effectiveSSHConfigPolicy: String?
    ) -> [String] {
        if
            let configured = effectiveSSHConfigPolicy?.lowercased(),
            SSHConfigResolver.shouldPreferSSHConfig(
                configuredValue: configured,
                defaultValue: "ask"
            )
        {
            if ["false", "no", "off"].contains(configured) {
                return [
                    "-o", "StrictHostKeyChecking=no",
                    "-o", "UserKnownHostsFile=/dev/null",
                    "-o", "LogLevel=ERROR"
                ]
            }
            return []
        }

        switch appPolicy {
        case .ask, .acceptNew:
            return [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "LogLevel=ERROR"
            ]
        case .strict:
            return ["-o", "StrictHostKeyChecking=yes"]
        }
    }
}

enum CommandOutputSummary {
    static let maximumLines = 16
    static let maximumCharacters = 3_000

    static func text(_ output: String) -> String {
        let lines = output.components(separatedBy: .newlines)
        let visibleLines: ArraySlice<String>
        let omittedLineCount: Int
        if lines.count > maximumLines {
            visibleLines = lines.suffix(maximumLines)
            omittedLineCount = lines.count - maximumLines
        } else {
            visibleLines = lines[...]
            omittedLineCount = 0
        }
        var result = visibleLines.joined(separator: "\n")
        if result.count > maximumCharacters {
            result = "…" + result.suffix(maximumCharacters)
        }
        if omittedLineCount > 0 {
            result = "…已省略 \(omittedLineCount) 行\n" + result
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SSHCommandBuilder {
    static func sshpassPath(fileManager: FileManager = .default) -> String? {
        let candidates = [
            "/opt/homebrew/bin/sshpass",
            "/usr/local/bin/sshpass",
            "/opt/local/bin/sshpass"
        ]
        return candidates.first(where: fileManager.isExecutableFile(atPath:))
    }

    static func ssh(
        profile: SessionProfile,
        jumpProfile: SessionProfile? = nil,
        command: String? = nil,
        forceTTY: Bool = false,
        connectionTimeoutSeconds: Int? = nil,
        batchMode: Bool = false
    ) throws -> SSHInvocation {
        var sshArguments = commonArguments(for: profile)
        sshArguments += try routeArguments(
            profile: profile,
            jumpProfile: jumpProfile
        )
        if let connectionTimeoutSeconds {
            sshArguments += [
                "-o", "ConnectTimeout=\(max(1, connectionTimeoutSeconds))",
                "-o", "ConnectionAttempts=1"
            ]
        }
        if batchMode, profile.authentication != .password {
            sshArguments += ["-o", "BatchMode=yes"]
        }
        if forceTTY {
            sshArguments.append("-tt")
        }
        sshArguments.append("\(profile.username)@\(profile.resolvedHost)")
        if let command, !command.isEmpty {
            sshArguments.append(command)
        }
        return try wrapIfNeeded(
            tool: "/usr/bin/ssh",
            arguments: sshArguments,
            profile: profile,
            jumpProfile: jumpProfile
        )
    }

    static func localShell(
        _ shell: LocalShell,
        startingDirectory: String? = nil
    ) -> SSHInvocation {
        let executable = shell.resolvedPath
        var environment = ProcessInfo.processInfo.environment
        environment["SHELL"] = executable
        let requestedDirectory = startingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let directory: String
        if
            let requestedDirectory,
            !requestedDirectory.isEmpty
        {
            directory = NSString(
                string: requestedDirectory
            ).expandingTildeInPath
        } else {
            directory =
                FileManager.default.homeDirectoryForCurrentUser.path
        }
        let usableDirectory =
            FileManager.default.fileExists(atPath: directory)
                ? directory
                : FileManager.default.homeDirectoryForCurrentUser.path
        return SSHInvocation(
            executableURL: URL(fileURLWithPath: executable),
            arguments: ["-l"],
            environment: environment,
            displayCommand: "\(shell.shellName) -l",
            currentDirectory: usableDirectory
        )
    }

    static func mosh(
        profile: SessionProfile,
        jumpProfile: SessionProfile? = nil,
        startingDirectory: String? = nil
    ) throws -> SSHInvocation {
        if
            profile.resolvedMoshJumpMode == .moshOnJump,
            let jumpProfile
        {
            return try jumpMosh(
                profile: profile,
                jumpProfile: jumpProfile,
                startingDirectory: startingDirectory
            )
        }

        var environment = ProcessInfo.processInfo.environment
        augmentCommandPath(in: &environment)

        let sshCommand = try moshBootstrapCommand(
            profile: profile,
            jumpProfile: jumpProfile,
            environment: &environment
        )

        let sshBootstrap = sshCommand
            .map(shellQuote)
            .joined(separator: " ")
        var moshArguments: [String] = []
        if
            jumpProfile != nil ||
            profile.isProxyEnabled
        {
            // With ProxyCommand, Mosh cannot reliably infer the UDP endpoint
            // from its local SSH command. Ask the remote side to report the
            // address seen by SSH. This discovers an address; it does not
            // tunnel UDP through the proxy or jump host.
            moshArguments.append(
                "--experimental-remote-ip=remote"
            )
        }
        moshArguments.append("--ssh=\(sshBootstrap)")
        let serverCommand = profile.resolvedMoshServerCommand
        if !serverCommand.isEmpty {
            moshArguments.append("--server=\(serverCommand)")
        }
        moshArguments += [
            "--",
            "\(profile.username)@\(profile.resolvedHost)"
        ]
        let restoredDirectory = startingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if
            let restoredDirectory,
            !restoredDirectory.isEmpty,
            restoredDirectory != "~",
            let shellCommand = interactiveShellCommand(
                startingDirectory: restoredDirectory
            )
        {
            moshArguments += ["/bin/sh", "-lc", shellCommand]
        }

        let configuredCommand = profile.resolvedMoshCommand
        let commandLine = (
            [shellQuote(configuredCommand)] +
            moshArguments.map(shellQuote)
        ).joined(separator: " ")
        return SSHInvocation(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lc", commandLine],
            environment: environment,
            displayCommand: commandLine
        )
    }

    private static func jumpMosh(
        profile: SessionProfile,
        jumpProfile: SessionProfile,
        startingDirectory: String?
    ) throws -> SSHInvocation {
        let targetSSH = jumpSideTargetSSHArguments(
            profile: profile
        )
        let sshBootstrap = targetSSH
            .map(shellQuote)
            .joined(separator: " ")
        var moshArguments = [
            "--experimental-remote-ip=remote",
            "--ssh=\(sshBootstrap)"
        ]
        if !profile.resolvedMoshServerCommand.isEmpty {
            moshArguments.append(
                "--server=\(profile.resolvedMoshServerCommand)"
            )
        }
        moshArguments += [
            "--",
            "\(profile.username)@\(profile.resolvedHost)"
        ]

        let restoredDirectory = startingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if
            let restoredDirectory,
            !restoredDirectory.isEmpty,
            restoredDirectory != "~",
            let shellCommand = interactiveShellCommand(
                startingDirectory: restoredDirectory
            )
        {
            moshArguments += ["/bin/sh", "-lc", shellCommand]
        }

        let remoteCommand = (
            [shellQuote(profile.resolvedJumpMoshCommand)] +
            moshArguments.map(shellQuote)
        ).joined(separator: " ")
        return try ssh(
            profile: jumpProfile,
            command: remoteCommand,
            forceTTY: true
        )
    }

    private static func moshBootstrapCommand(
        profile: SessionProfile,
        jumpProfile: SessionProfile?,
        environment: inout [String: String]
    ) throws -> [String] {
        var sshArguments = commonArguments(for: profile)
        sshArguments += try routeArguments(
            profile: profile,
            jumpProfile: jumpProfile
        )
        var sshCommand = ["/usr/bin/ssh"] + sshArguments

        if jumpProfile?.authentication == .password {
            try configurePasswordAskpass(
                environment: &environment,
                profile: profile,
                jumpProfile: jumpProfile
            )
        } else if profile.authentication == .password {
            guard let sshpass = sshpassPath() else {
                throw SSHServiceError.sshpassUnavailable
            }
            environment["SSHPASS"] = profile.password
            sshCommand = [sshpass, "-e"] + sshCommand
        }
        return sshCommand
    }

    private static func jumpSideTargetSSHArguments(
        profile: SessionProfile
    ) -> [String] {
        var arguments = [
            "ssh",
            "-p", String(profile.port)
        ]
        switch profile.hostKeyPolicy {
        case .ask:
            arguments += [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "LogLevel=ERROR"
            ]
        case .acceptNew:
            arguments += [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "LogLevel=ERROR"
            ]
        case .strict:
            arguments += [
                "-o", "StrictHostKeyChecking=yes"
            ]
        }
        if profile.keepAliveSeconds > 0 {
            arguments += [
                "-o",
                "ServerAliveInterval=\(profile.keepAliveSeconds)",
                "-o",
                "ServerAliveCountMax=3"
            ]
        }
        arguments.append(
            "\(profile.username)@\(profile.resolvedHost)"
        )
        return arguments
    }

    static func scp(
        profile: SessionProfile,
        jumpProfile: SessionProfile? = nil,
        localPath: String,
        remotePath: String,
        direction: TransferDirection,
        recursive: Bool
    ) throws -> SSHInvocation {
        var arguments = ["-P", String(profile.port)]
        arguments += hostKeyArguments(for: profile)
        arguments += try routeArguments(
            profile: profile,
            jumpProfile: jumpProfile
        )
        if profile.keepAliveSeconds > 0 {
            arguments += ["-o", "ServerAliveInterval=\(profile.keepAliveSeconds)"]
        }
        if profile.authentication == .privateKey, !profile.privateKeyPath.isEmpty {
            arguments += ["-i", profile.privateKeyPath]
        }
        if recursive {
            arguments.append("-r")
        }

        // Process receives each argument directly, so no local shell escaping is
        // needed. Modern OpenSSH scp uses SFTP and accepts the remote path verbatim.
        let remote =
            "\(profile.username)@\(profile.resolvedHost):\(remotePath)"
        switch direction {
        case .upload:
            arguments += [localPath, remote]
        case .download:
            arguments += [remote, localPath]
        }
        return try wrapIfNeeded(
            tool: "/usr/bin/scp",
            arguments: arguments,
            profile: profile,
            jumpProfile: jumpProfile
        )
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func interactiveShellCommand(
        startingDirectory: String?
    ) -> String? {
        guard
            let startingDirectory,
            !startingDirectory.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        else {
            return nil
        }
        let directory: String
        if startingDirectory == "~" {
            directory = "\"$HOME\""
        } else if startingDirectory.hasPrefix("~/") {
            directory = "\"$HOME\"/" + shellQuote(
                String(startingDirectory.dropFirst(2))
            )
        } else {
            directory = shellQuote(startingDirectory)
        }
        return """
        stty opost onlcr 2>/dev/null || true
        cd -- \(directory) 2>/dev/null || cd -- "$HOME"
        exec "${SHELL:-$0}" -l
        """
    }

    private static func commonArguments(for profile: SessionProfile) -> [String] {
        var arguments = ["-p", String(profile.port)]
        arguments += hostKeyArguments(for: profile)
        if profile.keepAliveSeconds > 0 {
            arguments += [
                "-o", "ServerAliveInterval=\(profile.keepAliveSeconds)",
                "-o", "ServerAliveCountMax=3"
            ]
        }
        if profile.authentication == .privateKey, !profile.privateKeyPath.isEmpty {
            arguments += ["-i", profile.privateKeyPath]
        }
        return arguments
    }

    private static func hostKeyArguments(
        for profile: SessionProfile
    ) -> [String] {
        // OpenSSH still disables password authentication for a changed key
        // when StrictHostKeyChecking=no unless known_hosts is isolated.
        // Treat an explicit "no" in ~/.ssh/config as the user's request to
        // bypass host-key persistence completely, without modifying their
        // known_hosts file.
        SSHHostKeyPolicyArguments.resolve(
            appPolicy: profile.hostKeyPolicy,
            effectiveSSHConfigPolicy:
                SSHConfigResolver.hostKeyPolicy(for: profile)
        )
    }

    private static func routeArguments(
        profile: SessionProfile,
        jumpProfile: SessionProfile?
    ) throws -> [String] {
        guard let jumpProfile else {
            return try networkProxyArguments(for: profile)
        }
        guard
            !jumpProfile.isLocalConnection,
            jumpProfile.isConnectable
        else {
            throw SSHServiceError.invalidJumpProfile
        }

        var arguments = commonArguments(for: jumpProfile)
        arguments += try networkProxyArguments(for: jumpProfile)
        arguments += ["-o", "ExitOnForwardFailure=yes"]
        arguments += ["-W", "%h:%p"]
        arguments.append(
            "\(jumpProfile.username)@\(jumpProfile.resolvedHost)"
        )

        var command = ["/usr/bin/ssh"] + arguments
        if jumpProfile.authentication == .password {
            command = [
                "/usr/bin/env",
                "SHELLHARBOR_PASSWORD_ROLE=jump"
            ] + command
        }
        let proxyCommand = command
            .map(shellQuote)
            .joined(separator: " ")
        return ["-o", "ProxyCommand=\(proxyCommand)"]
    }

    private static func networkProxyArguments(
        for profile: SessionProfile
    ) throws -> [String] {
        guard profile.isProxyEnabled else { return [] }
        guard
            profile.isProxyConfigurationValid,
            let proxyProtocol = profile.resolvedProxyType.ncProtocol
        else {
            throw SSHServiceError.invalidProxy
        }

        let host = profile.resolvedProxyHost
        let endpoint = host.contains(":")
            ? "[\(host)]:\(profile.resolvedProxyPort)"
            : "\(host):\(profile.resolvedProxyPort)"
        let command = [
            "/usr/bin/nc",
            "-x", endpoint,
            "-X", proxyProtocol,
            "%h", "%p"
        ]
        let proxyCommand = command
            .map(shellQuote)
            .joined(separator: " ")
        return ["-o", "ProxyCommand=\(proxyCommand)"]
    }

    private static func wrapIfNeeded(
        tool: String,
        arguments: [String],
        profile: SessionProfile,
        jumpProfile: SessionProfile?
    ) throws -> SSHInvocation {
        var environment = ProcessInfo.processInfo.environment
        let visible = ([tool] + arguments).map(shellQuote).joined(separator: " ")
        let jumpUsesPassword =
            jumpProfile?.authentication == .password

        if jumpUsesPassword {
            try configurePasswordAskpass(
                environment: &environment,
                profile: profile,
                jumpProfile: jumpProfile
            )
            return SSHInvocation(
                executableURL: URL(fileURLWithPath: tool),
                arguments: arguments,
                environment: environment,
                displayCommand: visible
            )
        }

        guard profile.authentication == .password else {
            return SSHInvocation(
                executableURL: URL(fileURLWithPath: tool),
                arguments: arguments,
                environment: environment,
                displayCommand: visible
            )
        }

        guard let sshpass = sshpassPath() else {
            throw SSHServiceError.sshpassUnavailable
        }
        environment["SSHPASS"] = profile.password
        return SSHInvocation(
            executableURL: URL(fileURLWithPath: sshpass),
            arguments: ["-e", tool] + arguments,
            environment: environment,
            displayCommand: "SSHPASS=•••• \(shellQuote(sshpass)) -e \(visible)"
        )
    }

    private static func configurePasswordAskpass(
        environment: inout [String: String],
        profile: SessionProfile,
        jumpProfile: SessionProfile?
    ) throws {
        guard let askpass = try passwordAskpassPath() else {
            throw SSHServiceError.askpassUnavailable
        }
        environment["SSH_ASKPASS"] = askpass
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] =
            environment["DISPLAY"] ?? "ShellHarbor"
        environment["SHELLHARBOR_PASSWORD_ROLE"] = "target"
        environment["SHELLHARBOR_TARGET_PASSWORD"] =
            profile.authentication == .password
                ? profile.password
                : ""
        environment["SHELLHARBOR_JUMP_PASSWORD"] =
            jumpProfile?.password ?? ""
    }

    private static func augmentCommandPath(
        in environment: inout [String: String]
    ) {
        let preferred = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existing = environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        environment["PATH"] = (preferred + existing)
            .reduce(into: [String]()) { result, path in
                if !result.contains(path) {
                    result.append(path)
                }
            }
            .joined(separator: ":")
        if environment["LANG"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }
        if environment["LC_CTYPE"] == nil {
            environment["LC_CTYPE"] = "en_US.UTF-8"
        }
    }

    private static func passwordAskpassPath() throws -> String? {
        let fileManager = FileManager.default
        let directory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(
            "ShellHarbor",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(
            "ssh-askpass",
            isDirectory: false
        )
        let script = """
        #!/bin/sh
        if [ "$SHELLHARBOR_PASSWORD_ROLE" = "jump" ]; then
          printf '%s\\n' "$SHELLHARBOR_JUMP_PASSWORD"
        else
          printf '%s\\n' "$SHELLHARBOR_TARGET_PASSWORD"
        fi
        """
        let data = Data(script.utf8)
        if
            (try? Data(contentsOf: url)) != data
        {
            try data.write(to: url, options: .atomic)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        return fileManager.isExecutableFile(atPath: url.path)
            ? url.path
            : nil
    }
}

enum SSHConfigResolver {
    private struct CacheKey: Hashable {
        let host: String
        let port: Int
        let username: String
        let configModificationTime: TimeInterval
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var values: [CacheKey: String] = [:]
    }

    private static let cache = Cache()

    static func hasExplicitHostKeyPolicy(
        for profile: SessionProfile
    ) -> Bool {
        shouldPreferSSHConfig(
            configuredValue: hostKeyPolicy(for: profile),
            defaultValue: "ask"
        )
    }

    static func hostKeyPolicy(
        for profile: SessionProfile
    ) -> String? {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: configURL.path
            )
        else {
            return nil
        }
        let modificationTime = (
            attributes[.modificationDate] as? Date
        )?.timeIntervalSince1970 ?? 0
        let key = CacheKey(
            host: profile.resolvedHost,
            port: profile.port,
            username: profile.username,
            configModificationTime: modificationTime
        )

        cache.lock.lock()
        if let cached = cache.values[key] {
            cache.lock.unlock()
            return cached
        }
        cache.lock.unlock()

        guard let configured = effectiveHostKeyPolicy(profile: profile) else {
            return nil
        }

        cache.lock.lock()
        cache.values[key] = configured
        cache.lock.unlock()
        return configured
    }

    static func shouldPreferSSHConfig(
        configuredValue: String?,
        defaultValue: String?
    ) -> Bool {
        guard
            let configuredValue,
            let defaultValue
        else {
            return false
        }
        return configuredValue != defaultValue
    }

    private static func effectiveHostKeyPolicy(
        profile: SessionProfile
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = ["-G"]
        arguments += [
            "-p", String(profile.port),
            "\(profile.username)@\(profile.resolvedHost)"
        ]
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard
            process.terminationStatus == 0,
            let output = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return output
            .split(whereSeparator: \.isNewline)
            .first(where: {
                $0.hasPrefix("stricthostkeychecking ")
            })?
            .split(separator: " ", maxSplits: 1)
            .last
            .map(String.init)
    }
}

enum SSHServiceError: LocalizedError {
    case sshpassUnavailable
    case invalidProfile
    case invalidJumpProfile
    case invalidProxy
    case askpassUnavailable
    case commandFailed(Int32, String)
    case noActiveSession

    var errorDescription: String? {
        switch self {
        case .sshpassUnavailable:
            "未找到 sshpass。请通过 Homebrew 安装：brew install hudochenkov/sshpass/sshpass"
        case .invalidProfile:
            "主机地址、用户名或端口无效。"
        case .invalidJumpProfile:
            "SSH 跳板 Remote 配置无效。"
        case .invalidProxy:
            "Proxy 主机或端口配置无效。"
        case .askpassUnavailable:
            "无法创建 SSH 跳板密码助手。"
        case let .commandFailed(code, output):
            "命令退出（\(code)）：\(CommandOutputSummary.text(output))"
        case .noActiveSession:
            "请先连接一个 SSH 会话。"
        }
    }
}
