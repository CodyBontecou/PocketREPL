import SwiftUI
import Combine

@MainActor
final class AppContainer {
    let projectStore: ProjectStore
    let contextManager: ContextManager
    let modelManager: ModelBackendManager
    let memoryCoordinator: ModelMemoryCoordinator
    let runtime: JSRuntime
    let agentSession: AgentSession
    let workspaceInfo: WorkspaceInfo

    init(defaultWorkspaceName: String = "PocketREPL") {
        let store = ProjectStore.restore(defaultWorkspaceName: defaultWorkspaceName)
        let contextManager = ContextManager(projectStore: store)
        let modelManager = ModelBackendManager()
        let memoryCoordinator = ModelMemoryCoordinator(modelManager: modelManager)
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
        self.memoryCoordinator = memoryCoordinator
        self.runtime = runtime
        self.agentSession = session
        self.workspaceInfo = store.workspaceInfo
    }

    static let preview = AppContainer(defaultWorkspaceName: "PocketREPL Preview")
}

struct RootView: View {
    let container: AppContainer
    @ObservedObject private var memoryCoordinator: ModelMemoryCoordinator
    @State private var showingModelManagement = false
    @State private var showingUnloadAlert = false

    init(container: AppContainer) {
        self.container = container
        self._memoryCoordinator = ObservedObject(wrappedValue: container.memoryCoordinator)
    }

    var body: some View {
        NavigationSplitView {
            FileBrowserView(projectStore: container.projectStore)
                .navigationTitle(container.workspaceInfo.displayName)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingModelManagement = true
                        } label: {
                            ModelStatusView(modelManager: container.modelManager)
                        }
                    }
                }
        } detail: {
            AgentView(session: container.agentSession, workspaceInfo: container.workspaceInfo)
        }
        .sheet(isPresented: $showingModelManagement) {
            NavigationStack {
                ModelManagementView(modelManager: container.modelManager)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                showingModelManagement = false
                            }
                        }
                    }
            }
        }
        .onChange(of: memoryCoordinator.modelWasUnloadedAutomatically) { _, newValue in
            if newValue {
                showingUnloadAlert = true
            }
        }
        .alert("Model Unloaded", isPresented: $showingUnloadAlert) {
            Button("Reload Model") {
                memoryCoordinator.clearUnloadState()
                showingModelManagement = true
            }
            Button("OK", role: .cancel) {
                memoryCoordinator.clearUnloadState()
            }
        } message: {
            Text(memoryCoordinator.lastUnloadReason?.message ?? "Model was unloaded automatically.")
        }
        .task {
            await container.agentSession.bootstrapIfNeeded()
        }
    }
}

#Preview {
    RootView(container: .preview)
}
