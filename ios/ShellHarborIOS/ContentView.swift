import SwiftUI
import UniformTypeIdentifiers
import CoreLocation

@MainActor
private final class MobileBackgroundLocationKeeper: NSObject,
    @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var wantsTracking = false
    private(set) var isTrackingLocation = false

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 1_000
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
    }

    func prepareAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways, .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    func start() {
        wantsTracking = true
        switch manager.authorizationStatus {
        case .authorizedAlways:
            manager.startUpdatingLocation()
            isTrackingLocation = true
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        case .denied, .restricted:
            isTrackingLocation = false
        @unknown default:
            isTrackingLocation = false
        }
    }

    func stop() {
        wantsTracking = false
        manager.stopUpdatingLocation()
        isTrackingLocation = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard wantsTracking else { return }
        start()
    }
}

private extension Color {
    init(shellHarborHex value: String) {
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let number = UInt64(hex, radix: 16) else {
            self = .blue
            return
        }
        self.init(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }
}

private extension UIColor {
    var shellHarborHex: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: nil) else {
            return "#4F8CFF"
        }
        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

private enum IOSRootTab: String, Hashable {
    case remotes
    case sessions
    case forwarding
    case tailscale
    case settings
}

private enum MobileTerminalMultiplexer: String, CaseIterable, Identifiable {
    case tmux

    var id: String { rawValue }
    var title: String { rawValue }

    func launch(sessionName existingName: String? = nil) -> (command: String, suffix: String) {
        let generatedSuffix = "\(rawValue)-\(String(UUID().uuidString.prefix(6)).lowercased())"
        let sessionName = existingName ?? "shellharbor-\(generatedSuffix)"
        let quoted = "'" + sessionName.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Keep the login shell alive so detaching from or exiting tmux does
        // not strand the iOS Session in a terminated PTY.
        let command = "tmux has-session -t \(quoted) 2>/dev/null || tmux new-session -d -s \(quoted); tmux set-option -t \(quoted) mouse on && tmux attach-session -t \(quoted)"
        return (command, existingName ?? generatedSuffix)
    }

    static let listingCommand = """
    PATH="$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
    tmux_bin=$(command -v tmux 2>/dev/null || true)
    for candidate in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux "$HOME/.local/bin/tmux"; do
      [ -n "$tmux_bin" ] || [ ! -x "$candidate" ] || tmux_bin=$candidate
    done
    if [ -z "$tmux_bin" ]; then
      printf '%s\n' '__SHELLHARBOR_TMUX_ERROR__tmux command not found in non-interactive SSH environment'
    else
      "$tmux_bin" list-sessions -F '__SHELLHARBOR_TMUX__#{session_name}' 2>&1 || status=$?
      if [ "${status:-0}" -ne 0 ]; then
        printf '%s%s\n' '__SHELLHARBOR_TMUX_ERROR__' 'tmux list-sessions failed'
      fi
    fi
    """

    static func parseSessions(_ output: String) -> [String] {
        let prefix = "__SHELLHARBOR_TMUX__"
        var seen = Set<String>()
        return output.split(whereSeparator: \Character.isNewline).compactMap { line in
            let value = String(line)
            guard value.hasPrefix(prefix) else { return nil }
            let name = String(value.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    static func parseError(_ output: String) -> String? {
        let prefix = "__SHELLHARBOR_TMUX_ERROR__"
        return output.split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)) }
    }
}

struct ContentView: View {
    @Environment(RemoteStore.self) private var remoteStore
    @Environment(ImportedKeyStore.self) private var keyStore
    @Environment(KnownHostStore.self) private var knownHostStore
    @Environment(MobileProxyStore.self) private var proxyStore
    @Environment(MobileInspectionStore.self) private var inspectionStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("mobileSelectedRootTab") private var selectedTabRaw =
        IOSRootTab.remotes.rawValue
    @AppStorage("mobileSelectedSessionID") private var selectedSessionID = ""
    @AppStorage("mobileBackgroundKeepAliveEnabled")
    private var backgroundKeepAliveEnabled = false
    @State private var requestedSessionID: UUID?
    @State private var suspendedConnectionIDs = Set<UUID>()
    @State private var backgroundLocationKeeper =
        MobileBackgroundLocationKeeper()

    private var selectedTab: Binding<IOSRootTab> {
        Binding(
            get: { IOSRootTab(rawValue: selectedTabRaw) ?? .remotes },
            set: { selectedTabRaw = $0.rawValue }
        )
    }

    var body: some View {
        TabView(selection: selectedTab) {
            RemoteListView { sessionID in
                requestedSessionID = sessionID
                selectedTabRaw = IOSRootTab.sessions.rawValue
            }
                .tabItem { Label("Remote", systemImage: "server.rack") }
                .tag(IOSRootTab.remotes)
            SessionListView(
                requestedSessionID: $requestedSessionID,
                onSelectedSessionChanged: { sessionID in
                    selectedSessionID = sessionID?.uuidString ?? ""
                }
            )
                .tabItem { Label("Session", systemImage: "terminal") }
                .tag(IOSRootTab.sessions)
            IOSPortForwardView()
                .tabItem {
                    Label(
                        "转发",
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                }
                .tag(IOSRootTab.forwarding)
            IOSTailscaleView()
                .tabItem { Label("Tailscale", systemImage: "network") }
                .tag(IOSRootTab.tailscale)
            IOSSettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(IOSRootTab.settings)
        }
        .tint(.blue)
        .task {
            remoteStore.restoreSessions(keyStore: keyStore, knownHostStore: knownHostStore)
            if backgroundKeepAliveEnabled {
                backgroundLocationKeeper.prepareAuthorization()
            }
            if IOSRootTab(rawValue: selectedTabRaw) == .sessions,
               let sessionID = UUID(uuidString: selectedSessionID),
               remoteStore.sessions.contains(where: { $0.id == sessionID }) {
                requestedSessionID = sessionID
            }
            await remoteStore.prewarmTailscale(proxyStore: proxyStore)
            #if DEBUG
            await MobileConnectionSelfTest.runIfRequested()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                if suspendedConnectionIDs.isEmpty {
                    suspendedConnectionIDs = Set(
                        remoteStore.sessions
                            .filter(\.controller.hasConnectionIntent)
                            .map(\.id)
                    )
                    remoteStore.persistSessionRestoration()
                    if backgroundKeepAliveEnabled,
                       !suspendedConnectionIDs.isEmpty {
                        backgroundLocationKeeper.start()
                    }
                }
            } else {
                backgroundLocationKeeper.stop()
                remoteStore.resumeSessionsAfterSuspension(
                    suspendedConnectionIDs
                )
                suspendedConnectionIDs.removeAll()
            }
        }
        .onChange(of: remoteStore.sessions.map(\.controller.hasConnectionIntent)) {
            _, intents in
            guard backgroundKeepAliveEnabled, intents.contains(true) else {
                backgroundLocationKeeper.stop()
                return
            }
            if scenePhase == .active {
                backgroundLocationKeeper.prepareAuthorization()
            } else {
                backgroundLocationKeeper.start()
            }
        }
        .onChange(of: backgroundKeepAliveEnabled) { _, enabled in
            guard enabled else {
                backgroundLocationKeeper.stop()
                return
            }
            if scenePhase == .active {
                backgroundLocationKeeper.prepareAuthorization()
            } else if scenePhase != .active,
                      !suspendedConnectionIDs.isEmpty {
                backgroundLocationKeeper.start()
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                inspectionStore.inspectDueSessions(
                    remotes: remoteStore.remotes,
                    sessions: remoteStore.sessions
                )
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
            }
        }
    }
}

private struct IOSTailscaleView: View {
    @Environment(RemoteStore.self) private var remoteStore
    @Environment(MobileProxyStore.self) private var proxyStore
    @State private var statuses: [UUID: TailscaleDisplayStatus] = [:]

    private var tailscaleProxies: [MobileProxyProfile] {
        proxyStore.proxies.filter { $0.type == .tailscale }
    }

    var body: some View {
        NavigationStack {
            List(tailscaleProxies) { proxy in
                let status = statuses[proxy.id] ?? .disconnected
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(proxy.name, systemImage: "network")
                            .font(.headline)
                        Spacer()
                        Label(status.title, systemImage: status.symbol)
                            .font(.caption)
                            .foregroundStyle(status.color)
                    }
                    LabeledContent("节点", value: status.nodeName ?? proxy.tailscaleNodeName)
                    LabeledContent(
                        "Login Server",
                        value: proxy.tailscaleLoginServer.isEmpty ? "https://login.tailscale.com" : proxy.tailscaleLoginServer
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let error = status.error, !error.isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if tailscaleProxies.isEmpty {
                    ContentUnavailableView(
                        "没有 Tailscale 配置",
                        systemImage: "network",
                        description: Text("请先在设置的共享 Proxy 中添加 Tailscale")
                    )
                }
            }
            .navigationTitle("Tailscale")
            .task(id: tailscaleProxies.map(\.id)) {
                while !Task.isCancelled {
                    await refreshStatuses()
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                }
            }
        }
    }

    private func refreshStatuses() async {
        var refreshed: [UUID: TailscaleDisplayStatus] = [:]
        for proxy in tailscaleProxies {
            let result = await remoteStore.tailscaleStatus(for: proxy)
            refreshed[proxy.id] = TailscaleDisplayStatus(
                state: result.state,
                nodeName: result.nodeName,
                error: result.error
            )
        }
        statuses = refreshed
    }
}

private struct IOSPortForwardView: View {
    @Environment(RemoteStore.self) private var remoteStore
    @State private var forwardStore = MobilePortForwardStore()

    private var availableSessions: [MobileSession] {
        remoteStore.sessions.filter {
            $0.controller.state == .connected &&
                $0.remote.connectionMethod == .ssh
        }
    }

    var body: some View {
        @Bindable var forwardStore = forwardStore
        NavigationStack {
            List {
                Section {
                    Text("本机 IP：\(MobileLocalNetworkAddresses.ipv4.joined(separator: "  "))")
                        .font(.caption)
                        .textSelection(.enabled)
                }
                ForEach($forwardStore.rules) { $rule in
                    Section {
                        Picker("SSH Session", selection: $rule.selectedSessionID) {
                            Text("请选择").tag(UUID?.none)
                            ForEach(availableSessions) { session in
                                Text(session.displayName).tag(Optional(session.id))
                            }
                        }
                        TextField("监听地址", text: $rule.bindHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField(
                            "监听端口",
                            value: $rule.listenPort,
                            format: .number.grouping(.never)
                        )
                        .keyboardType(.numberPad)
                        TextField("目标地址", text: $rule.targetHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField(
                            "目标端口",
                            value: $rule.targetPort,
                            format: .number.grouping(.never)
                        )
                        .keyboardType(.numberPad)
                        forwardStatus(rule)
                    } header: {
                        HStack {
                            Text("端口转发")
                            Spacer()
                            Button(role: .destructive) {
                                forwardStore.removeRule(rule.id)
                            } label: { Image(systemName: "trash") }
                        }
                    }
                }
            }
            .navigationTitle("端口转发")
            .toolbar {
                Button { forwardStore.addRule() } label: { Image(systemName: "plus") }
            }
            .onAppear { selectDefaultSessionsIfNeeded() }
            .onChange(of: availableSessions.map(\.id)) { _, _ in
                selectDefaultSessionsIfNeeded()
            }
        }
    }

    private func selectedSession(for rule: MobilePortForwardRule) -> MobileSession? {
        guard let id = rule.selectedSessionID else { return nil }
        return availableSessions.first { $0.id == id }
    }

    @ViewBuilder
    private func forwardStatus(_ rule: MobilePortForwardRule) -> some View {
        let status = forwardStore.statuses[rule.id] ?? .stopped
        HStack {
            Circle().fill(statusColor(status)).frame(width: 8, height: 8)
            Text(statusText(status, rule: rule)).textSelection(.enabled)
            Spacer()
            if case .running = status {
                Button("停止", role: .destructive) { forwardStore.stop(rule.id) }
            } else {
                Button("启动") {
                    guard let session = selectedSession(for: rule) else { return }
                    forwardStore.start(rule, using: session)
                }
                .disabled(selectedSession(for: rule) == nil || status == .starting)
            }
        }
    }

    private func selectDefaultSessionsIfNeeded() {
        guard let first = availableSessions.first?.id else { return }
        for index in forwardStore.rules.indices
            where selectedSession(for: forwardStore.rules[index]) == nil {
            forwardStore.rules[index].selectedSessionID = first
        }
    }

    private func statusText(
        _ status: MobilePortForwardStore.Status,
        rule: MobilePortForwardRule
    ) -> String {
        switch status {
        case .stopped: "未启动"
        case .starting: "正在建立转发"
        case .running(let port): "正在监听 \(rule.bindHost):\(port)"
        case .failed(let message): message
        }
    }

    private func statusColor(_ status: MobilePortForwardStore.Status) -> Color {
        switch status {
        case .stopped: .secondary
        case .starting: .orange
        case .running: .green
        case .failed: .red
        }
    }
}

private struct TailscaleDisplayStatus {
    let state: MobileTailscaleConnectionState
    var nodeName: String?
    var error: String?

    static let disconnected = Self(state: .disconnected, nodeName: nil, error: nil)

    var title: String {
        switch state {
        case .disconnected: "未连接"
        case .connecting: "连接中"
        case .connected: "已连接"
        case .failed: "连接失败"
        }
    }

    var symbol: String {
        switch state {
        case .disconnected: "circle"
        case .connecting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch state {
        case .connected: .green
        case .connecting: .blue
        case .failed: .red
        case .disconnected: .secondary
        }
    }
}

private struct RemoteListView: View {
    @Environment(RemoteStore.self) private var store
    @Environment(MobileInspectionStore.self) private var inspectionStore
    @Environment(ImportedKeyStore.self) private var keyStore
    @Environment(KnownHostStore.self) private var knownHostStore
    @Environment(MobileProxyStore.self) private var proxyStore
    @State private var editingRemote: MobileRemoteProfile?
    @State private var selection: Set<UUID> = []
    @State private var editMode: EditMode = .inactive
    @State private var isNamingGroup = false
    @State private var groupName = ""
    @State private var groupBeingRenamed: String?
    @State private var renamedGroupName = ""
    @State private var groupBeingRemoved: String?
    @State private var confirmingRemoteDeletion = false
    @State private var inspectionRemote: MobileRemoteProfile?
    let onSessionOpened: (UUID) -> Void

    private var groupNames: [String] {
        groupedRemotes.map(\.name).filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.remotes.isEmpty {
                    ContentUnavailableView(
                        "还没有 Remote",
                        systemImage: "server.rack",
                        description: Text("添加 SSH、Mosh 或 Tailscale Remote")
                    )
                } else {
                    List(selection: $selection) {
                        ForEach(groupedRemotes) { group in
                            Section {
                                ForEach(group.remotes) { remote in
                                    remoteRow(remote)
                                }
                                .onMove { source, destination in
                                    store.reorderRemotes(
                                        inGroup: group.name,
                                        from: source,
                                        to: destination
                                    )
                                }
                            } header: {
                                HStack {
                                    Label(
                                        group.name.isEmpty ? "未分组" : group.name,
                                        systemImage: group.name.isEmpty ? "tray" : "folder"
                                    )
                                    Spacer()
                                    Text("\(group.remotes.count)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                                .contextMenu {
                                    if !group.name.isEmpty {
                                        Button("重命名分组…", systemImage: "pencil") {
                                            groupBeingRenamed = group.name
                                            renamedGroupName = group.name
                                        }
                                        Button(
                                            "删除分组",
                                            systemImage: "folder.badge.minus",
                                            role: .destructive
                                        ) {
                                            groupBeingRemoved = group.name
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("ShellHarbor")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    if editMode.isEditing {
                        Menu {
                            Button("新建分组…") { groupName = ""; isNamingGroup = true }
                            ForEach(groupNames, id: \.self) { name in
                                Button(name) { store.move(selection, toGroup: name); selection.removeAll() }
                            }
                            Button("移出分组") { store.move(selection, toGroup: ""); selection.removeAll() }
                            Divider()
                            Button("上移", systemImage: "arrow.up") {
                                store.moveRemotes(selection, direction: .up)
                            }
                            Button("下移", systemImage: "arrow.down") {
                                store.moveRemotes(selection, direction: .down)
                            }
                            Divider()
                            Button("删除", role: .destructive) {
                                confirmingRemoteDeletion = true
                            }
                        } label: {
                            Image(systemName: "folder")
                        }
                        .disabled(selection.isEmpty)
                    } else {
                        Button {
                            editingRemote = MobileRemoteProfile()
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .sheet(item: $editingRemote) { remote in
                RemoteEditorView(profile: remote) { saved in
                    store.save(saved)
                    inspectImmediatelyIfPossible(saved)
                    editingRemote = nil
                }
            }
            .sheet(item: $inspectionRemote) { remote in
                NavigationStack {
                    MobileInspectionView(remoteID: remote.id)
                        .navigationTitle(remote.name)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("完成") { inspectionRemote = nil }
                            }
                        }
                }
            }
            .alert("移动到新分组", isPresented: $isNamingGroup) {
                TextField("分组名称", text: $groupName)
                Button("移动") {
                    store.move(selection, toGroup: groupName)
                    selection.removeAll()
                }
                .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消", role: .cancel) {}
            }
            .alert(
                "删除 \(selection.count) 个 Remote？",
                isPresented: $confirmingRemoteDeletion
            ) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    let deletedIDs = selection
                    store.delete(ids: deletedIDs)
                    for id in deletedIDs { inspectionStore.clear(remoteID: id) }
                    selection.removeAll()
                    if store.remotes.isEmpty { editMode = .inactive }
                }
            } message: {
                Text("相关的已打开 Session 会断开并关闭；其他 Remote 对这些 JumpHost 的引用也会移除。")
            }
            .alert(
                "重命名分组",
                isPresented: Binding(
                    get: { groupBeingRenamed != nil },
                    set: { if !$0 { groupBeingRenamed = nil } }
                )
            ) {
                TextField("分组名称", text: $renamedGroupName)
                Button("重命名") {
                    guard let currentName = groupBeingRenamed else { return }
                    store.renameGroup(currentName, to: renamedGroupName)
                    groupBeingRenamed = nil
                }
                .disabled(renameGroupValidationMessage != nil)
                Button("取消", role: .cancel) { groupBeingRenamed = nil }
            } message: {
                if let renameGroupValidationMessage {
                    Text(renameGroupValidationMessage)
                }
            }
            .alert(
                "删除分组？",
                isPresented: Binding(
                    get: { groupBeingRemoved != nil },
                    set: { if !$0 { groupBeingRemoved = nil } }
                )
            ) {
                Button("取消", role: .cancel) { groupBeingRemoved = nil }
                Button("删除分组", role: .destructive) {
                    guard let name = groupBeingRemoved else { return }
                    store.removeGroup(named: name)
                    groupBeingRemoved = nil
                }
            } message: {
                Text("分组内的 Remote 会移到“未分组”，不会被删除。")
            }
        }
    }

    private var renameGroupValidationMessage: String? {
        guard let currentName = groupBeingRenamed else { return nil }
        let normalized = renamedGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return "请输入分组名称。" }
        if MobileRemoteGroupName.key(normalized) == MobileRemoteGroupName.key(currentName) {
            return "请输入不同的分组名称。"
        }
        if groupNames.contains(where: {
            MobileRemoteGroupName.key($0) == MobileRemoteGroupName.key(normalized)
        }) {
            return "已存在同名分组。"
        }
        return nil
    }

    private var groupedRemotes: [MobileRemoteGroupSection] {
        MobileRemoteGroupSection.sections(from: store.remotes)
    }

    private func remoteRow(_ remote: MobileRemoteProfile) -> some View {
        Button {
            open(remote)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: remote.remoteIcon.symbol)
                    .foregroundStyle(
                        remoteRowIsOffline(remote)
                            ? Color.secondary
                            : Color(shellHarborHex: remote.accentHex)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(remote.name).font(.headline)
                    Text(remote.endpoint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if remote.jumpRemoteID != nil {
                    Image(systemName: "link")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .accessibilityLabel("通过 JumpHost 连接")
                } else if remote.savedProxyID != nil || remote.proxyType != .none {
                    Image(systemName: "network")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .accessibilityLabel("通过 Proxy 连接")
                }
                remoteRuntimeStatus(remote)
                let count = activeSessions(for: remote).count
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color(shellHarborHex: remote.accentHex), in: Capsule())
                        .accessibilityLabel("\(count) 个已打开的 Session")
                }
                Text(remote.connectionMethod.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.12), in: Capsule())
                    .overlay {
                        Capsule().stroke(Color.green.opacity(0.35), lineWidth: 1)
                    }
            }
            .grayscale(remoteRowIsOffline(remote) ? 1 : 0)
            .opacity(remoteRowIsOffline(remote) ? 0.58 : 1)
        }
        .buttonStyle(.plain)
        .tag(remote.id)
        .contextMenu {
            Menu("连接方式") {
                ForEach(remote.availableConnectionMethods) { method in
                    Button(method.title) { open(remote, method: method) }
                }
            }
            Menu("设为默认连接方式") {
                ForEach(remote.availableConnectionMethods) { method in
                    Button {
                        var updated = remote
                        updated.connectionMethod = method
                        store.save(updated)
                    } label: {
                        if remote.connectionMethod == method {
                            Label(method.title, systemImage: "checkmark")
                        } else {
                            Text(method.title)
                        }
                    }
                }
            }
            Menu("快速启动") {
                ForEach(MobileTerminalMultiplexer.allCases) { multiplexer in
                    Button("新建 \(multiplexer.title) Session") {
                        openMultiplexer(remote, multiplexer: multiplexer)
                    }
                }
            }
            Menu("移动到分组") {
                Button {
                    store.move([remote.id], toGroup: "")
                } label: {
                    Label("未分组", systemImage: remote.remoteGroup.isEmpty ? "checkmark" : "tray")
                }
                if !groupNames.isEmpty {
                    Divider()
                    ForEach(groupNames, id: \.self) { name in
                        Button {
                            store.move([remote.id], toGroup: name)
                        } label: {
                            Label(
                                name,
                                systemImage: MobileRemoteGroupName.key(remote.remoteGroup) ==
                                    MobileRemoteGroupName.key(name) ? "checkmark" : "folder"
                            )
                        }
                    }
                }
                Divider()
                Button("新建分组…", systemImage: "folder.badge.plus") {
                    selection = [remote.id]
                    groupName = ""
                    isNamingGroup = true
                }
            }
            Button("巡检日志", systemImage: "waveform.path.ecg") {
                inspectionRemote = remote
            }
            Button("编辑") { editingRemote = remote }
            Button("复制", systemImage: "doc.on.doc") {
                editingRemote = store.duplicate(remote)
            }
            Divider()
            Button("删除 Remote", systemImage: "trash", role: .destructive) {
                selection = [remote.id]
                confirmingRemoteDeletion = true
            }
        }
        .swipeActions(edge: .leading) {
            Button("编辑") { editingRemote = remote }
                .tint(.blue)
        }
    }

    private func activeSessions(for remote: MobileRemoteProfile) -> [MobileSession] {
        store.sessions.filter { $0.remote.id == remote.id }
    }

    private func latestInspection(for remote: MobileRemoteProfile) -> MobileInspectionRecord? {
        inspectionStore.records(for: remote.id).first
    }

    private func inspectImmediatelyIfPossible(_ remote: MobileRemoteProfile) {
        guard remote.inspectionEnabled,
              let session = store.sessions.first(where: {
                  $0.remote.id == remote.id && $0.controller.state == .connected
              }) else {
            return
        }
        inspectionStore.inspect(session)
    }

    private func remoteRowIsOffline(_ remote: MobileRemoteProfile) -> Bool {
        let connected = activeSessions(for: remote).contains { $0.controller.state == .connected }
        return !connected && latestInspection(for: remote)?.healthStatus == .offline
    }

    @ViewBuilder
    private func remoteRuntimeStatus(_ remote: MobileRemoteProfile) -> some View {
        let sessions = activeSessions(for: remote)
        if inspectionStore.runningRemoteIDs.contains(remote.id) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("正在巡检")
        } else if sessions.contains(where: { $0.controller.state == .connected }) {
            statusIconTag(symbol: "checkmark.circle.fill", color: .green, label: "在线")
        } else if sessions.contains(where: { $0.controller.state == .connecting }) {
            statusTag("连接中", symbol: "arrow.trianglehead.2.clockwise.rotate.90", color: .orange)
        } else if let inspection = latestInspection(for: remote) {
            if inspection.healthStatus == .healthy {
                statusIconTag(
                    symbol: inspection.healthStatus.symbol,
                    color: inspection.healthStatus.color,
                    label: inspection.healthStatus.title
                )
                .accessibilityHint(
                    "最近巡检 \(inspection.timestamp.formatted(date: .abbreviated, time: .shortened))"
                )
            } else {
                statusTag(
                    inspection.healthStatus.title,
                    symbol: inspection.healthStatus.symbol,
                    color: inspection.healthStatus.color
                )
                .accessibilityHint(
                    "最近巡检 \(inspection.timestamp.formatted(date: .abbreviated, time: .shortened))"
                )
            }
        }
    }

    private func statusIconTag(symbol: String, color: Color, label: String) -> some View {
        Image(systemName: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(4)
            .background(color.opacity(0.13), in: Circle())
            .overlay {
                Circle().stroke(color.opacity(0.35), lineWidth: 1)
            }
            .accessibilityLabel(label)
    }

    private func statusTag(_ title: String, symbol: String, color: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.13), in: Capsule())
            .overlay {
                Capsule().stroke(color.opacity(0.35), lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
    }

    private func open(
        _ source: MobileRemoteProfile,
        method: MobileConnectionMethod? = nil,
        startupCommand: String? = nil,
        nameSuffix: String? = nil
    ) {
        var effectiveRemote = proxyStore.resolved(source)
        if let method { effectiveRemote.connectionMethod = method }
        let jumpRemote = source.jumpRemoteID.flatMap { id in
            store.remotes.first(where: { $0.id == id })
        }.map(proxyStore.resolved)
        let session = store.openSession(
            for: effectiveRemote,
            identityURL: keyStore.keyURL(forID: effectiveRemote.identityKeyID),
            jumpRemote: jumpRemote,
            jumpIdentityURL: keyStore.keyURL(forID: jumpRemote?.identityKeyID),
            trustedHostKey: knownHostStore.key(for: effectiveRemote.hostKeyEndpoint),
            trustedJumpHostKey: jumpRemote.flatMap { knownHostStore.key(for: $0.hostKeyEndpoint) },
            trustHostKey: { key in knownHostStore.trust(key, for: effectiveRemote.hostKeyEndpoint) },
            trustJumpHostKey: { key in
                guard let jumpRemote else { return }
                knownHostStore.trust(key, for: jumpRemote.hostKeyEndpoint)
            },
            autoTrustNewHosts: knownHostStore.autoTrustNewHosts,
            startupCommand: startupCommand,
            nameSuffix: nameSuffix
        )
        onSessionOpened(session.id)
    }

    private func openMultiplexer(
        _ remote: MobileRemoteProfile,
        multiplexer: MobileTerminalMultiplexer
    ) {
        let launch = multiplexer.launch()
        open(remote, startupCommand: launch.command, nameSuffix: launch.suffix)
    }
}

private struct RemoteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ImportedKeyStore.self) private var keyStore
    @Environment(RemoteStore.self) private var remoteStore
    @Environment(MobileProxyStore.self) private var proxyStore
    @State private var profile: MobileRemoteProfile
    @State private var cleartextPassword: String
    @State private var cleartextTailscaleAuthKey: String
    @State private var saveError: String?
    let onSave: (MobileRemoteProfile) -> Void

    init(profile: MobileRemoteProfile, onSave: @escaping (MobileRemoteProfile) -> Void) {
        _profile = State(initialValue: profile)
        let password: String
        if MobilePasswordCipher.isEncrypted(profile.password) {
            password = (try? MobilePasswordCipher.decrypt(profile.password)) ?? ""
        } else {
            password = profile.password
        }
        _cleartextPassword = State(initialValue: password)
        let tailscaleKey: String
        if MobilePasswordCipher.isEncrypted(profile.tailscaleAuthKey) {
            tailscaleKey = (try? MobilePasswordCipher.decrypt(profile.tailscaleAuthKey)) ?? ""
        } else {
            tailscaleKey = profile.tailscaleAuthKey
        }
        _cleartextTailscaleAuthKey = State(initialValue: tailscaleKey)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Remote") {
                    TextField("名称", text: $profile.name)
                    LabeledContent("分组") {
                        HStack {
                            TextField("未分组", text: $profile.remoteGroup)
                            Menu {
                                Button("未分组") { profile.remoteGroup = "" }
                                if !existingGroupNames.isEmpty { Divider() }
                                ForEach(existingGroupNames, id: \.self) { group in
                                    Button(group) { profile.remoteGroup = group }
                                }
                            } label: {
                                Image(systemName: "folder.badge.plus")
                            }
                        }
                    }
                    Picker("设备图标", selection: $profile.remoteIcon) {
                        ForEach(MobileRemoteIcon.allCases) { icon in
                            Label(icon.title, systemImage: icon.symbol).tag(icon)
                        }
                    }
                    ColorPicker(
                        "强调色",
                        selection: Binding(
                            get: { Color(shellHarborHex: profile.accentHex) },
                            set: { profile.accentHex = UIColor($0).shellHarborHex }
                        ),
                        supportsOpacity: false
                    )
                    TextField("主机", text: $profile.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("用户名", text: $profile.username)
                        .textInputAutocapitalization(.never)
                    TextField("端口", value: $profile.port, format: .number)
                        .keyboardType(.numberPad)
                    TextField("远程起始目录（可选）", text: $profile.remoteStartPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("连接") {
                    Picker("默认方式", selection: $profile.connectionMethod) {
                        ForEach(profile.availableConnectionMethods) {
                            Text($0.title).tag($0)
                        }
                    }
                    if profile.connectionMethod != .ssh {
                        if profile.connectionMethod == .jumpMosh {
                            TextField(
                                "跳板 mosh-server 命令（可选）",
                                text: $profile.jumpMoshServerCommand
                            )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            Text("留空时使用所选跳板 Remote 的 mosh-server 配置；该设置只属于当前 Remote。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            TextField("目标 mosh-server 命令", text: $profile.moshServerCommand)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        TextField("UDP 端口或范围（可选）", text: $profile.moshUDPPort)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Picker("保存的 Proxy", selection: $profile.savedProxyID) {
                        Text("不使用保存的配置").tag(UUID?.none)
                        ForEach(proxyStore.proxies) { proxy in
                            Text(proxy.name).tag(Optional(proxy.id))
                        }
                    }
                    if profile.savedProxyID == nil {
                        Picker("网络 Proxy", selection: $profile.proxyType) {
                            ForEach(MobileProxyType.allCases) {
                                Text($0.title).tag($0)
                            }
                        }
                    }
                    Picker("跳板 Remote", selection: $profile.jumpRemoteID) {
                        Text("无").tag(UUID?.none)
                        ForEach(remoteStore.remotes.filter { $0.id != profile.id }) { remote in
                            Text(remote.name).tag(Optional(remote.id))
                        }
                    }
                    .onChange(of: profile.jumpRemoteID) { _, _ in
                        profile.normalizeConnectionMethodForJumpRemote()
                    }
                    if profile.jumpRemoteID != nil {
                        Picker("SSH 跳板方式", selection: $profile.sshJumpMode) {
                            ForEach(MobileSSHJumpMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        Text("iOS 内嵌 SSH 会复用同一条跳板隧道；该选择同时保留给 macOS 的 SSH Jump 或 Forward 实现。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("认证", selection: $profile.authentication) {
                        ForEach(MobileAuthentication.allCases) {
                            Text($0.title).tag($0)
                        }
                    }
                    Picker("主机密钥", selection: $profile.hostKeyPolicy) {
                        ForEach(MobileHostKeyPolicy.allCases) {
                            Text($0.title).tag($0)
                        }
                    }
                    Text(profile.hostKeyPolicy.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Stepper(
                        "保活间隔：\(profile.keepAliveSeconds) 秒",
                        value: $profile.keepAliveSeconds,
                        in: 0...300,
                        step: 5
                    )
                    switch profile.authentication {
                    case .privateKey:
                        Picker("私钥", selection: $profile.identityKeyID) {
                            Text("未选择").tag(UUID?.none)
                            ForEach(keyStore.keys) { key in
                                Text(key.name).tag(Optional(key.id))
                            }
                        }
                    case .password:
                        SecureField("密码", text: $cleartextPassword)
                            .textContentType(.password)
                    case .agent:
                        Text("该方式会原样保留用于与 macOS 同步；iOS 无法访问 macOS 的 SSH Agent。连接前请改用已导入的私钥或密码。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if profile.savedProxyID == nil && profile.proxyType != .none {
                        TextField("共享名称", text: $profile.proxyName)
                    }
                    if profile.savedProxyID == nil && profile.proxyType == .tailscale {
                        TextField("Login Server", text: $profile.tailscaleLoginServer)
                            .textInputAutocapitalization(.never)
                            .onChange(of: profile.tailscaleLoginServer) { oldValue, newValue in
                                let oldDefault = sharedName(from: oldValue)
                                if profile.proxyName.isEmpty || profile.proxyName == oldDefault {
                                    profile.proxyName = sharedName(from: newValue)
                                }
                            }
                        TextField("认证密钥", text: $cleartextTailscaleAuthKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("节点名称", text: $profile.tailscaleNodeName)
                            .textInputAutocapitalization(.never)
                        Text("相同共享名称会复用同一个 Tailscale 节点；节点名称为空时自动使用 shellharbor-[random]。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if profile.savedProxyID == nil && [.socks5, .httpConnect].contains(profile.proxyType) {
                        TextField("Proxy 主机", text: $profile.proxyHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Proxy 端口", value: $profile.proxyPort, format: .number)
                            .keyboardType(.numberPad)
                    }
                }
                Section("自动巡检") {
                    Toggle("启用自动巡检", isOn: $profile.inspectionEnabled)
                    Stepper(
                        "巡检间隔：\(profile.inspectionIntervalMinutes) 分钟",
                        value: $profile.inspectionIntervalMinutes,
                        in: 1...1_440
                    )
                    .disabled(!profile.inspectionEnabled)
                    Text("保存时若该 Remote 已连接会立即巡检一次；之后仅在应用前台按间隔执行，不会额外建立 SSH 或 Tailscale 连接。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("采集内容") {
                    inspectionCapability("联通情况", icon: "network")
                    inspectionCapability("CPU 占用百分比", icon: "cpu")
                    inspectionCapability(
                        "内存占用百分比与空间",
                        icon: "memorychip"
                    )
                    inspectionCapability(
                        "磁盘总量、可用空间与占用百分比",
                        icon: "internaldrive"
                    )
                }
            }
            .task { selectOnlyIdentityKeyIfNeeded() }
            .onChange(of: keyStore.keys) { _, _ in selectOnlyIdentityKeyIfNeeded() }
            .navigationTitle("Remote 配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            var saved = profile
                            let trimmedHost = saved.host.trimmingCharacters(in: .whitespacesAndNewlines)
                            saved.host = trimmedHost.isEmpty ? "127.0.0.1" : trimmedHost
                            saved.remoteGroup = MobileRemoteGroupName.normalized(saved.remoteGroup)
                            saved.password = saved.authentication == .password
                                ? try MobilePasswordCipher.encrypt(cleartextPassword)
                                : ""
                            if saved.proxyType == .tailscale {
                                saved.tailscaleLoginServer = normalizedLoginServer(saved.tailscaleLoginServer)
                                if saved.proxyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    saved.proxyName = sharedName(from: saved.tailscaleLoginServer)
                                }
                                saved.tailscaleAuthKey = cleartextTailscaleAuthKey.isEmpty
                                    ? ""
                                    : try MobilePasswordCipher.encrypt(cleartextTailscaleAuthKey)
                            } else {
                                saved.tailscaleAuthKey = ""
                            }
                            if saved.savedProxyID == nil,
                               let proxyID = proxyStore.saveReusableProxy(from: saved) {
                                saved.savedProxyID = proxyID
                            }
                            onSave(saved)
                        } catch {
                            saveError = error.localizedDescription
                        }
                    }
                    .disabled(!isSaveEnabled)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
            }
            .alert("无法保存 Remote", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("好", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "未知错误")
            }
        }
    }

    private func selectOnlyIdentityKeyIfNeeded() {
        guard profile.authentication == .privateKey,
              profile.identityKeyID == nil,
              keyStore.keys.count == 1 else { return }
        profile.identityKeyID = keyStore.keys[0].id
    }

    private func inspectionCapability(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .foregroundStyle(profile.inspectionEnabled ? .primary : .secondary)
    }

    private var existingGroupNames: [String] {
        MobileRemoteGroupSection.sections(
            from: remoteStore.remotes.filter { $0.id != profile.id }
        ).map(\.name).filter { !$0.isEmpty }
    }

    private var validationMessage: String? {
        if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请输入 Remote 名称。"
        }
        if profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请输入用户名。"
        }
        if !(1...65_535).contains(profile.port) {
            return "SSH 端口必须在 1–65535 之间。"
        }
        if profile.authentication == .password && cleartextPassword.isEmpty {
            return "请输入密码。"
        }
        if profile.authentication == .privateKey && profile.identityKeyID == nil {
            return "请选择 SSH 私钥。"
        }
        if profile.connectionMethod == .jumpMosh && profile.jumpRemoteID == nil {
            return "跳板 Mosh 必须选择一个跳板 Remote。"
        }
        if profile.savedProxyID == nil,
           [.socks5, .httpConnect].contains(profile.proxyType) {
            if profile.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "请输入 Proxy 主机。"
            }
            if !(1...65_535).contains(profile.proxyPort) {
                return "Proxy 端口必须在 1–65535 之间。"
            }
        }
        if profile.savedProxyID == nil,
           profile.proxyType == .tailscale,
           cleartextTailscaleAuthKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请输入 Tailscale 认证密钥。"
        }
        return nil
    }

    private var isSaveEnabled: Bool { validationMessage == nil }

    private func normalizedLoginServer(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    }

    private func sharedName(from loginServer: String) -> String {
        let normalized = normalizedLoginServer(loginServer)
        guard !normalized.isEmpty else { return "" }
        return normalized
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private struct MobileProxyEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: MobileProxyProfile
    @State private var cleartextAuthKey: String
    @State private var errorMessage: String?
    let onSave: (MobileProxyProfile) -> Void

    init(profile: MobileProxyProfile, onSave: @escaping (MobileProxyProfile) -> Void) {
        _profile = State(initialValue: profile)
        _cleartextAuthKey = State(initialValue: MobilePasswordCipher.isEncrypted(profile.tailscaleAuthKey)
            ? ((try? MobilePasswordCipher.decrypt(profile.tailscaleAuthKey)) ?? "")
            : profile.tailscaleAuthKey)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Proxy") {
                    TextField("名称", text: $profile.name)
                    Picker("类型", selection: $profile.type) {
                        ForEach(MobileProxyType.allCases.filter { $0 != .none }) { type in
                            Text(type.title).tag(type)
                        }
                    }
                }
                if profile.type == .tailscale {
                    Section("Tailscale") {
                        TextField("Login Server", text: $profile.tailscaleLoginServer)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: profile.tailscaleLoginServer) { oldValue, newValue in
                                let oldDefault = tailscaleSharedName(oldValue)
                                if profile.name.isEmpty || profile.name == oldDefault {
                                    profile.name = tailscaleSharedName(newValue)
                                }
                            }
                        TextField("认证密钥", text: $cleartextAuthKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("节点名称", text: $profile.tailscaleNodeName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("本地 SOCKS5 端口由 ShellHarbor 从 15040 开始自动分配。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("服务器") {
                        TextField("主机", text: $profile.host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("端口", value: $profile.port, format: .number)
                            .keyboardType(.numberPad)
                    }
                }
            }
            .navigationTitle("Proxy 配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            var saved = profile
                            if saved.type == .tailscale {
                                let trimmed = saved.tailscaleLoginServer.trimmingCharacters(in: .whitespacesAndNewlines)
                                saved.tailscaleLoginServer = trimmed.isEmpty || trimmed.contains("://")
                                    ? trimmed : "https://\(trimmed)"
                                if saved.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    saved.name = tailscaleSharedName(saved.tailscaleLoginServer)
                                }
                                saved.tailscaleAuthKey = cleartextAuthKey.isEmpty
                                    ? "" : try MobilePasswordCipher.encrypt(cleartextAuthKey)
                            } else {
                                saved.tailscaleAuthKey = ""
                            }
                            onSave(saved)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(proxyValidationMessage != nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let proxyValidationMessage {
                    Text(proxyValidationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
            }
            .alert("无法保存 Proxy", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "未知错误")
            }
        }
    }

    private var proxyValidationMessage: String? {
        if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           profile.type != .tailscale {
            return "请输入 Proxy 名称。"
        }
        if profile.type == .tailscale {
            if cleartextAuthKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "请输入 Tailscale 认证密钥。"
            }
        } else {
            if profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "请输入 Proxy 主机。"
            }
            if !(1...65_535).contains(profile.port) {
                return "Proxy 端口必须在 1–65535 之间。"
            }
        }
        return nil
    }

    private func tailscaleSharedName(_ loginServer: String) -> String {
        let value = loginServer
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return value.isEmpty ? "Tailscale 官方服务" : value
    }
}

private struct SessionListView: View {
    @Environment(RemoteStore.self) private var store
    @Environment(ImportedKeyStore.self) private var keyStore
    @Environment(KnownHostStore.self) private var knownHostStore
    @Environment(MobileProxyStore.self) private var proxyStore
    @Binding var requestedSessionID: UUID?
    let onSelectedSessionChanged: (UUID?) -> Void
    @State private var renamingSession: MobileSession?
    @State private var editingRemote: MobileRemoteProfile?
    @State private var sessionSuffix = ""
    @State private var navigationPath: [UUID] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                if store.sessions.isEmpty {
                    ForEach(store.cachedSessionSummaries) { session in
                        HStack {
                            Image(systemName: session.iconSymbol)
                                .foregroundStyle(
                                    Color(shellHarborHex: session.accentHex)
                                )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.displayName)
                                Text(session.endpoint)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(session.connectionMethod)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel("\(session.displayName)，正在恢复")
                    }
                }
                ForEach(store.sessions) { session in
                    NavigationLink(value: session.id) {
                        HStack {
                            Image(systemName: session.remoteIcon.symbol)
                                .foregroundStyle(Color(shellHarborHex: session.accentHex))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.displayName)
                                Text(session.remote.endpoint)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(session.controller.state.title)
                                    .font(.caption)
                                    .foregroundStyle(
                                        session.controller.state == .connected
                                            ? .green
                                            : .secondary
                                    )
                                Text(session.remote.connectionMethod.title)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Color.green.opacity(0.12),
                                        in: Capsule()
                                    )
                                    .overlay {
                                        Capsule().stroke(
                                            Color.green.opacity(0.35),
                                            lineWidth: 1
                                        )
                                    }
                            }
                        }
                    }
                    .contextMenu {
                        Button("重新连接", systemImage: "arrow.clockwise") {
                            session.controller.reconnect()
                        }
                        .disabled(session.controller.state == .connecting)
                        Button("断开连接", systemImage: "xmark.circle") {
                            session.controller.disconnect()
                        }
                        .disabled(
                            session.controller.state == .disconnected ||
                                session.controller.state == .idle
                        )
                        Button("改名", systemImage: "pencil") {
                            renamingSession = session
                            sessionSuffix = session.sessionLabel
                        }
                        Divider()
                        Button("关闭 Session", systemImage: "xmark") {
                            closeSession(session.id)
                        }
                        Button("关闭其他 Session", systemImage: "xmark.circle") {
                            store.closeOtherSessions(keeping: session.id)
                            navigationPath = navigationPath.filter { $0 == session.id }
                        }
                        .disabled(store.sessions.count <= 1)
                        Button("关闭下方 Session", systemImage: "xmark.square") {
                            store.closeSessionsAfter(id: session.id)
                        }
                        .disabled(store.sessions.last?.id == session.id)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            session.controller.reconnect()
                        } label: {
                            Label("重连", systemImage: "arrow.clockwise")
                        }
                        .tint(.blue)
                        .disabled(session.controller.state == .connecting)
                    }
                }
                .onDelete(perform: store.closeSessions)
                .onMove(perform: store.moveSessions)
            }
            .overlay {
                if store.sessions.isEmpty &&
                    store.cachedSessionSummaries.isEmpty {
                    ContentUnavailableView(
                        "没有打开的 Session",
                        systemImage: "terminal",
                        description: Text("从 Remote 页面点击一个配置")
                    )
                }
            }
            .navigationTitle("Session")
            .navigationDestination(for: UUID.self) { sessionID in
                if let session = store.sessions.first(where: { $0.id == sessionID }) {
                    MobileTerminalSessionView(
                        session: session,
                        onNewSession: {
                            let source = store.remotes.first(where: { $0.id == session.remote.id })
                                ?? session.remote
                            open(source)
                        },
                        onNewMultiplexerSession: { multiplexer in
                            let source = store.remotes.first(where: { $0.id == session.remote.id })
                                ?? session.remote
                            openMultiplexer(source, multiplexer: multiplexer)
                        },
                        onAttachTmuxSession: { name in
                            let source = store.remotes.first(where: { $0.id == session.remote.id })
                                ?? session.remote
                            openMultiplexer(source, multiplexer: .tmux, sessionName: name)
                        },
                        onEditRemote: {
                            editingRemote = store.remotes.first(where: {
                                $0.id == session.remote.id
                            })
                        },
                        onCloseSession: { closeSession(session.id) }
                    )
                    .id(session.id)
                } else {
                    ContentUnavailableView("Session 已关闭", systemImage: "terminal")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(store.remotes) { remote in
                            Menu(remote.name) {
                                Button("新建 Session", systemImage: "terminal") {
                                    open(remote)
                                }
                                Divider()
                                ForEach(MobileTerminalMultiplexer.allCases) { multiplexer in
                                    Button(
                                        "新建 \(multiplexer.title) Session",
                                        systemImage: "bolt.fill"
                                    ) {
                                        openMultiplexer(remote, multiplexer: multiplexer)
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(store.remotes.isEmpty)
                    .accessibilityLabel("新建 Session")
                    .accessibilityHint(
                        currentRemoteForNewSession.map {
                            "点击选择 Remote，并新建 \($0.name) 或 tmux Session"
                        } ?? "点击选择 Remote"
                    )
                }
            }
            .alert("Session 改名", isPresented: Binding(
                get: { renamingSession != nil },
                set: { if !$0 { renamingSession = nil } }
            )) {
                TextField("名称后缀", text: $sessionSuffix)
                Button("保存") {
                    renamingSession?.nameSuffix = sessionSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
                    renamingSession = nil
                    store.persistSessionRestoration()
                }
                Button("取消", role: .cancel) { renamingSession = nil }
            } message: {
                Text("Remote 名称保持不变，只修改 Session 后缀。")
            }
            .sheet(item: $editingRemote) { remote in
                RemoteEditorView(profile: remote) { saved in
                    store.save(saved)
                    editingRemote = nil
                }
            }
            .onAppear { openRequestedSessionIfNeeded() }
            .onChange(of: requestedSessionID) { _, _ in openRequestedSessionIfNeeded() }
            .onChange(of: navigationPath) { _, path in
                onSelectedSessionChanged(path.last)
            }
        }
    }

    private func openRequestedSessionIfNeeded() {
        guard let sessionID = requestedSessionID,
              store.sessions.contains(where: { $0.id == sessionID }) else { return }
        navigationPath = [sessionID]
        requestedSessionID = nil
    }

    private var currentRemoteForNewSession: MobileRemoteProfile? {
        let activeSession = navigationPath.last.flatMap { sessionID in
            store.sessions.first(where: { $0.id == sessionID })
        } ?? store.sessions.last
        guard let remoteID = activeSession?.remote.id else {
            return store.remotes.first
        }
        return store.remotes.first(where: { $0.id == remoteID }) ?? store.remotes.first
    }

    private func closeSession(_ id: UUID) {
        let wasSelected = navigationPath.last == id
        let replacementID = store.closeSession(id: id)
        if wasSelected {
            navigationPath = replacementID.map { [$0] } ?? []
        } else {
            navigationPath.removeAll { $0 == id }
        }
    }

    private func open(
        _ source: MobileRemoteProfile,
        startupCommand: String? = nil,
        nameSuffix: String? = nil
    ) {
        let remote = proxyStore.resolved(source)
        let jumpRemote = source.jumpRemoteID.flatMap { id in
            store.remotes.first(where: { $0.id == id })
        }.map(proxyStore.resolved)
        let session = store.openSession(
            for: remote,
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
            startupCommand: startupCommand,
            nameSuffix: nameSuffix
        )
        // A Session is a peer tab, not a nested terminal destination. Keeping
        // the previous SwiftTerm view underneath a newly pushed tmux view can
        // leave two first-responder terminal hierarchies alive and crash when
        // the second session enters alternate-screen mode.
        navigationPath = [session.id]
    }

    private func openMultiplexer(
        _ remote: MobileRemoteProfile,
        multiplexer: MobileTerminalMultiplexer,
        sessionName: String? = nil
    ) {
        let launch = multiplexer.launch(sessionName: sessionName)
        open(remote, startupCommand: launch.command, nameSuffix: launch.suffix)
    }
}

private struct MobileTerminalSessionView: View {
    @Environment(RemoteStore.self) private var store
    @Environment(MobileInspectionStore.self) private var inspectionStore
    @Environment(MobileAppCommandRouter.self) private var commandRouter
    let session: MobileSession
    let onNewSession: () -> Void
    let onNewMultiplexerSession: (MobileTerminalMultiplexer) -> Void
    let onAttachTmuxSession: (String) -> Void
    let onEditRemote: () -> Void
    let onCloseSession: () -> Void
    @State private var showingCommandHistory = false
    @State private var showingTerminalSettings = false
    @State private var showingTerminalSearch = false
    @State private var terminalSearchText = ""
    @FocusState private var terminalSearchFocused: Bool
    @State private var commandToken = UUID()
    @State private var tmuxSessions: [String] = []
    @State private var loadingTmuxSessions = false
    @State private var tmuxRefreshError: String?

    var body: some View {
        VStack(spacing: 0) {
            sessionConnectionSummary

            if session.selectedView.showsTerminal && showingTerminalSearch {
                terminalSearchBar
            }

            if session.selectedView.showsTerminal {
                terminalKeyBar
            }

            ZStack(alignment: .top) {
                GeometryReader { geometry in
                    let dividerHeight: CGFloat = session.selectedView == .workspace ? 1 : 0
                    let availableHeight = max(0, geometry.size.height - dividerHeight)
                    let terminalHeight: CGFloat = switch session.selectedView {
                    case .terminal: availableHeight
                    case .workspace: availableHeight * 0.46
                    case .files, .inspection: 0
                    }
                    let secondaryHeight = max(0, availableHeight - terminalHeight)

                    VStack(spacing: 0) {
                        // Keep the same SwiftTerm view mounted while switching
                        // modes so cursor, alternate-screen and scrollback state
                        // are not reconstructed from a bounded byte replay.
                        MobileTerminalView(controller: session.controller)
                            .frame(height: terminalHeight)
                            .opacity(session.selectedView.showsTerminal ? 1 : 0)
                            .allowsHitTesting(session.selectedView.showsTerminal)
                            .accessibilityHidden(!session.selectedView.showsTerminal)
                            .dropDestination(for: String.self) { paths, _ in
                                guard !paths.isEmpty else { return false }
                                session.controller.insertRemotePaths(paths)
                                return true
                            }
                            .clipped()

                        Divider()
                            .frame(height: dividerHeight)
                            .opacity(session.selectedView == .workspace ? 1 : 0)

                        if session.selectedView == .files || session.selectedView == .workspace {
                            MobileRemoteFilesView(session: session)
                                .frame(height: secondaryHeight)
                                .clipped()
                        } else if session.selectedView == .inspection {
                            MobileInspectionView(session: session)
                                .frame(height: secondaryHeight)
                                .clipped()
                        }
                    }
                }
                connectionOverlay
            }
        }
        .background(session.selectedView.showsTerminal ? Color.black : Color(uiColor: .systemBackground))
        .navigationTitle(session.controller.title.isEmpty ? session.displayName : session.controller.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("视图") {
                        ForEach(MobileSession.ViewMode.allCases) { mode in
                            Button {
                                session.selectedView = mode
                            } label: {
                                Label(
                                    mode.title,
                                    systemImage: session.selectedView == mode
                                        ? "checkmark"
                                        : mode.icon
                                )
                            }
                        }
                    }
                    if session.selectedView.showsTerminal {
                        Divider()
                        Label(session.controller.state.title, systemImage: connectionStateSymbol)
                        Divider()
                        Button("发送 Ctrl-C", systemImage: "stop.circle") {
                            session.controller.sendInterrupt()
                        }
                        .disabled(session.controller.state != .connected)
                        Button("本地清屏", systemImage: "eraser") {
                            session.controller.clearLocalBuffer()
                        }
                        .disabled(session.controller.state != .connected)
                        Button("查找终端内容", systemImage: "magnifyingglass") {
                            showingTerminalSearch = true
                            terminalSearchFocused = true
                        }
                        Button("远程命令历史", systemImage: "clock.arrow.circlepath") {
                            showingCommandHistory = true
                        }
                        .disabled(session.controller.state != .connected)
                        Button("终端外观与缓冲区", systemImage: "paintpalette") {
                            showingTerminalSettings = true
                        }
                        Button("重新连接", systemImage: "arrow.clockwise") {
                            session.controller.reconnect()
                        }
                        .disabled(session.controller.state == .connecting)
                    }
                    Divider()
                    Button("编辑 Remote", systemImage: "slider.horizontal.3") {
                        onEditRemote()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Session 更多操作")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("新建 Session", systemImage: "terminal") {
                        onNewSession()
                    }
                    Divider()
                    if !tmuxSessions.isEmpty {
                        Section("已有 tmux 会话") {
                            ForEach(tmuxSessions, id: \.self) { name in
                                Button(name, systemImage: "rectangle.on.rectangle") {
                                    onAttachTmuxSession(name)
                                }
                            }
                        }
                        Divider()
                    }
                    if let tmuxRefreshError {
                        Text(tmuxRefreshError)
                    }
                    ForEach(MobileTerminalMultiplexer.allCases) { multiplexer in
                        Button(
                            "新建 \(multiplexer.title) Session",
                            systemImage: "bolt.fill"
                        ) {
                            onNewMultiplexerSession(multiplexer)
                        }
                    }
                    Button(
                        loadingTmuxSessions ? "正在识别…" : "刷新已有 tmux 会话",
                        systemImage: "arrow.clockwise"
                    ) {
                        Task { await refreshTmuxSessions() }
                    }
                    .disabled(
                        loadingTmuxSessions || session.controller.state != .connected
                    )
                } label: {
                    Image(systemName: "plus")
                }
                .simultaneousGesture(
                    TapGesture().onEnded {
                        Task { await refreshTmuxSessions() }
                    }
                )
                .accessibilityLabel("新建 Session")
                .accessibilityHint("点击显示新建 Session 与 tmux 快速启动")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { onCloseSession() } label: {
                    Label("关闭 Session", systemImage: "xmark.circle")
                }
                .accessibilityHint("断开连接并移除当前 Session")
            }
        }
        .onDisappear { store.persistSessionRestoration() }
        .onAppear {
            registerAppCommands()
            Task { await refreshTmuxSessions() }
        }
        .onDisappear { commandRouter.unregister(token: commandToken) }
        .onChange(of: session.selectedView) { _, view in
            guard !view.showsTerminal else { return }
            showingTerminalSearch = false
            terminalSearchFocused = false
            session.controller.clearTerminalSearch()
        }
        .onChange(of: session.controller.state) { _, state in
            registerAppCommands()
            if state == .connected {
                Task { await refreshTmuxSessions() }
            }
            guard state == .connected,
                  store.remotes.first(where: { $0.id == session.remote.id })?.inspectionEnabled == true
            else { return }
            inspectionStore.inspect(session)
        }
        .sheet(isPresented: $showingCommandHistory) {
            MobileCommandHistoryView(session: session)
        }
        .sheet(isPresented: $showingTerminalSettings) {
            MobileTerminalSettingsView()
        }
        .alert(item: Binding(
            get: { session.controller.hostKeyPrompt },
            set: { _ in }
        )) { prompt in
            Alert(
                title: Text(prompt.isChanged ? "主机密钥已更改" : "确认 SSH 主机密钥"),
                message: Text("\(prompt.endpoint)\n\n\(prompt.algorithm) 指纹：\n\(prompt.fingerprint)\n\n仅在确认这是目标主机时继续。"),
                primaryButton: .default(Text("信任并连接")) { session.controller.acceptHostKey() },
                secondaryButton: .cancel(Text("取消")) { session.controller.rejectHostKey() }
            )
        }
    }

    private func refreshTmuxSessions() async {
        guard session.controller.state == .connected,
              !loadingTmuxSessions else { return }
        loadingTmuxSessions = true
        defer { loadingTmuxSessions = false }
        do {
            let output = try await session.controller.executeInspectionCommand(
                MobileTerminalMultiplexer.listingCommand
            )
            tmuxSessions = MobileTerminalMultiplexer.parseSessions(output)
            tmuxRefreshError = MobileTerminalMultiplexer.parseError(output)
        } catch {
            tmuxSessions = []
            tmuxRefreshError = error.localizedDescription
        }
    }

    private var terminalSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("查找终端内容", text: $terminalSearchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($terminalSearchFocused)
                .onSubmit { findTerminalText(forward: true) }
                .onChange(of: terminalSearchText) { _, value in
                    if value.isEmpty { session.controller.clearTerminalSearch() }
                }
            if !terminalSearchText.isEmpty, let found = session.controller.searchFound {
                Text(found ? "已匹配" : "无结果")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36)
            }
            Button { findTerminalText(forward: false) } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(terminalSearchText.isEmpty)
            Button { findTerminalText(forward: true) } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(terminalSearchText.isEmpty)
            Button {
                showingTerminalSearch = false
                terminalSearchFocused = false
                session.controller.clearTerminalSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("关闭查找")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var sessionConnectionSummary: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connectionStateColor)
                .frame(width: 7, height: 7)
            Text(connectionSummaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 7)
        .accessibilityElement(children: .combine)
    }

    private var connectionSummaryText: String {
        var parts = [
            session.remote.endpoint,
            session.remote.connectionMethod.title
        ]
        if let jumpRemote = session.jumpRemote {
            parts.append("经 \(jumpRemote.name)")
        } else if session.remote.proxyType != .none ||
                    session.remote.savedProxyID != nil {
            let proxyName = session.remote.proxyName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            parts.append(
                proxyName.isEmpty
                    ? session.remote.proxyType.title
                    : proxyName
            )
        }
        if session.controller.state != .connected {
            parts.append(session.controller.state.title)
        }
        return parts.joined(separator: " · ")
    }

    private var terminalKeyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                terminalKeyButton("Esc", bytes: [0x1B])
                terminalKeyButton("⇥", bytes: [0x09])
                terminalKeyButton("⌃C", bytes: [0x03])
                Divider().frame(height: 22)
                terminalKeyButton("←", bytes: [0x1B, 0x5B, 0x44])
                terminalKeyButton("↓", bytes: [0x1B, 0x5B, 0x42])
                terminalKeyButton("↑", bytes: [0x1B, 0x5B, 0x41])
                terminalKeyButton("→", bytes: [0x1B, 0x5B, 0x43])
                terminalKeyButton("↵", bytes: [0x0D])
                terminalKeyboardButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var terminalKeyboardButton: some View {
        Button {
            session.controller.toggleTerminalKeyboard()
        } label: {
            Image(systemName: "keyboard")
                .font(.body.weight(.medium))
                .frame(height: 14)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel("显示或收起键盘")
    }

    private func terminalKeyButton(
        _ title: String,
        bytes: [UInt8]
    ) -> some View {
        let usesLargeSymbol = title == "⇥" || title == "↵"
        return Button(title) {
            session.controller.send(bytes[...])
        }
        .font(
            usesLargeSymbol
                ? .title3.weight(.semibold)
                : .caption.monospaced().weight(.medium)
        )
        .frame(height: 14)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(session.controller.state != .connected)
        .accessibilityLabel("发送 \(title)")
    }

    private func findTerminalText(forward: Bool) {
        session.controller.findTerminalText(terminalSearchText, forward: forward)
    }

    private func registerAppCommands() {
        commandRouter.register(
            token: commandToken,
            newSession: onNewSession,
            closeSession: onCloseSession,
            reconnect: { session.controller.reconnect() },
            disconnect: { session.controller.disconnect() },
            interrupt: { session.controller.sendInterrupt() },
            clearTerminal: { session.controller.clearLocalBuffer() },
            findTerminal: {
                showingTerminalSearch = true
                terminalSearchFocused = true
            },
            canReconnect: session.controller.state != .connecting,
            canDisconnect: session.controller.state != .idle &&
                session.controller.state != .disconnected,
            canUseConnectedTerminal: session.controller.state == .connected
        )
    }

    private var connectionStateSymbol: String {
        switch session.controller.state {
        case .connected: "checkmark.circle.fill"
        case .connecting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .failed: "exclamationmark.triangle.fill"
        case .idle, .disconnected: "circle"
        }
    }

    private var connectionStateColor: Color {
        switch session.controller.state {
        case .connected: .green
        case .connecting: .blue
        case .failed: .red
        case .idle, .disconnected: .secondary
        }
    }

    @ViewBuilder
    private var connectionOverlay: some View {
        if case .failed(let message) = session.controller.state {
            VStack(spacing: 10) {
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = message
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    Button {
                        session.controller.reconnect()
                    } label: {
                        Label("重新连接", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        } else if session.controller.state == .connecting {
            ProgressView("正在连接 \(session.remote.endpoint)")
                .padding()
                .background(.regularMaterial, in: Capsule())
                .padding()
        } else if session.controller.state == .disconnected {
            Button("重新连接") { session.controller.reconnect() }
                .padding()
                .background(.regularMaterial, in: Capsule())
                .padding()
        }
    }
}

private extension MobileSession.ViewMode {
    var showsTerminal: Bool {
        self == .terminal || self == .workspace
    }
}

private struct MobileTerminalSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("mobileTerminalFont") private var terminalFont =
        MobileTerminalFont.dejaVuSansMono.rawValue
    @AppStorage("mobileTerminalFontSize") private var terminalFontSize =
        MobileTerminalFontSizeSettings.defaultSize
    @AppStorage("mobileTerminalTheme") private var terminalTheme =
        MobileTerminalTheme.night.rawValue
    @AppStorage("mobileTerminalScrollbackLines") private var terminalScrollbackLines =
        MobileTerminalScrollbackSettings.defaultLines
    @State private var terminalScrollbackDraft = ""

    private let presets = [
        10_000, 50_000, 100_000, 200_000, 500_000, 1_000_000
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("外观") {
                    Picker("主题", selection: $terminalTheme) {
                        ForEach(MobileTerminalTheme.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                    }
                    Picker("字体", selection: $terminalFont) {
                        ForEach(MobileTerminalFont.allCases) { font in
                            Text(font.rawValue).tag(font.rawValue)
                        }
                    }
                    Stepper(
                        value: $terminalFontSize,
                        in: MobileTerminalFontSizeSettings.allowedSizes,
                        step: 1
                    ) {
                        LabeledContent("字体大小", value: "\(Int(terminalFontSize)) pt")
                    }
                    Text("设备未安装所选字体时自动使用系统等宽字体。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("滚动缓冲区") {
                    Picker("行数", selection: $terminalScrollbackLines) {
                        ForEach(presets, id: \.self) { lines in
                            Text(lines.formatted()).tag(lines)
                        }
                        if !presets.contains(terminalScrollbackLines) {
                            Text("\(terminalScrollbackLines.formatted())（自定义）")
                                .tag(terminalScrollbackLines)
                        }
                    }
                    .onChange(of: terminalScrollbackLines) { _, lines in
                        terminalScrollbackDraft = String(lines)
                    }
                    HStack {
                        TextField("自定义行数", text: $terminalScrollbackDraft)
                            .keyboardType(.numberPad)
                            .onSubmit(applyScrollbackDraft)
                        Button("应用", action: applyScrollbackDraft)
                            .disabled(parsedScrollbackDraft == nil)
                    }
                    Text("允许 1,000–1,000,000 行；修改会立即应用到所有 Session。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("终端设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                terminalScrollbackDraft = String(terminalScrollbackLines)
            }
        }
    }

    private var parsedScrollbackDraft: Int? {
        let value = terminalScrollbackDraft.replacingOccurrences(of: ",", with: "")
        guard let lines = Int(value),
              MobileTerminalScrollbackSettings.allowedLines.contains(lines) else {
            return nil
        }
        return lines
    }

    private func applyScrollbackDraft() {
        guard let parsedScrollbackDraft else { return }
        terminalScrollbackLines = parsedScrollbackDraft
        terminalScrollbackDraft = String(parsedScrollbackDraft)
    }
}

private struct MobileCommandHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let session: MobileSession
    @State private var errorMessage: String?

    private var filteredEntries: [MobileCommandHistoryEntry] {
        let query = session.commandHistorySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return session.commandHistory }
        return session.commandHistory.filter {
            $0.command.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredEntries) { entry in
                Button {
                    session.controller.insertTerminalText(entry.command)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.command)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let date = entry.date {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu {
                    Button("复制命令", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = entry.command
                    }
                }
            }
            .overlay {
                if session.isLoadingCommandHistory {
                    ProgressView("正在读取远程历史…")
                } else if let errorMessage {
                    ContentUnavailableView("读取失败", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else if filteredEntries.isEmpty {
                    ContentUnavailableView(
                        session.commandHistorySearch.isEmpty ? "没有历史记录" : "没有匹配命令",
                        systemImage: "clock",
                        description: Text("支持读取远端 zsh、bash 和 fish 的历史文件。")
                    )
                }
            }
            .searchable(
                text: Binding(
                    get: { session.commandHistorySearch },
                    set: { session.commandHistorySearch = $0 }
                ),
                prompt: "搜索远程命令"
            )
            .navigationTitle("远程命令历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("刷新", systemImage: "arrow.clockwise") { Task { await load() } }
                        .disabled(session.isLoadingCommandHistory)
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard !session.isLoadingCommandHistory else { return }
        session.isLoadingCommandHistory = true
        errorMessage = nil
        do {
            session.commandHistory = try await session.controller.loadCommandHistory()
        } catch {
            errorMessage = error.localizedDescription
        }
        session.isLoadingCommandHistory = false
    }
}

private enum IOSSettingsImportMode {
    case identityKey
    case configuration

    var contentTypes: [UTType] {
        switch self {
        case .identityKey: [.data, .plainText]
        case .configuration: [.json]
        }
    }
}

private struct IOSSettingsView: View {
    @Environment(RemoteStore.self) private var remoteStore
    @Environment(ImportedKeyStore.self) private var keyStore
    @Environment(KnownHostStore.self) private var knownHostStore
    @Environment(MobileProxyStore.self) private var proxyStore
    @State private var importMode: IOSSettingsImportMode?
    @State private var isFileImporterPresented = false
    @State private var importError: String?
    @State private var isExportingConfiguration = false
    @State private var exportDocument = ShellHarborConfigurationDocument()
    @State private var transferStatus = ""
    @State private var editingProxy: MobileProxyProfile?
    @State private var proxyIDsPendingDeletion: Set<UUID> = []
    @State private var identityKeyPendingDeletion: ImportedIdentityKey?
    @State private var isConfirmingKnownHostsClear = false
    @State private var areIdentityKeysExpanded = false
    @AppStorage("mobileTerminalFont") private var terminalFont = MobileTerminalFont.dejaVuSansMono.rawValue
    @AppStorage("mobileTerminalFontSize") private var terminalFontSize =
        MobileTerminalFontSizeSettings.defaultSize
    @AppStorage("mobileTerminalTheme") private var terminalTheme = MobileTerminalTheme.night.rawValue
    @AppStorage("mobileTerminalScrollbackLines") private var terminalScrollbackLines = MobileTerminalScrollbackSettings.defaultLines
    @AppStorage("mobileBackgroundKeepAliveEnabled")
    private var backgroundKeepAliveEnabled = false
    @State private var terminalScrollbackDraft = ""

    private let terminalScrollbackPresets = [
        10_000, 50_000, 100_000, 200_000, 500_000, 1_000_000
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("平台") {
                    LabeledContent("最低版本", value: "iOS 17")
                    LabeledContent("界面", value: "SwiftUI")
                }
                Section("后台") {
                    Toggle("后台连接保活", isOn: $backgroundKeepAliveEnabled)
                    Text("默认关闭。开启后，有活动连接时会使用低精度后台定位维持 SSH、Mosh 和 Tailscale 连接；首次开启需要允许始终访问位置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup(isExpanded: $areIdentityKeysExpanded) {
                        Button {
                            importMode = .identityKey
                            isFileImporterPresented = true
                        } label: {
                            Label("导入 id_rsa.key", systemImage: "square.and.arrow.down")
                        }
                        ForEach(keyStore.keys) { key in
                            HStack {
                                Image(systemName: "key.fill")
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading) {
                                    Text(key.name)
                                    Text(key.importedAt, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    identityKeyPendingDeletion = key
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    } label: {
                        Label("SSH 私钥（\(keyStore.keys.count)）", systemImage: "key")
                    }
                }
                Section("终端") {
                    Picker("主题", selection: $terminalTheme) {
                        ForEach(MobileTerminalTheme.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                    }
                    Picker("字体", selection: $terminalFont) {
                        ForEach(MobileTerminalFont.allCases) { font in
                            Text(font.rawValue).tag(font.rawValue)
                        }
                    }
                    Stepper(
                        value: $terminalFontSize,
                        in: MobileTerminalFontSizeSettings.allowedSizes,
                        step: 1
                    ) {
                        LabeledContent("字体大小", value: "\(Int(terminalFontSize)) pt")
                    }
                    Picker("滚动缓冲区", selection: $terminalScrollbackLines) {
                        ForEach(terminalScrollbackPresets, id: \.self) { lines in
                            Text(lines.formatted()).tag(lines)
                        }
                        if !terminalScrollbackPresets.contains(terminalScrollbackLines) {
                            Text("\(terminalScrollbackLines.formatted())（自定义）")
                                .tag(terminalScrollbackLines)
                        }
                    }
                    .onChange(of: terminalScrollbackLines) { _, lines in
                        terminalScrollbackDraft = String(lines)
                    }
                    HStack {
                        TextField("自定义行数", text: $terminalScrollbackDraft)
                            .keyboardType(.numberPad)
                            .onSubmit(applyTerminalScrollbackDraft)
                        Button("应用", action: applyTerminalScrollbackDraft)
                            .disabled(parsedTerminalScrollbackDraft == nil)
                    }
                    Text("设备未安装所选字体时自动使用系统等宽字体。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("滚动缓冲区允许 1,000–1,000,000 行，修改会立即应用到所有 Session。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("共享 Proxy") {
                    Button {
                        editingProxy = MobileProxyProfile()
                    } label: {
                        Label("添加 Proxy", systemImage: "plus.circle")
                    }
                    ForEach(proxyStore.proxies) { proxy in
                        HStack {
                            Button { editingProxy = proxy } label: {
                                Label(proxy.name, systemImage: "network")
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Text(proxy.type.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(role: .destructive) {
                                proxyIDsPendingDeletion = [proxy.id]
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onDelete { offsets in
                        proxyIDsPendingDeletion = Set(offsets.compactMap { index in
                            proxyStore.proxies.indices.contains(index)
                                ? proxyStore.proxies[index].id
                                : nil
                        })
                    }
                }
                Section("已信任的主机") {
                    Toggle("自动信任新主机", isOn: Binding(
                        get: { knownHostStore.autoTrustNewHosts },
                        set: { knownHostStore.setAutoTrustNewHosts($0) }
                    ))
                    Text("默认关闭。开启后仅自动信任首次出现的主机；主机密钥发生变化时仍会要求确认。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if knownHostStore.entries.isEmpty {
                        Text("暂无")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(knownHostStore.entries.keys.sorted(), id: \.self) { endpoint in
                        HStack {
                            Image(systemName: "checkmark.shield")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(endpoint)
                                if let identity = knownHostStore.identity(for: endpoint) {
                                    Text("\(identity.algorithm) · \(identity.fingerprint)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                knownHostStore.remove(endpoint: endpoint)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    if !knownHostStore.entries.isEmpty {
                        Button("清空已信任主机", role: .destructive) {
                            isConfirmingKnownHostsClear = true
                        }
                    }
                }
                Section("配置导入与导出") {
                    Button {
                        importMode = .configuration
                        isFileImporterPresented = true
                    } label: {
                        Label("导入配置", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        do {
                            exportDocument = ShellHarborConfigurationDocument(
                                data: try remoteStore.exportedConfigurationData(proxyStore: proxyStore)
                            )
                            isExportingConfiguration = true
                        } catch {
                            importError = error.localizedDescription
                        }
                    } label: {
                        Label("导出配置", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("导入时按 host、port、user 自动合并。密码、认证密钥和本机私钥不会导出。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !transferStatus.isEmpty {
                        Text(transferStatus)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("设置")
            .confirmationDialog(
                "删除 \(proxyIDsPendingDeletion.count) 个共享 Proxy？",
                isPresented: Binding(
                    get: { !proxyIDsPendingDeletion.isEmpty },
                    set: { if !$0 { proxyIDsPendingDeletion.removeAll() } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) { deletePendingProxies() }
                Button("取消", role: .cancel) { proxyIDsPendingDeletion.removeAll() }
            } message: {
                Text("引用这些 Proxy 的 Remote 会保留一份独立配置，连接不会失效。")
            }
            .confirmationDialog(
                "删除私钥 \(identityKeyPendingDeletion?.name ?? "")？",
                isPresented: Binding(
                    get: { identityKeyPendingDeletion != nil },
                    set: { if !$0 { identityKeyPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除私钥", role: .destructive) { deletePendingIdentityKey() }
                Button("取消", role: .cancel) { identityKeyPendingDeletion = nil }
            } message: {
                let count = identityKeyPendingDeletion.map(identityKeyReferenceCount) ?? 0
                Text(
                    count == 0
                        ? "密钥文件会从此设备永久删除。"
                        : "有 \(count) 个 Remote 正在使用此私钥；删除后会清除这些引用。当前已连接 Session 不会断开。"
                )
            }
            .confirmationDialog(
                "清空所有已信任主机？",
                isPresented: $isConfirmingKnownHostsClear,
                titleVisibility: .visible
            ) {
                Button("清空", role: .destructive) {
                    knownHostStore.removeAll()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("后续连接会重新校验主机密钥；当前已连接 Session 不会断开。")
            }
            .onAppear {
                if terminalScrollbackDraft.isEmpty {
                    terminalScrollbackDraft = String(terminalScrollbackLines)
                }
            }
            .sheet(item: $editingProxy) { proxy in
                MobileProxyEditorView(profile: proxy) {
                    proxyStore.save($0)
                    editingProxy = nil
                }
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: importMode?.contentTypes ?? [.data],
                allowsMultipleSelection: false
            ) { result in
                let requestedMode = importMode
                importMode = nil
                do {
                    guard let url = try result.get().first else { return }
                    switch requestedMode {
                    case .identityKey:
                        try keyStore.importKey(from: url)
                        transferStatus = "已导入私钥 \(url.lastPathComponent)"
                    case .configuration:
                        let hasAccess = url.startAccessingSecurityScopedResource()
                        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                        let counts = try remoteStore.importConfigurationData(
                            Data(contentsOf: url),
                            proxyStore: proxyStore
                        )
                        transferStatus = "导入完成：新增 \(counts.added)，更新 \(counts.updated)"
                    case nil:
                        return
                    }
                } catch {
                    importError = error.localizedDescription
                }
            }
            .fileExporter(
                isPresented: $isExportingConfiguration,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "ShellHarbor-Config"
            ) { result in
                switch result {
                case .success:
                    transferStatus = "配置已导出"
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
            .alert("无法导入私钥", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("好", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "未知错误")
            }
        }
    }

    private var parsedTerminalScrollbackDraft: Int? {
        let normalized = terminalScrollbackDraft.replacingOccurrences(of: ",", with: "")
        guard let lines = Int(normalized),
              MobileTerminalScrollbackSettings.allowedLines.contains(lines) else {
            return nil
        }
        return lines
    }

    private func applyTerminalScrollbackDraft() {
        guard let lines = parsedTerminalScrollbackDraft else { return }
        terminalScrollbackLines = lines
        terminalScrollbackDraft = String(lines)
    }

    private func deletePendingProxies() {
        let proxies = proxyStore.proxies.filter { proxyIDsPendingDeletion.contains($0.id) }
        for proxy in proxies { remoteStore.detachSavedProxy(proxy) }
        proxyStore.delete(ids: proxyIDsPendingDeletion)
        proxyIDsPendingDeletion.removeAll()
    }

    private func identityKeyReferenceCount(_ key: ImportedIdentityKey) -> Int {
        remoteStore.remotes.count { $0.identityKeyID == key.id }
    }

    private func deletePendingIdentityKey() {
        guard let key = identityKeyPendingDeletion else { return }
        do {
            try keyStore.delete(key)
            remoteStore.clearIdentityKeyReferences(key.id)
            identityKeyPendingDeletion = nil
        } catch {
            identityKeyPendingDeletion = nil
            importError = error.localizedDescription
        }
    }
}
