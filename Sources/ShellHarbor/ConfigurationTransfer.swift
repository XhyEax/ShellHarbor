import Foundation

struct ShellHarborConfigurationArchive: Codable {
    static let currentVersion = 1
    var version = currentVersion
    var exportedAt = Date()
    var remotes: [PortableRemote]
    var proxies: [PortableProxy]
}

struct PortableRemote: Codable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authentication: String
    var hostKeyPolicy: String
    var keepAliveSeconds: Int
    var accentHex: String
    var remoteGroup: String?
    var remoteIcon: String?
    var connectionMethod: String
    var jumpRemoteID: UUID?
    var sshJumpMode: String?
    var savedProxyID: UUID?
    var proxyType: String?
    var proxyHost: String?
    var proxyPort: Int?
    var tailscaleLoginServer: String?
    var tailscaleHostname: String?
    var moshCommand: String?
    var moshServerCommand: String?
    var jumpMoshCommand: String?
}

struct PortableProxy: Codable {
    var id: UUID
    var name: String
    var type: String
    var host: String?
    var port: Int
    var tailscaleLoginServer: String?
    var tailscaleHostname: String?
}

struct RemoteDeduplicationKey: Hashable {
    let host: String
    let port: Int
    let username: String

    init(host: String, port: Int, username: String) {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.host = (normalizedHost.isEmpty ? "127.0.0.1" : normalizedHost).lowercased()
        self.port = port
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum ConfigurationTransferError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidArchive

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "不支持配置文件版本 \(version)。"
        case .invalidArchive: "所选文件不是有效的 ShellHarbor 配置。"
        }
    }
}

extension AppState {
    func exportedConfigurationData() throws -> Data {
        let archive = ShellHarborConfigurationArchive(
            remotes: sessions.map { profile in
                PortableRemote(
                    id: profile.id,
                    name: profile.name,
                    host: profile.resolvedHost,
                    port: profile.port,
                    username: profile.username,
                    authentication: profile.authentication.rawValue,
                    hostKeyPolicy: profile.hostKeyPolicy.rawValue,
                    keepAliveSeconds: profile.keepAliveSeconds,
                    accentHex: profile.accentHex,
                    remoteGroup: profile.remoteGroup,
                    remoteIcon: profile.remoteIcon?.rawValue,
                    connectionMethod: profile.resolvedTerminalConnectionMethod.rawValue,
                    jumpRemoteID: profile.jumpRemoteID,
                    sshJumpMode: profile.sshJumpMode?.rawValue,
                    savedProxyID: profile.savedProxyID,
                    proxyType: profile.proxyType?.rawValue,
                    proxyHost: profile.proxyHost,
                    proxyPort: profile.proxyPort,
                    tailscaleLoginServer: profile.tailscaleLoginServer,
                    tailscaleHostname: profile.tailscaleHostname,
                    moshCommand: profile.moshCommand,
                    moshServerCommand: profile.moshServerCommand,
                    jumpMoshCommand: profile.jumpMoshCommand
                )
            },
            proxies: savedProxies.map {
                PortableProxy(
                    id: $0.id,
                    name: $0.name,
                    type: $0.type.rawValue,
                    host: $0.host,
                    port: $0.port,
                    tailscaleLoginServer: $0.tailscaleLoginServer,
                    tailscaleHostname: $0.tailscaleHostname
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(archive)
    }

    @discardableResult
    func importConfigurationData(_ data: Data) throws -> (added: Int, updated: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(ShellHarborConfigurationArchive.self, from: data) else {
            throw ConfigurationTransferError.invalidArchive
        }
        guard archive.version <= ShellHarborConfigurationArchive.currentVersion else {
            throw ConfigurationTransferError.unsupportedVersion(archive.version)
        }

        var proxyIDMap: [UUID: UUID] = [:]
        for proxy in archive.proxies {
            let existing = savedProxies.first(where: {
                $0.id == proxy.id || $0.name.caseInsensitiveCompare(proxy.name) == .orderedSame
            })
            proxyIDMap[proxy.id] = existing?.id ?? proxy.id
        }

        var existingByKey: [RemoteDeduplicationKey: UUID] = [:]
        for profile in sessions {
            let key = RemoteDeduplicationKey(
                host: profile.resolvedHost,
                port: profile.port,
                username: profile.username
            )
            if existingByKey[key] == nil { existingByKey[key] = profile.id }
        }
        var idMap: [UUID: UUID] = [:]
        for remote in archive.remotes {
            let key = RemoteDeduplicationKey(host: remote.host, port: remote.port, username: remote.username)
            let finalID = existingByKey[key] ?? (sessions.contains { $0.id == remote.id } ? UUID() : remote.id)
            idMap[remote.id] = finalID
            existingByKey[key] = finalID
        }

        var added = 0
        var updated = 0
        for remote in archive.remotes {
            guard let finalID = idMap[remote.id] else { continue }
            let old = sessions.first(where: { $0.id == finalID })
            var profile = old ?? SessionProfile()
            profile.id = finalID
            profile.name = remote.name
            profile.host = remote.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "127.0.0.1" : remote.host
            profile.port = remote.port
            profile.username = remote.username
            profile.authentication = AuthenticationMethod(rawValue: remote.authentication) ?? .agent
            profile.hostKeyPolicy = HostKeyPolicy(rawValue: remote.hostKeyPolicy) ?? .ask
            profile.keepAliveSeconds = remote.keepAliveSeconds
            profile.accentHex = remote.accentHex
            profile.remoteGroup = RemoteGroupName.normalized(remote.remoteGroup)
            profile.remoteIcon = remote.remoteIcon.flatMap(RemoteIcon.init(rawValue:))
            profile.terminalConnectionMethod = TerminalConnectionMethod(rawValue: remote.connectionMethod) ?? .ssh
            profile.jumpRemoteID = remote.jumpRemoteID.flatMap { idMap[$0] ?? $0 }
            profile.sshJumpMode = remote.sshJumpMode.flatMap(SSHJumpMode.init(rawValue:))
            profile.savedProxyID = remote.savedProxyID.flatMap { proxyIDMap[$0] ?? $0 }
            profile.proxyType = remote.proxyType.flatMap(SSHProxyType.init(rawValue:))
            profile.proxyHost = remote.proxyHost
            profile.proxyPort = remote.proxyPort
            profile.tailscaleLoginServer = remote.tailscaleLoginServer
            profile.tailscaleHostname = remote.tailscaleHostname
            profile.moshCommand = remote.moshCommand
            profile.moshServerCommand = remote.moshServerCommand
            profile.jumpMoshCommand = remote.jumpMoshCommand
            if let index = sessions.firstIndex(where: { $0.id == finalID }) {
                sessions[index] = profile
                updated += 1
            } else {
                sessions.append(profile)
                added += 1
            }
        }

        for portable in archive.proxies {
            guard let type = SSHProxyType(rawValue: portable.type) else { continue }
            let finalID = proxyIDMap[portable.id] ?? portable.id
            let proxy = NetworkProxyProfile(
                id: finalID,
                name: portable.name,
                type: type,
                host: portable.host,
                port: portable.port,
                tailscaleAuthKey: nil,
                tailscaleLoginServer: portable.tailscaleLoginServer,
                tailscaleHostname: portable.tailscaleHostname
            )
            if let index = savedProxies.firstIndex(where: { $0.id == finalID }) {
                var preserved = proxy
                preserved.id = savedProxies[index].id
                preserved.tailscaleAuthKey = savedProxies[index].tailscaleAuthKey
                savedProxies[index] = preserved
            } else {
                savedProxies.append(proxy)
            }
        }
        SessionStore.save(sessions)
        NetworkProxyStore.save(savedProxies)
        selectedSessionID = sessions.first?.id ?? localSessionID
        return (added, updated)
    }
}
