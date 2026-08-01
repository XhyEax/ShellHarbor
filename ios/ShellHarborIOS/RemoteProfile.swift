import Foundation
import Observation

enum MobileConnectionMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case ssh
    case mosh
    case jumpMosh

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ssh: "SSH"
        case .mosh: "Mosh"
        case .jumpMosh: "跳板 Mosh → SSH 目标"
        }
    }
}

enum MobileProxyType: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case socks5
    case httpConnect
    case tailscale

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "无"
        case .socks5: "SOCKS5"
        case .httpConnect: "HTTP CONNECT"
        case .tailscale: "Tailscale"
        }
    }
}

enum MobileAuthentication: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case privateKey

    var id: String { rawValue }
    var title: String { self == .password ? "密码" : "私钥" }
}

struct MobileRemoteProfile: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name = "新 Remote"
    var host = "127.0.0.1"
    var port = 22
    var username = ""
    var remoteGroup = ""
    var authentication = MobileAuthentication.privateKey
    var identityKeyID: UUID?
    var password = ""
    var connectionMethod = MobileConnectionMethod.ssh
    var jumpRemoteID: UUID?
    var savedProxyID: UUID?
    var proxyType = MobileProxyType.none
    var proxyName = ""
    var proxyHost = "127.0.0.1"
    var proxyPort = 1080
    var tailscaleLoginServer = ""
    var tailscaleNodeName = ""
    var tailscaleAuthKey = ""
    var moshServerCommand = "mosh-server"
    var moshUDPPort = ""

    init() {}

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, remoteGroup, authentication, identityKeyID, password
        case connectionMethod, jumpRemoteID, savedProxyID, proxyType, proxyName, proxyHost, proxyPort
        case tailscaleLoginServer, tailscaleNodeName, tailscaleAuthKey
        case moshServerCommand, moshUDPPort
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "新 Remote"
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
        remoteGroup = try values.decodeIfPresent(String.self, forKey: .remoteGroup) ?? ""
        authentication = try values.decodeIfPresent(MobileAuthentication.self, forKey: .authentication) ?? .privateKey
        identityKeyID = try values.decodeIfPresent(UUID.self, forKey: .identityKeyID)
        password = try values.decodeIfPresent(String.self, forKey: .password) ?? ""
        connectionMethod = try values.decodeIfPresent(MobileConnectionMethod.self, forKey: .connectionMethod) ?? .ssh
        jumpRemoteID = try values.decodeIfPresent(UUID.self, forKey: .jumpRemoteID)
        savedProxyID = try values.decodeIfPresent(UUID.self, forKey: .savedProxyID)
        proxyType = try values.decodeIfPresent(MobileProxyType.self, forKey: .proxyType) ?? .none
        proxyName = try values.decodeIfPresent(String.self, forKey: .proxyName) ?? ""
        proxyHost = try values.decodeIfPresent(String.self, forKey: .proxyHost) ?? "127.0.0.1"
        proxyPort = try values.decodeIfPresent(Int.self, forKey: .proxyPort) ?? 1080
        tailscaleLoginServer = try values.decodeIfPresent(String.self, forKey: .tailscaleLoginServer) ?? ""
        tailscaleNodeName = try values.decodeIfPresent(String.self, forKey: .tailscaleNodeName) ?? ""
        tailscaleAuthKey = try values.decodeIfPresent(String.self, forKey: .tailscaleAuthKey) ?? ""
        moshServerCommand = try values.decodeIfPresent(String.self, forKey: .moshServerCommand) ?? "mosh-server"
        moshUDPPort = try values.decodeIfPresent(String.self, forKey: .moshUDPPort) ?? ""
    }

    var endpoint: String {
        "\(username.isEmpty ? "user" : username)@\(host):\(port)"
    }

    var hostKeyEndpoint: String {
        "\(host.isEmpty ? "127.0.0.1" : host):\(port)"
    }
}

@MainActor
@Observable
final class RemoteStore {
    var remotes: [MobileRemoteProfile] = []
    var sessions: [MobileSession] = []
    private let tailscaleProxyManager = MobileTailscaleProxyManager()
    private let restorationURL: URL
    private var didRestoreSessions = false

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        restorationURL = support
            .appendingPathComponent("ShellHarbor", isDirectory: true)
            .appendingPathComponent("mobile-session-restoration.json")
        guard
            let data = UserDefaults.standard.data(forKey: "mobileRemotes"),
            let decoded = try? JSONDecoder().decode(
                [MobileRemoteProfile].self,
                from: data
            )
        else { return }
        remotes = decoded
    }

    func save(_ profile: MobileRemoteProfile) {
        if let index = remotes.firstIndex(where: { $0.id == profile.id }) {
            remotes[index] = profile
        } else {
            remotes.append(profile)
        }
        for session in sessions where session.remote.id == profile.id {
            session.remoteName = profile.name
        }
        persist()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            remotes.remove(at: index)
        }
        persist()
    }

    func delete(ids: Set<UUID>) {
        remotes.removeAll { ids.contains($0.id) }
        persist()
    }

    func move(_ ids: Set<UUID>, toGroup group: String) {
        let normalized = group.trimmingCharacters(in: .whitespacesAndNewlines)
        for index in remotes.indices where ids.contains(remotes[index].id) {
            remotes[index].remoteGroup = normalized
        }
        persist()
    }

    @discardableResult
    func openSession(
        for remote: MobileRemoteProfile,
        identityURL: URL?,
        jumpRemote: MobileRemoteProfile?,
        jumpIdentityURL: URL?,
        trustedHostKey: String?,
        trustedJumpHostKey: String?,
        trustHostKey: @escaping @MainActor (String) -> Void,
        trustJumpHostKey: @escaping @MainActor (String) -> Void,
        autoTrustNewHosts: Bool = false,
        startupCommand: String? = nil,
        nameSuffix: String? = nil
    ) -> MobileSession {
        let session = MobileSession(
            remote: remote,
            identityURL: identityURL,
            jumpRemote: jumpRemote,
            jumpIdentityURL: jumpIdentityURL,
            trustedHostKey: trustedHostKey,
            trustedJumpHostKey: trustedJumpHostKey,
            trustHostKey: trustHostKey,
            trustJumpHostKey: trustJumpHostKey,
            autoTrustNewHosts: autoTrustNewHosts,
            tailscaleProxyManager: tailscaleProxyManager,
            startupCommand: startupCommand,
            nameSuffix: nameSuffix
        )
        sessions.append(session)
        persistSessionRestoration()
        return session
    }

    func closeSessions(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            sessions[index].controller.disconnect()
            sessions.remove(at: index)
        }
        persistSessionRestoration()
    }

    func persist() {
        let data = try? JSONEncoder().encode(remotes)
        UserDefaults.standard.set(data, forKey: "mobileRemotes")
    }

    func restoreSessions(
        keyStore: ImportedKeyStore,
        knownHostStore: KnownHostStore
    ) {
        guard !didRestoreSessions else { return }
        didRestoreSessions = true
        guard let data = try? Data(contentsOf: restorationURL),
              let records = try? JSONDecoder().decode([MobileSessionRestoration].self, from: data) else {
            return
        }
        for record in records {
            let remote = remotes.first(where: { $0.id == record.remote.id }) ?? record.remote
            let jump = record.jumpRemote.flatMap { saved in
                remotes.first(where: { $0.id == saved.id }) ?? saved
            }
            let session = makeSession(
                remote: remote,
                keyStore: keyStore,
                jumpRemote: jump,
                knownHostStore: knownHostStore,
                restoredOutputHistory: record.terminalHistory,
                restoredDirectory: record.terminalDirectory,
                restoredMoshState: record.moshState,
                restoredMoshServerPort: record.moshServerPort,
                restoredMoshKey: Self.decryptedRestorationKey(record.moshKey),
                nameSuffix: record.nameSuffix
            )
            session.selectedView = MobileSession.ViewMode(rawValue: record.selectedView) ?? .terminal
            session.fileBrowser.currentPath = record.remotePath
            session.controller.title = record.terminalTitle
            session.controller.lastDirectory = record.terminalDirectory
            sessions.append(session)
        }
    }

    func persistSessionRestoration() {
        let records = sessions.map { session in
            MobileSessionRestoration(
                remote: session.remote,
                jumpRemote: session.jumpRemote,
                selectedView: session.selectedView.rawValue,
                remotePath: session.fileBrowser.currentPath,
                terminalTitle: session.controller.title,
                terminalDirectory: session.controller.lastDirectory,
                terminalHistory: session.controller.restorationOutputHistory(),
                moshState: session.controller.restorationMoshState(),
                moshServerPort: session.controller.restorationMoshServerPort(),
                moshKey: session.controller.restorationMoshKey().flatMap {
                    try? MobilePasswordCipher.encrypt($0)
                },
                nameSuffix: session.nameSuffix
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: restorationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            try JSONEncoder().encode(records).write(
                to: restorationURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            // A failed restoration snapshot must not interrupt an active terminal.
        }
    }

    private func makeSession(
        remote: MobileRemoteProfile,
        keyStore: ImportedKeyStore,
        jumpRemote: MobileRemoteProfile?,
        knownHostStore: KnownHostStore,
        restoredOutputHistory: Data,
        restoredDirectory: String?,
        restoredMoshState: Data,
        restoredMoshServerPort: Int?,
        restoredMoshKey: String?,
        nameSuffix: String?
    ) -> MobileSession {
        MobileSession(
            remote: remote,
            identityURL: keyStore.keyURL(forID: remote.identityKeyID),
            jumpRemote: jumpRemote,
            jumpIdentityURL: keyStore.keyURL(forID: jumpRemote?.identityKeyID),
            trustedHostKey: knownHostStore.key(for: remote.hostKeyEndpoint),
            trustedJumpHostKey: jumpRemote.flatMap { knownHostStore.key(for: $0.hostKeyEndpoint) },
            trustHostKey: { key in knownHostStore.trust(key, for: remote.hostKeyEndpoint) },
                trustJumpHostKey: { key in
                guard let jumpRemote else { return }
                knownHostStore.trust(key, for: jumpRemote.hostKeyEndpoint)
                },
                autoTrustNewHosts: knownHostStore.autoTrustNewHosts,
            tailscaleProxyManager: tailscaleProxyManager,
            restoredOutputHistory: restoredOutputHistory,
            restoredDirectory: restoredDirectory,
            restoredMoshState: restoredMoshState,
            restoredMoshServerPort: restoredMoshServerPort,
            restoredMoshKey: restoredMoshKey,
            nameSuffix: nameSuffix
        )
    }

    private static func decryptedRestorationKey(_ stored: String?) -> String? {
        guard let stored, !stored.isEmpty else { return nil }
        guard MobilePasswordCipher.isEncrypted(stored) else { return stored }
        return try? MobilePasswordCipher.decrypt(stored)
    }
}

private struct MobileSessionRestoration: Codable {
    var remote: MobileRemoteProfile
    var jumpRemote: MobileRemoteProfile?
    var selectedView: String
    var remotePath: String
    var terminalTitle: String
    var terminalDirectory: String?
    var terminalHistory: Data
    var moshState: Data
    var moshServerPort: Int?
    var moshKey: String?
    var nameSuffix: String?

    private enum CodingKeys: String, CodingKey {
        case remote, jumpRemote, selectedView, remotePath
        case terminalTitle, terminalDirectory, terminalHistory, moshState
        case moshServerPort, moshKey, nameSuffix
    }

    init(
        remote: MobileRemoteProfile,
        jumpRemote: MobileRemoteProfile?,
        selectedView: String,
        remotePath: String,
        terminalTitle: String,
        terminalDirectory: String?,
        terminalHistory: Data,
        moshState: Data,
        moshServerPort: Int?,
        moshKey: String?,
        nameSuffix: String?
    ) {
        self.remote = remote
        self.jumpRemote = jumpRemote
        self.selectedView = selectedView
        self.remotePath = remotePath
        self.terminalTitle = terminalTitle
        self.terminalDirectory = terminalDirectory
        self.terminalHistory = terminalHistory
        self.moshState = moshState
        self.moshServerPort = moshServerPort
        self.moshKey = moshKey
        self.nameSuffix = nameSuffix
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        remote = try values.decode(MobileRemoteProfile.self, forKey: .remote)
        jumpRemote = try values.decodeIfPresent(MobileRemoteProfile.self, forKey: .jumpRemote)
        selectedView = try values.decodeIfPresent(String.self, forKey: .selectedView) ?? "terminal"
        remotePath = try values.decodeIfPresent(String.self, forKey: .remotePath) ?? "."
        terminalTitle = try values.decodeIfPresent(String.self, forKey: .terminalTitle) ?? ""
        terminalDirectory = try values.decodeIfPresent(String.self, forKey: .terminalDirectory)
        terminalHistory = try values.decodeIfPresent(Data.self, forKey: .terminalHistory) ?? Data()
        moshState = try values.decodeIfPresent(Data.self, forKey: .moshState) ?? Data()
        moshServerPort = try values.decodeIfPresent(Int.self, forKey: .moshServerPort)
        moshKey = try values.decodeIfPresent(String.self, forKey: .moshKey)
        nameSuffix = try values.decodeIfPresent(String.self, forKey: .nameSuffix)
    }
}

@MainActor
@Observable
final class MobileSession: Identifiable {
    enum ViewMode: String, CaseIterable, Identifiable {
        case terminal
        case files
        case inspection
        var id: String { rawValue }
        var title: String {
            switch self {
            case .terminal: "终端"
            case .files: "文件"
            case .inspection: "巡检"
            }
        }
    }

    let id = UUID()
    let remote: MobileRemoteProfile
    let jumpRemote: MobileRemoteProfile?
    let createdAt = Date()
    let controller: MobileSSHController
    let fileBrowser: MobileSFTPBrowser
    var remoteName: String
    var nameSuffix: String?
    var selectedView = ViewMode.terminal

    init(
        remote: MobileRemoteProfile,
        identityURL: URL?,
        jumpRemote: MobileRemoteProfile?,
        jumpIdentityURL: URL?,
        trustedHostKey: String?,
        trustedJumpHostKey: String?,
        trustHostKey: @escaping @MainActor (String) -> Void,
        trustJumpHostKey: @escaping @MainActor (String) -> Void,
        autoTrustNewHosts: Bool = false,
        tailscaleProxyManager: MobileTailscaleProxyManager,
        restoredOutputHistory: Data = Data(),
        restoredDirectory: String? = nil,
        restoredMoshState: Data = Data(),
        restoredMoshServerPort: Int? = nil,
        restoredMoshKey: String? = nil,
        startupCommand: String? = nil,
        nameSuffix: String? = nil
    ) {
        self.remote = remote
        remoteName = remote.name
        self.jumpRemote = jumpRemote
        self.nameSuffix = nameSuffix
        let controller = MobileSSHController(
            remote: remote,
            identityURL: identityURL,
            jumpRemote: jumpRemote,
            jumpIdentityURL: jumpIdentityURL,
            trustedHostKey: trustedHostKey,
            trustedJumpHostKey: trustedJumpHostKey,
            trustHostKey: trustHostKey,
            trustJumpHostKey: trustJumpHostKey,
            autoTrustNewHosts: autoTrustNewHosts,
            tailscaleProxyManager: tailscaleProxyManager,
            restoredOutputHistory: restoredOutputHistory,
            restoredDirectory: restoredDirectory,
            restoredMoshState: restoredMoshState,
            restoredMoshServerPort: restoredMoshServerPort,
            restoredMoshKey: restoredMoshKey,
            startupCommand: startupCommand
        )
        self.controller = controller
        fileBrowser = MobileSFTPBrowser(ssh: controller)
    }

    var displayName: String {
        guard let nameSuffix, !nameSuffix.isEmpty else { return remoteName }
        return "\(remoteName) · \(nameSuffix)"
    }
}
