import AppKit
import Foundation

enum RemoteMoveDirection {
    case up
    case down
}

@MainActor
final class AppState: ObservableObject {
    /// Persisted Remote definitions. The historical property name is kept to
    /// avoid a migration of the on-disk JSON format.
    @Published var sessions: [SessionProfile]
    @Published var savedProxies: [NetworkProxyProfile]
    @Published var selectedSessionID: UUID?
    @Published var editingSession: SessionProfile?
    @Published var showingSessionEditor = false
    @Published var showingLocalSettings = false
    @Published var notice: String?
    @Published private(set) var globalLocalPathHistory: [String] =
        UserDefaults.standard.stringArray(forKey: "globalLocalPathHistory") ?? []
    @Published var shcliLinkEnabled = SHCLILinkPreferences.savedEnabled {
        didSet {
            SHCLILinkPreferences.save(enabled: shcliLinkEnabled)
            synchronizeSHCLILink()
        }
    }
    @Published private(set) var shcliLinkStatus = ""
    @Published private(set) var shcliLinkStatusIsError = false
    @Published private(set) var remoteMultiplexerSessions:
        [UUID: [RemoteMultiplexerSession]] = [:]
    @Published private(set) var loadingMultiplexerRemoteIDs = Set<UUID>()
    @Published private(set) var activeWorkspaceIDs: [UUID] = []
    @Published var selectedWorkspaceID: UUID?
    @Published private(set) var inspectionRecords = InspectionStore.load()
    @Published private(set) var inspectingRemoteIDs = Set<UUID>()
    @Published var terminalTheme = TerminalTheme.saved {
        didSet {
            UserDefaults.standard.set(
                terminalTheme.rawValue,
                forKey: "terminalTheme"
            )
        }
    }
    @Published var terminalFont = TerminalFontFamily.saved {
        didSet {
            TerminalFontFamily.save(terminalFont)
        }
    }
    @Published var terminalFontSize = TerminalFontSizeSettings.savedSize {
        didSet {
            let normalized = TerminalFontSizeSettings.normalized(
                terminalFontSize
            )
            if terminalFontSize != normalized {
                terminalFontSize = normalized
                return
            }
            TerminalFontSizeSettings.save(normalized)
        }
    }
    @Published var terminalScrollbackLines =
        TerminalScrollbackSettings.savedLines {
        didSet {
            let normalized = TerminalScrollbackSettings.normalized(
                terminalScrollbackLines
            )
            if terminalScrollbackLines != normalized {
                terminalScrollbackLines = normalized
                return
            }
            TerminalScrollbackSettings.save(normalized)
            fallbackTerminal.setScrollbackLines(normalized)
            for workspace in activeWorkspaces {
                workspace.terminal.setScrollbackLines(normalized)
            }
        }
    }
    @Published var localShell: LocalShell {
        didSet {
            UserDefaults.standard.set(
                localShell.rawValue,
                forKey: "localShell"
            )
            let profile = localProfile
            for workspace in activeWorkspaces where
                workspace.remoteID == localRemoteID
            {
                workspace.updateProfile(profile)
            }
        }
    }
    @Published var localStartPath: String {
        didSet {
            UserDefaults.standard.set(localStartPath, forKey: "localStartPath")
            let profile = localProfile
            for workspace in activeWorkspaces where
                workspace.remoteID == localRemoteID
            {
                workspace.updateProfile(profile)
            }
        }
    }

    private var workspaces: [UUID: SessionWorkspace] = [:]
    private var lastWorkspaceByRemote: [UUID: UUID] = [:]
    private var inspectionTasks: [UUID: Task<Void, Never>] = [:]
    private var transferControls: [UUID: CommandProcessControl] = [:]
    private var restorationSaveTask: Task<Void, Never>?
    private let tailscaleProxyManager = TailscaleProxyManager()
    private let fallbackTerminal = TerminalController()
    private let localRemoteID = UUID(
        uuidString: "4C4F4341-4C53-5348-0000-000000000022"
    )!

    var selectedSession: SessionProfile? {
        sessions.first(where: { $0.id == selectedSessionID })
    }

    var selectedWorkspace: SessionWorkspace? {
        guard let selectedWorkspaceID else { return nil }
        return workspaces[selectedWorkspaceID]
    }

    var activeWorkspaces: [SessionWorkspace] {
        activeWorkspaceIDs.compactMap { workspaces[$0] }
    }

    var globalRecentLocalDirectories: [String] {
        var seen = Set<String>()
        let transferDirectories = TransferRecentDirectoryResolver.localDirectories(
            from: activeWorkspaces.flatMap(\.transfers)
        )
        return (globalLocalPathHistory + transferDirectories).filter {
            seen.insert($0).inserted
        }
    }

    func activeSessionCount(for remoteID: UUID) -> Int {
        activeWorkspaces.lazy.filter { $0.remoteID == remoteID }.count
    }

    func hasInteractiveConnection(for remoteID: UUID) -> Bool {
        activeWorkspaces.contains {
            $0.remoteID == remoteID && $0.terminal.state == .connected
        }
    }

    /// Convenience for app menu commands.
    var terminal: TerminalController {
        selectedWorkspace?.terminal ?? fallbackTerminal
    }

    var localSessionID: UUID {
        localRemoteID
    }

    var isLocalSelected: Bool {
        selectedSessionID == localRemoteID
    }

    var localProfile: SessionProfile {
        var profile = SessionProfile.local(id: localRemoteID, shell: localShell)
        let path = localStartPath.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.remoteStartPath = path.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.path
            : NSString(string: path).expandingTildeInPath
        return profile
    }

    func isPersistedRemote(_ remoteID: UUID) -> Bool {
        sessions.contains(where: { $0.id == remoteID })
    }

    func jumpProfile(for profile: SessionProfile) -> SessionProfile? {
        guard
            let jumpRemoteID = profile.jumpRemoteID,
            jumpRemoteID != profile.id
        else {
            return nil
        }
        return sessions.first(where: { $0.id == jumpRemoteID })
    }

    init() {
        let loaded = SessionStore.load()
        sessions = loaded
        savedProxies = NetworkProxyStore.load()
        localShell = .saved
        let localDirectoryMigrationKey =
            "localStartPathUsesHomeDefaultV1"
        let savedLocalStartPath = UserDefaults.standard.string(
            forKey: "localStartPath"
        )
        if
            !UserDefaults.standard.bool(forKey: localDirectoryMigrationKey),
            savedLocalStartPath == "/"
        {
            localStartPath = "~"
        } else {
            localStartPath = savedLocalStartPath ?? "~"
        }
        UserDefaults.standard.set(true, forKey: localDirectoryMigrationKey)
        selectedSessionID = loaded.first?.id ?? localRemoteID
        for profile in loaded {
            scheduleInspection(for: profile, runImmediately: true)
        }
        restoreSessionWorkspaces()
        synchronizeSHCLILink()
    }

    private func synchronizeSHCLILink() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            shcliLinkStatus = "打包后的 App 会自动管理 /opt/homebrew/bin/shcli。"
            shcliLinkStatusIsError = false
            return
        }
        SHCLILinkManager.removeManagedLegacyLink()
        do {
            try SHCLILinkManager.synchronize(enabled: shcliLinkEnabled)
            shcliLinkStatus = shcliLinkEnabled
                ? "已链接，可在终端直接运行 shcli。"
                : "链接已关闭。"
            shcliLinkStatusIsError = false
        } catch {
            shcliLinkStatus = error.localizedDescription
            shcliLinkStatusIsError = true
        }
    }

    func addSession() {
        var profile = SessionProfile()
        profile.name = "Remote \(sessions.count + 1)"
        editingSession = profile
        showingSessionEditor = true
    }

    func editSelectedSession() {
        guard let selectedSession else { return }
        editingSession = selectedSession
        showingSessionEditor = true
    }

    func editRemote(_ remoteID: UUID) {
        guard let profile = sessions.first(where: { $0.id == remoteID }) else {
            return
        }
        selectedSessionID = remoteID
        editingSession = profile
        showingSessionEditor = true
    }

    func saveEditedSession(_ draft: SessionProfile) {
        var profile = draft
        profile.host = draft.resolvedHost
        if
            profile.resolvedProxyType == .tailscale,
            (profile.tailscaleHostname ?? "").trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        {
            profile.tailscaleHostname = TailscaleNodeIdentity.name
        }
        if profile.resolvedProxyType == .tailscale {
            profile.tailscaleLoginServer = TailscaleLoginServer.normalized(
                profile.tailscaleLoginServer
            )
        }
        profile.remoteGroup = RemoteGroupName.normalized(
            draft.remoteGroup
        )
        if profile.isProxyEnabled {
            profile.proxyHost = draft.resolvedProxyHost
            profile.proxyPort = profile.resolvedProxyType == .tailscale
                ? SSHProxyType.tailscale.defaultPort
                : draft.resolvedProxyPort
        }
        if
            profile.jumpRemoteID == profile.id ||
            (
                profile.jumpRemoteID != nil &&
                !sessions.contains(where: {
                    $0.id == profile.jumpRemoteID
                })
            )
        {
            profile.jumpRemoteID = nil
        }
        if
            profile.jumpRemoteID == nil,
            profile.terminalConnectionMethod == .jumpMosh
        {
            profile.terminalConnectionMethod = .mosh
            profile.moshJumpMode = nil
        }
        if let index = sessions.firstIndex(where: { $0.id == profile.id }) {
            sessions[index] = profile
        } else {
            sessions.append(profile)
        }
        for workspace in activeWorkspaces {
            guard
                let current = sessions.first(where: {
                    $0.id == workspace.remoteID
                })
            else {
                continue
            }
            workspace.updateProfile(current)
            workspace.updateJumpProfile(jumpProfile(for: current))
        }
        selectedSessionID = profile.id
        SessionStore.save(sessions)
        scheduleInspection(for: profile, runImmediately: true)
        editingSession = nil
        showingSessionEditor = false
    }

    @discardableResult
    func saveProxy(
        named name: String,
        from draft: SessionProfile
    ) -> NetworkProxyProfile? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, draft.isProxyConfigurationValid else {
            return nil
        }
        var normalizedDraft = draft
        if
            normalizedDraft.resolvedProxyType == .tailscale,
            (normalizedDraft.tailscaleHostname ?? "").trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        {
            normalizedDraft.tailscaleHostname = TailscaleNodeIdentity.name
        }
        if normalizedDraft.resolvedProxyType == .tailscale {
            normalizedDraft.tailscaleLoginServer =
                TailscaleLoginServer.normalized(
                    normalizedDraft.tailscaleLoginServer
                )
        }
        var proxy = NetworkProxyProfile(name: normalized, from: normalizedDraft)
        let matchingID = draft.savedProxyID ?? savedProxies.first(where: {
            $0.name.caseInsensitiveCompare(normalized) == .orderedSame
        })?.id
        if
            let existingID = matchingID,
            let index = savedProxies.firstIndex(where: { $0.id == existingID })
        {
            proxy.id = existingID
            savedProxies[index] = proxy
            for sessionIndex in sessions.indices where
                sessions[sessionIndex].savedProxyID == existingID
            {
                sessions[sessionIndex] = proxy.applying(to: sessions[sessionIndex])
            }
            SessionStore.save(sessions)
            for workspace in activeWorkspaces {
                guard
                    let current = sessions.first(where: {
                        $0.id == workspace.remoteID
                    })
                else { continue }
                workspace.updateProfile(current)
                workspace.updateJumpProfile(jumpProfile(for: current))
            }
        } else {
            savedProxies.append(proxy)
        }
        NetworkProxyStore.save(savedProxies)
        return proxy
    }

    func deleteSavedProxy(_ proxyID: UUID) {
        guard savedProxies.contains(where: { $0.id == proxyID }) else { return }
        for index in sessions.indices where sessions[index].savedProxyID == proxyID {
            // The resolved fields already contain a full copy of the shared
            // Proxy. Only detach the reference so existing Remotes continue
            // to connect with their current configuration.
            sessions[index].savedProxyID = nil
        }
        savedProxies.removeAll { $0.id == proxyID }
        NetworkProxyStore.save(savedProxies)
        SessionStore.save(sessions)
        for workspace in activeWorkspaces {
            guard let current = sessions.first(where: { $0.id == workspace.remoteID }) else {
                continue
            }
            workspace.updateProfile(current)
            workspace.updateJumpProfile(jumpProfile(for: current))
        }
    }

    func duplicateSelectedSession() {
        guard var copy = selectedSession else { return }
        copy.id = UUID()
        copy.name += " 副本"
        copy.password = ""
        sessions.append(copy)
        selectedSessionID = copy.id
        SessionStore.save(sessions)
        scheduleInspection(for: copy, runImmediately: true)
    }

    func setDefaultConnectionMethod(
        _ method: TerminalConnectionMethod,
        for remoteID: UUID
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == remoteID }) else {
            return
        }
        if method == .jumpMosh, sessions[index].jumpRemoteID == nil {
            return
        }
        sessions[index].terminalConnectionMethod = method
        switch method {
        case .ssh:
            sessions[index].moshJumpMode = nil
        case .mosh:
            sessions[index].moshJumpMode = .directTarget
        case .jumpMosh:
            sessions[index].moshJumpMode = .moshOnJump
        }
        SessionStore.save(sessions)
    }

    func deleteSelectedSession() {
        guard let remoteID = selectedSessionID else { return }
        deleteRemotes([remoteID])
    }

    func deleteRemotes(_ remoteIDs: Set<UUID>) {
        guard !remoteIDs.isEmpty else { return }
        let relatedSessionIDs = activeWorkspaces
            .filter { remoteIDs.contains($0.remoteID) }
            .map(\.id)
        for sessionID in relatedSessionIDs {
            closeWorkspace(sessionID)
        }
        sessions.removeAll { remoteIDs.contains($0.id) }
        for index in sessions.indices where
            sessions[index].jumpRemoteID.map(remoteIDs.contains) == true
        {
            sessions[index].jumpRemoteID = nil
        }
        for workspace in activeWorkspaces {
            guard
                let profile = sessions.first(where: {
                    $0.id == workspace.remoteID
                })
            else {
                continue
            }
            workspace.updateProfile(profile)
            workspace.updateJumpProfile(jumpProfile(for: profile))
        }
        for remoteID in remoteIDs {
            lastWorkspaceByRemote.removeValue(forKey: remoteID)
            inspectionTasks[remoteID]?.cancel()
            inspectionTasks.removeValue(forKey: remoteID)
        }
        inspectionRecords.removeAll { remoteIDs.contains($0.remoteID) }
        InspectionStore.save(inspectionRecords)

        if let selectedWorkspace {
            selectedSessionID = selectedWorkspace.remoteID
        } else if
            let selectedSessionID,
            sessions.contains(where: { $0.id == selectedSessionID })
        {
            self.selectedSessionID = selectedSessionID
        } else {
            selectSession(sessions.first?.id ?? localRemoteID)
        }
        SessionStore.save(sessions)
    }

    func inspectionRecords(for remoteID: UUID) -> [InspectionRecord] {
        inspectionRecords.filter { $0.remoteID == remoteID }
    }

    func latestInspectionRecord(
        for remoteID: UUID
    ) -> InspectionRecord? {
        inspectionRecords.first { $0.remoteID == remoteID }
    }

    func inspectNow(_ remoteID: UUID) {
        Task { await performInspection(remoteID: remoteID) }
    }

    func clearInspectionRecords(for remoteID: UUID) {
        inspectionRecords.removeAll { $0.remoteID == remoteID }
        InspectionStore.save(inspectionRecords)
    }

    private func scheduleInspection(
        for profile: SessionProfile,
        runImmediately: Bool
    ) {
        inspectionTasks[profile.id]?.cancel()
        inspectionTasks.removeValue(forKey: profile.id)
        guard profile.resolvedInspectionEnabled else { return }

        let remoteID = profile.id
        let interval = profile.resolvedInspectionIntervalMinutes
        inspectionTasks[remoteID] = Task { [weak self] in
            if runImmediately {
                await self?.performInspection(remoteID: remoteID)
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        for: .seconds(Double(interval * 60))
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.performInspection(remoteID: remoteID)
            }
        }
    }

    private func performInspection(remoteID: UUID) async {
        guard
            !inspectingRemoteIDs.contains(remoteID),
            var profile = sessions.first(where: { $0.id == remoteID })
        else {
            return
        }
        inspectingRemoteIDs.insert(remoteID)
        var jump = jumpProfile(for: profile)
        do {
            if var routingJump = jump {
                if let port = try await tailscaleProxyManager.ensureRunning(
                    for: routingJump
                ) {
                    routingJump.proxyPort = port
                    jump = routingJump
                }
            } else if let port = try await tailscaleProxyManager.ensureRunning(
                for: profile
            ) {
                profile.proxyPort = port
            }
        } catch {
            inspectingRemoteIDs.remove(remoteID)
            return
        }
        let record = await InspectionService.inspect(
            profile: profile,
            jumpProfile: jump
        )
        inspectingRemoteIDs.remove(remoteID)

        inspectionRecords.insert(record, at: 0)
        var perRemoteCount: [UUID: Int] = [:]
        inspectionRecords = inspectionRecords.filter { record in
            let count = perRemoteCount[record.remoteID, default: 0]
            guard count < 1_000 else { return false }
            perRemoteCount[record.remoteID] = count + 1
            return true
        }
        InspectionStore.save(inspectionRecords)
    }

    func moveRemotes(
        _ remoteIDs: Set<UUID>,
        direction: RemoteMoveDirection
    ) {
        guard !remoteIDs.isEmpty else { return }
        sessions.moveRemotesWithinGroups(
            remoteIDs,
            direction: direction
        )
        SessionStore.save(sessions)
    }

    func reorderRemote(
        _ remoteID: UUID,
        relativeTo targetID: UUID,
        placeAfter: Bool
    ) {
        guard remoteID != targetID else { return }
        if
            let sourceIndex = sessions.firstIndex(where: {
                $0.id == remoteID
            }),
            let target = sessions.first(where: { $0.id == targetID })
        {
            sessions[sourceIndex].remoteGroup =
                RemoteGroupName.normalized(target.remoteGroup)
        }
        sessions.reorderRemote(
            remoteID,
            relativeTo: targetID,
            placeAfter: placeAfter
        )
        SessionStore.save(sessions)
    }

    func assignRemotes(
        _ remoteIDs: Set<UUID>,
        toGroup group: String?
    ) {
        guard !remoteIDs.isEmpty else { return }
        let normalizedGroup = RemoteGroupName.normalized(group)
        for index in sessions.indices where
            remoteIDs.contains(sessions[index].id)
        {
            sessions[index].remoteGroup = normalizedGroup
        }
        for workspace in activeWorkspaces where
            remoteIDs.contains(workspace.remoteID)
        {
            if let profile = sessions.first(where: {
                $0.id == workspace.remoteID
            }) {
                workspace.updateProfile(profile)
            }
        }
        SessionStore.save(sessions)
    }

    func renameRemoteGroup(
        _ currentName: String,
        to newName: String
    ) {
        let updatedRemoteIDs = sessions.renameRemoteGroup(
            currentName,
            to: newName
        )
        guard !updatedRemoteIDs.isEmpty else { return }
        for workspace in activeWorkspaces where
            updatedRemoteIDs.contains(workspace.remoteID)
        {
            if let profile = sessions.first(where: {
                $0.id == workspace.remoteID
            }) {
                workspace.updateProfile(profile)
            }
        }
        SessionStore.save(sessions)
    }

    func selectSession(_ id: UUID?) {
        defer { scheduleSessionRestorationSave() }
        selectedSessionID = id
        guard let remoteID = id else {
            selectedWorkspaceID = nil
            return
        }
        if
            let rememberedID = lastWorkspaceByRemote[remoteID],
            workspaces[rememberedID] != nil
        {
            selectedWorkspaceID = rememberedID
            return
        }
        if let latest = activeWorkspaces.last(where: { $0.remoteID == remoteID }) {
            selectedWorkspaceID = latest.id
            lastWorkspaceByRemote[remoteID] = latest.id
        } else {
            selectedWorkspaceID = nil
        }
    }

    /// Double-clicking a Remote always creates a new independent Session.
    func connect(to remoteID: UUID) {
        openWorkspace(for: remoteID)
    }

    func openWorkspace(for remoteID: UUID) {
        let profile =
            remoteID == localRemoteID
                ? localProfile
                : sessions.first(where: { $0.id == remoteID })
        guard let profile else {
            return
        }
        openWorkspace(profile: profile)
    }

    private func openWorkspace(
        profile: SessionProfile,
        restoration: RestorableSessionSnapshot? = nil,
        multiplexer: TerminalMultiplexer? = nil,
        multiplexerSessionName: String? = nil,
        shouldSelect: Bool = true
    ) {
        let remoteID = profile.id
        let nextNumber = restoration?.sessionNumber ?? (
            (activeWorkspaces
                .filter { $0.remoteID == remoteID }
                .map(\.sessionNumber)
                .max() ?? 0) + 1
        )
        let workspace = SessionWorkspace(
            profile: profile,
            jumpProfile: jumpProfile(for: profile),
            sessionNumber: nextNumber,
            multiplexer: restoration?.multiplexer ?? multiplexer,
            id: restoration?.workspaceID ?? UUID()
        )
        if let multiplexerSessionName {
            workspace.rename(to: multiplexerSessionName)
        }
        workspace.terminal.setScrollbackLines(terminalScrollbackLines)
        if let restoration {
            workspace.applyRestoration(restoration)
        }
        workspace.terminal.onRestorationChanged = { [weak self] in
            self?.scheduleSessionRestorationSave()
        }
        workspaces[workspace.id] = workspace
        activeWorkspaceIDs.append(workspace.id)
        if shouldSelect {
            selectedWorkspaceID = workspace.id
            selectedSessionID = remoteID
        }
        lastWorkspaceByRemote[remoteID] = workspace.id
        workspace.prepareIfNeeded()
        rememberLocalPath(for: workspace)
        startConnection(in: workspace)
        scheduleSessionRestorationSave()
    }

    func selectWorkspace(_ workspaceID: UUID) {
        guard let workspace = workspaces[workspaceID] else { return }
        selectedWorkspaceID = workspaceID
        selectedSessionID = workspace.remoteID
        lastWorkspaceByRemote[workspace.remoteID] = workspaceID
        scheduleSessionRestorationSave()
    }

    func reorderWorkspace(
        _ workspaceID: UUID,
        relativeTo targetID: UUID,
        placeAfter: Bool
    ) {
        activeWorkspaceIDs.reorderWorkspace(
            workspaceID,
            relativeTo: targetID,
            placeAfter: placeAfter
        )
        scheduleSessionRestorationSave()
    }

    func closeWorkspace(_ workspaceID: UUID) {
        guard
            let index = activeWorkspaceIDs.firstIndex(of: workspaceID),
            let workspace = workspaces[workspaceID]
        else { return }
        workspace.terminal.disconnect(appendMessage: false)
        workspace.portForwards.stopAll()
        workspaces.removeValue(forKey: workspaceID)
        activeWorkspaceIDs.remove(at: index)
        if lastWorkspaceByRemote[workspace.remoteID] == workspaceID {
            if let replacementForRemote = activeWorkspaces.last(where: {
                $0.remoteID == workspace.remoteID
            }) {
                lastWorkspaceByRemote[workspace.remoteID] = replacementForRemote.id
            } else {
                lastWorkspaceByRemote.removeValue(forKey: workspace.remoteID)
            }
        }

        guard selectedWorkspaceID == workspaceID else {
            saveSessionRestorationNow()
            return
        }
        if activeWorkspaceIDs.isEmpty {
            selectedWorkspaceID = nil
        } else {
            let replacementIndex = min(index, activeWorkspaceIDs.count - 1)
            let replacementID = activeWorkspaceIDs[replacementIndex]
            selectedWorkspaceID = replacementID
            if let replacement = workspaces[replacementID] {
                selectedSessionID = replacement.remoteID
            }
        }
        saveSessionRestorationNow()
    }

    func closeOtherWorkspaces(keeping workspaceID: UUID) {
        guard activeWorkspaceIDs.contains(workspaceID) else { return }
        for id in activeWorkspaceIDs
            .workspaceIDsExcluding(workspaceID)
            .reversed()
        {
            closeWorkspace(id)
        }
        selectWorkspace(workspaceID)
    }

    func closeWorkspacesToRight(of workspaceID: UUID) {
        for id in activeWorkspaceIDs
            .workspaceIDsToRight(of: workspaceID)
            .reversed()
        {
            closeWorkspace(id)
        }
    }

    func newSession() {
        if isLocalSelected {
            openWorkspace(profile: localProfile)
        } else if let selectedSession {
            openWorkspace(profile: selectedSession)
        } else if sessions.isEmpty {
            openWorkspace(profile: localProfile)
        } else {
            notice = "请先从左侧选择一个 Remote。"
        }
    }

    func newSession(for remoteID: UUID) {
        if remoteID == localRemoteID {
            openWorkspace(profile: localProfile)
        } else if let profile = sessions.first(where: { $0.id == remoteID }) {
            selectSession(remoteID)
            openWorkspace(profile: profile)
        }
    }

    func launchMultiplexer(
        _ multiplexer: TerminalMultiplexer,
        for remoteID: UUID,
        sessionName: String? = nil
    ) {
        guard
            remoteID != localRemoteID,
            let profile = sessions.first(where: { $0.id == remoteID })
        else { return }
        selectSession(remoteID)
        openWorkspace(
            profile: profile,
            multiplexer: multiplexer,
            multiplexerSessionName: sessionName
        )
    }

    func refreshMultiplexerSessions(for remoteID: UUID) {
        guard
            remoteID != localRemoteID,
            !loadingMultiplexerRemoteIDs.contains(remoteID),
            let storedProfile = sessions.first(where: { $0.id == remoteID })
        else { return }
        loadingMultiplexerRemoteIDs.insert(remoteID)
        Task { [weak self] in
            guard let self else { return }
            defer { loadingMultiplexerRemoteIDs.remove(remoteID) }
            var profile = storedProfile
            var jumpProfile = jumpProfile(for: profile)
            do {
                if var jump = jumpProfile {
                    if let port = try await tailscaleProxyManager.ensureRunning(for: jump) {
                        jump.proxyPort = port
                        jumpProfile = jump
                    }
                } else if let port = try await tailscaleProxyManager.ensureRunning(for: profile) {
                    profile.proxyPort = port
                }
                let invocation = try SSHCommandBuilder.ssh(
                    profile: profile,
                    jumpProfile: jumpProfile,
                    command: RemoteMultiplexerSessionService.listingCommand,
                    connectionTimeoutSeconds: 8,
                    batchMode: true
                )
                let result = try await CommandRunner.run(invocation)
                remoteMultiplexerSessions[remoteID] =
                    RemoteMultiplexerSessionService.parse(result.output)
            } catch {
                remoteMultiplexerSessions[remoteID] = []
            }
        }
    }

    func reconnect() {
        guard let workspace = selectedWorkspace else {
            notice = "请先选择一个已打开的 Session。"
            return
        }
        reconnect(workspace)
    }

    func reconnect(_ workspace: SessionWorkspace) {
        startConnection(in: workspace)
    }

    func disconnect() {
        selectedWorkspace?.terminal.disconnect()
    }

    func startPortForward(
        _ rule: PortForwardRule,
        in workspace: SessionWorkspace
    ) {
        Task { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            var profile = workspace.connectionProfile
            var jumpProfile = workspace.connectionJumpProfile
            do {
                if var routingJump = jumpProfile {
                    if let port = try await tailscaleProxyManager.ensureRunning(
                        for: routingJump
                    ) {
                        routingJump.proxyPort = port
                        jumpProfile = routingJump
                    }
                } else if let port = try await tailscaleProxyManager.ensureRunning(
                    for: profile
                ) {
                    profile.proxyPort = port
                }
            } catch {
                workspace.portForwards.fail(
                    rule.id,
                    message: error.localizedDescription
                )
                return
            }
            guard self.workspaces[workspace.id] === workspace else { return }
            workspace.portForwards.start(
                rule,
                profile: profile,
                jumpProfile: jumpProfile
            )
        }
    }

    func closeCurrentSession() {
        guard let selectedWorkspaceID else { return }
        closeWorkspace(selectedWorkspaceID)
    }

    private func startConnection(in workspace: SessionWorkspace) {
        workspace.terminal.beginPreparingConnection()
        Task { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            // Local defaults are global settings. A restored workspace may
            // still carry the profile captured when its old shell was in `/`;
            // always resolve the current Local profile at process start.
            var profile = workspace.profile.isLocalConnection
                ? localProfile
                : workspace.profile
            var jumpProfile = workspace.jumpProfile
            do {
                if var routingJump = jumpProfile {
                    if let port = try await tailscaleProxyManager.ensureRunning(
                        for: routingJump
                    ) {
                        routingJump.proxyPort = port
                        jumpProfile = routingJump
                    }
                } else if let port = try await tailscaleProxyManager.ensureRunning(
                    for: profile
                ) {
                    profile.proxyPort = port
                }
                if
                    profile.isMoshConnection,
                    profile.resolvedMoshJumpMode != .moshOnJump
                {
                    let routingProxy = jumpProfile ?? profile
                    if routingProxy.resolvedProxyType == .tailscale {
                        // Mosh must not be launched until its UDP path exists.
                        // Creating the relay lazily from the mosh-client wrapper
                        // races a cold tsnet start during session restoration
                        // and turns the dependency failure into exit status 10
                        // (reported by the PTY as 2560).
                        profile.tailscaleMoshPortRange =
                            try await tailscaleProxyManager.prepareMoshRelay(
                                proxyProfile: routingProxy,
                                targetHost: profile.resolvedHost
                            )
                        profile.tailscaleMoshControlPort = nil
                        profile.tailscaleMoshClientPath = nil

                        // A freshly started tsnet node can report Up and bind
                        // the local relay before its peer/DERP path has fully
                        // settled. Mosh starts sending UDP immediately and
                        // exits with status 10 (raw wait status 2560) if that
                        // first exchange is lost. Give cold-start restoration
                        // a short stabilization window after every dependency
                        // has been created and before launching Mosh.
                        try await Task.sleep(for: .seconds(3))
                    }
                }
            } catch {
                workspace.terminal.failPreparingConnection(
                    error.localizedDescription
                )
                return
            }
            guard
                !Task.isCancelled,
                self.workspaces[workspace.id] === workspace
            else { return }
            workspace.updateConnectionRouting(
                profile: profile,
                jumpProfile: jumpProfile
            )
            if !workspace.profile.isLocalConnection {
                inspectNow(workspace.remoteID)
            }
            workspace.terminal.connect(
                profile: profile,
                jumpProfile: jumpProfile,
                startupCommand: workspace.consumeMultiplexerStartupCommand()
            )
            workspace.terminal.startProcessIfNeeded()
        }
    }

    func saveSessionRestorationNow() {
        restorationSaveTask?.cancel()
        restorationSaveTask = nil
        let snapshots = activeWorkspaces.map { workspace in
            let terminalState = workspace.terminal.restorationState()
            return RestorableSessionSnapshot(
                workspaceID: workspace.id,
                remoteID: workspace.remoteID,
                sessionNumber: workspace.sessionNumber,
                customName: workspace.customName,
                mode: workspace.mode,
                localPath: workspace.localPath.standardizedFileURL.path,
                remotePath: workspace.remotePath,
                terminalDirectory: terminalState.directory,
                terminalBuffer: terminalState.buffer,
                pendingCommand: terminalState.pendingCommand,
                multiplexer: workspace.multiplexer,
                portForwardRules: workspace.portForwardRules
            )
        }
        SessionRestorationStore.save(
            SessionRestorationArchive(
                selectedWorkspaceID: selectedWorkspaceID,
                sessions: snapshots
            )
        )
    }

    private func scheduleSessionRestorationSave() {
        restorationSaveTask?.cancel()
        restorationSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            self?.saveSessionRestorationNow()
        }
    }

    private func restoreSessionWorkspaces() {
        guard let archive = SessionRestorationStore.load() else { return }
        for snapshot in archive.sessions {
            let profile: SessionProfile?
            if snapshot.remoteID == localRemoteID {
                profile = localProfile
            } else {
                profile = sessions.first(where: {
                    $0.id == snapshot.remoteID
                })
            }
            guard let profile else { continue }
            openWorkspace(
                profile: profile,
                restoration: snapshot,
                shouldSelect: false
            )
        }

        if
            let selectedID = archive.selectedWorkspaceID,
            workspaces[selectedID] != nil
        {
            selectedWorkspaceID = selectedID
        } else {
            selectedWorkspaceID = activeWorkspaceIDs.last
        }
        if let selectedWorkspace {
            selectedSessionID = selectedWorkspace.remoteID
        }
        saveSessionRestorationNow()
    }

    func showCommandHistory(in workspace: SessionWorkspace) {
        workspace.showingCommandHistory = true
        Task { await refreshCommandHistory(in: workspace) }
    }

    func refreshCommandHistory(in workspace: SessionWorkspace) async {
        workspace.isLoadingCommandHistory = true
        defer { workspace.isLoadingCommandHistory = false }
        do {
            workspace.commandHistory = try await RemoteHistoryService.load(
                profile: workspace.connectionProfile,
                jumpProfile: workspace.connectionJumpProfile
            )
        } catch {
            notice = "远程命令历史读取失败：\(error.localizedDescription)"
        }
    }

    func insertHistoryCommand(
        _ entry: CommandHistoryEntry,
        in workspace: SessionWorkspace
    ) {
        workspace.terminal.insertText(entry.command)
        workspace.showingCommandHistory = false
    }

    func refreshLocal() {
        selectedWorkspace?.reloadLocal()
    }

    private func rememberLocalPath(for workspace: SessionWorkspace) {
        scheduleSessionRestorationSave()
        let path = workspace.localPath.standardizedFileURL.path
        globalLocalPathHistory.removeAll { $0 == path }
        globalLocalPathHistory.insert(path, at: 0)
        if globalLocalPathHistory.count > 20 {
            globalLocalPathHistory.removeLast(
                globalLocalPathHistory.count - 20
            )
        }
        UserDefaults.standard.set(
            globalLocalPathHistory,
            forKey: "globalLocalPathHistory"
        )
        guard let index = sessions.firstIndex(where: {
            $0.id == workspace.remoteID
        }) else {
            return
        }
        guard sessions[index].lastLocalPath != path else { return }
        sessions[index].lastLocalPath = path
        SessionStore.save(sessions)
    }

    private func rememberRemotePath(for workspace: SessionWorkspace) {
        scheduleSessionRestorationSave()
        guard let index = sessions.firstIndex(where: {
            $0.id == workspace.remoteID
        }) else {
            return
        }
        let path = workspace.remotePath
        guard sessions[index].lastRemotePath != path else { return }
        sessions[index].lastRemotePath = path
        SessionStore.save(sessions)
    }

    func rememberWorkspaceMode(
        _ mode: WorkspaceMode,
        for workspace: SessionWorkspace
    ) {
        scheduleSessionRestorationSave()
        guard let index = sessions.firstIndex(where: {
            $0.id == workspace.remoteID
        }) else {
            return
        }
        guard sessions[index].lastWorkspaceMode != mode.rawValue else {
            return
        }
        sessions[index].lastWorkspaceMode = mode.rawValue
        SessionStore.save(sessions)
    }

    func rememberPortForwardRules() {
        scheduleSessionRestorationSave()
    }

    func rememberFileSort(for workspace: SessionWorkspace) {
        guard let index = sessions.firstIndex(where: {
            $0.id == workspace.remoteID
        }) else {
            return
        }
        let localColumn = workspace.localSortColumn.rawValue
        let remoteColumn = workspace.remoteSortColumn.rawValue
        guard
            sessions[index].lastLocalSortColumn != localColumn ||
            sessions[index].lastLocalSortAscending !=
                workspace.localSortAscending ||
            sessions[index].lastRemoteSortColumn != remoteColumn ||
            sessions[index].lastRemoteSortAscending !=
                workspace.remoteSortAscending
        else {
            return
        }
        sessions[index].lastLocalSortColumn = localColumn
        sessions[index].lastLocalSortAscending =
            workspace.localSortAscending
        sessions[index].lastRemoteSortColumn = remoteColumn
        sessions[index].lastRemoteSortAscending =
            workspace.remoteSortAscending
        SessionStore.save(sessions)
    }

    func automaticallyRefreshFiles(
        in workspace: SessionWorkspace
    ) async {
        workspace.reloadLocal(preservingSelection: true)
        guard workspace.terminal.state == .connected else { return }
        if !workspace.hasLoadedRemoteDirectory {
            await loadRemoteFilesIfNeeded(in: workspace)
            return
        }
        guard !workspace.isLoadingRemote else { return }
        _ = await refreshRemote(
            workspace: workspace,
            profile: workspace.connectionProfile,
            preservingSelection: true
        )
    }

    func loadRemoteFilesIfNeeded(in workspace: SessionWorkspace) async {
        guard
            !workspace.profile.isLocalConnection,
            workspace.terminal.state == .connected,
            !workspace.hasLoadedRemoteDirectory,
            !workspace.isLoadingRemote
        else { return }
        // Avoid racing the independent file-service SSH process against the
        // interactive SSH handshake that has just started.
        try? await Task.sleep(for: .milliseconds(500))
        guard workspace.terminal.state == .connected else { return }
        let defaultPath = workspace.profile.resolvedRemoteFilePath
        let hasRememberedPath = workspace.remotePath != defaultPath
        let restored = await refreshRemote(
            workspace: workspace,
            profile: workspace.connectionProfile,
            reportErrors: false
        )
        if restored {
            workspace.markRemoteDirectoryLoaded()
        } else if hasRememberedPath {
            workspace.remotePath = defaultPath
            let fallbackLoaded = await refreshRemote(
                workspace: workspace,
                profile: workspace.connectionProfile,
                reportErrors: false
            )
            if fallbackLoaded {
                workspace.markRemoteDirectoryLoaded()
            }
        }
    }

    func navigateLocal(to rawPath: String, in workspace: SessionWorkspace) {
        let input = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            notice = "本地路径不能为空。"
            return
        }

        let expanded = (input as NSString).expandingTildeInPath
        let destination: URL
        if expanded.hasPrefix("/") {
            destination = URL(
                fileURLWithPath: expanded,
                isDirectory: true
            ).standardizedFileURL
        } else {
            destination = workspace.localPath
                .appendingPathComponent(expanded, isDirectory: true)
                .standardizedFileURL
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: destination.path,
            isDirectory: &isDirectory
        ) else {
            notice = "本地路径不存在：\(destination.path)"
            return
        }

        if isDirectory.boolValue {
            workspace.localPath = destination
            rememberLocalPath(for: workspace)
            workspace.reloadLocal()
        } else {
            workspace.localPath = destination.deletingLastPathComponent()
            rememberLocalPath(for: workspace)
            workspace.reloadLocal(selectingPath: destination.path)
        }
    }

    func openLocal(_ entry: FileEntry) {
        guard let workspace = selectedWorkspace else { return }
        if entry.isDirectory {
            workspace.localPath = URL(
                fileURLWithPath: entry.path,
                isDirectory: true
            )
            rememberLocalPath(for: workspace)
            workspace.reloadLocal()
        } else {
            NSWorkspace.shared.open(
                URL(fileURLWithPath: entry.path)
            )
        }
    }

    func renameLocal(
        _ entry: FileEntry,
        to rawName: String,
        in workspace: SessionWorkspace
    ) {
        guard let newName = FileNameValidator.normalized(rawName) else {
            notice = "文件名称无效。"
            return
        }
        guard newName != entry.name else { return }

        let source = URL(fileURLWithPath: entry.path)
        let destination = source.deletingLastPathComponent()
            .appendingPathComponent(
                newName,
                isDirectory: entry.isDirectory
            )
        do {
            try FileManager.default.moveItem(
                at: source,
                to: destination
            )
            workspace.reloadLocal(selectingPath: destination.path)
        } catch {
            notice = "本地重命名失败：\(error.localizedDescription)"
        }
    }

    func moveLocalItemsToTrash(
        _ entries: [FileEntry],
        in workspace: SessionWorkspace
    ) {
        guard !entries.isEmpty else { return }
        var failures: [String] = []
        for entry in entries {
            do {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(
                    at: URL(
                        fileURLWithPath: entry.path,
                        isDirectory: entry.isDirectory
                    ),
                    resultingItemURL: &resultingURL
                )
            } catch {
                failures.append(
                    "\(entry.name)：\(error.localizedDescription)"
                )
            }
        }
        workspace.reloadLocal()
        if !failures.isEmpty {
            notice = "部分本地项目无法移到废纸篓：\n" +
                failures.joined(separator: "\n")
        }
    }

    func localParent() {
        guard let workspace = selectedWorkspace else { return }
        let parent = workspace.localPath.deletingLastPathComponent()
        guard parent.path != workspace.localPath.path else { return }
        workspace.localPath = parent
        rememberLocalPath(for: workspace)
        workspace.reloadLocal()
    }

    func chooseLocalDirectory() {
        guard let workspace = selectedWorkspace else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = workspace.localPath
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            workspace.localPath = url
            rememberLocalPath(for: workspace)
            workspace.reloadLocal()
        }
    }

    func refreshRemote(in workspace: SessionWorkspace) async {
        _ = await refreshRemote(
            workspace: workspace,
            profile: workspace.connectionProfile
        )
    }

    func navigateRemote(to rawPath: String, in workspace: SessionWorkspace) {
        let destination = rawPath.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !destination.isEmpty else {
            notice = "远程路径不能为空。"
            return
        }

        Task {
            workspace.isLoadingRemote = true
            defer { workspace.isLoadingRemote = false }
            do {
                let navigation = try await RemoteFileService.resolvedNavigation(
                    profile: workspace.connectionProfile,
                    jumpProfile: workspace.connectionJumpProfile,
                    path: destination
                )
                let listing = navigation.listing
                workspace.remotePath = listing.path
                workspace.remoteEntries = listing.entries
                rememberRemotePath(for: workspace)
                if let selectedEntryID = navigation.selectedEntryID {
                    workspace.selectedRemoteIDs = [selectedEntryID]
                } else {
                    workspace.selectedRemoteIDs.removeAll()
                }
            } catch {
                notice = "远程目录读取失败：\(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    private func refreshRemote(
        workspace: SessionWorkspace,
        profile: SessionProfile,
        reportErrors: Bool = true,
        preservingSelection: Bool = false
    ) async -> Bool {
        let selectedPaths = preservingSelection
            ? Set(
                workspace.remoteEntries.lazy
                    .filter {
                        workspace.selectedRemoteIDs.contains($0.id)
                    }
                    .map(\.path)
            )
            : []
        workspace.isLoadingRemote = true
        defer { workspace.isLoadingRemote = false }
        do {
            let listing = try await RemoteFileService.resolvedListing(
                profile: profile,
                jumpProfile: workspace.connectionJumpProfile,
                path: workspace.remotePath
            )
            workspace.remotePath = listing.path
            workspace.remoteEntries = listing.entries
            if preservingSelection {
                workspace.selectedRemoteIDs = Set(
                    listing.entries.lazy
                        .filter { selectedPaths.contains($0.path) }
                        .map(\.id)
                )
            } else {
                workspace.selectedRemoteIDs.removeAll()
            }
            rememberRemotePath(for: workspace)
            return true
        } catch {
            if reportErrors {
                notice = "远程目录读取失败：\(error.localizedDescription)"
            }
            return false
        }
    }

    func openRemote(_ entry: FileEntry) {
        guard let workspace = selectedWorkspace else { return }
        if entry.isDirectory {
            workspace.remotePath = entry.path
            Task {
                await refreshRemote(
                    workspace: workspace,
                    profile: workspace.connectionProfile
                )
            }
        } else {
            enqueueDownload(
                entry,
                openWhenFinished:
                    RemoteFilePreviewPolicy.shouldOpenAfterDownload(entry),
                in: workspace
            )
        }
    }

    func renameRemote(
        _ entry: FileEntry,
        to rawName: String,
        in workspace: SessionWorkspace
    ) {
        guard let newName = FileNameValidator.normalized(rawName) else {
            notice = "文件名称无效。"
            return
        }
        guard newName != entry.name else { return }
        let currentPath = workspace.remotePath

        Task {
            do {
                let destination = try await RemoteFileService.rename(
                    profile: workspace.connectionProfile,
                    jumpProfile: workspace.connectionJumpProfile,
                    entry: entry,
                    newName: newName
                )
                let listing = try await RemoteFileService.resolvedListing(
                    profile: workspace.connectionProfile,
                    jumpProfile: workspace.connectionJumpProfile,
                    path: currentPath
                )
                guard workspace.remotePath == currentPath else { return }
                workspace.remotePath = listing.path
                workspace.remoteEntries = listing.entries
                workspace.selectedRemoteIDs = Set(
                    listing.entries.lazy
                        .filter { $0.path == destination }
                        .map(\.id)
                )
                rememberRemotePath(for: workspace)
            } catch {
                notice = "远程重命名失败：\(error.localizedDescription)"
            }
        }
    }

    func remoteParent() {
        guard let workspace = selectedWorkspace else { return }
        workspace.remotePath = RemoteFileService.parent(of: workspace.remotePath)
        Task {
            await refreshRemote(
                workspace: workspace,
                profile: workspace.connectionProfile
            )
        }
    }

    func createRemoteDirectory(name: String) {
        guard let workspace = selectedWorkspace else { return }
        let parentPath = workspace.remotePath
        Task {
            do {
                try await RemoteFileService.createDirectory(
                    profile: workspace.connectionProfile,
                    jumpProfile: workspace.connectionJumpProfile,
                    parentPath: parentPath,
                    name: name
                )
                await refreshRemote(
                    workspace: workspace,
                    profile: workspace.connectionProfile
                )
            } catch {
                notice = "创建远程文件夹失败：\(error.localizedDescription)"
            }
        }
    }

    func deleteSelectedRemote() {
        guard let workspace = selectedWorkspace else { return }
        let entries = workspace.remoteEntries.filter {
            workspace.selectedRemoteIDs.contains($0.id)
        }
        guard !entries.isEmpty else { return }
        Task {
            do {
                for entry in entries {
                    try await RemoteFileService.delete(
                        profile: workspace.connectionProfile,
                        jumpProfile: workspace.connectionJumpProfile,
                        entry: entry
                    )
                }
                await refreshRemote(
                    workspace: workspace,
                    profile: workspace.connectionProfile
                )
            } catch {
                notice = "删除失败：\(error.localizedDescription)"
            }
        }
    }

    func uploadSelected() {
        guard let workspace = selectedWorkspace else {
            notice = SSHServiceError.noActiveSession.localizedDescription
            return
        }
        let entries = workspace.localEntries.filter {
            workspace.selectedLocalIDs.contains($0.id)
        }
        upload(entries, in: workspace)
    }

    func upload(
        _ entries: [FileEntry],
        in workspace: SessionWorkspace
    ) {
        upload(entries, to: workspace.remotePath, in: workspace)
    }

    func upload(
        _ entries: [FileEntry],
        to remoteDirectory: String,
        in workspace: SessionWorkspace
    ) {
        guard !entries.isEmpty else { return }
        Task {
            do {
                let listing = try await RemoteFileService.resolvedListing(
                    profile: workspace.connectionProfile,
                    jumpProfile: workspace.connectionJumpProfile,
                    path: remoteDirectory
                )
                enqueueUploads(
                    entries,
                    remoteDirectory: listing.path,
                    existingNames: Set(listing.entries.map(\.name)),
                    in: workspace
                )
            } catch {
                notice = "上传目标目录读取失败：\(error.localizedDescription)"
            }
        }
    }

    func uploadDroppedFiles(
        _ urls: [URL],
        to remoteDirectory: String,
        in workspace: SessionWorkspace
    ) {
        var entries: [FileEntry] = []
        for url in urls where url.isFileURL {
            let source = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: source.path,
                isDirectory: &isDirectory
            ) else {
                continue
            }
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: source.path
            )
            let totalBytes = isDirectory.boolValue
                ? nil
                : (attributes?[.size] as? NSNumber)?.int64Value

            entries.append(
                FileEntry(
                    name: source.lastPathComponent,
                    path: source.path,
                    isDirectory: isDirectory.boolValue,
                    size: totalBytes ?? 0,
                    modifiedAt: attributes?[.modificationDate] as? Date,
                    createdAt: attributes?[.creationDate] as? Date
                )
            )
        }
        upload(entries, to: remoteDirectory, in: workspace)
    }

    private func enqueueUploads(
        _ entries: [FileEntry],
        remoteDirectory: String,
        existingNames: Set<String>,
        in workspace: SessionWorkspace
    ) {
        for entry in entries {
            enqueueUpload(
                fileName: entry.name,
                source: entry.path,
                isDirectory: entry.isDirectory,
                totalBytes: entry.isDirectory ? nil : entry.size,
                remoteDirectory: remoteDirectory,
                existingNames: existingNames,
                in: workspace
            )
        }
    }

    private func enqueueUpload(
        fileName: String,
        source: String,
        isDirectory: Bool,
        totalBytes: Int64?,
        remoteDirectory: String,
        existingNames: Set<String>,
        in workspace: SessionWorkspace
    ) {
        let queuedNames = Set(
            workspace.transfers.lazy
                .filter {
                    $0.direction == .upload &&
                    $0.status.reservesDestination &&
                    RemoteFileService.parent(of: $0.destination) ==
                        remoteDirectory
                }
                .map {
                    ($0.destination as NSString).lastPathComponent
                }
        )
        let resolvedName = FileNameCollisionResolver.uniqueName(
            for: fileName,
            isDirectory: isDirectory
        ) {
            existingNames.contains($0) || queuedNames.contains($0)
        }
        let destination = RemoteFileService.join(
            remoteDirectory,
            resolvedName
        )
        enqueueTransfer(
            workspace: workspace,
            fileName: resolvedName,
            source: source,
            destination: destination,
            direction: .upload,
            recursive: isDirectory,
            totalBytes: totalBytes
        )
    }

    func downloadSelected() {
        guard let workspace = selectedWorkspace else {
            notice = SSHServiceError.noActiveSession.localizedDescription
            return
        }
        let entries = workspace.remoteEntries.filter {
            workspace.selectedRemoteIDs.contains($0.id)
        }
        download(entries, in: workspace)
    }

    func download(
        _ entries: [FileEntry],
        in workspace: SessionWorkspace
    ) {
        for entry in entries {
            enqueueDownload(entry, in: workspace)
        }
    }

    private func enqueueDownload(
        _ entry: FileEntry,
        openWhenFinished: Bool = false,
        in workspace: SessionWorkspace
    ) {
        let queuedPaths = Set(
            workspace.transfers.lazy
                .filter {
                    $0.direction == .download &&
                        $0.status.reservesDestination
                }
                .map { $0.destination.lowercased() }
        )
        let resolvedName = FileNameCollisionResolver.uniqueName(
            for: entry.name,
            isDirectory: entry.isDirectory
        ) { candidate in
            let path = workspace.localPath
                .appendingPathComponent(candidate)
                .path
            return queuedPaths.contains(path.lowercased()) ||
                FileManager.default.fileExists(atPath: path)
        }
        let destination = workspace.localPath
            .appendingPathComponent(
                resolvedName,
                isDirectory: entry.isDirectory
            )
            .path
        enqueueTransfer(
            workspace: workspace,
            fileName: resolvedName,
            source: entry.path,
            destination: destination,
            direction: .download,
            recursive: entry.isDirectory,
            totalBytes: entry.isDirectory ? nil : entry.size,
            openWhenFinished: openWhenFinished
        )
    }

    private func enqueueTransfer(
        workspace: SessionWorkspace,
        fileName: String,
        source: String,
        destination: String,
        direction: TransferDirection,
        recursive: Bool,
        totalBytes: Int64? = nil,
        openWhenFinished: Bool = false
    ) {
        let item = TransferItem(
            id: UUID(),
            fileName: fileName,
            source: source,
            destination: destination,
            direction: direction,
            isDirectory: recursive,
            totalBytes: totalBytes,
            transferredBytes: 0,
            bytesPerSecond: 0,
            status: .queued,
            log: ""
        )
        workspace.transfers.insert(item, at: 0)
        let processControl = CommandProcessControl()
        transferControls[item.id] = processControl

        Task {
            defer { transferControls[item.id] = nil }
            guard processControl.state != .stopped else { return }
            updateTransfer(item.id, in: workspace) {
                $0.status = processControl.state == .paused
                    ? .paused
                    : .running
                $0.startedAt = Date()
            }
            let directorySizeTask: Task<Int64?, Never>? = if
                recursive,
                direction == .upload
            {
                Task {
                    let size = await Task.detached(priority: .utility) {
                        LocalDirectorySizeCalculator.size(atPath: source)
                    }.value
                    guard
                        !Task.isCancelled,
                        processControl.state != .stopped,
                        let size
                    else {
                        return size
                    }
                    updateTransfer(item.id, in: workspace) {
                        $0.totalBytes = size
                    }
                    return size
                }
            } else {
                nil
            }
            defer { directorySizeTask?.cancel() }

            let progressTask: Task<Void, Never>? = if direction == .upload {
                Task {
                    await monitorUploadProgress(
                        item.id,
                        destination: destination,
                        profile: workspace.connectionProfile,
                        in: workspace
                    )
                }
            } else if !recursive, totalBytes != nil {
                Task {
                    await monitorDownloadProgress(
                        item.id,
                        destination: destination,
                        in: workspace
                    )
                }
            } else {
                nil
            }
            defer { progressTask?.cancel() }
            do {
                let invocation = try SSHCommandBuilder.scp(
                    profile: workspace.connectionProfile,
                    jumpProfile: workspace.connectionJumpProfile,
                    localPath: direction == .upload ? source : destination,
                    remotePath: direction == .upload ? destination : source,
                    direction: direction,
                    recursive: recursive
                )
                let result = try await CommandRunner.run(
                    invocation,
                    control: processControl
                )
                guard processControl.state != .stopped else { return }
                if result.exitCode == 0 {
                    let measuredBytes: Int64? = if recursive {
                        if direction == .upload {
                            await directorySizeTask?.value
                        } else {
                            await localTransferSize(
                                atPath: destination,
                                isDirectory: true
                            )
                        }
                    } else {
                        await localTransferSize(
                            atPath: direction == .upload
                                ? source
                                : destination,
                            isDirectory: false
                        )
                    }
                    updateTransfer(item.id, in: workspace) {
                        if let measuredBytes {
                            $0.totalBytes = measuredBytes
                            $0.transferredBytes = measuredBytes
                        } else if let totalBytes = $0.totalBytes {
                            $0.transferredBytes = totalBytes
                        }
                        if
                            let startedAt = $0.startedAt,
                            $0.transferredBytes > 0
                        {
                            let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
                            $0.bytesPerSecond = Double($0.transferredBytes) / elapsed
                        }
                        $0.status = .finished
                        $0.finishedAt = Date()
                        $0.log = result.output
                    }
                    if direction == .upload {
                        await refreshRemote(
                            workspace: workspace,
                            profile: workspace.connectionProfile
                        )
                    } else {
                        workspace.reloadLocal()
                        if openWhenFinished {
                            NSWorkspace.shared.open(
                                URL(fileURLWithPath: destination)
                            )
                        }
                    }
                } else {
                    updateTransfer(item.id, in: workspace) {
                        $0.status = .failed(result.output)
                        $0.finishedAt = Date()
                        $0.log = result.output
                    }
                }
            } catch {
                guard processControl.state != .stopped else { return }
                updateTransfer(item.id, in: workspace) {
                    $0.status = .failed(error.localizedDescription)
                    $0.finishedAt = Date()
                    $0.log = error.localizedDescription
                }
            }
        }
    }

    func pauseTransfer(
        _ id: UUID,
        in workspace: SessionWorkspace
    ) {
        guard
            let control = transferControls[id],
            control.pause()
        else {
            return
        }
        updateTransfer(id, in: workspace) {
            $0.status = .paused
            $0.bytesPerSecond = 0
        }
    }

    func resumeTransfer(
        _ id: UUID,
        in workspace: SessionWorkspace
    ) {
        guard
            let control = transferControls[id],
            control.resume()
        else {
            return
        }
        updateTransfer(id, in: workspace) {
            $0.status = .running
            $0.bytesPerSecond = 0
        }
    }

    func stopTransfer(
        _ id: UUID,
        in workspace: SessionWorkspace
    ) {
        guard
            let control = transferControls[id],
            control.stop()
        else {
            return
        }
        updateTransfer(id, in: workspace) {
            $0.status = .cancelled
            $0.bytesPerSecond = 0
            $0.finishedAt = Date()
            $0.log = "传输已由用户停止。"
        }
    }

    private func monitorDownloadProgress(
        _ id: UUID,
        destination: String,
        in workspace: SessionWorkspace
    ) async {
        var previousBytes: Int64 = 0
        var previousTime = Date()

        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            guard
                let status = workspace.transfers.first(where: {
                    $0.id == id
                })?.status
            else {
                return
            }
            if status == .paused { continue }
            guard status == .running else { return }

            let attributes = try? FileManager.default.attributesOfItem(
                atPath: destination
            )
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let now = Date()
            let elapsed = max(now.timeIntervalSince(previousTime), 0.001)
            let delta = max(bytes - previousBytes, 0)
            let instantSpeed = Double(delta) / elapsed

            updateTransfer(id, in: workspace) { transfer in
                transfer.transferredBytes = bytes
                if instantSpeed > 0 {
                    transfer.bytesPerSecond = transfer.bytesPerSecond > 0
                        ? (transfer.bytesPerSecond * 0.65) + (instantSpeed * 0.35)
                        : instantSpeed
                } else if bytes < previousBytes {
                    transfer.bytesPerSecond = 0
                }
            }
            previousBytes = bytes
            previousTime = now
        }
    }

    private func monitorUploadProgress(
        _ id: UUID,
        destination: String,
        profile: SessionProfile,
        in workspace: SessionWorkspace
    ) async {
        var previousBytes: Int64 = 0
        var previousTime = Date()

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            guard
                let status = workspace.transfers.first(where: {
                    $0.id == id
                })?.status
            else {
                return
            }
            if status == .paused { continue }
            guard status == .running else { return }

            guard
                let bytes = try? await RemoteFileService.pathSize(
                    profile: profile,
                    jumpProfile: workspace.connectionJumpProfile,
                    path: destination
                )
            else {
                continue
            }
            let now = Date()
            let elapsed = max(now.timeIntervalSince(previousTime), 0.001)
            let delta = max(bytes - previousBytes, 0)
            let instantSpeed = Double(delta) / elapsed

            updateTransfer(id, in: workspace) { transfer in
                let limitedBytes = min(
                    bytes,
                    transfer.totalBytes ?? bytes
                )
                transfer.transferredBytes = limitedBytes
                if instantSpeed > 0 {
                    transfer.bytesPerSecond = transfer.bytesPerSecond > 0
                        ? (transfer.bytesPerSecond * 0.65) +
                            (instantSpeed * 0.35)
                        : instantSpeed
                } else if bytes < previousBytes {
                    transfer.bytesPerSecond = 0
                }
            }
            previousBytes = bytes
            previousTime = now
        }
    }

    private func localTransferSize(
        atPath path: String,
        isDirectory: Bool
    ) async -> Int64? {
        await Task.detached(priority: .utility) {
            if isDirectory {
                return LocalDirectorySizeCalculator.size(atPath: path)
            }
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: path
            )
            return (attributes?[.size] as? NSNumber)?.int64Value
        }.value
    }

    private func updateTransfer(
        _ id: UUID,
        in workspace: SessionWorkspace,
        mutate: (inout TransferItem) -> Void
    ) {
        guard let index = workspace.transfers.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutate(&workspace.transfers[index])
    }
}

enum LocalDirectorySizeCalculator {
    static func size(
        atPath path: String,
        fileManager: FileManager = .default
    ) -> Int64? {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return nil
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            if Task.isCancelled { return nil }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            if total > Int64.max - size {
                return Int64.max
            }
            total += size
        }
        return total
    }
}

extension Array where Element == SessionProfile {
    mutating func renameRemoteGroup(
        _ currentName: String,
        to newName: String
    ) -> Set<UUID> {
        guard
            let currentName = RemoteGroupName.normalized(currentName),
            let newName = RemoteGroupName.normalized(newName),
            currentName.caseInsensitiveCompare(newName) != .orderedSame
        else {
            return []
        }
        var updatedRemoteIDs = Set<UUID>()
        for index in indices where
            self[index].resolvedRemoteGroup.caseInsensitiveCompare(
                currentName
            ) == .orderedSame
        {
            self[index].remoteGroup = newName
            updatedRemoteIDs.insert(self[index].id)
        }
        return updatedRemoteIDs
    }

    mutating func moveRemotesWithinGroups(
        _ remoteIDs: Set<UUID>,
        direction: RemoteMoveDirection
    ) {
        guard count > 1, !remoteIDs.isEmpty else { return }

        for group in RemoteGroupSection.sections(from: self) {
            let groupIDs = Set(group.sessions.map(\.id))
            let selectedGroupIDs = remoteIDs.intersection(groupIDs)
            guard !selectedGroupIDs.isEmpty else { continue }

            let indices = self.indices.filter {
                groupIDs.contains(self[$0].id)
            }
            var groupSessions = indices.map { self[$0] }
            groupSessions.moveRemotes(
                selectedGroupIDs,
                direction: direction
            )
            for (index, session) in zip(indices, groupSessions) {
                self[index] = session
            }
        }
    }

    mutating func reorderRemote(
        _ remoteID: UUID,
        relativeTo targetID: UUID,
        placeAfter: Bool
    ) {
        guard
            remoteID != targetID,
            let sourceIndex = firstIndex(where: { $0.id == remoteID })
        else {
            return
        }
        let remote = remove(at: sourceIndex)
        guard let targetIndex = firstIndex(where: { $0.id == targetID }) else {
            insert(remote, at: Swift.min(sourceIndex, count))
            return
        }
        let insertionIndex = targetIndex + (placeAfter ? 1 : 0)
        insert(remote, at: Swift.min(insertionIndex, count))
    }

    mutating func moveRemotes(
        _ remoteIDs: Set<UUID>,
        direction: RemoteMoveDirection
    ) {
        guard count > 1, !remoteIDs.isEmpty else { return }

        switch direction {
        case .up:
            for index in 1..<count where
                remoteIDs.contains(self[index].id) &&
                !remoteIDs.contains(self[index - 1].id)
            {
                swapAt(index, index - 1)
            }
        case .down:
            for index in stride(from: count - 2, through: 0, by: -1) where
                remoteIDs.contains(self[index].id) &&
                !remoteIDs.contains(self[index + 1].id)
            {
                swapAt(index, index + 1)
            }
        }
    }
}

extension Array where Element == UUID {
    func workspaceIDsExcluding(_ workspaceID: UUID) -> [UUID] {
        filter { $0 != workspaceID }
    }

    func workspaceIDsToRight(of workspaceID: UUID) -> [UUID] {
        guard
            let index = firstIndex(of: workspaceID),
            index + 1 < count
        else {
            return []
        }
        return Array(self[(index + 1)...])
    }

    mutating func reorderWorkspace(
        _ workspaceID: UUID,
        relativeTo targetID: UUID,
        placeAfter: Bool
    ) {
        guard
            workspaceID != targetID,
            let sourceIndex = firstIndex(of: workspaceID)
        else {
            return
        }
        let workspace = remove(at: sourceIndex)
        guard let targetIndex = firstIndex(of: targetID) else {
            insert(workspace, at: Swift.min(sourceIndex, count))
            return
        }
        let insertionIndex = targetIndex + (placeAfter ? 1 : 0)
        insert(workspace, at: Swift.min(insertionIndex, count))
    }
}
