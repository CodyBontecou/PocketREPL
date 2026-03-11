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
    @State private var showingSettings = false
    @State private var showingUnloadAlert = false
    @State private var selectedTab: Tab = .chat
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme

    enum Tab {
        case files
        case chat
        case docs
        case settings
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
                                Text("Done", comment: "Button to dismiss sheet")
                                    .font(.escherSubheadline)
                                    .foregroundStyle(Color.escherPrism)
                            }
                        }
                    }
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onChange(of: memoryCoordinator.modelWasUnloadedAutomatically) { _, newValue in
            if newValue {
                showingUnloadAlert = true
            }
        }
        .alert(String(localized: "Model Unloaded"), isPresented: $showingUnloadAlert) {
            Button(String(localized: "Reload Model")) {
                memoryCoordinator.clearUnloadState()
                showingModelManagement = true
            }
            Button(String(localized: "OK"), role: .cancel) {
                memoryCoordinator.clearUnloadState()
            }
        } message: {
            Text(memoryCoordinator.lastUnloadReason?.message ?? String(localized: "Model was unloaded automatically."))
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
                AgentView(
                    session: container.agentSession,
                    modelManager: container.modelManager,
                    onModelButtonTapped: { showingModelManagement = true }
                )
            }
            .tabItem {
                VStack {
                    Image(systemName: selectedTab == .chat ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                    Text("Chat", comment: "Tab label for chat view")
                }
            }
            .tag(Tab.chat)
            .accessibilityIdentifier("tab_chat")
            .accessibilityHint(String(localized: "Chat with the AI assistant"))

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
                            .accessibilityLabel(String(localized: "Manage models"))
                            .accessibilityHint(String(localized: "Open model management to download, load, or unload AI models"))
                        }
                    }
            }
            .tabItem {
                VStack {
                    Image(systemName: selectedTab == .files ? "folder.fill" : "folder")
                    Text("Files", comment: "Tab label for files view")
                }
            }
            .tag(Tab.files)
            .accessibilityIdentifier("tab_files")
            .accessibilityHint(String(localized: "Browse project files and folders"))
            
            // Docs Tab
            NavigationStack {
                DocsView()
            }
            .tabItem {
                VStack {
                    Image(systemName: selectedTab == .docs ? "book.closed.fill" : "book.closed")
                    Text("Docs", comment: "Tab label for documentation view")
                }
            }
            .tag(Tab.docs)
            .accessibilityIdentifier("tab_docs")
            .accessibilityHint(String(localized: "Learn how PocketREPL works"))
            
            // Settings Tab
            NavigationStack {
                SettingsContentView()
            }
            .tabItem {
                VStack {
                    Image(systemName: selectedTab == .settings ? "gearshape.fill" : "gearshape")
                    Text("Settings", comment: "Tab label for settings view")
                }
            }
            .tag(Tab.settings)
            .accessibilityIdentifier("tab_settings")
            .accessibilityHint(String(localized: "Adjust app settings and preferences"))
        }
        .accessibilityIdentifier("main_tab_view")
        .tint(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
    }
    
    // MARK: - Regular Layout (iPad)
    
    private var regularLayout: some View {
        NavigationSplitView {
            FileBrowserView(projectStore: container.projectStore)
                .navigationTitle(container.workspaceInfo.displayName)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingSettings = true
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(colorScheme == .dark ? Color(white: 0.2) : Color.escherPaper)
                                    .frame(width: 32, height: 32)
                                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.06), radius: 4, x: 0, y: 2)
                                
                                Image(systemName: "gearshape.fill")
                                    .font(.escherFootnote)
                                    .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
                            }
                        }
                        .accessibilityLabel(String(localized: "Settings"))
                        .accessibilityHint(String(localized: "Open app settings"))
                    }
                    
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingModelManagement = true
                        } label: {
                            ModelStatusView(modelManager: container.modelManager)
                        }
                        .accessibilityLabel(String(localized: "Manage models"))
                        .accessibilityHint(String(localized: "Open model management to download, load, or unload AI models"))
                    }
                }
        } detail: {
            AgentView(
                session: container.agentSession,
                modelManager: container.modelManager,
                onModelButtonTapped: { showingModelManagement = true }
            )
        }
        .tint(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
    }
}

#Preview {
    RootView(container: .preview)
}
