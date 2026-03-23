import Metal
import Foundation

// MARK: - Flash Metal Pipeline
//
// Manages the Metal compute pipeline for GPU-accelerated flash inference.
//
// Architecture on Apple Silicon:
//   CPU → (shared memory, zero-copy) → GPU → output
//
// Using MTLStorageModeShared buffers means weights loaded from flash by the CPU
// are immediately visible to the GPU with no additional memcpy.
//
// Pipeline steps per token:
//   1. Attention projections: flash_matvec_f32 (Q, K, V, O)
//   2. Attention scores:      flash_attn_scores
//   3. Softmax:               flash_softmax
//   4. Value weighted sum:    flash_attn_weighted_sum
//   5. Sparse up-projection:  flash_sparse_up_proj
//   6. Activation (SwiGLU):   flash_swiglu
//   7. Sparse down-proj:      flash_sparse_down_proj_tiled
//   8. Residual adds:         flash_vector_add
//   9. RMSNorm:               flash_rmsnorm
//   10. RoPE:                 flash_rope
//   11. LM head:              flash_matvec_f32

// MARK: - Kernel Names

enum FlashKernel: String, CaseIterable {
    case matvecF32          = "flash_matvec_f32"
    case matvecF16          = "flash_matvec_f16"
    case sparseDownProj     = "flash_sparse_down_proj"
    case sparseDownProjTiled = "flash_sparse_down_proj_tiled"
    case sparseUpProj       = "flash_sparse_up_proj"
    case swiGLU             = "flash_swiglu"
    case relu               = "flash_relu"
    case relu2              = "flash_relu2"
    case rmsNorm            = "flash_rmsnorm"
    case softmax            = "flash_softmax"
    case attnScores         = "flash_attn_scores"
    case attnWeightedSum    = "flash_attn_weighted_sum"
    case dequantizeQ2       = "flash_dequantize_q2"
    case rope               = "flash_rope"
    case vectorAdd          = "flash_vector_add"
}

// MARK: - Pipeline State Cache

/// Pre-compiled compute pipeline states for all flash kernels.
final class FlashMetalPipeline: @unchecked Sendable {

    // MARK: - Properties

    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    private var pipelineStates: [FlashKernel: MTLComputePipelineState] = [:]
    private let lock = NSLock()

    // Thread sizes
    let defaultThreadsPerGroup: Int = 256

    // MARK: - Initialisation

    /// Create a Metal pipeline, compiling all kernels from the default library.
    ///
    /// - Throws: `FlashMetalError` if Metal is unavailable or shader compilation fails.
    init() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw FlashMetalError.deviceNotAvailable
        }
        guard let queue = dev.makeCommandQueue() else {
            throw FlashMetalError.commandQueueFailed
        }

        self.device = dev
        self.commandQueue = queue

        try compileAllKernels()
    }

    // MARK: - Buffer Allocation

    /// Allocate a shared (zero-copy CPU+GPU) float buffer.
    func makeFloatBuffer(count: Int, label: String? = nil) -> MTLBuffer? {
        let buf = device.makeBuffer(
            length: count * MemoryLayout<Float>.stride,
            options: .storageModeShared
        )
        buf?.label = label
        return buf
    }

    /// Allocate a shared buffer from existing float data.
    func makeFloatBuffer(from data: [Float], label: String? = nil) -> MTLBuffer? {
        let buf = device.makeBuffer(
            bytes: data,
            length: data.count * MemoryLayout<Float>.stride,
            options: .storageModeShared
        )
        buf?.label = label
        return buf
    }

    /// Allocate a shared byte buffer (for Q2/Q8 quantized weights).
    func makeByteBuffer(from data: Data, label: String? = nil) -> MTLBuffer? {
        let buf = data.withUnsafeBytes { ptr in
            device.makeBuffer(bytes: ptr.baseAddress!, length: data.count, options: .storageModeShared)
        }
        buf?.label = label
        return buf
    }

    // MARK: - Kernel Dispatch

    /// Dispatch a matrix-vector multiply: y = A × x
    func matVecMul(
        A: MTLBuffer, rows: Int, cols: Int,
        x: MTLBuffer,
        y: MTLBuffer,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let state = pipeline(for: .matvecF32) else { return }
        let encoder = commandBuffer.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(state)
        encoder.setBuffer(A, offset: 0, index: 0)
        encoder.setBuffer(x, offset: 0, index: 1)
        encoder.setBuffer(y, offset: 0, index: 2)
        var M = UInt32(rows), N = UInt32(cols)
        encoder.setBytes(&M, length: 4, index: 3)
        encoder.setBytes(&N, length: 4, index: 4)
        encoder.dispatchThreads(MTLSize(width: rows, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(256, rows), height: 1, depth: 1))
        encoder.endEncoding()
    }

    /// Dispatch sparse down-projection: output[i] += Σ(activations[j] × down_rows[j][i])
    func sparseDownProj(
        downRows: MTLBuffer,
        activations: MTLBuffer,
        output: MTLBuffer,
        activeCount: Int,
        hiddenSize: Int,
        commandBuffer: MTLCommandBuffer
    ) {
        // Use tiled variant for better perf
        guard let state = pipeline(for: .sparseDownProjTiled) else { return }
        let encoder = commandBuffer.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(state)
        encoder.setBuffer(downRows, offset: 0, index: 0)
        encoder.setBuffer(activations, offset: 0, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        var ac = UInt32(activeCount), hs = UInt32(hiddenSize)
        encoder.setBytes(&ac, length: 4, index: 3)
        encoder.setBytes(&hs, length: 4, index: 4)
        let tgSize = 256
        encoder.setThreadgroupMemoryLength(tgSize * MemoryLayout<Float>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: hiddenSize, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: tgSize, height: 1, depth: 1))
        encoder.endEncoding()
    }

    /// Dispatch sparse up-projection: up_out[j] = dot(x, up_cols[j])
    func sparseUpProj(
        upCols: MTLBuffer,
        x: MTLBuffer,
        upOut: MTLBuffer,
        activeCount: Int,
        hiddenSize: Int,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let state = pipeline(for: .sparseUpProj) else { return }
        let encoder = commandBuffer.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(state)
        encoder.setBuffer(upCols, offset: 0, index: 0)
        encoder.setBuffer(x, offset: 0, index: 1)
        encoder.setBuffer(upOut, offset: 0, index: 2)
        var ac = UInt32(activeCount), hs = UInt32(hiddenSize)
        encoder.setBytes(&ac, length: 4, index: 3)
        encoder.setBytes(&hs, length: 4, index: 4)
        encoder.dispatchThreads(MTLSize(width: activeCount, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(256, activeCount), height: 1, depth: 1))
        encoder.endEncoding()
    }

    /// Dispatch SwiGLU activation: out = SiLU(gate) × up
    func swiGLU(
        gate: MTLBuffer,
        up: MTLBuffer,
        out: MTLBuffer,
        count: Int,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let state = pipeline(for: .swiGLU) else { return }
        let encoder = commandBuffer.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(state)
        encoder.setBuffer(gate, offset: 0, index: 0)
        encoder.setBuffer(up, offset: 0, index: 1)
        encoder.setBuffer(out, offset: 0, index: 2)
        var n = UInt32(count)
        encoder.setBytes(&n, length: 4, index: 3)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(256, count), height: 1, depth: 1))
        encoder.endEncoding()
    }

    /// Dispatch RMSNorm: y = (x / RMS(x)) × weight
    func rmsNorm(
        x: MTLBuffer,
        weight: MTLBuffer,
        y: MTLBuffer,
        size: Int,
        eps: Float = 1e-5,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let state = pipeline(for: .rmsNorm) else { return }
        let encoder = commandBuffer.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(state)
        encoder.setBuffer(x, offset: 0, index: 0)
        encoder.setBuffer(weight, offset: 0, index: 1)
        encoder.setBuffer(y, offset: 0, index: 2)
        var n = UInt32(size); var e = eps
        encoder.setBytes(&n, length: 4, index: 3)
        encoder.setBytes(&e, length: 4, index: 4)
        let tgSize = min(256, size)
        encoder.setThreadgroupMemoryLength(tgSize * MemoryLayout<Float>.stride, index: 0)
        // Single threadgroup processes the whole vector via loop in shader
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tgSize, height: 1, depth: 1))
        encoder.endEncoding()
    }

    /// Dispatch RoPE position embedding (in-place)
    func rope(
        x: MTLBuffer,
        numHeads: Int,
        headDim: Int,
        position: Int,
        theta: Float = 10000.0,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let state = pipeline(for: .rope) else { return }
        let encoder = commandBuffer.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(state)
        encoder.setBuffer(x, offset: 0, index: 0)
        var nh = UInt32(numHeads), hd = UInt32(headDim), pos = UInt32(position), t = theta
        encoder.setBytes(&nh, length: 4, index: 1)
        encoder.setBytes(&hd, length: 4, index: 2)
        encoder.setBytes(&pos, length: 4, index: 3)
        encoder.setBytes(&t, length: 4, index: 4)
        encoder.dispatchThreads(MTLSize(width: numHeads, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(256, numHeads), height: 1, depth: 1))
        encoder.endEncoding()
    }

    /// Dispatch vector add: a += b (residual connection)
    func vectorAdd(
        a: MTLBuffer,
        b: MTLBuffer,
        count: Int,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let state = pipeline(for: .vectorAdd) else { return }
        let encoder = commandBuffer.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(state)
        encoder.setBuffer(a, offset: 0, index: 0)
        encoder.setBuffer(b, offset: 0, index: 1)
        var n = UInt32(count)
        encoder.setBytes(&n, length: 4, index: 2)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(256, count), height: 1, depth: 1))
        encoder.endEncoding()
    }

    /// Dispatch Q2 dequantization
    func dequantizeQ2(
        packed: MTLBuffer,
        output: MTLBuffer,
        count: Int,
        blockSize: Int = 32,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let state = pipeline(for: .dequantizeQ2) else { return }
        let encoder = commandBuffer.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(state)
        encoder.setBuffer(packed, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        var n = UInt32(count), bs = UInt32(blockSize)
        encoder.setBytes(&n, length: 4, index: 2)
        encoder.setBytes(&bs, length: 4, index: 3)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(256, count), height: 1, depth: 1))
        encoder.endEncoding()
    }

    // MARK: - Full Token Step Helper

    /// Execute the complete sparse FFN forward pass on GPU.
    ///
    /// This is the hottest path in flash inference:
    ///   1. Sparse up-projection (CPU already predicted active neurons)
    ///   2. Activation (SwiGLU or ReLU)
    ///   3. Sparse down-projection
    ///   4. Add to residual
    ///
    /// Returns the command buffer (caller must commit + wait).
    func executeSparsFFN(
        normOutput: MTLBuffer,        // [hiddenSize] — post-attention RMSNorm output
        activeUpCols: MTLBuffer,      // [activeCount × hiddenSize] packed up-proj cols
        activeGateCols: MTLBuffer?,   // [activeCount × hiddenSize] packed gate cols (nil if no gate)
        activeDownRows: MTLBuffer,    // [activeCount × hiddenSize] packed down-proj rows
        residual: MTLBuffer,          // [hiddenSize] — accumulated residual (modified in-place)
        upOut: MTLBuffer,             // [activeCount] scratch
        gateOut: MTLBuffer?,          // [activeCount] scratch (nil if no gate)
        activatedOut: MTLBuffer,      // [activeCount] scratch for post-activation values
        activeCount: Int,
        hiddenSize: Int,
        useGate: Bool
    ) -> MTLCommandBuffer? {
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return nil }
        cmdBuf.label = "FlashSparsFFN"

        // 1. Sparse up-projection
        sparseUpProj(upCols: activeUpCols, x: normOutput, upOut: upOut,
                     activeCount: activeCount, hiddenSize: hiddenSize,
                     commandBuffer: cmdBuf)

        if useGate, let gateCols = activeGateCols, let gOut = gateOut {
            // 2a. Gate projection
            sparseUpProj(upCols: gateCols, x: normOutput, upOut: gOut,
                         activeCount: activeCount, hiddenSize: hiddenSize,
                         commandBuffer: cmdBuf)
            // 2b. SwiGLU: activatedOut = SiLU(gate) × up
            swiGLU(gate: gOut, up: upOut, out: activatedOut,
                   count: activeCount, commandBuffer: cmdBuf)
        } else {
            // 2c. ReLU activation directly on upOut → activatedOut
            if let state = pipeline(for: .relu) {
                let encoder = cmdBuf.makeComputeCommandEncoder()!
                encoder.setComputePipelineState(state)
                // Copy upOut → activatedOut first via vector add with zero
                // (simpler: just use upOut directly as activations, in-place ReLU)
                encoder.setBuffer(upOut, offset: 0, index: 0)
                var n = UInt32(activeCount)
                encoder.setBytes(&n, length: 4, index: 1)
                encoder.dispatchThreads(MTLSize(width: activeCount, height: 1, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: min(256, activeCount), height: 1, depth: 1))
                encoder.endEncoding()
            }
            // Use upOut as activatedOut
        }

        // 3. Sparse down-projection: residual += Σ(activated[j] × down_rows[j])
        let activations = useGate ? activatedOut : upOut
        sparseDownProj(downRows: activeDownRows, activations: activations,
                       output: residual, activeCount: activeCount,
                       hiddenSize: hiddenSize, commandBuffer: cmdBuf)

        return cmdBuf
    }

    // MARK: - Device Info

    var isAppleSilicon: Bool {
        device.name.contains("Apple") || device.hasUnifiedMemory
    }

    var maxThreadsPerGroup: Int {
        Int(device.maxThreadsPerThreadgroup.width)
    }

    var recommendedThreadsPerGroup: Int {
        isAppleSilicon ? 256 : 128
    }

    // MARK: - Private

    private func pipeline(for kernel: FlashKernel) -> MTLComputePipelineState? {
        lock.lock()
        defer { lock.unlock() }
        return pipelineStates[kernel]
    }

    private func compileAllKernels() throws {
        // Load the default Metal library (compiled from FlashShaders.metal)
        guard let library = device.makeDefaultLibrary() else {
            throw FlashMetalError.libraryLoadFailed
        }

        for kernel in FlashKernel.allCases {
            guard let function = library.makeFunction(name: kernel.rawValue) else {
                // Not all kernels may be present in all builds — skip missing ones
                continue
            }
            do {
                let state = try device.makeComputePipelineState(function: function)
                lock.lock()
                pipelineStates[kernel] = state
                lock.unlock()
            } catch {
                throw FlashMetalError.kernelCompileFailed(kernel.rawValue, error.localizedDescription)
            }
        }
    }
}

// MARK: - Metal Error Types

enum FlashMetalError: Error, LocalizedError {
    case deviceNotAvailable
    case commandQueueFailed
    case libraryLoadFailed
    case kernelCompileFailed(String, String)
    case bufferAllocationFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotAvailable:
            return "No Metal-capable GPU found on this device"
        case .commandQueueFailed:
            return "Failed to create Metal command queue"
        case .libraryLoadFailed:
            return "Failed to load Metal shader library (FlashShaders.metal)"
        case .kernelCompileFailed(let name, let reason):
            return "Metal kernel '\(name)' failed to compile: \(reason)"
        case .bufferAllocationFailed(let name):
            return "Failed to allocate Metal buffer: \(name)"
        }
    }
}

// MARK: - GPU-Backed Working Buffers

/// Pre-allocated Metal buffers for the transformer forward pass.
/// Reused across tokens to avoid per-token allocation overhead.
final class FlashGPUBuffers: @unchecked Sendable {

    let hidden: MTLBuffer         // [hiddenSize]
    let residual: MTLBuffer       // [hiddenSize]
    let norm: MTLBuffer           // [hiddenSize]
    let q: MTLBuffer              // [numHeads × headDim]
    let k: MTLBuffer              // [numKVHeads × headDim]
    let v: MTLBuffer              // [numKVHeads × headDim]
    let attnOut: MTLBuffer        // [numHeads × headDim]
    let ffnUp: MTLBuffer          // [activeCount] scratch
    let ffnGate: MTLBuffer        // [activeCount] scratch
    let ffnActivated: MTLBuffer   // [activeCount] scratch
    let logits: MTLBuffer         // [vocabSize]

    // Active neuron data buffers (resized per token)
    var activeUpCols: MTLBuffer?
    var activeGateCols: MTLBuffer?
    var activeDownRows: MTLBuffer?

    init?(pipeline: FlashMetalPipeline, config: FlashModelConfig) {
        let h = config.hiddenSize
        let nh = config.numAttentionHeads
        let nkv = config.numKeyValueHeads
        let hd = config.headDim
        let maxActive = config.intermediateSize  // Worst case: all neurons
        let vocab = config.vocabSize

        let dev = pipeline.device
        guard
            let hid = dev.makeBuffer(length: h * 4, options: .storageModeShared),
            let res = dev.makeBuffer(length: h * 4, options: .storageModeShared),
            let nrm = dev.makeBuffer(length: h * 4, options: .storageModeShared),
            let qb  = dev.makeBuffer(length: nh * hd * 4, options: .storageModeShared),
            let kb  = dev.makeBuffer(length: nkv * hd * 4, options: .storageModeShared),
            let vb  = dev.makeBuffer(length: nkv * hd * 4, options: .storageModeShared),
            let ao  = dev.makeBuffer(length: nh * hd * 4, options: .storageModeShared),
            let fup = dev.makeBuffer(length: maxActive * 4, options: .storageModeShared),
            let fgt = dev.makeBuffer(length: maxActive * 4, options: .storageModeShared),
            let fac = dev.makeBuffer(length: maxActive * 4, options: .storageModeShared),
            let lg  = dev.makeBuffer(length: vocab * 4, options: .storageModeShared)
        else { return nil }

        hidden = hid; residual = res; norm = nrm
        q = qb; k = kb; v = vb; attnOut = ao
        ffnUp = fup; ffnGate = fgt; ffnActivated = fac
        logits = lg

        [hidden, residual, norm, q, k, v, attnOut, ffnUp, ffnGate, ffnActivated, logits]
            .enumerated().forEach { $0.element.label = "flash_\($0.offset)" }
    }

    /// Resize active neuron buffers for a new set of active neurons.
    func resizeActiveBuffers(pipeline: FlashMetalPipeline, activeCount: Int, hiddenSize: Int, hasGate: Bool) {
        let size = activeCount * hiddenSize * 4
        activeUpCols = pipeline.device.makeBuffer(length: size, options: .storageModeShared)
        activeUpCols?.label = "flash_active_up_cols"
        activeDownRows = pipeline.device.makeBuffer(length: size, options: .storageModeShared)
        activeDownRows?.label = "flash_active_down_rows"
        if hasGate {
            activeGateCols = pipeline.device.makeBuffer(length: size, options: .storageModeShared)
            activeGateCols?.label = "flash_active_gate_cols"
        }
    }

    /// Copy a float array into a Metal buffer (CPU → GPU via shared memory — zero-copy on Apple Silicon).
    func fill(_ buf: MTLBuffer, with floats: [Float]) {
        floats.withUnsafeBufferPointer { ptr in
            let bytes = ptr.count * MemoryLayout<Float>.stride
            memcpy(buf.contents(), ptr.baseAddress!, bytes)
        }
    }

    /// Read float data from a Metal buffer back to CPU.
    func read(_ buf: MTLBuffer, count: Int) -> [Float] {
        let ptr = buf.contents().bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }
}
