import SwiftUI

struct ContentView: View {
    let container: AppContainer

    var body: some View {
        RootView(container: container)
    }
}

#Preview {
    ContentView(container: .preview)
}
