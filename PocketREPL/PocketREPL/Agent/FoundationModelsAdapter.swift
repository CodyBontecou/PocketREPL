import Combine
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Orchestration Session

/// Orchestrates the agent's write-run-fix loop with tool execution.
/// Uses Foundation Models when available, otherwise provides a fallback mode.
@MainActor
final class AgentOrchestrator: ObservableObject {
    enum Mode {
        case foundationModels
        case fallback
    }

    @Published private(set) var mode: Mode = .fallback
    @Published private(set) var isProcessing = false
    @Published private(set) var retryState: RetryState

    private let toolExecutor: ToolExecutor
    private let systemInstructions: String
    private let maxToolIterations: Int
    private let maxConsecutiveFailures: Int

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private var session: LanguageModelSession?
    #endif

    init(
        toolExecutor: ToolExecutor,
        systemInstructions: String,
        maxToolIterations: Int = 10,
        maxConsecutiveFailures: Int = 3
    ) {
        self.toolExecutor = toolExecutor
        self.systemInstructions = systemInstructions
        self.maxToolIterations = maxToolIterations
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.retryState = RetryState()
        self.mode = Self.detectMode()
    }

    private static func detectMode() -> Mode {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            // Check if model assets are actually available
            let availability = SystemLanguageModel.default.availability
            switch availability {
            case .available:
                return .foundationModels
            case .unavailable:
                print("[AgentOrchestrator] Foundation Models unavailable on this device")
                return .fallback
            @unknown default:
                return .fallback
            }
        }
        #endif
        return .fallback
    }
    
    /// Check current model availability status
    var modelAvailabilityStatus: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let availability = SystemLanguageModel.default.availability
            switch availability {
            case .available:
                return String(localized: "Model is ready")
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return String(localized: "This device doesn't support Apple Intelligence")
                case .appleIntelligenceNotEnabled:
                    return String(localized: "Apple Intelligence is not enabled. Go to Settings > Apple Intelligence & Siri to enable it.")
                case .modelNotReady:
                    return String(localized: "Model is downloading. Please wait for Apple Intelligence to finish setup.")
                @unknown default:
                    return String(localized: "Model unavailable: \(String(describing: reason))")
                }
            @unknown default:
                return String(localized: "Unknown availability status")
            }
        }
        #endif
        return String(localized: "Foundation Models not supported on this OS version")
    }

    /// Process a user prompt, executing tools as needed.
    func process(
        prompt: String,
        projectContext: String? = nil,
        onAssistantMessage: @escaping (String) async -> Void,
        onToolCall: @escaping (String, [String: Any]) async -> Void,
        onToolResult: @escaping (String, ToolResult) async -> Void
    ) async throws -> OrchestrationResult {
        isProcessing = true
        defer { isProcessing = false }

        switch mode {
        case .foundationModels:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                return try await processWithFoundationModels(
                    prompt: prompt,
                    projectContext: projectContext,
                    onAssistantMessage: onAssistantMessage,
                    onToolCall: onToolCall,
                    onToolResult: onToolResult
                )
            }
            #endif
            fallthrough
        case .fallback:
            return await processWithFallback(
                prompt: prompt,
                projectContext: projectContext,
                onAssistantMessage: onAssistantMessage,
                onToolCall: onToolCall,
                onToolResult: onToolResult
            )
        }
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private func processWithFoundationModels(
        prompt: String,
        projectContext: String?,
        onAssistantMessage: @escaping (String) async -> Void,
        onToolCall: @escaping (String, [String: Any]) async -> Void,
        onToolResult: @escaping (String, ToolResult) async -> Void
    ) async throws -> OrchestrationResult {
        // Check model availability first
        let availability = SystemLanguageModel.default.availability
        if case .unavailable(let reason) = availability {
            let msg: String
            switch reason {
            case .deviceNotEligible:
                msg = String(localized: "⚠️ This device doesn't support Apple Intelligence. Using fallback mode.")
            case .appleIntelligenceNotEnabled:
                msg = String(localized: "⚠️ Apple Intelligence is not enabled.\n\nGo to Settings > Apple Intelligence & Siri to enable it.")
            case .modelNotReady:
                msg = String(localized: "⚠️ Apple Intelligence model is still downloading.\n\nPlease wait for it to finish in Settings > Apple Intelligence & Siri.")
            @unknown default:
                msg = String(localized: "⚠️ AI model unavailable: \(String(describing: reason))")
            }
            await onAssistantMessage(msg)
            mode = .fallback
            return await processWithFallback(
                prompt: prompt,
                projectContext: projectContext,
                onAssistantMessage: onAssistantMessage,
                onToolCall: onToolCall,
                onToolResult: onToolResult
            )
        }
        
        // Create session if needed
        if session == nil {
            session = LanguageModelSession(instructions: Instructions(systemInstructions))
        }

        guard let session = session else {
            throw OrchestrationError.sessionNotInitialized
        }

        // Build the full prompt with context
        var currentPrompt = prompt
        if let context = projectContext, !context.isEmpty {
            currentPrompt = """
                Context:
                \(context)

                User request:
                \(prompt)
                """
        }

        var toolCalls: [(name: String, parameters: [String: Any], result: String)] = []
        var iterations = 0
        var stoppedDueToRetryLimit = false
        var finalResponse = ""

        // Agentic loop - keep processing until model returns text or we hit limits
        while iterations < maxToolIterations {
            iterations += 1

            let response: LanguageModelSession.Response<AgentAction>
            do {
                response = try await session.respond(to: currentPrompt, generating: AgentAction.self)
            } catch let error as LanguageModelSession.GenerationError {
                let msg: String
                switch error {
                case .guardrailViolation(_):
                    msg = String(localized: "I can't help with that request.")
                    
                case .exceededContextWindowSize:
                    // Auto-reset the session and retry with a fresh context
                    self.session = nil
                    msg = String(localized: "⚠️ Context limit reached. Starting fresh session. Please try again.")
                    
                case .assetsUnavailable(_):
                    msg = String(localized: "⚠️ Apple Intelligence model is not available.\n\nTo use AI features:\n1. Go to Settings > Apple Intelligence & Siri\n2. Enable Apple Intelligence\n3. Wait for the model to finish downloading (~4GB)")
                    mode = .fallback
                    
                case .unsupportedLanguageOrLocale(_):
                    msg = String(localized: "⚠️ Your device language/locale is not supported by Apple Intelligence.")
                    mode = .fallback
                    
                case .rateLimited(_):
                    msg = String(localized: "⚠️ Too many requests. Please wait a moment and try again.")
                    
                case .concurrentRequests(_):
                    msg = String(localized: "⚠️ Another request is in progress. Please wait for it to complete.")
                    
                case .refusal(_, _):
                    msg = String(localized: "I can't help with that request.")
                    
                case .decodingFailure(_):
                    msg = String(localized: "⚠️ Failed to process the response. Please try again.")
                    
                case .unsupportedGuide(_):
                    msg = String(localized: "⚠️ Unsupported model configuration.")
                    
                @unknown default:
                    throw error
                }
                
                await onAssistantMessage(msg)
                return OrchestrationResult(
                    response: msg,
                    toolCalls: toolCalls,
                    iterations: iterations,
                    stoppedDueToRetryLimit: false
                )
            }

            // Process the action
            switch response.content {
            case .respond(let textResponse):
                // Model is done - return text response
                finalResponse = textResponse.message
                await onAssistantMessage(finalResponse)
                return OrchestrationResult(
                    response: finalResponse,
                    toolCalls: toolCalls,
                    iterations: iterations,
                    stoppedDueToRetryLimit: false
                )

            case .listFiles(let tool):
                let (name, params, result) = await executeListFiles(tool, onToolCall: onToolCall, onToolResult: onToolResult)
                toolCalls.append((name, params, result))
                currentPrompt = "Tool result:\n\(result)\n\nContinue with the next step or respond to the user."

            case .readFile(let tool):
                let (name, params, result) = await executeReadFile(tool, onToolCall: onToolCall, onToolResult: onToolResult)
                toolCalls.append((name, params, result))
                currentPrompt = "Tool result:\n\(result)\n\nContinue with the next step or respond to the user."

            case .writeFile(let tool):
                let (name, params, result) = await executeWriteFile(tool, onToolCall: onToolCall, onToolResult: onToolResult)
                toolCalls.append((name, params, result))
                currentPrompt = "Tool result:\n\(result)\n\nContinue with the next step or respond to the user."

            case .searchCode(let tool):
                let (name, params, result) = await executeSearchCode(tool, onToolCall: onToolCall, onToolResult: onToolResult)
                toolCalls.append((name, params, result))
                currentPrompt = "Tool result:\n\(result)\n\nContinue with the next step or respond to the user."

            case .runSnippet(let tool):
                let (name, params, result) = await executeRunSnippet(tool, onToolCall: onToolCall, onToolResult: onToolResult)
                toolCalls.append((name, params, result))

                // Check retry limits for execution tools
                let isError = result.contains("[RUNTIME ERROR]") || result.contains("[SYNTAX ERROR]") || result.contains("[ASSERTION FAILED]")
                let toolResult = isError ? ToolResult.failure(result) : ToolResult.success(result)
                stoppedDueToRetryLimit = recordToolResult(toolResult, toolName: "run_snippet")
                
                if stoppedDueToRetryLimit {
                    let msg = String(localized: "⚠️ Retry limit reached after \(retryState.consecutiveFailures) consecutive failures on the same error. Please review and provide guidance.")
                    await onAssistantMessage(msg)
                    return OrchestrationResult(
                        response: msg,
                        toolCalls: toolCalls,
                        iterations: iterations,
                        stoppedDueToRetryLimit: true
                    )
                }
                currentPrompt = "Tool result:\n\(result)\n\nContinue with the next step or respond to the user."

            case .runFile(let tool):
                let (name, params, result) = await executeRunFile(tool, onToolCall: onToolCall, onToolResult: onToolResult)
                toolCalls.append((name, params, result))

                // Check retry limits for execution tools
                let isError = result.contains("[RUNTIME ERROR]") || result.contains("[SYNTAX ERROR]") || result.contains("[ASSERTION FAILED]")
                let toolResult = isError ? ToolResult.failure(result) : ToolResult.success(result)
                stoppedDueToRetryLimit = recordToolResult(toolResult, toolName: "run_file")
                
                if stoppedDueToRetryLimit {
                    let msg = String(localized: "⚠️ Retry limit reached after \(retryState.consecutiveFailures) consecutive failures on the same error. Please review and provide guidance.")
                    await onAssistantMessage(msg)
                    return OrchestrationResult(
                        response: msg,
                        toolCalls: toolCalls,
                        iterations: iterations,
                        stoppedDueToRetryLimit: true
                    )
                }
                currentPrompt = "Tool result:\n\(result)\n\nContinue with the next step or respond to the user."
            }
        }

        // Hit max iterations
        let msg = String(localized: "Reached maximum tool iterations (\(maxToolIterations)). Stopping.")
        await onAssistantMessage(msg)
        return OrchestrationResult(
            response: msg,
            toolCalls: toolCalls,
            iterations: iterations,
            stoppedDueToRetryLimit: false
        )
    }

    // MARK: - Tool Execution Helpers

    @available(iOS 26.0, macOS 26.0, *)
    private func executeListFiles(
        _ tool: ListFilesAction,
        onToolCall: @escaping (String, [String: Any]) async -> Void,
        onToolResult: @escaping (String, ToolResult) async -> Void
    ) async -> (name: String, parameters: [String: Any], result: String) {
        let params: [String: Any] = [
            "path": tool.path ?? "",
            "recursive": tool.recursive
        ]
        await onToolCall("list_files", params)
        let result = await toolExecutor.execute(toolName: "list_files", parameters: params)
        await onToolResult("list_files", result)
        return ("list_files", params, result.output)
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func executeReadFile(
        _ tool: ReadFileAction,
        onToolCall: @escaping (String, [String: Any]) async -> Void,
        onToolResult: @escaping (String, ToolResult) async -> Void
    ) async -> (name: String, parameters: [String: Any], result: String) {
        var params: [String: Any] = ["path": tool.path]
        if let startLine = tool.startLine { params["start_line"] = startLine }
        if let maxLines = tool.maxLines { params["max_lines"] = maxLines }
        await onToolCall("read_file", params)
        let result = await toolExecutor.execute(toolName: "read_file", parameters: params)
        await onToolResult("read_file", result)
        return ("read_file", params, result.output)
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func executeWriteFile(
        _ tool: WriteFileAction,
        onToolCall: @escaping (String, [String: Any]) async -> Void,
        onToolResult: @escaping (String, ToolResult) async -> Void
    ) async -> (name: String, parameters: [String: Any], result: String) {
        let params: [String: Any] = [
            "path": tool.path,
            "content": tool.content
        ]
        await onToolCall("write_file", params)
        let result = await toolExecutor.execute(toolName: "write_file", parameters: params)
        await onToolResult("write_file", result)
        return ("write_file", params, result.output)
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func executeSearchCode(
        _ tool: SearchCodeAction,
        onToolCall: @escaping (String, [String: Any]) async -> Void,
        onToolResult: @escaping (String, ToolResult) async -> Void
    ) async -> (name: String, parameters: [String: Any], result: String) {
        var params: [String: Any] = ["query": tool.query]
        if let limit = tool.limit { params["limit"] = limit }
        await onToolCall("search_code", params)
        let result = await toolExecutor.execute(toolName: "search_code", parameters: params)
        await onToolResult("search_code", result)
        return ("search_code", params, result.output)
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func executeRunSnippet(
        _ tool: RunSnippetAction,
        onToolCall: @escaping (String, [String: Any]) async -> Void,
        onToolResult: @escaping (String, ToolResult) async -> Void
    ) async -> (name: String, parameters: [String: Any], result: String) {
        let params: [String: Any] = ["code": tool.code]
        await onToolCall("run_snippet", params)
        let result = await toolExecutor.execute(toolName: "run_snippet", parameters: params)
        await onToolResult("run_snippet", result)
        return ("run_snippet", params, result.output)
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func executeRunFile(
        _ tool: RunFileAction,
        onToolCall: @escaping (String, [String: Any]) async -> Void,
        onToolResult: @escaping (String, ToolResult) async -> Void
    ) async -> (name: String, parameters: [String: Any], result: String) {
        let params: [String: Any] = ["path": tool.path]
        await onToolCall("run_file", params)
        let result = await toolExecutor.execute(toolName: "run_file", parameters: params)
        await onToolResult("run_file", result)
        return ("run_file", params, result.output)
    }
    #endif

    private func processWithFallback(
        prompt: String,
        projectContext: String?,
        onAssistantMessage: @escaping (String) async -> Void,
        onToolCall: @escaping (String, [String: Any]) async -> Void,
        onToolResult: @escaping (String, ToolResult) async -> Void
    ) async -> OrchestrationResult {
        // Fallback mode: Parse simple tool commands from the prompt
        var toolCalls: [(name: String, parameters: [String: Any], result: String)] = []

        if let (toolName, params) = parseDirectToolCall(prompt) {
            if retryState.isAtLimit && (toolName == "run_snippet" || toolName == "run_file") {
                let response = String(localized: "⚠️ Retry limit reached (\(maxConsecutiveFailures) consecutive failures on the same error).\n\nLast error: \(retryState.lastFailureSignature ?? "Unknown")\n\nPlease review the error and provide guidance, or use a different approach.")
                await onAssistantMessage(response)
                return OrchestrationResult(response: response, toolCalls: [], iterations: 0, stoppedDueToRetryLimit: true)
            }

            await onToolCall(toolName, params)
            let result = await toolExecutor.execute(toolName: toolName, parameters: params)
            await onToolResult(toolName, result)
            toolCalls.append((name: toolName, parameters: params, result: result.output))

            let shouldStop = recordToolResult(result, toolName: toolName)
            retryState.recordExecution(succeeded: result.succeeded)

            var response = formatToolResponse(toolName: toolName, result: result)

            if shouldStop {
                response += String(localized: "\n\n⚠️ Retry limit reached. \(retryState.consecutiveFailures) consecutive failures on the same error. Please review and provide guidance.")
            }

            await onAssistantMessage(response)
            return OrchestrationResult(response: response, toolCalls: toolCalls, iterations: 1, stoppedDueToRetryLimit: shouldStop)
        }

        let tools = await toolExecutor.availableTools
        let toolList = tools.map { "- \($0.id): \($0.summary)" }.joined(separator: "\n")
        let response = """
            I received your prompt: "\(prompt)"
            
            Foundation Models is not available on this device.
            In fallback mode, you can invoke tools directly:
            
            Available tools:
            \(toolList)
            
            Example: list_files or run_snippet {"code": "console.log('hello')"}
            """
        await onAssistantMessage(response)
        return OrchestrationResult(response: response, toolCalls: [], iterations: 0, stoppedDueToRetryLimit: false)
    }

    private func parseDirectToolCall(_ input: String) -> (String, [String: Any])? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let availableToolNames = ["list_files", "read_file", "write_file", "search_code", "run_snippet", "run_file"]

        for toolName in availableToolNames {
            if trimmed == toolName {
                return (toolName, [:])
            }
            if trimmed.hasPrefix(toolName + " ") {
                let jsonPart = String(trimmed.dropFirst(toolName.count + 1))
                if let data = jsonPart.data(using: .utf8),
                   let params = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return (toolName, params)
                }
            }
        }

        return nil
    }

    private func formatToolResponse(toolName: String, result: ToolResult) -> String {
        let status = result.succeeded ? "✓" : "✗"
        return "[\(status) \(toolName)]\n\(result.output)"
    }

    func reset() {
        retryState = RetryState()
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            session = nil
        }
        #endif
    }

    func recordToolResult(_ result: ToolResult, toolName: String) -> Bool {
        let isExecutionTool = toolName == "run_snippet" || toolName == "run_file"

        if result.succeeded {
            if isExecutionTool {
                retryState.consecutiveFailures = 0
                retryState.lastFailureSignature = nil
            }
            return false
        }

        guard isExecutionTool else { return false }

        let signature = errorSignature(from: result.output)

        if retryState.lastFailureSignature == signature {
            retryState.consecutiveFailures += 1
        } else {
            retryState.consecutiveFailures = 1
            retryState.lastFailureSignature = signature
        }

        return retryState.consecutiveFailures >= maxConsecutiveFailures
    }

    private func errorSignature(from output: String) -> String {
        let lines = output.components(separatedBy: "\n")
        guard let firstLine = lines.first else { return output }

        var signature = firstLine
        signature = signature.replacingOccurrences(
            of: #"\s*\(line \d+\)"#,
            with: "",
            options: .regularExpression
        )
        signature = signature.replacingOccurrences(
            of: #":\d+:\d+"#,
            with: ":N:N",
            options: .regularExpression
        )

        return signature.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Foundation Models Tool Definitions

#if canImport(FoundationModels)
import FoundationModels

/// The model chooses one of these actions in response to each prompt.
/// Either respond with text, or use a tool.
@available(iOS 26.0, macOS 26.0, *)
@Generable
enum AgentAction {
    /// Respond to the user with a text message. Use when you have completed the task or need to ask a question.
    case respond(TextResponse)
    
    /// List files and directories in the workspace.
    case listFiles(ListFilesAction)
    
    /// Read text content from a file.
    case readFile(ReadFileAction)
    
    /// Create or overwrite a file with content.
    case writeFile(WriteFileAction)
    
    /// Search JavaScript files for a text pattern.
    case searchCode(SearchCodeAction)
    
    /// Execute inline JavaScript code.
    case runSnippet(RunSnippetAction)
    
    /// Execute a JavaScript file from the workspace.
    case runFile(RunFileAction)
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct TextResponse {
    @Guide(description: "Your response message to the user. Be concise and helpful.")
    var message: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct ListFilesAction {
    @Guide(description: "Optional path relative to workspace root. Leave empty for root.")
    var path: String?

    @Guide(description: "Whether to list recursively into subdirectories.")
    var recursive: Bool = false
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct ReadFileAction {
    @Guide(description: "Path to the file relative to workspace root.")
    var path: String

    @Guide(description: "Line number to start reading from (1-indexed).")
    var startLine: Int?

    @Guide(description: "Maximum number of lines to read.")
    var maxLines: Int?
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct WriteFileAction {
    @Guide(description: "Path to the file relative to workspace root.")
    var path: String

    @Guide(description: "Content to write to the file.")
    var content: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct SearchCodeAction {
    @Guide(description: "Text pattern to search for in JavaScript files.")
    var query: String

    @Guide(description: "Maximum number of results to return.")
    var limit: Int?
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct RunSnippetAction {
    @Guide(description: "JavaScript code to execute.")
    var code: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct RunFileAction {
    @Guide(description: "Path to the JavaScript file to execute, relative to workspace root.")
    var path: String
}
#endif

// MARK: - Orchestration Types

struct RetryState: Sendable, Equatable {
    var consecutiveFailures: Int = 0
    var lastFailureSignature: String?
    var totalExecutions: Int = 0
    var totalFailures: Int = 0

    var isAtLimit: Bool { consecutiveFailures >= 3 }

    mutating func recordExecution(succeeded: Bool) {
        totalExecutions += 1
        if !succeeded {
            totalFailures += 1
        }
    }
}

struct OrchestrationResult: Sendable {
    let response: String
    let toolCalls: [(name: String, parameters: [String: Any], result: String)]
    let iterations: Int
    let stoppedDueToRetryLimit: Bool

    var hadToolCalls: Bool { !toolCalls.isEmpty }

    init(
        response: String,
        toolCalls: [(name: String, parameters: [String: Any], result: String)],
        iterations: Int,
        stoppedDueToRetryLimit: Bool = false
    ) {
        self.response = response
        self.toolCalls = toolCalls
        self.iterations = iterations
        self.stoppedDueToRetryLimit = stoppedDueToRetryLimit
    }
}

enum OrchestrationError: LocalizedError {
    case sessionNotInitialized
    case maxIterationsExceeded
    case modelUnavailable

    var errorDescription: String? {
        switch self {
        case .sessionNotInitialized:
            return "The orchestration session has not been initialized."
        case .maxIterationsExceeded:
            return "The maximum number of tool iterations was exceeded."
        case .modelUnavailable:
            return "The on-device language model is not available."
        }
    }
}
