import Foundation

/// Backend implementation for llama.cpp inference.
/// 
/// ## Setup Requirements
/// 
/// To enable llama.cpp inference, you need to:
/// 
/// 1. Add llama.cpp as a dependency:
///    - Clone llama.cpp into the project: `git submodule add https://github.com/ggerganov/llama.cpp`
///    - Or use a Swift package wrapper like `swift-llama`
/// 
/// 2. Create a bridging header (PocketREPL-Bridging-Header.h):
///    ```c
///    #include "llama.h"
///    ```
/// 
/// 3. Configure the Xcode project:
///    - Add llama.cpp source files to build
///    - Set C++ Language Dialect to C++17
///    - Add Header Search Paths for llama.cpp
/// 
/// 4. Download a model:
///    - Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf (recommended for iOS)
///    - Place in app bundle or download to Documents
/// 
/// ## Model Recommendations for iOS
/// 
/// - **Qwen2.5-Coder-1.5B** - Best balance of quality and size
/// - **CodeGemma-2B** - Alternative coding model
/// - **Phi-3-mini** - Small general model with coding ability
/// 
/// Use Q4_K_M or Q4_K_S quantization for mobile.
/// 
actor LlamaBackend: ModelBackend {
    
    // MARK: - State
    
    private(set) var state: ModelState = .unloaded
    private(set) var modelInfo: ModelInfo?
    
    private var context: LlamaContext?
    private var configuration: ModelConfiguration?
    private var isCancelled = false
    
    // MARK: - Lifecycle
    
    func load(configuration: ModelConfiguration) async throws {
        guard state == .unloaded || state == .error(.cancelled) else {
            throw ModelError.invalidConfiguration(reason: "Model already loaded or loading")
        }
        
        self.configuration = configuration
        state = .loading(progress: 0)
        
        // Verify model file exists
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: configuration.modelPath) else {
            state = .error(.modelNotFound(path: configuration.modelPath))
            throw ModelError.modelNotFound(path: configuration.modelPath)
        }
        
        // Check available memory
        let availableMemory = ProcessInfo.processInfo.physicalMemory
        let estimatedModelSize = try estimateModelSize(at: configuration.modelPath)
        
        // Models typically need 1.5-2x their file size in RAM
        let requiredMemory = Int64(Double(estimatedModelSize) * 1.8)
        if requiredMemory > Int64(availableMemory) * 3 / 4 {
            // Warning: might be tight on memory
            // Don't fail, but log warning
        }
        
        state = .loading(progress: 0.1)
        
        // Initialize llama.cpp context
        do {
            context = try await LlamaContext.create(
                modelPath: configuration.modelPath,
                contextSize: configuration.contextSize,
                gpuLayers: configuration.gpuLayers,
                threadCount: configuration.threadCount,
                batchSize: configuration.batchSize,
                onProgress: { progress in
                    // Progress callback - state update happens after create returns
                }
            )
            
            state = .loading(progress: 1.0)
            
            // Extract model info
            if let ctx = context {
                modelInfo = ModelInfo(
                    name: ctx.modelName,
                    parameterCount: ctx.parameterCount,
                    contextSize: ctx.contextSize,
                    memoryUsage: ctx.memoryUsage,
                    quantization: ctx.quantization
                )
            }
            
            state = .ready
            
        } catch let error as ModelError {
            state = .error(error)
            throw error
        } catch {
            let modelError = ModelError.loadFailed(reason: error.localizedDescription)
            state = .error(modelError)
            throw modelError
        }
    }
    
    func unload() async {
        context?.free()
        context = nil
        modelInfo = nil
        state = .unloaded
    }
    
    // MARK: - Generation
    
    func generate(request: GenerationRequest) async throws -> GenerationResponse {
        guard let context = context else {
            throw ModelError.invalidConfiguration(reason: "Model not loaded")
        }
        
        guard state.isReady else {
            throw ModelError.invalidConfiguration(reason: "Model not ready (state: \(state))")
        }
        
        isCancelled = false
        let startTime = Date()
        
        // Build the prompt
        let prompt = buildPrompt(for: request)
        
        // Check token count
        let promptTokens = context.tokenize(prompt).count
        let maxContextTokens = configuration?.contextSize ?? 4096
        
        if promptTokens + request.maxTokens > maxContextTokens {
            throw ModelError.contextOverflow(tokens: promptTokens + request.maxTokens, maxTokens: maxContextTokens)
        }
        
        // Generate
        var generatedText = ""
        var completionTokens = 0
        var finishReason: GenerationResponse.FinishReason = .complete
        
        do {
            let tokens = try await context.generate(
                prompt: prompt,
                maxTokens: request.maxTokens,
                temperature: request.temperature,
                stopSequences: request.stopSequences,
                onToken: { token in
                    // Token callback - cancellation checked in context
                    generatedText += token
                    completionTokens += 1
                }
            )
            
            generatedText = tokens.joined()
            
            // Determine finish reason
            if isCancelled {
                finishReason = .cancelled
            } else if completionTokens >= request.maxTokens {
                finishReason = .maxTokens
            } else if request.stopSequences.contains(where: { generatedText.hasSuffix($0) }) {
                finishReason = .stopSequence
            }
            
        } catch let error as ModelError {
            throw error
        } catch {
            throw ModelError.inferenceError(reason: error.localizedDescription)
        }
        
        let duration = Date().timeIntervalSince(startTime)
        
        return GenerationResponse(
            text: generatedText,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            durationSeconds: duration,
            finishReason: finishReason
        )
    }
    
    func generateStreaming(request: GenerationRequest) async throws -> StreamedGeneration {
        guard let context = context else {
            throw ModelError.invalidConfiguration(reason: "Model not loaded")
        }
        
        guard state.isReady else {
            throw ModelError.invalidConfiguration(reason: "Model not ready")
        }
        
        isCancelled = false
        let prompt = buildPrompt(for: request)
        
        let stream = AsyncThrowingStream<GenerationToken, Error> { continuation in
            Task {
                var tokenIndex = 0
                
                do {
                    try await context.generateStreaming(
                        prompt: prompt,
                        maxTokens: request.maxTokens,
                        temperature: request.temperature,
                        stopSequences: request.stopSequences,
                        onToken: { token, isLast in
                            if self.isCancelled {
                                continuation.finish(throwing: ModelError.cancelled)
                                return false // Signal to stop generation
                            }
                            
                            continuation.yield(GenerationToken(
                                text: token,
                                tokenIndex: tokenIndex,
                                isLast: isLast
                            ))
                            
                            tokenIndex += 1
                            return true // Continue generation
                        }
                    )
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        
        return StreamedGeneration(stream)
    }
    
    func cancel() async {
        isCancelled = true
        context?.stopGeneration()
    }
    
    nonisolated func estimateTokens(for text: String) -> Int {
        // Without access to the actual tokenizer, estimate based on character count
        // Most LLMs average ~4 characters per token for code
        // This is a rough estimate; real tokenization is more accurate
        return max(1, text.count / 4)
    }
    
    // MARK: - Private Helpers
    
    private func buildPrompt(for request: GenerationRequest) -> String {
        switch request.task {
        case .generate:
            return PromptTemplates.codeGeneration(
                instruction: request.prompt,
                context: request.context,
                filePath: request.filePath
            )
        case .fix:
            return PromptTemplates.codeFix(
                code: request.existingCode ?? "",
                error: request.errorMessage ?? "",
                context: request.context,
                filePath: request.filePath
            )
        case .complete:
            return PromptTemplates.codeCompletion(
                partialCode: request.existingCode ?? "",
                context: request.context
            )
        case .explain:
            return """
                Explain the following code concisely:
                
                ```javascript
                \(request.existingCode ?? "")
                ```
                """
        }
    }
    
    private func estimateModelSize(at path: String) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return attributes[.size] as? Int64 ?? 0
    }
}

// MARK: - Llama Context Wrapper

/// Wrapper around llama.cpp context.
/// This is a placeholder that will be implemented when llama.cpp is integrated.
nonisolated final class LlamaContext: @unchecked Sendable {
    
    // Model info
    let modelName: String
    let parameterCount: String
    let contextSize: Int
    let memoryUsage: Int64
    let quantization: String?
    
    // Internal state - these would be actual llama.cpp pointers
    // private var model: OpaquePointer?
    // private var ctx: OpaquePointer?
    
    private var shouldStop = false
    
    private init(
        modelName: String,
        parameterCount: String,
        contextSize: Int,
        memoryUsage: Int64,
        quantization: String?
    ) {
        self.modelName = modelName
        self.parameterCount = parameterCount
        self.contextSize = contextSize
        self.memoryUsage = memoryUsage
        self.quantization = quantization
    }
    
    /// Create a new llama context from a model file.
    static func create(
        modelPath: String,
        contextSize: Int,
        gpuLayers: Int,
        threadCount: Int,
        batchSize: Int,
        onProgress: @escaping (Double) -> Void
    ) async throws -> LlamaContext {
        // TODO: Implement actual llama.cpp initialization
        // This is a placeholder that simulates model loading
        
        // In real implementation:
        // 1. Call llama_model_load_from_file()
        // 2. Create context with llama_new_context_with_model()
        // 3. Configure sampling parameters
        
        // Simulate loading progress
        for i in 1...10 {
            try await Task.sleep(nanoseconds: 50_000_000) // 0.05s
            onProgress(Double(i) / 10.0)
        }
        
        // Extract model info from filename
        let filename = URL(fileURLWithPath: modelPath).lastPathComponent
        let name = filename
            .replacingOccurrences(of: ".gguf", with: "")
            .replacingOccurrences(of: "-", with: " ")
        
        // Parse quantization from filename (e.g., Q4_K_M)
        let quantPattern = #"(Q[0-9]+_[A-Z_]+)"#
        let quantization: String?
        if let range = filename.range(of: quantPattern, options: .regularExpression) {
            quantization = String(filename[range])
        } else {
            quantization = nil
        }
        
        return LlamaContext(
            modelName: name,
            parameterCount: "1.5B", // Would be extracted from model metadata
            contextSize: contextSize,
            memoryUsage: 1_500_000_000, // Would be actual memory usage
            quantization: quantization
        )
    }
    
    /// Tokenize text into token IDs.
    func tokenize(_ text: String) -> [Int] {
        // TODO: Implement actual tokenization with llama_tokenize()
        // Placeholder: estimate ~4 chars per token
        let estimatedTokens = max(1, text.count / 4)
        return Array(0..<estimatedTokens)
    }
    
    /// Generate completion tokens.
    func generate(
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        stopSequences: [String],
        onToken: @escaping (String) throws -> Void
    ) async throws -> [String] {
        // TODO: Implement actual generation with llama_decode() loop
        // This is a placeholder that returns mock output
        
        shouldStop = false
        var tokens: [String] = []
        
        // Simulate token-by-token generation
        let mockOutput = "// Generated code placeholder\nfunction example() {\n  console.log('Hello');\n}\n"
        let words = mockOutput.components(separatedBy: .whitespaces)
        
        for (i, word) in words.enumerated() {
            if shouldStop { break }
            if tokens.count >= maxTokens { break }
            
            let token = i == 0 ? word : " " + word
            try onToken(token)
            tokens.append(token)
            
            // Simulate generation delay
            try await Task.sleep(nanoseconds: 20_000_000) // 0.02s per token
        }
        
        return tokens
    }
    
    /// Generate tokens with streaming callback.
    func generateStreaming(
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        stopSequences: [String],
        onToken: @escaping (String, Bool) -> Bool
    ) async throws {
        // TODO: Implement streaming generation
        shouldStop = false
        
        let mockOutput = "// Generated code placeholder\nfunction example() {\n  console.log('Hello');\n}\n"
        let words = mockOutput.components(separatedBy: .whitespaces)
        
        for (i, word) in words.enumerated() {
            if shouldStop { break }
            
            let token = i == 0 ? word : " " + word
            let isLast = i == words.count - 1
            
            let shouldContinue = onToken(token, isLast)
            if !shouldContinue { break }
            
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    
    /// Signal to stop generation.
    func stopGeneration() {
        shouldStop = true
    }
    
    /// Free resources.
    func free() {
        // TODO: Call llama_free() and llama_free_model()
        shouldStop = true
    }
}

// MARK: - Model Discovery

/// Utilities for finding and managing model files.
nonisolated enum ModelDiscovery: Sendable {
    
    /// Search for GGUF model files in common locations.
    static func findModels() -> [URL] {
        var models: [URL] = []
        let fileManager = FileManager.default
        
        // Check app bundle
        if let bundlePath = Bundle.main.resourcePath {
            models.append(contentsOf: findGGUFFiles(in: URL(fileURLWithPath: bundlePath)))
        }
        
        // Check Documents directory
        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            models.append(contentsOf: findGGUFFiles(in: documentsURL))
            
            // Check Models subdirectory
            let modelsDir = documentsURL.appendingPathComponent("Models")
            models.append(contentsOf: findGGUFFiles(in: modelsDir))
        }
        
        // Check Caches for downloaded models
        if let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let modelsDir = cachesURL.appendingPathComponent("Models")
            models.append(contentsOf: findGGUFFiles(in: modelsDir))
        }
        
        return models
    }
    
    private static func findGGUFFiles(in directory: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        return contents.filter { $0.pathExtension.lowercased() == "gguf" }
    }
    
    /// Get a recommended model configuration for a given file.
    static func recommendedConfiguration(for modelURL: URL) -> ModelConfiguration {
        let filename = modelURL.lastPathComponent.lowercased()
        
        // Adjust context size based on model
        let contextSize: Int
        if filename.contains("1.5b") || filename.contains("2b") {
            contextSize = 4096
        } else if filename.contains("7b") {
            contextSize = 2048 // More conservative for larger models
        } else {
            contextSize = 4096
        }
        
        // GPU layers - on iOS, typically use 0 (CPU) or limited GPU
        let gpuLayers = 0 // Metal support varies
        
        // Thread count - use performance cores
        let threadCount = ProcessInfo.processInfo.activeProcessorCount / 2
        
        return ModelConfiguration(
            modelPath: modelURL.path,
            contextSize: contextSize,
            gpuLayers: gpuLayers,
            threadCount: max(2, threadCount),
            useMemoryMapping: true,
            batchSize: 512
        )
    }
    
    /// Format file size for display.
    static func formatModelSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }
}
