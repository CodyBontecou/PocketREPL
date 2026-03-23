import Foundation
import Accelerate

// MARK: - Flash Math
//
// Hardware-accelerated transformer math using Apple's Accelerate framework.
//
// All operations target batch size = 1 (single token inference), which is the
// core use case for interactive on-device generation.
//
// Accelerate framework provides:
//   - BLAS: cblas_sgemv for matrix-vector products (the hot path)
//   - vDSP: elementwise operations (add, mul, exp, sqrt, etc.)
//   - BNNS: higher-level neural network ops (we use vDSP directly for control)
//
// Float32 is used throughout for computation.
// Float16 weights are converted during load (see FlashWeightStore).

// MARK: - RMSNorm

/// RMSNorm(x, weight) — used in LLaMA, Mistral, Qwen, etc.
///
/// y_i = (x_i / RMS(x)) * weight_i
/// RMS(x) = sqrt(mean(x²) + eps)
///
/// - Parameters:
///   - x:       Input [size] (in-place output)
///   - weight:  Scale weight [size]
///   - output:  Output buffer [size]
///   - size:    Vector length
///   - eps:     Small constant for numerical stability (default: 1e-5)
func rmsNorm(
    x: UnsafePointer<Float>,
    weight: UnsafePointer<Float>,
    output: UnsafeMutablePointer<Float>,
    size: Int,
    eps: Float = 1e-5
) {
    // Compute mean(x²)
    var sumSq: Float = 0
    vDSP_dotpr(x, 1, x, 1, &sumSq, vDSP_Length(size))
    let meanSq = sumSq / Float(size)

    // RMS = sqrt(mean(x²) + eps)
    let rms = sqrtf(meanSq + eps)

    // output = x / rms
    var invRms = 1.0 / rms
    vDSP_vsmul(x, 1, &invRms, output, 1, vDSP_Length(size))

    // output = output * weight  (elementwise)
    vDSP_vmul(output, 1, weight, 1, output, 1, vDSP_Length(size))
}

// MARK: - LayerNorm

/// LayerNorm(x, weight, bias) — used in GPT/OPT/Falcon.
///
/// y = ((x - mean) / std) * weight + bias
func layerNorm(
    x: UnsafePointer<Float>,
    weight: UnsafePointer<Float>,
    bias: UnsafePointer<Float>?,
    output: UnsafeMutablePointer<Float>,
    size: Int,
    eps: Float = 1e-5
) {
    // Compute mean
    var mean: Float = 0
    vDSP_meanv(x, 1, &mean, vDSP_Length(size))

    // output = x - mean
    var negMean = -mean
    vDSP_vsadd(x, 1, &negMean, output, 1, vDSP_Length(size))

    // Compute variance = mean(output²)
    var sumSq: Float = 0
    vDSP_dotpr(output, 1, output, 1, &sumSq, vDSP_Length(size))
    let variance = sumSq / Float(size)

    // Normalise
    var invStd = 1.0 / sqrtf(variance + eps)
    vDSP_vsmul(output, 1, &invStd, output, 1, vDSP_Length(size))

    // Scale
    vDSP_vmul(output, 1, weight, 1, output, 1, vDSP_Length(size))

    // Bias
    if let bias = bias {
        vDSP_vadd(output, 1, bias, 1, output, 1, vDSP_Length(size))
    }
}

// MARK: - Activation Functions

/// SiLU(x) = x * sigmoid(x)  — used in LLaMA's SwiGLU FFN.
func siluInPlace(_ x: UnsafeMutablePointer<Float>, count: Int) {
    // sigmoid(x) = 1 / (1 + exp(-x))
    var neg = (0..<count).map { -x[$0] }
    var expNeg = [Float](repeating: 0, count: count)
    var n = Int32(count)
    vvexpf(&expNeg, &neg, &n)

    var ones = [Float](repeating: 1.0, count: count)
    var denom = [Float](repeating: 0, count: count)
    vDSP_vadd(ones, 1, expNeg, 1, &denom, 1, vDSP_Length(count))

    // x * sigmoid(x)
    for i in 0..<count {
        x[i] = x[i] * (1.0 / denom[i])
    }
}

/// SwiGLU: output = SiLU(gate) * up
///
/// Used in LLaMA's FFN: output = SiLU(x @ W_gate) * (x @ W_up) @ W_down
func swiGLU(
    gate: UnsafeMutablePointer<Float>,
    up: UnsafePointer<Float>,
    output: UnsafeMutablePointer<Float>,
    count: Int
) {
    // SiLU in-place on gate
    siluInPlace(gate, count: count)
    // elementwise multiply: output = gate * up
    vDSP_vmul(gate, 1, up, 1, output, 1, vDSP_Length(count))
}

/// ReLU²(x) = max(0, x)² — used in ProSparse-sparsified models.
func relu2InPlace(_ x: UnsafeMutablePointer<Float>, count: Int) {
    // Clamp negatives to zero
    var zero: Float = 0
    vDSP_vthres(x, 1, &zero, x, 1, vDSP_Length(count))
    // Square: x² = x * x
    vDSP_vsq(x, 1, x, 1, vDSP_Length(count))
}

/// Standard ReLU: max(0, x).
func reluInPlace(_ x: UnsafeMutablePointer<Float>, count: Int) {
    var zero: Float = 0
    vDSP_vthres(x, 1, &zero, x, 1, vDSP_Length(count))
}

// MARK: - Matrix-Vector Product (the hot path)

/// y = alpha * A @ x + beta * y
///
/// A: [rows × cols] row-major
/// x: [cols]
/// y: [rows]
@inline(__always)
func matVecMul(
    A: UnsafePointer<Float>, rows: Int, cols: Int,
    x: UnsafePointer<Float>,
    y: UnsafeMutablePointer<Float>,
    alpha: Float = 1.0, beta: Float = 0.0
) {
    cblas_sgemv(
        CblasRowMajor, CblasNoTrans,
        Int32(rows), Int32(cols),
        alpha, A, Int32(cols),
        x, 1,
        beta, y, 1
    )
}

/// y = alpha * Aᵀ @ x + beta * y  (transpose)
@inline(__always)
func matVecMulT(
    A: UnsafePointer<Float>, rows: Int, cols: Int,
    x: UnsafePointer<Float>,
    y: UnsafeMutablePointer<Float>,
    alpha: Float = 1.0, beta: Float = 0.0
) {
    cblas_sgemv(
        CblasRowMajor, CblasTrans,
        Int32(rows), Int32(cols),
        alpha, A, Int32(cols),
        x, 1,
        beta, y, 1
    )
}

// MARK: - Sparse Matrix-Vector Product (for flash-loaded neurons)

/// Compute y += x[neuronIdx] * col_vec  for each loaded neuron.
///
/// This is the "down-projection" step in sparse FFN:
///   output += intermediate[j] * down_row_j    for each active neuron j
///
/// - Parameters:
///   - neuronValues:  Float array of active neuron values [activeCount]
///   - neuronRows:    For each active neuron, its row in down-proj [activeCount][hiddenSize]
///   - output:        Accumulator [hiddenSize]
///   - hiddenSize:    Size of output vector
///   - activeCount:   Number of active neurons
func sparseDownProjection(
    neuronValues: UnsafePointer<Float>,
    neuronRows: UnsafePointer<UnsafePointer<Float>?>,
    output: UnsafeMutablePointer<Float>,
    hiddenSize: Int,
    activeCount: Int
) {
    for i in 0..<activeCount {
        guard let row = neuronRows[i] else { continue }
        let scale = neuronValues[i]
        cblas_saxpy(Int32(hiddenSize), scale, row, 1, output, 1)
    }
}

/// Compute activations for selected neurons of the up-projection.
///
/// up_j = dot(x, up_col_j)  for each active neuron j
///
/// - Returns: Array of up-projection values for each selected neuron.
func sparseUpProjection(
    x: UnsafePointer<Float>,
    neuronCols: UnsafePointer<UnsafePointer<Float>?>,
    hiddenSize: Int,
    activeCount: Int
) -> [Float] {
    var upValues = [Float](repeating: 0, count: activeCount)
    for i in 0..<activeCount {
        guard let col = neuronCols[i] else { continue }
        upValues[i] = cblas_sdot(Int32(hiddenSize), x, 1, col, 1)
    }
    return upValues
}

// MARK: - Softmax

/// Softmax in-place over a vector.
func softmaxInPlace(_ x: UnsafeMutablePointer<Float>, count: Int) {
    // Numerically stable: subtract max first
    var maxVal: Float = -.infinity
    vDSP_maxv(x, 1, &maxVal, vDSP_Length(count))

    var negMax = -maxVal
    vDSP_vsadd(x, 1, &negMax, x, 1, vDSP_Length(count))

    // exp(x)
    var n = Int32(count)
    vvexpf(x, x, &n)

    // sum
    var sum: Float = 0
    vDSP_sve(x, 1, &sum, vDSP_Length(count))

    // divide by sum
    var invSum = 1.0 / sum
    vDSP_vsmul(x, 1, &invSum, x, 1, vDSP_Length(count))
}

// MARK: - Scaled Dot-Product Attention

/// Compute single-query scaled dot-product attention.
///
/// scores[i] = dot(q, k_i) / sqrt(headDim)
/// attn_weights = softmax(scores + mask)
/// out = sum_i(attn_weights[i] * v_i)
///
/// Used in prefill and decode phases for single-token generation.
///
/// - Parameters:
///   - q:         Query vector [headDim]
///   - kCache:    Key cache [seqLen × headDim] (row-major)
///   - vCache:    Value cache [seqLen × headDim] (row-major)
///   - seqLen:    Current sequence length (number of valid KV pairs)
///   - headDim:   Dimension per head
///   - output:    Output vector [headDim]
///   - mask:      Optional causal mask (nil = auto-causal)
func scaledDotProductAttention(
    q: UnsafePointer<Float>,
    kCache: UnsafePointer<Float>,
    vCache: UnsafePointer<Float>,
    seqLen: Int,
    headDim: Int,
    output: UnsafeMutablePointer<Float>,
    mask: UnsafePointer<Float>? = nil
) {
    let scale = 1.0 / sqrtf(Float(headDim))

    // Compute attention scores: scores[i] = q · k_i * scale
    var scores = [Float](repeating: 0, count: seqLen)
    for i in 0..<seqLen {
        let ki = kCache + i * headDim
        scores[i] = cblas_sdot(Int32(headDim), q, 1, ki, 1) * scale
    }

    // Apply mask
    if let mask = mask {
        vDSP_vadd(scores, 1, mask, 1, &scores, 1, vDSP_Length(seqLen))
    }

    // Softmax
    scores.withUnsafeMutableBufferPointer { ptr in
        softmaxInPlace(ptr.baseAddress!, count: seqLen)
    }

    // Weighted sum of values: output = sum_i(scores[i] * v_i)
    // Initialize output to zero
    var zero: Float = 0
    vDSP_vfill(&zero, output, 1, vDSP_Length(headDim))

    for i in 0..<seqLen {
        let vi = vCache + i * headDim
        cblas_saxpy(Int32(headDim), scores[i], vi, 1, output, 1)
    }
}

// MARK: - Rotary Position Embedding (RoPE)

/// Apply Rotary Position Embeddings to Q and K vectors.
///
/// RoPE rotates consecutive pairs of dimensions by a position-dependent angle:
///   theta_i = pos / theta^(2i/d)
///   [q_{2i}, q_{2i+1}] → [q_{2i}*cos - q_{2i+1}*sin, q_{2i}*sin + q_{2i+1}*cos]
///
/// - Parameters:
///   - x:         Input vector [numHeads × headDim]
///   - numHeads:  Number of attention heads
///   - headDim:   Dimensions per head (must be even)
///   - position:  Token position in the sequence
///   - theta:     Base rotation frequency (default: 10000)
func applyRoPE(
    x: UnsafeMutablePointer<Float>,
    numHeads: Int,
    headDim: Int,
    position: Int,
    theta: Float = 10000.0
) {
    let halfDim = headDim / 2
    let posFloat = Float(position)

    for head in 0..<numHeads {
        let base = x + head * headDim
        for i in 0..<halfDim {
            let freq = posFloat / powf(theta, Float(2 * i) / Float(headDim))
            let cosVal = cosf(freq)
            let sinVal = sinf(freq)
            let x0 = base[i * 2]
            let x1 = base[i * 2 + 1]
            base[i * 2]     = x0 * cosVal - x1 * sinVal
            base[i * 2 + 1] = x0 * sinVal + x1 * cosVal
        }
    }
}

// MARK: - Top-K / Top-P Sampling

/// Sample from logits using temperature + top-k + top-p.
///
/// - Parameters:
///   - logits:      Raw logits [vocabSize]
///   - vocabSize:   Number of tokens in vocabulary
///   - temperature: Controls randomness (0 = greedy, 1 = softmax)
///   - topK:        Keep only top-k candidates (0 = no limit)
///   - topP:        Keep candidates summing to top-p probability mass (1.0 = no limit)
/// - Returns: Sampled token index.
func sampleToken(
    logits: UnsafePointer<Float>,
    vocabSize: Int,
    temperature: Float,
    topK: Int = 40,
    topP: Float = 0.95
) -> Int {
    // Greedy decoding (temperature ≈ 0)
    if temperature < 1e-6 {
        var maxVal: Float = -.infinity
        var maxIdx: vDSP_Length = 0
        vDSP_maxvi(logits, 1, &maxVal, &maxIdx, vDSP_Length(vocabSize))
        return Int(maxIdx)
    }

    // Temperature scaling: logits / temperature
    var scaled = [Float](repeating: 0, count: vocabSize)
    var tempInv = 1.0 / temperature
    vDSP_vsmul(logits, 1, &tempInv, &scaled, 1, vDSP_Length(vocabSize))

    // Top-K filtering: set all but top-k logits to -inf
    if topK > 0 && topK < vocabSize {
        // Find k-th largest
        var sorted = scaled.enumerated().sorted { $0.element > $1.element }
        let kthVal = sorted[min(topK - 1, sorted.count - 1)].element
        for i in 0..<vocabSize {
            if scaled[i] < kthVal {
                scaled[i] = -.infinity
            }
        }
    }

    // Softmax to get probabilities
    scaled.withUnsafeMutableBufferPointer { ptr in
        softmaxInPlace(ptr.baseAddress!, count: vocabSize)
    }

    // Top-P nucleus filtering: zero out tokens outside the nucleus
    if topP < 1.0 {
        var sortedProbs = scaled.enumerated().sorted { $0.element > $1.element }
        var cumSum: Float = 0
        for (rank, (idx, prob)) in sortedProbs.enumerated() {
            cumSum += prob
            if cumSum > topP && rank > 0 {
                // Zero out all tokens beyond this point
                for r in rank..<sortedProbs.count {
                    scaled[sortedProbs[r].offset] = 0
                }
                break
            }
        }
        // Renormalise
        var sum: Float = 0
        vDSP_sve(scaled, 1, &sum, vDSP_Length(vocabSize))
        if sum > 0 {
            var invSum = 1.0 / sum
            vDSP_vsmul(scaled, 1, &invSum, &scaled, 1, vDSP_Length(vocabSize))
        }
    }

    // Sample from probability distribution using cumulative sum
    let r = Float.random(in: 0..<1)
    var cumSum: Float = 0
    for i in 0..<vocabSize {
        cumSum += scaled[i]
        if r < cumSum {
            return i
        }
    }
    return vocabSize - 1  // Fallback
}

// MARK: - Vector Copy / Add Helpers

/// Copy src to dst.
@inline(__always)
func vectorCopy(_ src: UnsafePointer<Float>, to dst: UnsafeMutablePointer<Float>, count: Int) {
    cblas_scopy(Int32(count), src, 1, dst, 1)
}

/// dst += src
@inline(__always)
func vectorAdd(_ src: UnsafePointer<Float>, to dst: UnsafeMutablePointer<Float>, count: Int) {
    cblas_saxpy(Int32(count), 1.0, src, 1, dst, 1)
}

/// dst = a + b
func vectorAddInto(
    _ a: UnsafePointer<Float>,
    _ b: UnsafePointer<Float>,
    into dst: UnsafeMutablePointer<Float>,
    count: Int
) {
    vDSP_vadd(a, 1, b, 1, dst, 1, vDSP_Length(count))
}
