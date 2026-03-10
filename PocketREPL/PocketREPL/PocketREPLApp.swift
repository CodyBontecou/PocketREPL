import SwiftUI

@main
struct PocketREPLApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
        }
    }
}
