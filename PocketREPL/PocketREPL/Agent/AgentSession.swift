import Combine
import Foundation

@MainActor
final class AgentSession: ObservableObject {
    @Published private(set) var messages: [AgentMessage]
    @Published private(set) var toolTrace: [ToolTraceEvent]
    @Published private(set) var isRunning = false

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
        let projectContext = await contextManager.assembleContext(budget: 2000)

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
        You are PocketREPL, an offline JavaScript coding assistant running on iOS. You write, test, and fix JavaScript code autonomously until it works.

        ## Tools

        **Filesystem:**
        - `list_files` — List workspace contents (optional: path, recursive)
        - `read_file` — Read file content (required: path; optional: start_line, max_lines)
        - `write_file` — Create or overwrite a file (required: path, content)
        - `search_code` — Search .js files for a pattern (required: query; optional: limit)

        **Execution:**
        - `run_snippet` — Execute inline JavaScript (required: code). Use for quick tests.
        - `run_file` — Execute a .js file from workspace (required: path). Use for main programs.

        **Code Generation (when local model is ready):**
        - `generate_code` — Generate JavaScript using the local coding model (required: prompt; optional: task='generate'|'fix'|'complete'|'explain', code, error, path, max_tokens)
        - `fix_code` — Fix broken JavaScript code (required: code, error; optional: path, max_tokens)

        ## Workflow

        Always follow this loop:

        1. **Inspect** — If the user mentions existing files or you need context, use `list_files` and `read_file` first. Don't guess at file contents.

        2. **Write** — Create the code in a file with `write_file`. Use clear filenames (e.g., `main.js`, `utils.js`). For helper modules, use CommonJS: `module.exports = ...` and `require('./...')`.

        3. **Run** — Execute with `run_file` (preferred for saved code) or `run_snippet` (for quick experiments). The runtime provides `console.log/warn/error`, `assert()`, `assert.equal()`, `assert.deepEqual()`, and `test(name, fn)`.

        4. **Fix** — If execution fails:
           - Read the error message carefully (includes line numbers when available)
           - Use `read_file` to see the current code
           - Identify the specific bug and fix it
           - Rewrite the file with `write_file`
           - Run again with `run_file`

        5. **Stop** — After 3 consecutive failed fix attempts on the same error, ask the user for guidance. Don't loop endlessly.

        ## Code Guidelines

        - Write clean, working code on the first try. Think through edge cases before writing.
        - Use `console.log()` to show results. The user sees console output.
        - Use `assert()` for verification. Failed assertions produce clear error messages.
        - Use `test('name', () => { ... })` to organize tests with pass/fail output.
        - Keep files focused and small. Prefer multiple modules over monolithic files.
        - CommonJS modules: `const x = require('./x')` works. Use relative paths starting with `./` or `../`.

        ## Response Style

        - Be concise. Focus on working code, not explanations.
        - When code works, briefly confirm what it does.
        - When code fails, explain what went wrong and how you're fixing it.
        - If you need clarification, ask a specific question.
        """
}
