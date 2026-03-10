import Foundation

// MARK: - Project Manifest

/// Compact representation of the project state for context injection.
/// Designed to be small enough for repeated prompt assembly.
nonisolated struct ProjectManifest: Codable, Sendable {
    /// Summary of all files in the workspace.
    let files: [FileEntry]

    /// Most recently modified files (paths only).
    let recentlyModified: [String]

    /// Last execution result summary (if any).
    let lastExecution: ExecutionSummary?

    /// Timestamp when this manifest was generated.
    let generatedAt: Date

    /// Estimated token count for this manifest when serialized.
    var estimatedTokens: Int {
        // Rough estimate: ~4 chars per token
        let fileTokens = files.reduce(0) { $0 + $1.estimatedTokens }
        let recentTokens = recentlyModified.count * 10
        let execTokens = lastExecution?.estimatedTokens ?? 0
        return fileTokens + recentTokens + execTokens + 20 // overhead
    }

    /// Render as compact text for model context.
    func render() -> String {
        var lines: [String] = ["## Project State"]

        // File tree
        if !files.isEmpty {
            lines.append("\nFiles:")
            for file in files {
                let sizeStr = file.isDirectory ? "/" : " (\(formatBytes(file.sizeBytes)))"
                lines.append("  \(file.path)\(sizeStr)")
            }
        } else {
            lines.append("\nNo files in workspace.")
        }

        // Recent modifications
        if !recentlyModified.isEmpty {
            lines.append("\nRecently modified: \(recentlyModified.joined(separator: ", "))")
        }

        // Last execution
        if let exec = lastExecution {
            lines.append("\nLast execution (\(exec.kind.rawValue)):")
            if let path = exec.sourcePath {
                lines.append("  File: \(path)")
            }
            lines.append("  Status: \(exec.succeeded ? "✓ Success" : "✗ Failed")")
            if let error = exec.errorSummary {
                lines.append("  Error: \(error)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024)KB" }
        return "\(bytes / (1024 * 1024))MB"
    }
}

/// Entry for a single file in the manifest.
nonisolated struct FileEntry: Codable, Sendable {
    let path: String
    let isDirectory: Bool
    let sizeBytes: Int64
    let lineCount: Int?

    var estimatedTokens: Int {
        path.count / 4 + 5
    }
}

/// Summary of the last execution for context.
nonisolated struct ExecutionSummary: Codable, Sendable {
    let kind: ExecutionKind
    let sourcePath: String?
    let succeeded: Bool
    let errorSummary: String?
    let timestamp: Date

    nonisolated enum ExecutionKind: String, Codable, Sendable {
        case snippet
        case file
    }

    var estimatedTokens: Int {
        var tokens = 15
        if let path = sourcePath { tokens += path.count / 4 }
        if let error = errorSummary { tokens += error.count / 4 }
        return tokens
    }
}

// MARK: - Activity Record

/// Structured record of an activity event.
nonisolated struct ActivityRecord: Codable, Sendable, Identifiable {
    let id: UUID
    let kind: ActivityKind
    let summary: String
    let timestamp: Date

    nonisolated enum ActivityKind: String, Codable, Sendable {
        case prompt
        case toolCall
        case toolResult
        case execution
        case fileWrite
        case fileRead
        case sessionControl
    }

    init(kind: ActivityKind, summary: String) {
        self.id = UUID()
        self.kind = kind
        self.summary = summary
        self.timestamp = .now
    }
}

// MARK: - Context Budget

/// Token budget tracking for context assembly.
nonisolated struct ContextBudget: Sendable {
    let maxTokens: Int
    private(set) var usedTokens: Int = 0

    init(maxTokens: Int = 4000) {
        self.maxTokens = maxTokens
    }

    var remainingTokens: Int { maxTokens - usedTokens }
    var isFull: Bool { usedTokens >= maxTokens }

    mutating func allocate(_ tokens: Int) -> Bool {
        guard usedTokens + tokens <= maxTokens else { return false }
        usedTokens += tokens
        return true
    }

    /// Estimate tokens for a string (rough: ~4 chars per token).
    static func estimateTokens(for text: String) -> Int {
        max(1, text.count / 4)
    }
}

// MARK: - Context Manager

actor ContextManager {
    // Configuration
    private let maxRecentActivity = 50
    private let maxRecentFiles = 20
    private let maxManifestFiles = 100
    private let defaultTokenBudget = 4000

    // State
    private var activities: [ActivityRecord] = []
    private var recentFilePaths: [String] = []
    private var lastExecutionSummary: ExecutionSummary?
    private var cachedManifest: ProjectManifest?
    private var manifestCacheTime: Date?

    private let projectStore: ProjectStore

    init(projectStore: ProjectStore) {
        self.projectStore = projectStore
    }

    // MARK: - Recording

    func recordActivity(_ kind: ActivityRecord.ActivityKind, summary: String) {
        guard !summary.isEmpty else { return }
        let record = ActivityRecord(kind: kind, summary: summary)
        activities.append(record)
        if activities.count > maxRecentActivity {
            activities.removeFirst(activities.count - maxRecentActivity)
        }
    }

    /// Convenience for legacy string-based recording.
    func recordActivity(_ summary: String) {
        // Infer kind from summary prefix
        let kind: ActivityRecord.ActivityKind
        if summary.hasPrefix("Tool ") {
            kind = .toolCall
        } else if summary.hasPrefix("Prompt:") {
            kind = .prompt
        } else if summary.hasPrefix("Runtime") {
            kind = .sessionControl
        } else {
            kind = .toolCall
        }
        recordActivity(kind, summary: summary)
    }

    func recordFileAccess(_ relativePath: String, isWrite: Bool = false) {
        guard !relativePath.isEmpty else { return }

        // Move to end (most recent)
        recentFilePaths.removeAll { $0 == relativePath }
        recentFilePaths.append(relativePath)

        if recentFilePaths.count > maxRecentFiles {
            recentFilePaths.removeFirst(recentFilePaths.count - maxRecentFiles)
        }

        // Invalidate manifest cache on writes
        if isWrite {
            cachedManifest = nil
        }

        recordActivity(isWrite ? .fileWrite : .fileRead, summary: relativePath)
    }

    func recordExecution(_ result: JSExecutionResult) {
        lastExecutionSummary = ExecutionSummary(
            kind: result.kind == .snippet ? .snippet : .file,
            sourcePath: result.sourcePath,
            succeeded: !result.hadError,
            errorSummary: result.error?.message,
            timestamp: .now
        )

        let status = result.hadError ? "failed" : "succeeded"
        let path = result.sourcePath ?? "snippet"
        recordActivity(.execution, summary: "\(path) \(status)")
    }

    // MARK: - Manifest Generation

    /// Generate a fresh project manifest.
    func generateManifest() async -> ProjectManifest {
        // Check cache (valid for 5 seconds)
        if let cached = cachedManifest,
           let cacheTime = manifestCacheTime,
           Date.now.timeIntervalSince(cacheTime) < 5.0 {
            return cached
        }

        // Fetch file list
        var fileEntries: [FileEntry] = []
        do {
            let files = try await projectStore.listFiles(recursive: true)
            fileEntries = files.prefix(maxManifestFiles).map { entry in
                FileEntry(
                    path: entry.relativePath,
                    isDirectory: entry.kind == .directory,
                    sizeBytes: entry.sizeBytes ?? 0,
                    lineCount: nil // Could add line counting for small files
                )
            }
        } catch {
            // Empty manifest on error
        }

        let manifest = ProjectManifest(
            files: fileEntries,
            recentlyModified: Array(recentFilePaths.suffix(5)),
            lastExecution: lastExecutionSummary,
            generatedAt: .now
        )

        cachedManifest = manifest
        manifestCacheTime = .now
        return manifest
    }

    // MARK: - Context Assembly

    /// Assemble context string within a token budget.
    func assembleContext(budget: Int? = nil) async -> String {
        var contextBudget = ContextBudget(maxTokens: budget ?? defaultTokenBudget)
        var sections: [String] = []

        // 1. Project manifest (high priority)
        let manifest = await generateManifest()
        let manifestText = manifest.render()
        let manifestTokens = ContextBudget.estimateTokens(for: manifestText)
        if contextBudget.allocate(manifestTokens) {
            sections.append(manifestText)
        }

        // 2. Recent activity (medium priority, truncate if needed)
        if !activities.isEmpty {
            let recentActivities = activities.suffix(10)
            var activityLines = ["## Recent Activity"]
            for activity in recentActivities {
                let line = "- [\(activity.kind.rawValue)] \(activity.summary)"
                let tokens = ContextBudget.estimateTokens(for: line)
                if contextBudget.allocate(tokens) {
                    activityLines.append(line)
                } else {
                    activityLines.append("- ... (truncated)")
                    break
                }
            }
            if activityLines.count > 1 {
                sections.append(activityLines.joined(separator: "\n"))
            }
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Snapshots

    func snapshot() -> ContextSnapshot {
        ContextSnapshot(
            recentActivity: activities.map { "[\($0.kind.rawValue)] \($0.summary)" },
            recentFiles: recentFilePaths
        )
    }

    func reset() {
        activities.removeAll()
        recentFilePaths.removeAll()
        lastExecutionSummary = nil
        cachedManifest = nil
        manifestCacheTime = nil
    }
}
