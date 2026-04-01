import Foundation
import Combine
import Metal
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
    private var tokenizerHolder = FlashTokenizerHolder()
    private var metalPipeline: FlashMetalPipeline?
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
            // Load Metal pipeline first so we can upload weights to GPU during model load
            updateProgress(0.05)
            let earlyPipeline: FlashMetalPipeline? = try? FlashMetalPipeline()
            if let p = earlyPipeline { metalPipeline = p }

            engine = try await FlashInferenceEngine.load(
                path: path,
                metalPipeline: earlyPipeline
            ) { [weak self] progress in
                Task { await self?.updateProgress(0.05 + progress * 0.80) }
            }

            guard let eng = engine else {
                throw ModelError.loadFailed(reason: "Engine returned nil after load")
            }

            // ── Load tokenizer (from companion GGUF) ──────────────────────
            updateProgress(0.87)
            if let tokenizer = try? FlashTokenizer.forFlashPack(at: path) {
                await tokenizerHolder.set(tokenizer)
                logger.info("Tokenizer loaded")
            } else {
                logger.warning("No companion tokenizer found — using placeholder tokenizer")
            }

            // Metal pipeline is already initialized above (earlyPipeline)
            if metalPipeline == nil {
                logger.warning("Metal not available — using CPU (Accelerate) inference only")
            } else {
                logger.info("Metal GPU pipeline ready")
            }

            maxContextSize = configuration.contextSize
            state = .ready

            let quantTag = eng.config.dtype.rawValue.uppercased()
            let gpuTag = metalPipeline != nil ? " · GPU" : " · CPU"
            modelInfo = ModelInfo(
                name: eng.config.architecture.rawValue.capitalized + " (Flash\(gpuTag))",
                parameterCount: formatParamCount(eng.config),
                contextSize: configuration.contextSize,
                memoryUsage: estimatedDRAMNeeded,
                quantization: quantTag
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
        metalPipeline = nil
        await tokenizerHolder.clear()
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

        // Tokenize using llama.cpp's real tokenizer (or fallback)
        let promptTokens = await tokenizeSimple(prompt)
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
            if await isEOG(nextToken) {
                break
            }

            generatedTokens.append(nextToken)
            position += 1
            tokenCount = position

            // Convert token to text using llama.cpp vocabulary
            let piece = await detokenizeSimple(nextToken)
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
        let promptTokens = await tokenizeSimple(prompt)

        let stream = AsyncThrowingStream<GenerationToken, Error> { continuation in
            Task {
                var tokenIndex = 0

                do {
                    // Prefill
                    let _ = try await engine.prefill(tokenIds: promptTokens)

                    var position = promptTokens.count
                    var generatedText = ""
                    var lastToken: Int32 = promptTokens.last ?? 1

                    while tokenIndex < request.maxTokens {
                        if self.isCancelled {
                            continuation.finish(throwing: ModelError.cancelled)
                            return
                        }

                        let (nextToken, _) = try await engine.decodeStep(
                            lastTokenId: lastToken,
                            position: position,
                            temperature: request.temperature,
                            topK: self.backendConfig.topK,
                            topP: self.backendConfig.topP
                        )

                        if await self.tokenizerHolder.isEOG(nextToken) {
                            continuation.yield(GenerationToken(text: "", tokenIndex: tokenIndex, isLast: true))
                            break
                        }

                        let piece = await self.tokenizerHolder.tokenToPiece(nextToken)
                        generatedText += piece
                        position += 1
                        lastToken = nextToken

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
        state = .loading(progress: max(0, min(1, progress)))
    }

    /// GPU pipeline accessor for FFN compute (nil = CPU fallback).
    var gpuPipeline: FlashMetalPipeline? { metalPipeline }

    /// Inference engine — available after model is loaded.
    var inferenceEngine: FlashInferenceEngine? { engine }

    /// Tokenizer — available after model is loaded.
    var loadedTokenizer: FlashTokenizer? { get async { await tokenizerHolder.tokenizer } }

    /// Path of the currently loaded FlashPack file.
    var loadedModelPath: String { backendConfig.modelPath }

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

    /// Tokenize using llama.cpp's real BPE/SentencePiece tokenizer.
    /// Falls back to a simple placeholder if no tokenizer was loaded.
    private func tokenizeSimple(_ text: String) async -> [Int32] {
        let tokens = await tokenizerHolder.tokenize(text, addBOS: true)
        if !tokens.isEmpty { return tokens }

        // Fallback: hash-based pseudo-tokenizer (for testing without a companion GGUF)
        var result: [Int32] = [1]
        var current = ""
        for char in text {
            current.append(char)
            if current.count >= 4 || char == " " || char == "\n" {
                result.append(Int32(abs(current.hashValue) % 30000 + 2))
                current = ""
            }
        }
        if !current.isEmpty {
            result.append(Int32(abs(current.hashValue) % 30000 + 2))
        }
        return result
    }

    /// Detokenize a single token ID using llama.cpp's vocabulary.
    private func detokenizeSimple(_ token: Int32) async -> String {
        let piece = await tokenizerHolder.tokenToPiece(token)
        if !piece.isEmpty { return piece }
        return " "
    }

    /// Check if a token is end-of-generation.
    private func isEOG(_ token: Int32) async -> Bool {
        return await tokenizerHolder.isEOG(token)
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

// FlashModelConverter is defined in FlashModelConverter.swift


