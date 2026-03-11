import Foundation
import llama

/// Backend implementation for llama.cpp inference.
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
    
    // MARK: - Context Tracking
    
    /// Current number of tokens used in the context window
    var currentContextTokens: Int {
        context?.currentContextUsed ?? 0
    }
    
    /// Maximum context size (tokens)
    var maxContextTokens: Int {
        context?.contextSize ?? 0
    }
    
    /// Context usage as a fraction (0.0 to 1.0)
    var contextUsageFraction: Double {
        guard let ctx = context, ctx.contextSize > 0 else { return 0 }
        return Double(ctx.currentContextUsed) / Double(ctx.contextSize)
    }
    
    // MARK: - Static Initialization
    
    private static var isBackendInitialized = false
    
    private static func initializeBackendIfNeeded() {
        guard !isBackendInitialized else { return }
        llama_backend_init()
        isBackendInitialized = true
    }
    
    // MARK: - Lifecycle
    
    func load(configuration: ModelConfiguration) async throws {
        guard state == .unloaded || state == .error(.cancelled) else {
            throw ModelError.invalidConfiguration(reason: "Model already loaded or loading")
        }
        
        Self.initializeBackendIfNeeded()
        
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
            print("[LlamaBackend] Warning: Model may be too large for available memory")
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
                onProgress: { [weak self] progress in
                    Task { @MainActor in
                        // Update progress on main actor if needed
                        _ = progress
                    }
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
                checkCancelled: { self.isCancelled },
                onToken: { token in
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
                        checkCancelled: { self.isCancelled },
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

/// Wrapper around llama.cpp context with actual C bindings.
nonisolated final class LlamaContext: @unchecked Sendable {
    
    // Model info
    let modelName: String
    let parameterCount: String
    let contextSize: Int
    let memoryUsage: Int64
    let quantization: String?
    
    // llama.cpp pointers
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    
    // Thread safety
    private let lock = NSLock()
    private var shouldStop = false
    
    // Context tracking
    private var _tokensUsed: Int = 0
    
    /// Current number of tokens in the context (tracked by generation)
    var currentContextUsed: Int {
        lock.lock()
        defer { lock.unlock() }
        return _tokensUsed
    }
    
    /// Update the token count after generation
    func updateTokensUsed(_ count: Int) {
        lock.lock()
        _tokensUsed = count
        lock.unlock()
    }
    
    /// Reset token count (e.g., when clearing context)
    func resetTokensUsed() {
        lock.lock()
        _tokensUsed = 0
        lock.unlock()
    }
    
    private init(
        model: OpaquePointer,
        ctx: OpaquePointer,
        modelName: String,
        parameterCount: String,
        contextSize: Int,
        memoryUsage: Int64,
        quantization: String?
    ) {
        self.model = model
        self.ctx = ctx
        self.modelName = modelName
        self.parameterCount = parameterCount
        self.contextSize = contextSize
        self.memoryUsage = memoryUsage
        self.quantization = quantization
    }
    
    deinit {
        free()
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
        // Configure model parameters
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = Int32(gpuLayers)
        modelParams.use_mmap = true
        
        // Set up progress callback
        modelParams.progress_callback = { progress, _ in
            // Note: Can't capture Swift closure directly, but progress is reported
            return true // Continue loading
        }
        
        onProgress(0.1)
        
        // Load model
        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw ModelError.loadFailed(reason: "Failed to load model from \(modelPath)")
        }
        
        onProgress(0.5)
        
        // Configure context parameters
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(contextSize)
        ctxParams.n_batch = UInt32(batchSize)
        ctxParams.n_ubatch = UInt32(min(batchSize, 512))
        ctxParams.n_threads = Int32(threadCount)
        ctxParams.n_threads_batch = Int32(threadCount)
        ctxParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        
        // Create context
        guard let ctx = llama_init_from_model(model, ctxParams) else {
            llama_model_free(model)
            throw ModelError.loadFailed(reason: "Failed to create context")
        }
        
        onProgress(0.9)
        
        // Extract model info from filename
        let filename = URL(fileURLWithPath: modelPath).lastPathComponent
        let name = filename
            .replacingOccurrences(of: ".gguf", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        
        // Parse quantization from filename (e.g., Q4_K_M)
        let quantPattern = #"(Q[0-9]+_[A-Z_]+|IQ[0-9]+_[A-Z_]+)"#
        let quantization: String?
        if let range = filename.range(of: quantPattern, options: .regularExpression) {
            quantization = String(filename[range])
        } else {
            quantization = nil
        }
        
        // Estimate parameter count from file size
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: modelPath)[.size] as? Int64) ?? 0
        let parameterCount = formatParameterCount(estimateParameters(fileSize: fileSize, quantization: quantization))
        
        onProgress(1.0)
        
        return LlamaContext(
            model: model,
            ctx: ctx,
            modelName: name,
            parameterCount: parameterCount,
            contextSize: contextSize,
            memoryUsage: fileSize,
            quantization: quantization
        )
    }
    
    /// Tokenize text into token IDs.
    func tokenize(_ text: String) -> [llama_token] {
        guard let model = model else { return [] }
        
        let vocab = llama_model_get_vocab(model)
        let utf8Text = text.utf8CString
        let maxTokens = text.count + 16 // Generous buffer
        
        var tokens = [llama_token](repeating: 0, count: maxTokens)
        
        let nTokens = utf8Text.withUnsafeBufferPointer { buffer in
            llama_tokenize(
                vocab,
                buffer.baseAddress,
                Int32(text.utf8.count),
                &tokens,
                Int32(maxTokens),
                true,  // add_special (BOS)
                true   // parse_special
            )
        }
        
        if nTokens < 0 {
            // Buffer too small - reallocate
            let neededSize = -Int(nTokens)
            tokens = [llama_token](repeating: 0, count: neededSize)
            let actualTokens = utf8Text.withUnsafeBufferPointer { buffer in
                llama_tokenize(
                    vocab,
                    buffer.baseAddress,
                    Int32(text.utf8.count),
                    &tokens,
                    Int32(neededSize),
                    true,
                    true
                )
            }
            return Array(tokens.prefix(Int(actualTokens)))
        }
        
        return Array(tokens.prefix(Int(nTokens)))
    }
    
    /// Convert a token to text.
    private func tokenToPiece(_ token: llama_token) -> String {
        guard let model = model else { return "" }
        
        let vocab = llama_model_get_vocab(model)
        var buffer = [CChar](repeating: 0, count: 256)
        
        let length = llama_token_to_piece(
            vocab,
            token,
            &buffer,
            Int32(buffer.count),
            0,     // lstrip
            true   // special
        )
        
        if length < 0 {
            // Buffer too small
            let neededSize = -Int(length)
            buffer = [CChar](repeating: 0, count: neededSize)
            let actualLength = llama_token_to_piece(vocab, token, &buffer, Int32(neededSize), 0, true)
            return String(cString: buffer.prefix(Int(actualLength)).map { $0 } + [0])
        }
        
        return String(cString: buffer.prefix(Int(length)).map { $0 } + [0])
    }
    
    /// Generate completion tokens.
    func generate(
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        stopSequences: [String],
        checkCancelled: () -> Bool,
        onToken: @escaping (String) throws -> Void
    ) async throws -> [String] {
        guard let model = model, let ctx = ctx else {
            throw ModelError.invalidConfiguration(reason: "Context not initialized")
        }
        
        lock.lock()
        shouldStop = false
        lock.unlock()
        
        var tokens: [String] = []
        let vocab = llama_model_get_vocab(model)
        
        // Tokenize prompt
        let promptTokens = tokenize(prompt)
        guard !promptTokens.isEmpty else {
            throw ModelError.invalidConfiguration(reason: "Failed to tokenize prompt")
        }
        
        // Clear memory (KV cache)
        let memory = llama_get_memory(ctx)
        llama_memory_clear(memory, true)
        resetTokensUsed()
        
        // Process prompt in batches
        var mutableTokens = promptTokens
        let batch = llama_batch_get_one(&mutableTokens, Int32(promptTokens.count))
        
        let decodeResult = llama_decode(ctx, batch)
        if decodeResult != 0 {
            throw ModelError.inferenceError(reason: "Failed to decode prompt (error: \(decodeResult))")
        }
        
        // Track prompt tokens
        updateTokensUsed(promptTokens.count)
        
        // Create sampler chain
        let samplerParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(samplerParams) else {
            throw ModelError.inferenceError(reason: "Failed to create sampler chain")
        }
        defer { llama_sampler_free(sampler) }
        
        // Add sampling stages
        if temperature > 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0..<UInt32.max)))
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        }
        
        // Generation loop
        var generatedCount = 0
        var generatedText = ""
        var currentToken: llama_token = 0
        let eosToken = llama_vocab_eos(vocab)
        let eotToken = llama_vocab_eot(vocab)
        
        while generatedCount < maxTokens {
            // Check for cancellation
            lock.lock()
            let stopped = shouldStop
            lock.unlock()
            if stopped || checkCancelled() {
                break
            }
            
            // Sample next token
            currentToken = llama_sampler_sample(sampler, ctx, -1)
            
            // Check for end of generation
            if currentToken == eosToken || currentToken == eotToken {
                break
            }
            if llama_vocab_is_eog(vocab, currentToken) {
                break
            }
            
            // Convert token to text
            let piece = tokenToPiece(currentToken)
            tokens.append(piece)
            generatedText += piece
            generatedCount += 1
            
            // Update context tracking
            updateTokensUsed(promptTokens.count + generatedCount)
            
            // Notify callback
            try onToken(piece)
            
            // Check stop sequences
            if stopSequences.contains(where: { generatedText.hasSuffix($0) }) {
                break
            }
            
            // Accept the token
            llama_sampler_accept(sampler, currentToken)
            
            // Decode next token
            var tokenBatch = llama_batch_get_one(&currentToken, 1)
            let result = llama_decode(ctx, tokenBatch)
            if result != 0 {
                throw ModelError.inferenceError(reason: "Failed to decode token (error: \(result))")
            }
            
            // Yield to other tasks occasionally
            if generatedCount % 10 == 0 {
                await Task.yield()
            }
        }
        
        return tokens
    }
    
    /// Generate tokens with streaming callback.
    func generateStreaming(
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        stopSequences: [String],
        checkCancelled: () -> Bool,
        onToken: @escaping (String, Bool) -> Bool
    ) async throws {
        guard let model = model, let ctx = ctx else {
            throw ModelError.invalidConfiguration(reason: "Context not initialized")
        }
        
        lock.lock()
        shouldStop = false
        lock.unlock()
        
        let vocab = llama_model_get_vocab(model)
        
        // Tokenize prompt
        let promptTokens = tokenize(prompt)
        guard !promptTokens.isEmpty else {
            throw ModelError.invalidConfiguration(reason: "Failed to tokenize prompt")
        }
        
        // Clear memory (KV cache)
        let memory = llama_get_memory(ctx)
        llama_memory_clear(memory, true)
        resetTokensUsed()
        
        // Process prompt
        var mutableTokens = promptTokens
        let batch = llama_batch_get_one(&mutableTokens, Int32(promptTokens.count))
        let decodeResult = llama_decode(ctx, batch)
        if decodeResult != 0 {
            throw ModelError.inferenceError(reason: "Failed to decode prompt")
        }
        
        // Track prompt tokens
        updateTokensUsed(promptTokens.count)
        
        // Create sampler chain
        let samplerParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(samplerParams) else {
            throw ModelError.inferenceError(reason: "Failed to create sampler chain")
        }
        defer { llama_sampler_free(sampler) }
        
        // Add sampling stages
        if temperature > 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0..<UInt32.max)))
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        }
        
        // Generation loop
        var generatedCount = 0
        var generatedText = ""
        var currentToken: llama_token = 0
        let eosToken = llama_vocab_eos(vocab)
        let eotToken = llama_vocab_eot(vocab)
        
        while generatedCount < maxTokens {
            // Check for cancellation
            lock.lock()
            let stopped = shouldStop
            lock.unlock()
            if stopped || checkCancelled() {
                break
            }
            
            // Sample next token
            currentToken = llama_sampler_sample(sampler, ctx, -1)
            
            // Check for end of generation
            let isLast = currentToken == eosToken || 
                         currentToken == eotToken || 
                         llama_vocab_is_eog(vocab, currentToken) ||
                         generatedCount + 1 >= maxTokens
            
            if currentToken == eosToken || currentToken == eotToken || llama_vocab_is_eog(vocab, currentToken) {
                _ = onToken("", true)
                break
            }
            
            // Convert token to text
            let piece = tokenToPiece(currentToken)
            generatedText += piece
            generatedCount += 1
            
            // Update context tracking
            updateTokensUsed(promptTokens.count + generatedCount)
            
            // Check stop sequences
            let hitStopSequence = stopSequences.contains(where: { generatedText.hasSuffix($0) })
            let finalIsLast = isLast || hitStopSequence
            
            // Notify callback
            let shouldContinue = onToken(piece, finalIsLast)
            if !shouldContinue || finalIsLast {
                break
            }
            
            // Accept and decode next
            llama_sampler_accept(sampler, currentToken)
            var tokenBatch = llama_batch_get_one(&currentToken, 1)
            let result = llama_decode(ctx, tokenBatch)
            if result != 0 {
                throw ModelError.inferenceError(reason: "Failed to decode token")
            }
            
            // Yield occasionally
            if generatedCount % 10 == 0 {
                await Task.yield()
            }
        }
    }
    
    /// Signal to stop generation.
    func stopGeneration() {
        lock.lock()
        shouldStop = true
        lock.unlock()
    }
    
    /// Free resources.
    func free() {
        lock.lock()
        defer { lock.unlock() }
        
        if let ctx = ctx {
            llama_free(ctx)
            self.ctx = nil
        }
        if let model = model {
            llama_model_free(model)
            self.model = nil
        }
    }
    
    // MARK: - Helpers
    
    private static func estimateParameters(fileSize: Int64, quantization: String?) -> Int64 {
        // Rough estimates based on quantization
        let bitsPerParam: Double
        switch quantization?.uppercased() {
        case "Q4_K_M", "Q4_K_S", "Q4_0", "Q4_1":
            bitsPerParam = 4.5
        case "Q5_K_M", "Q5_K_S", "Q5_0", "Q5_1":
            bitsPerParam = 5.5
        case "Q6_K":
            bitsPerParam = 6.5
        case "Q8_0":
            bitsPerParam = 8.5
        case "IQ2_XXS", "IQ2_XS", "IQ2_S", "IQ2_M":
            bitsPerParam = 2.5
        case "IQ3_XXS", "IQ3_XS", "IQ3_S", "IQ3_M":
            bitsPerParam = 3.5
        case "IQ4_NL", "IQ4_XS":
            bitsPerParam = 4.0
        default:
            bitsPerParam = 4.5 // Assume Q4
        }
        
        // Parameters = (file_size_bits) / bits_per_param
        return Int64(Double(fileSize * 8) / bitsPerParam)
    }
    
    private static func formatParameterCount(_ count: Int64) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.0fM", Double(count) / 1_000_000)
        } else {
            return String(format: "%.0fK", Double(count) / 1_000)
        }
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
        
        // GPU layers - on iOS, use Metal
        #if targetEnvironment(simulator)
        let gpuLayers = 0 // CPU only on simulator
        #else
        let gpuLayers = 99 // Offload all layers to GPU on device
        #endif
        
        // Thread count - use performance cores
        let threadCount = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        
        return ModelConfiguration(
            modelPath: modelURL.path,
            contextSize: contextSize,
            gpuLayers: gpuLayers,
            threadCount: threadCount,
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
