import SwiftUI

struct TerminalView: View {
    @ObservedObject var workspace: SessionWorkspace

    var body: some View {
        TerminalPanel(
            workspace: workspace,
            controller: workspace.terminal
        )
    }
}

private struct TerminalPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var workspace: SessionWorkspace
    @ObservedObject var controller: TerminalController
    @State private var isRemoteFileDropTarget = false
    @State private var showingTerminalSettings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(
                    workspace.profile.isLocalConnection
                        ? "Local 终端"
                        : (
                            workspace.profile
                                .resolvedTerminalConnectionMethod ==
                                .jumpMosh
                                ? "跳板 Mosh 终端"
                                : (
                                    workspace.profile.isMoshConnection
                                        ? "Mosh 终端"
                                        : "SSH 终端"
                                )
                        ),
                    systemImage: "terminal"
                )
                    .font(.subheadline.weight(.semibold))
                if !workspace.profile.isLocalConnection {
                    Button {
                        state.showCommandHistory(in: workspace)
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.borderless)
                    .help("远程命令历史")
                    .disabled(controller.state != .connected)
                    .popover(
                        isPresented: $workspace.showingCommandHistory,
                        arrowEdge: .bottom
                    ) {
                        CommandHistoryView(workspace: workspace)
                            .environmentObject(state)
                    }
                }
                Circle()
                    .fill(controller.state.color)
                    .frame(width: 7, height: 7)
                Text(controller.terminalTitle.isEmpty
                    ? controller.state.label
                    : controller.terminalTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showingTerminalSettings.toggle()
                } label: {
                    Image(systemName: "paintpalette")
                }
                .buttonStyle(.borderless)
                .help("终端外观与缓冲区设置")
                .popover(
                    isPresented: $showingTerminalSettings,
                    arrowEdge: .bottom
                ) {
                    TerminalSettingsPopover(
                        theme: $state.terminalTheme,
                        scrollbackLines: $state.terminalScrollbackLines
                    )
                }
                Button {
                    controller.sendInterrupt()
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless)
                .help("发送 Ctrl-C")
                .disabled(controller.state != .connected)
                Button {
                    controller.clear()
                } label: {
                    Image(systemName: "eraser")
                }
                .buttonStyle(.borderless)
                .help("本地清屏并保留当前行")
                .disabled(controller.state != .connected)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ZStack {
                Color(nsColor: state.terminalTheme.backgroundColor)
                if controller.invocation != nil {
                    InteractiveTerminalRepresentable(
                        controller: controller,
                        connectionToken: controller.connectionToken,
                        invocation: controller.invocation,
                        theme: state.terminalTheme
                    )
                    .id(controller.connectionToken)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "terminal")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text(statusText)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }
            .dropDestination(
                for: FileDragPayload.self
            ) { payloads, _ in
                guard controller.state == .connected else { return false }
                let paths = payloads
                    .filter { $0.location == .remote }
                    .flatMap(\.items)
                    .map(\.path)
                let text = ShellPathInputFormatter.text(for: paths)
                guard !text.isEmpty else { return false }
                controller.insertText(text)
                return true
            } isTargeted: { isTargeted in
                isRemoteFileDropTarget = isTargeted
            }
            .overlay {
                if isRemoteFileDropTarget {
                    ZStack {
                        Color.accentColor.opacity(0.08)
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                Color.accentColor,
                                style: StrokeStyle(
                                    lineWidth: 3,
                                    dash: [8, 5]
                                )
                            )
                            .padding(5)
                        Label(
                            "输入远程完整路径",
                            systemImage: "terminal.fill"
                        )
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: Capsule())
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private var statusText: String {
        if case let .failed(message) = controller.state {
            return "连接失败\n\(message)"
        }
        return "交互式终端已就绪\n点击“重连”后可直接键入，支持方向键、Tab、vim 与 top"
    }
}

private struct TerminalSettingsPopover: View {
    @Binding var theme: TerminalTheme
    @Binding var scrollbackLines: Int
    @State private var customLines: String

    private let presets = [
        10_000,
        50_000,
        100_000,
        200_000,
        500_000,
        1_000_000
    ]

    init(
        theme: Binding<TerminalTheme>,
        scrollbackLines: Binding<Int>
    ) {
        _theme = theme
        _scrollbackLines = scrollbackLines
        _customLines = State(
            initialValue: String(scrollbackLines.wrappedValue)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("终端设置")
                .font(.headline)

            Picker("主题", selection: $theme) {
                ForEach(TerminalTheme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            }

            Divider()

            Text("滚动缓冲区")
                .font(.subheadline.weight(.semibold))

            Picker("行数预设", selection: $scrollbackLines) {
                ForEach(presets, id: \.self) { lines in
                    Text(lines.formatted()).tag(lines)
                }
                if !presets.contains(scrollbackLines) {
                    Text("\(scrollbackLines.formatted())（自定义）")
                        .tag(scrollbackLines)
                }
            }
            .onChange(of: scrollbackLines) { _, lines in
                customLines = String(lines)
            }

            HStack {
                TextField("自定义行数", text: $customLines)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyCustomLines)
                Button("应用", action: applyCustomLines)
                    .disabled(parsedCustomLines == nil)
            }

            Text("允许 1,000–1,000,000 行；默认 100,000 行。修改会立即应用到所有 Session。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 330)
    }

    private var parsedCustomLines: Int? {
        let normalizedText = customLines.replacingOccurrences(
            of: ",",
            with: ""
        )
        guard
            let value = Int(normalizedText),
            TerminalScrollbackSettings.allowedLines.contains(value)
        else {
            return nil
        }
        return value
    }

    private func applyCustomLines() {
        guard let parsedCustomLines else { return }
        scrollbackLines = parsedCustomLines
        customLines = String(parsedCustomLines)
    }
}
