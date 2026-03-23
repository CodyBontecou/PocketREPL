import Foundation
import Accelerate

// MARK: - Flash Quantization
//
// Implements 2-bit quantization for FFN neuron weights, per the flash-moe paper:
//   "2-bit requantization of expert weights with negligible quality loss
//    (RMSE of 0.001 to 0.003 per layer), cutting expert storage from 209 GB to 120 GB."
//                                        — danveloper/flash-moe
//
// DESIGN:
// ────────
// Q2 quantization maps floating-point weights to 4 levels: {-3, -1, +1, +3} × scale/2
// This is "signed 2-bit" — each weight uses 2 bits, 4 values per byte.
//
// Block structure (blockSize = 32 values):
//   [scale: float16 (2 bytes)]
//   [quantized: 8 bytes]  ← 32 values × 2 bits / 8 bits/byte
//   Total: 10 bytes per block of 32 floats
//   vs. F16: 64 bytes per 32 floats → 6.4× compression
//
// For a 7B LLaMA model's FFN weights:
//   F16:  2 × 4096 × 11008 × 32 layers × 2 bytes = ~5.8 GB
//   Q2:   same ÷ 6.4 = ~0.9 GB  (saving 5 GB)
//
// Quality: RMSE typically 0.001–0.005 on typical LLM weight distributions.
//          Per flash-moe: K=4 expert routing is stable with Q2; K=3 collapses.

// MARK: - Q2 Block Format

/// A single quantized block of 32 float values.
///
/// Memory layout (10 bytes):
///   bytes [0..1]:  float16 scale  — max(|w|) / 1.5
///   bytes [2..9]:  8 bytes of packed 2-bit values (4 values/byte, 32 values total)
struct Q2Block {
    static let blockSize = 32           // Values per block
    static let bytesPerBlock = 10       // 2 (scale f16) + 8 (32 values × 2 bits)
    static let packPerByte = 4          // 4 values packed per byte

    var scale: Float16
    var data: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    /// The 4 quantization levels in terms of the normalised [-1, 1] range.
    static let levels: [Float] = [-1.5, -0.5, 0.5, 1.5]  // ÷ 1.5 gives {-1, -1/3, 1/3, 1}
}

// MARK: - Quantization Engine

enum FlashQuantization {

    // MARK: - 2-Bit Quantization

    /// Quantize a Float32 vector to Q2 format.
    ///
    /// - Parameters:
    ///   - input:     Input float array (any length, rounded up to block boundary internally).
    ///   - blockSize: Values per block (must be multiple of 4; default 32).
    /// - Returns: Packed Q2 bytes.
    static func quantizeQ2(_ input: [Float], blockSize: Int = Q2Block.blockSize) -> Data {
        let nBlocks = (input.count + blockSize - 1) / blockSize
        let bytesPerBlock = 2 + blockSize / 4   // 2-byte scale + (blockSize/4) data bytes
        var output = Data(count: nBlocks * bytesPerBlock)

        output.withUnsafeMutableBytes { outPtr in
            let base = outPtr.baseAddress!
            for b in 0..<nBlocks {
                let start = b * blockSize
                let end = min(start + blockSize, input.count)
                let count = end - start

                // Find absolute maximum for scale
                var maxAbs: Float = 0
                for i in start..<end {
                    let abs = abs(input[i])
                    if abs > maxAbs { maxAbs = abs }
                }

                // scale = max / 1.5  → maps [-1.5, 1.5] to 4 integer levels
                let scale = maxAbs > 1e-8 ? maxAbs / 1.5 : 1.0

                // Write scale as Float16
                let scaleF16 = Float16(scale)
                let scalePtr = base.advanced(by: b * bytesPerBlock)
                    .bindMemory(to: Float16.self, capacity: 1)
                scalePtr.pointee = scaleF16

                // Quantize and pack 4 values per byte
                let dataPtr = base.advanced(by: b * bytesPerBlock + 2)
                    .bindMemory(to: UInt8.self, capacity: blockSize / 4)

                let invScale = scale > 1e-8 ? 1.0 / scale : 0.0

                for byteIdx in 0..<(blockSize / 4) {
                    var packed: UInt8 = 0
                    for bit in 0..<4 {
                        let i = start + byteIdx * 4 + bit
                        let val: Float = i < end ? input[i] : 0.0

                        // Map val/scale → nearest of {-1.5, -0.5, 0.5, 1.5}
                        let normalised = val * invScale
                        let quantised: Int
                        if normalised < -1.0 {
                            quantised = 0          // -1.5
                        } else if normalised < 0.0 {
                            quantised = 1          // -0.5
                        } else if normalised < 1.0 {
                            quantised = 2          // +0.5
                        } else {
                            quantised = 3          // +1.5
                        }
                        packed |= UInt8(quantised) << (bit * 2)
                    }
                    if byteIdx < count / 4 + 1 {
                        dataPtr[byteIdx] = packed
                    }
                }
            }
        }

        return output
    }

    /// Dequantize Q2 bytes back to Float32.
    ///
    /// - Parameters:
    ///   - data:      Q2-packed byte data from `quantizeQ2()`.
    ///   - count:     Number of float values to decode (≤ data capacity).
    ///   - blockSize: Must match the block size used during quantization.
    /// - Returns: Float32 array of `count` values.
    static func dequantizeQ2(_ data: Data, count: Int, blockSize: Int = Q2Block.blockSize) -> [Float] {
        let bytesPerBlock = 2 + blockSize / 4
        let nBlocks = (count + blockSize - 1) / blockSize
        var output = [Float](repeating: 0, count: count)

        data.withUnsafeBytes { rawPtr in
            let base = rawPtr.baseAddress!
            for b in 0..<nBlocks {
                let blockStart = b * bytesPerBlock
                guard blockStart + bytesPerBlock <= data.count else { break }

                // Read scale
                let scale = Float(base.advanced(by: blockStart)
                    .bindMemory(to: Float16.self, capacity: 1).pointee)

                // Read and unpack 4 values per byte
                let dataPtr = base.advanced(by: blockStart + 2)
                    .bindMemory(to: UInt8.self, capacity: blockSize / 4)

                let outStart = b * blockSize
                for byteIdx in 0..<(blockSize / 4) {
                    let packed = dataPtr[byteIdx]
                    for bit in 0..<4 {
                        let idx = outStart + byteIdx * 4 + bit
                        guard idx < count else { break }
                        let quantised = Int((packed >> (bit * 2)) & 0x3)
                        // Map quantised level back to float:
                        // 0 → -1.5, 1 → -0.5, 2 → +0.5, 3 → +1.5
                        let level: Float = [(-1.5), (-0.5), (0.5), (1.5)][quantised]
                        output[idx] = level * scale
                    }
                }
            }
        }

        return output
    }

    // MARK: - Per-Neuron Quantization (for FlashPack bundled format)

    /// Quantize a complete bundled neuron [up_col | gate_col | down_row].
    ///
    /// Returns Q2-packed data for the entire neuron (all three parts together).
    static func quantizeNeuron(
        upCol: [Float],
        gateCol: [Float]?,
        downRow: [Float]
    ) -> Data {
        var packed = Data()
        packed.append(quantizeQ2(upCol))
        if let gate = gateCol {
            packed.append(quantizeQ2(gate))
        }
        packed.append(quantizeQ2(downRow))
        return packed
    }

    /// Compute byte size of one Q2-quantized neuron.
    static func neuronByteSize(hiddenSize: Int, hasGate: Bool) -> Int {
        let blockSize = Q2Block.blockSize
        let bytesPerBlock = 2 + blockSize / 4
        let blocksPerVec = (hiddenSize + blockSize - 1) / blockSize
        let parts = hasGate ? 3 : 2
        return parts * blocksPerVec * bytesPerBlock
    }

    // MARK: - RMSE Quality Check

    /// Compute RMSE between original and quantized/dequantized values.
    ///
    /// Per flash-moe target: RMSE < 0.003 for acceptable quality.
    static func rmse(original: [Float], quantized: [Float]) -> Float {
        guard original.count == quantized.count, !original.isEmpty else { return .infinity }
        var sumSqErr: Float = 0
        vDSP_measqv(original, 1, &sumSqErr, vDSP_Length(original.count))  // E[x²]
        var diff = [Float](repeating: 0, count: original.count)
        vDSP_vsub(quantized, 1, original, 1, &diff, 1, vDSP_Length(original.count))
        var errSq: Float = 0
        vDSP_measqv(diff, 1, &errSq, vDSP_Length(diff.count))
        return sqrtf(errSq)
    }

    /// Test Q2 quantization quality on a random weight vector.
    /// Returns RMSE — should be < 0.003 for typical LLM weight distributions.
    static func benchmarkQ2(hiddenSize: Int = 4096) -> Float {
        let original = (0..<hiddenSize).map { _ in Float.random(in: -0.1...0.1) }
        let packed = quantizeQ2(original)
        let restored = dequantizeQ2(packed, count: hiddenSize)
        return rmse(original: original, quantized: restored)
    }

    // MARK: - Q8 (8-bit) Quantization

    /// Quantize to Q8 (symmetric, per-block).
    ///
    /// Block format: [scale: float16 (2 bytes)][values: int8 × blockSize]
    static func quantizeQ8(_ input: [Float], blockSize: Int = 32) -> Data {
        let nBlocks = (input.count + blockSize - 1) / blockSize
        let bytesPerBlock = 2 + blockSize  // 2-byte scale + blockSize int8 values
        var output = Data(count: nBlocks * bytesPerBlock)

        output.withUnsafeMutableBytes { outPtr in
            let base = outPtr.baseAddress!
            for b in 0..<nBlocks {
                let start = b * blockSize
                let end = min(start + blockSize, input.count)
                var maxAbs: Float = 0
                for i in start..<end { maxAbs = max(maxAbs, abs(input[i])) }
                let scale = maxAbs > 1e-8 ? maxAbs / 127.0 : 1.0
                let scaleF16 = Float16(scale)
                base.advanced(by: b * bytesPerBlock).bindMemory(to: Float16.self, capacity: 1).pointee = scaleF16
                let invScale = scale > 1e-8 ? 1.0 / scale : 0.0
                let int8Ptr = base.advanced(by: b * bytesPerBlock + 2).bindMemory(to: Int8.self, capacity: blockSize)
                for i in 0..<blockSize {
                    let val = start + i < end ? input[start + i] : 0.0
                    let q = max(-127, min(127, Int(val * invScale)))
                    int8Ptr[i] = Int8(q)
                }
            }
        }
        return output
    }

    /// Dequantize Q8 bytes back to Float32.
    static func dequantizeQ8(_ data: Data, count: Int, blockSize: Int = 32) -> [Float] {
        let bytesPerBlock = 2 + blockSize
        let nBlocks = (count + blockSize - 1) / blockSize
        var output = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { rawPtr in
            let base = rawPtr.baseAddress!
            for b in 0..<nBlocks {
                let blockStart = b * bytesPerBlock
                guard blockStart + bytesPerBlock <= data.count else { break }
                let scale = Float(base.advanced(by: blockStart).bindMemory(to: Float16.self, capacity: 1).pointee)
                let int8Ptr = base.advanced(by: blockStart + 2).bindMemory(to: Int8.self, capacity: blockSize)
                let outStart = b * blockSize
                for i in 0..<blockSize {
                    let idx = outStart + i
                    guard idx < count else { break }
                    output[idx] = Float(int8Ptr[i]) * scale
                }
            }
        }
        return output
    }
}

// MARK: - Per-Layer Quantization Stats

/// Statistics gathered during layer quantization.
struct LayerQuantStats: Sendable {
    let layerIndex: Int
    let rmseUpProj: Float
    let rmseDownProj: Float
    let rmseGateProj: Float?
    let compressionRatio: Double
    let originalBytes: Int
    let quantizedBytes: Int

    var meetsQualityTarget: Bool {
        rmseUpProj < 0.003 && rmseDownProj < 0.003
    }

    var summary: String {
        let gateStr = rmseGateProj.map { String(format: "gate=%.4f ", $0) } ?? ""
        return "Layer \(layerIndex): up=\(String(format: "%.4f", rmseUpProj)) " +
               "down=\(String(format: "%.4f", rmseDownProj)) \(gateStr)" +
               "(\(String(format: "%.1f", compressionRatio))×)"
    }
}

// MARK: - Streaming Neuron Quantizer

/// Quantizes and writes neurons one at a time — used by the converter
/// to avoid loading the entire model weight matrix at once.
final class NeuronQuantizer: @unchecked Sendable {

    let hiddenSize: Int
    let hasGate: Bool
    let quantization: FlashDType
    let blockSize: Int

    private(set) var processedNeurons: Int = 0
    private(set) var totalOriginalBytes: Int = 0
    private(set) var totalQuantizedBytes: Int = 0

    init(hiddenSize: Int, hasGate: Bool, quantization: FlashDType, blockSize: Int = Q2Block.blockSize) {
        self.hiddenSize = hiddenSize
        self.hasGate = hasGate
        self.quantization = quantization
        self.blockSize = blockSize
    }

    /// Process one neuron and return quantized bytes.
    func quantizeNeuron(upCol: [Float], gateCol: [Float]?, downRow: [Float]) -> Data {
        let original = (hasGate ? 3 : 2) * hiddenSize * MemoryLayout<Float32>.size
        totalOriginalBytes += original

        let quantized: Data
        switch quantization {
        case .int4:  // Q2 2-bit
            quantized = FlashQuantization.quantizeNeuron(upCol: upCol, gateCol: gateCol, downRow: downRow)
        case .int8:  // Q8 8-bit
            var d = FlashQuantization.quantizeQ8(upCol, blockSize: blockSize)
            if let gate = gateCol { d.append(FlashQuantization.quantizeQ8(gate, blockSize: blockSize)) }
            d.append(FlashQuantization.quantizeQ8(downRow, blockSize: blockSize))
            quantized = d
        default:     // F16 — convert float32 to float16
            quantized = float32ToFloat16Data(upCol, gateCol, downRow)
        }

        totalQuantizedBytes += quantized.count
        processedNeurons += 1
        return quantized
    }

    var compressionRatio: Double {
        guard totalQuantizedBytes > 0 else { return 1.0 }
        return Double(totalOriginalBytes) / Double(totalQuantizedBytes)
    }

    private func float32ToFloat16Data(_ up: [Float], _ gate: [Float]?, _ down: [Float]) -> Data {
        var result = Data()
        result.append(floatsToF16Data(up))
        if let g = gate { result.append(floatsToF16Data(g)) }
        result.append(floatsToF16Data(down))
        return result
    }

    private func floatsToF16Data(_ floats: [Float]) -> Data {
        let f16 = floats.map { Float16($0) }
        return f16.withUnsafeBytes { Data($0) }
    }
}
