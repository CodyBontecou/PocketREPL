{
  "id": "7fd9fbca",
  "title": "Task: Add memory pressure handling and graceful degradation",
  "tags": [
    "task",
    "llm",
    "memory",
    "reliability"
  ],
  "status": "closed",
  "created_at": "2026-03-10T19:09:20.018Z"
}

## Goal
Handle low memory conditions gracefully to prevent crashes and provide a good user experience.

## Implementation

### Memory Pressure Monitoring
```swift
actor MemoryPressureMonitor {
    private var source: DispatchSourceMemoryPressure?
    private var onPressure: ((MemoryPressureLevel) -> Void)?
    
    enum MemoryPressureLevel {
        case normal
        case warning
        case critical
    }
    
    func startMonitoring(onPressure: @escaping (MemoryPressureLevel) -> Void) {
        self.onPressure = onPressure
        
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        
        source?.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            let event = source.data
            
            if event.contains(.critical) {
                self.onPressure?(.critical)
            } else if event.contains(.warning) {
                self.onPressure?(.warning)
            }
        }
        
        source?.resume()
    }
    
    func stopMonitoring() {
        source?.cancel()
        source = nil
    }
}
```

### Automatic Model Unloading
```swift
extension ModelBackendManager {
    func setupMemoryPressureHandling() {
        memoryMonitor.startMonitoring { [weak self] level in
            guard let self else { return }
            
            switch level {
            case .warning:
                // Log warning, maybe reduce context size
                print("Memory warning: consider unloading model")
                
            case .critical:
                // Unload model to free memory
                Task { @MainActor in
                    if self.state.isReady {
                        await self.unload()
                        self.lastUnloadReason = .memoryPressure
                    }
                }
                
            case .normal:
                break
            }
        }
    }
}
```

### Pre-flight Memory Checks
```swift
extension LocalModelOrchestrator {
    func canLoadModel(sizeBytes: Int64) -> Bool {
        let available = getAvailableMemory()
        let needed = sizeBytes + safetyMargin
        return available > needed
    }
    
    func canGenerate(promptTokens: Int) -> Bool {
        // Check if we have enough memory for KV cache
        let kvCacheSize = estimateKVCacheSize(tokens: promptTokens)
        let available = getAvailableMemory()
        return available > kvCacheSize + safetyMargin
    }
    
    private func getAvailableMemory() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        guard result == KERN_SUCCESS else { return 0 }
        
        // Estimate available as total - resident
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        return Int64(totalMemory) - Int64(info.resident_size)
    }
}
```

### User Feedback
```swift
enum ModelUnloadReason {
    case userRequested
    case memoryPressure
    case appBackgrounded
    case error(String)
}

extension ModelBackendManager {
    @Published var lastUnloadReason: ModelUnloadReason?
    
    // Show appropriate message to user
    var unloadMessage: String? {
        switch lastUnloadReason {
        case .memoryPressure:
            return "Model unloaded to free memory. You can reload it when ready."
        case .appBackgrounded:
            return "Model unloaded while app was in background."
        case .error(let msg):
            return "Model unloaded due to error: \(msg)"
        default:
            return nil
        }
    }
}
```

## Acceptance Criteria
- App doesn't crash under memory pressure
- Model is unloaded automatically when memory is critical
- User is informed when model is unloaded
- Can reload model after memory frees up
- Pre-flight checks prevent OOM situations

## Parent Epic
TODO-a65bee54
