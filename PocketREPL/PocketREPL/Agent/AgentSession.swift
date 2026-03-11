import Combine
import Foundation

@MainActor
final class AgentSession: ObservableObject {
    @Published private(set) var messages: [AgentMessage]
    @Published private(set) var toolTrace: [ToolTraceEvent]
    @Published private(set) var isRunning = false

    /// Whether Foundation Models (Apple Intelligence) is available
    var isAIAvailable: Bool {
        orchestrator.mode == .foundationModels
    }
    
    /// Human-readable status message about AI availability
    var aiAvailabilityStatus: String {
        orchestrator.modelAvailabilityStatus
    }
    
    // MARK: - Context Tracking
    
    /// Estimated context window limit for Foundation Models
    /// Apple Intelligence on-device models have a small context window
    static let estimatedContextLimit = 4096
    
    /// Estimate tokens for a string (~4 chars per token, minimum 1)
    private static func estimateTokens(for text: String) -> Int {
        max(1, text.count / 4)
    }
    
    /// Context settings manager for customizable prompt and tool toggles
    private let contextSettings = ContextSettingsManager.shared
    
    // MARK: - Dual Model Context Tracking
    
    /// Cached local model context tokens (updated asynchronously)
    private var _cachedLocalModelTokens: Int?
    private var _cachedLocalModelLimit: Int?
    
    /// Foundation Models (Apple Intelligence) context tokens
    var foundationModelTokens: Int? {
        orchestrator.sessionContextTokens
    }
    
    /// Foundation Models context limit
    var foundationModelLimit: Int {
        Self.estimatedContextLimit
    }
    
    /// Local model (Qwen) context tokens
    var localModelTokens: Int? {
        _cachedLocalModelTokens
    }
    
    /// Local model context limit
    var localModelLimit: Int? {
        _cachedLocalModelLimit
    }
    
    /// Whether the local model is loaded and active
    var isLocalModelActive: Bool {
        modelManager?.modelInfo != nil
    }
    
    /// Combined estimated tokens (primary model for display)
    /// Shows Foundation Models context when in AI mode, local estimate otherwise
    var estimatedContextTokens: Int {
        // Foundation Models is the primary context to track (agent conversation)
        if let sessionTokens = orchestrator.sessionContextTokens {
            return sessionTokens
        }
        
        // Fall back to local estimation for the conversation
        return localEstimatedContextTokens
    }
    
    /// The context limit to use (Foundation Models limit for primary display)
    var effectiveContextLimit: Int {
        Self.estimatedContextLimit
    }
    
    /// Whether we're using real session context (vs local estimate)
    var isUsingRealContextTracking: Bool {
        orchestrator.sessionContextTokens != nil
    }
    
    /// Whether local model has context in use
    var isLocalModelContextActive: Bool {
        (_cachedLocalModelTokens ?? 0) > 0
    }
    
    /// Refresh local model context tracking (call periodically or after generations)
    func refreshLocalModelContext() async {
        guard let modelManager = modelManager else {
            _cachedLocalModelTokens = nil
            _cachedLocalModelLimit = nil
            return
        }
        _cachedLocalModelTokens = await modelManager.currentContextTokens
        _cachedLocalModelLimit = await modelManager.maxContextTokens
    }
    
    /// Local estimate of tokens (used when Foundation Models session isn't available)
    private var localEstimatedContextTokens: Int {
        var tokens = 0
        
        // 1. System prompt (from settings manager - may be custom or default)
        tokens += Self.estimateTokens(for: contextSettings.effectiveSystemPrompt)
        
        // 2. Tool definitions schema (only count enabled tools)
        // Each tool is ~50 tokens for its @Generable schema + descriptions
        tokens += contextSettings.enabledToolCount * 50
        
        // 3. Project context (injected with prompts, ~500 char budget = ~125 tokens)
        // This is sent with each user turn but we count it once as baseline
        tokens += 125
        
        // 4. All conversation messages (user, assistant, tool calls, tool results)
        for message in messages {
            // Base message text
            tokens += Self.estimateTokens(for: message.text)
            
            // Role/structure overhead (~5 tokens per message)
            tokens += 5
            
            // Tool-specific content
            if let toolName = message.toolName {
                tokens += Self.estimateTokens(for: toolName) + 3 // +3 for structure
            }
            if let toolParams = message.toolParameters {
                tokens += Self.estimateTokens(for: toolParams)
            }
        }
        
        // 5. Per-turn overhead for the agentic loop prompts ("Tool result:\n...\nContinue...")
        let toolResultMessages = messages.filter { $0.role == .toolResult }.count
        tokens += toolResultMessages * 15  // ~15 tokens per continuation prompt
        
        return tokens
    }
    
    /// Context usage as a fraction (0.0 to 1.0+)
    var contextUsageFraction: Double {
        Double(estimatedContextTokens) / Double(effectiveContextLimit)
    }
    
    /// Whether context is getting close to the limit (>70%)
    var isContextNearLimit: Bool {
        contextUsageFraction > 0.7
    }
    
    /// Whether context has likely exceeded the limit
    var isContextOverLimit: Bool {
        contextUsageFraction > 1.0
    }

    let projectStore: ProjectStore
    let runtime: JSRuntime
    let contextManager: ContextManager
    let modelManager: ModelBackendManager?
    let toolExecutor: ToolExecutor
    let orchestrator: AgentOrchestrator
    let workspaceInfo: WorkspaceInfo
    let systemPrompt: String

    private var hasBootstrapped = false

    init(
        projectStore: ProjectStore,
        runtime: JSRuntime,
        contextManager: ContextManager,
        modelManager: ModelBackendManager? = nil,
        systemPrompt: String? = nil
    ) {
        self.projectStore = projectStore
        self.runtime = runtime
        self.contextManager = contextManager
        self.modelManager = modelManager
        self.toolExecutor = ToolExecutor(
            projectStore: projectStore,
            runtime: runtime,
            modelManager: modelManager,
            contextManager: contextManager
        )
        self.workspaceInfo = projectStore.workspaceInfo
        // Use provided system prompt, or fall back to context settings manager
        let effectivePrompt = systemPrompt ?? ContextSettingsManager.shared.effectiveSystemPrompt
        self.systemPrompt = effectivePrompt
        self.orchestrator = AgentOrchestrator(
            toolExecutor: toolExecutor,
            systemInstructions: effectivePrompt,
            contextSettings: ContextSettingsManager.shared
        )
        self.messages = [
            AgentMessage(
                role: .assistant,
                text: String(localized: "Ready to code.")
            )
        ]
        self.toolTrace = []
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        do {
            let metadata = try await projectStore.createWorkspaceIfNeeded()
            let files = try await projectStore.listFiles()
            let summary = "Opened workspace \(metadata.displayName) at \(metadata.rootURL.lastPathComponent)."
            toolTrace.append(
                ToolTraceEvent(
                    kind: .result,
                    toolName: "workspace_bootstrap",
                    summary: "\(summary) \(files.count) top-level item(s) available.",
                    status: .succeeded
                )
            )
            await contextManager.recordActivity(summary)
        } catch {
            messages.append(
                AgentMessage(
                    role: .assistant,
                    text: "Failed to bootstrap the workspace: \(error.localizedDescription)"
                )
            )
            toolTrace.append(
                ToolTraceEvent(
                    kind: .result,
                    toolName: "workspace_bootstrap",
                    summary: error.localizedDescription,
                    status: .failed
                )
            )
        }
    }

    func send(_ prompt: String) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }

        isRunning = true
        messages.append(AgentMessage(role: .user, text: trimmed))

        // Assemble compact project context for the model
        // Keep budget small for Foundation Models' limited context window
        let projectContext = await contextManager.assembleContext(budget: 500)

        do {
            let result = try await orchestrator.process(
                prompt: trimmed,
                projectContext: projectContext.isEmpty ? nil : projectContext,
                onAssistantMessage: { [weak self] message in
                    self?.messages.append(AgentMessage(role: .assistant, text: message))
                },
                onToolCall: { [weak self] toolName, params in
                    guard let self = self else { return }
                    let summary = self.formatToolCallSummary(name: toolName, parameters: params)
                    self.toolTrace.append(
                        ToolTraceEvent(
                            kind: .call,
                            toolName: toolName,
                            summary: summary,
                            status: .pending
                        )
                    )
                    // Add tool call to chat messages
                    self.messages.append(
                        AgentMessage(
                            role: .toolCall,
                            text: self.formatToolParameters(params),
                            toolName: toolName,
                            toolParameters: self.formatToolParameters(params),
                            toolStatus: .pending
                        )
                    )
                },
                onToolResult: { [weak self] toolName, toolResult in
                    guard let self = self else { return }
                    let status: ToolTraceStatus = toolResult.succeeded ? .succeeded : .failed
                    self.toolTrace.append(
                        ToolTraceEvent(
                            kind: .result,
                            toolName: toolName,
                            summary: toolResult.output.count > 200
                                ? String(toolResult.output.prefix(200)) + "..."
                                : toolResult.output,
                            status: status
                        )
                    )
                    // Add tool result to chat messages
                    self.messages.append(
                        AgentMessage(
                            role: .toolResult,
                            text: toolResult.output,
                            toolName: toolName,
                            toolStatus: status
                        )
                    )
                }
            )

            // Record activity for context (using typed records)
            await contextManager.recordActivity(.prompt, summary: trimmed)
            if result.hadToolCalls {
                for call in result.toolCalls {
                    await contextManager.recordActivity(.toolCall, summary: "\(call.name): \(call.result.prefix(100))")
                }
            }
        } catch {
            messages.append(
                AgentMessage(
                    role: .assistant,
                    text: String(localized: "Error: \(error.localizedDescription)")
                )
            )
            toolTrace.append(
                ToolTraceEvent(
                    kind: .result,
                    toolName: "orchestration",
                    summary: error.localizedDescription,
                    status: .failed
                )
            )
        }

        isRunning = false
    }

    func runSnippetPreview(_ code: String) async {
        let result = await runtime.runSnippet(code: code)
        let summary = result.hadError ? (result.error?.message ?? "Execution failed") : result.output
        toolTrace.append(
            ToolTraceEvent(
                kind: .result,
                toolName: "run_snippet",
                summary: summary.isEmpty ? "Snippet runtime scaffold returned no output." : summary,
                status: result.hadError ? .failed : .succeeded
            )
        )

        // Record execution to context manager
        await contextManager.recordExecution(result)
    }

    // MARK: - Tool Execution

    /// Execute a tool by name with the given parameters, recording trace events.
    @discardableResult
    func executeTool(name: String, parameters: [String: Any]) async -> ToolResult {
        // Record the call
        toolTrace.append(
            ToolTraceEvent(
                kind: .call,
                toolName: name,
                summary: formatToolCallSummary(name: name, parameters: parameters),
                status: .pending
            )
        )

        // Execute
        let result = await toolExecutor.execute(toolName: name, parameters: parameters)

        // Record the result
        let truncatedOutput = result.output.count > 200
            ? String(result.output.prefix(200)) + "..."
            : result.output
        toolTrace.append(
            ToolTraceEvent(
                kind: .result,
                toolName: name,
                summary: truncatedOutput,
                status: result.succeeded ? .succeeded : .failed
            )
        )

        // Record activity and file access for context
        await contextManager.recordActivity(.toolResult, summary: "\(name): \(result.status)")

        // Track file access for context management
        if let path = parameters["path"] as? String {
            switch name {
            case "read_file":
                await contextManager.recordFileAccess(path, isWrite: false)
            case "write_file":
                await contextManager.recordFileAccess(path, isWrite: true)
            case "run_file":
                await contextManager.recordFileAccess(path, isWrite: false)
            default:
                break
            }
        }

        return result
    }

    /// Execute a tool with JSON-encoded parameters.
    @discardableResult
    func executeTool(name: String, jsonParameters: String) async -> ToolResult {
        guard let data = jsonParameters.data(using: .utf8),
              let parameters = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let result = ToolResult.failure("Invalid JSON parameters")
            toolTrace.append(
                ToolTraceEvent(
                    kind: .result,
                    toolName: name,
                    summary: result.output,
                    status: .failed
                )
            )
            return result
        }

        return await executeTool(name: name, parameters: parameters)
    }

    /// Get all available tools for display or prompt construction.
    var availableTools: [ToolDescriptor] {
        get async {
            await toolExecutor.availableTools
        }
    }

    private func formatToolCallSummary(name: String, parameters: [String: Any]) -> String {
        var parts: [String] = []
        for (key, value) in parameters.sorted(by: { $0.key < $1.key }) {
            let valueStr: String
            if let str = value as? String {
                valueStr = str.count > 30 ? String(str.prefix(30)) + "..." : str
            } else {
                valueStr = "\(value)"
            }
            parts.append("\(key)=\(valueStr)")
        }
        return parts.isEmpty ? name : "\(name)(\(parts.joined(separator: ", ")))"
    }
    
    private func formatToolParameters(_ parameters: [String: Any]) -> String {
        var parts: [String] = []
        for (key, value) in parameters.sorted(by: { $0.key < $1.key }) {
            let valueStr: String
            if let str = value as? String {
                // For code, truncate more aggressively
                if key == "code" && str.count > 50 {
                    valueStr = String(str.prefix(50)) + "..."
                } else if str.count > 100 {
                    valueStr = String(str.prefix(100)) + "..."
                } else {
                    valueStr = str
                }
            } else {
                valueStr = "\(value)"
            }
            parts.append("\(key): \(valueStr)")
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Session Control

    /// Reset the JavaScript runtime, clearing module cache and state.
    func resetRuntime() async {
        await runtime.reset()
        toolTrace.append(
            ToolTraceEvent(
                kind: .note,
                toolName: "runtime",
                summary: String(localized: "JavaScript runtime reset. Module cache cleared."),
                status: .succeeded
            )
        )
        await contextManager.recordActivity("Runtime reset")
    }

    /// Start a new session, clearing messages and trace history.
    func newSession() async {
        messages = [
            AgentMessage(
                role: .assistant,
                text: String(localized: "New session started.")
            )
        ]
        toolTrace = []
        orchestrator.reset()
        await runtime.reset()
        await contextManager.reset()
    }

    private static let defaultSystemPrompt = """
        You are PocketREPL, a JavaScript coding assistant. Write, run, and fix code autonomously.
        
        Workflow: inspect files → write code → run → fix errors if needed.
        Use console.log() for output. Use assert() for tests.
        After 3 failed fixes, ask for guidance.
        """
}
