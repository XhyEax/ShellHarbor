import SwiftUI

struct TerminalView: View {
    @ObservedObject var workspace: SessionWorkspace
    let isActive: Bool

    var body: some View {
        TerminalPanel(
            workspace: workspace,
            controller: workspace.terminal,
            isActive: isActive
        )
    }
}

private struct TerminalPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var workspace: SessionWorkspace
    @ObservedObject var controller: TerminalController
    let isActive: Bool
    @State private var isRemoteFileDropTarget = false
    @State private var showingTerminalSettings = false
    @State private var dismissedConnectionFailure: String?

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
                    .help("命令历史")
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
                    controller.showFind()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("搜索终端")
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
                        fontFamily: $state.terminalFont,
                        fontSize: $state.terminalFontSize,
                        scrollbackLines: $state.terminalScrollbackLines
                    )
                }
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
                if controller.invocation != nil ||
                    controller.hasRetainedTerminalView {
                    InteractiveTerminalRepresentable(
                        controller: controller,
                        connectionToken: controller.connectionToken,
                        invocation: controller.invocation,
                        theme: state.terminalTheme,
                        fontFamily: state.terminalFont,
                        fontSize: state.terminalFontSize,
                        isActive: isActive
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
                if case let .failed(message) = controller.state,
                   dismissedConnectionFailure != message {
                    connectionFailureOverlay(message: message)
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
        .onChange(of: controller.state) { _, connectionState in
            if case .failed = connectionState {
                return
            }
            dismissedConnectionFailure = nil
        }
    }

    private var statusText: String {
        if case let .failed(message) = controller.state {
            return "连接失败\n\(message)"
        }
        return "交互式终端已就绪\n点击“重连”后可直接键入，支持方向键、Tab、vim 与 top"
    }

    private func connectionFailureOverlay(message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                Button {
                    state.reconnect(workspace)
                } label: {
                    Label("重新连接", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    dismissedConnectionFailure = message
                } label: {
                    Label("关闭", systemImage: "xmark")
                }
            }
        }
        .padding()
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}

private struct TerminalSettingsPopover: View {
    @Binding var theme: TerminalTheme
    @Binding var fontFamily: TerminalFontFamily
    @Binding var fontSize: Double
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
        fontFamily: Binding<TerminalFontFamily>,
        fontSize: Binding<Double>,
        scrollbackLines: Binding<Int>
    ) {
        _theme = theme
        _fontFamily = fontFamily
        _fontSize = fontSize
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

            Picker("字体", selection: $fontFamily) {
                ForEach(TerminalFontFamily.allCases) { family in
                    Text(family.rawValue).tag(family)
                }
            }

            Stepper(value: $fontSize, in: 8...32, step: 1) {
                LabeledContent("字体大小", value: "\(Int(fontSize)) pt")
            }

            Text("未安装的字体会回退为系统等宽字体。")
                .font(.caption)
                .foregroundStyle(.secondary)

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
