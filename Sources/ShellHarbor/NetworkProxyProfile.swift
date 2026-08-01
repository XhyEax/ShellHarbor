import Foundation

struct NetworkProxyProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var type: SSHProxyType
    var host: String?
    var port: Int
    var tailscaleAuthKey: String?
    var tailscaleLoginServer: String?
    var tailscaleHostname: String?

    init(name: String, from remote: SessionProfile) {
        self.name = name
        type = remote.resolvedProxyType
        host = remote.proxyHost
        port = remote.resolvedProxyPort
        tailscaleAuthKey = remote.tailscaleAuthKey
        tailscaleLoginServer = remote.tailscaleLoginServer
        tailscaleHostname = remote.tailscaleHostname
    }

    func applying(to remote: SessionProfile) -> SessionProfile {
        var result = remote
        result.savedProxyID = id
        result.proxyType = type
        result.proxyHost = type == .tailscale ? "127.0.0.1" : host
        result.proxyPort = port
        result.tailscaleAuthKey = tailscaleAuthKey
        result.tailscaleLoginServer = tailscaleLoginServer
        result.tailscaleHostname = tailscaleHostname
        return result
    }
}

enum NetworkProxyStore {
    private static var fileURL: URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("ShellHarbor", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("proxies.json")
    }

    static func load() -> [NetworkProxyProfile] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let stored = try? JSONDecoder().decode(
                [NetworkProxyProfile].self,
                from: data
            )
        else { return [] }
        return stored.map { item in
            var item = item
            if
                let key = item.tailscaleAuthKey,
                PasswordCipher.isEncrypted(key)
            {
                item.tailscaleAuthKey = try? PasswordCipher.decrypt(key)
            }
            return item
        }
    }

    static func save(_ proxies: [NetworkProxyProfile]) {
        do {
            let encrypted = try proxies.map { item in
                var item = item
                if
                    let key = item.tailscaleAuthKey,
                    !key.isEmpty,
                    !PasswordCipher.isEncrypted(key)
                {
                    item.tailscaleAuthKey = try PasswordCipher.encrypt(key)
                }
                return item
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(encrypted).write(to: fileURL, options: .atomic)
        } catch {
            return
        }
    }
}
