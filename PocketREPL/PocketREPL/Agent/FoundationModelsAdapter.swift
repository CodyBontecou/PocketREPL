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
            return .foundationModels
        }
        #endif
        return .fallback
    }

    /// Process a user prompt, executing tools as needed.
    /// - Parameters:
    ///   - prompt: The user's message
    ///   - projectContext: Optional assembled context from ContextManager
    ///   - onAssistantMessage: Called when the assistant produces a message
    ///   - onToolCall: Called when a tool is about to be executed
    ///   - onToolResult: Called when a tool execution completes
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
        // Foundation Models integration
        // TODO: Implement when Foundation Models API is finalized
        // The projectContext would be injected into the conversation context here
        // For now, fall back to the basic mode
        return await processWithFallback(
            prompt: prompt,
            projectContext: projectContext,
            onAssistantMessage: onAssistantMessage,
            onToolCall: onToolCall,
            onToolResult: onToolResult
        )
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
        // This allows basic testing without Foundation Models
        var toolCalls: [(name: String, parameters: [String: Any], result: String)] = []

        // Check if the prompt looks like a direct tool invocation
        if let (toolName, params) = parseDirectToolCall(prompt) {
            // Check if we're at the retry limit for execution tools
            if retryState.isAtLimit && (toolName == "run_snippet" || toolName == "run_file") {
                let response = """
                    ⚠️ Retry limit reached (\(maxConsecutiveFailures) consecutive failures on the same error).
                    
                    Last error: \(retryState.lastFailureSignature ?? "Unknown")
                    
                    Please review the error and provide guidance, or use a different approach.
                    """
                await onAssistantMessage(response)
                return OrchestrationResult(response: response, toolCalls: [], iterations: 0, stoppedDueToRetryLimit: true)
            }

            await onToolCall(toolName, params)
            let result = await toolExecutor.execute(toolName: toolName, parameters: params)
            await onToolResult(toolName, result)
            toolCalls.append((name: toolName, parameters: params, result: result.output))

            // Track execution results for retry limiting
            let shouldStop = recordToolResult(result, toolName: toolName)
            retryState.recordExecution(succeeded: result.succeeded)

            var response = formatToolResponse(toolName: toolName, result: result)

            if shouldStop {
                response += "\n\n⚠️ Retry limit reached. \(retryState.consecutiveFailures) consecutive failures on the same error. Please review and provide guidance."
            }

            await onAssistantMessage(response)
            return OrchestrationResult(response: response, toolCalls: toolCalls, iterations: 1, stoppedDueToRetryLimit: shouldStop)
        }

        // Default response in fallback mode
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

    /// Parse a direct tool invocation from user input.
    /// Format: "tool_name" or "tool_name {json_params}"
    private func parseDirectToolCall(_ input: String) -> (String, [String: Any])? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let availableToolNames = ["list_files", "read_file", "write_file", "search_code", "run_snippet", "run_file"]

        // Check for "tool_name {json}" or just "tool_name"
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
    }

    /// Record a tool execution result for retry tracking.
    /// Returns true if the agent should stop due to too many consecutive failures.
    func recordToolResult(_ result: ToolResult, toolName: String) -> Bool {
        let isExecutionTool = toolName == "run_snippet" || toolName == "run_file"

        if result.succeeded {
            if isExecutionTool {
                // Successful execution resets the counter
                retryState.consecutiveFailures = 0
                retryState.lastFailureSignature = nil
            }
            return false
        }

        // Only count execution failures for retry limiting
        guard isExecutionTool else { return false }

        // Check if this is the same error as before
        let signature = errorSignature(from: result.output)

        if retryState.lastFailureSignature == signature {
            retryState.consecutiveFailures += 1
        } else {
            // New error type, reset counter
            retryState.consecutiveFailures = 1
            retryState.lastFailureSignature = signature
        }

        return retryState.consecutiveFailures >= maxConsecutiveFailures
    }

    /// Extract a signature from an error message for deduplication.
    private func errorSignature(from output: String) -> String {
        // Extract the core error message, ignoring line numbers and variable values
        let lines = output.components(separatedBy: "\n")
        guard let firstLine = lines.first else { return output }

        // Strip line/column references like "(line 5)" or ":5:10"
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

// MARK: - Orchestration Types

/// Tracks consecutive execution failures for bounded retry logic.
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
