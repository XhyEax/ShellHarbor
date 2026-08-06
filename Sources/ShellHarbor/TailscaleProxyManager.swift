import CryptoKit
import Foundation

struct TailscaleProxyReadyMessage: Decodable {
    let type: String
    let host: String
    let port: Int
    let controlPort: Int
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
        let controlPort: Int
    }

    private var instances: [String: Instance] = [:]
    private var startingKeys = Set<String>()
    private var relayRanges: [String: String] = [:]

    func ensureRunning(for profile: SessionProfile) async throws -> Int? {
        guard profile.resolvedProxyType == .tailscale else { return nil }
        let instanceKey = instanceKey(for: profile)
        if let instance = instances[instanceKey], instance.process.isRunning {
            return instance.port
        }
        if startingKeys.contains(instanceKey) {
            while startingKeys.contains(instanceKey) {
                try await Task.sleep(for: .milliseconds(50))
            }
            return try await ensureRunning(for: profile)
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
        startingKeys.insert(instanceKey)
        defer { startingKeys.remove(instanceKey) }
        let helper = try helperURL()
        let stateDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("ShellHarbor/Tailscale", isDirectory: true)
        .appendingPathComponent(
            SHA256.hash(data: Data(instanceKey.utf8))
                .map { String(format: "%02x", $0) }
                .joined(),
            isDirectory: true
        )
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

        do {
            let ready = try await waitUntilReady(
                process: process,
                output: output,
                errors: errors
            )
            guard
                ready.type == "ready",
                ready.host == "127.0.0.1",
                (15_040...65_535).contains(ready.port)
            else {
                process.terminate()
                throw TailscaleProxyError.startupFailed("helper 返回了无效地址")
            }
            instances[instanceKey] = Instance(
                process: process,
                port: ready.port,
                controlPort: ready.controlPort
            )
            return ready.port
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    func prepareMoshRelay(
        proxyProfile: SessionProfile,
        targetHost: String
    ) async throws -> String {
        _ = try await ensureRunning(for: proxyProfile)
        let key = instanceKey(for: proxyProfile)
        let relayKey = "\(key)|\(targetHost)"
        if let existing = relayRanges[relayKey] {
            return existing
        }
        guard let instance = instances[key], instance.process.isRunning else {
            throw TailscaleProxyError.startupFailed("Tailscale helper 未运行")
        }
        struct Request: Encodable { let target: String }
        struct Response: Decodable { let start: Int; let end: Int }
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(instance.controlPort)/udp-relay")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(target: targetHost))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard
            (response as? HTTPURLResponse)?.statusCode == 200,
            let relay = try? JSONDecoder().decode(Response.self, from: data)
        else {
            throw TailscaleProxyError.startupFailed("无法创建 Mosh UDP relay")
        }
        let range = "\(relay.start):\(relay.end)"
        relayRanges[relayKey] = range
        return range
    }

    func moshRelayConfiguration(
        for proxyProfile: SessionProfile
    ) async throws -> (controlPort: Int, clientPath: String) {
        _ = try await ensureRunning(for: proxyProfile)
        let key = instanceKey(for: proxyProfile)
        guard let instance = instances[key], instance.process.isRunning else {
            throw TailscaleProxyError.startupFailed("Tailscale helper 未运行")
        }
        let helper = try helperURL()
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw TailscaleProxyError.helperUnavailable
        }
        return (instance.controlPort, helper.path)
    }

    private func instanceKey(for profile: SessionProfile) -> String {
        [
            profile.savedProxyID?.uuidString ?? "standalone",
            profile.resolvedTailscaleHostname,
            (profile.tailscaleLoginServer ?? "").trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        ].joined(separator: "|")
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
