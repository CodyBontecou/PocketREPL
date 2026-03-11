import Foundation

nonisolated enum AgentMessageRole: String, Codable, Hashable, Sendable {
    case system
    case user
    case assistant
    case toolCall
    case toolResult
}

nonisolated struct AgentMessage: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let role: AgentMessageRole
    let text: String
    let createdAt: Date
    
    // Tool-specific metadata
    let toolName: String?
    let toolParameters: String?
    let toolStatus: ToolTraceStatus?

    init(id: UUID = UUID(), role: AgentMessageRole, text: String, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.toolName = nil
        self.toolParameters = nil
        self.toolStatus = nil
    }
    
    init(
        id: UUID = UUID(),
        role: AgentMessageRole,
        text: String,
        toolName: String,
        toolParameters: String? = nil,
        toolStatus: ToolTraceStatus = .pending,
        createdAt: Date = .now
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.toolName = toolName
        self.toolParameters = toolParameters
        self.toolStatus = toolStatus
    }
}

nonisolated enum ToolTraceEventKind: String, Codable, Hashable, Sendable {
    case call
    case result
    case note
}

nonisolated enum ToolTraceStatus: String, Codable, Hashable, Sendable {
    case pending
    case succeeded
    case failed
    case skipped
}

nonisolated struct ToolTraceEvent: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let kind: ToolTraceEventKind
    let toolName: String
    let summary: String
    let status: ToolTraceStatus
    let createdAt: Date

    init(
        id: UUID = UUID(),
        kind: ToolTraceEventKind,
        toolName: String,
        summary: String,
        status: ToolTraceStatus,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.toolName = toolName
        self.summary = summary
        self.status = status
        self.createdAt = createdAt
    }
}

nonisolated enum JSExecutionKind: String, Codable, Hashable, Sendable {
    case snippet
    case file
}

nonisolated enum JSConsoleLevel: String, Codable, Hashable, Sendable {
    case log
    case warn
    case error
}

nonisolated struct JSConsoleEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let level: JSConsoleLevel
    let message: String

    init(id: UUID = UUID(), level: JSConsoleLevel, message: String) {
        self.id = id
        self.level = level
        self.message = message
    }
}

nonisolated struct JSErrorSummary: Codable, Hashable, Sendable {
    let message: String
    let line: Int?
    let column: Int?
    let stack: String?
}

nonisolated struct JSExecutionResult: Codable, Hashable, Sendable {
    let kind: JSExecutionKind
    let sourcePath: String?
    let returnValue: String?
    let output: String
    let console: [JSConsoleEntry]
    let assertionFailures: [String]
    let loadedModulePaths: [String]
    let error: JSErrorSummary?
    let startedAt: Date
    let finishedAt: Date

    var hadError: Bool {
        error != nil || !assertionFailures.isEmpty
    }

    static func notImplemented(kind: JSExecutionKind, sourcePath: String? = nil, reason: String) -> JSExecutionResult {
        JSExecutionResult(
            kind: kind,
            sourcePath: sourcePath,
            returnValue: nil,
            output: reason,
            console: [],
            assertionFailures: [],
            loadedModulePaths: [],
            error: nil,
            startedAt: .now,
            finishedAt: .now
        )
    }

    static func failed(kind: JSExecutionKind, sourcePath: String? = nil, message: String) -> JSExecutionResult {
        JSExecutionResult(
            kind: kind,
            sourcePath: sourcePath,
            returnValue: nil,
            output: "",
            console: [],
            assertionFailures: [],
            loadedModulePaths: [],
            error: JSErrorSummary(message: message, line: nil, column: nil, stack: nil),
            startedAt: .now,
            finishedAt: .now
        )
    }
}

nonisolated struct ContextSnapshot: Hashable, Sendable {
    let recentActivity: [String]
    let recentFiles: [String]
}
