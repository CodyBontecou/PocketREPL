import Foundation
import Combine
import os.log

// MARK: - Memory Pressure Level

/// The severity of memory pressure on the system.
enum MemoryPressureLevel: String, Sendable {
    case normal
    case warning
    case critical
    
    var description: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

// MARK: - Model Unload Reason

/// Reason why a model was unloaded.
enum ModelUnloadReason: Sendable, Equatable {
    case userRequested
    case memoryPressure
    case appBackgrounded
    case error(String)
    
    var message: String {
        switch self {
        case .userRequested:
            return "Model unloaded by user"
        case .memoryPressure:
            return "Model unloaded to free memory. You can reload it when ready."
        case .appBackgrounded:
            return "Model unloaded while app was in background to conserve resources."
        case .error(let msg):
            return "Model unloaded due to error: \(msg)"
        }
    }
}

// MARK: - Memory Info

/// Current memory usage information.
struct MemoryInfo: Sendable {
    /// Memory currently used by the app (resident size).
    let usedBytes: Int64
    
    /// Physical memory footprint (more accurate for iOS).
    let footprintBytes: Int64
    
    /// Total physical memory on device.
    let totalPhysicalBytes: Int64
    
    /// Estimated available memory (rough approximation).
    var estimatedAvailableBytes: Int64 {
        // iOS doesn't expose free memory directly.
        // Rough heuristic: total * 0.75 - footprint (leave 25% for system)
        let systemReserve = Int64(Double(totalPhysicalBytes) * 0.25)
        return max(0, totalPhysicalBytes - systemReserve - footprintBytes)
    }
    
    var usedMB: Int64 { usedBytes / (1024 * 1024) }
    var footprintMB: Int64 { footprintBytes / (1024 * 1024) }
    var totalMB: Int64 { totalPhysicalBytes / (1024 * 1024) }
    var estimatedAvailableMB: Int64 { estimatedAvailableBytes / (1024 * 1024) }
}

// MARK: - Memory Pressure Monitor

/// Monitors system memory pressure and provides callbacks for handling low memory.
final class MemoryPressureMonitor: @unchecked Sendable {
    
    // MARK: - Properties
    
    private var source: DispatchSourceMemoryPressure?
    private var onPressureChange: (@Sendable (MemoryPressureLevel) -> Void)?
    private let queue = DispatchQueue(label: "com.pocketrepl.memory-monitor")
    private let logger = Logger(subsystem: "com.pocketrepl", category: "memory")
    
    /// Current memory pressure level.
    private(set) var currentLevel: MemoryPressureLevel = .normal
    
    /// Shared instance for app-wide monitoring.
    static let shared = MemoryPressureMonitor()
    
    // MARK: - Initialization
    
    init() {}
    
    deinit {
        stopMonitoring()
    }
    
    // MARK: - Monitoring
    
    /// Start monitoring memory pressure.
    /// - Parameter onPressure: Callback invoked when memory pressure changes.
    func startMonitoring(onPressure: @escaping @Sendable (MemoryPressureLevel) -> Void) {
        queue.async { [weak self] in
            self?.setupMonitoring(onPressure: onPressure)
        }
    }
    
    private func setupMonitoring(onPressure: @escaping @Sendable (MemoryPressureLevel) -> Void) {
        // Cancel existing source if any
        source?.cancel()
        
        self.onPressureChange = onPressure
        
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical, .normal],
            queue: queue
        )
        
        source?.setEventHandler { [weak self] in
            guard let self = self, let source = self.source else { return }
            
            let event = source.data
            var newLevel: MemoryPressureLevel = .normal
            
            if event.contains(.critical) {
                newLevel = .critical
            } else if event.contains(.warning) {
                newLevel = .warning
            }
            
            if newLevel != self.currentLevel {
                self.currentLevel = newLevel
                self.logger.info("Memory pressure changed: \(newLevel.rawValue)")
                self.onPressureChange?(newLevel)
            }
        }
        
        source?.resume()
        logger.info("Memory pressure monitoring started")
    }
    
    /// Stop monitoring memory pressure.
    func stopMonitoring() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
            self?.onPressureChange = nil
            self?.logger.info("Memory pressure monitoring stopped")
        }
    }
    
    // MARK: - Memory Queries
    
    /// Get current memory usage information.
    static func currentMemoryInfo() -> MemoryInfo {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        var usedBytes: Int64 = 0
        var footprintBytes: Int64 = 0
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            usedBytes = Int64(info.resident_size)
        }
        
        // Get footprint (more accurate for iOS memory limits)
        var taskInfo = task_vm_info_data_t()
        var taskInfoCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        
        let vmResult = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(taskInfoCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &taskInfoCount)
            }
        }
        
        if vmResult == KERN_SUCCESS {
            footprintBytes = Int64(taskInfo.phys_footprint)
        }
        
        return MemoryInfo(
            usedBytes: usedBytes,
            footprintBytes: footprintBytes,
            totalPhysicalBytes: Int64(ProcessInfo.processInfo.physicalMemory)
        )
    }
    
    /// Estimate if we can load a model of the given size.
    /// - Parameters:
    ///   - modelSizeBytes: Size of the model file on disk.
    ///   - safetyMarginMB: Additional memory buffer to keep free (default 512MB).
    /// - Returns: true if loading should be safe.
    static func canLoadModel(
        modelSizeBytes: Int64,
        safetyMarginMB: Int64 = 512
    ) -> Bool {
        let info = currentMemoryInfo()
        let safetyMarginBytes = safetyMarginMB * 1024 * 1024
        
        // Models typically use ~1.5-2x their file size in RAM
        // - Model weights (mmap'd but may page in)
        // - KV cache for context
        // - Temporary buffers
        let estimatedModelRAM = Int64(Double(modelSizeBytes) * 1.8)
        
        return info.estimatedAvailableBytes > (estimatedModelRAM + safetyMarginBytes)
    }
    
    /// Estimate if we can process a prompt of the given token count.
    /// - Parameters:
    ///   - promptTokens: Number of tokens in the prompt.
    ///   - contextSize: Total context window size.
    ///   - kvCacheBytesPerToken: Memory per token in KV cache (model-dependent).
    /// - Returns: true if generation should be safe.
    static func canGenerate(
        promptTokens: Int,
        contextSize: Int = 4096,
        kvCacheBytesPerToken: Int = 256 // Rough estimate for Q4 models
    ) -> Bool {
        let info = currentMemoryInfo()
        let kvCacheSize = Int64(contextSize * kvCacheBytesPerToken)
        let safetyMargin: Int64 = 256 * 1024 * 1024 // 256MB
        
        return info.estimatedAvailableBytes > (kvCacheSize + safetyMargin)
    }
    
    /// Get a human-readable memory summary.
    static func memorySummary() -> String {
        let info = currentMemoryInfo()
        return """
        Memory Usage:
        - Footprint: \(info.footprintMB) MB
        - Resident: \(info.usedMB) MB
        - Total Physical: \(info.totalMB) MB
        - Est. Available: \(info.estimatedAvailableMB) MB
        """
    }
}

// MARK: - Memory-Aware Model Loading

/// Extension to integrate memory checks with model loading.
extension ModelBackendManager {
    
    /// Check if a model can be loaded given current memory constraints.
    func canLoadModel(sizeBytes: Int64) -> Bool {
        MemoryPressureMonitor.canLoadModel(modelSizeBytes: sizeBytes)
    }
    
    /// Load a model with pre-flight memory check.
    func loadWithMemoryCheck(configuration: ModelConfiguration, modelSizeBytes: Int64) async throws {
        guard MemoryPressureMonitor.canLoadModel(modelSizeBytes: modelSizeBytes) else {
            let info = MemoryPressureMonitor.currentMemoryInfo()
            throw ModelError.insufficientMemory(
                required: Int64(Double(modelSizeBytes) * 1.8),
                available: info.estimatedAvailableBytes
            )
        }
        
        try await load(configuration: configuration)
    }
}

// MARK: - App Lifecycle Memory Handling

import UIKit

/// Handles memory pressure and app lifecycle events for automatic model management.
@MainActor
final class ModelMemoryCoordinator: ObservableObject {
    
    private let modelManager: ModelBackendManager
    private let memoryMonitor = MemoryPressureMonitor()
    private var notificationObservers: [Any] = []
    
    /// Reason for last automatic unload, if any.
    @Published private(set) var lastUnloadReason: ModelUnloadReason?
    
    /// Whether a model was unloaded and can be reloaded.
    @Published private(set) var modelWasUnloadedAutomatically = false
    
    init(modelManager: ModelBackendManager) {
        self.modelManager = modelManager
        setupHandlers()
    }
    
    deinit {
        // Stopping monitor in a non-isolated context
        let monitor = memoryMonitor
        Task { @Sendable in
            monitor.stopMonitoring()
        }
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func setupHandlers() {
        // Memory pressure
        memoryMonitor.startMonitoring { [weak self] level in
            Task { @MainActor [weak self] in
                await self?.handleMemoryPressure(level)
            }
        }
        
        // App backgrounding
        let bgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleAppBackgrounded()
            }
        }
        notificationObservers.append(bgObserver)
        
        // Memory warning from system
        let memObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleSystemMemoryWarning()
            }
        }
        notificationObservers.append(memObserver)
    }
    
    private func handleMemoryPressure(_ level: MemoryPressureLevel) async {
        switch level {
        case .normal:
            break
            
        case .warning:
            // Could reduce context or warn user
            print("⚠️ Memory warning - consider unloading model")
            
        case .critical:
            // Must unload to prevent crash
            if modelManager.state.isReady || modelManager.state.isGenerating {
                await modelManager.cancel()
                await modelManager.unload()
                lastUnloadReason = .memoryPressure
                modelWasUnloadedAutomatically = true
                print("🛑 Model unloaded due to critical memory pressure")
            }
        }
    }
    
    private func handleAppBackgrounded() async {
        // On iOS, unload model when backgrounded to prevent jetsam termination
        // Users on newer devices with lots of RAM might not need this
        let info = MemoryPressureMonitor.currentMemoryInfo()
        
        // Only unload if using significant memory (>1GB footprint)
        if info.footprintBytes > 1_000_000_000 {
            if modelManager.state.isReady {
                await modelManager.unload()
                lastUnloadReason = .appBackgrounded
                modelWasUnloadedAutomatically = true
                print("📱 Model unloaded on app background")
            }
        }
    }
    
    private func handleSystemMemoryWarning() async {
        // iOS UIKit memory warning - more urgent than dispatch source
        if modelManager.state.isReady || modelManager.state.isGenerating {
            await modelManager.cancel()
            await modelManager.unload()
            lastUnloadReason = .memoryPressure
            modelWasUnloadedAutomatically = true
            print("🛑 Model unloaded due to system memory warning")
        }
    }
    
    /// Clear the automatic unload state (e.g., after user reloads).
    func clearUnloadState() {
        lastUnloadReason = nil
        modelWasUnloadedAutomatically = false
    }
}
