import Foundation

// MARK: - Tool Protocol

nonisolated protocol Tool: Sendable {
    nonisolated var name: String { get }
    nonisolated var summary: String { get }
    func execute(parameters: [String: Any], context: ToolContext) async -> ToolResult
}

// MARK: - Tool Context

struct ToolContext: @unchecked Sendable {
    let projectStore: ProjectStore
    let runtime: JSRuntime
    let modelManager: ModelBackendManager?
    let contextManager: ContextManager?
}

// MARK: - Tool Result

nonisolated enum ToolResultStatus: String, Codable, Sendable {
    case success
    case failure
}

nonisolated struct ToolResult: Sendable {
    let status: ToolResultStatus
    let output: String
    
    nonisolated static func success(_ output: String) -> ToolResult {
        ToolResult(status: .success, output: output)
    }
    
    nonisolated static func failure(_ message: String) -> ToolResult {
        ToolResult(status: .failure, output: message)
    }
    
    var succeeded: Bool { status == .success }
    var failed: Bool { status == .failure }
}

// MARK: - Tool Executor

actor ToolExecutor {
    let context: ToolContext
    private let tools: [String: any Tool]
    
    init(
        projectStore: ProjectStore,
        runtime: JSRuntime,
        modelManager: ModelBackendManager? = nil,
        contextManager: ContextManager? = nil
    ) {
        self.context = ToolContext(
            projectStore: projectStore,
            runtime: runtime,
            modelManager: modelManager,
            contextManager: contextManager
        )
        
        var allTools: [any Tool] = [
            ListFilesTool(),
            ReadFileTool(),
            WriteFileTool(),
            SearchCodeTool(),
            RunSnippetToolImpl(),
            RunFileToolImpl()
        ]
        
        // Add coding model tools if dependencies are available
        if let modelMgr = modelManager, let ctxMgr = contextManager {
            allTools.append(CodingModelTool(modelManager: modelMgr, contextManager: ctxMgr))
            allTools.append(FixCodeTool(modelManager: modelMgr, contextManager: ctxMgr))
        }
        
        var toolMap: [String: any Tool] = [:]
        for tool in allTools {
            toolMap[tool.name] = tool
        }
        self.tools = toolMap
    }
    
    var availableTools: [ToolDescriptor] {
        tools.values.map { ToolDescriptor(id: $0.name, summary: $0.summary) }
            .sorted { $0.id < $1.id }
    }
    
    func execute(toolName: String, parameters: [String: Any]) async -> ToolResult {
        guard let tool = tools[toolName] else {
            return .failure("Unknown tool: \(toolName). Available: \(tools.keys.sorted().joined(separator: ", "))")
        }
        
        return await tool.execute(parameters: parameters, context: context)
    }
    
    func execute(toolName: String, jsonParameters: String) async -> ToolResult {
        guard let data = jsonParameters.data(using: .utf8),
              let parameters = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("Invalid JSON parameters")
        }
        
        return await execute(toolName: toolName, parameters: parameters)
    }
}

// MARK: - Parameter Helpers

private nonisolated func stringParam(_ params: [String: Any], _ key: String, default defaultValue: String? = nil) -> String? {
    params[key] as? String ?? defaultValue
}

private nonisolated func intParam(_ params: [String: Any], _ key: String, default defaultValue: Int? = nil) -> Int? {
    if let value = params[key] as? Int { return value }
    if let value = params[key] as? Double { return Int(value) }
    if let str = params[key] as? String, let value = Int(str) { return value }
    return defaultValue
}

private nonisolated func boolParam(_ params: [String: Any], _ key: String, default defaultValue: Bool = false) -> Bool {
    if let value = params[key] as? Bool { return value }
    if let str = params[key] as? String {
        return str.lowercased() == "true" || str == "1"
    }
    return defaultValue
}

// MARK: - list_files Tool

struct ListFilesTool: Tool {
    let name = "list_files"
    let summary = "List files and directories in the workspace. Returns names, types, and sizes."
    
    func execute(parameters: [String: Any], context: ToolContext) async -> ToolResult {
        let path = stringParam(parameters, "path") ?? ""
        let recursive = boolParam(parameters, "recursive")
        
        do {
            let entries = try await context.projectStore.listFiles(in: path, recursive: recursive)
            
            if entries.isEmpty {
                let location = path.isEmpty ? "workspace root" : "'\(path)'"
                return .success("No files found in \(location).")
            }
            
            var lines: [String] = []
            for entry in entries {
                let typeIndicator = entry.kind == .directory ? "/" : ""
                let sizeInfo: String
                if let size = entry.sizeBytes, entry.kind == .file {
                    sizeInfo = " (\(formatBytes(size)))"
                } else {
                    sizeInfo = ""
                }
                lines.append("\(entry.relativePath)\(typeIndicator)\(sizeInfo)")
            }
            
            let header = path.isEmpty ? "Contents of workspace:" : "Contents of '\(path)':"
            return .success("\(header)\n\(lines.joined(separator: "\n"))")
        } catch {
            return .failure(error.localizedDescription)
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes / (1024 * 1024)) MB"
    }
}

// MARK: - read_file Tool

struct ReadFileTool: Tool {
    let name = "read_file"
    let summary = "Read text content from a file. Supports line range selection."
    
    func execute(parameters: [String: Any], context: ToolContext) async -> ToolResult {
        guard let path = stringParam(parameters, "path"), !path.isEmpty else {
            return .failure("Missing required parameter: path")
        }
        
        let startLine = intParam(parameters, "start_line") ?? 1
        let maxLines = intParam(parameters, "max_lines")
        
        do {
            let contents = try await context.projectStore.readFile(
                at: path,
                startingAtLine: startLine,
                maxLines: maxLines
            )
            
            var header = "File: \(path)"
            if contents.totalLineCount > 0 {
                header += " (lines \(contents.startLine)-\(contents.endLine) of \(contents.totalLineCount))"
            }
            if contents.isTruncated {
                header += " [truncated]"
            }
            
            if contents.text.isEmpty {
                return .success("\(header)\n<empty file>")
            }
            
            return .success("\(header)\n```\n\(contents.text)\n```")
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

// MARK: - write_file Tool

struct WriteFileTool: Tool {
    let name = "write_file"
    let summary = "Create or overwrite a file with the given content."
    
    func execute(parameters: [String: Any], context: ToolContext) async -> ToolResult {
        guard let path = stringParam(parameters, "path"), !path.isEmpty else {
            return .failure("Missing required parameter: path")
        }
        guard let content = stringParam(parameters, "content") else {
            return .failure("Missing required parameter: content")
        }
        
        do {
            _ = try await context.projectStore.writeFile(content, to: path)
            let lineCount = content.components(separatedBy: "\n").count
            let byteCount = content.utf8.count
            return .success("Wrote \(path) (\(lineCount) lines, \(byteCount) bytes)")
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

// MARK: - search_code Tool

struct SearchCodeTool: Tool {
    let name = "search_code"
    let summary = "Search JavaScript files for a text pattern. Returns matching lines with context."
    
    func execute(parameters: [String: Any], context: ToolContext) async -> ToolResult {
        guard let query = stringParam(parameters, "query"), !query.isEmpty else {
            return .failure("Missing required parameter: query")
        }
        
        let limit = intParam(parameters, "limit") ?? 50
        
        do {
            let matches = try await context.projectStore.searchJavaScript(query: query, limit: limit)
            
            if matches.isEmpty {
                return .success("No matches found for '\(query)'")
            }
            
            var lines: [String] = ["Found \(matches.count) match(es) for '\(query)':"]
            
            var currentFile = ""
            for match in matches {
                if match.relativePath != currentFile {
                    currentFile = match.relativePath
                    lines.append("\n\(currentFile):")
                }
                lines.append("  \(match.lineNumber): \(match.lineText.trimmingCharacters(in: .whitespaces))")
            }
            
            if matches.count >= limit {
                lines.append("\n[Results truncated at \(limit) matches]")
            }
            
            return .success(lines.joined(separator: "\n"))
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

// MARK: - run_snippet Tool

struct RunSnippetToolImpl: Tool {
    let name = "run_snippet"
    let summary = "Execute inline JavaScript code and return the result."
    
    func execute(parameters: [String: Any], context: ToolContext) async -> ToolResult {
        guard let code = stringParam(parameters, "code"), !code.isEmpty else {
            return .failure("Missing required parameter: code")
        }
        
        let result = await context.runtime.runSnippet(code: code)
        return formatExecutionResult(result)
    }
}

// MARK: - run_file Tool

struct RunFileToolImpl: Tool {
    let name = "run_file"
    let summary = "Execute a JavaScript file from the workspace."
    
    func execute(parameters: [String: Any], context: ToolContext) async -> ToolResult {
        guard let path = stringParam(parameters, "path"), !path.isEmpty else {
            return .failure("Missing required parameter: path")
        }
        
        let result = await context.runtime.runFile(path: path)
        return formatExecutionResult(result)
    }
}

// MARK: - Execution Result Formatting

private nonisolated func formatExecutionResult(_ result: JSExecutionResult) -> ToolResult {
    let diagnostic = ExecutionDiagnostic(result: result)
    return diagnostic.toToolResult()
}

/// Structured diagnostic for execution results.
/// Provides categorized, actionable error information.
private nonisolated struct ExecutionDiagnostic: Sendable {
    nonisolated enum FailureKind: String, Sendable {
        case none = "success"
        case syntaxError = "syntax_error"
        case runtimeError = "runtime_error"
        case assertionFailure = "assertion_failure"
        case moduleNotFound = "module_not_found"
        case typeError = "type_error"
        case referenceError = "reference_error"
    }

    let result: JSExecutionResult
    let failureKind: FailureKind
    let primaryMessage: String?
    let location: String?

    nonisolated init(result: JSExecutionResult) {
        self.result = result
        (self.failureKind, self.primaryMessage, self.location) = Self.categorize(result)
    }

    private nonisolated static func categorize(_ result: JSExecutionResult) -> (FailureKind, String?, String?) {
        // Check assertion failures first (most specific)
        if !result.assertionFailures.isEmpty {
            let msg = result.assertionFailures.first
            return (.assertionFailure, msg, result.sourcePath)
        }

        // Check for errors
        guard let error = result.error else {
            return (.none, nil, nil)
        }

        let msg = error.message
        let location = formatLocation(error: error, sourcePath: result.sourcePath)

        // Categorize by error message patterns
        if msg.contains("SyntaxError") || msg.contains("Unexpected token") || msg.contains("Parse error") {
            return (.syntaxError, msg, location)
        }
        if msg.contains("Could not find") || msg.contains("module") && msg.contains("not found") {
            return (.moduleNotFound, msg, location)
        }
        if msg.contains("TypeError") || msg.contains("is not a function") || msg.contains("is not an object") {
            return (.typeError, msg, location)
        }
        if msg.contains("ReferenceError") || msg.contains("is not defined") || msg.contains("undefined is not") {
            return (.referenceError, msg, location)
        }

        return (.runtimeError, msg, location)
    }

    private nonisolated static func formatLocation(error: JSErrorSummary, sourcePath: String?) -> String? {
        var parts: [String] = []
        if let path = sourcePath {
            parts.append(path)
        }
        if let line = error.line {
            parts.append("line \(line)")
            if let col = error.column {
                parts.append("col \(col)")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ":")
    }

    nonisolated func toToolResult() -> ToolResult {
        var sections: [String] = []

        // Console output (always include if present)
        let consoleOutput = result.console
            .filter { $0.level != .error || result.error == nil } // Don't duplicate error messages
            .map { $0.message }
            .joined(separator: "\n")
        if !consoleOutput.isEmpty {
            sections.append(consoleOutput)
        }

        // Return value for successful execution
        if failureKind == .none {
            if let returnValue = result.returnValue {
                if !sections.isEmpty || !returnValue.hasPrefix("=>") {
                    sections.append("=> \(returnValue)")
                }
            }
            let output = sections.isEmpty ? "(no output)" : sections.joined(separator: "\n")
            return .success(output)
        }

        // Build failure diagnostic
        var errorSection: [String] = []

        // Primary error header with category
        let categoryLabel: String
        switch failureKind {
        case .syntaxError: categoryLabel = "SYNTAX ERROR"
        case .runtimeError: categoryLabel = "RUNTIME ERROR"
        case .assertionFailure: categoryLabel = "ASSERTION FAILED"
        case .moduleNotFound: categoryLabel = "MODULE NOT FOUND"
        case .typeError: categoryLabel = "TYPE ERROR"
        case .referenceError: categoryLabel = "REFERENCE ERROR"
        case .none: categoryLabel = "ERROR"
        }

        var header = "[\(categoryLabel)]"
        if let loc = location {
            header += " at \(loc)"
        }
        errorSection.append(header)

        // Error message
        if let msg = primaryMessage {
            errorSection.append(msg)
        }

        // Stack trace (trimmed for model consumption)
        if let stack = result.error?.stack, !stack.isEmpty {
            let stackLines = stack.components(separatedBy: "\n")
                .filter { !$0.isEmpty }
                .prefix(5) // Limit stack depth for token efficiency
            if !stackLines.isEmpty {
                errorSection.append("Stack:")
                errorSection.append(contentsOf: stackLines.map { "  \($0)" })
            }
        }

        // Additional assertion failures
        if result.assertionFailures.count > 1 {
            errorSection.append("Additional assertions failed:")
            for failure in result.assertionFailures.dropFirst() {
                errorSection.append("  • \(failure)")
            }
        }

        // Loaded modules (helpful for module errors)
        if failureKind == .moduleNotFound && !result.loadedModulePaths.isEmpty {
            errorSection.append("Loaded modules: \(result.loadedModulePaths.joined(separator: ", "))")
        }

        sections.append(errorSection.joined(separator: "\n"))

        return .failure(sections.joined(separator: "\n\n"))
    }
}
