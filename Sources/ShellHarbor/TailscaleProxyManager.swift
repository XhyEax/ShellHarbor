import Foundation

struct TailscaleProxyReadyMessage: Decodable {
    let type: String
    let host: String
    let port: Int
}

enum TailscaleProxyError: LocalizedError {
    case helperUnavailable
    case invalidConfiguration
    case startupFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            "找不到内置 Tailscale helper，请重新打包 ShellHarbor。"
        case .invalidConfiguration:
            "Tailscale Proxy 配置无效，请检查认证密钥和本地端口。"
        case let .startupFailed(message):
            "Tailscale Proxy 启动失败：\(message)"
        }
    }
}

@MainActor
final class TailscaleProxyManager {
    private struct Instance {
        let process: Process
        let port: Int
    }

    private var instances: [UUID: Instance] = [:]

    func ensureRunning(for profile: SessionProfile) async throws {
        guard profile.resolvedProxyType == .tailscale else { return }
        if let instance = instances[profile.id], instance.process.isRunning {
            guard instance.port == profile.resolvedProxyPort else {
                instance.process.terminate()
                instances.removeValue(forKey: profile.id)
                return try await ensureRunning(for: profile)
            }
            return
        }
        guard
            profile.isProxyConfigurationValid,
            let key = profile.tailscaleAuthKey?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !key.isEmpty
        else {
            throw TailscaleProxyError.invalidConfiguration
        }
        let helper = try helperURL()
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
        process.executableURL = helper
        process.arguments = [
            "--hostname", profile.resolvedTailscaleHostname,
            "--state-dir", stateDirectory.path,
            "--listen", "127.0.0.1:\(profile.resolvedProxyPort)",
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
            "--login-server", profile.tailscaleLoginServer ?? ""
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data("\(key)\n".utf8))
        try? input.fileHandleForWriting.close()

        do {
            let ready = try await waitUntilReady(
                process: process,
                output: output,
                errors: errors
            )
            guard
                ready.type == "ready",
                ready.host == "127.0.0.1",
                ready.port == profile.resolvedProxyPort
            else {
                process.terminate()
                throw TailscaleProxyError.startupFailed("helper 返回了无效地址")
            }
            instances[profile.id] = Instance(
                process: process,
                port: ready.port
            )
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    private func waitUntilReady(
        process: Process,
        output: Pipe,
        errors: Pipe
    ) async throws -> TailscaleProxyReadyMessage {
        try await withThrowingTaskGroup(
            of: TailscaleProxyReadyMessage.self
        ) { group in
            group.addTask {
                let data = output.fileHandleForReading.availableData
                guard
                    !data.isEmpty,
                    let ready = try? JSONDecoder().decode(
                        TailscaleProxyReadyMessage.self,
                        from: data
                    )
                else {
                    let errorData = errors.fileHandleForReading.availableData
                    let message = String(decoding: errorData, as: UTF8.self)
                    throw TailscaleProxyError.startupFailed(
                        message.isEmpty
                            ? "helper 在就绪前退出（\(process.terminationStatus)）"
                            : message
                    )
                }
                return ready
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw TailscaleProxyError.startupFailed("等待连接超时")
            }
            guard let result = try await group.next() else {
                throw TailscaleProxyError.startupFailed("未收到就绪消息")
            }
            group.cancelAll()
            return result
        }
    }

    private func helperURL() throws -> URL {
        let fileManager = FileManager.default
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/tailscale-proxy-helper")
        if fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let development = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(".build/tailscale-proxy-helper")
        if fileManager.isExecutableFile(atPath: development.path) {
            return development
        }
        throw TailscaleProxyError.helperUnavailable
    }
}
