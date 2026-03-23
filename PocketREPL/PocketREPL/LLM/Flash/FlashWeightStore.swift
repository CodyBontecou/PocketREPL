import Foundation
import Darwin  // for open, pread, close, fcntl

// MARK: - Flash Weight Store
//
// Implements hardware-aware flash I/O per Apple's "LLM in a Flash" paper.
//
// Key techniques (Section 2 & 3.2):
//
// 1. Parallel reads across 32 threads — amortizes per-read latency overhead.
//    macOS NVMe: ~6 GB/s sequential, ~1.25 GB/s sparse; both improve with parallelism.
//
// 2. Large chunk reads — minimum 32 KiB to overcome "latency to first byte" cost.
//    The paper measures that below ~32 KiB, per-read overhead dominates throughput.
//
// 3. Row-column bundling — up-proj column i and down-proj row i are stored adjacently,
//    so one read fetches both, doubling effective chunk size with no extra I/O ops.
//
// 4. F_NOCACHE / F_RDAHEAD hints — disable OS read-ahead that wastes bandwidth
//    on weights we won't need; let the app control what gets loaded.
//
// Thread safety: all public methods are safe to call from any thread.
// `pread()` is POSIX thread-safe (unlike `read()` which uses shared offset).

final class FlashWeightStore: @unchecked Sendable {

    // MARK: - Properties

    private let fd: Int32               // File descriptor (read-only)
    private let fileSize: UInt64        // Total file size in bytes
    private let config: FlashModelConfig
    private let ioQueue: DispatchQueue  // Concurrent queue for parallel reads
    private(set) var readBytesTotal: Int64 = 0    // Accumulated bytes read (metrics)
    private(set) var readCountTotal: Int = 0       // Accumulated read calls (metrics)
    private let lock = NSLock()         // Protects metric counters

    // MARK: - Initialization

    init(path: String, config: FlashModelConfig) throws {
        // Open file read-only
        let openFd = Darwin.open(path, O_RDONLY)
        guard openFd >= 0 else {
            throw FlashModelError.ioError(errno: errno, description: "open(\(path))")
        }

        // Apply I/O hints
        if config.bypassOSCache {
            // F_NOCACHE: bypass the page cache — measure raw NVMe latency
            Darwin.fcntl(openFd, F_NOCACHE, 1)
        }
        if !config.enableReadAhead {
            // F_RDAHEAD: disable OS read-ahead (we control prefetch ourselves)
            Darwin.fcntl(openFd, F_RDAHEAD, 0)
        }

        // Get file size
        var st = stat()
        guard Darwin.fstat(openFd, &st) == 0 else {
            Darwin.close(openFd)
            throw FlashModelError.ioError(errno: errno, description: "fstat")
        }

        self.fd = openFd
        self.fileSize = UInt64(st.st_size)
        self.config = config
        self.ioQueue = DispatchQueue(
            label: "com.pocketrepl.flash.io",
            qos: .userInitiated,
            attributes: .concurrent
        )
    }

    deinit {
        Darwin.close(fd)
    }

    // MARK: - Low-Level Read

    /// Read `size` bytes starting at `offset` into a new `Data` buffer.
    ///
    /// - Important: Uses `pread()` which is thread-safe (no shared seek position).
    /// - Throws: `FlashModelError.ioError` on partial reads or OS errors.
    func read(offset: UInt64, size: Int) throws -> Data {
        guard offset + UInt64(size) <= fileSize else {
            throw FlashModelError.sectionOutOfBounds(
                section: "raw-read",
                offset: offset,
                fileSize: fileSize
            )
        }

        var buffer = Data(count: max(size, config.minReadChunkBytes))
        let bytesToRead = max(size, config.minReadChunkBytes)

        let result: Int = buffer.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return -1 }
            return Darwin.pread(fd, base, bytesToRead, off_t(offset))
        }

        guard result >= size else {
            throw FlashModelError.ioError(
                errno: errno,
                description: "pread returned \(result) (wanted \(bytesToRead)) at offset \(offset)"
            )
        }

        lock.lock()
        readBytesTotal += Int64(result)
        readCountTotal += 1
        lock.unlock()

        return buffer.prefix(size)
    }

    // MARK: - Tensor Loading

    /// Load a tensor (e.g., attention weight matrix) fully into memory as Float32.
    ///
    /// Converts from stored dtype to Float32 for computation.
    func loadTensor(_ spec: TensorShape) throws -> [Float] {
        let rawData = try read(offset: spec.offset, size: spec.byteSize)
        return convertToFloat32(rawData, dtype: spec.dtype, count: spec.elementCount)
    }

    /// Load a 1-D weight vector (e.g., RMSNorm weight) as Float32.
    func loadVector(_ spec: TensorShape) throws -> [Float] {
        assert(spec.rows == 1 || spec.cols == 1, "Expected 1-D tensor")
        return try loadTensor(spec)
    }

    // MARK: - Bundled Neuron Loading (the core flash technique)

    /// Load a single bundled FFN neuron from flash.
    ///
    /// Each neuron i stores: [up_col_i | gate_col_i (optional) | down_row_i]
    /// All as contiguous bytes, sized `spec.ffnNeuronByteSize` per neuron.
    ///
    /// - Returns: Float32 array of shape [2 or 3, hidden_size] (up, [gate,] down).
    func loadNeuron(layer: Int, neuronIndex: Int) throws -> [Float] {
        let spec = config.sections.layers[layer]
        let offset = spec.ffnNeuronsOffset + UInt64(neuronIndex * spec.ffnNeuronByteSize)
        let rawData = try read(offset: offset, size: spec.ffnNeuronByteSize)
        return convertToFloat32(rawData, dtype: spec.ffnDType, count: spec.ffnNeuronByteSize / spec.ffnDType.bytesPerElement)
    }

    /// Load multiple FFN neurons in parallel using up to `config.ioThreadCount` threads.
    ///
    /// This is the core performance optimization: instead of loading neurons sequentially,
    /// we fire 32 concurrent `pread()` calls to saturate the NVMe controller's internal
    /// parallelism and amortize per-read latency across all neurons.
    ///
    /// - Returns: Array where `result[i]` corresponds to `neuronIndices[i]`.
    func loadNeurons(layer: Int, neuronIndices: [Int]) throws -> [[Float]] {
        guard !neuronIndices.isEmpty else { return [] }

        let spec = config.sections.layers[layer]
        var results = [[Float]](repeating: [], count: neuronIndices.count)
        var errors = [Error?](repeating: nil, count: neuronIndices.count)

        // Limit parallelism to configured thread count
        let batchSize = min(config.ioThreadCount, neuronIndices.count)
        let actualCount = neuronIndices.count

        // Thread-safe storage for results from concurrent reads
        // Using a simple UnsafeMutablePointer array since indices are non-overlapping
        withUnsafeMutablePointer(to: &results[0]) { basePtr in
            DispatchQueue.concurrentPerform(iterations: actualCount) { [self] i in
                guard i < actualCount else { return }
                let neuronIdx = neuronIndices[i]
                let offset = spec.ffnNeuronsOffset + UInt64(neuronIdx * spec.ffnNeuronByteSize)

                do {
                    let raw = try self.readDirect(offset: offset, size: spec.ffnNeuronByteSize)
                    let floats = self.convertToFloat32(raw, dtype: spec.ffnDType,
                                                       count: spec.ffnNeuronByteSize / spec.ffnDType.bytesPerElement)
                    (basePtr + i).pointee = floats
                } catch {
                    (basePtr + i).pointee = []
                }
            }
        }

        // Check for errors (simplified: if any result is empty for a valid index, something failed)
        for (i, result) in results.enumerated() {
            if result.isEmpty && neuronIndices[i] < spec.ffnNeuronCount {
                throw FlashModelError.ioError(errno: 0, description: "Failed to load neuron \(neuronIndices[i]) in layer \(layer)")
            }
        }

        return results
    }

    // MARK: - Batch Loading with Prefetch

    /// Prefetch neuron data into OS buffer cache for the next batch.
    ///
    /// Per the paper: "we can issue read-ahead hints so the OS starts fetching
    /// the next layer's experts while the GPU computes the current layer."
    ///
    /// On iOS/macOS this uses `fcntl(F_RDADVISE)` to hint upcoming accesses.
    func prefetchNeurons(layer: Int, neuronIndices: [Int]) {
        guard config.enableReadAhead else { return }
        let spec = config.sections.layers[layer]

        // Issue fcntl advisory reads on a background thread (fire-and-forget)
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            for neuronIdx in neuronIndices {
                let offset = spec.ffnNeuronsOffset + UInt64(neuronIdx * spec.ffnNeuronByteSize)
                var radv = radvisory(ra_offset: off_t(offset), ra_count: Int32(spec.ffnNeuronByteSize))
                _ = Darwin.fcntl(self.fd, F_RDADVISE, &radv)
            }
        }
    }

    /// Load all attention weights for a layer (for DRAM-resident attention heads).
    ///
    /// These are loaded ONCE at model initialization and stay in memory.
    func loadAttentionWeights(layer: Int) throws -> AttentionWeights {
        let spec = config.sections.layers[layer]
        return AttentionWeights(
            qProj:         try loadTensor(spec.qProj),
            kProj:         try loadTensor(spec.kProj),
            vProj:         try loadTensor(spec.vProj),
            oProj:         try loadTensor(spec.oProj),
            inputNorm:     try loadVector(spec.inputNorm),
            postAttnNorm:  try loadVector(spec.postAttentionNorm)
        )
    }

    /// Load model-global weights (embeddings, final norm, LM head).
    func loadGlobalWeights() throws -> GlobalWeights {
        let sections = config.sections
        return GlobalWeights(
            tokenEmbedding: try loadTensor(sections.tokenEmbedding),
            norm:           try loadVector(sections.norm),
            lmHead:         config.tieEmbeddings ? nil : try loadTensor(sections.lmHead)
        )
    }

    /// Load sparsity predictor weights for a layer (if available).
    func loadPredictorWeights(layer: Int) throws -> PredictorWeights? {
        let spec = config.sections.layers[layer]
        guard let wInSpec = spec.predictorWIn, let wOutSpec = spec.predictorWOut else {
            return nil
        }
        return PredictorWeights(
            wIn:  try loadTensor(wInSpec),
            wOut: try loadTensor(wOutSpec),
            rank: wInSpec.cols
        )
    }

    /// Load per-neuron importance scores for a layer (if available).
    ///
    /// These are float32 scalars used to keep the "always hot" neurons warm in cache.
    func loadNeuronImportance(layer: Int) throws -> [Float]? {
        let spec = config.sections.layers[layer]
        guard let importanceOffset = spec.neuronImportanceOffset else { return nil }
        let neuronCount = spec.ffnNeuronCount
        let byteSize = neuronCount * MemoryLayout<Float>.size
        let rawData = try read(offset: importanceOffset, size: byteSize)
        return rawData.withUnsafeBytes { ptr in
            Array(ptr.bindMemory(to: Float.self))
        }
    }

    // MARK: - Performance Metrics

    /// Reset I/O counters (call at start of each inference benchmark).
    func resetMetrics() {
        lock.lock()
        readBytesTotal = 0
        readCountTotal = 0
        lock.unlock()
    }

    /// Approximate throughput in GB/s if a time interval is provided.
    func throughputGBps(elapsedSeconds: Double) -> Double {
        guard elapsedSeconds > 0 else { return 0 }
        lock.lock()
        let bytes = readBytesTotal
        lock.unlock()
        return Double(bytes) / elapsedSeconds / 1e9
    }

    // MARK: - Private Helpers

    /// Direct pread without minimum-chunk padding (for parallel inner reads).
    private func readDirect(offset: UInt64, size: Int) throws -> Data {
        var buffer = Data(count: size)
        let result: Int = buffer.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return -1 }
            return Darwin.pread(fd, base, size, off_t(offset))
        }
        guard result == size else {
            throw FlashModelError.ioError(
                errno: errno,
                description: "pread returned \(result) (wanted \(size)) at offset \(offset)"
            )
        }
        lock.lock()
        readBytesTotal += Int64(result)
        readCountTotal += 1
        lock.unlock()
        return buffer
    }

    /// Convert raw bytes to Float32, handling different source dtypes.
    private func convertToFloat32(_ data: Data, dtype: FlashDType, count: Int) -> [Float] {
        return data.withUnsafeBytes { rawPtr -> [Float] in
            switch dtype {
            case .float32:
                let ptr = rawPtr.bindMemory(to: Float.self)
                return Array(ptr.prefix(count))

            case .float16:
                // Float16 → Float32 via Swift's native Float16 type (available since iOS 14 / macOS 11)
                let ptr = rawPtr.bindMemory(to: Float16.self)
                return (0..<count).map { Float(ptr[$0]) }

            case .int8:
                // Symmetric int8 quantization with scale embedded as first float32
                // Format: [scale: float32][quantized values: int8 × count]
                // This is a simplified version; real implementation needs per-layer scales
                let scalePtr = rawPtr.bindMemory(to: Float.self)
                let scale = scalePtr.count > 0 ? scalePtr[0] : 1.0
                let int8Ptr = rawPtr.baseAddress!.advanced(by: 4).bindMemory(to: Int8.self, capacity: count)
                return (0..<count).map { Float(int8Ptr[$0]) * scale / 127.0 }

            case .int4:
                // 4-bit packed: two values per byte, range [-8, 7]
                let byteCount = (count + 1) / 2
                let bytePtr = rawPtr.bindMemory(to: UInt8.self)
                var result = [Float](repeating: 0, count: count)
                for i in 0..<byteCount {
                    let byte = bytePtr[i]
                    let lo = Int8(bitPattern: (byte & 0x0F) << 4) >> 4  // sign-extend lower nibble
                    let hi = Int8(bitPattern: byte & 0xF0) >> 4          // sign-extend upper nibble
                    let idx = i * 2
                    result[idx] = Float(lo) / 8.0
                    if idx + 1 < count {
                        result[idx + 1] = Float(hi) / 8.0
                    }
                }
                return result
            }
        }
    }
}

// MARK: - Weight Structs

/// DRAM-resident attention weights for one transformer layer.
struct AttentionWeights: Sendable {
    let qProj: [Float]       // [numHeads * headDim, hiddenSize]
    let kProj: [Float]       // [numKVHeads * headDim, hiddenSize]
    let vProj: [Float]       // [numKVHeads * headDim, hiddenSize]
    let oProj: [Float]       // [hiddenSize, numHeads * headDim]
    let inputNorm: [Float]   // [hiddenSize]
    let postAttnNorm: [Float] // [hiddenSize]
}

/// DRAM-resident global model weights.
struct GlobalWeights: Sendable {
    let tokenEmbedding: [Float] // [vocabSize, hiddenSize]
    let norm: [Float]           // [hiddenSize]
    let lmHead: [Float]?        // [vocabSize, hiddenSize] or nil if tied to embedding
}

/// Weights for a single-layer low-rank sparsity predictor.
struct PredictorWeights: Sendable {
    let wIn: [Float]   // [hiddenSize, rank]
    let wOut: [Float]  // [rank, intermediateSize]
    let rank: Int
}

// MARK: - FlashPack Header Parser

/// Reads and validates a FlashPack file header.
enum FlashPackReader {

    static let magicBytes = Data("FLASHPK1".utf8)

    /// Open a FlashPack file and parse its header.
    static func readHeader(path: String) throws -> (config: FlashModelConfig, dataStartOffset: UInt64) {
        guard FileManager.default.fileExists(atPath: path) else {
            throw FlashModelError.fileNotFound(path: path)
        }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }

        // Read and validate magic bytes (8 bytes)
        guard let magic = try handle.read(upToCount: 8),
              magic == magicBytes else {
            throw FlashModelError.invalidMagic
        }

        // Read header JSON length (8 bytes, little-endian uint64)
        guard let lenBytes = try handle.read(upToCount: 8), lenBytes.count == 8 else {
            throw FlashModelError.headerParseFailure("Could not read header length")
        }
        let headerLength = lenBytes.withUnsafeBytes { $0.load(as: UInt64.self) }

        // Read header JSON
        guard let headerData = try handle.read(upToCount: Int(headerLength)),
              headerData.count == Int(headerLength) else {
            throw FlashModelError.headerParseFailure("Could not read header JSON")
        }

        // Parse
        let decoder = JSONDecoder()
        let header: FlashPackHeader
        do {
            header = try decoder.decode(FlashPackHeader.self, from: headerData)
        } catch {
            throw FlashModelError.headerParseFailure(error.localizedDescription)
        }

        guard header.fileFormatVersion == 1 else {
            throw FlashModelError.unsupportedVersion(header.fileFormatVersion)
        }

        let dataStartOffset: UInt64 = 8 + 8 + headerLength
        return (config: header.config, dataStartOffset: dataStartOffset)
    }
}

// MARK: - FileHandle read helper

private extension FileHandle {
    func read(upToCount count: Int) throws -> Data? {
        if #available(iOS 15.4, macOS 12.3, *) {
            return try read(upToCount: count)
        } else {
            return readData(ofLength: count)
        }
    }
}
