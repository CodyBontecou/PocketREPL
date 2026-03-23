import Foundation
import Accelerate

// MARK: - Flash Inference Engine
//
// Implements the complete LLM forward pass with flash-loaded FFN weights.
//
// ARCHITECTURE:
// ─────────────
// For each token, the pipeline is:
//
//   Input Token
//     │
//     ▼
//   Embedding Lookup              ← DRAM (always resident)
//     │
//     ▼
//   For each layer:
//     ├─ 1. RMSNorm (input)        ← DRAM
//     ├─ 2. Attention (Q, K, V, O) ← DRAM (DRAM-resident per paper: ~33% of model)
//     ├─ 3. KV Cache update        ← DRAM (bounded by context length)
//     ├─ 4. Residual add
//     ├─ 5. RMSNorm (post-attn)    ← DRAM
//     ├─ 6. Predict active FFN neurons via SparsityPredictor
//     ├─ 7. Load needed neurons from FlashNeuronCache (or flash if miss)
//     ├─ 8. Sparse FFN forward pass
//     ├─ 9. Residual add
//     └─ 10. Advance sliding window
//     │
//     ▼
//   Final RMSNorm                  ← DRAM
//   LM Head projection             ← DRAM
//   Sampling
//     │
//     ▼
//   Next Token

// MARK: - KV Cache

/// Key-Value cache for efficient multi-turn attention.
///
/// Storage: [seqLen × headDim] per head, pre-allocated to maxSeqLen.
final class KVCache: @unchecked Sendable {

    let numLayers: Int
    let numKVHeads: Int
    let headDim: Int
    let maxSeqLen: Int

    private let keyData: UnsafeMutablePointer<Float>    // [layers × maxSeqLen × numKVHeads × headDim]
    private let valueData: UnsafeMutablePointer<Float>  // [layers × maxSeqLen × numKVHeads × headDim]
    private(set) var usedSeqLen: Int = 0

    init(numLayers: Int, numKVHeads: Int, headDim: Int, maxSeqLen: Int) {
        self.numLayers = numLayers
        self.numKVHeads = numKVHeads
        self.headDim = headDim
        self.maxSeqLen = maxSeqLen

        let total = numLayers * maxSeqLen * numKVHeads * headDim
        keyData = UnsafeMutablePointer<Float>.allocate(capacity: total)
        valueData = UnsafeMutablePointer<Float>.allocate(capacity: total)
        keyData.initialize(repeating: 0, count: total)
        valueData.initialize(repeating: 0, count: total)
    }

    deinit {
        keyData.deallocate()
        valueData.deallocate()
    }

    /// Pointer to key data for (layer, seqPos, head).
    func keyPtr(layer: Int, seqPos: Int, head: Int) -> UnsafeMutablePointer<Float> {
        let offset = ((layer * maxSeqLen + seqPos) * numKVHeads + head) * headDim
        return keyData + offset
    }

    /// Pointer to all key vectors for a head in a given layer (seqLen entries).
    /// Returns [usedSeqLen × headDim] contiguous.
    func keysForLayer(layer: Int, head: Int) -> UnsafePointer<Float> {
        // We need a contiguous [seqLen × headDim] view.
        // Our layout is [layer × seqLen × numKVHeads × headDim], so head is interleaved.
        // For efficiency, provide a strided access — callers handle stride.
        let offset = (layer * maxSeqLen + 0) * numKVHeads * headDim + head * headDim
        return UnsafePointer(keyData + offset)
    }

    func valuePtr(layer: Int, seqPos: Int, head: Int) -> UnsafeMutablePointer<Float> {
        let offset = ((layer * maxSeqLen + seqPos) * numKVHeads + head) * headDim
        return valueData + offset
    }

    /// Append current token's K, V to the cache.
    func append(
        layer: Int,
        keyVec: UnsafePointer<Float>,     // [numKVHeads × headDim]
        valueVec: UnsafePointer<Float>    // [numKVHeads × headDim]
    ) {
        let pos = usedSeqLen
        for head in 0..<numKVHeads {
            let src = keyVec + head * headDim
            let dst = keyPtr(layer: layer, seqPos: pos, head: head)
            cblas_scopy(Int32(headDim), src, 1, dst, 1)
        }
        for head in 0..<numKVHeads {
            let src = valueVec + head * headDim
            let dst = valuePtr(layer: layer, seqPos: pos, head: head)
            cblas_scopy(Int32(headDim), src, 1, dst, 1)
        }
    }

    func incrementSeqLen() {
        usedSeqLen += 1
    }

    func reset() {
        usedSeqLen = 0
    }
}

// MARK: - Flash Inference Stats

/// Per-token generation statistics.
struct FlashTokenStats: Sendable {
    var totalFlashLoadBytes: Int64 = 0
    var totalCacheHits: Int = 0
    var totalCacheMisses: Int = 0
    var predictedNeuronsCount: Int = 0
    var flashLoadTimeNs: UInt64 = 0
    var computeTimeNs: UInt64 = 0

    var flashBandwidthGBps: Double {
        let secs = Double(flashLoadTimeNs) / 1e9
        guard secs > 0 else { return 0 }
        return Double(totalFlashLoadBytes) / secs / 1e9
    }
}

// MARK: - Flash Inference Engine

/// Complete transformer inference engine with flash-loaded FFN weights.
final class FlashInferenceEngine: @unchecked Sendable {

    // MARK: - Properties

    let config: FlashModelConfig
    private let predictorManager: SparsityPredictorManager

    // Flash I/O and caching (internal for metrics reporting)
    let cacheManager: FlashCacheManager
    let store: FlashWeightStore

    // DRAM-resident weights
    private let globalWeights: GlobalWeights
    private let attentionWeights: [AttentionWeights]   // One per layer

    // KV cache
    private let kvCache: KVCache

    // Working buffers (allocated once, reused each token)
    private let hiddenBuf: UnsafeMutablePointer<Float>      // [hiddenSize]
    private let residualBuf: UnsafeMutablePointer<Float>    // [hiddenSize]
    private let normBuf: UnsafeMutablePointer<Float>        // [hiddenSize]
    private let qBuf: UnsafeMutablePointer<Float>           // [numHeads × headDim]
    private let kBuf: UnsafeMutablePointer<Float>           // [numKVHeads × headDim]
    private let vBuf: UnsafeMutablePointer<Float>           // [numKVHeads × headDim]
    private let attnOutBuf: UnsafeMutablePointer<Float>     // [numHeads × headDim]
    private let ffnUpBuf: UnsafeMutablePointer<Float>       // [intermediateSize]
    private let ffnGateBuf: UnsafeMutablePointer<Float>     // [intermediateSize]
    private let ffnDownBuf: UnsafeMutablePointer<Float>     // [hiddenSize]
    private let logitsBuf: UnsafeMutablePointer<Float>      // [vocabSize]

    // Per-head attention scratch
    private let attnScoresBuf: UnsafeMutablePointer<Float>  // [maxSeqLen]
    private let attnPerHeadBuf: UnsafeMutablePointer<Float> // [headDim]

    // MARK: - Initialization

    init(
        config: FlashModelConfig,
        store: FlashWeightStore,
        cacheManager: FlashCacheManager,
        predictorManager: SparsityPredictorManager,
        globalWeights: GlobalWeights,
        attentionWeights: [AttentionWeights]
    ) {
        self.config = config
        self.store = store
        self.cacheManager = cacheManager
        self.predictorManager = predictorManager
        self.globalWeights = globalWeights
        self.attentionWeights = attentionWeights

        let h = config.hiddenSize
        let nh = config.numAttentionHeads
        let nkv = config.numKeyValueHeads
        let hd = config.headDim
        let intermediate = config.intermediateSize
        let vocab = config.vocabSize
        let maxSeq = config.maxPositionEmbeddings

        // KV cache
        kvCache = KVCache(numLayers: config.numHiddenLayers, numKVHeads: nkv, headDim: hd, maxSeqLen: maxSeq)

        // Working buffers
        hiddenBuf    = UnsafeMutablePointer<Float>.allocate(capacity: h)
        residualBuf  = UnsafeMutablePointer<Float>.allocate(capacity: h)
        normBuf      = UnsafeMutablePointer<Float>.allocate(capacity: h)
        qBuf         = UnsafeMutablePointer<Float>.allocate(capacity: nh * hd)
        kBuf         = UnsafeMutablePointer<Float>.allocate(capacity: nkv * hd)
        vBuf         = UnsafeMutablePointer<Float>.allocate(capacity: nkv * hd)
        attnOutBuf   = UnsafeMutablePointer<Float>.allocate(capacity: nh * hd)
        ffnUpBuf     = UnsafeMutablePointer<Float>.allocate(capacity: intermediate)
        ffnGateBuf   = UnsafeMutablePointer<Float>.allocate(capacity: intermediate)
        ffnDownBuf   = UnsafeMutablePointer<Float>.allocate(capacity: h)
        logitsBuf    = UnsafeMutablePointer<Float>.allocate(capacity: vocab)
        attnScoresBuf = UnsafeMutablePointer<Float>.allocate(capacity: maxSeq)
        attnPerHeadBuf = UnsafeMutablePointer<Float>.allocate(capacity: hd)

        // Initialize working buffers to zero
        hiddenBuf.initialize(repeating: 0, count: h)
        residualBuf.initialize(repeating: 0, count: h)
        normBuf.initialize(repeating: 0, count: h)
        qBuf.initialize(repeating: 0, count: nh * hd)
        kBuf.initialize(repeating: 0, count: nkv * hd)
        vBuf.initialize(repeating: 0, count: nkv * hd)
        attnOutBuf.initialize(repeating: 0, count: nh * hd)
        ffnUpBuf.initialize(repeating: 0, count: intermediate)
        ffnGateBuf.initialize(repeating: 0, count: intermediate)
        ffnDownBuf.initialize(repeating: 0, count: h)
        logitsBuf.initialize(repeating: 0, count: vocab)
        attnScoresBuf.initialize(repeating: 0, count: maxSeq)
        attnPerHeadBuf.initialize(repeating: 0, count: hd)
    }

    deinit {
        hiddenBuf.deallocate()
        residualBuf.deallocate()
        normBuf.deallocate()
        qBuf.deallocate()
        kBuf.deallocate()
        vBuf.deallocate()
        attnOutBuf.deallocate()
        ffnUpBuf.deallocate()
        ffnGateBuf.deallocate()
        ffnDownBuf.deallocate()
        logitsBuf.deallocate()
        attnScoresBuf.deallocate()
        attnPerHeadBuf.deallocate()
    }

    // MARK: - Inference

    /// Prefill: process the entire prompt, return last hidden state and set up KV cache.
    /// For flash inference, we still need to compute attention over the whole sequence.
    func prefill(tokenIds: [Int32]) throws -> FlashTokenStats {
        kvCache.reset()
        var stats = FlashTokenStats()
        for (pos, tokenId) in tokenIds.enumerated() {
            let s = try forwardToken(tokenId: tokenId, position: pos, computeLogits: pos == tokenIds.count - 1)
            stats.totalFlashLoadBytes += s.totalFlashLoadBytes
            stats.totalCacheHits += s.totalCacheHits
            stats.totalCacheMisses += s.totalCacheMisses
        }
        return stats
    }

    /// Decode: generate one new token given the last token.
    /// Returns (next_token_id, stats).
    func decodeStep(
        lastTokenId: Int32,
        position: Int,
        temperature: Float,
        topK: Int,
        topP: Float
    ) throws -> (Int32, FlashTokenStats) {
        let stats = try forwardToken(tokenId: lastTokenId, position: position, computeLogits: true)

        // Sample
        let nextToken = sampleToken(
            logits: logitsBuf,
            vocabSize: config.vocabSize,
            temperature: temperature,
            topK: topK,
            topP: topP
        )
        return (Int32(nextToken), stats)
    }

    /// Reset state for new conversation (clear KV cache and neuron caches).
    func resetState() {
        kvCache.reset()
        // Note: neuron caches retain their data — they'll be naturally evicted
        // as the sliding window advances. Could force-clear for hard reset:
        // cacheManager.layerCaches.forEach { $0.clearAll() }
    }

    // MARK: - Full Forward Pass for One Token

    private func forwardToken(
        tokenId: Int32,
        position: Int,
        computeLogits: Bool
    ) throws -> FlashTokenStats {
        var stats = FlashTokenStats()
        let h = config.hiddenSize
        let nh = config.numAttentionHeads
        let nkv = config.numKeyValueHeads
        let hd = config.headDim

        // 1. Embedding lookup: hidden = embedding[tokenId]
        let embOffset = Int(tokenId) * h
        let embedding = globalWeights.tokenEmbedding
        cblas_scopy(Int32(h), embedding.withUnsafeBufferPointer { $0.baseAddress! + embOffset }, 1, hiddenBuf, 1)

        // Copy to residual
        cblas_scopy(Int32(h), hiddenBuf, 1, residualBuf, 1)

        // 2. Process each transformer layer
        for layerIdx in 0..<config.numHiddenLayers {
            let attnW = attentionWeights[layerIdx]
            let layer = config.sections.layers[layerIdx]

            // ── Attention ──────────────────────────────────────────────────

            // a. Input RMSNorm
            attnW.inputNorm.withUnsafeBufferPointer { normW in
                rmsNorm(x: residualBuf, weight: normW.baseAddress!, output: normBuf,
                        size: h, eps: config.rmsNormEps)
            }

            // b. Q, K, V projections
            attnW.qProj.withUnsafeBufferPointer { qW in
                matVecMul(A: qW.baseAddress!, rows: nh * hd, cols: h, x: normBuf, y: qBuf)
            }
            attnW.kProj.withUnsafeBufferPointer { kW in
                matVecMul(A: kW.baseAddress!, rows: nkv * hd, cols: h, x: normBuf, y: kBuf)
            }
            attnW.vProj.withUnsafeBufferPointer { vW in
                matVecMul(A: vW.baseAddress!, rows: nkv * hd, cols: h, x: normBuf, y: vBuf)
            }

            // c. Apply RoPE to Q and K
            applyRoPE(x: qBuf, numHeads: nh, headDim: hd, position: position, theta: config.ropeTheta)
            applyRoPE(x: kBuf, numHeads: nkv, headDim: hd, position: position, theta: config.ropeTheta)

            // d. Append K, V to cache
            kvCache.append(layer: layerIdx, keyVec: kBuf, valueVec: vBuf)
            kvCache.incrementSeqLen()
            let seqLen = kvCache.usedSeqLen

            // e. Multi-head attention
            var zero: Float = 0
            vDSP_vfill(&zero, attnOutBuf, 1, vDSP_Length(nh * hd))

            for head in 0..<nh {
                let kvHead = head * nkv / nh  // GQA: map Q head to KV head
                let q_h = qBuf + head * hd
                let out_h = attnOutBuf + head * hd

                // Build contiguous K and V arrays for this head's sequence
                var kFlat = [Float](repeating: 0, count: seqLen * hd)
                var vFlat = [Float](repeating: 0, count: seqLen * hd)
                kFlat.withUnsafeMutableBufferPointer { kFlatBuf in
                    vFlat.withUnsafeMutableBufferPointer { vFlatBuf in
                        for pos in 0..<seqLen {
                            let kSrc = kvCache.keyPtr(layer: layerIdx, seqPos: pos, head: kvHead)
                            let vSrc = kvCache.valuePtr(layer: layerIdx, seqPos: pos, head: kvHead)
                            cblas_scopy(Int32(hd), kSrc, 1, kFlatBuf.baseAddress! + pos * hd, 1)
                            cblas_scopy(Int32(hd), vSrc, 1, vFlatBuf.baseAddress! + pos * hd, 1)
                        }
                    }
                }

                kFlat.withUnsafeBufferPointer { kPtr in
                    vFlat.withUnsafeBufferPointer { vPtr in
                        scaledDotProductAttention(
                            q: q_h,
                            kCache: kPtr.baseAddress!,
                            vCache: vPtr.baseAddress!,
                            seqLen: seqLen,
                            headDim: hd,
                            output: out_h
                        )
                    }
                }
            }

            // f. Output projection: hidden = attnOut @ O_proj
            attnW.oProj.withUnsafeBufferPointer { oW in
                matVecMul(A: oW.baseAddress!, rows: h, cols: nh * hd, x: attnOutBuf, y: hiddenBuf)
            }

            // g. Residual connection: residual += hidden
            vectorAdd(hiddenBuf, to: residualBuf, count: h)

            // ── FFN (sparse, flash-loaded) ─────────────────────────────────

            // a. Post-attention RMSNorm
            attnW.postAttnNorm.withUnsafeBufferPointer { normW in
                rmsNorm(x: residualBuf, weight: normW.baseAddress!, output: normBuf,
                        size: h, eps: config.rmsNormEps)
            }

            // b. Predict active neurons via sparsity predictor
            let predictedIndices = predictorManager.predictActiveNeurons(
                layer: layerIdx,
                attentionOutput: normBuf
            )
            stats.predictedNeuronsCount += predictedIndices.count

            // c. Load neurons: check cache first, then flash for misses
            let startFlashNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let (cacheHits, cacheMisses) = cacheManager[layerIdx].getBatch(predictedIndices)
            stats.totalCacheHits += cacheHits.count
            stats.totalCacheMisses += cacheMisses.count

            var loadedNeuronData: [(Int, CachedNeuronView)] = cacheHits

            if !cacheMisses.isEmpty {
                // Load misses from flash (parallel)
                let missData = try store.loadNeurons(layer: layerIdx, neuronIndices: cacheMisses)
                stats.totalFlashLoadBytes += Int64(cacheMisses.count * layer.ffnNeuronByteSize)

                // Insert into cache
                let toInsert = zip(cacheMisses, missData).map { ($0, $1) }
                cacheManager[layerIdx].insertBatch(neurons: toInsert)

                // Get views for newly loaded neurons
                for missIdx in cacheMisses {
                    if let view = cacheManager[layerIdx].get(missIdx) {
                        loadedNeuronData.append((missIdx, view))
                    }
                }
            }

            let endFlashNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            stats.flashLoadTimeNs += endFlashNs - startFlashNs

            // d. Sparse FFN forward pass
            var ffnOutZero: Float = 0
            vDSP_vfill(&ffnOutZero, ffnDownBuf, 1, vDSP_Length(h))

            if layer.ffnUseGate {
                // SwiGLU FFN: out = SiLU(x @ W_gate_j) * (x @ W_up_j)
                // Then: output += out_j * down_row_j
                for (_, view) in loadedNeuronData {
                    let upVal = cblas_sdot(Int32(h), normBuf, 1, view.upCol, 1)
                    let gateVal = view.gateCol.map { cblas_sdot(Int32(h), normBuf, 1, $0, 1) } ?? upVal

                    // SiLU(gateVal) * upVal
                    let sigmoidGate = 1.0 / (1.0 + expf(-gateVal))
                    let siluGate = gateVal * sigmoidGate
                    let activated = siluGate * upVal

                    // Accumulate: ffnDown += activated * down_row
                    cblas_saxpy(Int32(h), activated, view.downRow, 1, ffnDownBuf, 1)
                }
            } else {
                // Standard FFN: out = ReLU(x @ W_up_j) * (x @ W_down_j)
                for (_, view) in loadedNeuronData {
                    var upVal = cblas_sdot(Int32(h), normBuf, 1, view.upCol, 1)
                    upVal = max(0, upVal)  // ReLU
                    if upVal == 0 { continue }  // Sparse: skip zero activations
                    cblas_saxpy(Int32(h), upVal, view.downRow, 1, ffnDownBuf, 1)
                }
            }

            // e. Residual connection: residual += ffnDown
            vectorAdd(ffnDownBuf, to: residualBuf, count: h)

            // f. Advance sliding window cache
            let activeSet = Set(loadedNeuronData.map { $0.0 })
            cacheManager[layerIdx].advanceWindow(activeNeurons: activeSet)

            // g. Prefetch next layer's neurons in background
            if layerIdx + 1 < config.numHiddenLayers {
                store.prefetchNeurons(layer: layerIdx + 1, neuronIndices: predictedIndices)
            }
        }

        // 3. Final RMSNorm
        globalWeights.norm.withUnsafeBufferPointer { normW in
            rmsNorm(x: residualBuf, weight: normW.baseAddress!, output: normBuf,
                    size: config.hiddenSize, eps: config.rmsNormEps)
        }

        // 4. LM Head → logits (only needed for last token in prefill, or decode)
        if computeLogits {
            let lmHead = globalWeights.lmHead ?? globalWeights.tokenEmbedding
            lmHead.withUnsafeBufferPointer { lmW in
                matVecMul(
                    A: lmW.baseAddress!, rows: config.vocabSize, cols: config.hiddenSize,
                    x: normBuf, y: logitsBuf
                )
            }
        }

        return stats
    }
}

// MARK: - Engine Factory

extension FlashInferenceEngine {

    /// Build a complete inference engine from a FlashPack model file.
    ///
    /// Loading sequence:
    ///   1. Parse header (fast)
    ///   2. Load all attention weights into DRAM (sequential, one-time)
    ///   3. Load global weights (embedding, norm, LM head)
    ///   4. Initialize neuron caches (empty, will populate on-demand)
    ///   5. Load predictor weights (small, fast)
    ///   6. Optionally pre-warm caches with high-importance neurons
    ///
    /// Progress is reported via `onProgress` callback (0.0 → 1.0).
    static func load(
        path: String,
        onProgress: @escaping (Double) -> Void
    ) async throws -> FlashInferenceEngine {

        onProgress(0.0)

        // 1. Parse header
        let (config, _) = try FlashPackReader.readHeader(path: path)
        onProgress(0.05)

        // 2. Open weight store
        let store = try FlashWeightStore(path: path, config: config)
        onProgress(0.10)

        // 3. Load global weights
        let globalWeights = try store.loadGlobalWeights()
        onProgress(0.20)

        // 4. Load attention weights for all layers (DRAM-resident)
        var attentionWeights: [AttentionWeights] = []
        for layerIdx in 0..<config.numHiddenLayers {
            let weights = try store.loadAttentionWeights(layer: layerIdx)
            attentionWeights.append(weights)
            let progress = 0.20 + 0.50 * Double(layerIdx + 1) / Double(config.numHiddenLayers)
            onProgress(progress)
        }

        // 5. Initialize neuron cache manager (empty caches)
        let cacheManager = FlashCacheManager(config: config)
        onProgress(0.72)

        // 6. Load predictor weights
        let predictorManager = try await SparsityPredictorManager.build(
            config: config,
            store: store
        )
        onProgress(0.85)

        // 7. Pre-warm caches with high-importance neurons (optional)
        for layerIdx in 0..<config.numHiddenLayers {
            if let importanceScores = try? store.loadNeuronImportance(layer: layerIdx) {
                let maxNeuronsPerLayer = Int(Double(config.intermediateSize) * config.maxCacheFraction)
                let warmupN = min(maxNeuronsPerLayer / 4, 128)  // Warm up 25% of capacity
                try await cacheManager[layerIdx].prewarmWithImportant(
                    importanceScores: importanceScores,
                    store: store,
                    layer: layerIdx,
                    topN: warmupN
                )
            }
        }
        onProgress(1.0)

        return FlashInferenceEngine(
            config: config,
            store: store,
            cacheManager: cacheManager,
            predictorManager: predictorManager,
            globalWeights: globalWeights,
            attentionWeights: attentionWeights
        )
    }
}

// MARK: - POSIX clock helper

private func clock_gettime_nsec_np(_ clock: clockid_t) -> UInt64 {
    var ts = timespec()
    clock_gettime(clock, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}
