import Foundation
import Combine
import os.log

// MARK: - Flash Inference Backend
//
// Implements the `ModelBackend` protocol using Apple's "LLM in a Flash" technique.
//
// The key difference from LlamaBackend:
//   ┌───────────────────────────────────────────────────────┐
//   │  LlamaBackend: loads entire model into DRAM           │
//   │   → Limited to models ≤ available DRAM               │
//   │                                                        │
//   │  FlashInferenceBackend: stores model on NVMe SSD      │
//   │   → Loads only active FFN neurons per token           │
//   │   → DRAM usage = attention weights + small neuron     │
//   │     cache (≈ 25–50% of model size)                   │
//   │   → Supports models 2× larger than available DRAM    │
//   └───────────────────────────────────────────────────────┘
//
// HARDWARE UTILISATION:
//   On an M3 Max with 48 GB DRAM and 209 GB NVMe:
//     - Attention weights (33% of 7B model ≈ 4.6 GB) → DRAM
//     - Neuron cache (25% of FFN ≈ 2.3 GB) → DRAM
//     - Remaining FFN weights (≈ 6.9 GB) → NVMe SSD
//     - Total DRAM: ~7 GB for a 7B model (vs. 14 GB traditionally)
//
//   At 17.5 GB/s SSD read bandwidth and 90%+ sparsity:
//     - Only ~3% of FFN weights needed per token
//     - Flash load: ~50 ms/token  (paper: 87 ms on M1 Max)
//     - Target: ~5–7 tok/s for 7B models

// MARK: - Flash Backend Configuration

/// Configuration for the Flash Inference Backend.
struct FlashBackendConfig: Sendable {
    /// Path to the FlashPack model file (.flashpack).
    let modelPath: String

    /// Maximum context window in tokens.
    let contextSize: Int

    /// Sampling temperature (0 = greedy).
    let temperature: Float

    /// Top-K for sampling (0 = no limit).
    let topK: Int

    /// Top-P nucleus for sampling (1.0 = no limit).
    let topP: Float

    /// Override flash loading config (nil = use model defaults).
    var flashOverrides: FlashOverrides?

    struct FlashOverrides: Sendable {
        var slidingWindowSize: Int?
        var maxCacheFraction: Double?
        var ioThreadCount: Int?
        var bypassOSCache: Bool?
        var predictorThreshold: Float?
    }

    static let `default` = FlashBackendConfig(
        modelPath: "",
        contextSize: 4096,
        temperature: 0.2,
        topK: 40,
        topP: 0.95
    )
}

// MARK: - Flash Inference Backend

actor FlashInferenceBackend: ModelBackend {

    // MARK: - State

    private(set) var state: ModelState = .unloaded
    private(set) var modelInfo: ModelInfo? = nil

    private var engine: FlashInferenceEngine?
    private var backendConfig: FlashBackendConfig
    private var isCancelled = false
    private var conversationHistory: [Int32] = []

    // For tracking context window
    private var tokenCount: Int = 0
    private var maxContextSize: Int = 4096

    // Logging
    private let logger = Logger(subsystem: "com.pocketrepl", category: "flash-inference")

    // MARK: - ModelBackend Protocol

    var currentContextTokens: Int { tokenCount }
    var maxContextTokens: Int     { maxContextSize }

    // MARK: - Initialization

    init(config: FlashBackendConfig = .default) {
        self.backendConfig = config
    }

    // MARK: - Loading

    func load(configuration: ModelConfiguration) async throws {
        guard state == .unloaded || state == .error(.cancelled) else {
            throw ModelError.invalidConfiguration(reason: "Model already loaded or loading")
        }

        let path = configuration.modelPath
        guard FileManager.default.fileExists(atPath: path) else {
            state = .error(.modelNotFound(path: path))
            throw ModelError.modelNotFound(path: path)
        }

        // Check it's a FlashPack file
        guard path.hasSuffix(".flashpack") else {
            state = .error(.loadFailed(reason: "FlashInferenceBackend requires .flashpack model files"))
            throw ModelError.loadFailed(reason: "FlashInferenceBackend requires .flashpack model files. Use FlashModelConverter to convert your GGUF model.")
        }

        state = .loading(progress: 0)
        logger.info("Loading FlashPack model: \(path)")

        // Check DRAM availability
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        let memInfo = MemoryPressureMonitor.currentMemoryInfo()

        // Estimate DRAM needed: attention weights + neuron cache = ~50% of model in best case
        let estimatedDRAMNeeded = Int64(Double(fileSize) * 0.5)
        guard estimatedDRAMNeeded < memInfo.estimatedAvailableBytes else {
            let err = ModelError.insufficientMemory(
                required: estimatedDRAMNeeded,
                available: memInfo.estimatedAvailableBytes
            )
            state = .error(err)
            throw err
        }

        logger.info("Estimated DRAM needed: \(estimatedDRAMNeeded / 1_000_000) MB")
        logger.info("Available DRAM: \(memInfo.estimatedAvailableBytes / 1_000_000) MB")

        do {
            engine = try await FlashInferenceEngine.load(path: path) { [weak self] progress in
                Task { await self?.updateProgress(progress) }
            }

            guard let eng = engine else {
                throw ModelError.loadFailed(reason: "Engine returned nil after load")
            }

            maxContextSize = configuration.contextSize
            state = .ready

            modelInfo = ModelInfo(
                name: eng.config.architecture.rawValue.capitalized + " (Flash)",
                parameterCount: formatParamCount(eng.config),
                contextSize: configuration.contextSize,
                memoryUsage: estimatedDRAMNeeded,
                quantization: eng.config.dtype.rawValue.uppercased()
            )

            logger.info("FlashPack model loaded. DRAM footprint: ~\(estimatedDRAMNeeded / 1_000_000) MB")

        } catch let fe as FlashModelError {
            let err = ModelError.loadFailed(reason: fe.localizedDescription ?? "Unknown flash error")
            state = .error(err)
            throw err
        } catch let me as ModelError {
            state = .error(me)
            throw me
        } catch {
            let me = ModelError.loadFailed(reason: error.localizedDescription)
            state = .error(me)
            throw me
        }
    }

    func unload() async {
        engine = nil
        state = .unloaded
        modelInfo = nil
        tokenCount = 0
        conversationHistory = []
        logger.info("FlashPack model unloaded")
    }

    // MARK: - Generation

    func generate(request: GenerationRequest) async throws -> GenerationResponse {
        guard let engine = engine, state.isReady else {
            throw ModelError.invalidConfiguration(reason: "Model not ready (state: \(state))")
        }

        isCancelled = false
        let startTime = Date()

        let prompt = buildPrompt(for: request)

        // Tokenize (simple whitespace split as placeholder;
        // production implementation uses llama.cpp tokenizer)
        let promptTokens = tokenizeSimple(prompt)
        let maxContextTokens = backendConfig.contextSize

        guard promptTokens.count + request.maxTokens <= maxContextTokens else {
            throw ModelError.contextOverflow(tokens: promptTokens.count + request.maxTokens, maxTokens: maxContextTokens)
        }

        tokenCount = promptTokens.count

        // Prefill
        let _ = try await engine.prefill(tokenIds: promptTokens)

        // Generate tokens
        var generatedTokens: [Int32] = []
        var generatedText = ""
        var position = promptTokens.count
        var finishReason: GenerationResponse.FinishReason = .complete

        while generatedTokens.count < request.maxTokens {
            if isCancelled {
                finishReason = .cancelled
                break
            }

            let lastToken = generatedTokens.last ?? promptTokens.last ?? 1
            let (nextToken, _) = try await engine.decodeStep(
                lastTokenId: lastToken,
                position: position,
                temperature: request.temperature,
                topK: backendConfig.topK,
                topP: backendConfig.topP
            )

            // Check for end-of-sequence tokens
            if nextToken == 2 || nextToken == 1 {  // EOS/BOS for Llama
                break
            }

            generatedTokens.append(nextToken)
            position += 1
            tokenCount = position

            // Convert token to text (placeholder; real impl uses llama vocab)
            let piece = detokenizeSimple(nextToken)
            generatedText += piece

            // Check stop sequences
            if request.stopSequences.contains(where: { generatedText.hasSuffix($0) }) {
                finishReason = .stopSequence
                break
            }

            if generatedTokens.count >= request.maxTokens {
                finishReason = .maxTokens
            }

            // Yield occasionally for cooperative multitasking
            if generatedTokens.count % 10 == 0 {
                await Task.yield()
            }
        }

        let duration = Date().timeIntervalSince(startTime)

        return GenerationResponse(
            text: generatedText,
            promptTokens: promptTokens.count,
            completionTokens: generatedTokens.count,
            durationSeconds: duration,
            finishReason: finishReason
        )
    }

    func generateStreaming(request: GenerationRequest) async throws -> StreamedGeneration {
        guard let engine = engine, state.isReady else {
            throw ModelError.invalidConfiguration(reason: "Model not ready")
        }

        isCancelled = false
        let prompt = buildPrompt(for: request)
        let promptTokens = tokenizeSimple(prompt)

        let stream = AsyncThrowingStream<GenerationToken, Error> { continuation in
            Task {
                var tokenIndex = 0

                do {
                    // Prefill
                    let _ = try await engine.prefill(tokenIds: promptTokens)

                    var position = promptTokens.count
                    var generatedText = ""

                    while tokenIndex < request.maxTokens {
                        if self.isCancelled {
                            continuation.finish(throwing: ModelError.cancelled)
                            return
                        }

                        let lastToken: Int32 = tokenIndex == 0
                            ? (promptTokens.last ?? 1)
                            : Int32(tokenIndex)  // Placeholder

                        let (nextToken, _) = try await engine.decodeStep(
                            lastTokenId: lastToken,
                            position: position,
                            temperature: request.temperature,
                            topK: self.backendConfig.topK,
                            topP: self.backendConfig.topP
                        )

                        if nextToken == 2 || nextToken == 1 {
                            continuation.yield(GenerationToken(text: "", tokenIndex: tokenIndex, isLast: true))
                            break
                        }

                        let piece = self.detokenizeSimple(nextToken)
                        generatedText += piece
                        position += 1

                        let hitStop = request.stopSequences.contains { generatedText.hasSuffix($0) }
                        let isLast = hitStop || tokenIndex + 1 >= request.maxTokens

                        continuation.yield(GenerationToken(text: piece, tokenIndex: tokenIndex, isLast: isLast))
                        tokenIndex += 1

                        if isLast { break }

                        if tokenIndex % 10 == 0 {
                            await Task.yield()
                        }
                    }

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
        engine?.resetState()
    }

    nonisolated func estimateTokens(for text: String) -> Int {
        // ~4 characters per token for English; ~3 for code
        return max(1, text.count / 4)
    }

    // MARK: - Flash-Specific Metrics

    /// Returns current cache performance metrics across all layers.
    func cacheMetrics() async -> FlashCacheMetrics? {
        guard let engine = engine else { return nil }
        let mgr = engine.cacheManager
        return FlashCacheMetrics(
            averageHitRate: mgr.averageHitRate,
            totalHits: mgr.totalCacheHits,
            totalMisses: mgr.totalCacheMisses,
            estimatedDRAMUsedMB: mgr.estimatedDRAMUsedMB,
            totalEvictions: mgr.totalEvictions
        )
    }

    /// Returns current flash I/O throughput metrics.
    func ioMetrics() async -> FlashIOMetrics? {
        guard let engine = engine else { return nil }
        let store = engine.store
        return FlashIOMetrics(
            totalBytesRead: store.readBytesTotal,
            totalReads: store.readCountTotal
        )
    }

    // MARK: - Private Helpers

    private func updateProgress(_ progress: Double) {
        state = .loading(progress: progress)
    }

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
            return "Explain the following code:\n\n```\n\(request.existingCode ?? "")\n```"
        }
    }

    /// Placeholder tokenizer: splits on spaces and maps to token IDs.
    /// Real implementation should use llama.cpp's tokenizer (BPE/SentencePiece).
    private func tokenizeSimple(_ text: String) -> [Int32] {
        // Very rough: byte-pair heuristic based on character categories
        // TODO: integrate llama_tokenize() from the llama framework
        var tokens: [Int32] = [1]  // BOS token
        var current = ""
        for char in text {
            current.append(char)
            if current.count >= 4 || char == " " || char == "\n" {
                // Hash the string to get a pseudo-token-id in vocab range
                let hash = abs(current.hashValue) % 30000 + 2  // Avoid special tokens
                tokens.append(Int32(hash))
                current = ""
            }
        }
        if !current.isEmpty {
            tokens.append(Int32(abs(current.hashValue) % 30000 + 2))
        }
        return tokens
    }

    /// Placeholder detokenizer. Real implementation uses llama_token_to_piece().
    private func detokenizeSimple(_ token: Int32) -> String {
        // TODO: integrate llama_token_to_piece() from the llama framework
        // For now, return a placeholder character to demonstrate the loop works
        let letters = " the a in of and is to it I that was for on are be with as at by from"
        let words = letters.split(separator: " ")
        let idx = Int(token) % words.count
        return " " + words[idx]
    }

    private func formatParamCount(_ config: FlashModelConfig) -> String {
        let approxParams = config.vocabSize * config.hiddenSize +
                          config.numHiddenLayers * (4 * config.hiddenSize * config.hiddenSize +
                                                    3 * config.hiddenSize * config.intermediateSize)
        if approxParams >= 1_000_000_000 {
            return String(format: "%.1fB", Double(approxParams) / 1e9)
        }
        return String(format: "%.0fM", Double(approxParams) / 1e6)
    }
}

// MARK: - Metrics Structs

struct FlashCacheMetrics: Sendable {
    let averageHitRate: Double
    let totalHits: Int
    let totalMisses: Int
    let estimatedDRAMUsedMB: Double
    let totalEvictions: Int

    var formattedHitRate: String {
        String(format: "%.1f%%", averageHitRate * 100)
    }
}

struct FlashIOMetrics: Sendable {
    let totalBytesRead: Int64
    let totalReads: Int

    var totalMBRead: Double {
        Double(totalBytesRead) / (1024 * 1024)
    }
}

// MARK: - Flash Model Converter (Stub)
//
// Converts standard GGUF models to FlashPack format.
// Full implementation requires parsing GGUF tensor layout.
//
// Usage:
//   FlashModelConverter.convert(ggufPath: "model.gguf", output: "model.flashpack")
//
// The conversion:
//   1. Parses GGUF header (vocabulary, architecture params)
//   2. Dequantizes weights to Float16 (or keeps them quantized if supported)
//   3. Rearranges FFN weights into bundled neuron format:
//      - For neuron j: [up_col_j | gate_col_j | down_row_j]  (contiguous)
//   4. Computes neuron importance scores from a small calibration dataset
//   5. Writes FlashPack header + weights
//
// The bundled format is the KEY innovation from the paper:
//   Loading neuron j requires reading ONE chunk of 2×hiddenSize×sizeof(dtype) bytes,
//   vs TWO separate reads (one column from up_proj, one row from down_proj).
//   This doubles effective chunk size → nearly doubles throughput on Apple NVMe.

enum FlashModelConverter {

    /// Convert a GGUF model file to FlashPack format.
    /// - Parameters:
    ///   - ggufPath: Path to source .gguf file
    ///   - outputPath: Path for output .flashpack file
    ///   - onProgress: Progress callback (0.0 → 1.0)
    /// - Note: Full implementation requires GGUF parser.
    static func convert(
        ggufPath: String,
        outputPath: String,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        // Stub: full implementation requires:
        // 1. Parse GGUF metadata and tensors
        // 2. Read each layer's up_proj, gate_proj, down_proj
        // 3. Bundle neurons: interleave [up_col_j, gate_col_j, down_row_j]
        // 4. Compute importance scores (optional, needs calibration data)
        // 5. Write FlashPack binary with JSON header
        throw FlashModelError.headerParseFailure(
            "FlashModelConverter is not yet implemented. " +
            "Please use a pre-converted .flashpack model. " +
            "See: https://github.com/danveloper/flash-moe for conversion scripts."
        )
    }

    /// Estimate the DRAM reduction from using flash inference.
    ///
    /// For a model with `modelSizeBytes` total size and `sparsityRatio` FFN sparsity:
    ///   DRAM saved = FFN size × (1 - cache fraction)
    ///   FFN fraction ≈ 0.67 (2/3 of transformer is FFN)
    static func estimateDRAMReduction(modelSizeBytes: Int64, sparsityRatio: Double) -> (savingsMB: Double, fractionSaved: Double) {
        let ffnFraction = 0.67
        let cacheFraction = max(0.0, 1.0 - sparsityRatio) * 1.1  // 10% buffer
        let ffnInDRAM = Double(modelSizeBytes) * ffnFraction * cacheFraction
        let attnInDRAM = Double(modelSizeBytes) * (1.0 - ffnFraction)
        let totalDRAM = ffnInDRAM + attnInDRAM
        let savings = Double(modelSizeBytes) - totalDRAM
        return (savingsMB: savings / (1024 * 1024), fractionSaved: savings / Double(modelSizeBytes))
    }
}


