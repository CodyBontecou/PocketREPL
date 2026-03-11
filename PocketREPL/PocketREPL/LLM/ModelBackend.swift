import Combine
import Foundation

// MARK: - Model Lifecycle

/// The lifecycle state of a local model.
nonisolated enum ModelState: Sendable, Equatable {
    /// Model is not loaded into memory.
    case unloaded
    
    /// Model is being loaded (downloading weights, initializing).
    case loading(progress: Double)
    
    /// Model is ready for inference.
    case ready
    
    /// Model failed to load or encountered an error.
    case error(ModelError)
    
    /// Model is currently generating a response.
    case generating
    
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
    
    var isGenerating: Bool {
        if case .generating = self { return true }
        return false
    }
    
    var canGenerate: Bool {
        isReady || isGenerating
    }
}

/// Errors that can occur during model operations.
nonisolated enum ModelError: Error, Sendable, Equatable {
    case modelNotFound(path: String)
    case insufficientMemory(required: Int64, available: Int64)
    case loadFailed(reason: String)
    case inferenceError(reason: String)
    case cancelled
    case contextOverflow(tokens: Int, maxTokens: Int)
    case invalidConfiguration(reason: String)
}

extension ModelError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "Model not found at path: \(path)"
        case .insufficientMemory(let required, let available):
            let reqMB = required / (1024 * 1024)
            let availMB = available / (1024 * 1024)
            return "Insufficient memory: requires \(reqMB)MB, available \(availMB)MB"
        case .loadFailed(let reason):
            return "Failed to load model: \(reason)"
        case .inferenceError(let reason):
            return "Inference error: \(reason)"
        case .cancelled:
            return "Generation was cancelled"
        case .contextOverflow(let tokens, let maxTokens):
            return "Context overflow: \(tokens) tokens exceeds limit of \(maxTokens)"
        case .invalidConfiguration(let reason):
            return "Invalid configuration: \(reason)"
        }
    }
}

// MARK: - Generation Request

/// A request for code generation or completion.
nonisolated struct GenerationRequest: Sendable {
    /// The type of generation task.
    nonisolated enum TaskKind: Sendable {
        /// Generate new code from a natural language description.
        case generate
        
        /// Fix/rewrite existing code based on an error.
        case fix
        
        /// Complete partial code.
        case complete
        
        /// Explain existing code.
        case explain
    }
    
    /// The task being requested.
    let task: TaskKind
    
    /// The user's prompt or instruction.
    let prompt: String
    
    /// Existing code to operate on (for fix/complete/explain tasks).
    let existingCode: String?
    
    /// Error message when fixing code.
    let errorMessage: String?
    
    /// File path context (for module resolution hints).
    let filePath: String?
    
    /// Additional context (file manifest, recent activity, etc.).
    let context: String?
    
    /// Maximum tokens to generate.
    let maxTokens: Int
    
    /// Temperature for sampling (0.0 = deterministic, 1.0 = creative).
    let temperature: Float
    
    /// Stop sequences to end generation.
    let stopSequences: [String]
    
    init(
        task: TaskKind,
        prompt: String,
        existingCode: String? = nil,
        errorMessage: String? = nil,
        filePath: String? = nil,
        context: String? = nil,
        maxTokens: Int = 2048,
        temperature: Float = 0.2,
        stopSequences: [String] = []
    ) {
        self.task = task
        self.prompt = prompt
        self.existingCode = existingCode
        self.errorMessage = errorMessage
        self.filePath = filePath
        self.context = context
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.stopSequences = stopSequences
    }
    
    /// Create a generation request for writing new code.
    static func generate(
        prompt: String,
        context: String? = nil,
        filePath: String? = nil,
        maxTokens: Int = 2048
    ) -> GenerationRequest {
        GenerationRequest(
            task: .generate,
            prompt: prompt,
            filePath: filePath,
            context: context,
            maxTokens: maxTokens
        )
    }
    
    /// Create a request to fix broken code.
    static func fix(
        code: String,
        error: String,
        context: String? = nil,
        filePath: String? = nil,
        maxTokens: Int = 2048
    ) -> GenerationRequest {
        GenerationRequest(
            task: .fix,
            prompt: "Fix this code",
            existingCode: code,
            errorMessage: error,
            filePath: filePath,
            context: context,
            maxTokens: maxTokens
        )
    }
    
    /// Create a request to complete partial code.
    static func complete(
        code: String,
        context: String? = nil,
        filePath: String? = nil,
        maxTokens: Int = 512
    ) -> GenerationRequest {
        GenerationRequest(
            task: .complete,
            prompt: "Complete this code",
            existingCode: code,
            filePath: filePath,
            context: context,
            maxTokens: maxTokens,
            temperature: 0.1 // Lower temperature for completions
        )
    }
}

// MARK: - Generation Response

/// The result of a generation request.
nonisolated struct GenerationResponse: Sendable {
    /// The generated text (code, explanation, etc.).
    let text: String
    
    /// Number of tokens in the prompt.
    let promptTokens: Int
    
    /// Number of tokens generated.
    let completionTokens: Int
    
    /// Generation time in seconds.
    let durationSeconds: Double
    
    /// Whether generation was stopped early (by stop sequence or max tokens).
    let finishReason: FinishReason
    
    nonisolated enum FinishReason: Sendable {
        case complete
        case maxTokens
        case stopSequence
        case cancelled
        case error(String)
    }
    
    var totalTokens: Int { promptTokens + completionTokens }
    
    var tokensPerSecond: Double {
        guard durationSeconds > 0 else { return 0 }
        return Double(completionTokens) / durationSeconds
    }
}

// MARK: - Streaming Generation

/// A token emitted during streaming generation.
nonisolated struct GenerationToken: Sendable {
    let text: String
    let tokenIndex: Int
    let isLast: Bool
}

/// An async sequence of generated tokens for streaming output.
struct StreamedGeneration: AsyncSequence, Sendable {
    typealias Element = GenerationToken
    
    private let stream: AsyncThrowingStream<GenerationToken, Error>
    
    init(_ stream: AsyncThrowingStream<GenerationToken, Error>) {
        self.stream = stream
    }
    
    func makeAsyncIterator() -> AsyncThrowingStream<GenerationToken, Error>.AsyncIterator {
        stream.makeAsyncIterator()
    }
}

// MARK: - Model Configuration

/// Configuration for a local model.
nonisolated struct ModelConfiguration: Sendable {
    /// Path to the model weights file (GGUF, etc.).
    let modelPath: String
    
    /// Maximum context window size in tokens.
    let contextSize: Int
    
    /// Number of layers to offload to GPU (0 = CPU only).
    let gpuLayers: Int
    
    /// Number of threads for CPU inference.
    let threadCount: Int
    
    /// Whether to use memory mapping for model weights.
    let useMemoryMapping: Bool
    
    /// Batch size for prompt processing.
    let batchSize: Int
    
    init(
        modelPath: String,
        contextSize: Int = 4096,
        gpuLayers: Int = 0,
        threadCount: Int = 4,
        useMemoryMapping: Bool = true,
        batchSize: Int = 512
    ) {
        self.modelPath = modelPath
        self.contextSize = contextSize
        self.gpuLayers = gpuLayers
        self.threadCount = threadCount
        self.useMemoryMapping = useMemoryMapping
        self.batchSize = batchSize
    }
}

/// Runtime information about a loaded model.
nonisolated struct ModelInfo: Sendable {
    /// Human-readable model name.
    let name: String
    
    /// Model parameter count (e.g., "1.5B", "7B").
    let parameterCount: String
    
    /// Context window size in tokens.
    let contextSize: Int
    
    /// Memory usage in bytes.
    let memoryUsage: Int64
    
    /// Quantization format (e.g., "Q4_K_M", "Q8_0").
    let quantization: String?
}

// MARK: - Model Backend Protocol

/// Protocol for local model backends (llama.cpp, MLX, etc.).
/// Implementations must be thread-safe.
protocol ModelBackend: Actor {
    /// Current state of the model.
    var state: ModelState { get }
    
    /// Information about the loaded model (nil if not loaded).
    var modelInfo: ModelInfo? { get }
    
    /// Current number of tokens used in the context window.
    var currentContextTokens: Int { get }
    
    /// Maximum context size (tokens).
    var maxContextTokens: Int { get }
    
    /// Load the model into memory.
    /// - Parameter configuration: Model configuration including path and inference settings.
    /// - Throws: `ModelError` if loading fails.
    func load(configuration: ModelConfiguration) async throws
    
    /// Unload the model from memory.
    func unload() async
    
    /// Generate a response for the given request.
    /// - Parameter request: The generation request.
    /// - Returns: The generation response.
    /// - Throws: `ModelError` if generation fails.
    func generate(request: GenerationRequest) async throws -> GenerationResponse
    
    /// Generate a streaming response for the given request.
    /// - Parameter request: The generation request.
    /// - Returns: An async sequence of tokens.
    func generateStreaming(request: GenerationRequest) async throws -> StreamedGeneration
    
    /// Cancel any ongoing generation.
    func cancel() async
    
    /// Estimate tokens for the given text.
    /// - Parameter text: Text to tokenize.
    /// - Returns: Estimated token count.
    nonisolated func estimateTokens(for text: String) -> Int
}

// MARK: - Model Persistence

/// Handles saving and restoring the last loaded model.
enum ModelPersistence {
    private static let lastModelIdKey = "LastLoadedModelId"
    
    /// Save the ID of the last loaded model.
    static func saveLastModelId(_ modelId: String) {
        UserDefaults.standard.set(modelId, forKey: lastModelIdKey)
    }
    
    /// Get the ID of the last loaded model, if any.
    static func lastModelId() -> String? {
        UserDefaults.standard.string(forKey: lastModelIdKey)
    }
    
    /// Clear the saved model ID.
    static func clearLastModelId() {
        UserDefaults.standard.removeObject(forKey: lastModelIdKey)
    }
}

// MARK: - Model Backend Manager

/// Manages model backends and provides a unified interface.
@MainActor
final class ModelBackendManager: ObservableObject {
    @Published private(set) var state: ModelState = .unloaded
    @Published private(set) var modelInfo: ModelInfo?
    
    /// The ID of the currently loaded model, if any.
    private(set) var loadedModelId: String?
    
    private var backend: (any ModelBackend)?
    
    // MARK: - Context Tracking
    
    /// Current number of tokens used in the context window.
    var currentContextTokens: Int {
        get async {
            await backend?.currentContextTokens ?? 0
        }
    }
    
    /// Maximum context size (tokens).
    var maxContextTokens: Int {
        get async {
            await backend?.maxContextTokens ?? 0
        }
    }
    
    /// Register a backend implementation.
    func setBackend(_ backend: any ModelBackend) async {
        self.backend = backend
        self.state = await backend.state
        self.modelInfo = await backend.modelInfo
    }
    
    /// Load a model with the given configuration.
    /// - Parameters:
    ///   - configuration: The model configuration.
    ///   - modelId: Optional model ID to track which model is loaded.
    ///   - persistSelection: If true, saves this model as the last loaded model.
    func load(configuration: ModelConfiguration, modelId: String? = nil, persistSelection: Bool = true) async throws {
        guard let backend = backend else {
            throw ModelError.invalidConfiguration(reason: "No backend registered")
        }
        
        state = .loading(progress: 0)
        
        do {
            try await backend.load(configuration: configuration)
            state = await backend.state
            modelInfo = await backend.modelInfo
            loadedModelId = modelId
            
            // Persist the loaded model ID for auto-load on next launch
            if persistSelection, let modelId = modelId {
                ModelPersistence.saveLastModelId(modelId)
            }
        } catch let error as ModelError {
            state = .error(error)
            throw error
        } catch {
            let modelError = ModelError.loadFailed(reason: error.localizedDescription)
            state = .error(modelError)
            throw modelError
        }
    }
    
    /// Unload the current model.
    /// - Parameter clearPersistence: If true, clears the saved model selection so it won't auto-load on next launch.
    func unload(clearPersistence: Bool = false) async {
        await backend?.unload()
        state = .unloaded
        modelInfo = nil
        loadedModelId = nil
        
        if clearPersistence {
            ModelPersistence.clearLastModelId()
        }
    }
    
    /// Generate a response.
    func generate(request: GenerationRequest) async throws -> GenerationResponse {
        guard let backend = backend else {
            throw ModelError.invalidConfiguration(reason: "No backend registered")
        }
        
        guard state.isReady else {
            throw ModelError.invalidConfiguration(reason: "Model not ready (state: \(state))")
        }
        
        state = .generating
        defer { Task { @MainActor in state = .ready } }
        
        return try await backend.generate(request: request)
    }
    
    /// Generate a streaming response.
    func generateStreaming(request: GenerationRequest) async throws -> StreamedGeneration {
        guard let backend = backend else {
            throw ModelError.invalidConfiguration(reason: "No backend registered")
        }
        
        guard state.isReady else {
            throw ModelError.invalidConfiguration(reason: "Model not ready (state: \(state))")
        }
        
        state = .generating
        
        return try await backend.generateStreaming(request: request)
    }
    
    /// Cancel ongoing generation.
    func cancel() async {
        await backend?.cancel()
        if state.isGenerating {
            state = .ready
        }
    }
    
    /// Estimate token count for text.
    func estimateTokens(for text: String) -> Int {
        // Fallback estimation if no backend loaded
        // Rough heuristic: ~4 characters per token for code
        guard let backend = backend else {
            return text.count / 4
        }
        return backend.estimateTokens(for: text)
    }
}
