import SwiftUI

@main
struct PocketREPLApp: App {
    @State private var container = AppContainer()
    @State private var appearanceManager = AppearanceManager.shared

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
                .preferredColorScheme(appearanceManager.colorScheme)
                .task {
                    // Restore any existing purchase entitlements on launch
                    await PaywallManager.shared.checkExistingEntitlements()
                }
        }
    }
}
