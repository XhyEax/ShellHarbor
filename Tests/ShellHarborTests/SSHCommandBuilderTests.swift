import AppKit
import Security
import UniformTypeIdentifiers
import XCTest
@testable import ShellHarbor
import SwiftTerm

final class SSHCommandBuilderTests: XCTestCase {
    func testLocalPathCompletionFindsFilesAndDirectories() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        let directory = temporary.appendingPathComponent(
            "Documents",
            isDirectory: true
        )
        let file = temporary.appendingPathComponent("download.log")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data().write(to: file)

        let suggestions = FilePathCompletion.local(
            input: temporary.appendingPathComponent("do").path,
            currentDirectory: temporary
        )

        XCTAssertEqual(
            suggestions.map(\.path),
            [directory.path, file.path]
        )
        XCTAssertEqual(
            suggestions.map(\.isDirectory),
            [true, false]
        )
    }

    func testRemotePathCompletionUsesVisibleDirectory() {
        let entries = [
            FileEntry(
                name: "Documents",
                path: "/var/mobile/Documents",
                isDirectory: true,
                size: 0,
                modifiedAt: nil
            ),
            FileEntry(
                name: "download.log",
                path: "/var/mobile/download.log",
                isDirectory: false,
                size: 1,
                modifiedAt: nil
            )
        ]

        let suggestions = FilePathCompletion.remote(
            input: "/var/mobile/do",
            currentDirectory: "/var/mobile",
            entries: entries
        )

        XCTAssertEqual(
            suggestions.map(\.path),
            [
                "/var/mobile/Documents",
                "/var/mobile/download.log"
            ]
        )
    }

    func testFinderFileDropDecodesFileURLData() {
        let encoded = Data(
            "file:///Users/test/My%20File.txt".utf8
        )

        XCTAssertEqual(
            FinderFileDropDecoder.fileURL(from: encoded)?.path,
            "/Users/test/My File.txt"
        )
    }

    func testTerminalFileURLPasteUsesFullPaths() {
        let paths = TerminalFilePasteDecoder.paths(
            fileURLStrings: [],
            plainText: """
            file:///Users/test/My%20File.txt
            file:///tmp/report.log
            """
        )

        XCTAssertEqual(
            paths,
            [
                "/Users/test/My File.txt",
                "/tmp/report.log"
            ]
        )
        XCTAssertEqual(
            ShellPathInputFormatter.text(for: paths ?? []),
            "'/Users/test/My File.txt' /tmp/report.log"
        )
        XCTAssertNil(
            TerminalFilePasteDecoder.paths(
                fileURLStrings: [],
                plainText: "普通文本"
            )
        )
    }

    func testFileNameValidationForRename() {
        XCTAssertEqual(
            FileNameValidator.normalized("  renamed.log  "),
            "renamed.log"
        )
        XCTAssertNil(FileNameValidator.normalized(""))
        XCTAssertNil(FileNameValidator.normalized(".."))
        XCTAssertNil(FileNameValidator.normalized("folder/name"))
    }

    func testRemoteTextPreviewPolicyUsesExtensionAndTenMegabyteLimit() {
        func entry(_ name: String, _ size: Int64) -> FileEntry {
            FileEntry(
                name: name,
                path: "/remote/\(name)",
                isDirectory: false,
                size: size,
                modifiedAt: nil
            )
        }

        XCTAssertTrue(
            RemoteFilePreviewPolicy.shouldOpenAfterDownload(
                entry("system.LOG", 10 * 1_024 * 1_024 - 1)
            )
        )
        XCTAssertTrue(
            RemoteFilePreviewPolicy.shouldOpenAfterDownload(
                entry("notes.txt", 12)
            )
        )
        XCTAssertTrue(
            RemoteFilePreviewPolicy.shouldOpenAfterDownload(
                entry("Info.plist", 12)
            )
        )
        XCTAssertFalse(
            RemoteFilePreviewPolicy.shouldOpenAfterDownload(
                entry("large.log", 10 * 1_024 * 1_024)
            )
        )
        XCTAssertFalse(
            RemoteFilePreviewPolicy.shouldOpenAfterDownload(
                entry("archive.zip", 12)
            )
        )
    }

    func testFileNameCollisionAddsFinderStyleSuffix() {
        let unavailable = Set([
            "report.txt",
            "report (1).txt",
            "Archive"
        ])

        XCTAssertEqual(
            FileNameCollisionResolver.uniqueName(
                for: "report.txt",
                isDirectory: false,
                isUnavailable: unavailable.contains
            ),
            "report (2).txt"
        )
        XCTAssertEqual(
            FileNameCollisionResolver.uniqueName(
                for: "Archive",
                isDirectory: true,
                isUnavailable: unavailable.contains
            ),
            "Archive (1)"
        )
    }

    func testRenameCaretStopsBeforeFileExtension() {
        XCTAssertEqual(
            FileNameEditing.renameCaretOffset(
                for: "report.txt",
                isDirectory: false
            ),
            6
        )
        XCTAssertEqual(
            FileNameEditing.renameCaretOffset(
                for: "archive.tar.gz",
                isDirectory: false
            ),
            7
        )
        XCTAssertEqual(
            FileNameEditing.renameCaretOffset(
                for: "folder.name",
                isDirectory: true
            ),
            11
        )
        XCTAssertEqual(
            FileNameEditing.renameCaretOffset(
                for: ".config.json",
                isDirectory: false
            ),
            7
        )
        XCTAssertEqual(
            FileNameEditing.renameCaretOffset(
                for: ".env",
                isDirectory: false
            ),
            4
        )
    }

    func testRemotePathsAreShellSafeWhenDroppedIntoTerminal() {
        XCTAssertEqual(
            ShellPathInputFormatter.text(
                for: ["/var/mobile/Documents/qbditracer.log"]
            ),
            "/var/mobile/Documents/qbditracer.log"
        )
        XCTAssertEqual(
            ShellPathInputFormatter.text(
                for: [
                    "/tmp/a file.txt",
                    "/tmp/it's.log"
                ]
            ),
            "'/tmp/a file.txt' '/tmp/it'\"'\"'s.log'"
        )
    }

    func testPendingTerminalInputTracksEditingAndExecution() {
        var input = PendingTerminalInput()
        input.record(Array("echo helo".utf8))
        input.record([0x1B, 0x5B, 0x44])
        input.record(Array("l".utf8))

        XCTAssertEqual(input.text, "echo hello")
        XCTAssertTrue(input.isReliable)

        input.record([0x0D])
        XCTAssertEqual(input.text, "")
    }

    func testPendingTerminalInputRejectsUnknownHistoryRecall() {
        var input = PendingTerminalInput()
        input.record(Array("partial".utf8))
        input.record([0x1B, 0x5B, 0x41])

        XCTAssertFalse(input.isReliable)
    }

    func testRemoteDirectoryTrackerFollowsCommonCDCommands() {
        var tracker = RemoteDirectoryTracker()
        tracker.restore("/var/mobile")
        tracker.record(command: "cd Documents")
        XCTAssertEqual(tracker.currentDirectory, "/var/mobile/Documents")

        tracker.record(command: "cd 'My Files'")
        XCTAssertEqual(
            tracker.currentDirectory,
            "/var/mobile/Documents/My Files"
        )

        tracker.record(command: "cd ..")
        XCTAssertEqual(tracker.currentDirectory, "/var/mobile/Documents")

        tracker.record(command: "cd -")
        XCTAssertEqual(
            tracker.currentDirectory,
            "/var/mobile/Documents/My Files"
        )
    }

    func testRestoredTerminalStartsInRememberedDirectory() {
        let command = SSHCommandBuilder.interactiveShellCommand(
            startingDirectory: "/var/mobile/My Files"
        )

        XCTAssertTrue(
            command?.contains("stty opost onlcr 2>/dev/null || true") == true
        )
        XCTAssertTrue(
            command?.contains("cd -- '/var/mobile/My Files'") == true
        )
        XCTAssertTrue(
            command?.contains("exec \"${SHELL:-$0}\" -l") == true
        )
        XCTAssertFalse(command?.contains("/bin/sh") == true)
    }

    func testDefaultRemoteStartDirectoryDoesNotModifyLoginDirectory() {
        let profile = SessionProfile()

        XCTAssertEqual(profile.remoteStartPath, "")
        XCTAssertEqual(profile.resolvedRemoteFilePath, "~")
        XCTAssertNil(
            SSHCommandBuilder.interactiveShellCommand(
                startingDirectory: profile.remoteStartPath
            )
        )
    }

    func testRestoredTerminalBufferReplaysNewlinesAtColumnZero() {
        let replay = SessionRestorationStore.replayBuffer(
            Data("first\nsecond\r\nthird".utf8)
        )

        XCTAssertEqual(
            String(decoding: replay, as: UTF8.self),
            "first\r\nsecond\r\nthird"
        )
    }

    func testSessionRestorationArchiveRoundTrips() throws {
        let workspaceID = UUID()
        let remoteID = UUID()
        let archive = SessionRestorationArchive(
            selectedWorkspaceID: workspaceID,
            sessions: [
                RestorableSessionSnapshot(
                    workspaceID: workspaceID,
                    remoteID: remoteID,
                    sessionNumber: 2,
                    customName: "日志",
                    mode: .workspace,
                    localPath: "/Users/test/Downloads",
                    remotePath: "/var/log",
                    terminalDirectory: "/srv/app",
                    terminalBuffer: Data("buffer".utf8),
                    pendingCommand: "tail -f app.log"
                )
            ]
        )

        let data = try JSONEncoder().encode(archive)
        let decoded = try JSONDecoder().decode(
            SessionRestorationArchive.self,
            from: data
        )

        XCTAssertEqual(decoded, archive)
    }

    @MainActor
    func testTerminalScrollbackDefaultsAndAppliesToController() {
        XCTAssertEqual(
            TerminalScrollbackSettings.defaultLines,
            100_000
        )
        XCTAssertEqual(
            TerminalScrollbackSettings.normalized(500),
            1_000
        )
        XCTAssertEqual(
            TerminalScrollbackSettings.normalized(2_000_000),
            1_000_000
        )

        let controller = TerminalController()
        controller.setScrollbackLines(250_000)
        XCTAssertEqual(controller.scrollbackLines, 250_000)
    }

    @MainActor
    func testRepeatedTerminalInsertFallbackRequestsStayDistinct() {
        let profile = SessionProfile.local(
            id: UUID(),
            shell: .system
        )
        let controller = TerminalController()
        controller.connect(profile: profile)
        controller.processStarted(for: controller.connectionToken)

        controller.insertText("first")
        let firstRequest = controller.inputRequest
        controller.insertText("second")
        let secondRequest = controller.inputRequest

        XCTAssertEqual(firstRequest?.text, "first")
        XCTAssertEqual(secondRequest?.text, "second")
        XCTAssertNotEqual(firstRequest?.id, secondRequest?.id)
    }

    func testRemoteIconDefaultsAndSymbols() {
        var profile = SessionProfile()
        XCTAssertEqual(profile.resolvedRemoteIcon, .server)
        XCTAssertEqual(profile.resolvedRemoteIcon.symbol, "server.rack")
        XCTAssertTrue(profile.resolvedInspectionEnabled)
        XCTAssertEqual(profile.resolvedInspectionIntervalMinutes, 15)

        profile.remoteIcon = .iPhone
        XCTAssertEqual(profile.resolvedRemoteIcon.symbol, "iphone")
    }

    func testInspectionOutputParsing() throws {
        let remoteID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let record = try XCTUnwrap(
            InspectionService.parse(
                """
                Login banner
                __SHELLHARBOR_INSPECTION__
                CPU_PERCENT=23.5
                MEMORY_PERCENT=62.1
                MEMORY_TOTAL=17179869184
                MEMORY_AVAILABLE=6512345678
                DISK_TOTAL=1000000000000
                DISK_AVAILABLE=250000000000
                DISK_PERCENT=75
                """,
                remoteID: remoteID,
                timestamp: timestamp
            )
        )

        XCTAssertEqual(record.remoteID, remoteID)
        XCTAssertEqual(record.timestamp, timestamp)
        XCTAssertTrue(record.isReachable)
        XCTAssertEqual(record.cpuUsagePercent, 23.5)
        XCTAssertEqual(record.memoryUsagePercent, 62.1)
        XCTAssertEqual(record.diskUsagePercent, 75)
        XCTAssertEqual(record.diskAvailableBytes, 250_000_000_000)
    }

    func testInspectionHealthStatusAndStatistics() {
        func record(
            reachable: Bool,
            cpu: Double?
        ) -> InspectionRecord {
            InspectionRecord(
                id: UUID(),
                remoteID: UUID(),
                timestamp: Date(),
                isReachable: reachable,
                cpuUsagePercent: cpu,
                memoryUsagePercent: 40,
                memoryTotalBytes: 1_000,
                memoryAvailableBytes: 600,
                diskTotalBytes: 1_000,
                diskAvailableBytes: 500,
                diskUsagePercent: 50,
                errorMessage: reachable ? nil : "timeout"
            )
        }

        let records = [
            record(reachable: true, cpu: 20),
            record(reachable: true, cpu: 92),
            record(reachable: false, cpu: nil)
        ]

        XCTAssertEqual(records[0].healthStatus, .healthy)
        XCTAssertEqual(records[1].healthStatus, .warning)
        XCTAssertEqual(records[2].healthStatus, .offline)

        let statistics = InspectionStatistics(records: records)
        XCTAssertEqual(statistics.total, 3)
        XCTAssertEqual(statistics.healthy, 1)
        XCTAssertEqual(statistics.warning, 1)
        XCTAssertEqual(statistics.offline, 1)
        XCTAssertEqual(statistics.healthyRate, 1.0 / 3.0)
    }

    func testInspectionSSHUsesConnectionTimeoutAndBatchMode() throws {
        var profile = SessionProfile()
        profile.host = "example.com"
        profile.username = "alice"
        profile.authentication = .agent

        let invocation = try SSHCommandBuilder.ssh(
            profile: profile,
            command: "true",
            connectionTimeoutSeconds: 10,
            batchMode: true
        )

        XCTAssertTrue(invocation.arguments.contains("ConnectTimeout=10"))
        XCTAssertTrue(invocation.arguments.contains("ConnectionAttempts=1"))
        XCTAssertTrue(invocation.arguments.contains("BatchMode=yes"))
    }

    func testAuthenticationFailuresDoNotMeanInspectionOffline() {
        XCTAssertFalse(InspectionService.isConnectivityFailure(
            "Permission denied, please try again."
        ))
        XCTAssertFalse(InspectionService.isConnectivityFailure(
            "Received disconnect: Too many authentication failures"
        ))
        XCTAssertTrue(InspectionService.isConnectivityFailure(
            "Connection timed out"
        ))
    }

    func testJumpDefaultsToOpenSSHProxyJump() throws {
        var target = SessionProfile()
        target.host = "target.internal"
        target.username = "deploy"
        var jump = SessionProfile()
        jump.host = "gateway.example.com"
        jump.username = "bastion"
        jump.port = 2222

        let invocation = try SSHCommandBuilder.ssh(
            profile: target,
            jumpProfile: jump
        )

        XCTAssertTrue(invocation.arguments.contains("-J"))
        XCTAssertTrue(invocation.arguments.contains(
            "bastion@gateway.example.com:2222"
        ))
    }

    func testAgentSSHInvocationUsesSystemSSH() throws {
        var profile = SessionProfile()
        profile.host = "example.com"
        profile.username = "alice"
        profile.port = 2202
        profile.authentication = .agent
        profile.hostKeyPolicy = .ask

        let invocation = try SSHCommandBuilder.ssh(
            profile: profile,
            command: "uname -a"
        )

        XCTAssertEqual(invocation.executableURL.path, "/usr/bin/ssh")
        XCTAssertTrue(invocation.arguments.contains("2202"))
        XCTAssertFalse(invocation.arguments.contains(
            "StrictHostKeyChecking=accept-new"
        ))
        XCTAssertFalse(
            invocation.arguments.contains("StrictHostKeyChecking=yes")
        )
        XCTAssertEqual(invocation.arguments.suffix(2), ["alice@example.com", "uname -a"])
        XCTAssertFalse(invocation.displayCommand.contains("••••"))
    }

    func testSSHProxyUsesSelectedRemoteConnectionSettings() throws {
        var target = SessionProfile()
        target.host = "private.internal"
        target.username = "deploy"
        target.port = 2200
        target.sshJumpMode = .forward

        var jump = SessionProfile()
        jump.name = "Gateway"
        jump.host = "gateway.example.com"
        jump.username = "bastion"
        jump.port = 2222
        jump.authentication = .privateKey
        jump.privateKeyPath = "/Users/test/.ssh/jump key"
        jump.hostKeyPolicy = .ask

        let invocation = try SSHCommandBuilder.ssh(
            profile: target,
            jumpProfile: jump,
            command: "hostname"
        )
        let proxyOption = try XCTUnwrap(
            invocation.arguments.first(where: {
                $0.hasPrefix("ProxyCommand=")
            })
        )

        XCTAssertTrue(proxyOption.contains("/usr/bin/ssh"))
        XCTAssertTrue(proxyOption.contains("gateway.example.com"))
        XCTAssertTrue(proxyOption.contains("bastion@"))
        XCTAssertTrue(proxyOption.contains("2222"))
        XCTAssertTrue(proxyOption.contains("jump key"))
        XCTAssertTrue(proxyOption.contains("%h:%p"))
        XCTAssertEqual(
            invocation.arguments.suffix(2),
            ["deploy@private.internal", "hostname"]
        )
    }

    func testPasswordJumpUsesSeparateAskpassSecrets() throws {
        var target = SessionProfile()
        target.host = "private.internal"
        target.username = "deploy"
        target.authentication = .password
        target.password = "target-secret"

        var jump = SessionProfile()
        jump.host = "gateway.example.com"
        jump.username = "bastion"
        jump.authentication = .password
        jump.password = "jump-secret"

        let invocation = try SSHCommandBuilder.ssh(
            profile: target,
            jumpProfile: jump
        )

        XCTAssertEqual(invocation.executableURL.path, "/usr/bin/ssh")
        XCTAssertEqual(
            invocation.environment["SHELLHARBOR_TARGET_PASSWORD"],
            "target-secret"
        )
        XCTAssertEqual(
            invocation.environment["SHELLHARBOR_JUMP_PASSWORD"],
            "jump-secret"
        )
        XCTAssertEqual(
            invocation.environment["SHELLHARBOR_PASSWORD_ROLE"],
            "target"
        )
        let askpass = try XCTUnwrap(
            invocation.environment["SSH_ASKPASS"]
        )
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: askpass)
        )
        XCTAssertFalse(invocation.displayCommand.contains("target-secret"))
        XCTAssertFalse(invocation.displayCommand.contains("jump-secret"))
        XCTAssertFalse(invocation.arguments.contains("target-secret"))
        XCTAssertFalse(invocation.arguments.contains("jump-secret"))
    }

    func testSOCKS5ProxyIsAppliedToSSH() throws {
        var profile = SessionProfile()
        profile.host = "private.internal"
        profile.username = "deploy"
        profile.proxyType = .socks5
        profile.proxyHost = "127.0.0.1"
        profile.proxyPort = 7890

        let invocation = try SSHCommandBuilder.ssh(profile: profile)
        let proxyOption = try XCTUnwrap(
            invocation.arguments.first(where: {
                $0.hasPrefix("ProxyCommand=")
            })
        )

        XCTAssertTrue(proxyOption.contains("/usr/bin/nc"))
        XCTAssertTrue(proxyOption.contains("127.0.0.1:7890"))
        XCTAssertTrue(proxyOption.contains("'-X' '5'"))
        XCTAssertTrue(proxyOption.contains("'%h' '%p'"))
    }

    func testHTTPConnectProxyIsAppliedToSCP() throws {
        var profile = SessionProfile()
        profile.host = "private.internal"
        profile.username = "deploy"
        profile.proxyType = .httpConnect
        profile.proxyHost = "proxy.example.com"
        profile.proxyPort = 3128

        let invocation = try SSHCommandBuilder.scp(
            profile: profile,
            localPath: "/tmp/report.txt",
            remotePath: "/tmp/report.txt",
            direction: .upload,
            recursive: false
        )
        let proxyOption = try XCTUnwrap(
            invocation.arguments.first(where: {
                $0.hasPrefix("ProxyCommand=")
            })
        )

        XCTAssertTrue(proxyOption.contains("proxy.example.com:3128"))
        XCTAssertTrue(proxyOption.contains("'-X' 'connect'"))
    }

    func testJumpRemoteUsesItsOwnNetworkProxy() throws {
        var target = SessionProfile()
        target.host = "private.internal"
        target.username = "deploy"

        var jump = SessionProfile()
        jump.host = "gateway.internal"
        jump.username = "bastion"
        jump.proxyType = .socks5
        jump.proxyHost = "10.0.0.2"
        jump.proxyPort = 1088

        let invocation = try SSHCommandBuilder.ssh(
            profile: target,
            jumpProfile: jump
        )
        let proxyOption = try XCTUnwrap(
            invocation.arguments.first(where: {
                $0.hasPrefix("ProxyCommand=")
            })
        )

        XCTAssertTrue(proxyOption.contains("gateway.internal"))
        XCTAssertTrue(proxyOption.contains("/usr/bin/nc"))
        XCTAssertTrue(proxyOption.contains("10.0.0.2:1088"))
    }

    func testRemoteDefaultsToSSHConnectionMethod() {
        let profile = SessionProfile()

        XCTAssertEqual(
            profile.resolvedTerminalConnectionMethod,
            .ssh
        )
        XCTAssertEqual(profile.resolvedMoshJumpMode, .directTarget)
        XCTAssertFalse(profile.isMoshConnection)
    }

    func testMoshBuildsInteractiveInvocationWithCustomCommand() throws {
        var profile = SessionProfile()
        profile.host = "example.com"
        profile.username = "alice"
        profile.port = 2202
        profile.authentication = .agent
        profile.terminalConnectionMethod = .mosh
        profile.moshCommand = "/custom/bin/mosh"
        profile.moshServerCommand = "/remote/bin/mosh-server"

        let invocation = try SSHCommandBuilder.mosh(profile: profile)
        let commandLine = try XCTUnwrap(invocation.arguments.last)

        XCTAssertTrue(profile.isMoshConnection)
        XCTAssertEqual(invocation.executableURL.path, "/bin/zsh")
        XCTAssertEqual(invocation.arguments.first, "-lc")
        XCTAssertTrue(commandLine.contains("/custom/bin/mosh"))
        XCTAssertTrue(
            commandLine.contains(
                "--server=/remote/bin/mosh-server"
            )
        )
        XCTAssertTrue(commandLine.contains("--ssh="))
        XCTAssertTrue(commandLine.contains("/usr/bin/ssh"))
        XCTAssertTrue(commandLine.contains("2202"))
        XCTAssertTrue(commandLine.contains("alice@example.com"))
        XCTAssertTrue(
            invocation.environment["PATH"]?
                .split(separator: ":")
                .contains("/opt/homebrew/bin") == true
        )
    }

    func testMoshJumpDefaultsToBootstrapOnlyAndDirectTargetUDP()
        throws
    {
        var target = SessionProfile()
        target.host = "10.0.0.8"
        target.username = "deploy"
        target.terminalConnectionMethod = .mosh
        target.moshCommand = "mosh"
        target.sshJumpMode = .forward

        var jump = SessionProfile()
        jump.host = "gateway.example.com"
        jump.username = "bastion"
        jump.port = 2222

        let invocation = try SSHCommandBuilder.mosh(
            profile: target,
            jumpProfile: jump
        )
        let commandLine = try XCTUnwrap(invocation.arguments.last)

        XCTAssertTrue(
            commandLine.contains(
                "--experimental-remote-ip=remote"
            )
        )
        XCTAssertTrue(commandLine.contains("ProxyCommand="))
        XCTAssertTrue(commandLine.contains("deploy@10.0.0.8"))
        XCTAssertTrue(commandLine.contains("gateway.example.com"))
        XCTAssertFalse(commandLine.contains("bastion@gateway.example.com' 'ssh"))
    }

    func testMoshCanRunOnJumpThenSSHToTarget() throws {
        var target = SessionProfile()
        target.host = "10.0.0.8"
        target.username = "deploy"
        target.port = 2200
        target.hostKeyPolicy = .acceptNew
        target.terminalConnectionMethod = .jumpMosh
        target.moshCommand = "/opt/homebrew/bin/mosh"
        target.jumpMoshCommand = "/var/jb/usr/bin/mosh"
        target.moshServerCommand = "/opt/homebrew/bin/mosh-server"

        var jump = SessionProfile()
        jump.host = "gateway.example.com"
        jump.username = "bastion"
        jump.port = 2222
        jump.authentication = .agent
        target.jumpRemoteID = jump.id

        let invocation = try SSHCommandBuilder.mosh(
            profile: target,
            jumpProfile: jump,
            startingDirectory: "/srv/app"
        )
        let commandLine = try XCTUnwrap(invocation.arguments.last)

        XCTAssertEqual(invocation.executableURL.path, "/usr/bin/ssh")
        XCTAssertTrue(invocation.arguments.contains("-tt"))
        XCTAssertTrue(
            invocation.arguments.contains(
                "bastion@gateway.example.com"
            )
        )
        XCTAssertTrue(commandLine.contains("/var/jb/usr/bin/mosh"))
        XCTAssertTrue(commandLine.contains("/opt/homebrew/bin/mosh-server"))
        XCTAssertTrue(
            commandLine.contains(
                "--experimental-remote-ip=remote"
            )
        )
        XCTAssertTrue(commandLine.contains("'ssh'"))
        XCTAssertTrue(commandLine.contains("'2200'"))
        XCTAssertTrue(commandLine.contains("deploy@10.0.0.8"))
        XCTAssertTrue(
            commandLine.contains(
                "StrictHostKeyChecking=accept-new"
            )
        )
        XCTAssertTrue(commandLine.contains("/srv/app"))
        XCTAssertFalse(commandLine.contains("ProxyCommand="))
    }

    func testMoshOnPasswordJumpUsesJumpSecretForBootstrap()
        throws
    {
        guard SSHCommandBuilder.sshpassPath() != nil else {
            throw XCTSkip("当前环境未安装 sshpass")
        }
        var target = SessionProfile()
        target.host = "10.0.0.8"
        target.username = "deploy"
        target.authentication = .password
        target.password = "target-secret"
        target.terminalConnectionMethod = .jumpMosh
        target.moshCommand = "mosh"

        var jump = SessionProfile()
        jump.host = "gateway.example.com"
        jump.username = "bastion"
        jump.authentication = .password
        jump.password = "jump-secret"
        target.jumpRemoteID = jump.id

        let invocation = try SSHCommandBuilder.mosh(
            profile: target,
            jumpProfile: jump
        )
        let commandLine = try XCTUnwrap(invocation.arguments.last)

        XCTAssertEqual(
            invocation.environment["SSHPASS"],
            "jump-secret"
        )
        XCTAssertFalse(commandLine.contains("target-secret"))
        XCTAssertFalse(commandLine.contains("jump-secret"))
        XCTAssertTrue(commandLine.contains("deploy@10.0.0.8"))
    }

    func testJumpMoshAutomaticallyAnswersTargetPasswordOnce() {
        var responder = TerminalPasswordPromptResponder(
            username: "kk3",
            host: "100.64.0.3",
            password: "target-secret"
        )

        XCTAssertNil(
            responder.response(
                for: Array("root@127.0.0.1's password:".utf8)
            )
        )
        XCTAssertNil(
            responder.response(
                for: Array("(kk3@100.64.".utf8)
            )
        )
        XCTAssertEqual(
            responder.response(for: Array("0.3) Password:".utf8)),
            Array("target-secret\n".utf8)
        )
        XCTAssertNil(
            responder.response(
                for: Array("(kk3@100.64.0.3) Password:".utf8)
            )
        )
        XCTAssertTrue(responder.didRespond)
    }

    func testJumpMoshRecognizesOpenSSHPasswordPrompt() {
        var responder = TerminalPasswordPromptResponder(
            username: "deploy",
            host: "10.0.0.8",
            password: "target-secret"
        )

        XCTAssertEqual(
            responder.response(
                for: Array("deploy@10.0.0.8's password:".utf8)
            ),
            Array("target-secret\n".utf8)
        )
    }

    func testJumpMoshCommandDefaultsToRemotePATH() {
        var profile = SessionProfile()
        XCTAssertEqual(profile.resolvedJumpMoshCommand, "mosh")

        profile.jumpMoshCommand = "/var/jb/usr/bin/mosh"
        XCTAssertEqual(
            profile.resolvedJumpMoshCommand,
            "/var/jb/usr/bin/mosh"
        )
    }

    func testLegacyMoshJumpModeResolvesToJumpMoshChoice() {
        var profile = SessionProfile()
        profile.jumpRemoteID = UUID()
        profile.terminalConnectionMethod = .mosh
        profile.moshJumpMode = .moshOnJump

        XCTAssertEqual(
            profile.resolvedTerminalConnectionMethod,
            .jumpMosh
        )
        XCTAssertEqual(
            profile.resolvedMoshJumpMode,
            .moshOnJump
        )

        profile.jumpRemoteID = nil
        XCTAssertEqual(
            profile.resolvedTerminalConnectionMethod,
            .mosh
        )
    }

    func testLegacyMoshCommandSplitsLocalPathAndServer() {
        var profile = SessionProfile()
        profile.moshCommand =
            "/opt/homebrew/bin/mosh --server=/remote/mosh-server"

        XCTAssertEqual(
            profile.resolvedMoshCommand,
            "/opt/homebrew/bin/mosh"
        )
        XCTAssertEqual(
            profile.resolvedMoshServerCommand,
            "/remote/mosh-server"
        )
    }

    func testMoshRestoresRemoteWorkingDirectory() throws {
        var profile = SessionProfile()
        profile.host = "example.com"
        profile.username = "alice"
        profile.terminalConnectionMethod = .mosh
        profile.moshCommand = "mosh"

        let invocation = try SSHCommandBuilder.mosh(
            profile: profile,
            startingDirectory: "/var/mobile/Documents"
        )
        let commandLine = try XCTUnwrap(invocation.arguments.last)

        XCTAssertTrue(commandLine.contains("/bin/sh"))
        XCTAssertTrue(commandLine.contains("cd --"))
        XCTAssertTrue(commandLine.contains("/var/mobile/Documents"))
    }

    func testMoshPasswordIsPassedOnlyThroughEnvironment() throws {
        guard SSHCommandBuilder.sshpassPath() != nil else {
            throw XCTSkip("当前环境未安装 sshpass")
        }
        var profile = SessionProfile()
        profile.host = "example.com"
        profile.username = "alice"
        profile.authentication = .password
        profile.password = "mosh-secret"
        profile.terminalConnectionMethod = .mosh
        profile.moshCommand = "mosh"

        let invocation = try SSHCommandBuilder.mosh(profile: profile)
        let commandLine = try XCTUnwrap(invocation.arguments.last)

        XCTAssertEqual(invocation.environment["SSHPASS"], "mosh-secret")
        XCTAssertTrue(commandLine.contains("sshpass"))
        XCTAssertFalse(commandLine.contains("mosh-secret"))
        XCTAssertFalse(invocation.displayCommand.contains("mosh-secret"))
    }

    func testShellQuoteProtectsSingleQuotes() {
        XCTAssertEqual(
            SSHCommandBuilder.shellQuote("a'b"),
            "'a'\"'\"'b'"
        )
    }

    func testExplicitSSHConfigValueTakesPriorityOverAppFallback() {
        XCTAssertTrue(
            SSHConfigResolver.shouldPreferSSHConfig(
                configuredValue: "false",
                defaultValue: "ask"
            )
        )
        XCTAssertTrue(
            SSHConfigResolver.shouldPreferSSHConfig(
                configuredValue: "true",
                defaultValue: "ask"
            )
        )
        XCTAssertFalse(
            SSHConfigResolver.shouldPreferSSHConfig(
                configuredValue: "ask",
                defaultValue: "ask"
            )
        )
        XCTAssertFalse(
            SSHConfigResolver.shouldPreferSSHConfig(
                configuredValue: nil,
                defaultValue: "ask"
            )
        )
    }

    func testMissingHostKeyConfigKeepsInteractivePrompt() {
        let arguments = SSHHostKeyPolicyArguments.resolve(
            appPolicy: .ask,
            effectiveSSHConfigPolicy: "ask"
        )

        XCTAssertTrue(arguments.isEmpty)
    }

    func testExplicitHostKeyConfigStillTakesPriority() {
        XCTAssertEqual(
            SSHHostKeyPolicyArguments.resolve(
                appPolicy: .acceptNew,
                effectiveSSHConfigPolicy: "yes"
            ),
            []
        )
        let disabled = SSHHostKeyPolicyArguments.resolve(
            appPolicy: .strict,
            effectiveSSHConfigPolicy: "no"
        )
        XCTAssertTrue(
            disabled.contains("StrictHostKeyChecking=no")
        )
        XCTAssertTrue(disabled.contains("UserKnownHostsFile=/dev/null"))
    }

    func testBuilderDefersToEffectiveSSHConfigHostKeyPolicy() throws {
        var profile = SessionProfile()
        profile.host = "127.0.0.1"
        profile.port = 2222
        profile.username = "root"
        profile.hostKeyPolicy = .acceptNew

        let invocation = try SSHCommandBuilder.ssh(profile: profile)
        let hasAppOverride = invocation.arguments.contains(
            "StrictHostKeyChecking=accept-new"
        )

        XCTAssertEqual(
            hasAppOverride,
            !SSHConfigResolver.hasExplicitHostKeyPolicy(for: profile)
        )
        if
            SSHConfigResolver.hostKeyPolicy(for: profile) == "false"
        {
            XCTAssertTrue(
                invocation.arguments.contains(
                    "UserKnownHostsFile=/dev/null"
                )
            )
            XCTAssertTrue(
                invocation.arguments.contains(
                    "StrictHostKeyChecking=no"
                )
            )
        }
    }

    func testCommandOutputSummaryKeepsTailAndBoundsLargeErrors() {
        let output = (1...100)
            .map { "entry-\($0)" }
            .joined(separator: "\n")
        let summary = CommandOutputSummary.text(output)

        XCTAssertTrue(summary.contains("已省略 84 行"))
        XCTAssertFalse(summary.contains("entry-1\n"))
        XCTAssertTrue(summary.contains("entry-100"))
        XCTAssertLessThan(summary.count, 3_200)
    }

    func testPasswordNeverAppearsInDisplayCommand() throws {
        guard SSHCommandBuilder.sshpassPath() != nil else {
            throw XCTSkip("sshpass is not installed")
        }
        var profile = SessionProfile()
        profile.host = "example.com"
        profile.username = "alice"
        profile.authentication = .password
        profile.password = "super-secret"

        let invocation = try SSHCommandBuilder.ssh(profile: profile)

        XCTAssertEqual(invocation.environment["SSHPASS"], "super-secret")
        XCTAssertFalse(invocation.arguments.contains("super-secret"))
        XCTAssertFalse(invocation.displayCommand.contains("super-secret"))
        XCTAssertTrue(invocation.arguments.starts(with: ["-e", "/usr/bin/ssh"]))
    }

    func testPasswordCipherUsesRSAAndRoundTrips() throws {
        let privateKey = try PasswordCipher.generatePrivateKey()
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let plaintext = "super-secret-密码"
        let ciphertext = try PasswordCipher.encrypt(
            plaintext,
            using: publicKey
        )

        XCTAssertTrue(ciphertext.hasPrefix(PasswordCipher.prefix))
        XCTAssertFalse(ciphertext.contains(plaintext))
        XCTAssertEqual(
            try PasswordCipher.decrypt(
                ciphertext,
                using: privateKey
            ),
            plaintext
        )
    }

    func testSCPKeepsRemotePathInOneProcessArgument() throws {
        var profile = SessionProfile()
        profile.host = "example.com"
        profile.username = "alice"
        profile.authentication = .agent

        let invocation = try SSHCommandBuilder.scp(
            profile: profile,
            localPath: "/tmp/report.txt",
            remotePath: "~/reports/a;$(touch bad).txt",
            direction: .upload,
            recursive: false
        )

        XCTAssertEqual(
            invocation.arguments.last,
            "alice@example.com:~/reports/a;$(touch bad).txt"
        )
    }

    func testRemotePathNavigation() {
        XCTAssertEqual(RemoteFileService.parent(of: "~/a/b"), "~/a")
        XCTAssertEqual(RemoteFileService.parent(of: "~/a"), "~")
        XCTAssertEqual(RemoteFileService.parent(of: "/var/log"), "/var")
        XCTAssertEqual(RemoteFileService.parent(of: "file.log"), ".")
        XCTAssertEqual(RemoteFileService.parent(of: "logs/file.log"), "logs")
        XCTAssertEqual(RemoteFileService.join("/", "tmp"), "/tmp")
        XCTAssertEqual(RemoteFileService.join("~/work", "x"), "~/work/x")
    }

    func testRemoteHomePathIsReplacedWithResolvedAbsolutePath() throws {
        let listing = try RemoteFileService.parseResolvedOutput(
            """
            Warning: test banner
            __SHELLHARBOR_PWD__\t/Users/alice
            d\t0\t0\tDownloads
            f\t12\t0\t.profile
            """,
            requestedPath: "~"
        )

        XCTAssertEqual(listing.path, "/Users/alice")
        XCTAssertEqual(
            listing.entries.map(\.path),
            ["/Users/alice/Downloads", "/Users/alice/.profile"]
        )
    }

    func testRemoteListingFindsPathMarkerAfterBannerWithoutNewline() throws {
        let listing = try RemoteFileService.parseResolvedOutput(
            """
            custom login banner__SHELLHARBOR_PWD__\t/private/var/mobile
            f\t12\t0\t.profile
            """,
            requestedPath: "~"
        )

        XCTAssertEqual(listing.path, "/private/var/mobile")
        XCTAssertEqual(
            listing.entries.first?.path,
            "/private/var/mobile/.profile"
        )
    }

    func testRemoteListingAllowsEmptyZshDirectories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = RemoteFileService.listingScript(
            path: directory.path
        )
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", script]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, output)
        let listing = try RemoteFileService.parseResolvedOutput(
            output,
            requestedPath: directory.path
        )
        XCTAssertEqual(
            (listing.path as NSString).lastPathComponent,
            directory.lastPathComponent
        )
        XCTAssertTrue(listing.entries.isEmpty)
    }

    func testRemoteListingParsesCreationTime() throws {
        let listing = try RemoteFileService.parseResolvedOutput(
            """
            __SHELLHARBOR_PWD__\t/var/mobile/Documents
            f\t42\t1700000000\t1600000000\tqbditracer.log
            """,
            requestedPath: "/var/mobile/Documents"
        )

        XCTAssertEqual(listing.entries.first?.name, "qbditracer.log")
        XCTAssertEqual(
            listing.entries.first?.createdAt,
            Date(timeIntervalSince1970: 1_600_000_000)
        )
    }

    func testRemoteListingParsesWhitespacePaddedMacOSFileSize() throws {
        let listing = try RemoteFileService.parseResolvedOutput(
            """
            __SHELLHARBOR_PWD__\t/Users/kk3/Downloads
            f\t    615733087\t1784019169\t1784019070\tChatGPT.dmg
            """,
            requestedPath: "/Users/kk3/Downloads"
        )

        XCTAssertEqual(listing.entries.first?.size, 615_733_087)
        XCTAssertNotEqual(listing.entries.first?.sizeLabel, "Zero KB")
    }

    func testZshRemoteHistoryParsesDatesAndDeduplicatesNewest() {
        let output = """
        __SHELLHARBOR_ZSH__
        : 1700000000:0;git status
        : 1700000001:0;swift build
        : 1700000002:0;git status

        """

        let entries = RemoteHistoryService.parse(output)

        XCTAssertEqual(entries.map(\.command), ["git status", "swift build"])
        XCTAssertEqual(
            entries.first?.date,
            Date(timeIntervalSince1970: 1_700_000_002)
        )
    }

    func testBashRemoteHistoryUsesTimestampForFollowingCommand() {
        let output = """
        __SHELLHARBOR_BASH__
        #1700000000
        ls -la
        pwd

        """

        let entries = RemoteHistoryService.parse(output)

        XCTAssertEqual(entries.map(\.command), ["pwd", "ls -la"])
        XCTAssertEqual(
            entries.last?.date,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testTerminalEngineInterpretsANSIInsteadOfDisplayingControlBytes() {
        let terminal = HeadlessTerminal { _ in }
        terminal.terminal.feed(text: "\u{001B}[31mRED\u{001B}[0m")

        let rendered = String(
            data: terminal.terminal.getBufferAsData(),
            encoding: .utf8
        ) ?? ""

        XCTAssertTrue(rendered.contains("RED"))
        XCTAssertFalse(rendered.contains("\u{001B}"))
        XCTAssertFalse(rendered.contains("[31m"))
    }

    func testTerminalEngineUsesAlternateBufferForFullScreenPrograms() {
        let terminal = HeadlessTerminal { _ in }
        terminal.terminal.feed(text: "shell")
        terminal.terminal.feed(text: "\u{001B}[?1049h")
        terminal.terminal.feed(text: "vim-screen")

        var rendered = String(
            data: terminal.terminal.getBufferAsData(),
            encoding: .utf8
        ) ?? ""
        XCTAssertTrue(rendered.contains("vim-screen"))

        terminal.terminal.feed(text: "\u{001B}[?1049l")
        rendered = String(
            data: terminal.terminal.getBufferAsData(),
            encoding: .utf8
        ) ?? ""
        XCTAssertTrue(rendered.contains("shell"))
        XCTAssertFalse(rendered.contains("vim-screen"))
    }

    @MainActor
    func testLocalTerminalClearPreservesCurrentLineAndCursor() {
        let view = SteadyCursorTerminalView(frame: .zero)
        view.feed(text: "old output\r\nprompt: command --flag")
        let originalCursor = view.getTerminal().getCursorLocation()

        view.clearLocalBufferPreservingCurrentLine()

        let buffer = String(
            decoding: view.getTerminal().getBufferAsData(kind: .normal),
            as: UTF8.self
        )
        XCTAssertFalse(buffer.contains("old output"))
        XCTAssertTrue(
            buffer.contains("prompt: command --flag"),
            "buffer=\(buffer.debugDescription), cursor=\(originalCursor)"
        )
        XCTAssertEqual(
            view.getTerminal().getCursorLocation().x,
            originalCursor.x
        )
        XCTAssertEqual(view.getTerminal().getCursorLocation().y, 0)
    }

    func testSHCLILinkManagerCreatesAndRemovesOnlyManagedLink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("app/shcli")
        let link = root.appendingPathComponent("homebrew/bin/shcli")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binary.path
        )

        try SHCLILinkManager.synchronize(
            enabled: true,
            binaryURL: binary,
            linkURL: link
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: link.path
            ),
            binary.path
        )

        try SHCLILinkManager.synchronize(
            enabled: false,
            binaryURL: binary,
            linkURL: link
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))

        try Data("user-owned".utf8).write(to: link)
        XCTAssertThrowsError(
            try SHCLILinkManager.synchronize(
                enabled: true,
                binaryURL: binary,
                linkURL: link
            )
        )
        try SHCLILinkManager.synchronize(
            enabled: false,
            binaryURL: binary,
            linkURL: link
        )
        XCTAssertEqual(
            try String(contentsOf: link, encoding: .utf8),
            "user-owned"
        )
    }

    func testSHCLILinkIsRebuiltAfterApplicationMoves() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldBinary = root.appendingPathComponent(
            "Downloads/ShellHarbor.app/Contents/MacOS/shcli"
        )
        let movedBinary = root.appendingPathComponent(
            "Applications/ShellHarbor.app/Contents/MacOS/shcli"
        )
        let link = root.appendingPathComponent("homebrew/bin/shcli")
        for binary in [oldBinary, movedBinary] {
            try FileManager.default.createDirectory(
                at: binary.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\n".utf8).write(to: binary)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: binary.path
            )
        }
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: oldBinary
        )

        try SHCLILinkManager.synchronize(
            enabled: true,
            binaryURL: movedBinary,
            linkURL: link
        )

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: link.path
            ),
            movedBinary.path
        )

        try SHCLILinkManager.synchronize(
            enabled: true,
            binaryURL: oldBinary,
            linkURL: link
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: link.path
            ),
            oldBinary.path
        )
    }

    @MainActor
    func testTerminalFindBarCanBeShown() {
        let terminal = SteadyCursorTerminalView(frame: .init(
            x: 0,
            y: 0,
            width: 800,
            height: 500
        ))

        terminal.showTerminalFindBar()

        XCTAssertTrue(containsSearchField(in: terminal))
    }

    @MainActor
    func testSessionWorkspacesKeepIndependentRightSideState() {
        var firstProfile = SessionProfile()
        firstProfile.id = UUID()
        firstProfile.remoteStartPath = "~/first"
        var secondProfile = SessionProfile()
        secondProfile.id = UUID()
        secondProfile.remoteStartPath = "/srv/second"

        let first = SessionWorkspace(profile: firstProfile)
        let second = SessionWorkspace(profile: secondProfile)

        XCTAssertFalse(first.terminal === second.terminal)
        XCTAssertEqual(first.remotePath, "~/first")
        XCTAssertEqual(second.remotePath, "/srv/second")
        XCTAssertEqual(
            first.localPath,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads", isDirectory: true)
        )
        XCTAssertFalse(first.showTransfers)
        XCTAssertFalse(second.showTransfers)

        first.remotePath = "~/first/changed"
        first.mode = .files
        XCTAssertEqual(second.remotePath, "/srv/second")
        XCTAssertEqual(second.mode, .terminal)
    }

    @MainActor
    func testOpenWorkspaceReflectsRemoteRenameImmediately() {
        var profile = SessionProfile()
        profile.id = UUID()
        profile.name = "Before"
        let workspace = SessionWorkspace(profile: profile)

        profile.name = "After"
        workspace.updateProfile(profile)

        XCTAssertEqual(workspace.profile.name, "After")
        XCTAssertEqual(workspace.displayName, "After · 1")
    }

    @MainActor
    func testWorkspaceRestoresPathsRememberedByRemote() {
        var profile = SessionProfile()
        profile.lastLocalPath = FileManager.default
            .homeDirectoryForCurrentUser.path
        profile.lastRemotePath = "/var/mobile/Documents"
        profile.lastWorkspaceMode = WorkspaceMode.files.rawValue
        profile.lastLocalSortColumn = FileSortColumn.modified.rawValue
        profile.lastLocalSortAscending = false
        profile.lastRemoteSortColumn = FileSortColumn.size.rawValue
        profile.lastRemoteSortAscending = true

        let workspace = SessionWorkspace(profile: profile)

        XCTAssertEqual(
            workspace.localPath,
            FileManager.default.homeDirectoryForCurrentUser
        )
        XCTAssertEqual(workspace.remotePath, "/var/mobile/Documents")
        XCTAssertEqual(workspace.mode, .files)
        XCTAssertEqual(workspace.localSortColumn, .modified)
        XCTAssertFalse(workspace.localSortAscending)
        XCTAssertEqual(workspace.remoteSortColumn, .size)
        XCTAssertTrue(workspace.remoteSortAscending)
    }

    func testWorkspaceModesUseRequestedOrderAndLabels() {
        XCTAssertEqual(
            WorkspaceMode.allCases.map(\.title),
            ["终端", "文件", "工作台", "巡检日志"]
        )
    }

    func testTransferItemReportsProgressAndSpeed() {
        let item = TransferItem(
            id: UUID(),
            fileName: "archive.zip",
            source: "/remote/archive.zip",
            destination: "/local/archive.zip",
            direction: .download,
            totalBytes: 1_000,
            transferredBytes: 500,
            bytesPerSecond: 250,
            status: .running,
            log: ""
        )

        XCTAssertEqual(item.progressFraction, 0.5)
        XCTAssertEqual(
            item.totalSizeLabel,
            ByteCountFormatter.string(
                fromByteCount: 1_000,
                countStyle: .file
            )
        )
        XCTAssertTrue(item.progressLabel?.contains("50%") == true)
        XCTAssertTrue(item.speedLabel?.hasSuffix("/秒") == true)
    }

    func testFinishedTransferReportsBytesAndElapsedTime() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let item = TransferItem(
            id: UUID(),
            fileName: "folder",
            source: "/local/folder",
            destination: "/remote/folder",
            direction: .upload,
            isDirectory: true,
            totalBytes: 2_048,
            transferredBytes: 2_048,
            bytesPerSecond: 0,
            status: .finished,
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(65),
            log: ""
        )

        XCTAssertEqual(
            item.transferredSizeLabel,
            ByteCountFormatter.string(
                fromByteCount: 2_048,
                countStyle: .file
            )
        )
        XCTAssertEqual(item.durationLabel, "1 分 5 秒")
        XCTAssertTrue(
            item.completionSummaryLabel?.contains("已传输") == true
        )
        XCTAssertTrue(
            item.completionSummaryLabel?.contains("耗时 1 分 5 秒") == true
        )
    }

    func testDirectoryUploadSizeIncludesNestedFilesAndSkipsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        let first = root.appendingPathComponent("first.bin")
        let second = nested.appendingPathComponent("second.bin")
        try Data(repeating: 1, count: 7).write(to: first)
        try Data(repeating: 2, count: 13).write(to: second)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("first-link.bin"),
            withDestinationURL: first
        )

        XCTAssertEqual(
            LocalDirectorySizeCalculator.size(atPath: root.path),
            20
        )

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-c",
            RemoteFileService.pathSizeScript(path: root.path)
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(
            Int64(
                String(decoding: result, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            20
        )
    }

    func testCommandProcessControlPendingTransitions() {
        let control = CommandProcessControl()

        XCTAssertEqual(control.state, .pending)
        XCTAssertTrue(control.pause())
        XCTAssertEqual(control.state, .paused)
        XCTAssertTrue(control.resume())
        XCTAssertEqual(control.state, .pending)
        XCTAssertTrue(control.stop())
        XCTAssertEqual(control.state, .stopped)
        XCTAssertFalse(control.pause())
        XCTAssertFalse(control.resume())
    }

    func testCommandProcessControlPausesResumesAndStopsProcess()
        async throws
    {
        let control = CommandProcessControl()
        let invocation = SSHInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 10"],
            environment: ProcessInfo.processInfo.environment,
            displayCommand: "sleep 10"
        )
        let task = Task {
            try await CommandRunner.run(
                invocation,
                control: control
            )
        }
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(control.pause())
        XCTAssertEqual(control.state, .paused)
        XCTAssertTrue(control.resume())
        XCTAssertEqual(control.state, .running)
        XCTAssertTrue(control.stop())
        _ = try? await task.value
        XCTAssertEqual(control.state, .stopped)
    }

    func testRecentTransferDirectoriesResolveBothSides() {
        let upload = TransferItem(
            id: UUID(),
            fileName: "first.log",
            source: "/Users/test/Desktop/Logs/first.log",
            destination: "/var/mobile/Documents/first.log",
            direction: .upload,
            totalBytes: 20,
            transferredBytes: 20,
            bytesPerSecond: 0,
            status: .finished,
            log: ""
        )
        let download = TransferItem(
            id: UUID(),
            fileName: "second.log",
            source: "/var/log/second.log",
            destination: "/Users/test/Downloads/second.log",
            direction: .download,
            totalBytes: 30,
            transferredBytes: 30,
            bytesPerSecond: 0,
            status: .finished,
            log: ""
        )
        let duplicateUpload = TransferItem(
            id: UUID(),
            fileName: "third.log",
            source: "/Users/test/Desktop/Logs/third.log",
            destination: "/var/mobile/Documents/third.log",
            direction: .upload,
            totalBytes: 40,
            transferredBytes: 40,
            bytesPerSecond: 0,
            status: .finished,
            log: ""
        )
        let transfers = [upload, download, duplicateUpload]

        XCTAssertEqual(
            TransferRecentDirectoryResolver.localDirectories(
                from: transfers
            ),
            ["/Users/test/Desktop/Logs", "/Users/test/Downloads"]
        )
        XCTAssertEqual(
            TransferRecentDirectoryResolver.remoteDirectories(
                from: transfers
            ),
            ["/var/mobile/Documents", "/var/log"]
        )
    }

    func testInternalDirectoryDragProviderRoundTripsBothTypes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ShellHarbor-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = FileDragPayload(
            location: .local,
            items: [
                .init(
                    name: directory.lastPathComponent,
                    path: directory.path,
                    isDirectory: true,
                    size: 0
                )
            ]
        )
        let provider = FileDragItemProvider.make(payload)

        XCTAssertTrue(
            provider.hasItemConformingToTypeIdentifier(
                UTType.shellHarborFileEntries.identifier
            )
        )
        XCTAssertTrue(
            provider.hasItemConformingToTypeIdentifier(
                UTType.fileURL.identifier
            )
        )
        let loaded = expectation(description: "drag payload loaded")
        provider.loadDataRepresentation(
            forTypeIdentifier: UTType.shellHarborFileEntries.identifier
        ) { data, error in
            XCTAssertNil(error)
            let decoded = data.flatMap {
                try? JSONDecoder().decode(
                    FileDragPayload.self,
                    from: $0
                )
            }
            XCTAssertEqual(decoded?.location, .local)
            XCTAssertEqual(decoded?.items.first?.path, directory.path)
            XCTAssertEqual(decoded?.items.first?.isDirectory, true)
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 1)

        let fileURLLoaded = expectation(
            description: "directory file URL loaded"
        )
        provider.loadDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier
        ) { data, error in
            XCTAssertNil(error)
            XCTAssertEqual(
                data.flatMap(FinderFileDropDecoder.fileURL(from:))?.path,
                directory.path
            )
            fileURLLoaded.fulfill()
        }
        wait(for: [fileURLLoaded], timeout: 1)
    }

    func testSelectedRemotesMoveAsAGroup() {
        var remotes = ["A", "B", "C", "D"].map { name in
            var profile = SessionProfile()
            profile.name = name
            return profile
        }
        let selectedIDs = Set([remotes[1].id, remotes[2].id])

        remotes.moveRemotes(selectedIDs, direction: .up)
        XCTAssertEqual(remotes.map(\.name), ["B", "C", "A", "D"])

        remotes.moveRemotes(selectedIDs, direction: .down)
        XCTAssertEqual(remotes.map(\.name), ["A", "B", "C", "D"])
    }

    func testRemoteGroupsPreserveOrderAndPutUngroupedLast() {
        var productionA = SessionProfile()
        productionA.name = "Production A"
        productionA.remoteGroup = "Production"
        var ungrouped = SessionProfile()
        ungrouped.name = "Ungrouped"
        var productionB = SessionProfile()
        productionB.name = "Production B"
        productionB.remoteGroup = "production"
        var staging = SessionProfile()
        staging.name = "Staging"
        staging.remoteGroup = "Staging"

        let groups = RemoteGroupSection.sections(
            from: [productionA, ungrouped, productionB, staging]
        )

        XCTAssertEqual(
            groups.map(\.name),
            ["Production", "Staging", RemoteGroupName.ungrouped]
        )
        XCTAssertEqual(
            groups[0].sessions.map(\.name),
            ["Production A", "Production B"]
        )
    }

    func testRemoteGroupNormalizationAndLegacyProfileDecoding() throws {
        XCTAssertEqual(
            RemoteGroupName.normalized("  Production  "),
            "Production"
        )
        XCTAssertNil(RemoteGroupName.normalized("  \n "))
        XCTAssertNil(
            RemoteGroupName.normalized(RemoteGroupName.ungrouped)
        )

        let legacyData = try JSONEncoder().encode(SessionProfile())
        let decoded = try JSONDecoder().decode(
            SessionProfile.self,
            from: legacyData
        )
        XCTAssertNil(decoded.remoteGroup)
        XCTAssertEqual(
            decoded.resolvedRemoteGroup,
            RemoteGroupName.ungrouped
        )
    }

    func testSelectedRemoteMovesWithinItsVisibleGroup() {
        var productionA = SessionProfile()
        productionA.name = "Production A"
        productionA.remoteGroup = "Production"
        var staging = SessionProfile()
        staging.name = "Staging"
        staging.remoteGroup = "Staging"
        var productionB = SessionProfile()
        productionB.name = "Production B"
        productionB.remoteGroup = "Production"

        var remotes = [productionA, staging, productionB]
        remotes.moveRemotesWithinGroups(
            [productionB.id],
            direction: .up
        )

        let groups = RemoteGroupSection.sections(from: remotes)
        XCTAssertEqual(
            groups[0].sessions.map(\.name),
            ["Production B", "Production A"]
        )
        XCTAssertEqual(groups[1].sessions.map(\.name), ["Staging"])
    }

    func testRemoteGroupRenameUpdatesEveryMatchingRemote() {
        var first = SessionProfile()
        first.name = "First"
        first.remoteGroup = "Production"
        var second = SessionProfile()
        second.name = "Second"
        second.remoteGroup = "production"
        var third = SessionProfile()
        third.name = "Third"
        third.remoteGroup = "Staging"
        var remotes = [first, second, third]

        let updatedIDs = remotes.renameRemoteGroup(
            "Production",
            to: "Online"
        )

        XCTAssertEqual(updatedIDs, [first.id, second.id])
        XCTAssertEqual(
            remotes.map(\.resolvedRemoteGroup),
            ["Online", "Online", "Staging"]
        )
    }

    func testRemoteDragReordersBeforeOrAfterTarget() {
        var remotes = ["A", "B", "C", "D"].map { name in
            var profile = SessionProfile()
            profile.name = name
            return profile
        }
        let a = remotes[0].id
        let b = remotes[1].id
        let d = remotes[3].id

        remotes.reorderRemote(a, relativeTo: d, placeAfter: true)
        XCTAssertEqual(remotes.map(\.name), ["B", "C", "D", "A"])

        remotes.reorderRemote(d, relativeTo: b, placeAfter: false)
        XCTAssertEqual(remotes.map(\.name), ["D", "B", "C", "A"])
    }

    func testSessionTabDragReordersWorkspaceIDs() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let d = UUID()
        var workspaceIDs = [a, b, c, d]

        workspaceIDs.reorderWorkspace(
            a,
            relativeTo: c,
            placeAfter: true
        )
        XCTAssertEqual(workspaceIDs, [b, c, a, d])

        workspaceIDs.reorderWorkspace(
            d,
            relativeTo: b,
            placeAfter: false
        )
        XCTAssertEqual(workspaceIDs, [d, b, c, a])
    }

    func testSessionTabCloseGroupsFollowCurrentOrder() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()
        let ids = [first, second, third, fourth]

        XCTAssertEqual(
            ids.workspaceIDsExcluding(second),
            [first, third, fourth]
        )
        XCTAssertEqual(
            ids.workspaceIDsToRight(of: second),
            [third, fourth]
        )
        XCTAssertTrue(ids.workspaceIDsToRight(of: fourth).isEmpty)
    }

    func testFileColumnsUseFinderStyleMixedSorting() {
        let entries = [
            FileEntry(
                name: "z-folder",
                path: "/z-folder",
                isDirectory: true,
                size: 0,
                modifiedAt: Date(timeIntervalSince1970: 10)
            ),
            FileEntry(
                name: "small.txt",
                path: "/small.txt",
                isDirectory: false,
                size: 10,
                modifiedAt: Date(timeIntervalSince1970: 20)
            ),
            FileEntry(
                name: "large.txt",
                path: "/large.txt",
                isDirectory: false,
                size: 100,
                modifiedAt: Date(timeIntervalSince1970: 30)
            )
        ]

        XCTAssertEqual(
            FileEntrySorter.sorted(
                entries,
                by: .name,
                ascending: true
            ).map(\.name),
            ["large.txt", "small.txt", "z-folder"]
        )
        XCTAssertEqual(
            FileEntrySorter.sorted(
                entries,
                by: .size,
                ascending: false
            ).map(\.name),
            ["large.txt", "small.txt", "z-folder"]
        )
    }

    func testLocalhostProfileUsesCurrentUserAndSSHPort() throws {
        let profile = SessionProfile.localhost(username: "local-user")
        let invocation = try SSHCommandBuilder.ssh(
            profile: profile,
            forceTTY: true
        )

        XCTAssertEqual(profile.name, "本机")
        XCTAssertEqual(profile.host, "127.0.0.1")
        XCTAssertEqual(profile.port, 22)
        XCTAssertEqual(profile.username, "local-user")
        XCTAssertEqual(profile.authentication, .agent)
        XCTAssertTrue(invocation.arguments.contains("local-user@127.0.0.1"))
        XCTAssertTrue(invocation.arguments.contains("22"))
    }

    func testBlankHostDefaultsToLocalhost() throws {
        var profile = SessionProfile()
        profile.host = "   "
        profile.username = "alice"

        XCTAssertEqual(profile.resolvedHost, "127.0.0.1")
        XCTAssertTrue(profile.isConnectable)
        let invocation = try SSHCommandBuilder.ssh(profile: profile)
        XCTAssertTrue(invocation.arguments.contains("alice@127.0.0.1"))

        profile.host = "localhost"
        XCTAssertEqual(profile.resolvedHost, "127.0.0.1")
    }

    func testLocalProfileStartsSelectedLoginShellWithoutSSH() {
        let id = UUID()
        let profile = SessionProfile.local(id: id, shell: .zsh)
        let invocation = SSHCommandBuilder.localShell(
            profile.resolvedLocalShell
        )

        XCTAssertEqual(profile.id, id)
        XCTAssertEqual(profile.name, "Local")
        XCTAssertTrue(profile.isLocalConnection)
        XCTAssertTrue(profile.isConnectable)
        XCTAssertEqual(profile.subtitle, "\(NSUserName()) · zsh")
        XCTAssertEqual(invocation.executableURL.path, "/bin/zsh")
        XCTAssertEqual(invocation.arguments, ["-l"])
        XCTAssertEqual(
            invocation.currentDirectory,
            FileManager.default.homeDirectoryForCurrentUser.path
        )
        XCTAssertFalse(
            invocation.executableURL.lastPathComponent.contains("ssh")
        )
    }

    func testLocalShellCanUseBashOrSystemDefault() {
        XCTAssertEqual(LocalShell.bash.resolvedPath, "/bin/bash")
        XCTAssertEqual(LocalShell.zsh.resolvedPath, "/bin/zsh")
        XCTAssertFalse(LocalShell.system.resolvedPath.isEmpty)
        XCTAssertTrue(
            FileManager.default.isExecutableFile(
                atPath: LocalShell.system.resolvedPath
            )
        )
    }

    @MainActor
    func testSameRemoteCanCreateMultipleIndependentSessions() {
        var remote = SessionProfile()
        remote.id = UUID()
        remote.name = "production"

        let first = SessionWorkspace(profile: remote, sessionNumber: 1)
        let second = SessionWorkspace(profile: remote, sessionNumber: 2)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.remoteID, remote.id)
        XCTAssertEqual(second.remoteID, remote.id)
        XCTAssertFalse(first.terminal === second.terminal)
        XCTAssertEqual(first.displayName, "production · 1")
        XCTAssertEqual(second.displayName, "production · 2")

        first.rename(to: "  deploy shell  ")
        XCTAssertEqual(first.sessionLabel, "deploy shell")
        XCTAssertEqual(first.displayName, "production · deploy shell")
        XCTAssertEqual(second.displayName, "production · 2")

        first.rename(to: "   ")
        XCTAssertEqual(first.sessionLabel, "1")
        XCTAssertEqual(first.displayName, "production · 1")
    }

    @MainActor
    private func containsSearchField(in view: NSView) -> Bool {
        if view is NSSearchField { return true }
        return view.subviews.contains {
            containsSearchField(in: $0)
        }
    }
}
