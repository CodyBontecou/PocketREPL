import Foundation
import Darwin       // pread, open, close
import Observation  // @Observable
import llama        // gguf_*, ggml_*

// MARK: - Flash Model Converter
//
// Converts a GGUF model file into FlashPack format.
//
// What it does:
//   1. Parses the GGUF header using gguf_init_from_file (no_alloc=true)
//      → reads tensor names, byte offsets, shapes, and data types
//   2. Extracts model architecture metadata
//   3. Loads attention weights → writes to FlashPack (sequence matters)
//   4. For each FFN layer, reads up/gate/down projection matrices:
//      - Dequantizes to F32 using ggml type traits
//      - Re-quantizes to target format (F16 or Q2)
//      - Bundles neurons: [up_col_j | gate_col_j | down_row_j] per neuron
//      - Writes bundled data to FlashPack
//   5. Computes per-neuron importance scores (L2 norm of up-proj column)
//   6. Writes FlashPack JSON header with all byte offsets
//
// Memory efficiency: Only one FFN layer's weight matrix is in memory at a time.
// A 7B model's FFN for one layer ≈ 3 × 4096 × 11008 × 2 bytes = ~270 MB.

// MARK: - GGUF Metadata Keys (Llama architecture)
// Reference: https://github.com/ggerganov/ggml/blob/master/docs/gguf.md

private enum GGUFKey {
    // Architecture
    static let generalArchitecture = "general.architecture"
    static let generalName         = "general.name"

    // Llama keys
    static func llamaKey(_ suffix: String) -> String { "llama.\(suffix)" }
    static let blockCount          = "llama.block_count"
    static let embeddingLength     = "llama.embedding_length"
    static let feedForwardLength   = "llama.feed_forward_length"
    static let headCount           = "llama.attention.head_count"
    static let headCountKV         = "llama.attention.head_count_kv"
    static let maxPositionEmbeddings = "llama.context_length"
    static let rmsNormEps          = "llama.attention.layer_norm_rms_epsilon"
    static let ropeFreqBase        = "llama.rope.freq_base"
    static let vocabSize           = "tokenizer.ggml.tokens"

    // Tensor name patterns (e.g., "blk.0.attn_q.weight")
    static func tensorName(_ pattern: String, layer: Int) -> String {
        pattern.replacingOccurrences(of: "{L}", with: "\(layer)")
    }

    // Llama tensor names
    static let tokenEmbedding = "token_embd.weight"
    static let outputNorm     = "output_norm.weight"
    static let output         = "output.weight"        // LM head

    static func attnQ(layer: Int)  -> String { "blk.\(layer).attn_q.weight" }
    static func attnK(layer: Int)  -> String { "blk.\(layer).attn_k.weight" }
    static func attnV(layer: Int)  -> String { "blk.\(layer).attn_v.weight" }
    static func attnO(layer: Int)  -> String { "blk.\(layer).attn_output.weight" }
    static func attnNorm(layer: Int) -> String { "blk.\(layer).attn_norm.weight" }
    static func ffnNorm(layer: Int)  -> String { "blk.\(layer).ffn_norm.weight" }
    static func ffnUp(layer: Int)   -> String { "blk.\(layer).ffn_up.weight" }
    static func ffnGate(layer: Int) -> String { "blk.\(layer).ffn_gate.weight" }
    static func ffnDown(layer: Int) -> String { "blk.\(layer).ffn_down.weight" }
}

// MARK: - Conversion Options

struct FlashConversionOptions: Sendable {
    /// Output quantization for FFN neuron weights.
    var ffnQuantization: FlashDType = .float16
    /// Output quantization for attention weights.
    var attnQuantization: FlashDType = .float16
    /// Quantization block size.
    var blockSize: Int = 32
    /// Whether to compute neuron importance scores.
    var computeImportance: Bool = true
    /// Number of parallel I/O threads for reading source GGUF.
    var ioThreadCount: Int = 4

    static let `default` = FlashConversionOptions()

    /// 2-bit quantized (smallest file, ~6× compression vs F16).
    static let q2 = FlashConversionOptions(ffnQuantization: .int4, attnQuantization: .float16)

    /// 8-bit quantized (good quality, ~2× compression vs F16).
    static let q8 = FlashConversionOptions(ffnQuantization: .int8, attnQuantization: .float16)
}

// MARK: - Converter

enum FlashModelConverter {

    /// Convert a GGUF model file to FlashPack format.
    ///
    /// - Parameters:
    ///   - ggufPath:    Source .gguf file path.
    ///   - outputPath:  Destination .flashpack file path.
    ///   - options:     Quantization and conversion options.
    ///   - onProgress:  Progress callback: (fraction, message) → (0.0 … 1.0)
    static func convert(
        ggufPath: String,
        outputPath: String,
        options: FlashConversionOptions = .default,
        onProgress: @escaping (Double, String) -> Void
    ) async throws {

        onProgress(0.0, "Opening GGUF file…")

        // ── Step 1: Open GGUF header (no_alloc — only reads metadata) ─────
        var initParams = gguf_init_params()
        initParams.no_alloc = true
        initParams.ctx = nil

        guard let ggufCtx = gguf_init_from_file(ggufPath, initParams) else {
            throw FlashModelError.headerParseFailure("gguf_init_from_file failed for: \(ggufPath)")
        }
        defer { gguf_free(ggufCtx) }

        // ── Step 2: Extract architecture metadata ─────────────────────────
        let arch = try GGUFReader.readArchitecture(ggufCtx)
        onProgress(0.05, "Detected: \(arch.name) (\(arch.numLayers) layers)")

        // ── Step 3: Open source file for raw byte reads ────────────────────
        let srcFd = Darwin.open(ggufPath, O_RDONLY)
        guard srcFd >= 0 else {
            throw FlashModelError.ioError(errno: errno, description: "open(\(ggufPath))")
        }
        defer { Darwin.close(srcFd) }

        let dataOffset = Int64(gguf_get_data_offset(ggufCtx))

        // ── Step 4: Create output file ─────────────────────────────────────
        guard FileManager.default.createFile(atPath: outputPath, contents: nil) else {
            throw FlashModelError.ioError(errno: errno, description: "createFile(\(outputPath))")
        }
        let outputHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: outputPath))
        defer { try? outputHandle.close() }

        // Reserve space for the JSON header.
        // Estimation: magic(8) + len(8) + JSON.
        // JSON size scales with numLayers: ~1,500 bytes/layer + ~3,000 bytes global.
        // We double the estimate and align to 4 KB to be safe against overflow.
        let estimatedJSONBytes = arch.numLayers * 1500 + 3000
        let headerReserve = ((estimatedJSONBytes * 2 + 4095) / 4096) * 4096  // Round up to 4KB boundary
        let placeholder = Data(count: headerReserve)
        outputHandle.write(placeholder)
        var writeOffset: Int = headerReserve

        // ── Step 5: Write global weights ──────────────────────────────────
        onProgress(0.08, "Writing token embedding…")
        let embSpec = try writeTensor(
            name: GGUFKey.tokenEmbedding, ggufCtx: ggufCtx,
            srcFd: srcFd, dataOffset: dataOffset,
            outputHandle: outputHandle, writeOffset: &writeOffset,
            targetDType: options.attnQuantization, arch: arch
        )

        // ── Step 6: Write layer weights ─────────────────────────────────
        var layerSpecs: [FlashLayerSpec] = []

        for layerIdx in 0..<arch.numLayers {
            let progress = 0.10 + 0.75 * Double(layerIdx) / Double(arch.numLayers)
            onProgress(progress, "Converting layer \(layerIdx)/\(arch.numLayers)…")

            // Attention weights
            let qSpec   = try writeTensor(name: GGUFKey.attnQ(layer: layerIdx),
                                          ggufCtx: ggufCtx, srcFd: srcFd, dataOffset: dataOffset,
                                          outputHandle: outputHandle, writeOffset: &writeOffset,
                                          targetDType: options.attnQuantization, arch: arch)
            let kSpec   = try writeTensor(name: GGUFKey.attnK(layer: layerIdx),
                                          ggufCtx: ggufCtx, srcFd: srcFd, dataOffset: dataOffset,
                                          outputHandle: outputHandle, writeOffset: &writeOffset,
                                          targetDType: options.attnQuantization, arch: arch)
            let vSpec   = try writeTensor(name: GGUFKey.attnV(layer: layerIdx),
                                          ggufCtx: ggufCtx, srcFd: srcFd, dataOffset: dataOffset,
                                          outputHandle: outputHandle, writeOffset: &writeOffset,
                                          targetDType: options.attnQuantization, arch: arch)
            let oSpec   = try writeTensor(name: GGUFKey.attnO(layer: layerIdx),
                                          ggufCtx: ggufCtx, srcFd: srcFd, dataOffset: dataOffset,
                                          outputHandle: outputHandle, writeOffset: &writeOffset,
                                          targetDType: options.attnQuantization, arch: arch)
            let inNorm  = try writeTensor(name: GGUFKey.attnNorm(layer: layerIdx),
                                          ggufCtx: ggufCtx, srcFd: srcFd, dataOffset: dataOffset,
                                          outputHandle: outputHandle, writeOffset: &writeOffset,
                                          targetDType: .float16, arch: arch)
            let ffnNorm = try writeTensor(name: GGUFKey.ffnNorm(layer: layerIdx),
                                          ggufCtx: ggufCtx, srcFd: srcFd, dataOffset: dataOffset,
                                          outputHandle: outputHandle, writeOffset: &writeOffset,
                                          targetDType: .float16, arch: arch)

            // FFN bundled neurons
            let (ffnSpec, importanceSpec) = try writeBundledFFN(
                layerIdx: layerIdx, arch: arch, options: options,
                ggufCtx: ggufCtx, srcFd: srcFd, dataOffset: dataOffset,
                outputHandle: outputHandle, writeOffset: &writeOffset
            )

            let layerSpec = FlashLayerSpec(
                qProj: qSpec, kProj: kSpec, vProj: vSpec, oProj: oSpec,
                inputNorm: inNorm, postAttentionNorm: ffnNorm,
                ffnNeuronsOffset: ffnSpec.neuronsOffset,
                ffnNeuronCount: arch.intermediateSize,
                ffnNeuronByteSize: ffnSpec.neuronByteSize,
                ffnUseGate: arch.hasGateProjection,
                ffnDType: options.ffnQuantization,
                predictorWIn: nil,
                predictorWOut: nil,
                neuronImportanceOffset: importanceSpec?.offset
            )
            layerSpecs.append(layerSpec)
        }

        // ── Step 7: Write final norm and LM head ───────────────────────────
        onProgress(0.87, "Writing output norm and LM head…")
        let normSpec = try writeTensor(
            name: GGUFKey.outputNorm, ggufCtx: ggufCtx,
            srcFd: srcFd, dataOffset: dataOffset,
            outputHandle: outputHandle, writeOffset: &writeOffset,
            targetDType: .float16, arch: arch
        )

        // LM head — may be tied to embedding or separate
        let lmHeadName = gguf_find_tensor(ggufCtx, GGUFKey.output) >= 0
            ? GGUFKey.output : GGUFKey.tokenEmbedding
        let lmHeadSpec = try writeTensor(
            name: lmHeadName, ggufCtx: ggufCtx,
            srcFd: srcFd, dataOffset: dataOffset,
            outputHandle: outputHandle, writeOffset: &writeOffset,
            targetDType: options.attnQuantization, arch: arch
        )

        // ── Step 8: Build and write JSON header ────────────────────────────
        onProgress(0.93, "Writing header…")

        let sections = FlashModelSections(
            tokenEmbedding: embSpec,
            norm: normSpec,
            lmHead: lmHeadSpec,
            layers: layerSpecs
        )

        let config = FlashModelConfig(
            architecture: arch.flashArchitecture,
            sparsityType: .fatrelu,
            vocabSize: arch.vocabSize,
            hiddenSize: arch.hiddenSize,
            intermediateSize: arch.intermediateSize,
            numHiddenLayers: arch.numLayers,
            numAttentionHeads: arch.numQHeads,
            numKeyValueHeads: arch.numKVHeads,
            headDim: arch.hiddenSize / arch.numQHeads,
            maxPositionEmbeddings: arch.contextLength,
            rmsNormEps: arch.rmsNormEps,
            ropeTheta: arch.ropeTheta,
            tieEmbeddings: lmHeadName == GGUFKey.tokenEmbedding,
            slidingWindowSize: 4,
            maxCacheFraction: 0.25,
            ioThreadCount: 32,
            minReadChunkBytes: 32768,
            bypassOSCache: false,
            enableReadAhead: true,
            predictorRank: 128,
            predictorThreshold: 0.5,
            predictorSafetyBuffer: 32,
            dtype: options.ffnQuantization,
            sections: sections
        )

        let header = FlashPackHeader(config: config, fileFormatVersion: 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let headerJSON = try encoder.encode(header)

        // Write actual header at start of file
        let magic = FlashPackReader.magicBytes
        var headerLen = UInt64(headerJSON.count)
        var headerData = magic
        headerData.append(Data(bytes: &headerLen, count: 8))
        headerData.append(headerJSON)

        // Verify the header fits in the reserved space
        guard headerData.count <= headerReserve else {
            throw FlashModelError.headerParseFailure(
                "Header (\(headerData.count) bytes) exceeds reserved space (\(headerReserve) bytes). " +
                "This is a bug — please file an issue with model architecture details."
            )
        }

        // Seek to beginning, write header, pad remainder of reservation with zeros
        try outputHandle.seek(toOffset: 0)
        outputHandle.write(headerData)
        // Pad remaining reserved space so weight offsets remain valid
        let padding = Data(count: headerReserve - headerData.count)
        outputHandle.write(padding)

        onProgress(1.0, "Done! \(outputPath)")
    }

    // MARK: - Private: Write Single Tensor

    /// Read a tensor from GGUF and write to output, returning the TensorShape spec.
    private static func writeTensor(
        name: String,
        ggufCtx: OpaquePointer,
        srcFd: Int32,
        dataOffset: Int64,
        outputHandle: FileHandle,
        writeOffset: inout Int,
        targetDType: FlashDType,
        arch: GGUFArchitecture? = nil
    ) throws -> TensorShape {
        let tensorId = gguf_find_tensor(ggufCtx, name)
        guard tensorId >= 0 else {
            throw FlashModelError.headerParseFailure("Tensor not found: \(name)")
        }

        let tensorOffset = Int64(gguf_get_tensor_offset(ggufCtx, tensorId))
        let tensorSize   = Int(gguf_get_tensor_size(ggufCtx, tensorId))
        let ggmlType     = gguf_get_tensor_type(ggufCtx, tensorId)

        // Read raw bytes from source file
        var rawBytes = Data(count: tensorSize)
        let readResult: Int = rawBytes.withUnsafeMutableBytes { ptr in
            Darwin.pread(srcFd, ptr.baseAddress!, tensorSize, dataOffset + tensorOffset)
        }
        guard readResult == tensorSize else {
            throw FlashModelError.ioError(errno: errno, description: "pread tensor \(name)")
        }

        // Dequantize to float32
        let floats = dequantize(rawBytes, ggmlType: ggmlType, elementCount: numElements(ggufCtx, id: tensorId))

        // Re-quantize to target format
        let outputBytes: Data
        switch targetDType {
        case .float32:
            outputBytes = floats.withUnsafeBytes { Data($0) }
        case .float16:
            let f16 = floats.map { Float16($0) }
            outputBytes = f16.withUnsafeBytes { Data($0) }
        case .int8:
            outputBytes = FlashQuantization.quantizeQ8(floats)
        case .int4:
            outputBytes = FlashQuantization.quantizeQ2(floats)
        }

        // Determine correct 2D shape from tensor name + architecture
        let (rows, cols) = tensorShape(ggufCtx, id: tensorId, arch: arch)

        let spec = TensorShape(
            offset: UInt64(writeOffset),
            rows: rows,
            cols: cols,
            dtype: targetDType
        )

        outputHandle.write(outputBytes)
        writeOffset += outputBytes.count

        return spec
    }

    // MARK: - Private: Write Bundled FFN Neurons

    struct FFNSpec {
        let neuronsOffset: UInt64
        let neuronByteSize: Int
    }

    private static func writeBundledFFN(
        layerIdx: Int,
        arch: GGUFArchitecture,
        options: FlashConversionOptions,
        ggufCtx: OpaquePointer,
        srcFd: Int32,
        dataOffset: Int64,
        outputHandle: FileHandle,
        writeOffset: inout Int
    ) throws -> (FFNSpec, TensorShape?) {

        // Load full up / gate / down matrices as float32
        let upMatrix   = try loadFullTensor(name: GGUFKey.ffnUp(layer: layerIdx),
                                            ggufCtx: ggufCtx, srcFd: srcFd, dataOffset: dataOffset)
        let gateMatrix = arch.hasGateProjection
            ? try? loadFullTensor(name: GGUFKey.ffnGate(layer: layerIdx),
                                  ggufCtx: ggufCtx, srcFd: srcFd, dataOffset: dataOffset)
            : nil
        let downMatrix = try loadFullTensor(name: GGUFKey.ffnDown(layer: layerIdx),
                                            ggufCtx: ggufCtx, srcFd: srcFd, dataOffset: dataOffset)

        // upMatrix:   [intermediateSize × hiddenSize] row-major  (row j = up_col_j as activation output)
        // downMatrix: [hiddenSize × intermediateSize] row-major  (col j = down_row_j)
        //
        // For bundled format, neuron j needs:
        //   up_col_j   = upMatrix[j, :]     (row j of up_proj.weight)
        //   gate_col_j = gateMatrix[j, :]   (row j of gate_proj.weight)
        //   down_row_j = downMatrix[:, j]   = downMatrix transposed row j
        //                                   = column j of down_proj.weight

        let h = arch.hiddenSize
        let inter = arch.intermediateSize
        let neuronsOffset = UInt64(writeOffset)

        let quantizer = NeuronQuantizer(hiddenSize: h, hasGate: arch.hasGateProjection,
                                         quantization: options.ffnQuantization,
                                         blockSize: options.blockSize)

        var importanceScores = [Float](repeating: 0, count: inter)

        for j in 0..<inter {
            // Extract neuron j's up column (row j of up_proj weight matrix)
            let upCol = Array(upMatrix[(j * h)..<(j * h + h)])

            // Extract gate column if present (row j of gate_proj weight matrix)
            let gateCol: [Float]? = gateMatrix.map { m in Array(m[(j * h)..<(j * h + h)]) }

            // Extract down row: column j of down_proj [h × inter] row-major
            // i.e. down_proj[i, j] = downMatrix[i * inter + j] for i in 0..<h
            var downRow = [Float](repeating: 0, count: h)
            for i in 0..<h { downRow[i] = downMatrix[i * inter + j] }

            // Importance score = L2 norm of up column (proxy for global neuron activity)
            if options.computeImportance {
                var sumSq: Float = 0
                for v in upCol { sumSq += v * v }
                importanceScores[j] = sqrtf(sumSq)
            }

            // Quantize and write: [up_col_j | gate_col_j? | down_row_j] contiguous
            let packed = quantizer.quantizeNeuron(upCol: upCol, gateCol: gateCol, downRow: downRow)
            outputHandle.write(packed)
        }

        // writeOffset = neuronsOffset + total bytes written for all neurons
        let neuronByteSize = inter > 0 ? quantizer.totalQuantizedBytes / inter : 0
        writeOffset = Int(neuronsOffset) + quantizer.totalQuantizedBytes

        let ffnSpec = FFNSpec(neuronsOffset: neuronsOffset, neuronByteSize: neuronByteSize)

        // Write importance scores
        var importanceSpec: TensorShape? = nil
        if options.computeImportance {
            let importanceOffset = UInt64(writeOffset)
            let importanceData: Data = importanceScores.withUnsafeBytes { Data($0) }
            outputHandle.write(importanceData)
            writeOffset += importanceData.count
            importanceSpec = TensorShape(offset: importanceOffset, rows: 1,
                                         cols: inter, dtype: .float32)
        }

        return (ffnSpec, importanceSpec)
    }

    // MARK: - Private: Load Full Tensor as Float32

    private static func loadFullTensor(
        name: String,
        ggufCtx: OpaquePointer,
        srcFd: Int32,
        dataOffset: Int64
    ) throws -> [Float] {
        let tensorId = gguf_find_tensor(ggufCtx, name)
        guard tensorId >= 0 else {
            throw FlashModelError.headerParseFailure("Tensor not found: \(name)")
        }

        let tensorOffset = Int64(gguf_get_tensor_offset(ggufCtx, tensorId))
        let tensorSize   = Int(gguf_get_tensor_size(ggufCtx, tensorId))
        let ggmlType     = gguf_get_tensor_type(ggufCtx, tensorId)
        let nElements    = numElements(ggufCtx, id: tensorId)

        var rawBytes = Data(count: tensorSize)
        let readResult: Int = rawBytes.withUnsafeMutableBytes { ptr in
            Darwin.pread(srcFd, ptr.baseAddress!, tensorSize, dataOffset + tensorOffset)
        }
        guard readResult == tensorSize else {
            throw FlashModelError.ioError(errno: errno, description: "pread \(name)")
        }

        return dequantize(rawBytes, ggmlType: ggmlType, elementCount: nElements)
    }

    // MARK: - Private: GGML Dequantization

    /// Dequantize raw bytes from any GGML quantization to float32.
    private static func dequantize(_ raw: Data, ggmlType: ggml_type, elementCount: Int) -> [Float] {
        switch ggmlType {
        case GGML_TYPE_F32:
            return raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        case GGML_TYPE_F16:
            return raw.withUnsafeBytes { ptr -> [Float] in
                let f16Ptr = ptr.bindMemory(to: Float16.self)
                return (0..<min(elementCount, f16Ptr.count)).map { Float(f16Ptr[$0]) }
            }

        default:
            // Use ggml type traits for all quantized formats (Q4_K_M, Q8_0, etc.)
            let traits = ggml_get_type_traits(ggmlType)
            if let toFloat = traits?.pointee.to_float {
                var output = [Float](repeating: 0, count: elementCount)
                raw.withUnsafeBytes { rawPtr in
                    toFloat(rawPtr.baseAddress!, &output, Int64(elementCount))
                }
                return output
            }
            // Fallback: return zeros (unsupported quantization type)
            return [Float](repeating: 0, count: elementCount)
        }
    }

    // MARK: - Private: Shape helpers

    private static func numElements(_ ctx: OpaquePointer, id: Int64) -> Int {
        // Read tensor dimensions from GGUF
        // GGUF stores up to 4 dimensions; for 2D tensors, ne[0]=cols, ne[1]=rows
        let n = gguf_get_tensor_size(ctx, id) / ggml_type_size(gguf_get_tensor_type(ctx, id))
        // Actually need to use ggml tensor access, but in no_alloc mode the actual
        // ggml_tensor structs aren't populated. Calculate from byte size:
        let ggmlType = gguf_get_tensor_type(ctx, id)
        let blkSz = Int(ggml_blck_size(ggmlType))
        let typeSz = Int(ggml_type_size(ggmlType))
        return blkSz > 0 ? Int(gguf_get_tensor_size(ctx, id)) / typeSz * blkSz : Int(n)
    }

    /// Return (rows, cols) for a tensor, deriving shape from the tensor name and architecture.
    ///
    /// In `no_alloc` mode the `ggml_tensor.ne` array isn't populated, so we infer
    /// the 2D shape from the known architecture structure:
    ///   - Weight matrices: [out_features, in_features]
    ///   - Bias / norm vectors: [features, 1]
    private static func tensorShape(
        _ ctx: OpaquePointer,
        id: Int64,
        arch: GGUFArchitecture? = nil
    ) -> (rows: Int, cols: Int) {
        let nElem = numElements(ctx, id: id)
        guard let a = arch else { return (rows: nElem, cols: 1) }

        // Match common weight shapes to architecture dimensions
        let name = String(cString: gguf_get_tensor_name(ctx, id))

        let h  = a.hiddenSize
        let nh = a.numQHeads
        let nkv = a.numKVHeads
        let hd = h / max(1, nh)
        let inter = a.intermediateSize

        switch true {
        case name.hasSuffix("attn_q.weight"):    return (rows: nh * hd, cols: h)
        case name.hasSuffix("attn_k.weight"):    return (rows: nkv * hd, cols: h)
        case name.hasSuffix("attn_v.weight"):    return (rows: nkv * hd, cols: h)
        case name.hasSuffix("attn_output.weight"): return (rows: h, cols: nh * hd)
        case name.hasSuffix("ffn_up.weight"):    return (rows: inter, cols: h)
        case name.hasSuffix("ffn_gate.weight"):  return (rows: inter, cols: h)
        case name.hasSuffix("ffn_down.weight"):  return (rows: h, cols: inter)
        case name.hasSuffix("token_embd.weight"): return (rows: a.vocabSize, cols: h)
        case name.hasSuffix("output.weight"):    return (rows: a.vocabSize, cols: h)
        default:
            // Norms and biases are 1D: [features]
            if nElem == h || nElem == inter {
                return (rows: nElem, cols: 1)
            }
            // Unknown: return flat
            return (rows: nElem, cols: 1)
        }
    }
}

// MARK: - GGUF Architecture Parser

struct GGUFArchitecture: Sendable {
    let name: String
    let numLayers: Int
    let hiddenSize: Int
    let intermediateSize: Int
    let numQHeads: Int
    let numKVHeads: Int
    let contextLength: Int
    let rmsNormEps: Float
    let ropeTheta: Float
    let vocabSize: Int
    let hasGateProjection: Bool  // true for LLaMA (SwiGLU), false for OPT/Falcon

    var flashArchitecture: FlashArchitecture {
        let n = name.lowercased()
        if n.contains("llama") { return .llama }
        if n.contains("mistral") { return .mistral }
        if n.contains("falcon") { return .falcon }
        if n.contains("phi") { return .phi }
        if n.contains("opt") { return .opt }
        return .llama
    }
}

enum GGUFReader {

    static func readArchitecture(_ ctx: OpaquePointer) throws -> GGUFArchitecture {
        func int32Key(_ key: String) -> Int { Int(readI32(ctx, key: key) ?? 0) }
        func floatKey(_ key: String) -> Float { readF32(ctx, key: key) ?? 0 }
        func stringKey(_ key: String) -> String { readStr(ctx, key: key) ?? "" }

        let archStr = stringKey(GGUFKey.generalArchitecture)
        let name    = stringKey(GGUFKey.generalName)

        let numLayers    = int32Key(GGUFKey.blockCount)
        let hiddenSize   = int32Key(GGUFKey.embeddingLength)
        let intermediate = int32Key(GGUFKey.feedForwardLength)
        let numQHeads    = int32Key(GGUFKey.headCount)
        let numKVHeads   = int32Key(GGUFKey.headCountKV)
        let ctxLen       = int32Key(GGUFKey.maxPositionEmbeddings)
        let rmsEps       = floatKey(GGUFKey.rmsNormEps)
        let ropeBase     = floatKey(GGUFKey.ropeFreqBase)
        let vocabSize    = int32Key(GGUFKey.vocabSize)

        guard numLayers > 0, hiddenSize > 0, intermediate > 0 else {
            throw FlashModelError.headerParseFailure(
                "Could not read model architecture from GGUF. " +
                "Found: layers=\(numLayers), hidden=\(hiddenSize), intermediate=\(intermediate)"
            )
        }

        // Detect gate projection by checking if a gate tensor exists for layer 0
        let hasGate = gguf_find_tensor(ctx, GGUFKey.ffnGate(layer: 0)) >= 0

        return GGUFArchitecture(
            name: name.isEmpty ? archStr : name,
            numLayers: numLayers,
            hiddenSize: hiddenSize,
            intermediateSize: intermediate,
            numQHeads: max(1, numQHeads),
            numKVHeads: max(1, numKVHeads > 0 ? numKVHeads : numQHeads),
            contextLength: ctxLen > 0 ? ctxLen : 4096,
            rmsNormEps: rmsEps > 0 ? rmsEps : 1e-5,
            ropeTheta: ropeBase > 0 ? ropeBase : 10000.0,
            vocabSize: vocabSize > 0 ? vocabSize : 32000,
            hasGateProjection: hasGate
        )
    }

    private static func readI32(_ ctx: OpaquePointer, key: String) -> Int32? {
        let id = gguf_find_key(ctx, key)
        guard id >= 0 else { return nil }
        let type = gguf_get_kv_type(ctx, id)
        switch type {
        case GGUF_TYPE_UINT32: return Int32(gguf_get_val_u32(ctx, id))
        case GGUF_TYPE_INT32:  return gguf_get_val_i32(ctx, id)
        default: return nil
        }
    }

    private static func readF32(_ ctx: OpaquePointer, key: String) -> Float? {
        let id = gguf_find_key(ctx, key)
        guard id >= 0 else { return nil }
        return gguf_get_val_f32(ctx, id)
    }

    private static func readStr(_ ctx: OpaquePointer, key: String) -> String? {
        let id = gguf_find_key(ctx, key)
        guard id >= 0 else { return nil }
        let type = gguf_get_kv_type(ctx, id)
        guard type == GGUF_TYPE_STRING else { return nil }
        guard let cStr = gguf_get_val_str(ctx, id) else { return nil }
        return String(cString: cStr)
    }
}

// MARK: - Conversion Progress UI Helper

@Observable
@MainActor
final class FlashConversionProgress {
    var fraction: Double = 0
    var message: String = ""
    var isConverting: Bool = false
    var error: String? = nil
    var outputPath: String? = nil

    func update(fraction: Double, message: String) {
        self.fraction = fraction
        self.message = message
    }
}
