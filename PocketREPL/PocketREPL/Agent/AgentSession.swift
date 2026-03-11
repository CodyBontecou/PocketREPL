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
        self.systemPrompt = systemPrompt ?? Self.defaultSystemPrompt
        self.orchestrator = AgentOrchestrator(
            toolExecutor: toolExecutor,
            systemInstructions: systemPrompt ?? Self.defaultSystemPrompt
        )
        self.messages = [
            AgentMessage(
                role: .assistant,
                text: "PocketREPL is ready. Tools are wired to ProjectStore and JSRuntime."
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
                    await MainActor.run {
                        self?.messages.append(AgentMessage(role: .assistant, text: message))
                    }
                },
                onToolCall: { [weak self] toolName, params in
                    await MainActor.run {
                        self?.toolTrace.append(
                            ToolTraceEvent(
                                kind: .call,
                                toolName: toolName,
                                summary: self?.formatToolCallSummary(name: toolName, parameters: params) ?? toolName,
                                status: .pending
                            )
                        )
                    }
                },
                onToolResult: { [weak self] toolName, toolResult in
                    await MainActor.run {
                        let truncated = toolResult.output.count > 200
                            ? String(toolResult.output.prefix(200)) + "..."
                            : toolResult.output
                        self?.toolTrace.append(
                            ToolTraceEvent(
                                kind: .result,
                                toolName: toolName,
                                summary: truncated,
                                status: toolResult.succeeded ? .succeeded : .failed
                            )
                        )
                    }
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
                    text: "Error: \(error.localizedDescription)"
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

    // MARK: - Session Control

    /// Reset the JavaScript runtime, clearing module cache and state.
    func resetRuntime() async {
        await runtime.reset()
        toolTrace.append(
            ToolTraceEvent(
                kind: .note,
                toolName: "runtime",
                summary: "JavaScript runtime reset. Module cache cleared.",
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
                text: "New session started. Tools are ready."
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
