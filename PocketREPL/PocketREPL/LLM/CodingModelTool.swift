import Foundation

// MARK: - Coding Model Tool

/// Tool that wraps the local coding model for code generation and fixing.
/// Integrates with the existing tool system and agent loop.
struct CodingModelTool: Tool {
    let name = "generate_code"
    let summary = "Generate or fix JavaScript code using the local coding model."
    
    /// Reference to the model backend manager for inference.
    /// This is set at runtime when the tool is registered.
    private let modelManager: ModelBackendManager
    private let contextManager: ContextManager
    
    init(modelManager: ModelBackendManager, contextManager: ContextManager) {
        self.modelManager = modelManager
        self.contextManager = contextManager
    }
    
    func execute(parameters: [String: Any], context: ToolContext) async -> ToolResult {
        // Parse task type
        let taskStr = parameters["task"] as? String ?? "generate"
        let task: GenerationRequest.TaskKind
        
        switch taskStr.lowercased() {
        case "generate", "create", "write":
            task = .generate
        case "fix", "repair", "debug":
            task = .fix
        case "complete", "finish":
            task = .complete
        case "explain":
            task = .explain
        default:
            task = .generate
        }
        
        // Get required parameters
        guard let prompt = parameters["prompt"] as? String, !prompt.isEmpty else {
            return .failure("Missing required parameter: prompt")
        }
        
        // Optional parameters
        let code = parameters["code"] as? String
        let error = parameters["error"] as? String
        let filePath = parameters["path"] as? String
        let maxTokens = parameters["max_tokens"] as? Int ?? 1024
        
        // Check if model is ready
        guard await modelManager.state.isReady else {
            return .failure("Local model not ready. State: \(await modelManager.state)")
        }
        
        // Build project context
        let projectContext = await contextManager.assembleContext(budget: 1000)
        
        // Create generation request
        let request: GenerationRequest
        switch task {
        case .generate:
            request = GenerationRequest.generate(
                prompt: prompt,
                context: projectContext.isEmpty ? nil : projectContext,
                filePath: filePath,
                maxTokens: maxTokens
            )
        case .fix:
            guard let existingCode = code else {
                return .failure("Fix task requires 'code' parameter with existing code")
            }
            request = GenerationRequest.fix(
                code: existingCode,
                error: error ?? prompt,
                context: projectContext.isEmpty ? nil : projectContext,
                filePath: filePath,
                maxTokens: maxTokens
            )
        case .complete:
            guard let partialCode = code else {
                return .failure("Complete task requires 'code' parameter with partial code")
            }
            request = GenerationRequest.complete(
                code: partialCode,
                context: projectContext.isEmpty ? nil : projectContext,
                filePath: filePath,
                maxTokens: maxTokens
            )
        case .explain:
            guard let codeToExplain = code else {
                return .failure("Explain task requires 'code' parameter")
            }
            request = GenerationRequest(
                task: .explain,
                prompt: prompt,
                existingCode: codeToExplain,
                filePath: filePath,
                context: projectContext,
                maxTokens: maxTokens
            )
        }
        
        // Execute generation
        do {
            let response = try await modelManager.generate(request: request)
            
            // Extract code from response (handle markdown blocks)
            let extractedCode = PromptTemplates.extractCode(response.text)
            
            // Build result with stats
            var output = extractedCode
            
            // Add generation stats as a comment at the end
            let stats = String(format: "// Generated: %d tokens in %.1fs (%.1f tok/s)",
                               response.completionTokens,
                               response.durationSeconds,
                               response.tokensPerSecond)
            
            // Don't append stats if the output is an explanation
            if task != .explain {
                output += "\n\n\(stats)"
            }
            
            return .success(output)
            
        } catch let error as ModelError {
            return .failure("Generation failed: \(error.localizedDescription)")
        } catch {
            return .failure("Unexpected error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Fix Code Tool

/// Specialized tool for fixing broken code with error context.
struct FixCodeTool: Tool {
    let name = "fix_code"
    let summary = "Fix broken JavaScript code using the error message as guidance."
    
    private let modelManager: ModelBackendManager
    private let contextManager: ContextManager
    
    init(modelManager: ModelBackendManager, contextManager: ContextManager) {
        self.modelManager = modelManager
        self.contextManager = contextManager
    }
    
    func execute(parameters: [String: Any], context: ToolContext) async -> ToolResult {
        // Required: code to fix
        guard let code = parameters["code"] as? String, !code.isEmpty else {
            return .failure("Missing required parameter: code")
        }
        
        // Required: error message
        guard let error = parameters["error"] as? String, !error.isEmpty else {
            return .failure("Missing required parameter: error")
        }
        
        // Optional: file path for context
        let filePath = parameters["path"] as? String
        let maxTokens = parameters["max_tokens"] as? Int ?? 1024
        
        // Check model readiness
        guard await modelManager.state.isReady else {
            return .failure("Local model not ready. State: \(await modelManager.state)")
        }
        
        // Get project context
        let projectContext = await contextManager.assembleContext(budget: 800)
        
        // Create fix request
        let request = GenerationRequest.fix(
            code: code,
            error: error,
            context: projectContext.isEmpty ? nil : projectContext,
            filePath: filePath,
            maxTokens: maxTokens
        )
        
        do {
            let response = try await modelManager.generate(request: request)
            let fixedCode = PromptTemplates.extractCode(response.text)
            
            // Return just the fixed code
            return .success(fixedCode)
            
        } catch let error as ModelError {
            return .failure("Fix failed: \(error.localizedDescription)")
        } catch {
            return .failure("Unexpected error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Tool Descriptors

/// Extended tool descriptor with parameter documentation.
struct CodingToolDescriptor {
    let name: String
    let summary: String
    let parameters: [ParameterDescriptor]
    
    struct ParameterDescriptor {
        let name: String
        let type: String
        let required: Bool
        let description: String
    }
}

extension CodingModelTool {
    /// Full descriptor with parameter documentation.
    static let descriptor = CodingToolDescriptor(
        name: "generate_code",
        summary: "Generate or fix JavaScript code using the local coding model.",
        parameters: [
            .init(name: "task", type: "string", required: false,
                  description: "Task type: 'generate', 'fix', 'complete', or 'explain'. Default: 'generate'"),
            .init(name: "prompt", type: "string", required: true,
                  description: "Description of what to generate or the instruction for fixing"),
            .init(name: "code", type: "string", required: false,
                  description: "Existing code (required for fix/complete/explain tasks)"),
            .init(name: "error", type: "string", required: false,
                  description: "Error message when fixing code"),
            .init(name: "path", type: "string", required: false,
                  description: "Target file path for context"),
            .init(name: "max_tokens", type: "integer", required: false,
                  description: "Maximum tokens to generate. Default: 1024")
        ]
    )
}

extension FixCodeTool {
    /// Full descriptor with parameter documentation.
    static let descriptor = CodingToolDescriptor(
        name: "fix_code",
        summary: "Fix broken JavaScript code using the error message as guidance.",
        parameters: [
            .init(name: "code", type: "string", required: true,
                  description: "The broken code to fix"),
            .init(name: "error", type: "string", required: true,
                  description: "The error message or description of what's wrong"),
            .init(name: "path", type: "string", required: false,
                  description: "File path for context"),
            .init(name: "max_tokens", type: "integer", required: false,
                  description: "Maximum tokens to generate. Default: 1024")
        ]
    )
}

// MARK: - Autonomous Fix Loop

/// Helper for running the autonomous fix loop.
/// This integrates code generation, execution, and fixing into a single flow.
actor AutonomousFixLoop {
    private let modelManager: ModelBackendManager
    private let runtime: JSRuntime
    private let projectStore: ProjectStore
    private let contextManager: ContextManager
    
    private let maxAttempts: Int
    private var attempts: Int = 0
    
    init(
        modelManager: ModelBackendManager,
        runtime: JSRuntime,
        projectStore: ProjectStore,
        contextManager: ContextManager,
        maxAttempts: Int = 3
    ) {
        self.modelManager = modelManager
        self.runtime = runtime
        self.projectStore = projectStore
        self.contextManager = contextManager
        self.maxAttempts = maxAttempts
    }
    
    /// Generate code, execute it, and fix errors until success or max attempts.
    /// - Parameters:
    ///   - prompt: The user's request
    ///   - filePath: Where to save the generated code
    ///   - onProgress: Called with status updates
    /// - Returns: The final execution result
    func run(
        prompt: String,
        filePath: String,
        onProgress: @escaping (FixLoopProgress) async -> Void
    ) async throws -> FixLoopResult {
        attempts = 0
        var lastError: String?
        var lastCode: String?
        
        // Generate initial code
        await onProgress(.generating(attempt: 1))
        
        let initialRequest = GenerationRequest.generate(
            prompt: prompt,
            filePath: filePath,
            maxTokens: 2048
        )
        
        guard await modelManager.state.isReady else {
            throw FixLoopError.modelNotReady
        }
        
        let initialResponse = try await modelManager.generate(request: initialRequest)
        var code = PromptTemplates.extractCode(initialResponse.text)
        
        // Write and execute loop
        while attempts < maxAttempts {
            attempts += 1
            lastCode = code
            
            // Write to file
            await onProgress(.writing(attempt: attempts, path: filePath))
            _ = try await projectStore.writeFile(code, to: filePath)
            
            // Execute
            await onProgress(.executing(attempt: attempts))
            let result = await runtime.runFile(path: filePath)
            
            if !result.hadError {
                // Success!
                await onProgress(.succeeded(attempt: attempts))
                return FixLoopResult(
                    succeeded: true,
                    finalCode: code,
                    output: result.output,
                    attempts: attempts
                )
            }
            
            // Failed - extract error and try to fix
            let errorMessage = result.error?.message ?? "Unknown error"
            lastError = errorMessage
            
            if attempts >= maxAttempts {
                break
            }
            
            // Generate fix
            await onProgress(.fixing(attempt: attempts + 1, error: errorMessage))
            
            let fixRequest = GenerationRequest.fix(
                code: code,
                error: errorMessage,
                filePath: filePath,
                maxTokens: 2048
            )
            
            let fixResponse = try await modelManager.generate(request: fixRequest)
            code = PromptTemplates.extractCode(fixResponse.text)
        }
        
        // Max attempts reached
        await onProgress(.failed(attempts: attempts, error: lastError ?? "Unknown error"))
        
        return FixLoopResult(
            succeeded: false,
            finalCode: lastCode ?? code,
            output: lastError ?? "Max attempts reached",
            attempts: attempts
        )
    }
}

/// Progress updates from the fix loop.
enum FixLoopProgress: Sendable {
    case generating(attempt: Int)
    case writing(attempt: Int, path: String)
    case executing(attempt: Int)
    case fixing(attempt: Int, error: String)
    case succeeded(attempt: Int)
    case failed(attempts: Int, error: String)
}

/// Result of the fix loop.
struct FixLoopResult: Sendable {
    let succeeded: Bool
    let finalCode: String
    let output: String
    let attempts: Int
}

/// Errors from the fix loop.
enum FixLoopError: Error, LocalizedError {
    case modelNotReady
    case generationFailed(String)
    case maxAttemptsReached(lastError: String)
    
    var errorDescription: String? {
        switch self {
        case .modelNotReady:
            return "Local model is not ready for inference"
        case .generationFailed(let reason):
            return "Code generation failed: \(reason)"
        case .maxAttemptsReached(let lastError):
            return "Max fix attempts reached. Last error: \(lastError)"
        }
    }
}
