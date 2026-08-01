import SwiftUI

@main
struct ShellHarborIOSApp: App {
    @State private var store = RemoteStore()
    @State private var keyStore = ImportedKeyStore()
    @State private var knownHostStore = KnownHostStore()
    @State private var proxyStore = MobileProxyStore()
    @State private var inspectionStore = MobileInspectionStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(keyStore)
                .environment(knownHostStore)
                .environment(proxyStore)
                .environment(inspectionStore)
                .preferredColorScheme(.dark)
        }
    }
}
