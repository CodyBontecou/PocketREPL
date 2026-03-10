import Combine
import Foundation

// MARK: - Local Model Orchestration

/// Integrates the local coding model with the agent orchestration system.
/// Provides guardrails, fallbacks, and resource management.
@MainActor
final class LocalModelOrchestrator: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var modelState: ModelState = .unloaded
    @Published private(set) var isGenerating = false
    @Published private(set) var lastGenerationStats: GenerationStats?
    
    // MARK: - Dependencies
    
    let modelManager: ModelBackendManager
    let contextManager: ContextManager
    let guardrails: OrchestrationGuardrails
    
    // MARK: - Initialization
    
    init(
        modelManager: ModelBackendManager,
        contextManager: ContextManager,
        guardrails: OrchestrationGuardrails = .default
    ) {
        self.modelManager = modelManager
        self.contextManager = contextManager
        self.guardrails = guardrails
        
        // Observe model state changes
        Task { @MainActor in
            self.modelState = await modelManager.state
        }
    }
    
    // MARK: - Model Management
    
    /// Load a model from the given path.
    func loadModel(at path: String) async throws {
        let config = ModelDiscovery.recommendedConfiguration(for: URL(fileURLWithPath: path))
        try await modelManager.load(configuration: config)
        modelState = await modelManager.state
    }
    
    /// Unload the current model.
    func unloadModel() async {
        await modelManager.unload()
        modelState = .unloaded
    }
    
    /// Check if the model is ready for inference.
    var isModelReady: Bool {
        modelState.isReady
    }
    
    // MARK: - Code Generation with Guardrails
    
    /// Generate code with full guardrails and fallback handling.
    func generateCode(
        prompt: String,
        filePath: String? = nil,
        options: GenerationOptions = .default
    ) async -> GenerationOutcome {
        
        // Check model readiness
        guard isModelReady else {
            return .fallback(reason: .modelNotReady)
        }
        
        // Check resource availability
        if let memoryIssue = checkMemoryGuardrails() {
            return .fallback(reason: .resourceConstrained(memoryIssue))
        }
        
        // Estimate prompt tokens and check budget
        let projectContext = await contextManager.assembleContext(budget: guardrails.maxContextTokens)
        let estimatedPromptTokens = modelManager.estimateTokens(for: prompt + projectContext)
        
        if estimatedPromptTokens > guardrails.maxPromptTokens {
            return .fallback(reason: .promptTooLarge(tokens: estimatedPromptTokens, max: guardrails.maxPromptTokens))
        }
        
        // Start generation with timeout
        isGenerating = true
        defer { isGenerating = false }
        
        let startTime = Date()
        
        do {
            let request = GenerationRequest.generate(
                prompt: prompt,
                context: projectContext,
                filePath: filePath,
                maxTokens: min(options.maxTokens, guardrails.maxCompletionTokens)
            )
            
            // Run with timeout
            let response = try await withTimeout(seconds: guardrails.maxGenerationTimeSeconds) {
                try await self.modelManager.generate(request: request)
            }
            
            let duration = Date().timeIntervalSince(startTime)
            
            // Record stats
            lastGenerationStats = GenerationStats(
                promptTokens: response.promptTokens,
                completionTokens: response.completionTokens,
                durationSeconds: duration,
                tokensPerSecond: response.tokensPerSecond
            )
            
            // Extract and return code
            let code = PromptTemplates.extractCode(response.text)
            return .success(code: code, stats: lastGenerationStats!)
            
        } catch is TimeoutError {
            await modelManager.cancel()
            return .fallback(reason: .timeout(seconds: guardrails.maxGenerationTimeSeconds))
        } catch let error as ModelError {
            return .error(error)
        } catch {
            return .error(.inferenceError(reason: error.localizedDescription))
        }
    }
    
    /// Fix code with guardrails.
    func fixCode(
        code: String,
        error: String,
        filePath: String? = nil,
        options: GenerationOptions = .default
    ) async -> GenerationOutcome {
        
        guard isModelReady else {
            return .fallback(reason: .modelNotReady)
        }
        
        if let memoryIssue = checkMemoryGuardrails() {
            return .fallback(reason: .resourceConstrained(memoryIssue))
        }
        
        isGenerating = true
        defer { isGenerating = false }
        
        let startTime = Date()
        let projectContext = await contextManager.assembleContext(budget: guardrails.maxContextTokens / 2)
        
        do {
            let request = GenerationRequest.fix(
                code: code,
                error: error,
                context: projectContext,
                filePath: filePath,
                maxTokens: min(options.maxTokens, guardrails.maxCompletionTokens)
            )
            
            let response = try await withTimeout(seconds: guardrails.maxGenerationTimeSeconds) {
                try await self.modelManager.generate(request: request)
            }
            
            let duration = Date().timeIntervalSince(startTime)
            
            lastGenerationStats = GenerationStats(
                promptTokens: response.promptTokens,
                completionTokens: response.completionTokens,
                durationSeconds: duration,
                tokensPerSecond: response.tokensPerSecond
            )
            
            let fixedCode = PromptTemplates.extractCode(response.text)
            return .success(code: fixedCode, stats: lastGenerationStats!)
            
        } catch is TimeoutError {
            await modelManager.cancel()
            return .fallback(reason: .timeout(seconds: guardrails.maxGenerationTimeSeconds))
        } catch let error as ModelError {
            return .error(error)
        } catch {
            return .error(.inferenceError(reason: error.localizedDescription))
        }
    }
    
    // MARK: - Guardrail Checks
    
    private func checkMemoryGuardrails() -> String? {
        let availableMemory = ProcessInfo.processInfo.physicalMemory
        let memoryPressure = getMemoryPressure()
        
        if memoryPressure > 0.8 {
            return "Memory pressure is high (\(Int(memoryPressure * 100))%)"
        }
        
        // Check if we have enough headroom
        let minimumMemoryMB: UInt64 = 500 // 500MB minimum
        let availableMB = availableMemory / (1024 * 1024)
        
        if availableMB < minimumMemoryMB {
            return "Low available memory (\(availableMB)MB)"
        }
        
        return nil
    }
    
    private func getMemoryPressure() -> Double {
        // Simplified memory pressure check
        // In a real implementation, use vm_statistics or task_info
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            let usedMemory = info.resident_size
            let totalMemory = ProcessInfo.processInfo.physicalMemory
            return Double(usedMemory) / Double(totalMemory)
        }
        
        return 0.5 // Default to 50% if we can't determine
    }
}

// MARK: - Guardrails Configuration

/// Resource guardrails for local model usage.
struct OrchestrationGuardrails: Sendable {
    /// Maximum tokens in the prompt (including context).
    let maxPromptTokens: Int
    
    /// Maximum tokens to generate.
    let maxCompletionTokens: Int
    
    /// Maximum tokens for project context.
    let maxContextTokens: Int
    
    /// Maximum time for a single generation in seconds.
    let maxGenerationTimeSeconds: Double
    
    /// Maximum consecutive failures before falling back.
    let maxConsecutiveFailures: Int
    
    /// Default guardrails for mobile devices.
    static let `default` = OrchestrationGuardrails(
        maxPromptTokens: 2048,
        maxCompletionTokens: 1024,
        maxContextTokens: 1000,
        maxGenerationTimeSeconds: 60.0,
        maxConsecutiveFailures: 3
    )
    
    /// Aggressive guardrails for low-memory situations.
    static let conservative = OrchestrationGuardrails(
        maxPromptTokens: 1024,
        maxCompletionTokens: 512,
        maxContextTokens: 500,
        maxGenerationTimeSeconds: 30.0,
        maxConsecutiveFailures: 2
    )
    
    /// Relaxed guardrails for capable devices.
    static let generous = OrchestrationGuardrails(
        maxPromptTokens: 4096,
        maxCompletionTokens: 2048,
        maxContextTokens: 2000,
        maxGenerationTimeSeconds: 120.0,
        maxConsecutiveFailures: 5
    )
}

// MARK: - Generation Options

/// Options for a generation request.
struct GenerationOptions: Sendable {
    let maxTokens: Int
    let temperature: Float
    let streamOutput: Bool
    
    static let `default` = GenerationOptions(
        maxTokens: 1024,
        temperature: 0.2,
        streamOutput: false
    )
    
    static let creative = GenerationOptions(
        maxTokens: 2048,
        temperature: 0.7,
        streamOutput: false
    )
    
    static let deterministic = GenerationOptions(
        maxTokens: 1024,
        temperature: 0.0,
        streamOutput: false
    )
}

// MARK: - Generation Outcome

/// The outcome of a guarded generation request.
enum GenerationOutcome: Sendable {
    /// Generation succeeded.
    case success(code: String, stats: GenerationStats)
    
    /// Generation failed with a model error.
    case error(ModelError)
    
    /// Fell back due to guardrail or resource issue.
    case fallback(reason: FallbackReason)
    
    var succeeded: Bool {
        if case .success = self { return true }
        return false
    }
    
    var code: String? {
        if case .success(let code, _) = self { return code }
        return nil
    }
}

/// Reasons for falling back from local model generation.
enum FallbackReason: Sendable, CustomStringConvertible {
    case modelNotReady
    case promptTooLarge(tokens: Int, max: Int)
    case resourceConstrained(String)
    case timeout(seconds: Double)
    case tooManyFailures(count: Int)
    
    var description: String {
        switch self {
        case .modelNotReady:
            return "Local model is not ready"
        case .promptTooLarge(let tokens, let max):
            return "Prompt too large: \(tokens) tokens (max: \(max))"
        case .resourceConstrained(let reason):
            return "Resource constraint: \(reason)"
        case .timeout(let seconds):
            return "Generation timed out after \(Int(seconds))s"
        case .tooManyFailures(let count):
            return "Too many consecutive failures (\(count))"
        }
    }
}

// MARK: - Generation Stats

/// Statistics from a generation.
nonisolated struct GenerationStats: Sendable {
    let promptTokens: Int
    let completionTokens: Int
    let durationSeconds: Double
    let tokensPerSecond: Double
    
    var totalTokens: Int { promptTokens + completionTokens }
    
    var formattedSpeed: String {
        String(format: "%.1f tok/s", tokensPerSecond)
    }
    
    var formattedDuration: String {
        if durationSeconds < 1 {
            return String(format: "%.0fms", durationSeconds * 1000)
        }
        return String(format: "%.1fs", durationSeconds)
    }
}

// MARK: - Timeout Helper

/// Error thrown when an operation times out.
struct TimeoutError: Error {}

/// Run an async operation with a timeout.
func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        
        // Return the first result, cancel the other
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// MARK: - Orchestrator Mode Extension

extension AgentOrchestrator {
    /// Extended mode including local model.
    enum ExtendedMode {
        case foundationModels
        case localModel
        case fallback
    }
}
