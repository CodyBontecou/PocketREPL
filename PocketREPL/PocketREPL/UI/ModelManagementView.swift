import SwiftUI

// MARK: - Model Management View

/// Main view for browsing, downloading, and managing local LLM models.
struct ModelManagementView: View {
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
    
    var body: some View {
        List {
            // Active Model Section
            activeModelSection
            
            // Storage Section
            storageSection
            
            // Installed Models Section
            installedModelsSection
            
            // Available Models Section
            availableModelsSection
        }
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.large)
        .refreshable {
            await refreshData()
        }
        .task {
            await refreshData()
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete Model",
            isPresented: $showingDeleteConfirmation,
            presenting: modelToDelete
        ) { model in
            Button("Delete \(model.name)", role: .destructive) {
                Task { await deleteModel(model) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text("This will remove \(model.formattedSize) from your device. This action cannot be undone.")
        }
        .overlay {
            if isLoading {
                loadingOverlay
            }
        }
    }
    
    // MARK: - Active Model Section
    
    @ViewBuilder
    private var activeModelSection: some View {
        Section {
            if let info = modelManager.modelInfo {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(info.name)
                                .font(.headline)
                            Text("\(info.parameterCount) • \(info.quantization ?? "Unknown")")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        modelStateIndicator
                    }
                    
                    HStack {
                        Label(formatMemory(info.memoryUsage), systemImage: "memorychip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Label("\(info.contextSize) tokens", systemImage: "text.alignleft")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                
                Button(role: .destructive) {
                    Task { await modelManager.unload(clearPersistence: true) }
                } label: {
                    Label("Unload Model", systemImage: "eject")
                }
            } else {
                ContentUnavailableView {
                    Label("No Model Loaded", systemImage: "cpu")
                } description: {
                    Text("Download and load a model to start coding with AI")
                }
            }
        } header: {
            Text("Active Model")
        }
    }
    
    @ViewBuilder
    private var modelStateIndicator: some View {
        switch modelManager.state {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .generating:
            ProgressView()
        case .loading(let progress):
            ProgressView(value: progress)
                .frame(width: 24)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .unloaded:
            EmptyView()
        }
    }
    
    // MARK: - Storage Section
    
    @ViewBuilder
    private var storageSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Models")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatBytes(storageInfo.used))
                        .fontWeight(.medium)
                }
                
                HStack {
                    Text("Available")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatBytes(storageInfo.available))
                        .fontWeight(.medium)
                        .foregroundStyle(storageInfo.available < 1_000_000_000 ? .red : .primary)
                }
                
                // Storage bar
                GeometryReader { geo in
                    let totalWidth = geo.size.width
                    let usedRatio = min(1.0, Double(storageInfo.used) / Double(storageInfo.used + storageInfo.available))
                    
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                            .frame(height: 8)
                        
                        Capsule()
                            .fill(.blue)
                            .frame(width: totalWidth * usedRatio, height: 8)
                    }
                }
                .frame(height: 8)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Storage")
        }
    }
    
    // MARK: - Installed Models Section
    
    @ViewBuilder
    private var installedModelsSection: some View {
        Section {
            if installedModels.isEmpty {
                Text("No models installed")
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                ForEach(installedModels) { model in
                    InstalledModelRow(
                        model: model,
                        isActive: modelManager.modelInfo?.name == model.name,
                        onLoad: { Task { await loadModel(model) } },
                        onDelete: {
                            modelToDelete = model
                            showingDeleteConfirmation = true
                        }
                    )
                }
            }
        } header: {
            HStack {
                Text("Installed")
                Spacer()
                Text("\(installedModels.count) model\(installedModels.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Available Models Section
    
    @ViewBuilder
    private var availableModelsSection: some View {
        Section {
            ForEach(availableModels) { model in
                if let progress = downloadProgress[model.id] {
                    DownloadProgressRow(
                        model: model,
                        progress: progress,
                        onCancel: { Task { await cancelDownload(model.id) } }
                    )
                } else {
                    DownloadableModelRow(model: model) {
                        Task { await downloadModel(model) }
                    }
                }
            }
        } header: {
            Text("Available for Download")
        } footer: {
            Text("Models are downloaded from Hugging Face and stored locally on your device.")
        }
    }
    
    // Available models = registry models not yet installed
    private var availableModels: [ModelRegistryEntry] {
        let installedIds = Set(installedModels.map { $0.id })
        return ModelRegistry.models.filter { !installedIds.contains($0.id) }
    }
    
    // MARK: - Loading Overlay
    
    @ViewBuilder
    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                Text("Loading model...")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(32)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
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
        guard let entry = model.registryEntry else {
            errorMessage = "Cannot load unknown model format"
            return
        }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            let config = ModelConfiguration(
                modelPath: model.path.path,
                contextSize: entry.recommendedContextSize,
                gpuLayers: 99, // Max GPU layers for device
                threadCount: 4
            )
            
            // Register LlamaBackend if needed
            let backend = LlamaBackend()
            await modelManager.setBackend(backend)
            try await modelManager.load(configuration: config, modelId: model.id, persistSelection: true)
            
        } catch {
            errorMessage = "Failed to load model: \(error.localizedDescription)"
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
            
            // Success - refresh list
            await refreshData()
            
        } catch {
            if (error as? ModelError) != .cancelled {
                errorMessage = "Download failed: \(error.localizedDescription)"
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
        // Unload if active
        if modelManager.modelInfo?.name == model.name {
            await modelManager.unload()
        }
        
        do {
            try await downloadManager.deleteModel(id: model.id)
            await refreshData()
        } catch {
            errorMessage = "Failed to delete model: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Formatting Helpers
    
    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    
    private func formatMemory(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}

// MARK: - Supporting Views

/// Row displaying an installed model with load/delete actions.
struct InstalledModelRow: View {
    let model: InstalledModel
    let isActive: Bool
    let onLoad: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.name)
                        .font(.headline)
                    if isActive {
                        Text("ACTIVE")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.2))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }
                
                HStack(spacing: 12) {
                    if let entry = model.registryEntry {
                        Text(entry.parameterCount)
                        Text(entry.quantization)
                    }
                    Text(model.formattedSize)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if !isActive {
                Button {
                    onLoad()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

/// Row displaying a downloadable model from the registry.
struct DownloadableModelRow: View {
    let model: ModelRegistryEntry
    let onDownload: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.name)
                        .font(.headline)
                    
                    if model.id == ModelRegistry.models.first(where: { $0.description.contains("Recommended") })?.id {
                        Text("RECOMMENDED")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.2))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }
                
                Text(model.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                
                HStack(spacing: 12) {
                    Label(model.parameterCount, systemImage: "cpu")
                    Label(model.quantization, systemImage: "square.grid.3x3")
                    Label(model.formattedSize, systemImage: "arrow.down.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button {
                onDownload()
            } label: {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.title2)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

/// Row showing download progress with cancel button.
struct DownloadProgressRow: View {
    let model: ModelRegistryEntry
    let progress: DownloadProgress
    let onCancel: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.name)
                    .font(.headline)
                Spacer()
                Button("Cancel", role: .destructive) {
                    onCancel()
                }
                .font(.subheadline)
            }
            
            ProgressView(value: progress.progress)
                .tint(.blue)
            
            HStack {
                Text(progress.formattedProgress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                if let eta = progress.estimatedTimeRemaining {
                    Text("~\(formatDuration(eta)) remaining")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(progress.percentComplete)%")
                        .font(.caption)
                        .fontWeight(.medium)
                }
            }
        }
        .padding(.vertical, 4)
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

// MARK: - Compact Model Status View

/// A compact view showing current model status, suitable for toolbar or status bar.
struct ModelStatusView: View {
    @ObservedObject var modelManager: ModelBackendManager
    
    var body: some View {
        HStack(spacing: 6) {
            statusIcon
            
            if let info = modelManager.modelInfo {
                Text(info.name)
                    .font(.caption)
                    .lineLimit(1)
            } else {
                Text("No model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch modelManager.state {
        case .ready:
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
        case .generating:
            ProgressView()
                .scaleEffect(0.6)
        case .loading:
            ProgressView()
                .scaleEffect(0.6)
        case .error:
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
        case .unloaded:
            Circle()
                .fill(.gray)
                .frame(width: 8, height: 8)
        }
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
}
