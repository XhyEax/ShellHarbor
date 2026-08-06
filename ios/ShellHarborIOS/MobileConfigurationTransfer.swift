import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
    var remoteStartPath: String?
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
    var jumpMoshServerCommand: String? = nil
    var moshUDPPort: String? = nil
    var inspectionEnabled: Bool? = nil
    var inspectionIntervalMinutes: Int? = nil
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

struct ShellHarborConfigurationDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw ConfigurationTransferError.invalidArchive
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension RemoteStore {
    func exportedConfigurationData(proxyStore: MobileProxyStore) throws -> Data {
        let archive = ShellHarborConfigurationArchive(
            remotes: remotes.map { remote in
                PortableRemote(
                    id: remote.id,
                    name: remote.name,
                    host: remote.host.isEmpty ? "127.0.0.1" : remote.host,
                    port: remote.port,
                    username: remote.username,
                    remoteStartPath: remote.remoteStartPath.isEmpty ? nil : remote.remoteStartPath,
                    authentication: remote.authentication.rawValue,
                    hostKeyPolicy: remote.hostKeyPolicy.rawValue,
                    keepAliveSeconds: remote.keepAliveSeconds,
                    accentHex: remote.accentHex,
                    remoteGroup: remote.remoteGroup.isEmpty ? nil : remote.remoteGroup,
                    remoteIcon: remote.remoteIcon.rawValue,
                    connectionMethod: remote.connectionMethod.rawValue,
                    jumpRemoteID: remote.jumpRemoteID,
                    sshJumpMode: remote.portableSSHJumpMode,
                    savedProxyID: remote.savedProxyID,
                    proxyType: remote.proxyType == .none ? nil : remote.proxyType.rawValue,
                    proxyHost: remote.proxyHost,
                    proxyPort: remote.proxyPort,
                    tailscaleLoginServer: remote.tailscaleLoginServer,
                    tailscaleHostname: remote.tailscaleNodeName,
                    moshCommand: remote.portableMoshCommand,
                    moshServerCommand: remote.moshServerCommand,
                    jumpMoshCommand: remote.portableJumpMoshCommand,
                    jumpMoshServerCommand: remote.jumpMoshServerCommand.isEmpty
                        ? nil
                        : remote.jumpMoshServerCommand,
                    moshUDPPort: remote.moshUDPPort.isEmpty ? nil : remote.moshUDPPort,
                    inspectionEnabled: remote.inspectionEnabled,
                    inspectionIntervalMinutes: remote.inspectionIntervalMinutes
                )
            },
            proxies: proxyStore.proxies.map { proxy in
                PortableProxy(
                    id: proxy.id,
                    name: proxy.name,
                    type: proxy.type.rawValue,
                    host: proxy.host,
                    port: proxy.port,
                    tailscaleLoginServer: proxy.tailscaleLoginServer,
                    tailscaleHostname: proxy.tailscaleNodeName
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(archive)
    }

    @discardableResult
    func importConfigurationData(
        _ data: Data,
        proxyStore: MobileProxyStore
    ) throws -> (added: Int, updated: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(ShellHarborConfigurationArchive.self, from: data) else {
            throw ConfigurationTransferError.invalidArchive
        }
        guard archive.version <= ShellHarborConfigurationArchive.currentVersion else {
            throw ConfigurationTransferError.unsupportedVersion(archive.version)
        }
        let proxyIDMap = proxyStore.importPortableProfiles(archive.proxies)

        var existingByKey: [RemoteDeduplicationKey: UUID] = [:]
        for remote in remotes {
            let key = RemoteDeduplicationKey(host: remote.host, port: remote.port, username: remote.username)
            if existingByKey[key] == nil { existingByKey[key] = remote.id }
        }
        var idMap: [UUID: UUID] = [:]
        for remote in archive.remotes {
            let key = RemoteDeduplicationKey(host: remote.host, port: remote.port, username: remote.username)
            let finalID = existingByKey[key] ?? (remotes.contains { $0.id == remote.id } ? UUID() : remote.id)
            idMap[remote.id] = finalID
            existingByKey[key] = finalID
        }

        var added = 0
        var updated = 0
        for portable in archive.remotes {
            guard let finalID = idMap[portable.id] else { continue }
            let old = remotes.first(where: { $0.id == finalID })
            var remote = old ?? MobileRemoteProfile()
            remote.id = finalID
            remote.name = portable.name
            remote.host = portable.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "127.0.0.1" : portable.host
            remote.port = portable.port
            remote.username = portable.username
            remote.remoteStartPath = portable.remoteStartPath ?? ""
            remote.remoteGroup = portable.remoteGroup ?? ""
            remote.remoteIcon = portable.remoteIcon.flatMap(MobileRemoteIcon.init(rawValue:)) ?? .server
            remote.accentHex = portable.accentHex
            remote.authentication = MobileAuthentication(rawValue: portable.authentication) ?? .privateKey
            remote.hostKeyPolicy = MobileHostKeyPolicy(rawValue: portable.hostKeyPolicy) ?? .ask
            remote.keepAliveSeconds = max(0, portable.keepAliveSeconds)
            remote.connectionMethod = MobileConnectionMethod(rawValue: portable.connectionMethod) ?? .ssh
            remote.jumpRemoteID = portable.jumpRemoteID.flatMap { idMap[$0] ?? $0 }
            remote.savedProxyID = portable.savedProxyID.flatMap { proxyIDMap[$0] ?? $0 }
            remote.proxyType = portable.proxyType.flatMap(MobileProxyType.init(rawValue:)) ?? .none
            remote.proxyHost = portable.proxyHost ?? "127.0.0.1"
            remote.proxyPort = portable.proxyPort ?? 1080
            remote.tailscaleLoginServer = portable.tailscaleLoginServer ?? ""
            remote.tailscaleNodeName = portable.tailscaleHostname ?? ""
            remote.moshServerCommand = portable.moshServerCommand ?? "mosh-server"
            remote.jumpMoshServerCommand = portable.jumpMoshServerCommand ?? ""
            remote.moshUDPPort = portable.moshUDPPort ?? ""
            remote.portableSSHJumpMode = portable.sshJumpMode
            remote.portableMoshCommand = portable.moshCommand
            remote.portableJumpMoshCommand = portable.jumpMoshCommand
            if let inspectionEnabled = portable.inspectionEnabled {
                remote.inspectionEnabled = inspectionEnabled
            }
            if let interval = portable.inspectionIntervalMinutes {
                remote.inspectionIntervalMinutes = max(1, interval)
            }
            if let index = remotes.firstIndex(where: { $0.id == finalID }) {
                remotes[index] = remote
                updated += 1
            } else {
                remotes.append(remote)
                added += 1
            }
        }
        persist()
        return (added, updated)
    }
}
