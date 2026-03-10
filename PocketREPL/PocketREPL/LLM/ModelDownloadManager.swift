import Foundation
import CryptoKit

// MARK: - Model Registry

/// A downloadable model from a remote source.
struct ModelRegistryEntry: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let sizeBytes: Int64
    let downloadURL: URL
    let sha256: String?
    let quantization: String
    let parameterCount: String
    let recommendedContextSize: Int
    let family: ModelFamily
    
    enum ModelFamily: String, Codable, Sendable {
        case qwen = "Qwen"
        case codegemma = "CodeGemma"
        case starcoder = "StarCoder"
        case deepseek = "DeepSeek"
        case other = "Other"
    }
    
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// Built-in model registry with recommended models for code generation.
enum ModelRegistry {
    /// Recommended models for PocketREPL, sorted by size (smallest first).
    static let models: [ModelRegistryEntry] = [
        // Qwen2.5-Coder family - excellent code generation
        ModelRegistryEntry(
            id: "qwen2.5-coder-0.5b-q4km",
            name: "Qwen2.5-Coder-0.5B",
            description: "Tiny but capable. Fast inference, good for simple tasks.",
            sizeBytes: 400_000_000,
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-0.5b-instruct-q4_k_m.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "0.5B",
            recommendedContextSize: 4096,
            family: .qwen
        ),
        ModelRegistryEntry(
            id: "qwen2.5-coder-1.5b-q4km",
            name: "Qwen2.5-Coder-1.5B",
            description: "Best balance of quality and speed. Recommended for most users.",
            sizeBytes: 934_000_000,
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "1.5B",
            recommendedContextSize: 4096,
            family: .qwen
        ),
        ModelRegistryEntry(
            id: "qwen2.5-coder-3b-q4km",
            name: "Qwen2.5-Coder-3B",
            description: "Higher quality code generation. Requires more memory.",
            sizeBytes: 1_800_000_000,
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-Coder-3B-Instruct-GGUF/resolve/main/qwen2.5-coder-3b-instruct-q4_k_m.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "3B",
            recommendedContextSize: 4096,
            family: .qwen
        ),
        // DeepSeek Coder - alternative family
        ModelRegistryEntry(
            id: "deepseek-coder-1.3b-q4km",
            name: "DeepSeek Coder 1.3B",
            description: "Strong code understanding. Good alternative to Qwen.",
            sizeBytes: 820_000_000,
            downloadURL: URL(string: "https://huggingface.co/TheBloke/deepseek-coder-1.3b-instruct-GGUF/resolve/main/deepseek-coder-1.3b-instruct.Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "1.3B",
            recommendedContextSize: 4096,
            family: .deepseek
        ),
    ]
    
    /// Get the recommended model for the device.
    static func recommendedModel(availableMemoryMB: Int) -> ModelRegistryEntry {
        // Leave ~2GB headroom for app and system
        let usableMemoryMB = availableMemoryMB - 2048
        let usableMemoryBytes = Int64(usableMemoryMB) * 1024 * 1024
        
        // Find the largest model that fits (models are sorted smallest-first)
        for model in models.reversed() {
            // Model typically needs ~1.5x file size in RAM
            let estimatedRAM = Int64(Double(model.sizeBytes) * 1.5)
            if estimatedRAM <= usableMemoryBytes {
                return model
            }
        }
        
        // Fall back to smallest model
        return models[0]
    }
    
    /// Find a model by ID.
    static func model(withId id: String) -> ModelRegistryEntry? {
        models.first { $0.id == id }
    }
}

// MARK: - Installed Model

/// A model that has been downloaded to local storage.
struct InstalledModel: Identifiable, Sendable {
    let id: String
    let path: URL
    let sizeBytes: Int64
    let registryEntry: ModelRegistryEntry?
    let downloadedAt: Date
    
    var name: String {
        registryEntry?.name ?? path.deletingPathExtension().lastPathComponent
    }
    
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

// MARK: - Download State

/// The state of a model download.
enum DownloadState: Sendable, Equatable {
    case idle
    case downloading(progress: Double, bytesDownloaded: Int64, totalBytes: Int64)
    case verifying
    case completed(URL)
    case failed(String)
    case cancelled
    
    var isActive: Bool {
        switch self {
        case .downloading, .verifying:
            return true
        default:
            return false
        }
    }
    
    var progress: Double {
        switch self {
        case .downloading(let progress, _, _):
            return progress
        case .completed:
            return 1.0
        default:
            return 0.0
        }
    }
}

// MARK: - Download Progress

/// Progress information for an active download.
struct DownloadProgress: Sendable {
    let modelId: String
    let progress: Double
    let bytesDownloaded: Int64
    let totalBytes: Int64
    let estimatedTimeRemaining: TimeInterval?
    
    var formattedProgress: String {
        let downloaded = ByteCountFormatter.string(fromByteCount: bytesDownloaded, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(downloaded) / \(total)"
    }
    
    var percentComplete: Int {
        Int(progress * 100)
    }
}

// MARK: - Model Download Manager

/// Manages downloading, storing, and deleting GGUF model files.
actor ModelDownloadManager {
    
    // MARK: - Properties
    
    /// Active download tasks keyed by model ID.
    private var activeDownloads: [String: DownloadTask] = [:]
    
    /// Download session configured for background transfers.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600 * 4 // 4 hours max for large models
        config.allowsCellularAccess = true // User can control via system settings
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }()
    
    /// Directory where models are stored.
    var modelsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let modelsDir = docs.appendingPathComponent("Models", isDirectory: true)
        
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        
        return modelsDir
    }
    
    // MARK: - Download Task Wrapper
    
    private struct DownloadTask {
        let modelId: String
        let task: URLSessionDownloadTask
        var progress: Double = 0
        var bytesDownloaded: Int64 = 0
        var totalBytes: Int64 = 0
        var startTime: Date = Date()
        var continuation: AsyncThrowingStream<DownloadProgress, Error>.Continuation?
    }
    
    // MARK: - Download Methods
    
    /// Download a model from the registry.
    /// - Parameters:
    ///   - model: The model registry entry to download.
    ///   - onProgress: Progress callback (0.0 to 1.0).
    /// - Returns: URL to the downloaded model file.
    func download(
        model: ModelRegistryEntry,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        // Check if already downloaded
        let destination = modelsDirectory.appendingPathComponent("\(model.id).gguf")
        if FileManager.default.fileExists(atPath: destination.path) {
            // Verify file size matches expected
            let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path)
            let fileSize = attrs?[.size] as? Int64 ?? 0
            
            // Allow some tolerance for size (within 10%)
            let sizeDiff = abs(fileSize - model.sizeBytes)
            if sizeDiff < model.sizeBytes / 10 {
                return destination
            }
            
            // Size mismatch - delete and re-download
            try? FileManager.default.removeItem(at: destination)
        }
        
        // Check if download already in progress
        if activeDownloads[model.id] != nil {
            throw ModelError.invalidConfiguration(reason: "Download already in progress for \(model.name)")
        }
        
        // Check available storage
        let availableSpace = availableStorage()
        if availableSpace < model.sizeBytes + 100_000_000 { // 100MB buffer
            throw ModelError.invalidConfiguration(
                reason: "Insufficient storage. Need \(model.formattedSize) but only \(ByteCountFormatter.string(fromByteCount: availableSpace, countStyle: .file)) available."
            )
        }
        
        // Create download request
        var request = URLRequest(url: model.downloadURL)
        request.setValue("PocketREPL/1.0", forHTTPHeaderField: "User-Agent")
        
        // Check for partial download to resume
        let partialPath = destination.appendingPathExtension("partial")
        var resumeData: Data?
        if FileManager.default.fileExists(atPath: partialPath.path) {
            resumeData = try? Data(contentsOf: partialPath)
        }
        
        // Create download task
        let task: URLSessionDownloadTask
        if let resumeData = resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: request)
        }
        
        var downloadTask = DownloadTask(modelId: model.id, task: task)
        downloadTask.totalBytes = model.sizeBytes
        activeDownloads[model.id] = downloadTask
        
        // Start download with progress observation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    do {
                        let result = try await self.performDownload(
                            task: task,
                            model: model,
                            destination: destination,
                            partialPath: partialPath,
                            onProgress: onProgress
                        )
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelDownload(modelId: model.id) }
        }
    }
    
    private func performDownload(
        task: URLSessionDownloadTask,
        model: ModelRegistryEntry,
        destination: URL,
        partialPath: URL,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        
        // Create progress observation
        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @Sendable [weak self] in
                guard let self = self else { return }
                let progressInfo = await self.updateProgress(
                    modelId: model.id,
                    progress: progress.fractionCompleted,
                    bytesDownloaded: task.countOfBytesReceived,
                    totalBytes: task.countOfBytesExpectedToReceive > 0 
                        ? task.countOfBytesExpectedToReceive 
                        : model.sizeBytes
                )
                if let progressInfo = progressInfo {
                    onProgress(progressInfo)
                }
            }
        }
        
        defer {
            observation.invalidate()
            Task { await self.removeDownload(modelId: model.id) }
        }
        
        task.resume()
        
        // Wait for completion
        let (tempURL, response) = try await session.download(from: model.downloadURL)
        
        // Verify response
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ModelError.loadFailed(reason: "Download failed with status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        
        // Clean up partial file
        try? FileManager.default.removeItem(at: partialPath)
        
        // Move to final destination
        try? FileManager.default.removeItem(at: destination) // Remove any existing file
        try FileManager.default.moveItem(at: tempURL, to: destination)
        
        // Verify hash if provided
        if let expectedHash = model.sha256 {
            let actualHash = try computeSHA256(of: destination)
            if actualHash.lowercased() != expectedHash.lowercased() {
                try? FileManager.default.removeItem(at: destination)
                throw ModelError.loadFailed(reason: "Hash verification failed")
            }
        }
        
        // Record download metadata
        try saveModelMetadata(model: model, path: destination)
        
        return destination
    }
    
    private func updateProgress(
        modelId: String,
        progress: Double,
        bytesDownloaded: Int64,
        totalBytes: Int64
    ) -> DownloadProgress? {
        guard var task = activeDownloads[modelId] else { return nil }
        
        task.progress = progress
        task.bytesDownloaded = bytesDownloaded
        task.totalBytes = totalBytes
        activeDownloads[modelId] = task
        
        let elapsed = Date().timeIntervalSince(task.startTime)
        let bytesPerSecond = elapsed > 0 ? Double(bytesDownloaded) / elapsed : 0
        let remainingBytes = totalBytes - bytesDownloaded
        let estimatedRemaining = bytesPerSecond > 0 ? TimeInterval(Double(remainingBytes) / bytesPerSecond) : nil
        
        return DownloadProgress(
            modelId: modelId,
            progress: progress,
            bytesDownloaded: bytesDownloaded,
            totalBytes: totalBytes,
            estimatedTimeRemaining: estimatedRemaining
        )
    }
    
    private func removeDownload(modelId: String) {
        activeDownloads.removeValue(forKey: modelId)
    }
    
    /// Cancel an active download.
    func cancelDownload(modelId: String) {
        guard let task = activeDownloads[modelId] else { return }
        
        // Save resume data for later
        task.task.cancel { resumeData in
            if let resumeData = resumeData {
                let partialPath = self.modelsDirectory
                    .appendingPathComponent("\(modelId).gguf")
                    .appendingPathExtension("partial")
                try? resumeData.write(to: partialPath)
            }
        }
        
        activeDownloads.removeValue(forKey: modelId)
    }
    
    /// Get the state of a download.
    func downloadState(for modelId: String) -> DownloadState {
        if let task = activeDownloads[modelId] {
            return .downloading(
                progress: task.progress,
                bytesDownloaded: task.bytesDownloaded,
                totalBytes: task.totalBytes
            )
        }
        
        let path = modelsDirectory.appendingPathComponent("\(modelId).gguf")
        if FileManager.default.fileExists(atPath: path.path) {
            return .completed(path)
        }
        
        return .idle
    }
    
    // MARK: - Storage Management
    
    /// List all installed models.
    func installedModels() -> [InstalledModel] {
        let fm = FileManager.default
        
        guard let contents = try? fm.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        return contents.compactMap { url -> InstalledModel? in
            guard url.pathExtension == "gguf" else { return nil }
            
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let created = values?.creationDate ?? Date()
            
            // Try to match to registry
            let id = url.deletingPathExtension().lastPathComponent
            let registryEntry = ModelRegistry.model(withId: id)
            
            return InstalledModel(
                id: id,
                path: url,
                sizeBytes: size,
                registryEntry: registryEntry,
                downloadedAt: created
            )
        }.sorted { $0.downloadedAt > $1.downloadedAt }
    }
    
    /// Delete an installed model.
    func deleteModel(id: String) throws {
        let path = modelsDirectory.appendingPathComponent("\(id).gguf")
        
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ModelError.modelNotFound(path: path.path)
        }
        
        try FileManager.default.removeItem(at: path)
        
        // Also delete metadata
        let metadataPath = path.appendingPathExtension("meta.json")
        try? FileManager.default.removeItem(at: metadataPath)
    }
    
    /// Delete all installed models.
    func deleteAllModels() throws {
        for model in installedModels() {
            try? deleteModel(id: model.id)
        }
    }
    
    /// Total storage used by installed models.
    func totalStorageUsed() -> Int64 {
        installedModels().reduce(0) { $0 + $1.sizeBytes }
    }
    
    /// Available storage on device.
    func availableStorage() -> Int64 {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        guard let path = paths.first else { return 0 }
        
        do {
            let values = try path.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage ?? 0
        } catch {
            return 0
        }
    }
    
    /// Check if a model is installed.
    func isModelInstalled(id: String) -> Bool {
        let path = modelsDirectory.appendingPathComponent("\(id).gguf")
        return FileManager.default.fileExists(atPath: path.path)
    }
    
    /// Get the path for an installed model.
    func modelPath(for id: String) -> URL? {
        let path = modelsDirectory.appendingPathComponent("\(id).gguf")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }
    
    // MARK: - Verification
    
    /// Compute SHA256 hash of a file.
    private func computeSHA256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        
        var hasher = SHA256()
        
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1024 * 1024) // 1MB chunks
            if chunk.isEmpty {
                return false
            }
            hasher.update(data: chunk)
            return true
        }) {}
        
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Verify model integrity.
    func verifyModel(at url: URL, expectedHash: String?) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        
        // If no hash provided, just check file exists and is non-empty
        guard let expectedHash = expectedHash else {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = attrs?[.size] as? Int64 ?? 0
            return size > 0
        }
        
        // Verify hash
        guard let actualHash = try? computeSHA256(of: url) else {
            return false
        }
        
        return actualHash.lowercased() == expectedHash.lowercased()
    }
    
    // MARK: - Metadata
    
    private struct ModelMetadata: Codable {
        let id: String
        let name: String
        let downloadedAt: Date
        let sizeBytes: Int64
        let parameterCount: String
        let quantization: String
    }
    
    private func saveModelMetadata(model: ModelRegistryEntry, path: URL) throws {
        let metadata = ModelMetadata(
            id: model.id,
            name: model.name,
            downloadedAt: Date(),
            sizeBytes: model.sizeBytes,
            parameterCount: model.parameterCount,
            quantization: model.quantization
        )
        
        let metadataPath = path.appendingPathExtension("meta.json")
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataPath)
    }
}

// MARK: - Convenience Extensions

extension ModelDownloadManager {
    /// Download the recommended model for this device.
    func downloadRecommendedModel(
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        let availableMemoryMB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        let recommended = ModelRegistry.recommendedModel(availableMemoryMB: availableMemoryMB)
        return try await download(model: recommended, onProgress: onProgress)
    }
    
    /// Get the first installed model, or nil if none installed.
    func firstInstalledModel() -> InstalledModel? {
        installedModels().first
    }
}
