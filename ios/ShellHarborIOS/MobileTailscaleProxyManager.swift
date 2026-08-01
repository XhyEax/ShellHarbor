import Foundation
import ShellHarborTS

private final class MobileGoTailscaleProxy: @unchecked Sendable {
    let value: SHShellharbortsProxy
    init(_ value: SHShellharbortsProxy) { self.value = value }
}

actor MobileTailscaleProxyManager {
    private var proxies: [String: MobileGoTailscaleProxy] = [:]
    private var startingProxies: [String: Task<MobileGoTailscaleProxy, Error>] = [:]
    private var forwards: [String: Int] = [:]
    private var udpForwards: [String: Int] = [:]
    private var nextPort = 15_040
    private var nextUDPPort = 16_040

    func prewarm(_ profiles: [MobileRemoteProfile]) async {
        await withTaskGroup(of: Void.self) { group in
            var seen: Set<String> = []
            for profile in profiles where profile.proxyType == .tailscale {
                let key = configurationKey(profile)
                guard seen.insert(key).inserted else { continue }
                group.addTask { [weak self] in
                    guard let self else { return }
                    _ = try? await self.tailscaleProxy(for: profile, key: key)
                }
            }
        }
    }

    func forwardedEndpoint(for profile: MobileRemoteProfile) async throws -> (host: String, port: Int) {
        guard profile.proxyType != .none else {
            return (profile.host.isEmpty ? "127.0.0.1" : profile.host, profile.port)
        }
        if profile.proxyType != .tailscale {
            return try await forwardedStandardProxyEndpoint(for: profile)
        }
        let key = configurationKey(profile)
        let targetHost = profile.host.isEmpty ? "127.0.0.1" : profile.host
        let target = "\(targetHost):\(profile.port)"
        let forwardKey = "\(key)|\(target)"
        if let port = forwards[forwardKey] { return ("127.0.0.1", port) }

        let proxy = try await tailscaleProxy(for: profile, key: key)

        let startPort = nextPort
        let port = try await runBlocking {
            var forwardedPort = 0
            try proxy.value.forward(
                targetHost,
                targetPort: profile.port,
                startPort: startPort,
                ret0_: &forwardedPort
            )
            return forwardedPort
        }
        nextPort = max(nextPort, port + 1)
        forwards[forwardKey] = port
        return ("127.0.0.1", port)
    }

    func forwardedMoshEndpoint(
        for profile: MobileRemoteProfile,
        serverPort: Int
    ) async throws -> (host: String, port: Int) {
        let targetHost = profile.host.isEmpty ? "127.0.0.1" : profile.host
        guard profile.proxyType == .tailscale else {
            return (targetHost, serverPort)
        }
        let key = configurationKey(profile)
        let forwardKey = "\(key)|udp|\(targetHost):\(serverPort)"
        if let port = udpForwards[forwardKey] { return ("127.0.0.1", port) }
        let proxy = try await tailscaleProxy(for: profile, key: key)
        let startPort = nextUDPPort
        let port = try await runBlocking {
            var forwardedPort = 0
            try proxy.value.forwardUDP(
                targetHost,
                targetPort: serverPort,
                startPort: startPort,
                ret0_: &forwardedPort
            )
            return forwardedPort
        }
        nextUDPPort = max(nextUDPPort, port + 1)
        udpForwards[forwardKey] = port
        return ("127.0.0.1", port)
    }

    private func tailscaleProxy(
        for profile: MobileRemoteProfile,
        key: String
    ) async throws -> MobileGoTailscaleProxy {
        if let existing = proxies[key] { return existing }
        if let starting = startingProxies[key] { return try await starting.value }
        guard let created = SHShellharbortsNewProxy() else {
            throw MobileTailscaleError.helperUnavailable
        }
        let proxy = MobileGoTailscaleProxy(created)
        let stateDirectory = try stateDirectory(for: key)
        let hostname = profile.tailscaleNodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nodeName = hostname.isEmpty ? Self.defaultNodeName : hostname
        let loginServer = Self.normalizedLoginServer(profile.tailscaleLoginServer)
        let authKey = try decryptedAuthKey(profile.tailscaleAuthKey)
        let starting = Task.detached(priority: .userInitiated) {
            try proxy.value.start(
                stateDirectory.path,
                hostname: nodeName,
                loginServer: loginServer,
                authKey: authKey
            )
            return proxy
        }
        startingProxies[key] = starting
        do {
            let ready = try await starting.value
            startingProxies[key] = nil
            proxies[key] = ready
            return ready
        } catch {
            startingProxies[key] = nil
            throw error
        }
    }

    private func forwardedStandardProxyEndpoint(
        for profile: MobileRemoteProfile
    ) async throws -> (host: String, port: Int) {
        let proxyHost = profile.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proxyHost.isEmpty, profile.proxyPort > 0 else {
            throw MobileTailscaleError.invalidProxy
        }
        let targetHost = profile.host.isEmpty ? "127.0.0.1" : profile.host
        let key = "\(profile.proxyType.rawValue)|\(proxyHost.lowercased()):\(profile.proxyPort)"
        let forwardKey = "\(key)|\(targetHost):\(profile.port)"
        if let port = forwards[forwardKey] { return ("127.0.0.1", port) }
        let proxy: MobileGoTailscaleProxy
        if let existing = proxies[key] {
            proxy = existing
        } else {
            guard let created = SHShellharbortsNewProxy() else {
                throw MobileTailscaleError.helperUnavailable
            }
            proxy = MobileGoTailscaleProxy(created)
            proxies[key] = proxy
        }
        let startPort = nextPort
        let port = try await runBlocking {
            var forwardedPort = 0
            switch profile.proxyType {
            case .socks5:
                try proxy.value.forwardSOCKS5(
                    proxyHost,
                    proxyPort: profile.proxyPort,
                    targetHost: targetHost,
                    targetPort: profile.port,
                    startPort: startPort,
                    ret0_: &forwardedPort
                )
            case .httpConnect:
                try proxy.value.forwardHTTPConnect(
                    proxyHost,
                    proxyPort: profile.proxyPort,
                    targetHost: targetHost,
                    targetPort: profile.port,
                    startPort: startPort,
                    ret0_: &forwardedPort
                )
            case .none, .tailscale:
                break
            }
            return forwardedPort
        }
        nextPort = max(nextPort, port + 1)
        forwards[forwardKey] = port
        return ("127.0.0.1", port)
    }

    private func configurationKey(_ profile: MobileRemoteProfile) -> String {
        let shared = profile.proxyName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !shared.isEmpty { return shared.lowercased() }
        let login = Self.normalizedLoginServer(profile.tailscaleLoginServer)
        return login.isEmpty ? "tailscale.com" : login.lowercased()
    }

    private func stateDirectory(for key: String) throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let safe = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        let url = base.appendingPathComponent("ShellHarbor/Tailscale/\(safe)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func decryptedAuthKey(_ stored: String) throws -> String {
        guard !stored.isEmpty else { return "" }
        return MobilePasswordCipher.isEncrypted(stored) ? try MobilePasswordCipher.decrypt(stored) : stored
    }

    private func runBlocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }

    private static func normalizedLoginServer(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    }

    private static let defaultNodeName: String = {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "mobileTailscaleNodeName"), !saved.isEmpty { return saved }
        let generated = "shellharbor-\(String(UUID().uuidString.lowercased().prefix(8)))"
        defaults.set(generated, forKey: "mobileTailscaleNodeName")
        return generated
    }()
}

enum MobileTailscaleError: LocalizedError {
    case helperUnavailable
    case invalidProxy
    var errorDescription: String? {
        switch self {
        case .helperUnavailable: "ShellHarbor 网络 helper 不可用。"
        case .invalidProxy: "Proxy 主机或端口无效。"
        }
    }
}
