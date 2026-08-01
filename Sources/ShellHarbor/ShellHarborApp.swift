import SwiftUI

@main
struct ShellHarborApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(state)
                .frame(minWidth: 1080, minHeight: 700)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建 Session") {
                    state.newSession()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(after: .newItem) {
                Button("新建 SSH Remote") {
                    state.addSession()
                }
            }
            CommandMenu("Session") {
                Button("新建 Session") { state.newSession() }
                Button("重连 Session") { state.reconnect() }
                    .disabled(state.selectedWorkspace?.profile.isConnectable != true)
                Button("断开 Session") { state.disconnect() }
                    .disabled(
                        state.selectedWorkspace == nil ||
                        state.terminal.state == .disconnected ||
                        state.terminal.state.isFailed
                    )
                Button("关闭当前 Session") {
                    state.closeCurrentSession()
                }
                .keyboardShortcut("w", modifiers: [.command])
                Divider()
                Button("发送中断 (Ctrl-C)") { state.terminal.sendInterrupt() }
                Button("本地清屏") { state.terminal.clear() }
                    .keyboardShortcut("k", modifiers: [.command])
                    .disabled(state.terminal.state != .connected)
                Button("搜索终端") { state.terminal.showFind() }
                    .keyboardShortcut("f", modifiers: [.command])
                    .disabled(state.selectedWorkspace == nil)
            }
        }
        Settings {
            ApplicationSettingsView()
                .environmentObject(state)
        }
    }
}
