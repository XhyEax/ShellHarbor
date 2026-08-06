import SwiftUI

@MainActor
@Observable
final class MobileAppCommandRouter {
    private var activeToken: UUID?
    private(set) var newSession: (() -> Void)?
    private(set) var closeSession: (() -> Void)?
    private(set) var reconnect: (() -> Void)?
    private(set) var disconnect: (() -> Void)?
    private(set) var interrupt: (() -> Void)?
    private(set) var clearTerminal: (() -> Void)?
    private(set) var findTerminal: (() -> Void)?
    private(set) var canReconnect = false
    private(set) var canDisconnect = false
    private(set) var canUseConnectedTerminal = false

    func register(
        token: UUID,
        newSession: @escaping () -> Void,
        closeSession: @escaping () -> Void,
        reconnect: @escaping () -> Void,
        disconnect: @escaping () -> Void,
        interrupt: @escaping () -> Void,
        clearTerminal: @escaping () -> Void,
        findTerminal: @escaping () -> Void,
        canReconnect: Bool,
        canDisconnect: Bool,
        canUseConnectedTerminal: Bool
    ) {
        activeToken = token
        self.newSession = newSession
        self.closeSession = closeSession
        self.reconnect = reconnect
        self.disconnect = disconnect
        self.interrupt = interrupt
        self.clearTerminal = clearTerminal
        self.findTerminal = findTerminal
        self.canReconnect = canReconnect
        self.canDisconnect = canDisconnect
        self.canUseConnectedTerminal = canUseConnectedTerminal
    }

    func unregister(token: UUID) {
        guard activeToken == token else { return }
        activeToken = nil
        newSession = nil
        closeSession = nil
        reconnect = nil
        disconnect = nil
        interrupt = nil
        clearTerminal = nil
        findTerminal = nil
        canReconnect = false
        canDisconnect = false
        canUseConnectedTerminal = false
    }
}

private struct MobileSessionCommands: Commands {
    let router: MobileAppCommandRouter

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建 Session") { router.newSession?() }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(router.newSession == nil)
        }
        CommandGroup(after: .newItem) {
            Button("新建 Session（新标签）") { router.newSession?() }
                .keyboardShortcut("t", modifiers: [.command])
                .disabled(router.newSession == nil)
        }
        CommandMenu("Session") {
            Button("新建 Session") { router.newSession?() }
                .disabled(router.newSession == nil)
            Button("重连 Session") { router.reconnect?() }
                .disabled(router.reconnect == nil || !router.canReconnect)
            Button("断开 Session") { router.disconnect?() }
                .disabled(router.disconnect == nil || !router.canDisconnect)
            Button("关闭当前 Session") { router.closeSession?() }
                .keyboardShortcut("w", modifiers: [.command])
                .disabled(router.closeSession == nil)
            Divider()
            Button("发送中断 (Ctrl-C)") { router.interrupt?() }
                .disabled(router.interrupt == nil || !router.canUseConnectedTerminal)
            Button("本地清屏") { router.clearTerminal?() }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(router.clearTerminal == nil || !router.canUseConnectedTerminal)
            Button("搜索终端") { router.findTerminal?() }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(router.findTerminal == nil)
        }
    }
}

@main
struct ShellHarborIOSApp: App {
    @AppStorage("mobileTerminalTheme") private var terminalTheme = MobileTerminalTheme.night.rawValue
    @State private var store = RemoteStore()
    @State private var keyStore = ImportedKeyStore()
    @State private var knownHostStore = KnownHostStore()
    @State private var proxyStore = MobileProxyStore()
    @State private var inspectionStore = MobileInspectionStore()
    @State private var commandRouter = MobileAppCommandRouter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(keyStore)
                .environment(knownHostStore)
                .environment(proxyStore)
                .environment(inspectionStore)
                .environment(commandRouter)
                .preferredColorScheme(
                    (MobileTerminalTheme(rawValue: terminalTheme) ?? .night).colorScheme
                )
        }
        .commands {
            MobileSessionCommands(router: commandRouter)
        }
    }
}
