import Foundation

// MARK: - Flash Neuron Cache
//
// Implements the "Sliding Window Technique" from Section 3.1 of
// Apple's "LLM in a Flash" paper.
//
// DESIGN:
// ───────
// The cache pre-allocates a single contiguous block of DRAM that can hold
// up to `capacity` neurons. This avoids reallocating memory at each step.
//
// Physical layout (for layer L):
//
//   matrix[0..capacity-1][0..neuronSize-1]   ← contiguous Float32 buffer
//   pointerMap[slot] = originalNeuronIndex   ← slot → original index
//   reverseMap[originalIndex] = slot         ← original index → slot (or -1)
//   numUsed                                  ← current occupancy
//
// Neuron replacement (O(1) amortized):
//   To evict neuron at slot S (there are `numUsed` entries):
//     1. Copy the LAST entry (slot numUsed-1) into slot S.
//     2. Update pointerMap and reverseMap accordingly.
//     3. Decrement numUsed.
//   → No array shifts, just O(1) pointer swaps.
//
// Sliding window logic:
//   After each token, evict neurons that weren't active in the last `k` tokens.
//   Insert newly predicted neurons.
//   The incremental data loaded from flash = sagg(k+1) - sagg(k), which
//   decreases as k grows (per Figure 4(a) of paper) → larger windows need
//   fewer flash reads per token.
//
// Memory layout per neuron (matches FlashWeightStore bundling):
//   [up_col_i:  hiddenSize floats]
//   [gate_col_i: hiddenSize floats]  ← only for SwiGLU
//   [down_row_i: hiddenSize floats]

// MARK: - Neuron Data View

/// A lightweight handle into the neuron cache for a specific slot.
/// Pointers are valid until the next cache mutation.
///
/// `@unchecked Sendable` because UnsafePointer is not automatically Sendable,
/// but we guarantee pointer validity within a cache read lock.
struct CachedNeuronView: @unchecked Sendable {
    let upCol: UnsafePointer<Float>     // Column i of up-projection
    let gateCol: UnsafePointer<Float>?  // Column i of gate-projection (nil if no gate)
    let downRow: UnsafePointer<Float>   // Row i of down-projection
    let hiddenSize: Int
}

// MARK: - Flash Neuron Cache

/// Per-layer sliding window cache of FFN neuron weights in DRAM.
///
/// One `FlashNeuronCache` instance per transformer layer.
/// Thread-safe for concurrent reads, serialised writes.
final class FlashNeuronCache: @unchecked Sendable {

    // MARK: - Properties

    let layerIndex: Int
    let hiddenSize: Int
    let useGate: Bool          // true for SwiGLU (up + gate + down), false for standard FFN
    let capacity: Int          // Max neurons that fit in this cache
    let neuronsPerLayerTotal: Int

    /// Floats per cached neuron: hiddenSize * (2 for FFN, 3 for SwiGLU)
    var floatsPerNeuron: Int { hiddenSize * (useGate ? 3 : 2) }

    /// Total bytes in the pre-allocated buffer
    var bufferBytes: Int { capacity * floatsPerNeuron * MemoryLayout<Float>.size }

    // ── Pre-allocated storage ──
    //
    // We use UnsafeMutablePointer<Float> instead of [Float] so we can hand out
    // raw pointers to callers without copies. The buffer is owned by this cache.
    private let buffer: UnsafeMutablePointer<Float>   // [capacity * floatsPerNeuron]
    private var pointerMap: [Int]                     // pointerMap[slot] = neuronIndex  (-1 = unused)
    private var reverseMap: [Int]                     // reverseMap[neuronIdx] = slot  (-1 = not cached)
    private(set) var numUsed: Int = 0

    // ── Statistics (accessed under rwLock or atomically via metrics lock) ──
    private(set) var cacheHits: Int = 0
    private(set) var cacheMisses: Int = 0
    private(set) var evictions: Int = 0
    private let metricsLock = NSLock()

    // ── Sliding window tracking ──
    //    recentSets[t % windowSize] = set of neurons active at timestep t
    private var recentSets: [Set<Int>]
    private var windowSize: Int
    private var windowIndex: Int = 0

    // ── Thread safety ──
    private let rwLock = ReadWriteLock()

    // MARK: - Initialization

    init(
        layerIndex: Int,
        hiddenSize: Int,
        useGate: Bool,
        capacity: Int,
        neuronsPerLayerTotal: Int,
        slidingWindowSize: Int
    ) {
        self.layerIndex = layerIndex
        self.hiddenSize = hiddenSize
        self.useGate = useGate
        self.capacity = capacity
        self.neuronsPerLayerTotal = neuronsPerLayerTotal
        self.windowSize = max(1, slidingWindowSize)

        // Pre-allocate contiguous memory
        let totalFloats = capacity * hiddenSize * (useGate ? 3 : 2)
        self.buffer = UnsafeMutablePointer<Float>.allocate(capacity: totalFloats)
        self.buffer.initialize(repeating: 0, count: totalFloats)

        // Maps: capacity items, initially all -1 (empty)
        self.pointerMap = [Int](repeating: -1, count: capacity)
        self.reverseMap = [Int](repeating: -1, count: neuronsPerLayerTotal)

        self.recentSets = [Set<Int>](repeating: [], count: windowSize)
    }

    deinit {
        buffer.deallocate()
    }

    // MARK: - Cache Reads

    /// Check whether a neuron is currently cached (non-mutating, safe for concurrent reads).
    func contains(_ neuronIndex: Int) -> Bool {
        rwLock.readLock()
        defer { rwLock.readUnlock() }
        guard neuronIndex >= 0, neuronIndex < neuronsPerLayerTotal else { return false }
        return reverseMap[neuronIndex] >= 0
    }

    /// Get a view into cached neuron data. Returns nil if not cached.
    ///
    /// - Warning: The returned pointers are valid only until the next write operation.
    ///   Call within a `withReadLock` block for safe access in concurrent contexts.
    func get(_ neuronIndex: Int) -> CachedNeuronView? {
        rwLock.readLock()
        defer { rwLock.readUnlock() }
        return getUnsafe(neuronIndex)
    }

    /// Batch read: returns cached views for a set of neurons.
    /// Returns only the neurons that ARE in cache; caller handles the rest.
    func getBatch(_ neuronIndices: [Int]) -> (hits: [(Int, CachedNeuronView)], misses: [Int]) {
        rwLock.readLock()

        var hits: [(Int, CachedNeuronView)] = []
        var misses: [Int] = []

        for idx in neuronIndices {
            if let view = getUnsafe(idx) {
                hits.append((idx, view))
            } else {
                misses.append(idx)
            }
        }

        rwLock.readUnlock()

        // Update metrics outside the read lock to avoid mutation under shared lock
        metricsLock.lock()
        cacheHits += hits.count
        cacheMisses += misses.count
        metricsLock.unlock()

        return (hits: hits, misses: misses)
    }

    // MARK: - Cache Writes

    /// Insert a neuron's weight data into the cache.
    ///
    /// If the cache is full, evicts the least recently active neuron
    /// (one not in the current sliding window's union).
    ///
    /// - Parameter data: Float32 array of size `floatsPerNeuron`.
    ///                    Layout: [up_col | gate_col (optional) | down_row]
    /// - Returns: true if inserted, false if already present.
    @discardableResult
    func insert(neuronIndex: Int, data: [Float]) -> Bool {
        assert(data.count == floatsPerNeuron,
               "Neuron data size mismatch: got \(data.count), expected \(floatsPerNeuron)")

        rwLock.writeLock()
        defer { rwLock.writeUnlock() }

        // Already present?
        guard reverseMap[neuronIndex] < 0 else { return false }

        // Find a slot
        let slot: Int
        if numUsed < capacity {
            slot = numUsed
            numUsed += 1
        } else {
            // Evict: find a neuron not in current window union
            slot = evictOne()
        }

        // Write data into buffer at slot
        let bufferOffset = slot * floatsPerNeuron
        data.withUnsafeBufferPointer { src in
            (buffer + bufferOffset).update(from: src.baseAddress!, count: floatsPerNeuron)
        }

        // Update maps
        pointerMap[slot] = neuronIndex
        reverseMap[neuronIndex] = slot

        return true
    }

    /// Batch insert multiple neurons after loading from flash.
    func insertBatch(neurons: [(neuronIndex: Int, data: [Float])]) {
        for (idx, data) in neurons {
            insert(neuronIndex: idx, data: data)
        }
    }

    // MARK: - Sliding Window Update

    /// Record the set of neurons activated at the current timestep.
    ///
    /// Call this after each token to advance the sliding window.
    /// Evicts neurons that haven't been active in the last `windowSize` tokens.
    func advanceWindow(activeNeurons: Set<Int>) {
        rwLock.writeLock()
        defer { rwLock.writeUnlock() }

        // Compute neurons to evict: in cache but not in new union of recent `k` sets
        let newWindowIndex = windowIndex % windowSize
        recentSets[newWindowIndex] = activeNeurons
        windowIndex += 1

        let unionActive = recentSets.reduce(Set<Int>()) { $0.union($1) }

        // Evict neurons no longer in the sliding window
        var toEvict: [Int] = []
        for slot in 0..<numUsed {
            let neuronIdx = pointerMap[slot]
            if neuronIdx >= 0, !unionActive.contains(neuronIdx) {
                toEvict.append(neuronIdx)
            }
        }

        for neuronIdx in toEvict {
            evictNeuron(neuronIdx)
        }
    }

    /// Pre-populate cache with the N most important neurons (from importance scores).
    ///
    /// Per the paper: some neurons are always active (high global importance).
    /// Keeping them permanently warm avoids repeated flash reads.
    func prewarmWithImportant(importanceScores: [Float], store: FlashWeightStore, layer: Int, topN: Int) async throws {
        // Find top-N neurons by importance
        let indexed = importanceScores.enumerated().sorted { $0.element > $1.element }
        let topNeuronIndices = Array(indexed.prefix(topN).map { $0.offset })

        // Filter out already cached
        let toLoad = topNeuronIndices.filter { !contains($0) }
        guard !toLoad.isEmpty else { return }

        // Load from flash in parallel
        let neuronData = try store.loadNeurons(layer: layer, neuronIndices: toLoad)
        let batch = zip(toLoad, neuronData).map { ($0, $1) }
        insertBatch(neurons: batch)
    }

    // MARK: - Statistics

    var hitRate: Double {
        metricsLock.lock()
        let hits = cacheHits
        let misses = cacheMisses
        metricsLock.unlock()
        let total = hits + misses
        return total > 0 ? Double(hits) / Double(total) : 0
    }

    var occupancy: Double {
        return capacity > 0 ? Double(numUsed) / Double(capacity) : 0
    }

    func resetStats() {
        metricsLock.lock()
        cacheHits = 0
        cacheMisses = 0
        evictions = 0
        metricsLock.unlock()
    }

    // MARK: - Private Helpers

    /// Non-locking get. Caller must hold rwLock.readLock().
    private func getUnsafe(_ neuronIndex: Int) -> CachedNeuronView? {
        guard neuronIndex >= 0, neuronIndex < neuronsPerLayerTotal else { return nil }
        let slot = reverseMap[neuronIndex]
        guard slot >= 0 else { return nil }

        let base = buffer + slot * floatsPerNeuron
        let upCol = UnsafePointer(base)
        if useGate {
            let gateCol = UnsafePointer(base + hiddenSize)
            let downRow = UnsafePointer(base + hiddenSize * 2)
            return CachedNeuronView(upCol: upCol, gateCol: gateCol, downRow: downRow, hiddenSize: hiddenSize)
        } else {
            let downRow = UnsafePointer(base + hiddenSize)
            return CachedNeuronView(upCol: upCol, gateCol: nil, downRow: downRow, hiddenSize: hiddenSize)
        }
    }

    /// Evict one neuron from cache (caller must hold writeLock).
    /// Returns the slot that was freed.
    /// Strategy: evict the first neuron not in any recent window (simple, fast).
    private func evictOne() -> Int {
        let unionActive = recentSets.reduce(Set<Int>()) { $0.union($1) }

        for slot in 0..<numUsed {
            let neuronIdx = pointerMap[slot]
            if neuronIdx >= 0, !unionActive.contains(neuronIdx) {
                evictNeuron(neuronIdx)
                return slot
            }
        }

        // All neurons in window — evict the last slot (LRU fallback)
        let slot = numUsed - 1
        if slot >= 0, pointerMap[slot] >= 0 {
            evictNeuron(pointerMap[slot])
        }
        return slot
    }

    /// Remove a specific neuron from cache using the swap-with-last trick.
    /// Caller must hold writeLock.
    private func evictNeuron(_ neuronIndex: Int) {
        let slot = reverseMap[neuronIndex]
        guard slot >= 0 else { return }

        let lastSlot = numUsed - 1

        if slot != lastSlot {
            // Swap contents of `slot` with `lastSlot`
            let lastNeuronIdx = pointerMap[lastSlot]

            // Copy data from lastSlot → slot
            let destBase = buffer + slot * floatsPerNeuron
            let srcBase = buffer + lastSlot * floatsPerNeuron
            destBase.update(from: srcBase, count: floatsPerNeuron)

            // Update maps for the neuron that moved
            pointerMap[slot] = lastNeuronIdx
            if lastNeuronIdx >= 0 {
                reverseMap[lastNeuronIdx] = slot
            }
        }

        // Clear the last slot
        pointerMap[lastSlot] = -1
        reverseMap[neuronIndex] = -1
        numUsed -= 1
        metricsLock.lock()
        evictions += 1
        metricsLock.unlock()
    }
}

// MARK: - Multi-Layer Cache Manager

/// Manages per-layer `FlashNeuronCache` instances for an entire model.
final class FlashCacheManager: @unchecked Sendable {

    private(set) var layerCaches: [FlashNeuronCache]
    private let config: FlashModelConfig

    init(config: FlashModelConfig) {
        self.config = config
        let maxNeuronsPerLayer = Int(Double(config.intermediateSize) * config.maxCacheFraction)

        self.layerCaches = (0..<config.numHiddenLayers).map { layerIdx in
            FlashNeuronCache(
                layerIndex: layerIdx,
                hiddenSize: config.hiddenSize,
                useGate: config.sections.layers[layerIdx].ffnUseGate,
                capacity: maxNeuronsPerLayer,
                neuronsPerLayerTotal: config.intermediateSize,
                slidingWindowSize: config.slidingWindowSize
            )
        }
    }

    subscript(layer: Int) -> FlashNeuronCache {
        return layerCaches[layer]
    }

    var totalCacheHits: Int    { layerCaches.reduce(0) { $0 + $1.cacheHits } }
    var totalCacheMisses: Int  { layerCaches.reduce(0) { $0 + $1.cacheMisses } }
    var totalEvictions: Int    { layerCaches.reduce(0) { $0 + $1.evictions } }
    var averageHitRate: Double {
        let rates = layerCaches.map { $0.hitRate }
        return rates.reduce(0, +) / Double(max(1, rates.count))
    }

    var estimatedDRAMUsedMB: Double {
        let totalBytes = layerCaches.reduce(0) { total, layer in
            total + layer.numUsed * layer.floatsPerNeuron * MemoryLayout<Float>.size
        }
        return Double(totalBytes) / (1024 * 1024)
    }

    func resetAllStats() {
        layerCaches.forEach { $0.resetStats() }
    }
}



// MARK: - ReadWriteLock

/// Simple POSIX read-write lock wrapper.
final class ReadWriteLock: @unchecked Sendable {
    private var lock = pthread_rwlock_t()

    init() {
        pthread_rwlock_init(&lock, nil)
    }

    deinit {
        pthread_rwlock_destroy(&lock)
    }

    func readLock()   { pthread_rwlock_rdlock(&lock) }
    func readUnlock() { pthread_rwlock_unlock(&lock) }
    func writeLock()  { pthread_rwlock_wrlock(&lock) }
    func writeUnlock(){ pthread_rwlock_unlock(&lock) }
}
