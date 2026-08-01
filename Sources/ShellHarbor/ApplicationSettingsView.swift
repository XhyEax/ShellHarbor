import SwiftUI

struct ApplicationSettingsView: View {
    @EnvironmentObject private var state: AppState

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
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 520, height: 240)
    }
}
