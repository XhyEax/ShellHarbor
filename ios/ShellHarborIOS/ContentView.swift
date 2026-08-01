import SwiftUI
import UniformTypeIdentifiers

private enum IOSRootTab: Hashable {
    case remotes
    case sessions
    case settings
}

struct ContentView: View {
    @Environment(RemoteStore.self) private var remoteStore
    @Environment(ImportedKeyStore.self) private var keyStore
    @Environment(KnownHostStore.self) private var knownHostStore
    @Environment(MobileProxyStore.self) private var proxyStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = IOSRootTab.remotes
    @State private var requestedSessionID: UUID?

    var body: some View {
        TabView(selection: $selectedTab) {
            RemoteListView { sessionID in
                requestedSessionID = sessionID
                selectedTab = .sessions
            }
                .tabItem { Label("Remote", systemImage: "server.rack") }
                .tag(IOSRootTab.remotes)
            SessionListView(requestedSessionID: $requestedSessionID)
                .tabItem { Label("Session", systemImage: "terminal") }
                .tag(IOSRootTab.sessions)
            IOSSettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(IOSRootTab.settings)
        }
        .tint(.blue)
        .task {
            remoteStore.restoreSessions(keyStore: keyStore, knownHostStore: knownHostStore)
            await remoteStore.prewarmTailscale(proxyStore: proxyStore)
            #if DEBUG
            await MobileConnectionSelfTest.runIfRequested()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { remoteStore.persistSessionRestoration() }
        }
    }
}

private struct RemoteListView: View {
    @Environment(RemoteStore.self) private var store
    @Environment(ImportedKeyStore.self) private var keyStore
    @Environment(KnownHostStore.self) private var knownHostStore
    @Environment(MobileProxyStore.self) private var proxyStore
    @State private var editingRemote: MobileRemoteProfile?
    @State private var selection: Set<UUID> = []
    @State private var editMode: EditMode = .inactive
    @State private var isNamingGroup = false
    @State private var groupName = ""
    let onSessionOpened: (UUID) -> Void

    private var groupNames: [String] {
        Array(Set(store.remotes.map(\.remoteGroup).filter { !$0.isEmpty })).sorted()
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
                        ForEach(groupedRemotes, id: \.name) { group in
                            Section(group.name.isEmpty ? "未分组" : group.name) {
                            ForEach(group.remotes) { remote in
                            Button {
                                open(remote)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "server.rack")
                                        .foregroundStyle(.blue)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(remote.name).font(.headline)
                                        Text(remote.endpoint)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(remote.connectionMethod.title)
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Menu("连接方式") {
                                    ForEach(MobileConnectionMethod.allCases) { method in
                                        Button(method.title) { open(remote, method: method) }
                                    }
                                }
                                Menu("设为默认连接方式") {
                                    ForEach(MobileConnectionMethod.allCases) { method in
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
                                    Button("新建 tmux Session") { openMultiplexer(remote, kind: "tmux") }
                                    Button("新建 zellij Session") { openMultiplexer(remote, kind: "zellij") }
                                }
                                Button("编辑") { editingRemote = remote }
                            }
                            .swipeActions(edge: .leading) {
                                Button("编辑") { editingRemote = remote }
                                    .tint(.blue)
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
                            Button("删除", role: .destructive) {
                                store.delete(ids: selection); selection.removeAll()
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
                RemoteEditorView(profile: remote) {
                    store.save($0)
                    editingRemote = nil
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
        }
    }

    private var groupedRemotes: [(name: String, remotes: [MobileRemoteProfile])] {
        Dictionary(grouping: store.remotes, by: \.remoteGroup)
            .map { (name: $0.key, remotes: $0.value) }
            .sorted {
                if $0.name.isEmpty { return false }
                if $1.name.isEmpty { return true }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
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

    private func openMultiplexer(_ remote: MobileRemoteProfile, kind: String) {
        let suffix = "\(kind)-\(String(UUID().uuidString.prefix(6)).lowercased())"
        let quotedName = "shellharbor-\(suffix)"
        let command = kind == "tmux"
            ? "tmux new-session -s \(quotedName)"
            : "zellij --session \(quotedName)"
        open(remote, startupCommand: command, nameSuffix: suffix)
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
                    TextField("分组（可选）", text: $profile.remoteGroup)
                    TextField("主机", text: $profile.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("用户名", text: $profile.username)
                        .textInputAutocapitalization(.never)
                    TextField("端口", value: $profile.port, format: .number)
                        .keyboardType(.numberPad)
                }
                Section("连接") {
                    Picker("默认方式", selection: $profile.connectionMethod) {
                        ForEach(MobileConnectionMethod.allCases) {
                            Text($0.title).tag($0)
                        }
                    }
                    if profile.connectionMethod != .ssh {
                        TextField("mosh-server 命令", text: $profile.moshServerCommand)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
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
                    Picker("认证", selection: $profile.authentication) {
                        ForEach(MobileAuthentication.allCases) {
                            Text($0.title).tag($0)
                        }
                    }
                    if profile.authentication == .privateKey {
                        Picker("私钥", selection: $profile.identityKeyID) {
                            Text("未选择").tag(UUID?.none)
                            ForEach(keyStore.keys) { key in
                                Text(key.name).tag(Optional(key.id))
                            }
                        }
                    } else {
                        SecureField("密码", text: $cleartextPassword)
                            .textContentType(.password)
                    }
                    if profile.savedProxyID == nil && profile.proxyType == .tailscale {
                        TextField("共享名称", text: $profile.proxyName)
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
                            onSave(saved)
                        } catch {
                            saveError = error.localizedDescription
                        }
                    }
                    .disabled(
                        profile.name.isEmpty
                            || profile.username.isEmpty
                            || (profile.authentication == .password && cleartextPassword.isEmpty)
                    )
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
                                    saved.name = saved.tailscaleLoginServer
                                        .replacingOccurrences(of: "https://", with: "")
                                        .replacingOccurrences(of: "http://", with: "")
                                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
                    .disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
}

private struct SessionListView: View {
    @Environment(RemoteStore.self) private var store
    @Environment(ImportedKeyStore.self) private var keyStore
    @Environment(KnownHostStore.self) private var knownHostStore
    @Environment(MobileProxyStore.self) private var proxyStore
    @Binding var requestedSessionID: UUID?
    @State private var renamingSession: MobileSession?
    @State private var sessionSuffix = ""
    @State private var navigationPath: [UUID] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                ForEach(store.sessions) { session in
                    NavigationLink(value: session.id) {
                        HStack {
                            Label(session.displayName, systemImage: "terminal")
                            Spacer()
                            Text(session.controller.state.title)
                                .font(.caption)
                                .foregroundStyle(session.controller.state == .connected ? .green : .secondary)
                        }
                    }
                    .contextMenu {
                        Button("改名", systemImage: "pencil") {
                            renamingSession = session
                            sessionSuffix = session.nameSuffix ?? ""
                        }
                    }
                }
                .onDelete(perform: store.closeSessions)
            }
            .overlay {
                if store.sessions.isEmpty {
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
                    MobileTerminalSessionView(session: session)
                } else {
                    ContentUnavailableView("Session 已关闭", systemImage: "terminal")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(store.remotes) { remote in
                            Button(remote.name) { open(remote) }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(store.remotes.isEmpty)
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
            .onAppear { openRequestedSessionIfNeeded() }
            .onChange(of: requestedSessionID) { _, _ in openRequestedSessionIfNeeded() }
        }
    }

    private func openRequestedSessionIfNeeded() {
        guard let sessionID = requestedSessionID,
              store.sessions.contains(where: { $0.id == sessionID }) else { return }
        navigationPath = [sessionID]
        requestedSessionID = nil
    }

    private func open(_ source: MobileRemoteProfile) {
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
            autoTrustNewHosts: knownHostStore.autoTrustNewHosts
        )
        navigationPath.append(session.id)
    }
}

private struct MobileTerminalSessionView: View {
    @Environment(RemoteStore.self) private var store
    let session: MobileSession

    var body: some View {
        VStack(spacing: 0) {
            Picker("Session 视图", selection: Binding(
                get: { session.selectedView },
                set: { session.selectedView = $0 }
            )) {
                ForEach(MobileSession.ViewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            ZStack(alignment: .top) {
                if session.selectedView == .terminal {
                    MobileTerminalView(controller: session.controller)
                } else if session.selectedView == .files {
                    MobileRemoteFilesView(session: session)
                } else {
                    MobileInspectionView(session: session)
                }
                connectionOverlay
            }
        }
        .background(session.selectedView == .terminal ? Color.black : Color(uiColor: .systemBackground))
        .navigationTitle(session.controller.title.isEmpty ? session.displayName : session.controller.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { session.controller.disconnect() } label: {
                    Label("断开连接", systemImage: "xmark.circle")
                }
                .disabled(session.controller.state == .disconnected || session.controller.state == .idle)
            }
        }
        .onDisappear { store.persistSessionRestoration() }
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

    @ViewBuilder
    private var connectionOverlay: some View {
        if case .failed(let message) = session.controller.state {
            VStack(spacing: 10) {
                Text(message).font(.callout).multilineTextAlignment(.center)
                Button("重新连接") { session.controller.reconnect() }
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

    var body: some View {
        NavigationStack {
            Form {
                Section("平台") {
                    LabeledContent("最低版本", value: "iOS 17")
                    LabeledContent("界面", value: "SwiftUI")
                }
                Section("SSH 私钥") {
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
                                do { try keyStore.delete(key) }
                                catch { importError = error.localizedDescription }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Section("共享 Proxy") {
                    Button {
                        editingProxy = MobileProxyProfile()
                    } label: {
                        Label("添加 Proxy", systemImage: "plus.circle")
                    }
                    ForEach(proxyStore.proxies) { proxy in
                        Button { editingProxy = proxy } label: {
                            HStack {
                                Label(proxy.name, systemImage: "network")
                                Spacer()
                                Text(proxy.type.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: proxyStore.delete)
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
                            Label(endpoint, systemImage: "checkmark.shield")
                            Spacer()
                            Button(role: .destructive) {
                                knownHostStore.remove(endpoint: endpoint)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
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
}
