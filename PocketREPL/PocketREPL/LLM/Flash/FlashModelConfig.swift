import Foundation

// MARK: - Flash Model Configuration
//
// Implements Apple's "LLM in a Flash" paper:
//   Alizadeh et al., 2023 — https://arxiv.org/abs/2312.11805
//
// Key insight: store model weights in flash (NVMe SSD), load only the
// active subset into DRAM each token using activation sparsity.
//
// "FlashPack" binary format:
//
//   [8 bytes]  Magic: "FLASHPK1"
//   [8 bytes]  uint64 header_json_length
//   [N bytes]  UTF-8 JSON header (FlashPackHeader)
//   [weights]  Described by header's `sections`
//
// Neuron bundling (Section 3.2 of paper):
//   For FFN layer i, neuron j is stored as a single contiguous chunk:
//     [up_proj_col_j   : hidden_size × sizeof(dtype)]   — column j of up-projection
//     [gate_proj_col_j : hidden_size × sizeof(dtype)]   — column j of gate (optional, SwiGLU)
//     [down_proj_row_j : hidden_size × sizeof(dtype)]   — row j of down-projection
//   Total: 2 (or 3 for SwiGLU) × hidden_size × sizeof(dtype) bytes per neuron.
//   This doubles chunk size compared to loading rows/cols separately → better NVMe throughput.

// MARK: - Data Type

/// Supported weight data types stored in flash.
enum FlashDType: String, Codable, Sendable {
    case float32 = "float32"    // 4 bytes/elem — full precision
    case float16 = "float16"    // 2 bytes/elem — half precision (default)
    case int8    = "int8"       // 1 byte/elem  — quantized
    case int4    = "int4"       // 0.5 byte/elem — quantized (packed 2 per byte)

    var bytesPerElement: Int {
        switch self {
        case .float32: return 4
        case .float16: return 2
        case .int8:    return 1
        case .int4:    return 1  // packed; actual = 0.5, stored 2 per byte
        }
    }
}

// MARK: - Architecture Type

/// Transformer architecture variant.
enum FlashArchitecture: String, Codable, Sendable {
    case llama      = "llama"       // LLaMA / LLaMA-2 / LLaMA-3
    case mistral    = "mistral"     // Mistral 7B
    case falcon     = "falcon"      // Falcon 7B/40B
    case opt        = "opt"         // OPT family
    case phi        = "phi"         // Phi-2, Phi-3
    case persimmon  = "persimmon"   // Persimmon-8B
    case moe        = "moe"         // Generic Mixture-of-Experts
}

// MARK: - Sparsity Type

/// How FFN sparsity is induced in the model.
enum FlashSparsityType: String, Codable, Sendable {
    /// Standard ReLU — ~90–97% sparsity for tuned models (OPT, Falcon-relufied).
    case relu       = "relu"
    /// ReLU² variant (ProSparse, LLaMA sparsified).
    case relu2      = "relu2"
    /// FATReLU (Llama-2 sparsified, Song et al. 2024).
    case fatrelu    = "fatrelu"
    /// Mixture-of-Experts routing — always sparse.
    case moe        = "moe"
    /// Dense (no sparsity) — loads all neurons; baseline comparison.
    case dense      = "dense"
}

// MARK: - Tensor Shape

struct TensorShape: Codable, Sendable {
    let offset: UInt64      // Byte offset from start of file
    let rows: Int           // First dimension (typically output features / vocab)
    let cols: Int           // Second dimension (typically input features)
    let dtype: FlashDType

    /// Total number of elements.
    var elementCount: Int { rows * cols }

    /// Total size in bytes.
    var byteSize: Int { elementCount * dtype.bytesPerElement }

    /// Compute offset of element (row, col) in row-major order.
    func elementOffset(row: Int, col: Int) -> UInt64 {
        return offset + UInt64((row * cols + col) * dtype.bytesPerElement)
    }
}

// MARK: - Layer Section Spec

/// File-offset specification for a single transformer layer.
struct FlashLayerSpec: Codable, Sendable {

    // ── Attention weights (always kept in DRAM) ──

    /// Query projection [num_heads * head_dim, hidden_size]
    let qProj: TensorShape
    /// Key projection [num_kv_heads * head_dim, hidden_size]
    let kProj: TensorShape
    /// Value projection [num_kv_heads * head_dim, hidden_size]
    let vProj: TensorShape
    /// Output projection [hidden_size, num_heads * head_dim]
    let oProj: TensorShape
    /// RMSNorm before attention [hidden_size]
    let inputNorm: TensorShape
    /// RMSNorm before FFN [hidden_size]
    let postAttentionNorm: TensorShape

    // ── Bundled FFN neurons (loaded from flash on demand) ──

    /// Byte offset of the first bundled neuron in this layer.
    let ffnNeuronsOffset: UInt64
    /// Total number of FFN neurons (= intermediate_size).
    let ffnNeuronCount: Int
    /// Byte size of one bundled neuron entry.
    ///   For standard FFN (up + down):        2 × hidden_size × dtype.bytes
    ///   For SwiGLU (up + gate + down):       3 × hidden_size × dtype.bytes
    let ffnNeuronByteSize: Int
    /// Whether this layer uses a gated (SwiGLU) FFN.
    let ffnUseGate: Bool
    /// Data type of FFN neuron data.
    let ffnDType: FlashDType

    // ── Low-rank sparsity predictor (optional) ──
    //    Input: attention output [hidden_size]
    //    W_in:  [hidden_size, predictor_rank]
    //    W_out: [predictor_rank, ffn_neuron_count]
    //    Output: logits → top-k neurons to pre-load

    let predictorWIn: TensorShape?    // nil → no predictor (dense loading)
    let predictorWOut: TensorShape?

    // ── Neuron importance scores (alternative to predictor) ──
    //    Pre-computed global importance for each neuron, so we can
    //    always keep the top-N most-active neurons warm in cache.
    let neuronImportanceOffset: UInt64?  // [ffnNeuronCount] float32
}

// MARK: - Model Section Spec

/// File-offset specs for model-global tensors.
struct FlashModelSections: Codable, Sendable {
    /// Token embedding table [vocab_size, hidden_size]
    let tokenEmbedding: TensorShape
    /// Final RMSNorm weight [hidden_size]
    let norm: TensorShape
    /// Language-model head [vocab_size, hidden_size]
    let lmHead: TensorShape
    /// Per-layer specs
    let layers: [FlashLayerSpec]
}

// MARK: - Model Configuration

/// Hyper-parameters and I/O configuration for a flash-packed model.
struct FlashModelConfig: Codable, Sendable {

    // ── Architecture ──
    let architecture: FlashArchitecture
    let sparsityType: FlashSparsityType
    let vocabSize: Int
    let hiddenSize: Int
    let intermediateSize: Int
    let numHiddenLayers: Int
    let numAttentionHeads: Int
    let numKeyValueHeads: Int    // < numAttentionHeads for GQA
    let headDim: Int             // = hiddenSize / numAttentionHeads (usually)
    let maxPositionEmbeddings: Int
    let rmsNormEps: Float
    let ropeTheta: Float
    let tieEmbeddings: Bool      // lm_head shares token embedding weights

    // ── Flash loading parameters ──

    /// Window size k: keep active neurons from the last k tokens in DRAM.
    /// Larger k → fewer loads, more DRAM. (Paper default: k=4–5)
    var slidingWindowSize: Int

    /// Max fraction of DRAM to use for the FFN neuron cache per layer.
    /// Controls memory/latency tradeoff.
    var maxCacheFraction: Double

    /// Number of parallel I/O threads for flash reads. (Paper: 32)
    var ioThreadCount: Int

    /// Minimum read chunk size in bytes. Smaller → more I/O overhead.
    /// (Paper: 32 KiB optimal for Apple SSD)
    var minReadChunkBytes: Int

    /// Bypass OS buffer cache for accurate latency measurement.
    /// Production code should set this to false to benefit from caching.
    var bypassOSCache: Bool

    /// Read-ahead hint: pre-fetch next layer's neurons while computing current.
    var enableReadAhead: Bool

    // ── Sparsity predictor parameters ──

    /// Low-rank predictor rank (paper: 128–1152 depending on layer sensitivity).
    var predictorRank: Int

    /// Sigmoid threshold for predictor output. Lower → more neurons loaded
    /// (higher recall, lower precision). (Paper: 0.5–0.7)
    var predictorThreshold: Float

    /// How many additional neurons to load as a safety margin beyond predicted.
    var predictorSafetyBuffer: Int

    // ── File data ──
    let dtype: FlashDType
    let sections: FlashModelSections

    // ── Coding keys ──
    enum CodingKeys: String, CodingKey {
        case architecture, sparsityType, vocabSize, hiddenSize
        case intermediateSize, numHiddenLayers, numAttentionHeads
        case numKeyValueHeads, headDim, maxPositionEmbeddings
        case rmsNormEps, ropeTheta, tieEmbeddings
        case slidingWindowSize, maxCacheFraction, ioThreadCount
        case minReadChunkBytes, bypassOSCache, enableReadAhead
        case predictorRank, predictorThreshold, predictorSafetyBuffer
        case dtype, sections
    }
}

// MARK: - Flash File Header

/// Top-level JSON header embedded at the start of a FlashPack file.
struct FlashPackHeader: Codable, Sendable {
    static let magic: String = "FLASHPK1"
    let config: FlashModelConfig
    let fileFormatVersion: Int  // = 1

    enum CodingKeys: String, CodingKey {
        case config, fileFormatVersion
    }
}

// MARK: - Convenience Constructors

extension FlashModelConfig {

    /// Default flash configuration for a 7B LLaMA-family model.
    static func defaultLlama7B(sections: FlashModelSections) -> FlashModelConfig {
        FlashModelConfig(
            architecture: .llama,
            sparsityType: .fatrelu,
            vocabSize: 32000,
            hiddenSize: 4096,
            intermediateSize: 11008,
            numHiddenLayers: 32,
            numAttentionHeads: 32,
            numKeyValueHeads: 32,
            headDim: 128,
            maxPositionEmbeddings: 4096,
            rmsNormEps: 1e-5,
            ropeTheta: 10000.0,
            tieEmbeddings: false,
            slidingWindowSize: 4,
            maxCacheFraction: 0.25,   // Keep up to 25% of FFN weights in DRAM
            ioThreadCount: 32,
            minReadChunkBytes: 32768,  // 32 KiB (paper's sweet spot)
            bypassOSCache: false,      // Let macOS buffer cache help
            enableReadAhead: true,
            predictorRank: 128,
            predictorThreshold: 0.5,
            predictorSafetyBuffer: 32,
            dtype: .float16,
            sections: sections
        )
    }

    /// Estimated DRAM required for attention weights only (bytes).
    var attentionDRAMBytes: Int64 {
        let attentionPerLayer = Int64(4 * hiddenSize * hiddenSize) * 2 // Q,K,V,O each ≈ hidden²
        return attentionPerLayer * Int64(numHiddenLayers)
    }

    /// Estimated max DRAM for FFN cache (bytes).
    var ffnCacheDRAMBytes: Int64 {
        let neuronsPerLayer = Int64(Double(intermediateSize) * maxCacheFraction)
        let bytesPerNeuron = Int64(2 * hiddenSize) * Int64(dtype.bytesPerElement)
        return neuronsPerLayer * bytesPerNeuron * Int64(numHiddenLayers)
    }

    /// Total DRAM footprint estimate in megabytes.
    var estimatedDRAMMB: Double {
        let total = attentionDRAMBytes + ffnCacheDRAMBytes
        return Double(total) / (1024 * 1024)
    }
}

// MARK: - Flash Model Errors

enum FlashModelError: Error, Sendable, LocalizedError {
    case fileNotFound(path: String)
    case invalidMagic
    case unsupportedVersion(Int)
    case headerParseFailure(String)
    case sectionOutOfBounds(section: String, offset: UInt64, fileSize: UInt64)
    case ioError(errno: Int32, description: String)
    case insufficientDRAM(required: Int64, available: Int64)
    case predictorNotAvailable
    case tokenizationFailure

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "FlashPack model not found: \(path)"
        case .invalidMagic:
            return "Not a valid FlashPack file (bad magic bytes)"
        case .unsupportedVersion(let v):
            return "Unsupported FlashPack version: \(v)"
        case .headerParseFailure(let msg):
            return "Failed to parse FlashPack header: \(msg)"
        case .sectionOutOfBounds(let s, let o, let fs):
            return "Section \(s) at offset \(o) exceeds file size \(fs)"
        case .ioError(let errno, let desc):
            return "I/O error (errno \(errno)): \(desc)"
        case .insufficientDRAM(let req, let avail):
            return "Insufficient DRAM: need \(req / 1024 / 1024) MB, have \(avail / 1024 / 1024) MB"
        case .predictorNotAvailable:
            return "No sparsity predictor trained for this model"
        case .tokenizationFailure:
            return "Failed to tokenize input"
        }
    }
}
