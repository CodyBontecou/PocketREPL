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
    
    private let downloadManager = ModelDownloadManager()

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
    
    /// Automatically loads the last used model if one was saved.
    func autoLoadLastModelIfNeeded() async {
        // Skip if a model is already loaded
        guard modelManager.state == .unloaded else { return }
        
        // Check if we have a saved model ID
        guard let lastModelId = ModelPersistence.lastModelId() else { return }
        
        // Check if this model is still installed
        let installedModels = await downloadManager.installedModels()
        guard let model = installedModels.first(where: { $0.id == lastModelId }),
              let entry = model.registryEntry else {
            // Model was removed or is unknown, clear the persistence
            ModelPersistence.clearLastModelId()
            return
        }
        
        // Load the model
        do {
            let config = ModelConfiguration(
                modelPath: model.path.path,
                contextSize: entry.recommendedContextSize,
                gpuLayers: 99,
                threadCount: 4
            )
            
            let backend = LlamaBackend()
            await modelManager.setBackend(backend)
            try await modelManager.load(configuration: config, modelId: model.id, persistSelection: false)
        } catch {
            // Failed to auto-load, clear persistence so we don't keep trying
            print("[AppContainer] Failed to auto-load model \(lastModelId): \(error)")
            ModelPersistence.clearLastModelId()
        }
    }

    static let preview = AppContainer(defaultWorkspaceName: "PocketREPL Preview")
}

struct RootView: View {
    let container: AppContainer
    @ObservedObject private var memoryCoordinator: ModelMemoryCoordinator
    @State private var showingModelManagement = false
    @State private var showingUnloadAlert = false
    @State private var selectedTab: Tab = .chat
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    enum Tab {
        case files
        case chat
    }

    init(container: AppContainer) {
        self.container = container
        self._memoryCoordinator = ObservedObject(wrappedValue: container.memoryCoordinator)
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                // iPhone: Use TabView for easy switching
                TabView(selection: $selectedTab) {
                    NavigationStack {
                        AgentView(session: container.agentSession, workspaceInfo: container.workspaceInfo)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button {
                                        showingModelManagement = true
                                    } label: {
                                        ModelStatusView(modelManager: container.modelManager)
                                    }
                                }
                            }
                    }
                    .tabItem {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    }
                    .tag(Tab.chat)

                    NavigationStack {
                        FileBrowserView(projectStore: container.projectStore)
                            .navigationTitle(container.workspaceInfo.displayName)
                    }
                    .tabItem {
                        Label("Files", systemImage: "folder")
                    }
                    .tag(Tab.files)
                }
            } else {
                // iPad: Use NavigationSplitView for side-by-side
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
            }
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
            // Auto-load the last used model if available
            await container.autoLoadLastModelIfNeeded()
            await container.agentSession.bootstrapIfNeeded()
        }
    }
}

#Preview {
    RootView(container: .preview)
}
