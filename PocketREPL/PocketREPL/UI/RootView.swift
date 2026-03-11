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
        guard modelManager.state == .unloaded else { return }
        
        guard let lastModelId = ModelPersistence.lastModelId() else { return }
        
        let installedModels = await downloadManager.installedModels()
        guard let model = installedModels.first(where: { $0.id == lastModelId }),
              let entry = model.registryEntry else {
            ModelPersistence.clearLastModelId()
            return
        }
        
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
                compactLayout
            } else {
                regularLayout
            }
        }
        .sheet(isPresented: $showingModelManagement) {
            NavigationStack {
                ModelManagementView(modelManager: container.modelManager)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                showingModelManagement = false
                            } label: {
                                Text("Done")
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.escherPrism)
                            }
                        }
                    }
            }
            .presentationDragIndicator(.visible)
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
            await container.autoLoadLastModelIfNeeded()
            await container.agentSession.bootstrapIfNeeded()
        }
    }
    
    // MARK: - Compact Layout (iPhone)
    
    private var compactLayout: some View {
        TabView(selection: $selectedTab) {
            // Chat Tab
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
                VStack {
                    Image(systemName: selectedTab == .chat ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                    Text("Chat")
                }
            }
            .tag(Tab.chat)

            // Files Tab
            NavigationStack {
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
            }
            .tabItem {
                VStack {
                    Image(systemName: selectedTab == .files ? "folder.fill" : "folder")
                    Text("Files")
                }
            }
            .tag(Tab.files)
        }
        .tint(Color.escherInk)
    }
    
    // MARK: - Regular Layout (iPad)
    
    private var regularLayout: some View {
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
        .tint(Color.escherInk)
    }
}

#Preview {
    RootView(container: .preview)
}
