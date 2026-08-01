import Foundation
import Observation

struct MobileProxyProfile: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name = "新 Proxy"
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

    func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) { proxies.remove(at: index) }
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
                $0.type == type && $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
            })
            let finalID = existing?.id ?? (proxies.contains { $0.id == portable.id } ? UUID() : portable.id)
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
