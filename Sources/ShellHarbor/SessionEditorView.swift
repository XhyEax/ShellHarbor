import AppKit
import SwiftUI

private enum SessionEditorSection: String, CaseIterable, Identifiable {
    case basic
    case connection
    case inspection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basic: "基本信息"
        case .connection: "连接选项"
        case .inspection: "巡检设置"
        }
    }

    var icon: String {
        switch self {
        case .basic: "server.rack"
        case .connection: "link"
        case .inspection: "waveform.path.ecg"
        }
    }
}

private extension View {
    func editorFormStyle() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
    }
}

struct SessionEditorView: View {
    @State private var draft: SessionProfile
    @State private var selectedSection: SessionEditorSection = .basic
    @State private var showingNewGroup = false
    let availableJumpRemotes: [SessionProfile]
    let onSave: (SessionProfile) -> Void
    let onCancel: () -> Void

    init(
        profile: SessionProfile,
        availableJumpRemotes: [SessionProfile] = [],
        onSave: @escaping (SessionProfile) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: profile)
        self.availableJumpRemotes = availableJumpRemotes.filter {
            $0.id != profile.id && !$0.isLocalConnection
        }
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: draft.resolvedRemoteIcon.symbol)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SSH Remote")
                        .font(.title3.weight(.semibold))
                    Text("保存用于创建一个或多个 Session 的连接配置")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            HStack(spacing: 0) {
                VStack(spacing: 6) {
                    ForEach(SessionEditorSection.allCases) { section in
                        editorSectionButton(section)
                    }
                    Spacer()
                }
                .padding(12)
                .frame(width: 158)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                editorContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isConnectable || draft.name.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 720, height: 620)
        .sheet(isPresented: $showingNewGroup) {
            NewRemoteGroupSheet(
                existingGroupNames: editorGroupNames,
                onCreate: { groupName in
                    draft.remoteGroup = groupName
                    showingNewGroup = false
                },
                onCancel: {
                    showingNewGroup = false
                }
            )
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        switch selectedSection {
        case .basic:
            Form {
                Section("基本信息") {
                    LabeledContent("设备类型") {
                        HStack(spacing: 8) {
                            ForEach(RemoteIcon.allCases) { icon in
                                deviceTypeButton(icon)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    Picker(
                        "终端连接",
                        selection: Binding(
                            get: {
                                draft.resolvedTerminalConnectionMethod
                            },
                            set: {
                                draft.terminalConnectionMethod =
                                    $0 == .ssh ? nil : $0
                                draft.moshJumpMode = nil
                            }
                        )
                    ) {
                        ForEach(
                            TerminalConnectionMethod.allCases.filter {
                                $0 != .jumpMosh ||
                                    draft.jumpRemoteID != nil
                            }
                        ) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Remote 名称", text: $draft.name)
                    LabeledContent("分组") {
                        HStack {
                            TextField(
                                "新建分组名称",
                                text: Binding(
                                    get: { draft.remoteGroup ?? "" },
                                    set: {
                                        draft.remoteGroup = $0.isEmpty
                                            ? nil
                                            : $0
                                    }
                                ),
                                prompt: Text(RemoteGroupName.ungrouped)
                            )
                            Menu {
                                Button(RemoteGroupName.ungrouped) {
                                    draft.remoteGroup = nil
                                }
                                if !editorGroupNames.isEmpty {
                                    Divider()
                                    ForEach(
                                        editorGroupNames,
                                        id: \.self
                                    ) { groupName in
                                        Button(groupName) {
                                            draft.remoteGroup = groupName
                                        }
                                    }
                                }
                                Divider()
                                Button("新建分组…") {
                                    showingNewGroup = true
                                }
                            } label: {
                                Image(systemName: "folder.badge.plus")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("选择或新建分组")
                        }
                    }
                    TextField(
                        "主机",
                        text: $draft.host,
                        prompt: Text("127.0.0.1")
                    )
                    TextField("用户名", text: $draft.username)
                    TextField("端口", value: $draft.port, format: .number)
                    TextField(
                        "远程起始目录",
                        text: $draft.remoteStartPath,
                        prompt: Text("不修改")
                    )

                    if draft.isMoshConnection {
                        if
                            draft.resolvedMoshJumpMode == .moshOnJump,
                            draft.jumpRemoteID != nil
                        {
                            TextField(
                                "跳板 Mosh 路径",
                                text: Binding(
                                    get: {
                                        draft.resolvedJumpMoshCommand
                                    },
                                    set: {
                                        draft.jumpMoshCommand = $0
                                    }
                                ),
                                prompt: Text(
                                    "例如 /var/jb/usr/bin/mosh"
                                )
                            )
                            TextField(
                                "目标 --server 参数",
                                text: Binding(
                                    get: {
                                        draft.resolvedMoshServerCommand
                                    },
                                    set: {
                                        draft.moshServerCommand = $0
                                    }
                                ),
                                prompt: Text("留空使用 mosh-server")
                            )
                        } else {
                            HStack {
                                TextField(
                                    "本地 Mosh 路径",
                                    text: Binding(
                                        get: {
                                            draft.resolvedMoshCommand
                                        },
                                        set: {
                                            draft.moshCommand = $0
                                        }
                                    )
                                )
                                Button("选择…") {
                                    chooseMoshCommand()
                                }
                            }
                            TextField(
                                "目标 --server 参数",
                                text: Binding(
                                    get: {
                                        draft.resolvedMoshServerCommand
                                    },
                                    set: {
                                        draft.moshServerCommand = $0
                                    }
                                ),
                                prompt: Text("留空使用 mosh-server")
                            )
                        }
                        Text(
                            draft.resolvedMoshJumpMode == .moshOnJump &&
                                draft.jumpRemoteID != nil
                                ? "ShellHarbor 先用 SSH 登录跳板，再在跳板机执行指定的 mosh，例如 /var/jb/usr/bin/mosh；目标机由 --server 参数指定 mosh-server。"
                                : "本地路径例如 /opt/homebrew/bin/mosh；--server 参数可填写目标机 mosh-server 的完整路径或命令，留空使用默认值。文件、历史和巡检仍使用 SSH。"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("身份验证") {
                    Picker("方式", selection: $draft.authentication) {
                        ForEach(AuthenticationMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }

                    switch draft.authentication {
                    case .password:
                        SecureField("密码", text: $draft.password)
                        HStack(alignment: .top) {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(.green)
                            Text("密码使用本地 RSA-2048 OAEP 公钥体系加密；私钥仅保存在 ShellHarbor 本地配置目录，不使用 macOS Keychain。连接时通过 SSHPASS 环境变量传递。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    case .privateKey:
                        HStack {
                            TextField("私钥路径", text: $draft.privateKeyPath)
                            Button("选择…") { choosePrivateKey() }
                        }
                    case .agent:
                        Text("将使用系统 ssh 和当前 SSH Agent/钥匙串配置。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .editorFormStyle()

        case .connection:
            Form {
                Section("连接选项") {
                    Picker("主机密钥", selection: $draft.hostKeyPolicy) {
                        ForEach(HostKeyPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    Stepper(
                        "保活间隔：\(draft.keepAliveSeconds) 秒",
                        value: $draft.keepAliveSeconds,
                        in: 0...300,
                        step: 5
                    )
                    if draft.hostKeyPolicy == .ask {
                        Label(
                            "优先使用当前 macOS 用户的 ~/.ssh/config；未指定 StrictHostKeyChecking 时自动接受首次出现的主机密钥。配置为 no 时不修改 known_hosts。",
                            systemImage: "doc.text"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else if draft.hostKeyPolicy == .acceptNew {
                        Label(
                            "~/.ssh/config 未指定时，仅自动接受第一次出现的主机密钥；已变化的密钥仍会被拒绝。",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("SSH 跳板") {
                    Picker(
                        "通过 Remote 连接",
                        selection: $draft.jumpRemoteID
                    ) {
                        Text("无（直接连接）")
                            .tag(UUID?.none)
                        ForEach(availableJumpRemotes) { remote in
                            Text(
                                "\(remote.name) · \(remote.subtitle)"
                            )
                            .tag(Optional(remote.id))
                        }
                    }

                    if let jumpRemote {
                        if draft.isMoshConnection {
                            Label(
                                draft.resolvedMoshJumpMode == .directTarget
                                    ? "检测到“跳板 + Mosh”。SSH 跳板不会转发 Mosh 后续使用的 UDP。"
                                    : "跳板 Mosh 会把 Mosh 客户端运行在跳板机上，UDP 链路为跳板机到目标机。",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)

                            if draft.resolvedMoshJumpMode == .directTarget {
                                Label(
                                    "当前选择“目标机 Mosh”：\(jumpRemote.name) 只负责 SSH 启动；本机必须能直接访问目标机 UDP 端口。可在基本信息中改为“跳板 Mosh”。",
                                    systemImage: "arrow.triangle.branch"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            } else {
                                Label(
                                    "当前选择“跳板 Mosh”：本机先通过 SSH 连接 \(jumpRemote.name)，再由跳板机上的 Mosh 通过 UDP 连接目标机。",
                                    systemImage: "terminal"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                Text(
                                    "目标机认证使用跳板机上的 SSH 配置、私钥或交互式密码；不会把 ShellHarbor 本地保存的目标密码或私钥复制到跳板机。"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        } else {
                            Label(
                                "终端、文件传输、命令历史和巡检都会先连接 \(jumpRemote.name)，再访问当前 Remote。",
                                systemImage: "point.3.connected.trianglepath.dotted"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } else if availableJumpRemotes.isEmpty {
                        Text("请先创建另一个 Remote，才能将其设为 SSH 跳板。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("网络 Proxy") {
                    Picker(
                        "类型",
                        selection: Binding(
                            get: { draft.resolvedProxyType },
                            set: { type in
                                draft.proxyType =
                                    type == .none ? nil : type
                                if
                                    type != .none,
                                    !(1...65535).contains(
                                        draft.proxyPort ?? 0
                                    )
                                {
                                    draft.proxyPort = type.defaultPort
                                }
                            }
                        )
                    ) {
                        ForEach(SSHProxyType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }

                    if draft.isProxyEnabled {
                        TextField(
                            "Proxy 主机",
                            text: Binding(
                                get: { draft.proxyHost ?? "" },
                                set: { draft.proxyHost = $0 }
                            ),
                            prompt: Text("127.0.0.1")
                        )
                        TextField(
                            "Proxy 端口",
                            value: Binding(
                                get: { draft.resolvedProxyPort },
                                set: { draft.proxyPort = $0 }
                            ),
                            format: .number
                        )

                        Label(
                            draft.jumpRemoteID == nil
                                ? (
                                    draft.isMoshConnection
                                        ? "Proxy 只负责 Mosh 的 SSH 启动和其他 SSH 功能；Mosh UDP 不经过此 TCP Proxy。"
                                        : "终端、文件传输、历史和巡检都会通过此 Proxy。"
                                )
                                : "当前 Remote 使用 SSH 跳板；连接跳板时将采用跳板 Remote 自身的 Proxy 设置。",
                            systemImage: "network"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Text("当前支持无需身份认证的 SOCKS5 和 HTTP CONNECT Proxy。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .editorFormStyle()

        case .inspection:
            Form {
                Section("自动巡检") {
                    Toggle(
                        "启用自动巡检",
                        isOn: Binding(
                            get: { draft.resolvedInspectionEnabled },
                            set: { draft.inspectionEnabled = $0 }
                        )
                    )
                    Stepper(
                        "巡检间隔：\(draft.resolvedInspectionIntervalMinutes) 分钟",
                        value: Binding(
                            get: {
                                draft.resolvedInspectionIntervalMinutes
                            },
                            set: {
                                draft.inspectionIntervalMinutes = $0
                            }
                        ),
                        in: 1...1_440,
                        step: 1
                    )
                    .disabled(!draft.resolvedInspectionEnabled)
                }

                Section("采集内容") {
                    inspectionCapability(
                        "联通情况",
                        icon: "network"
                    )
                    inspectionCapability(
                        "CPU 占用百分比",
                        icon: "cpu"
                    )
                    inspectionCapability(
                        "内存占用百分比与空间",
                        icon: "memorychip"
                    )
                    inspectionCapability(
                        "磁盘总量、可用空间与占用百分比",
                        icon: "internaldrive"
                    )
                }

                Section {
                    Label(
                        "保存后会立即执行一次巡检，之后按设置的间隔自动运行。巡检日志按 Remote 独立保存。",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .editorFormStyle()
        }
    }

    private func editorSectionButton(
        _ section: SessionEditorSection
    ) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 20)
                Text(section.title)
                    .font(.subheadline.weight(
                        selectedSection == section ? .semibold : .regular
                    ))
                Spacer()
            }
            .foregroundStyle(
                selectedSection == section
                    ? Color.accentColor
                    : Color.primary
            )
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(
                selectedSection == section
                    ? Color.accentColor.opacity(0.14)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func inspectionCapability(
        _ title: String,
        icon: String
    ) -> some View {
        Label(title, systemImage: icon)
            .foregroundStyle(.secondary)
    }

    private var editorGroupNames: [String] {
        let candidates = availableJumpRemotes.compactMap {
            RemoteGroupName.normalized($0.remoteGroup)
        } + [RemoteGroupName.normalized(draft.remoteGroup)].compactMap { $0 }
        return candidates.reduce(into: [String]()) { result, name in
            if !result.contains(where: {
                $0.caseInsensitiveCompare(name) == .orderedSame
            }) {
                result.append(name)
            }
        }
    }

    private var validationMessage: String {
        if !draft.isProxyConfigurationValid {
            return "请填写有效的 Proxy 主机和端口。"
        }
        if draft.authentication == .password && SSHCommandBuilder.sshpassPath() == nil {
            return "未检测到 sshpass，密码连接暂不可用。"
        }
        return draft.isConnectable
            ? "配置有效；主机留空时使用 127.0.0.1"
            : "请填写用户名和有效端口。主机留空时使用 127.0.0.1。"
    }

    private var jumpRemote: SessionProfile? {
        guard let id = draft.jumpRemoteID else { return nil }
        return availableJumpRemotes.first(where: { $0.id == id })
    }

    private func deviceTypeButton(_ icon: RemoteIcon) -> some View {
        let isSelected = draft.resolvedRemoteIcon == icon
        return Button {
            draft.remoteIcon = icon
        } label: {
            VStack(spacing: 7) {
                Image(systemName: icon.symbol)
                    .font(.system(size: 27, weight: .medium))
                    .frame(height: 30)
                Text(icon.title)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(
                isSelected ? Color.accentColor : Color.secondary
            )
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.14)
                    : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        isSelected
                            ? Color.accentColor
                            : Color.secondary.opacity(0.22),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("设备类型：\(icon.title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func choosePrivateKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let path = panel.url?.path {
            draft.privateKeyPath = path
        }
    }

    private func chooseMoshCommand() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let path = panel.url?.path {
            draft.moshCommand = path
        }
    }
}
