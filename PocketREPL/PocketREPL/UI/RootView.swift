import SwiftUI

@MainActor
final class AppContainer {
    let projectStore: ProjectStore
    let contextManager: ContextManager
    let modelManager: ModelBackendManager
    let runtime: JSRuntime
    let agentSession: AgentSession
    let workspaceInfo: WorkspaceInfo

    init(defaultWorkspaceName: String = "PocketREPL") {
        let store = ProjectStore.restore(defaultWorkspaceName: defaultWorkspaceName)
        let contextManager = ContextManager(projectStore: store)
        let modelManager = ModelBackendManager()
        let runtime = JSRuntime(projectStore: store)
        let session = AgentSession(
            projectStore: store,
            runtime: runtime,
            contextManager: contextManager,
            modelManager: modelManager
        )

        self.projectStore = store
        self.contextManager = contextManager
        self.modelManager = modelManager
        self.runtime = runtime
        self.agentSession = session
        self.workspaceInfo = store.workspaceInfo
    }

    static let preview = AppContainer(defaultWorkspaceName: "PocketREPL Preview")
}

struct RootView: View {
    let container: AppContainer

    var body: some View {
        NavigationSplitView {
            FileBrowserView(projectStore: container.projectStore)
                .navigationTitle(container.workspaceInfo.displayName)
        } detail: {
            AgentView(session: container.agentSession, workspaceInfo: container.workspaceInfo)
        }
        .task {
            await container.agentSession.bootstrapIfNeeded()
        }
    }
}

#Preview {
    RootView(container: .preview)
}
