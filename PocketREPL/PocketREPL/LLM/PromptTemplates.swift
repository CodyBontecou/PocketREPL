import Foundation

/// Templates for formatting prompts to the local coding model.
/// Optimized for code generation, fixing, and completion tasks.
nonisolated enum PromptTemplates: Sendable {
    
    // MARK: - Code Generation
    
    /// Format a prompt for generating new code.
    static func codeGeneration(
        instruction: String,
        context: String? = nil,
        filePath: String? = nil
    ) -> String {
        var parts: [String] = []
        
        // System context
        parts.append("""
            You are a JavaScript code generator. Write clean, working code that solves the given task.
            Output only the code, no explanations.
            Use CommonJS for modules: require('./path') and module.exports.
            """)
        
        // File context
        if let context = context, !context.isEmpty {
            parts.append("## Project Context\n\(context)")
        }
        
        // Target file
        if let filePath = filePath {
            parts.append("## Target File\n\(filePath)")
        }
        
        // Instruction
        parts.append("## Task\n\(instruction)")
        
        // Output marker
        parts.append("## Code")
        
        return parts.joined(separator: "\n\n")
    }
    
    // MARK: - Code Fixing
    
    /// Format a prompt for fixing broken code.
    static func codeFix(
        code: String,
        error: String,
        context: String? = nil,
        filePath: String? = nil
    ) -> String {
        var parts: [String] = []
        
        // System context
        parts.append("""
            You are a JavaScript debugger. Fix the code to resolve the error.
            Output only the corrected code, no explanations.
            Make minimal changes to fix the issue.
            """)
        
        // File context
        if let filePath = filePath {
            parts.append("## File: \(filePath)")
        }
        
        // Current code
        parts.append("## Broken Code\n```javascript\n\(code)\n```")
        
        // Error message
        parts.append("## Error\n\(error)")
        
        // Additional context
        if let context = context, !context.isEmpty {
            parts.append("## Context\n\(context)")
        }
        
        // Output marker
        parts.append("## Fixed Code")
        
        return parts.joined(separator: "\n\n")
    }
    
    // MARK: - Code Completion
    
    /// Format a prompt for completing partial code.
    static func codeCompletion(
        partialCode: String,
        cursorPosition: Int? = nil,
        context: String? = nil
    ) -> String {
        var parts: [String] = []
        
        parts.append("Complete the following JavaScript code. Output only the completion, not the full file.")
        
        if let context = context, !context.isEmpty {
            parts.append("## Context\n\(context)")
        }
        
        parts.append("## Code to Complete\n```javascript\n\(partialCode)\n```")
        
        parts.append("## Completion")
        
        return parts.joined(separator: "\n\n")
    }
    
    // MARK: - Code Rewrite
    
    /// Format a prompt for rewriting code with modifications.
    static func codeRewrite(
        code: String,
        instruction: String,
        filePath: String? = nil
    ) -> String {
        var parts: [String] = []
        
        parts.append("""
            Rewrite the following JavaScript code according to the instruction.
            Output only the rewritten code, no explanations.
            """)
        
        if let filePath = filePath {
            parts.append("## File: \(filePath)")
        }
        
        parts.append("## Original Code\n```javascript\n\(code)\n```")
        
        parts.append("## Instruction\n\(instruction)")
        
        parts.append("## Rewritten Code")
        
        return parts.joined(separator: "\n\n")
    }
    
    // MARK: - Agentic Workflow
    
    /// Format a prompt for the autonomous agent workflow.
    /// This template is used when the model needs to decide which tools to use.
    static func agentWorkflow(
        userMessage: String,
        projectContext: String?,
        availableTools: [ToolDescriptor],
        conversationHistory: [AgentMessage]?
    ) -> String {
        var parts: [String] = []
        
        // System instructions
        parts.append("""
            You are PocketREPL, an autonomous JavaScript coding assistant.
            You write, test, and fix code using the available tools.
            
            Respond with either:
            1. A tool call in this format: TOOL: tool_name {"param": "value"}
            2. A message to the user (no TOOL prefix)
            
            Always test code after writing it. Fix errors until the code works.
            Stop after 3 consecutive failures on the same error.
            """)
        
        // Available tools
        let toolList = availableTools.map { "- \($0.id): \($0.summary)" }.joined(separator: "\n")
        parts.append("## Available Tools\n\(toolList)")
        
        // Project context
        if let context = projectContext, !context.isEmpty {
            parts.append("## Project State\n\(context)")
        }
        
        // Conversation history (last few messages)
        if let history = conversationHistory, !history.isEmpty {
            let recentHistory = history.suffix(6).map { msg in
                let role = msg.role == .user ? "User" : "Assistant"
                return "\(role): \(msg.text.prefix(200))"
            }.joined(separator: "\n")
            parts.append("## Recent Messages\n\(recentHistory)")
        }
        
        // Current user message
        parts.append("## User Message\n\(userMessage)")
        
        parts.append("## Response")
        
        return parts.joined(separator: "\n\n")
    }
    
    // MARK: - Response Parsing
    
    /// Parse a tool call from model output.
    /// Returns (toolName, parameters) if a tool call is found.
    static func parseToolCall(_ output: String) -> (name: String, parameters: [String: Any])? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check for TOOL: prefix
        guard trimmed.hasPrefix("TOOL:") else { return nil }
        
        let afterPrefix = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        
        // Extract tool name and optional JSON parameters
        if let spaceIndex = afterPrefix.firstIndex(of: " ") {
            let toolName = String(afterPrefix[..<spaceIndex])
            let jsonPart = String(afterPrefix[spaceIndex...]).trimmingCharacters(in: .whitespaces)
            
            if let data = jsonPart.data(using: .utf8),
               let params = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return (toolName, params)
            }
            
            // Tool name with malformed or no params
            return (toolName, [:])
        }
        
        // Just tool name, no params
        return (afterPrefix, [:])
    }
    
    /// Extract code from a model response.
    /// Handles code blocks and raw code.
    static func extractCode(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check for markdown code block
        if let startRange = trimmed.range(of: "```javascript\n"),
           let endRange = trimmed.range(of: "\n```", range: startRange.upperBound..<trimmed.endIndex) {
            return String(trimmed[startRange.upperBound..<endRange.lowerBound])
        }
        
        // Check for generic code block
        if let startRange = trimmed.range(of: "```\n"),
           let endRange = trimmed.range(of: "\n```", range: startRange.upperBound..<trimmed.endIndex) {
            return String(trimmed[startRange.upperBound..<endRange.lowerBound])
        }
        
        // Check for inline code block (```code```)
        if trimmed.hasPrefix("```") && trimmed.hasSuffix("```") {
            var code = String(trimmed.dropFirst(3).dropLast(3))
            // Remove optional language identifier
            if code.hasPrefix("javascript\n") {
                code = String(code.dropFirst(11))
            } else if code.hasPrefix("js\n") {
                code = String(code.dropFirst(3))
            }
            return code.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // Return as-is if no code block markers
        return trimmed
    }
}

// MARK: - Prompt Builder

/// Fluent builder for constructing prompts with options.
struct PromptBuilder {
    private var instruction: String = ""
    private var code: String?
    private var error: String?
    private var filePath: String?
    private var context: String?
    private var maxLines: Int = 100
    
    init() {}
    
    func instruction(_ text: String) -> PromptBuilder {
        var builder = self
        builder.instruction = text
        return builder
    }
    
    func code(_ text: String) -> PromptBuilder {
        var builder = self
        builder.code = text
        return builder
    }
    
    func error(_ text: String) -> PromptBuilder {
        var builder = self
        builder.error = text
        return builder
    }
    
    func filePath(_ path: String) -> PromptBuilder {
        var builder = self
        builder.filePath = path
        return builder
    }
    
    func context(_ text: String) -> PromptBuilder {
        var builder = self
        builder.context = text
        return builder
    }
    
    func maxLines(_ count: Int) -> PromptBuilder {
        var builder = self
        builder.maxLines = count
        return builder
    }
    
    func buildGeneration() -> String {
        PromptTemplates.codeGeneration(
            instruction: instruction,
            context: context,
            filePath: filePath
        )
    }
    
    func buildFix() -> String {
        PromptTemplates.codeFix(
            code: code ?? "",
            error: error ?? "Unknown error",
            context: context,
            filePath: filePath
        )
    }
    
    func buildCompletion() -> String {
        PromptTemplates.codeCompletion(
            partialCode: code ?? "",
            context: context
        )
    }
    
    func buildRewrite() -> String {
        PromptTemplates.codeRewrite(
            code: code ?? "",
            instruction: instruction,
            filePath: filePath
        )
    }
}
