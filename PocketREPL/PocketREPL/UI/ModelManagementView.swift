import SwiftUI

// MARK: - Model Management View

/// Main view for browsing, downloading, and managing local LLM models.
/// Greyscale design matching the chat interface aesthetic.
struct ModelManagementView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var modelManager: ModelBackendManager
    
    @State private var downloadManager = ModelDownloadManager()
    @State private var installedModels: [InstalledModel] = []
    @State private var downloadProgress: [String: DownloadProgress] = [:]
    @State private var activeDownloads: Set<String> = []
    @State private var errorMessage: String?
    @State private var showingDeleteConfirmation = false
    @State private var modelToDelete: InstalledModel?
    @State private var isLoading = false
    @State private var storageInfo: (used: Int64, available: Int64) = (0, 0)
    @State private var showingCustomModelSheet = false
    @State private var customModelURL = ""
    @State private var customModelContextSize = "4096"
    @State private var expandedFamilies: Set<ModelRegistryEntry.ModelFamily> = []
    
    // Adaptive colors
    private var foregroundColor: Color {
        colorScheme == .dark ? .escherPaper : .escherInk
    }
    
    private var surfaceColor: Color {
        colorScheme == .dark ? Color(white: 0.14) : .escherPaper
    }
    
    private var accentColor: Color {
        colorScheme == .dark ? .escherPaper : .escherInk
    }
    
    var body: some View {
        ZStack {
            EscherBackground()
            
            ScrollView {
                VStack(spacing: 20) {
                    // Active Model Card
                    activeModelCard
                    
                    // Storage Visualization
                    storageCard
                    
                    // Installed Models
                    installedModelsSection
                    
                    // Available Models
                    availableModelsSection
                }
                .padding(16)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Models", comment: "Navigation title for model management")
                    .font(.escherHeadline)
                    .foregroundStyle(foregroundColor)
            }
        }
        .refreshable {
            await refreshData()
        }
        .task {
            await refreshData()
        }
        .alert(String(localized: "Error"), isPresented: .constant(errorMessage != nil)) {
            Button(String(localized: "OK")) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            String(localized: "Delete Model"),
            isPresented: $showingDeleteConfirmation,
            presenting: modelToDelete
        ) { model in
            Button(String(localized: "Delete \(model.name)"), role: .destructive) {
                Task { await deleteModel(model) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { model in
            Text("This will remove \(model.formattedSize) from your device. This action cannot be undone.")
        }
        .overlay {
            if isLoading {
                loadingOverlay
            }
        }
        .sheet(isPresented: $showingCustomModelSheet) {
            CustomModelInputSheet(
                url: $customModelURL,
                contextSize: $customModelContextSize,
                onSubmit: { url, contextSize in
                    Task { await downloadCustomModel(url: url, contextSize: contextSize) }
                }
            )
        }
        .escherNavigationStyle()
        .onChange(of: modelManager.state) { oldState, newState in
            // Announce significant model state changes to VoiceOver users
            let announcement: String? = switch newState {
            case .ready:
                if case .loading = oldState {
                    String(localized: "Model loaded successfully")
                } else {
                    nil
                }
            case .unloaded:
                if case .ready = oldState {
                    String(localized: "Model unloaded")
                } else {
                    nil
                }
            case .error:
                String(localized: "Model failed to load")
            case .loading, .generating:
                nil // Don't announce intermediate states
            }
            if let announcement {
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
        }
    }
    
    // MARK: - Active Model Card
    
    private var activeModelCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("ACTIVE MODEL", comment: "Section header for currently loaded model")
                    .font(.escherCaption2)
                    .tracking(1)
                    .foregroundStyle(Color.escherSecondaryText)
                
                Spacer()
                
                modelStateIndicator
            }
            
            if let info = modelManager.modelInfo {
                // Model info
                HStack(alignment: .top, spacing: 14) {
                    // Model Provider Icon for active model
                    ModelProviderIcon(
                        family: activeModelFamily,
                        size: 50,
                        isActive: true,
                        colorScheme: colorScheme
                    )
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text(info.name)
                            .font(.escherHeadline)
                            .foregroundStyle(foregroundColor)
                        
                        HStack(spacing: 8) {
                            GreyscaleBadge(text: info.parameterCount, colorScheme: colorScheme)
                            if let quant = info.quantization {
                                GreyscaleBadge(text: quant, colorScheme: colorScheme, variant: .subtle)
                            }
                        }
                    }
                    
                    Spacer()
                }
                
                // Stats bar
                HStack(spacing: 20) {
                    GreyscaleStatItem(icon: "memorychip", value: formatMemory(info.memoryUsage), label: String(localized: "Memory"), colorScheme: colorScheme)
                    GreyscaleStatItem(icon: "text.alignleft", value: "\(info.contextSize)", label: String(localized: "Context"), colorScheme: colorScheme)
                }
                
                // llama.cpp badge
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.escherCaption)
                    Text("Code generation powered by llama.cpp", comment: "Badge showing llama.cpp is used")
                        .font(.escherCaption)
                }
                .foregroundStyle(Color.escherSecondaryText)
                .padding(.top, 4)
                
                // Unload button - uses red for destructive
                Button(role: .destructive) {
                    Task { await modelManager.unload(clearPersistence: true) }
                } label: {
                    HStack {
                        Image(systemName: "eject.fill")
                        Text("Unload Model", comment: "Button to unload the current model")
                    }
                    .font(.escherFootnote.weight(.semibold))
                    .foregroundStyle(Color.escherError)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.escherError.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Unload model"))
                .accessibilityHint(String(localized: "Removes the current model from memory"))
                
            } else {
                // No model loaded state
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(foregroundColor.opacity(0.05))
                            .frame(width: 70, height: 70)
                        
                        Image(systemName: "cpu")
                            .font(.escherDisplay.weight(.thin))
                            .foregroundStyle(foregroundColor.opacity(0.3))
                    }
                    
                    VStack(spacing: 4) {
                        Text("No Model Loaded", comment: "Displayed when no model is loaded")
                            .font(.escherCallout.weight(.semibold))
                            .foregroundStyle(foregroundColor)
                        
                        Text("Download and load a model to generate code", comment: "Instruction")
                            .font(.escherFootnote)
                            .foregroundStyle(Color.escherSecondaryText)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
        .padding(18)
        .escherCard()
    }
    
    @ViewBuilder
    private var modelStateIndicator: some View {
        switch modelManager.state {
        case .ready:
            HStack(spacing: 6) {
                Circle()
                    .fill(foregroundColor)
                    .frame(width: 8, height: 8)
                Text("Ready", comment: "Model status indicating ready to use")
                    .font(.escherCaption.weight(.semibold))
                    .foregroundStyle(foregroundColor)
            }
        case .generating:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Generating", comment: "Model status indicating text generation")
                    .font(.escherCaption.weight(.semibold))
                    .foregroundStyle(foregroundColor.opacity(0.7))
            }
        case .loading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 40)
                    .tint(foregroundColor.opacity(0.7))
                Text("\(Int(progress * 100))%")
                    .font(.escherCaption.weight(.semibold))
                    .foregroundStyle(foregroundColor.opacity(0.7))
            }
        case .error:
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.escherError)
                    .frame(width: 8, height: 8)
                Text("Error", comment: "Model status indicating an error")
                    .font(.escherCaption.weight(.semibold))
                    .foregroundStyle(Color.escherError)
            }
        case .unloaded:
            EmptyView()
        }
    }
    
    // MARK: - Storage Card
    
    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("STORAGE", comment: "Section header for storage information")
                .font(.escherCaption2)
                .tracking(1)
                .foregroundStyle(Color.escherSecondaryText)
            
            // Greyscale storage bar
            GeometryReader { geo in
                let totalWidth = geo.size.width
                let total = Double(storageInfo.used + storageInfo.available)
                let usedRatio = total > 0 ? min(1.0, Double(storageInfo.used) / total) : 0
                
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(foregroundColor.opacity(0.08))
                    
                    // Used portion
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(foregroundColor.opacity(0.5))
                        .frame(width: totalWidth * usedRatio)
                    
                    // Tessellation overlay
                    TessellationPattern(density: 20, opacity: 0.1)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .frame(height: 12)
            
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Models", comment: "Label for models storage")
                        .font(.escherCaption)
                        .foregroundStyle(Color.escherSecondaryText)
                    Text(formatBytes(storageInfo.used))
                        .font(.escherSubheadline)
                        .foregroundStyle(foregroundColor)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Available", comment: "Label for available storage")
                        .font(.escherCaption)
                        .foregroundStyle(Color.escherSecondaryText)
                    Text(formatBytes(storageInfo.available))
                        .font(.escherSubheadline)
                        .foregroundStyle(storageInfo.available < 1_000_000_000 ? Color.escherError : foregroundColor)
                }
            }
        }
        .padding(18)
        .escherCard()
    }
    
    // MARK: - Installed Models Section
    
    private var installedModelsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("INSTALLED", comment: "Section header for installed models")
                    .font(.escherCaption2)
                    .tracking(1)
                    .foregroundStyle(Color.escherSecondaryText)
                
                Spacer()
                
                Text("\(installedModels.count)")
                    .font(.escherCaption.weight(.bold))
                    .foregroundStyle(foregroundColor.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(foregroundColor.opacity(0.1))
                    )
            }
            
            if installedModels.isEmpty {
                HStack {
                    Spacer()
                    Text("No models installed yet", comment: "Empty state message")
                        .font(.escherFootnote)
                        .foregroundStyle(Color.escherSecondaryText)
                        .padding(.vertical, 20)
                    Spacer()
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(installedModels) { model in
                        InstalledModelRow(
                            model: model,
                            isActive: modelManager.modelInfo?.name == model.name,
                            activeModelInfo: modelManager.modelInfo?.name == model.name ? modelManager.modelInfo : nil,
                            onLoad: { Task { await loadModel(model) } },
                            onDelete: {
                                modelToDelete = model
                                showingDeleteConfirmation = true
                            }
                        )
                    }
                }
            }
        }
        .padding(18)
        .escherCard()
    }
    
    // MARK: - Available Models Section
    
    private var availableModelsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("AVAILABLE FOR DOWNLOAD", comment: "Section header for downloadable models")
                    .font(.escherCaption2)
                    .tracking(1)
                    .foregroundStyle(Color.escherSecondaryText)
                
                Spacer()
                
                Button {
                    showingCustomModelSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.escherMini.weight(.bold))
                        Text("Custom", comment: "Button to add custom model")
                            .font(.escherCaption2)
                    }
                    .foregroundStyle(foregroundColor.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(foregroundColor.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
            }
            
            // Grouped by family with accordions
            VStack(spacing: 10) {
                ForEach(groupedAvailableModels, id: \.family) { group in
                    ModelFamilyAccordion(
                        family: group.family,
                        models: group.models,
                        isExpanded: expandedFamilies.contains(group.family),
                        downloadProgress: downloadProgress,
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                if expandedFamilies.contains(group.family) {
                                    expandedFamilies.remove(group.family)
                                } else {
                                    expandedFamilies.insert(group.family)
                                }
                            }
                        },
                        onDownload: { model in
                            Task { await downloadModel(model) }
                        },
                        onCancelDownload: { modelId in
                            Task { await cancelDownload(modelId) }
                        }
                    )
                }
                
                // Show pending custom models (not yet downloaded)
                if !pendingCustomModels.isEmpty {
                    ModelFamilyAccordion(
                        family: .other,
                        models: pendingCustomModels,
                        isExpanded: expandedFamilies.contains(.other),
                        downloadProgress: downloadProgress,
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                if expandedFamilies.contains(.other) {
                                    expandedFamilies.remove(.other)
                                } else {
                                    expandedFamilies.insert(.other)
                                }
                            }
                        },
                        onDownload: { model in
                            Task { await downloadModel(model) }
                        },
                        onCancelDownload: { modelId in
                            Task { await cancelDownload(modelId) }
                        }
                    )
                }
            }
            
            // Footer
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.escherCaption)
                    Text("Models are downloaded from Hugging Face and stored locally.", comment: "Footer text")
                        .font(.escherCaption)
                }
                
                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .font(.escherCaption)
                    Text("Code is generated on-device using llama.cpp.", comment: "Footer text about llama.cpp")
                        .font(.escherCaption)
                }
            }
            .foregroundStyle(Color.escherSecondaryText)
            .padding(.top, 8)
        }
        .padding(18)
        .escherCard()
    }
    
    /// Groups available models by family for accordion display
    private var groupedAvailableModels: [(family: ModelRegistryEntry.ModelFamily, models: [ModelRegistryEntry])] {
        let grouped = Dictionary(grouping: availableModels) { $0.family }
        return grouped
            .map { (family: $0.key, models: $0.value.sorted { $0.sizeBytes < $1.sizeBytes }) }
            .sorted { $0.family.sortOrder < $1.family.sortOrder }
    }
    
    private var availableModels: [ModelRegistryEntry] {
        let installedIds = Set(installedModels.map { $0.id })
        return ModelRegistry.models.filter { !installedIds.contains($0.id) }
    }
    
    private var pendingCustomModels: [ModelRegistryEntry] {
        let installedIds = Set(installedModels.map { $0.id })
        return CustomModelStorage.loadCustomModels().filter { !installedIds.contains($0.id) }
    }
    
    /// Get the model family for the currently active model
    private var activeModelFamily: ModelRegistryEntry.ModelFamily {
        // Try to find the installed model that matches the current model info
        if let info = modelManager.modelInfo {
            if let installed = installedModels.first(where: { $0.name == info.name }) {
                return installed.registryEntry?.family ?? .other
            }
        }
        return .other
    }
    
    // MARK: - Loading Overlay
    
    private var loadingOverlay: some View {
        ZStack {
            Color.escherInk.opacity(0.5)
                .ignoresSafeArea()
            
            VStack(spacing: 24) {
                InfiniteStairs(size: 56)
                
                Text("Loading model...", comment: "Loading overlay text")
                    .font(.escherCallout.weight(.semibold))
                    .foregroundStyle(Color.escherPaper)
            }
            .padding(40)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
        }
    }
    
    // MARK: - Actions
    
    private func refreshData() async {
        installedModels = await downloadManager.installedModels()
        let used = await downloadManager.totalStorageUsed()
        let available = await downloadManager.availableStorage()
        storageInfo = (used, available)
    }
    
    private func loadModel(_ model: InstalledModel) async {
        isLoading = true
        defer { isLoading = false }
        
        let path = model.path.path
        let contextSize = model.registryEntry?.recommendedContextSize ?? 4096
        
        do {
            let config = ModelConfiguration(
                modelPath: path,
                contextSize: contextSize,
                gpuLayers: 99,
                threadCount: 4
            )

            // Route to FlashInferenceBackend for .flashpack models,
            // LlamaBackend for standard .gguf models.
            if path.hasSuffix(".flashpack") {
                let backend = FlashInferenceBackend(config: FlashBackendConfig(
                    modelPath: path,
                    contextSize: contextSize,
                    temperature: 0.2,
                    topK: 40,
                    topP: 0.95
                ))
                await modelManager.setBackend(backend)
            } else {
                guard model.registryEntry != nil else {
                    errorMessage = String(localized: "Cannot load unknown model format")
                    return
                }
                let backend = LlamaBackend()
                await modelManager.setBackend(backend)
            }

            try await modelManager.load(configuration: config, modelId: model.id, persistSelection: true)
            
        } catch {
            errorMessage = String(localized: "Failed to load model: \(error.localizedDescription)")
        }
    }
    
    private func downloadModel(_ model: ModelRegistryEntry) async {
        activeDownloads.insert(model.id)
        downloadProgress[model.id] = DownloadProgress(
            modelId: model.id,
            progress: 0,
            bytesDownloaded: 0,
            totalBytes: model.sizeBytes,
            estimatedTimeRemaining: nil
        )
        
        do {
            _ = try await downloadManager.download(model: model) { progress in
                Task { @MainActor in
                    downloadProgress[model.id] = progress
                }
            }
            
            await refreshData()
            
            // Announce download completion to VoiceOver users
            UIAccessibility.post(
                notification: .announcement,
                argument: String(localized: "Download complete: \(model.name)")
            )
            
        } catch {
            if (error as? ModelError) != .cancelled {
                errorMessage = String(localized: "Download failed: \(error.localizedDescription)")
                // Announce download failure to VoiceOver users
                UIAccessibility.post(
                    notification: .announcement,
                    argument: String(localized: "Download failed for \(model.name)")
                )
            }
        }
        
        downloadProgress.removeValue(forKey: model.id)
        activeDownloads.remove(model.id)
    }
    
    private func cancelDownload(_ modelId: String) async {
        await downloadManager.cancelDownload(modelId: modelId)
        downloadProgress.removeValue(forKey: modelId)
        activeDownloads.remove(modelId)
    }
    
    private func deleteModel(_ model: InstalledModel) async {
        if modelManager.modelInfo?.name == model.name {
            await modelManager.unload()
        }
        
        do {
            try await downloadManager.deleteModel(id: model.id)
            await refreshData()
            // Announce deletion to VoiceOver users
            UIAccessibility.post(
                notification: .announcement,
                argument: String(localized: "Model deleted: \(model.name)")
            )
        } catch {
            errorMessage = String(localized: "Failed to delete model: \(error.localizedDescription)")
        }
    }
    
    private func downloadCustomModel(url: String, contextSize: Int) async {
        // Create a temporary ID for progress tracking
        guard let model = ModelRegistryEntry.fromHuggingFaceURL(url, contextSize: contextSize) else {
            errorMessage = String(localized: "Invalid Hugging Face URL. Expected format:\nhttps://huggingface.co/{org}/{repo}/resolve/main/{filename}.gguf")
            return
        }
        
        activeDownloads.insert(model.id)
        downloadProgress[model.id] = DownloadProgress(
            modelId: model.id,
            progress: 0,
            bytesDownloaded: 0,
            totalBytes: 0,
            estimatedTimeRemaining: nil
        )
        
        do {
            _ = try await downloadManager.downloadCustomModel(
                urlString: url,
                contextSize: contextSize
            ) { progress in
                Task { @MainActor in
                    downloadProgress[model.id] = progress
                }
            }
            
            await refreshData()
            
            // Clear the input fields
            customModelURL = ""
            customModelContextSize = "4096"
            
            // Announce download completion to VoiceOver users
            UIAccessibility.post(
                notification: .announcement,
                argument: String(localized: "Custom model download complete")
            )
            
        } catch {
            if (error as? ModelError) != .cancelled {
                errorMessage = String(localized: "Download failed: \(error.localizedDescription)")
                // Announce download failure to VoiceOver users
                UIAccessibility.post(
                    notification: .announcement,
                    argument: String(localized: "Custom model download failed")
                )
            }
        }
        
        downloadProgress.removeValue(forKey: model.id)
        activeDownloads.remove(model.id)
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    
    private func formatMemory(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}

// MARK: - Greyscale Supporting Components

struct GreyscaleBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let customColorScheme: ColorScheme?
    let variant: BadgeVariant
    
    enum BadgeVariant {
        case standard
        case subtle
    }
    
    init(text: String, colorScheme: ColorScheme? = nil, variant: BadgeVariant = .standard) {
        self.text = text
        self.customColorScheme = colorScheme
        self.variant = variant
    }
    
    private var effectiveScheme: ColorScheme {
        customColorScheme ?? colorScheme
    }
    
    private var foreground: Color {
        let base = effectiveScheme == .dark ? Color.escherPaper : Color.escherInk
        return variant == .subtle ? base.opacity(0.6) : base
    }
    
    private var background: Color {
        let base = effectiveScheme == .dark ? Color.escherPaper : Color.escherInk
        return base.opacity(variant == .subtle ? 0.06 : 0.1)
    }
    
    var body: some View {
        Text(text)
            .font(.escherMini.weight(.bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(background)
            )
    }
}

struct GreyscaleStatItem: View {
    let icon: String
    let value: String
    let label: String
    let colorScheme: ColorScheme
    
    private var foreground: Color {
        colorScheme == .dark ? .escherPaper : .escherInk
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.escherCaption)
                .foregroundStyle(Color.escherSecondaryText)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.escherFootnote.weight(.bold))
                    .foregroundStyle(foreground)
                Text(label)
                    .font(.escherMini)
                    .foregroundStyle(Color.escherSecondaryText)
            }
        }
    }
}

// MARK: - Model Provider Icon (Greyscale)

/// Renders a monochromatic icon for each model provider/family.
struct ModelProviderIcon: View {
    @Environment(\.colorScheme) private var environmentColorScheme
    let family: ModelRegistryEntry.ModelFamily
    let size: CGFloat
    let isActive: Bool
    let customColorScheme: ColorScheme?
    
    init(family: ModelRegistryEntry.ModelFamily, size: CGFloat = 44, isActive: Bool = false, colorScheme: ColorScheme? = nil) {
        self.family = family
        self.size = size
        self.isActive = isActive
        self.customColorScheme = colorScheme
    }
    
    private var effectiveScheme: ColorScheme {
        customColorScheme ?? environmentColorScheme
    }
    
    private var foregroundColor: Color {
        effectiveScheme == .dark ? .escherPaper : .escherInk
    }
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(foregroundColor.opacity(isActive ? 0.15 : 0.08))
                .frame(width: size, height: size)
            
            iconContent
                .frame(width: size * 0.5, height: size * 0.5)
        }
    }
    
    @ViewBuilder
    private var iconContent: some View {
        switch family {
        case .qwen25Coder, .qwen3, .qwen35:
            QwenIcon()
                .stroke(foregroundColor.opacity(isActive ? 1.0 : 0.6), lineWidth: size * 0.045)
        case .gemma3n, .codegemma:
            GemmaIcon()
                .fill(foregroundColor.opacity(isActive ? 1.0 : 0.6))
        case .starcoder:
            StarCoderIcon()
                .fill(foregroundColor.opacity(isActive ? 1.0 : 0.6))
        case .deepseek:
            DeepSeekIcon()
                .stroke(foregroundColor.opacity(isActive ? 1.0 : 0.6), lineWidth: size * 0.045)
        case .other:
            Image(systemName: "cube.box")
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(foregroundColor.opacity(isActive ? 1.0 : 0.6))
        }
    }
}

/// Qwen icon - stylized "Q" with cloud influence (Alibaba Cloud)
struct QwenIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.45
        
        // Main circle (Q body)
        path.addArc(center: center, radius: radius, startAngle: .degrees(45), endAngle: .degrees(360 + 45), clockwise: false)
        
        // Q tail - diagonal stroke
        let tailStart = CGPoint(x: center.x + radius * 0.4, y: center.y + radius * 0.4)
        let tailEnd = CGPoint(x: center.x + radius * 0.95, y: center.y + radius * 0.95)
        path.move(to: tailStart)
        path.addLine(to: tailEnd)
        
        return path
    }
}

/// CodeGemma icon - gemstone/diamond shape (Google's Gemini inspiration)
struct GemmaIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        
        // Diamond with facets
        path.move(to: CGPoint(x: w * 0.5, y: 0))
        path.addLine(to: CGPoint(x: w, y: h * 0.35))
        path.addLine(to: CGPoint(x: w * 0.5, y: h))
        path.addLine(to: CGPoint(x: 0, y: h * 0.35))
        path.closeSubpath()
        
        // Inner facet (creates gem effect)
        path.move(to: CGPoint(x: w * 0.25, y: h * 0.35))
        path.addLine(to: CGPoint(x: w * 0.5, y: h * 0.15))
        path.addLine(to: CGPoint(x: w * 0.75, y: h * 0.35))
        path.addLine(to: CGPoint(x: w * 0.5, y: h * 0.55))
        path.closeSubpath()
        
        return path
    }
}

/// StarCoder icon - 5-pointed star (BigCode/HuggingFace)
struct StarCoderIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) * 0.5
        let innerRadius = outerRadius * 0.4
        
        var path = Path()
        
        for i in 0..<5 {
            let outerAngle = Angle(degrees: Double(i) * 72 - 90)
            let innerAngle = Angle(degrees: Double(i) * 72 - 90 + 36)
            
            let outerPoint = CGPoint(
                x: center.x + outerRadius * CGFloat(cos(outerAngle.radians)),
                y: center.y + outerRadius * CGFloat(sin(outerAngle.radians))
            )
            let innerPoint = CGPoint(
                x: center.x + innerRadius * CGFloat(cos(innerAngle.radians)),
                y: center.y + innerRadius * CGFloat(sin(innerAngle.radians))
            )
            
            if i == 0 {
                path.move(to: outerPoint)
            } else {
                path.addLine(to: outerPoint)
            }
            path.addLine(to: innerPoint)
        }
        path.closeSubpath()
        
        return path
    }
}

/// DeepSeek icon - wave/search pattern (deep exploration)
struct DeepSeekIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        
        // Magnifying glass circle
        let glassCenter = CGPoint(x: w * 0.4, y: h * 0.4)
        let glassRadius = w * 0.32
        path.addArc(center: glassCenter, radius: glassRadius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
        
        // Handle
        let handleStart = CGPoint(x: glassCenter.x + glassRadius * 0.7, y: glassCenter.y + glassRadius * 0.7)
        let handleEnd = CGPoint(x: w * 0.95, y: h * 0.95)
        path.move(to: handleStart)
        path.addLine(to: handleEnd)
        
        // Inner wave (represents "deep" search)
        path.move(to: CGPoint(x: glassCenter.x - glassRadius * 0.5, y: glassCenter.y))
        path.addQuadCurve(
            to: CGPoint(x: glassCenter.x + glassRadius * 0.5, y: glassCenter.y),
            control: CGPoint(x: glassCenter.x, y: glassCenter.y - glassRadius * 0.4)
        )
        
        return path
    }
}

/// Row displaying an installed model with load/delete actions.
struct InstalledModelRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: InstalledModel
    let isActive: Bool
    let activeModelInfo: ModelInfo?
    let onLoad: () -> Void
    let onDelete: () -> Void
    
    @State private var showingDetail = false
    
    private var foreground: Color {
        colorScheme == .dark ? .escherPaper : .escherInk
    }
    
    private var surface: Color {
        colorScheme == .dark ? Color(white: 0.18) : .escherPaper.opacity(0.6)
    }
    
    var body: some View {
        Button {
            showingDetail = true
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.name)
                            .font(.escherSubheadline)
                            .foregroundStyle(foreground)
                            .lineLimit(1)
                        
                        if isActive {
                            Text("ACTIVE", comment: "Badge indicating model is active")
                                .font(.escherMini.weight(.bold))
                                .foregroundStyle(foreground)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(foreground.opacity(0.15))
                                )
                        }
                        
                        if model.isCustom {
                            Text("CUSTOM", comment: "Badge indicating custom model")
                                .font(.escherMini.weight(.bold))
                                .foregroundStyle(foreground.opacity(0.6))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(foreground.opacity(0.08))
                                )
                        }
                    }
                    
                    HStack(spacing: 6) {
                        if let entry = model.registryEntry {
                            Text(entry.parameterCount)
                            Text("•")
                            Text(entry.quantization)
                            Text("•")
                        }
                        Text(model.formattedSize)
                    }
                    .font(.escherCaption)
                    .foregroundStyle(Color.escherSecondaryText)
                }
                
                Spacer()
                
                // Chevron indicator
                Image(systemName: "chevron.right")
                    .font(.escherCaption.weight(.semibold))
                    .foregroundStyle(foreground.opacity(0.3))
                
                if !isActive {
                    Button {
                        onLoad()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(foreground.opacity(0.1))
                                .frame(width: 36, height: 36)
                            
                            Image(systemName: "play.fill")
                                .font(.escherFootnote.weight(.semibold))
                                .foregroundStyle(foreground.opacity(0.7))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(surface)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("installed_model_\(model.id)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(modelAccessibilityLabel)
        .accessibilityHint(String(localized: "Double-tap to view details"))
        .accessibilityInputLabels([model.name])
        .accessibilityAction(named: String(localized: "Load model")) { onLoad() }
        .accessibilityAction(named: String(localized: "Delete model")) { onDelete() }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
        }
        .sheet(isPresented: $showingDetail) {
            ModelDetailView(
                model: model,
                isActive: isActive,
                activeModelInfo: activeModelInfo,
                onLoad: onLoad,
                onDelete: onDelete
            )
        }
    }
    
    private var modelAccessibilityLabel: String {
        var parts: [String] = [model.name]
        
        if isActive {
            parts.append(String(localized: "currently active"))
        }
        
        if model.isCustom {
            parts.append(String(localized: "custom model"))
        }
        
        if let entry = model.registryEntry {
            parts.append("\(entry.parameterCount) parameters")
            parts.append("\(entry.quantization) quantization")
        }
        
        parts.append(model.formattedSize)
        
        return parts.joined(separator: ", ")
    }
}

/// Row displaying a downloadable model from the registry.
struct DownloadableModelRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: ModelRegistryEntry
    let onDownload: () -> Void
    
    @State private var showingDetail = false
    
    private var isRecommended: Bool {
        model.description.contains("Recommended")
    }
    
    private var isCustom: Bool {
        model.isCustom
    }
    
    private var foreground: Color {
        colorScheme == .dark ? .escherPaper : .escherInk
    }
    
    private var surface: Color {
        colorScheme == .dark ? Color(white: 0.18) : .escherPaper.opacity(0.6)
    }
    
    var body: some View {
        Button {
            showingDetail = true
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(model.name)
                            .font(.escherSubheadline)
                            .foregroundStyle(foreground)
                            .lineLimit(1)
                        
                        if isRecommended {
                            Text("★")
                                .font(.escherMini.weight(.bold))
                                .foregroundStyle(foreground.opacity(0.7))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(foreground.opacity(0.1))
                                )
                        }
                        
                        if isCustom {
                            Text("CUSTOM", comment: "Badge for custom model")
                                .font(.escherMini.weight(.bold))
                                .foregroundStyle(foreground.opacity(0.6))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(foreground.opacity(0.08))
                                )
                        }
                    }
                    
                    Text(model.description)
                        .font(.escherCaption)
                        .foregroundStyle(Color.escherSecondaryText)
                        .lineLimit(2)
                    
                    HStack(spacing: 6) {
                        GreyscaleBadge(text: model.parameterCount, colorScheme: colorScheme)
                        GreyscaleBadge(text: model.quantization, colorScheme: colorScheme, variant: .subtle)
                        if model.sizeBytes > 0 {
                            GreyscaleBadge(text: model.formattedSize, colorScheme: colorScheme, variant: .subtle)
                        }
                    }
                }
                
                Spacer()
                
                // Chevron indicator
                Image(systemName: "chevron.right")
                    .font(.escherCaption.weight(.semibold))
                    .foregroundStyle(foreground.opacity(0.3))
                
                Button {
                    onDownload()
                } label: {
                    ZStack {
                        Circle()
                            .fill(foreground.opacity(0.1))
                            .frame(width: 36, height: 36)
                        
                        Image(systemName: "arrow.down")
                            .font(.escherFootnote.weight(.bold))
                            .foregroundStyle(foreground.opacity(0.7))
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(surface)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("downloadable_model_\(model.id)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(downloadableModelAccessibilityLabel)
        .accessibilityHint(String(localized: "Double-tap to view details"))
        .accessibilityInputLabels([model.name, String(localized: "Download \(model.name)")])
        .accessibilityAction(named: String(localized: "Download model")) { onDownload() }
        .sheet(isPresented: $showingDetail) {
            RegistryModelDetailView(model: model, onDownload: onDownload)
        }
    }
    
    private var downloadableModelAccessibilityLabel: String {
        var parts: [String] = [model.name]
        
        if isRecommended {
            parts.append(String(localized: "recommended"))
        }
        
        if isCustom {
            parts.append(String(localized: "custom model"))
        }
        
        parts.append(model.description)
        parts.append("\(model.parameterCount) parameters")
        parts.append("\(model.quantization) quantization")
        
        if model.sizeBytes > 0 {
            parts.append(model.formattedSize)
        }
        
        return parts.joined(separator: ", ")
    }
}

/// Row showing download progress with cancel button.
struct DownloadProgressRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: ModelRegistryEntry
    let progress: DownloadProgress
    let onCancel: () -> Void
    
    private var foreground: Color {
        colorScheme == .dark ? .escherPaper : .escherInk
    }
    
    private var surface: Color {
        colorScheme == .dark ? Color(white: 0.14) : .escherPaper
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 10) {
                    // Animated download icon
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(foreground.opacity(0.08))
                            .frame(width: 36, height: 36)
                        
                        InfiniteStairs(size: 20)
                    }
                    
                    Text(model.name)
                        .font(.escherSubheadline)
                        .foregroundStyle(foreground)
                }
                
                Spacer()
                
                Button(String(localized: "Cancel"), role: .destructive) {
                    onCancel()
                }
                .font(.escherFootnote.weight(.semibold))
                .foregroundStyle(Color.escherError)
            }
            
            // Greyscale progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(foreground.opacity(0.1))
                    
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(foreground.opacity(0.5))
                        .frame(width: geo.size.width * progress.progress)
                    
                    TessellationPattern(density: 30, opacity: 0.15)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .frame(height: 8)
            
            HStack {
                Text(progress.formattedProgress)
                    .font(.escherCaption)
                    .foregroundStyle(Color.escherSecondaryText)
                
                Spacer()
                
                if let eta = progress.estimatedTimeRemaining {
                    Text("~\(formatDuration(eta)) remaining", comment: "Estimated time remaining")
                        .font(.escherCaption)
                        .foregroundStyle(Color.escherSecondaryText)
                } else {
                    Text("\(progress.percentComplete)%")
                        .font(.escherCaption.weight(.bold))
                        .foregroundStyle(foreground.opacity(0.7))
                }
            }
        }
        .padding(14)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(surface)
                
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(foreground.opacity(0.15), lineWidth: 1)
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(downloadProgressAccessibilityLabel)
        .accessibilityValue("\(progress.percentComplete) percent")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityAction(named: String(localized: "Cancel download")) { onCancel() }
    }
    
    private var downloadProgressAccessibilityLabel: String {
        var label = String(localized: "Downloading \(model.name)")
        if let eta = progress.estimatedTimeRemaining {
            label += ", " + String(localized: "about \(formatDuration(eta)) remaining")
        }
        return label
    }
    
    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        } else if seconds < 3600 {
            return "\(Int(seconds / 60))m"
        } else {
            return "\(Int(seconds / 3600))h \(Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60))m"
        }
    }
}

// MARK: - Model Family Accordion

/// Expandable accordion for a group of models in the same family.
struct ModelFamilyAccordion: View {
    @Environment(\.colorScheme) private var colorScheme
    let family: ModelRegistryEntry.ModelFamily
    let models: [ModelRegistryEntry]
    let isExpanded: Bool
    let downloadProgress: [String: DownloadProgress]
    let onToggle: () -> Void
    let onDownload: (ModelRegistryEntry) -> Void
    let onCancelDownload: (String) -> Void
    
    private var foreground: Color {
        colorScheme == .dark ? .escherPaper : .escherInk
    }
    
    private var surface: Color {
        colorScheme == .dark ? Color(white: 0.18) : .escherPaper.opacity(0.6)
    }
    
    private var expandedSurface: Color {
        colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.96)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header (always visible, tappable)
            Button {
                onToggle()
            } label: {
                HStack(spacing: 14) {
                    // Family Icon
                    ModelProviderIcon(
                        family: family,
                        size: 44,
                        isActive: false,
                        colorScheme: colorScheme
                    )
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(family.displayName)
                            .font(.escherSubheadline.weight(.semibold))
                            .foregroundStyle(foreground)
                        
                        Text(family.familyDescription)
                            .font(.escherCaption)
                            .foregroundStyle(Color.escherSecondaryText)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    // Model count badge
                    Text("\(models.count)")
                        .font(.escherCaption.weight(.bold))
                        .foregroundStyle(foreground.opacity(0.6))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(foreground.opacity(0.08))
                        )
                    
                    // Chevron
                    Image(systemName: "chevron.right")
                        .font(.escherFootnote.weight(.semibold))
                        .foregroundStyle(foreground.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: isExpanded ? 12 : 12, style: .continuous)
                        .fill(surface)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(family.displayName), \(models.count) models")
            .accessibilityHint(isExpanded ? String(localized: "Double-tap to collapse") : String(localized: "Double-tap to expand"))
            .accessibilityAddTraits(.isButton)
            
            // Expanded content
            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(models) { model in
                        if let progress = downloadProgress[model.id] {
                            AccordionDownloadProgressRow(
                                model: model,
                                progress: progress,
                                onCancel: { onCancelDownload(model.id) }
                            )
                        } else {
                            AccordionModelRow(model: model) {
                                onDownload(model)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(expandedSurface)
                        .padding(.top, -8)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }
}

/// Compact model row for use inside accordion
struct AccordionModelRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: ModelRegistryEntry
    let onDownload: () -> Void
    
    @State private var showingDetail = false
    
    private var foreground: Color {
        colorScheme == .dark ? .escherPaper : .escherInk
    }
    
    private var isRecommended: Bool {
        model.description.contains("Recommended")
    }
    
    var body: some View {
        Button {
            showingDetail = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(model.name)
                            .font(.escherFootnote.weight(.medium))
                            .foregroundStyle(foreground)
                            .lineLimit(1)
                        
                        if isRecommended {
                            Text("★")
                                .font(.escherMini)
                                .foregroundStyle(foreground.opacity(0.6))
                        }
                    }
                    
                    HStack(spacing: 6) {
                        Text(model.parameterCount)
                            .font(.escherCaption2)
                        Text("•")
                            .font(.escherCaption2)
                        Text(model.quantization)
                            .font(.escherCaption2)
                        Text("•")
                            .font(.escherCaption2)
                        Text(model.formattedSize)
                            .font(.escherCaption2)
                    }
                    .foregroundStyle(Color.escherSecondaryText)
                }
                
                Spacer()
                
                Button {
                    onDownload()
                } label: {
                    ZStack {
                        Circle()
                            .fill(foreground.opacity(0.1))
                            .frame(width: 32, height: 32)
                        
                        Image(systemName: "arrow.down")
                            .font(.escherCaption.weight(.bold))
                            .foregroundStyle(foreground.opacity(0.7))
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(colorScheme == .dark ? Color(white: 0.16) : Color.white)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingDetail) {
            RegistryModelDetailView(model: model, onDownload: onDownload)
        }
    }
}

/// Compact download progress row for use inside accordion
struct AccordionDownloadProgressRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: ModelRegistryEntry
    let progress: DownloadProgress
    let onCancel: () -> Void
    
    private var foreground: Color {
        colorScheme == .dark ? .escherPaper : .escherInk
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 8) {
                    InfiniteStairs(size: 16)
                    
                    Text(model.name)
                        .font(.escherFootnote.weight(.medium))
                        .foregroundStyle(foreground)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Button(String(localized: "Cancel"), role: .destructive) {
                    onCancel()
                }
                .font(.escherCaption.weight(.semibold))
                .foregroundStyle(Color.escherError)
            }
            
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(foreground.opacity(0.1))
                    
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(foreground.opacity(0.5))
                        .frame(width: geo.size.width * progress.progress)
                }
            }
            .frame(height: 6)
            
            HStack {
                Text(progress.formattedProgress)
                    .font(.escherCaption2)
                    .foregroundStyle(Color.escherSecondaryText)
                
                Spacer()
                
                Text("\(progress.percentComplete)%")
                    .font(.escherCaption2.weight(.bold))
                    .foregroundStyle(foreground.opacity(0.7))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.16) : Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(foreground.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

// MARK: - Model Detail View (Installed Models)

/// Detailed view for an installed model showing all metadata.
struct ModelDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: InstalledModel
    let isActive: Bool
    let activeModelInfo: ModelInfo?
    let onLoad: () -> Void
    let onDelete: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    private var foreground: Color {
        colorScheme == .dark ? .escherPaper : .escherInk
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                EscherBackground()
                
                ScrollView {
                    VStack(spacing: 20) {
                        // Hero Section
                        heroSection
                        
                        // Quick Stats
                        quickStatsSection
                        
                        // Detailed Specifications
                        specsSection
                        
                        // File Information
                        fileInfoSection
                        
                        // Actions
                        actionsSection
                    }
                    .padding(16)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Model Details", comment: "Navigation title for model detail view")
                        .font(.escherHeadline)
                        .foregroundStyle(foreground)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Done")) {
                        dismiss()
                    }
                    .font(.escherCallout.weight(.semibold))
                    .foregroundStyle(foreground.opacity(0.7))
                }
            }
            .escherNavigationStyle()
        }
    }
    
    // MARK: - Hero Section
    
    private var heroSection: some View {
        VStack(spacing: 16) {
            // Model Provider Icon
            ModelProviderIcon(
                family: model.registryEntry?.family ?? .other,
                size: 80,
                isActive: isActive,
                colorScheme: colorScheme
            )
            
            VStack(spacing: 6) {
                Text(model.name)
                    .font(.escherTitle)
                    .foregroundStyle(foreground)
                    .multilineTextAlignment(.center)
                
                if isActive {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(foreground)
                            .frame(width: 8, height: 8)
                        Text("Currently Active", comment: "Badge for active model")
                            .font(.escherFootnote.weight(.semibold))
                            .foregroundStyle(foreground)
                    }
                }
            }
            
            // Badge Row
            if let entry = model.registryEntry {
                HStack(spacing: 8) {
                    GreyscaleBadge(text: entry.parameterCount, colorScheme: colorScheme)
                    GreyscaleBadge(text: entry.quantization, colorScheme: colorScheme, variant: .subtle)
                    GreyscaleBadge(text: entry.family.rawValue, colorScheme: colorScheme, variant: .subtle)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .escherCard()
    }
    
    // MARK: - Quick Stats Section
    
    private var quickStatsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("RUNTIME STATS", comment: "Section header for runtime statistics")
                .font(.escherCaption2)
                .tracking(1)
                .foregroundStyle(Color.escherSecondaryText)
            
            HStack(spacing: 0) {
                // Memory Usage
                GreyscaleQuickStatCard(
                    icon: "memorychip",
                    title: String(localized: "Memory"),
                    value: memoryValue,
                    colorScheme: colorScheme
                )
                
                Divider()
                    .frame(height: 40)
                    .padding(.horizontal, 8)
                
                // Context Size
                GreyscaleQuickStatCard(
                    icon: "text.alignleft",
                    title: String(localized: "Context"),
                    value: contextValue,
                    colorScheme: colorScheme
                )
                
                Divider()
                    .frame(height: 40)
                    .padding(.horizontal, 8)
                
                // File Size
                GreyscaleQuickStatCard(
                    icon: "internaldrive",
                    title: String(localized: "Disk"),
                    value: model.formattedSize,
                    colorScheme: colorScheme
                )
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(foreground.opacity(0.05))
            )
        }
        .padding(18)
        .escherCard()
    }
    
    private var memoryValue: String {
        if let info = activeModelInfo {
            return formatMemory(info.memoryUsage)
        } else if let entry = model.registryEntry {
            // Estimate: ~1.5x file size when loaded
            let estimated = Int64(Double(entry.sizeBytes) * 1.5)
            return "~\(formatMemory(estimated))"
        }
        return "—"
    }
    
    private var contextValue: String {
        if let info = activeModelInfo {
            return formatNumber(info.contextSize)
        } else if let entry = model.registryEntry {
            return formatNumber(entry.recommendedContextSize)
        }
        return "—"
    }
    
    // MARK: - Specs Section
    
    private var specsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SPECIFICATIONS", comment: "Section header for model specifications")
                .font(.escherCaption2)
                .tracking(1)
                .foregroundStyle(Color.escherSecondaryText)
            
            VStack(spacing: 0) {
                if let entry = model.registryEntry {
                    GreyscaleSpecRow(label: String(localized: "Parameters"), value: entry.parameterCount, colorScheme: colorScheme)
                    SpecDivider()
                    GreyscaleSpecRow(label: String(localized: "Quantization"), value: entry.quantization, colorScheme: colorScheme)
                    SpecDivider()
                    GreyscaleSpecRow(label: String(localized: "Model Family"), value: entry.family.rawValue, colorScheme: colorScheme)
                    SpecDivider()
                    GreyscaleSpecRow(label: String(localized: "Context Window"), value: "\(formatNumber(entry.recommendedContextSize)) \(String(localized: "tokens"))", colorScheme: colorScheme)
                    if !entry.isCustom, let pageURL = entry.huggingFacePageURL {
                        SpecDivider()
                        GreyscaleLinkSpecRow(label: String(localized: "Source"), value: String(localized: "Hugging Face"), url: pageURL, colorScheme: colorScheme)
                    }
                } else {
                    GreyscaleSpecRow(label: String(localized: "Format"), value: "GGUF", colorScheme: colorScheme)
                    SpecDivider()
                    GreyscaleSpecRow(label: String(localized: "Source"), value: String(localized: "Custom Import"), colorScheme: colorScheme)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(foreground.opacity(0.05))
            )
        }
        .padding(18)
        .escherCard()
    }
    
    // MARK: - File Info Section
    
    private var fileInfoSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("FILE INFORMATION", comment: "Section header for file information")
                .font(.escherCaption2)
                .tracking(1)
                .foregroundStyle(Color.escherSecondaryText)
            
            VStack(spacing: 0) {
                GreyscaleSpecRow(label: String(localized: "File Size"), value: model.formattedSize, colorScheme: colorScheme)
                SpecDivider()
                GreyscaleSpecRow(label: String(localized: "Downloaded"), value: formatDate(model.downloadedAt), colorScheme: colorScheme)
                SpecDivider()
                GreyscaleSpecRow(label: String(localized: "Model ID"), value: model.id, isMonospace: true, colorScheme: colorScheme)
                SpecDivider()
                GreyscaleSpecRow(label: String(localized: "Location"), value: model.path.lastPathComponent, isMonospace: true, colorScheme: colorScheme)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(foreground.opacity(0.05))
            )
        }
        .padding(18)
        .escherCard()
    }
    
    // MARK: - Actions Section
    
    private var actionsSection: some View {
        VStack(spacing: 12) {
            if !isActive {
                Button {
                    dismiss()
                    onLoad()
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Load Model", comment: "Button to load a model")
                    }
                    .font(.escherSubheadline)
                    .foregroundStyle(colorScheme == .dark ? Color.escherInk : Color.escherPaper)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(foreground)
                    )
                }
                .buttonStyle(.plain)
            }
            
            Button(role: .destructive) {
                dismiss()
                onDelete()
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("Delete Model", comment: "Button to delete a model")
                }
                .font(.escherSubheadline)
                .foregroundStyle(Color.escherError)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.escherError.opacity(0.1))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .escherCard()
    }
    
    // MARK: - Helpers
    
    private func formatMemory(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
    
    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Registry Model Detail View (Available for Download)

/// Detailed view for a model available for download from the registry.
struct RegistryModelDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: ModelRegistryEntry
    let onDownload: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    private var foreground: Color {
        colorScheme == .dark ? .escherPaper : .escherInk
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                EscherBackground()
                
                ScrollView {
                    VStack(spacing: 20) {
                        // Hero Section
                        heroSection
                        
                        // Description
                        descriptionSection
                        
                        // Specifications
                        specsSection
                        
                        // Estimated Usage
                        estimatedUsageSection
                        
                        // Download Action
                        actionSection
                    }
                    .padding(16)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Model Details", comment: "Navigation title")
                        .font(.escherHeadline)
                        .foregroundStyle(foreground)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Done")) {
                        dismiss()
                    }
                    .font(.escherCallout.weight(.semibold))
                    .foregroundStyle(foreground.opacity(0.7))
                }
            }
            .escherNavigationStyle()
        }
    }
    
    // MARK: - Hero Section
    
    private var heroSection: some View {
        VStack(spacing: 16) {
            // Model Provider Icon
            ModelProviderIcon(family: model.family, size: 80, colorScheme: colorScheme)
            
            VStack(spacing: 6) {
                Text(model.name)
                    .font(.escherTitle)
                    .foregroundStyle(foreground)
                    .multilineTextAlignment(.center)
                
                Text("Available for Download", comment: "Badge for downloadable model")
                    .font(.escherFootnote)
                    .foregroundStyle(Color.escherSecondaryText)
            }
            
            // Badge Row
            HStack(spacing: 8) {
                GreyscaleBadge(text: model.parameterCount, colorScheme: colorScheme)
                GreyscaleBadge(text: model.quantization, colorScheme: colorScheme, variant: .subtle)
                GreyscaleBadge(text: model.family.rawValue, colorScheme: colorScheme, variant: .subtle)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .escherCard()
    }
    
    // MARK: - Description Section
    
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ABOUT", comment: "Section header for model description")
                .font(.escherCaption2)
                .tracking(1)
                .foregroundStyle(Color.escherSecondaryText)
            
            Text(model.description)
                .font(.escherCallout.weight(.regular))
                .foregroundStyle(foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .escherCard()
    }
    
    // MARK: - Specs Section
    
    private var specsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SPECIFICATIONS")
                .font(.escherCaption2)
                .tracking(1)
                .foregroundStyle(Color.escherSecondaryText)
            
            VStack(spacing: 0) {
                GreyscaleSpecRow(label: String(localized: "Parameters"), value: model.parameterCount, colorScheme: colorScheme)
                SpecDivider()
                GreyscaleSpecRow(label: String(localized: "Quantization"), value: model.quantization, colorScheme: colorScheme)
                SpecDivider()
                GreyscaleSpecRow(label: String(localized: "Model Family"), value: model.family.rawValue, colorScheme: colorScheme)
                SpecDivider()
                GreyscaleSpecRow(label: String(localized: "Recommended Context"), value: "\(formatNumber(model.recommendedContextSize)) \(String(localized: "tokens"))", colorScheme: colorScheme)
                SpecDivider()
                GreyscaleSpecRow(label: String(localized: "Download Size"), value: model.formattedSize, colorScheme: colorScheme)
                if let pageURL = model.huggingFacePageURL {
                    SpecDivider()
                    GreyscaleLinkSpecRow(label: String(localized: "Source"), value: String(localized: "Hugging Face"), url: pageURL, colorScheme: colorScheme)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(foreground.opacity(0.05))
            )
        }
        .padding(18)
        .escherCard()
    }
    
    // MARK: - Estimated Usage Section
    
    private var estimatedUsageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ESTIMATED USAGE", comment: "Section header for usage estimates")
                .font(.escherCaption2)
                .tracking(1)
                .foregroundStyle(Color.escherSecondaryText)
            
            HStack(spacing: 0) {
                // Memory Estimate
                GreyscaleQuickStatCard(
                    icon: "memorychip",
                    title: String(localized: "RAM Required"),
                    value: estimatedMemory,
                    colorScheme: colorScheme
                )
                
                Divider()
                    .frame(height: 40)
                    .padding(.horizontal, 8)
                
                // Disk Space
                GreyscaleQuickStatCard(
                    icon: "internaldrive",
                    title: String(localized: "Disk Space"),
                    value: model.formattedSize,
                    colorScheme: colorScheme
                )
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(foreground.opacity(0.05))
            )
            
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.escherCaption)
                Text("Memory estimate is approximate. Actual usage depends on context length.", comment: "Disclaimer")
                    .font(.escherCaption)
            }
            .foregroundStyle(Color.escherSecondaryText)
        }
        .padding(18)
        .escherCard()
    }
    
    private var estimatedMemory: String {
        // Estimate: ~1.5x file size when loaded
        let estimated = Int64(Double(model.sizeBytes) * 1.5)
        return "~\(ByteCountFormatter.string(fromByteCount: estimated, countStyle: .memory))"
    }
    
    // MARK: - Action Section
    
    private var actionSection: some View {
        VStack(spacing: 12) {
            Button {
                dismiss()
                onDownload()
            } label: {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Download Model", comment: "Button to download a model")
                    Text("(\(model.formattedSize))")
                        .foregroundStyle(colorScheme == .dark ? Color.escherInk.opacity(0.7) : Color.escherPaper.opacity(0.7))
                }
                .font(.escherSubheadline)
                .foregroundStyle(colorScheme == .dark ? Color.escherInk : Color.escherPaper)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(foreground)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .escherCard()
    }
    
    // MARK: - Helpers
    
    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }
}

// MARK: - Greyscale Supporting Detail View Components

struct GreyscaleQuickStatCard: View {
    let icon: String
    let title: String
    let value: String
    let colorScheme: ColorScheme
    
    private var foreground: Color {
        colorScheme == .dark ? .escherPaper : .escherInk
    }
    
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.escherHeadline)
                .foregroundStyle(foreground.opacity(0.6))
            
            Text(value)
                .font(.escherSubheadline)
                .foregroundStyle(foreground)
            
            Text(title)
                .font(.escherCaption2)
                .foregroundStyle(Color.escherSecondaryText)
        }
        .frame(maxWidth: .infinity)
    }
}

struct GreyscaleSpecRow: View {
    let label: String
    let value: String
    var isMonospace: Bool = false
    var icon: String? = nil
    let colorScheme: ColorScheme
    
    private var foreground: Color {
        colorScheme == .dark ? .escherPaper : .escherInk
    }
    
    var body: some View {
        HStack {
            Text(label)
                .font(.escherFootnote)
                .foregroundStyle(Color.escherSecondaryText)
            
            Spacer()
            
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.escherCaption)
                        .foregroundStyle(foreground.opacity(0.6))
                }
                
                Text(value)
                    .font(isMonospace ? .escherMonoSmall : .escherFootnote.weight(.semibold))
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct SpecDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 14)
    }
}

/// A spec row that opens a URL when tapped.
struct GreyscaleLinkSpecRow: View {
    let label: String
    let value: String
    let url: URL?
    let colorScheme: ColorScheme
    
    @Environment(\.openURL) private var openURL
    
    private var foreground: Color {
        colorScheme == .dark ? .escherPaper : .escherInk
    }
    
    var body: some View {
        Button {
            if let url = url {
                openURL(url)
            }
        } label: {
            HStack {
                Text(label)
                    .font(.escherFootnote)
                    .foregroundStyle(Color.escherSecondaryText)
                
                Spacer()
                
                HStack(spacing: 4) {
                    Text(value)
                        .font(.escherFootnote.weight(.semibold))
                        .foregroundStyle(foreground)
                    
                    Image(systemName: "arrow.up.right")
                        .font(.escherCaption2)
                        .foregroundStyle(foreground.opacity(0.5))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .accessibilityLabel("\(label): \(value)")
        .accessibilityHint(url != nil ? String(localized: "Opens in browser") : "")
    }
}

// MARK: - Custom Model Input Sheet

/// Sheet for entering a custom Hugging Face model URL.
struct CustomModelInputSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    
    @Binding var url: String
    @Binding var contextSize: String
    let onSubmit: (String, Int) -> Void
    
    @State private var isValidURL = false
    @State private var parsedModelInfo: ModelRegistryEntry?
    
    private var foreground: Color {
        colorScheme == .dark ? .escherPaper : .escherInk
    }
    
    private var surface: Color {
        colorScheme == .dark ? Color(white: 0.14) : .escherPaper
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                EscherBackground()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Header
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Add Custom Model", comment: "Title for custom model sheet")
                                .font(.escherDisplay)
                                .foregroundStyle(foreground)
                            
                            Text("Enter a Hugging Face URL to download any GGUF model.", comment: "Instruction")
                                .font(.escherFootnote)
                                .foregroundStyle(Color.escherSecondaryText)
                        }
                        
                        // URL Input
                        VStack(alignment: .leading, spacing: 10) {
                            Text("HUGGING FACE URL", comment: "Label for URL input field")
                                .font(.escherCaption2)
                                .tracking(1)
                                .foregroundStyle(Color.escherSecondaryText)
                            
                            TextField("https://huggingface.co/...", text: $url)
                                .textFieldStyle(.plain)
                                .font(.escherMono)
                                .foregroundStyle(foreground)
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(surface)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(
                                            isValidURL ? foreground.opacity(0.3) : foreground.opacity(0.1),
                                            lineWidth: 1
                                        )
                                )
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .onChange(of: url) { _, newValue in
                                    validateURL(newValue)
                                }
                            
                            // Example URLs
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Example:", comment: "Label for example URL")
                                    .font(.escherCaption2.weight(.semibold))
                                    .foregroundStyle(Color.escherSecondaryText)
                                
                                Text("https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf")
                                    .font(.escherMonoMini)
                                    .foregroundStyle(Color.escherSecondaryText.opacity(0.85))
                                    .lineLimit(2)
                            }
                        }
                        
                        // Context Size
                        VStack(alignment: .leading, spacing: 10) {
                            Text("CONTEXT SIZE (TOKENS)", comment: "Label for context size selector")
                                .font(.escherCaption2)
                                .tracking(1)
                                .foregroundStyle(Color.escherSecondaryText)
                            
                            HStack(spacing: 10) {
                                ForEach(["2048", "4096", "8192"], id: \.self) { size in
                                    Button {
                                        contextSize = size
                                    } label: {
                                        Text(size)
                                            .font(.escherFootnote.weight(.semibold))
                                            .foregroundStyle(contextSize == size ? (colorScheme == .dark ? Color.escherInk : Color.escherPaper) : foreground)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 10)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .fill(contextSize == size ? foreground : surface)
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .strokeBorder(foreground.opacity(0.1), lineWidth: contextSize == size ? 0 : 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                                
                                Spacer()
                            }
                            
                            Text("Larger context uses more memory. Start with 4096 if unsure.", comment: "Help text")
                                .font(.escherCaption2)
                                .foregroundStyle(Color.escherSecondaryText)
                        }
                        
                        // Parsed model info preview
                        if let info = parsedModelInfo {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("DETECTED MODEL", comment: "Section header for detected model info")
                                    .font(.escherCaption2)
                                    .tracking(1)
                                    .foregroundStyle(Color.escherSecondaryText)
                                
                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(foreground.opacity(0.1))
                                            .frame(width: 44, height: 44)
                                        
                                        Image(systemName: "checkmark.circle")
                                            .font(.escherTitle)
                                            .foregroundStyle(foreground.opacity(0.7))
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(info.name)
                                            .font(.escherSubheadline)
                                            .foregroundStyle(foreground)
                                        
                                        HStack(spacing: 6) {
                                            GreyscaleBadge(text: info.parameterCount, colorScheme: colorScheme)
                                            GreyscaleBadge(text: info.quantization, colorScheme: colorScheme, variant: .subtle)
                                        }
                                    }
                                    
                                    Spacer()
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(surface)
                                )
                            }
                        }
                        
                        Spacer(minLength: 40)
                    }
                    .padding(20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        dismiss()
                    }
                    .foregroundStyle(Color.escherSecondaryText)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Download")) {
                        let ctx = Int(contextSize) ?? 4096
                        onSubmit(url, ctx)
                        dismiss()
                    }
                    .font(.escherSubheadline)
                    .foregroundStyle(isValidURL ? foreground : Color.escherSecondaryText)
                    .disabled(!isValidURL)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    
    private func validateURL(_ urlString: String) {
        parsedModelInfo = ModelRegistryEntry.fromHuggingFaceURL(urlString)
        isValidURL = parsedModelInfo != nil
    }
}

// MARK: - Compact Model Status View

/// A compact view showing current model status, suitable for toolbar or status bar.
struct ModelStatusView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var modelManager: ModelBackendManager
    
    private var foreground: Color {
        colorScheme == .dark ? .escherPaper : .escherInk
    }
    
    private var surface: Color {
        colorScheme == .dark ? Color(white: 0.18) : .escherPaper
    }
    
    var body: some View {
        HStack(spacing: 8) {
            statusIndicator
            
            VStack(alignment: .leading, spacing: 1) {
                if let info = modelManager.modelInfo {
                    Text(info.name)
                        .font(.escherCaption.weight(.semibold))
                        .foregroundStyle(foreground)
                        .lineLimit(1)
                } else {
                    Text("No model", comment: "Status when no model is loaded")
                        .font(.escherCaption)
                        .foregroundStyle(Color.escherSecondaryText)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(surface)
        )
        .overlay(
            Capsule()
                .strokeBorder(foreground.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .escherInk.opacity(0.12), radius: 8, x: 0, y: 4)
    }
    
    @ViewBuilder
    private var statusIndicator: some View {
        switch modelManager.state {
        case .ready:
            ZStack {
                Circle()
                    .fill(foreground.opacity(0.15))
                    .frame(width: 18, height: 18)
                
                PenroseTriangle()
                    .stroke(foreground, lineWidth: 1)
                    .frame(width: 8, height: 8)
            }
        case .generating:
            ProgressView()
                .scaleEffect(0.6)
        case .loading:
            ProgressView()
                .scaleEffect(0.6)
        case .error:
            Circle()
                .fill(Color.escherError)
                .frame(width: 8, height: 8)
        case .unloaded:
            Circle()
                .fill(foreground.opacity(0.3))
                .frame(width: 8, height: 8)
        }
    }
}

// MARK: - Model Status Compact View (for toolbar)

struct ModelStatusCompactView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var modelManager: ModelBackendManager
    
    private var foreground: Color {
        colorScheme == .dark ? .escherPaper : .escherInk
    }
    
    private var surface: Color {
        colorScheme == .dark ? Color(white: 0.18) : .escherPaper
    }
    
    var body: some View {
        ZStack {
            Circle()
                .fill(surface)
                .frame(width: 32, height: 32)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.06), radius: 4, x: 0, y: 2)
            
            statusIndicator
        }
    }
    
    @ViewBuilder
    private var statusIndicator: some View {
        switch modelManager.state {
        case .ready:
            ZStack {
                PenroseTriangle()
                    .stroke(foreground, lineWidth: 1.5)
                    .frame(width: 12, height: 12)
            }
        case .generating:
            ProgressView()
                .scaleEffect(0.5)
        case .loading:
            ProgressView()
                .scaleEffect(0.5)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.escherCaption.weight(.semibold))
                .foregroundStyle(Color.escherError)
        case .unloaded:
            Image(systemName: "cpu")
                .font(.escherCaption)
                .foregroundStyle(Color.escherSecondaryText)
        }
    }
}

// MARK: - Legacy Support (ModelBadge, StatItem, QuickStatCard, SpecRow for backwards compatibility)

struct ModelBadge: View {
    let text: String
    let color: Color
    
    var body: some View {
        Text(text)
            .font(.escherMini.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
    }
}

struct StatItem: View {
    let icon: String
    let value: String
    let label: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.escherCaption)
                .foregroundStyle(Color.escherSecondaryText)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.escherFootnote.weight(.bold))
                    .foregroundStyle(Color.escherInk)
                Text(label)
                    .font(.escherMini)
                    .foregroundStyle(Color.escherSecondaryText)
            }
        }
    }
}

struct QuickStatCard: View {
    let icon: String
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.escherHeadline)
                .foregroundStyle(color)
            
            Text(value)
                .font(.escherSubheadline)
                .foregroundStyle(Color.escherInk)
            
            Text(title)
                .font(.escherCaption2)
                .foregroundStyle(Color.escherSecondaryText)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SpecRow: View {
    let label: String
    let value: String
    var isMonospace: Bool = false
    var icon: String? = nil
    
    var body: some View {
        HStack {
            Text(label)
                .font(.escherFootnote)
                .foregroundStyle(Color.escherSecondaryText)
            
            Spacer()
            
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.escherCaption)
                        .foregroundStyle(Color.escherPrism)
                }
                
                Text(value)
                    .font(isMonospace ? .escherMonoSmall : .escherFootnote.weight(.semibold))
                    .foregroundStyle(Color.escherInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - Preview

#Preview("Model Management") {
    NavigationStack {
        ModelManagementView(modelManager: ModelBackendManager())
    }
}

#Preview("Model Status") {
    VStack {
        ModelStatusView(modelManager: ModelBackendManager())
    }
    .padding()
    .background(EscherBackground())
}

#Preview("Model Status Compact") {
    VStack(spacing: 20) {
        ModelStatusCompactView(modelManager: ModelBackendManager())
    }
    .padding()
    .background(EscherBackground())
}

#Preview("Installed Model Detail") {
    let sampleModel = InstalledModel(
        id: "qwen2.5-coder-1.5b-q4km",
        path: URL(filePath: "/Models/qwen2.5-coder-1.5b.gguf"),
        sizeBytes: 934_000_000,
        registryEntry: ModelRegistry.models[1],
        downloadedAt: Date()
    )
    
    ModelDetailView(
        model: sampleModel,
        isActive: true,
        activeModelInfo: ModelInfo(
            name: "Qwen2.5-Coder-1.5B",
            parameterCount: "1.5B",
            contextSize: 4096,
            memoryUsage: 1_400_000_000,
            quantization: "Q4_K_M"
        ),
        onLoad: {},
        onDelete: {}
    )
}

#Preview("Registry Model Detail") {
    RegistryModelDetailView(
        model: ModelRegistry.models[1],
        onDownload: {}
    )
}

#Preview("Model Family Accordion") {
    let qwenModels = ModelRegistry.models.filter { $0.family == .qwen25Coder }
    
    return ScrollView {
        VStack(spacing: 12) {
            ModelFamilyAccordion(
                family: .qwen25Coder,
                models: qwenModels,
                isExpanded: true,
                downloadProgress: [:],
                onToggle: {},
                onDownload: { _ in },
                onCancelDownload: { _ in }
            )
            
            ModelFamilyAccordion(
                family: .qwen3,
                models: ModelRegistry.models.filter { $0.family == .qwen3 },
                isExpanded: false,
                downloadProgress: [:],
                onToggle: {},
                onDownload: { _ in },
                onCancelDownload: { _ in }
            )
            
            ModelFamilyAccordion(
                family: .gemma3n,
                models: ModelRegistry.models.filter { $0.family == .gemma3n },
                isExpanded: false,
                downloadProgress: [:],
                onToggle: {},
                onDownload: { _ in },
                onCancelDownload: { _ in }
            )
        }
        .padding()
    }
    .background(EscherBackground())
}
