import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ApplicationSettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var transferStatus = ""
    @State private var transferIsError = false
    @State private var proxyPendingDeletion: NetworkProxyProfile?

    var body: some View {
        Form {
            Section("命令行工具") {
                Toggle(
                    "链接到 Homebrew bin",
                    isOn: $state.shcliLinkEnabled
                )
                LabeledContent("命令", value: "shcli")
                LabeledContent(
                    "链接位置",
                    value: SHCLILinkManager.defaultLinkURL.path
                )
                Text(state.shcliLinkStatus)
                    .font(.caption)
                    .foregroundStyle(
                        state.shcliLinkStatusIsError
                            ? Color.red
                            : Color.secondary
                    )
                    .textSelection(.enabled)
            }
            Section("终端") {
                Picker("主题", selection: $state.terminalTheme) {
                    ForEach(TerminalTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                Picker("字体", selection: $state.terminalFont) {
                    ForEach(TerminalFontFamily.allCases) { family in
                        Text(family.rawValue).tag(family)
                    }
                }
                Stepper(
                    value: $state.terminalFontSize,
                    in: 8...32,
                    step: 1
                ) {
                    LabeledContent(
                        "字体大小",
                        value: "\(Int(state.terminalFontSize)) pt"
                    )
                }
                Text("字体与字号会立即应用到所有已打开的 Session；未安装的字体会回退为系统等宽字体。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("共享 Proxy") {
                if state.savedProxies.isEmpty {
                    Text("暂无")
                        .foregroundStyle(.secondary)
                }
                ForEach(state.savedProxies) { proxy in
                    HStack {
                        Label(proxy.name, systemImage: "network")
                        Spacer()
                        Text(proxy.type.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            proxyPendingDeletion = proxy
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Text("删除共享 Proxy 后，引用它的 Remote 会保留当前独立配置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("配置导入与导出") {
                HStack {
                    Button("导入配置…") { importConfiguration() }
                    Button("导出配置…") { exportConfiguration() }
                }
                Text("Remote 与共享 Proxy 使用同一 JSON 格式；导入时按 host、port、user 自动合并。密码、认证密钥和本机私钥路径不会导出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !transferStatus.isEmpty {
                    Text(transferStatus)
                        .font(.caption)
                        .foregroundStyle(transferIsError ? .red : .green)
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 560, height: 560)
        .confirmationDialog(
            "删除共享 Proxy“\(proxyPendingDeletion?.name ?? "")”？",
            isPresented: Binding(
                get: { proxyPendingDeletion != nil },
                set: { if !$0 { proxyPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let proxyPendingDeletion {
                    state.deleteSavedProxy(proxyPendingDeletion.id)
                }
                proxyPendingDeletion = nil
            }
            Button("取消", role: .cancel) { proxyPendingDeletion = nil }
        }
    }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ShellHarbor-Config.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.exportedConfigurationData().write(to: url, options: .atomic)
            transferStatus = "已导出到 \(url.lastPathComponent)"
            transferIsError = false
        } catch {
            transferStatus = error.localizedDescription
            transferIsError = true
        }
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try state.importConfigurationData(Data(contentsOf: url))
            transferStatus = "导入完成：新增 \(result.added)，更新 \(result.updated)"
            transferIsError = false
        } catch {
            transferStatus = error.localizedDescription
            transferIsError = true
        }
    }
}
