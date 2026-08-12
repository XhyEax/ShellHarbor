import SwiftUI

struct PortForwardView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var workspace: SessionWorkspace
    @ObservedObject private var controller: PortForwardController

    init(workspace: SessionWorkspace) {
        self.workspace = workspace
        controller = workspace.portForwards
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SSH 端口转发").font(.headline)
                    Text("转发生命周期属于当前 Session；关闭 Session 时自动停止。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !LocalNetworkAddresses.ipv4.isEmpty {
                    Text("本机 IP：\(LocalNetworkAddresses.ipv4.joined(separator: "  "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button {
                    workspace.portForwardRules.append(PortForwardRule())
                } label: {
                    Label("添加转发", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)

            Divider()

            if workspace.portForwardRules.isEmpty {
                ContentUnavailableView {
                    Label(
                        "没有端口转发",
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                } description: {
                    Text("支持本地、远程和动态 SOCKS5 转发。")
                } actions: {
                    Button("添加转发") {
                        workspace.portForwardRules.append(PortForwardRule())
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach($workspace.portForwardRules) { $rule in
                            ruleEditor($rule)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: workspace.portForwardRules) { _, _ in
            state.rememberPortForwardRules()
        }
    }

    private func ruleEditor(_ rule: Binding<PortForwardRule>) -> some View {
        let value = rule.wrappedValue
        let status = controller.statuses[value.id] ?? .stopped
        let isActive = status == .starting || status == .running
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("类型", selection: rule.direction) {
                    ForEach(PortForwardDirection.allCases) { direction in
                        Text(direction.title).tag(direction)
                    }
                }
                .frame(width: 150)

                TextField("监听地址", text: rule.bindHost)
                    .textFieldStyle(.roundedBorder)
                TextField(
                    "监听端口",
                    value: rule.listenPort,
                    format: .number.grouping(.never)
                )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)

                if value.direction != .dynamic {
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField("目标地址", text: rule.destinationHost)
                        .textFieldStyle(.roundedBorder)
                    TextField(
                        "目标端口",
                        value: rule.destinationPort,
                        format: .number.grouping(.never)
                    )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }
            .disabled(isActive)

            HStack {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 8, height: 8)
                Text(status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case let .failed(message) = status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer()
                if isActive {
                    Button("停止", role: .destructive) {
                        controller.stop(value.id)
                    }
                } else {
                    Button("启动") {
                        state.startPortForward(value, in: workspace)
                    }
                    .disabled(!value.isValid)
                }
                Button(role: .destructive) {
                    controller.stop(value.id)
                    workspace.portForwardRules.removeAll { $0.id == value.id }
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .padding(14)
        .background(
            .background.opacity(0.75),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.45))
        }
    }

    private func statusColor(_ status: PortForwardController.Status) -> Color {
        switch status {
        case .stopped: .secondary
        case .starting: .orange
        case .running: .green
        case .failed: .red
        }
    }
}
