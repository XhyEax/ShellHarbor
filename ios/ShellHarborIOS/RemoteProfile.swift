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

enum MobileSSHJumpMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case sshJump
    case forward

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sshJump: "SSH Jump（默认）"
        case .forward: "Forward（ProxyCommand）"
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
    case agent

    var id: String { rawValue }
    var title: String {
        switch self {
        case .password: "密码"
        case .privateKey: "私钥"
        case .agent: "SSH Agent"
        }
    }
}

enum MobileHostKeyPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask
    case acceptNew
    case strict

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "未知主机时询问"
        case .acceptNew: "自动接受新主机"
        case .strict: "严格校验"
        }
    }

    var explanation: String {
        switch self {
        case .ask:
            "已信任的密钥会直接校验；首次连接或主机密钥变化时弹窗确认。"
        case .acceptNew:
            "首次出现的主机密钥会自动保存；主机密钥变化时仍会弹窗确认。"
        case .strict:
            "仅允许连接设置中已有且完全匹配的主机密钥。"
        }
    }
}

enum MobileRemoteIcon: String, Codable, CaseIterable, Identifiable, Sendable {
    case server
    case macOS
    case iPhone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .server: "服务器"
        case .macOS: "PC"
        case .iPhone: "iPhone"
        }
    }

    var symbol: String {
        switch self {
        case .server: "server.rack"
        case .macOS: "desktopcomputer"
        case .iPhone: "iphone"
        }
    }
}

enum MobileRemoteGroupName {
    static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "未分组" ? "" : trimmed
    }

    static func key(_ value: String) -> String {
        normalized(value).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}

enum MobileRemoteMoveDirection {
    case up
    case down
}

struct MobileRemoteGroupSection: Identifiable {
    let id: String
    let name: String
    let remotes: [MobileRemoteProfile]

    static func sections(from remotes: [MobileRemoteProfile]) -> [Self] {
        var displayNames: [String: String] = [:]
        var buckets: [String: [MobileRemoteProfile]] = [:]
        var order: [String] = []
        for remote in remotes {
            let name = MobileRemoteGroupName.normalized(remote.remoteGroup)
            let key = MobileRemoteGroupName.key(name)
            if buckets[key] == nil {
                order.append(key)
                displayNames[key] = name
                buckets[key] = []
            }
            buckets[key, default: []].append(remote)
        }
        let ungroupedKey = MobileRemoteGroupName.key("")
        if let index = order.firstIndex(of: ungroupedKey) {
            order.append(order.remove(at: index))
        }
        return order.compactMap { key in
            guard let name = displayNames[key], let remotes = buckets[key] else { return nil }
            return Self(id: key, name: name, remotes: remotes)
        }
    }
}

struct MobileRemoteProfile: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name = "新 Remote"
    var host = "127.0.0.1"
    var port = 22
    var username = ""
    var remoteStartPath = ""
    var remoteGroup = ""
    var remoteIcon = MobileRemoteIcon.server
    var accentHex = "#4F8CFF"
    var authentication = MobileAuthentication.privateKey
    var identityKeyID: UUID?
    var password = ""
    var hostKeyPolicy = MobileHostKeyPolicy.ask
    var keepAliveSeconds = 30
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
    var jumpMoshServerCommand = ""
    var moshUDPPort = ""
    // Preserved when configurations travel through iOS. The embedded iOS
    // transport does not launch an external local mosh binary or OpenSSH
    // ProxyJump, but a later export must not discard the macOS settings.
    var portableSSHJumpMode: String?
    var portableMoshCommand: String?
    var portableJumpMoshCommand: String?
    var inspectionEnabled = false
    var inspectionIntervalMinutes = 15

    init() {}

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, remoteStartPath, remoteGroup, remoteIcon, accentHex
        case authentication, identityKeyID, password, hostKeyPolicy, keepAliveSeconds
        case connectionMethod, jumpRemoteID, savedProxyID, proxyType, proxyName, proxyHost, proxyPort
        case tailscaleLoginServer, tailscaleNodeName, tailscaleAuthKey
        case moshServerCommand, jumpMoshServerCommand, moshUDPPort
        case portableSSHJumpMode, portableMoshCommand, portableJumpMoshCommand
        case inspectionEnabled, inspectionIntervalMinutes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "新 Remote"
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
        remoteStartPath = try values.decodeIfPresent(String.self, forKey: .remoteStartPath) ?? ""
        remoteGroup = try values.decodeIfPresent(String.self, forKey: .remoteGroup) ?? ""
        remoteIcon = try values.decodeIfPresent(MobileRemoteIcon.self, forKey: .remoteIcon) ?? .server
        accentHex = try values.decodeIfPresent(String.self, forKey: .accentHex) ?? "#4F8CFF"
        authentication = try values.decodeIfPresent(MobileAuthentication.self, forKey: .authentication) ?? .privateKey
        identityKeyID = try values.decodeIfPresent(UUID.self, forKey: .identityKeyID)
        password = try values.decodeIfPresent(String.self, forKey: .password) ?? ""
        hostKeyPolicy = try values.decodeIfPresent(MobileHostKeyPolicy.self, forKey: .hostKeyPolicy) ?? .ask
        keepAliveSeconds = max(0, try values.decodeIfPresent(Int.self, forKey: .keepAliveSeconds) ?? 30)
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
        jumpMoshServerCommand = try values.decodeIfPresent(String.self, forKey: .jumpMoshServerCommand) ?? ""
        moshUDPPort = try values.decodeIfPresent(String.self, forKey: .moshUDPPort) ?? ""
        portableSSHJumpMode = try values.decodeIfPresent(String.self, forKey: .portableSSHJumpMode)
        portableMoshCommand = try values.decodeIfPresent(String.self, forKey: .portableMoshCommand)
        portableJumpMoshCommand = try values.decodeIfPresent(String.self, forKey: .portableJumpMoshCommand)
        inspectionEnabled = try values.decodeIfPresent(Bool.self, forKey: .inspectionEnabled) ?? false
        inspectionIntervalMinutes = max(
            1,
            try values.decodeIfPresent(Int.self, forKey: .inspectionIntervalMinutes) ?? 15
        )
    }

    var endpoint: String {
        "\(username.isEmpty ? "user" : username)@\(host):\(port)"
    }

    var hostKeyEndpoint: String {
        "\(host.isEmpty ? "127.0.0.1" : host):\(port)"
    }

    var availableConnectionMethods: [MobileConnectionMethod] {
        MobileConnectionMethod.allCases.filter {
            $0 != .jumpMosh || jumpRemoteID != nil
        }
    }

    var sshJumpMode: MobileSSHJumpMode {
        get {
            portableSSHJumpMode.flatMap(MobileSSHJumpMode.init(rawValue:)) ??
                .sshJump
        }
        set {
            portableSSHJumpMode = newValue.rawValue
        }
    }

    mutating func normalizeConnectionMethodForJumpRemote() {
        if jumpRemoteID == nil, connectionMethod == .jumpMosh {
            connectionMethod = .mosh
        }
    }
}

@MainActor
@Observable
final class RemoteStore {
    var remotes: [MobileRemoteProfile] = []
    var sessions: [MobileSession] = []
    private let tailscaleProxyManager = MobileTailscaleProxyManager.shared
    private let restorationURL: URL
    private var didRestoreSessions = false
    private var restorationSaveTask: Task<Void, Never>?

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
        var normalizedProfile = profile
        normalizedProfile.normalizeConnectionMethodForJumpRemote()
        if let index = remotes.firstIndex(where: { $0.id == normalizedProfile.id }) {
            remotes[index] = normalizedProfile
        } else {
            remotes.append(normalizedProfile)
        }
        for session in sessions where session.remote.id == normalizedProfile.id {
            session.remoteName = normalizedProfile.name
            session.remoteIcon = normalizedProfile.remoteIcon
            session.accentHex = normalizedProfile.accentHex
        }
        persist()
    }

    @discardableResult
    func duplicate(_ profile: MobileRemoteProfile) -> MobileRemoteProfile {
        var copy = profile
        copy.id = UUID()
        copy.name += " 副本"
        copy.password = ""
        remotes.append(copy)
        persist()
        return copy
    }

    func delete(at offsets: IndexSet) {
        delete(ids: Set(offsets.compactMap { remotes.indices.contains($0) ? remotes[$0].id : nil }))
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for session in sessions where ids.contains(session.remote.id) {
            session.controller.disconnect()
        }
        sessions.removeAll { ids.contains($0.remote.id) }
        remotes.removeAll { ids.contains($0.id) }
        for index in remotes.indices where remotes[index].jumpRemoteID.map(ids.contains) == true {
            remotes[index].jumpRemoteID = nil
            remotes[index].normalizeConnectionMethodForJumpRemote()
        }
        persist()
        persistSessionRestoration()
    }

    func move(_ ids: Set<UUID>, toGroup group: String) {
        let normalized = MobileRemoteGroupName.normalized(group)
        for index in remotes.indices where ids.contains(remotes[index].id) {
            remotes[index].remoteGroup = normalized
        }
        persist()
    }

    func moveRemotes(
        _ ids: Set<UUID>,
        direction: MobileRemoteMoveDirection
    ) {
        guard !ids.isEmpty else { return }
        for group in MobileRemoteGroupSection.sections(from: remotes) {
            let groupIDs = Set(group.remotes.map(\.id))
            let selectedIDs = ids.intersection(groupIDs)
            guard !selectedIDs.isEmpty else { continue }
            let indices = remotes.indices.filter { groupIDs.contains(remotes[$0].id) }
            var values = indices.map { remotes[$0] }
            switch direction {
            case .up:
                guard values.count > 1 else { continue }
                for index in 1..<values.count where
                    selectedIDs.contains(values[index].id) &&
                    !selectedIDs.contains(values[index - 1].id) {
                    values.swapAt(index, index - 1)
                }
            case .down:
                guard values.count > 1 else { continue }
                for index in stride(from: values.count - 2, through: 0, by: -1) where
                    selectedIDs.contains(values[index].id) &&
                    !selectedIDs.contains(values[index + 1].id) {
                    values.swapAt(index, index + 1)
                }
            }
            for (index, value) in zip(indices, values) { remotes[index] = value }
        }
        persist()
    }

    func reorderRemotes(
        inGroup groupName: String,
        from source: IndexSet,
        to destination: Int
    ) {
        let groupKey = MobileRemoteGroupName.key(groupName)
        let indices = remotes.indices.filter {
            MobileRemoteGroupName.key(remotes[$0].remoteGroup) == groupKey
        }
        guard !indices.isEmpty else { return }
        var values = indices.map { remotes[$0] }
        values.move(fromOffsets: source, toOffset: destination)
        for (index, value) in zip(indices, values) { remotes[index] = value }
        persist()
    }

    func renameGroup(_ currentName: String, to newName: String) {
        let normalized = MobileRemoteGroupName.normalized(newName)
        guard !normalized.isEmpty else { return }
        for index in remotes.indices where
            MobileRemoteGroupName.key(remotes[index].remoteGroup) == MobileRemoteGroupName.key(currentName)
        {
            remotes[index].remoteGroup = normalized
        }
        persist()
    }

    func removeGroup(named name: String) {
        for index in remotes.indices where
            MobileRemoteGroupName.key(remotes[index].remoteGroup) == MobileRemoteGroupName.key(name)
        {
            remotes[index].remoteGroup = ""
        }
        persist()
    }

    func detachSavedProxy(_ proxy: MobileProxyProfile) {
        var changed = false
        for index in remotes.indices where remotes[index].savedProxyID == proxy.id {
            remotes[index].savedProxyID = nil
            remotes[index].proxyType = proxy.type
            remotes[index].proxyName = proxy.name
            remotes[index].proxyHost = proxy.host
            remotes[index].proxyPort = proxy.port
            remotes[index].tailscaleLoginServer = proxy.tailscaleLoginServer
            remotes[index].tailscaleNodeName = proxy.tailscaleNodeName
            remotes[index].tailscaleAuthKey = proxy.tailscaleAuthKey
            changed = true
        }
        if changed { persist() }
    }

    func clearIdentityKeyReferences(_ keyID: UUID) {
        var changed = false
        for index in remotes.indices where remotes[index].identityKeyID == keyID {
            remotes[index].identityKeyID = nil
            changed = true
        }
        if changed { persist() }
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
        let nextSessionNumber =
            (sessions
                .filter { $0.remote.id == remote.id }
                .map(\.sessionNumber)
                .max() ?? 0) + 1
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
            sessionNumber: nextSessionNumber,
            startupCommand: startupCommand,
            nameSuffix: nameSuffix
        )
        sessions.append(session)
        observeRestoration(of: session)
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

    @discardableResult
    func closeSession(id: UUID) -> UUID? {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        sessions[index].controller.disconnect()
        sessions.remove(at: index)
        persistSessionRestoration()
        guard !sessions.isEmpty else { return nil }
        return sessions[min(index, sessions.count - 1)].id
    }

    func closeOtherSessions(keeping id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        for session in sessions where session.id != id {
            session.controller.disconnect()
        }
        sessions.removeAll { $0.id != id }
        persistSessionRestoration()
    }

    func closeSessionsAfter(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              index + 1 < sessions.count else { return }
        for session in sessions[(index + 1)...] {
            session.controller.disconnect()
        }
        sessions.removeSubrange((index + 1)...)
        persistSessionRestoration()
    }

    func moveSessions(from offsets: IndexSet, to destination: Int) {
        sessions.move(fromOffsets: offsets, toOffset: destination)
        persistSessionRestoration()
    }

    func persist() {
        let data = try? JSONEncoder().encode(remotes)
        UserDefaults.standard.set(data, forKey: "mobileRemotes")
    }

    func prewarmTailscale(proxyStore: MobileProxyStore) async {
        let profiles = remotes.map(proxyStore.resolved)
        await tailscaleProxyManager.prewarm(profiles)
    }

    func tailscaleStatus(
        for proxy: MobileProxyProfile
    ) async -> (state: MobileTailscaleConnectionState, nodeName: String, error: String?) {
        var profile = MobileRemoteProfile()
        profile.proxyType = .tailscale
        profile.proxyName = proxy.name
        profile.tailscaleLoginServer = proxy.tailscaleLoginServer
        profile.tailscaleNodeName = proxy.tailscaleNodeName
        profile.tailscaleAuthKey = proxy.tailscaleAuthKey
        let state = await tailscaleProxyManager.connectionState(for: profile)
        let nodeName = await tailscaleProxyManager.effectiveNodeName(for: profile)
        let error = await tailscaleProxyManager.connectionError(for: profile)
        return (state, nodeName, error)
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
            var remote = record.remote
            if let current = remotes.first(where: { $0.id == remote.id }) {
                remote.name = current.name
                remote.remoteIcon = current.remoteIcon
                remote.accentHex = current.accentHex
            }
            let jump = record.jumpRemote.map { saved in
                var restored = saved
                if let current = remotes.first(where: { $0.id == saved.id }) {
                    restored.name = current.name
                    restored.remoteIcon = current.remoteIcon
                    restored.accentHex = current.accentHex
                }
                return restored
            }
            let session = makeSession(
                sessionID: record.sessionID,
                remote: remote,
                keyStore: keyStore,
                jumpRemote: jump,
                knownHostStore: knownHostStore,
                restoredOutputHistory: record.terminalHistory,
                restoredPendingCommand: record.pendingCommand,
                restoredDirectory: record.terminalDirectory,
                restoredLocalPath: record.localPath,
                restoredMoshState: record.moshState,
                restoredMoshServerPort: record.moshServerPort,
                restoredMoshKey: Self.decryptedRestorationKey(record.moshKey),
                sessionNumber: record.sessionNumber ?? (
                    (sessions
                        .filter { $0.remote.id == remote.id }
                        .map(\.sessionNumber)
                        .max() ?? 0) + 1
                ),
                nameSuffix: record.nameSuffix
            )
            session.selectedView = MobileSession.ViewMode(rawValue: record.selectedView) ?? .terminal
            session.fileBrowser.restorePath(record.remotePath)
            session.controller.title = record.terminalTitle
            session.controller.lastDirectory = record.terminalDirectory
            sessions.append(session)
            observeRestoration(of: session)
            if record.shouldReconnect {
                // A restored background Session must resume its connection
                // even before SwiftTerm is mounted. When its terminal view is
                // opened later, connect(output:) replaces this sink and
                // replays the retained terminal history into that view.
                session.controller.connect { _ in }
            }
        }
    }

    private func observeRestoration(of session: MobileSession) {
        session.controller.onRestorationChanged = { [weak self] in
            self?.scheduleSessionRestorationSave()
        }
    }

    func resumeSessionsAfterSuspension(_ sessionIDs: Set<UUID>) {
        for session in sessions where sessionIDs.contains(session.id) {
            switch session.controller.state {
            case .connecting:
                continue
            case .connected, .idle, .disconnected, .failed:
                // iOS can preserve the NIO channel object while suspending its
                // underlying socket. Recreate the connection after activation
                // instead of trusting a stale `.connected` state that fails on
                // the first read with NIOConnectionError.
                session.controller.reconnect()
            }
        }
    }

    private func scheduleSessionRestorationSave() {
        restorationSaveTask?.cancel()
        restorationSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            guard let self else { return }
            self.persistSessionRestoration()
            self.restorationSaveTask = nil
        }
    }

    func persistSessionRestoration() {
        restorationSaveTask?.cancel()
        restorationSaveTask = nil
        let records = sessions.map { session in
            MobileSessionRestoration(
                sessionID: session.id,
                remote: session.remote,
                jumpRemote: session.jumpRemote,
                selectedView: session.selectedView.rawValue,
                remotePath: session.fileBrowser.currentPath,
                localPath: session.localFileBrowser.relativePath,
                terminalTitle: session.controller.title,
                terminalDirectory: session.controller.lastDirectory,
                terminalHistory: session.controller.restorationOutputHistory(),
                pendingCommand: session.controller.restorationPendingCommand(),
                moshState: session.controller.restorationMoshState(),
                moshServerPort: session.controller.restorationMoshServerPort(),
                moshKey: session.controller.restorationMoshKey().flatMap {
                    try? MobilePasswordCipher.encrypt($0)
                },
                shouldReconnect: session.controller.hasConnectionIntent,
                sessionNumber: session.sessionNumber,
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
        sessionID: UUID,
        remote: MobileRemoteProfile,
        keyStore: ImportedKeyStore,
        jumpRemote: MobileRemoteProfile?,
        knownHostStore: KnownHostStore,
        restoredOutputHistory: Data,
        restoredPendingCommand: String?,
        restoredDirectory: String?,
        restoredLocalPath: String,
        restoredMoshState: Data,
        restoredMoshServerPort: Int?,
        restoredMoshKey: String?,
        sessionNumber: Int,
        nameSuffix: String?
    ) -> MobileSession {
        MobileSession(
            id: sessionID,
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
            sessionNumber: sessionNumber,
            restoredOutputHistory: restoredOutputHistory,
            restoredPendingCommand: restoredPendingCommand,
            restoredDirectory: restoredDirectory,
            restoredLocalPath: restoredLocalPath,
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
    var sessionID: UUID
    var remote: MobileRemoteProfile
    var jumpRemote: MobileRemoteProfile?
    var selectedView: String
    var remotePath: String
    var localPath: String
    var terminalTitle: String
    var terminalDirectory: String?
    var terminalHistory: Data
    var pendingCommand: String?
    var moshState: Data
    var moshServerPort: Int?
    var moshKey: String?
    var shouldReconnect: Bool
    var sessionNumber: Int?
    var nameSuffix: String?

    private enum CodingKeys: String, CodingKey {
        case sessionID, remote, jumpRemote, selectedView, remotePath, localPath
        case terminalTitle, terminalDirectory, terminalHistory, pendingCommand, moshState
        case moshServerPort, moshKey, shouldReconnect, sessionNumber, nameSuffix
    }

    init(
        sessionID: UUID,
        remote: MobileRemoteProfile,
        jumpRemote: MobileRemoteProfile?,
        selectedView: String,
        remotePath: String,
        localPath: String,
        terminalTitle: String,
        terminalDirectory: String?,
        terminalHistory: Data,
        pendingCommand: String?,
        moshState: Data,
        moshServerPort: Int?,
        moshKey: String?,
        shouldReconnect: Bool,
        sessionNumber: Int,
        nameSuffix: String?
    ) {
        self.sessionID = sessionID
        self.remote = remote
        self.jumpRemote = jumpRemote
        self.selectedView = selectedView
        self.remotePath = remotePath
        self.localPath = localPath
        self.terminalTitle = terminalTitle
        self.terminalDirectory = terminalDirectory
        self.terminalHistory = terminalHistory
        self.pendingCommand = pendingCommand
        self.moshState = moshState
        self.moshServerPort = moshServerPort
        self.moshKey = moshKey
        self.shouldReconnect = shouldReconnect
        self.sessionNumber = sessionNumber
        self.nameSuffix = nameSuffix
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try values.decodeIfPresent(UUID.self, forKey: .sessionID) ?? UUID()
        remote = try values.decode(MobileRemoteProfile.self, forKey: .remote)
        jumpRemote = try values.decodeIfPresent(MobileRemoteProfile.self, forKey: .jumpRemote)
        selectedView = try values.decodeIfPresent(String.self, forKey: .selectedView) ?? "terminal"
        remotePath = try values.decodeIfPresent(String.self, forKey: .remotePath) ?? "."
        localPath = try values.decodeIfPresent(String.self, forKey: .localPath) ?? ""
        terminalTitle = try values.decodeIfPresent(String.self, forKey: .terminalTitle) ?? ""
        terminalDirectory = try values.decodeIfPresent(String.self, forKey: .terminalDirectory)
        terminalHistory = try values.decodeIfPresent(Data.self, forKey: .terminalHistory) ?? Data()
        pendingCommand = try values.decodeIfPresent(String.self, forKey: .pendingCommand)
        moshState = try values.decodeIfPresent(Data.self, forKey: .moshState) ?? Data()
        moshServerPort = try values.decodeIfPresent(Int.self, forKey: .moshServerPort)
        moshKey = try values.decodeIfPresent(String.self, forKey: .moshKey)
        shouldReconnect = try values.decodeIfPresent(
            Bool.self,
            forKey: .shouldReconnect
        ) ?? true
        sessionNumber = try values.decodeIfPresent(Int.self, forKey: .sessionNumber)
        nameSuffix = try values.decodeIfPresent(String.self, forKey: .nameSuffix)
    }
}

@MainActor
@Observable
final class MobileSession: Identifiable {
    enum ViewMode: String, CaseIterable, Identifiable {
        case terminal
        case files
        case workspace
        case inspection
        var id: String { rawValue }
        var title: String {
            switch self {
            case .terminal: "终端"
            case .files: "文件"
            case .workspace: "工作台"
            case .inspection: "巡检日志"
            }
        }
        var icon: String {
            switch self {
            case .terminal: "terminal"
            case .files: "arrow.left.arrow.right"
            case .workspace: "rectangle.split.2x1"
            case .inspection: "waveform.path.ecg"
            }
        }
    }

    let id: UUID
    let remote: MobileRemoteProfile
    let jumpRemote: MobileRemoteProfile?
    let createdAt = Date()
    let controller: MobileSSHController
    let fileBrowser: MobileSFTPBrowser
    let localFileBrowser: MobileLocalFileBrowser
    var remoteName: String
    var remoteIcon: MobileRemoteIcon
    var accentHex: String
    let sessionNumber: Int
    var nameSuffix: String?
    var commandHistory: [MobileCommandHistoryEntry] = []
    var commandHistorySearch = ""
    var isLoadingCommandHistory = false
    var selectedView = ViewMode.terminal {
        didSet {
            UserDefaults.standard.set(
                selectedView.rawValue,
                forKey: "mobileSelectedView.\(remote.id.uuidString)"
            )
        }
    }

    init(
        id: UUID = UUID(),
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
        sessionNumber: Int = 1,
        restoredOutputHistory: Data = Data(),
        restoredPendingCommand: String? = nil,
        restoredDirectory: String? = nil,
        restoredLocalPath: String = "",
        restoredMoshState: Data = Data(),
        restoredMoshServerPort: Int? = nil,
        restoredMoshKey: String? = nil,
        startupCommand: String? = nil,
        nameSuffix: String? = nil
    ) {
        self.id = id
        self.remote = remote
        remoteName = remote.name
        remoteIcon = remote.remoteIcon
        accentHex = remote.accentHex
        self.sessionNumber = sessionNumber
        self.jumpRemote = jumpRemote
        self.nameSuffix = nameSuffix
        selectedView = UserDefaults.standard.string(
            forKey: "mobileSelectedView.\(remote.id.uuidString)"
        ).flatMap(ViewMode.init(rawValue:)) ?? .terminal
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
            restoredPendingCommand: restoredPendingCommand,
            restoredDirectory: restoredDirectory,
            restoredMoshState: restoredMoshState,
            restoredMoshServerPort: restoredMoshServerPort,
            restoredMoshKey: restoredMoshKey,
            startupCommand: startupCommand
        )
        self.controller = controller
        fileBrowser = MobileSFTPBrowser(
            ssh: controller,
            remoteID: remote.id,
            defaultPath: remote.remoteStartPath
        )
        localFileBrowser = MobileLocalFileBrowser(remoteID: remote.id, relativePath: restoredLocalPath)
    }

    var displayName: String {
        "\(remoteName) · \(sessionLabel)"
    }

    var sessionLabel: String {
        guard let nameSuffix, !nameSuffix.isEmpty else { return String(sessionNumber) }
        return nameSuffix
    }
}
