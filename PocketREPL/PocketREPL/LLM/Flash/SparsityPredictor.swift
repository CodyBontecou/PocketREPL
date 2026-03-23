import Foundation
import Accelerate

// MARK: - Sparsity Predictor
//
// Implements the low-rank activation predictor from Section 3.1 of
// Apple's "LLM in a Flash" paper.
//
// MOTIVATION:
// ───────────
// The key bottleneck for flash loading is knowing WHICH neurons to load
// BEFORE you need them. Without a predictor, you'd have to load all neurons
// to run the FFN, defeating the purpose.
//
// APPROACH:
// ─────────
// For each FFN layer, train a small low-rank linear model:
//
//   predictor_output = sigmoid(attention_output @ W_in @ W_out)
//
// where:
//   attention_output: [hidden_size] — the layer's attention output
//   W_in:  [hidden_size, rank]     — low-rank down-projection
//   W_out: [rank, intermediate_size]  — low-rank up-projection
//
// W_in and W_out together have only (hidden_size + intermediate_size) × rank
// parameters vs. the full hidden_size × intermediate_size FFN matrix.
//
// For OPT-6.7B with rank=128 and hidden_size=4096, intermediate_size=16384:
//   Predictor params = (4096 + 16384) × 128 ≈ 2.6M params
//   vs. FFN params   = 4096 × 16384 ≈ 67M params
//   ≈ 3.9% overhead in params and FLOPs (within paper's 2–5% target)
//
// TRAINING (offline, not in this file):
// ─────────────────────────────────────
// Train predictor by:
//   1. Run the full model on a subset of C4 dataset (~10k samples)
//   2. For each layer, collect (attention_output, ground_truth_activation_mask)
//   3. Train W_in, W_out to minimise balanced BCE loss (equal weight on pos/neg)
//   4. Save weights to FlashPack file alongside the main model
//
// INFERENCE (this file):
// ───────────────────────
// Given current token's attention output, run a 2-matmul forward pass
// to predict which neurons will activate, then load only those from cache/flash.

// MARK: - Prediction Result

/// Output from the sparsity predictor for one layer.
struct PredictionResult: Sendable {
    /// Sorted indices of predicted active neurons (ascending).
    let predictedNeuronIndices: [Int]
    /// Confidence scores (sigmoid outputs) for predicted neurons.
    let confidenceScores: [Float]
    /// Total FFN neurons for this layer.
    let totalNeurons: Int
    /// Sparsity fraction: 1 - (predicted / total).
    var sparsity: Double {
        1.0 - Double(predictedNeuronIndices.count) / Double(max(1, totalNeurons))
    }
}

// MARK: - Layer Predictor

/// Single-layer low-rank sparsity predictor.
/// Stateless after init — safe to call from any thread.
struct LayerPredictor: Sendable {

    let layerIndex: Int
    let hiddenSize: Int
    let intermediateSize: Int
    let rank: Int
    let threshold: Float
    let safetyBuffer: Int

    // W_in: [hiddenSize × rank] row-major
    private let wIn: [Float]
    // W_out: [rank × intermediateSize] row-major
    private let wOut: [Float]

    // Intermediate buffer size
    private let rankBuffer: Int   // = rank

    init(
        layerIndex: Int,
        weights: PredictorWeights,
        hiddenSize: Int,
        intermediateSize: Int,
        threshold: Float,
        safetyBuffer: Int
    ) {
        self.layerIndex = layerIndex
        self.hiddenSize = hiddenSize
        self.intermediateSize = intermediateSize
        self.rank = weights.rank
        self.threshold = threshold
        self.safetyBuffer = safetyBuffer
        self.wIn = weights.wIn
        self.wOut = weights.wOut
        self.rankBuffer = weights.rank
    }

    /// Run the predictor on the current attention output.
    ///
    /// - Parameter attentionOutput: Float32 array of shape [hiddenSize].
    /// - Returns: Predicted neuron indices and confidence scores.
    func predict(attentionOutput: UnsafePointer<Float>) -> PredictionResult {
        // Step 1: hidden = attentionOutput @ W_in   [hiddenSize] × [hiddenSize, rank] → [rank]
        var hidden = [Float](repeating: 0, count: rank)
        wIn.withUnsafeBufferPointer { wInPtr in
            cblas_sgemv(
                CblasRowMajor, CblasTrans,         // Transpose: input is row, W_in cols → rank
                Int32(hiddenSize), Int32(rank),    // M=hidden, N=rank
                1.0,
                wInPtr.baseAddress!, Int32(rank),  // A=W_in, lda=rank
                attentionOutput, 1,                // x=attentionOutput
                0.0,
                &hidden, 1                         // y=hidden
            )
        }

        // Step 2: logits = hidden @ W_out   [rank] × [rank, intermediateSize] → [intermediateSize]
        var logits = [Float](repeating: 0, count: intermediateSize)
        wOut.withUnsafeBufferPointer { wOutPtr in
            cblas_sgemv(
                CblasRowMajor, CblasTrans,
                Int32(rank), Int32(intermediateSize),
                1.0,
                wOutPtr.baseAddress!, Int32(intermediateSize),
                &hidden, 1,
                0.0,
                &logits, 1
            )
        }

        // Step 3: sigmoid(logits) → probabilities in [0, 1]
        var sigmoidOut = [Float](repeating: 0, count: intermediateSize)
        var negLogits = logits.map { -$0 }
        var ones = [Float](repeating: 1.0, count: intermediateSize)
        var expNeg = [Float](repeating: 0, count: intermediateSize)

        // exp(-logits)
        var n = Int32(intermediateSize)
        vvexpf(&expNeg, &negLogits, &n)

        // sigmoid = 1 / (1 + exp(-logit))
        vDSP_vadd(ones, 1, expNeg, 1, &sigmoidOut, 1, vDSP_Length(intermediateSize))
        // Invert: 1 / (1 + exp(-x))
        var recip = [Float](repeating: 0, count: intermediateSize)
        vDSP_svdiv(&ones, &sigmoidOut, &recip, vDSP_Length(intermediateSize))

        // Step 4: Threshold → indices above threshold are predicted active
        var indices: [Int] = []
        var scores: [Float] = []
        indices.reserveCapacity(intermediateSize / 10)  // Assume ~10% active
        scores.reserveCapacity(intermediateSize / 10)

        for i in 0..<intermediateSize {
            if recip[i] >= threshold {
                indices.append(i)
                scores.append(recip[i])
            }
        }

        // Step 5: Safety buffer — include top `safetyBuffer` additional neurons
        // by probability, even if below threshold (reduces false negatives)
        if safetyBuffer > 0 {
            let indicesSet = Set(indices)
            var extras: [(Int, Float)] = []
            for i in 0..<intermediateSize {
                if !indicesSet.contains(i) {
                    extras.append((i, recip[i]))
                }
            }
            extras.sort { $0.1 > $1.1 }
            for (idx, score) in extras.prefix(safetyBuffer) {
                indices.append(idx)
                scores.append(score)
            }
            // Re-sort by index
            let combined = zip(indices, scores).sorted { $0.0 < $1.0 }
            return PredictionResult(
                predictedNeuronIndices: combined.map { $0.0 },
                confidenceScores: combined.map { $0.1 },
                totalNeurons: intermediateSize
            )
        }

        return PredictionResult(
            predictedNeuronIndices: indices.sorted(),
            confidenceScores: scores,
            totalNeurons: intermediateSize
        )
    }
}

// MARK: - Model-Level Predictor Manager

/// Manages predictors for all layers. Falls back gracefully when predictor
/// weights are not available.
final class SparsityPredictorManager: Sendable {

    enum Strategy: Sendable {
        /// Use trained low-rank predictors (best quality, requires offline training).
        case lowRankPredictor
        /// Always load the top-N globally important neurons (no predictor needed).
        case importanceBased(topFraction: Double)
        /// Load a fixed fraction of neurons deterministically (baseline comparison).
        case fixedFraction(Double)
        /// Load all neurons (dense baseline; equivalent to normal inference).
        case dense
    }

    private let predictors: [LayerPredictor?]       // nil = no predictor for that layer
    private let importanceScores: [[Float]?]          // per-layer global importance
    private let strategy: Strategy
    private let intermediateSize: Int
    private let config: FlashModelConfig

    init(
        config: FlashModelConfig,
        predictors: [LayerPredictor?],
        importanceScores: [[Float]?],
        strategy: Strategy
    ) {
        self.config = config
        self.predictors = predictors
        self.importanceScores = importanceScores
        self.strategy = strategy
        self.intermediateSize = config.intermediateSize
    }

    /// Predict which neurons to load for the given layer and attention output.
    ///
    /// - Returns: Set of neuron indices to load from cache or flash.
    func predictActiveNeurons(
        layer: Int,
        attentionOutput: UnsafePointer<Float>
    ) -> [Int] {
        switch strategy {
        case .lowRankPredictor:
            guard let predictor = predictors[safe: layer] ?? nil else {
                return densePrediction()
            }
            let result = predictor.predict(attentionOutput: attentionOutput)
            return result.predictedNeuronIndices

        case .importanceBased(let fraction):
            if let scores = importanceScores[safe: layer] ?? nil {
                let topN = Int(Double(intermediateSize) * fraction)
                return topNIndices(scores: scores, n: topN)
            }
            return fixedFractionPrediction(fraction)

        case .fixedFraction(let fraction):
            return fixedFractionPrediction(fraction)

        case .dense:
            return densePrediction()
        }
    }

    // MARK: - Private

    private func densePrediction() -> [Int] {
        return Array(0..<intermediateSize)
    }

    private func fixedFractionPrediction(_ fraction: Double) -> [Int] {
        let count = Int(Double(intermediateSize) * fraction)
        // Return evenly spaced indices as a simple heuristic
        let step = max(1, intermediateSize / count)
        return stride(from: 0, to: intermediateSize, by: step).map { $0 }
    }

    private func topNIndices(scores: [Float], n: Int) -> [Int] {
        let indexed = scores.enumerated().sorted { $0.element > $1.element }
        return Array(indexed.prefix(n).map { $0.offset }.sorted())
    }
}

// MARK: - Predictor Factory

extension SparsityPredictorManager {

    /// Build a predictor manager from a loaded model.
    static func build(
        config: FlashModelConfig,
        store: FlashWeightStore
    ) async throws -> SparsityPredictorManager {

        var predictors: [LayerPredictor?] = []
        var importanceScores: [[Float]?] = []

        for layerIdx in 0..<config.numHiddenLayers {
            // Try to load predictor weights
            if let weights = try? store.loadPredictorWeights(layer: layerIdx) {
                let predictor = LayerPredictor(
                    layerIndex: layerIdx,
                    weights: weights,
                    hiddenSize: config.hiddenSize,
                    intermediateSize: config.intermediateSize,
                    threshold: config.predictorThreshold,
                    safetyBuffer: config.predictorSafetyBuffer
                )
                predictors.append(predictor)
            } else {
                predictors.append(nil)
            }

            // Try to load importance scores
            if let scores = try? store.loadNeuronImportance(layer: layerIdx) {
                importanceScores.append(scores)
            } else {
                importanceScores.append(nil)
            }
        }

        // Choose strategy based on what's available
        let hasPredictors = predictors.contains { $0 != nil }
        let hasImportance = importanceScores.contains { $0 != nil }

        let strategy: Strategy
        if hasPredictors {
            strategy = .lowRankPredictor
        } else if hasImportance {
            // Default to top 10% based on importance (paper: ~3-5x actual sparsity rate)
            strategy = .importanceBased(topFraction: 0.10)
        } else {
            // Fallback: load 10% fixed fraction (naive sparsity assumption)
            strategy = .fixedFraction(0.10)
        }

        return SparsityPredictorManager(
            config: config,
            predictors: predictors,
            importanceScores: importanceScores,
            strategy: strategy
        )
    }
}

// MARK: - Array safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}

// MARK: - vDSP division helper

private func vDSP_svdiv(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>,
                         _ c: UnsafeMutablePointer<Float>, _ n: vDSP_Length) {
    // c[i] = a[i] / b[i]
    vDSP_vdiv(b, 1, a, 1, c, 1, n)
}
