import Foundation
import Observation

struct MobileProxyProfile: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name = "Tailscale 官方服务"
    var type = MobileProxyType.tailscale
    var host = "127.0.0.1"
    var port = 1080
    var tailscaleLoginServer = ""
    var tailscaleNodeName = ""
    var tailscaleAuthKey = ""
}

@MainActor
@Observable
final class MobileProxyStore {
    private(set) var proxies: [MobileProxyProfile] = []

    init() {
        guard let data = UserDefaults.standard.data(forKey: "mobileProxies"),
              let decoded = try? JSONDecoder().decode([MobileProxyProfile].self, from: data) else {
            return
        }
        proxies = decoded
    }

    func save(_ proxy: MobileProxyProfile) {
        if let index = proxies.firstIndex(where: { $0.id == proxy.id }) {
            proxies[index] = proxy
        } else {
            proxies.append(proxy)
        }
        persist()
    }

    @discardableResult
    func saveReusableProxy(from remote: MobileRemoteProfile) -> UUID? {
        guard remote.proxyType != .none else { return nil }
        let trimmedName = remote.proxyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName: String
        if remote.proxyType == .tailscale {
            let loginServerName = remote.tailscaleLoginServer
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            fallbackName = loginServerName.isEmpty ? "Tailscale 官方服务" : loginServerName
        } else {
            fallbackName = remote.proxyHost
        }
        let name = trimmedName.isEmpty ? fallbackName : trimmedName
        guard !name.isEmpty else { return nil }

        var proxy = proxies.first(where: {
            $0.type == remote.proxyType &&
                $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) ?? MobileProxyProfile()
        proxy.name = name
        proxy.type = remote.proxyType
        proxy.host = remote.proxyHost
        proxy.port = remote.proxyPort
        proxy.tailscaleLoginServer = remote.tailscaleLoginServer
        proxy.tailscaleNodeName = remote.tailscaleNodeName
        proxy.tailscaleAuthKey = remote.tailscaleAuthKey
        save(proxy)
        return proxy.id
    }

    func delete(at offsets: IndexSet) {
        delete(ids: Set(offsets.compactMap { proxies.indices.contains($0) ? proxies[$0].id : nil }))
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        proxies.removeAll { ids.contains($0.id) }
        persist()
    }

    func resolved(_ remote: MobileRemoteProfile) -> MobileRemoteProfile {
        guard let id = remote.savedProxyID,
              let proxy = proxies.first(where: { $0.id == id }) else { return remote }
        var result = remote
        result.proxyType = proxy.type
        result.proxyName = proxy.name
        result.proxyHost = proxy.host
        result.proxyPort = proxy.port
        result.tailscaleLoginServer = proxy.tailscaleLoginServer
        result.tailscaleNodeName = proxy.tailscaleNodeName
        result.tailscaleAuthKey = proxy.tailscaleAuthKey
        return result
    }

    func importPortableProfiles(_ incoming: [PortableProxy]) -> [UUID: UUID] {
        var idMap: [UUID: UUID] = [:]
        for portable in incoming {
            let type = Self.proxyType(portable.type)
            let normalizedName = portable.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let existing = proxies.first(where: {
                $0.id == portable.id ||
                    $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
            })
            let finalID = existing?.id ?? portable.id
            idMap[portable.id] = finalID
            var proxy = existing ?? MobileProxyProfile()
            proxy.id = finalID
            proxy.name = normalizedName.isEmpty ? "Proxy" : normalizedName
            proxy.type = type
            proxy.host = portable.host ?? "127.0.0.1"
            proxy.port = portable.port
            proxy.tailscaleLoginServer = portable.tailscaleLoginServer ?? ""
            proxy.tailscaleNodeName = portable.tailscaleHostname ?? ""
            // Portable archives intentionally contain no authentication key.
            if let index = proxies.firstIndex(where: { $0.id == finalID }) { proxies[index] = proxy }
            else { proxies.append(proxy) }
        }
        persist()
        return idMap
    }

    private static func proxyType(_ value: String) -> MobileProxyType {
        switch value.lowercased() {
        case "socks", "socks5": .socks5
        case "http", "httpconnect", "http-connect": .httpConnect
        case "tailscale": .tailscale
        default: .none
        }
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(proxies), forKey: "mobileProxies")
    }
}
