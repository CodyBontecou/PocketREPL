import Foundation

// MARK: - Tool Configuration

/// Represents the configuration for a single tool
struct ToolConfiguration: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let summary: String
    let icon: String
    var isEnabled: Bool
    
    static func defaultTools() -> [ToolConfiguration] {
        [
            ToolConfiguration(
                id: "list_files",
                name: "List Files",
                summary: "List files and directories in the workspace",
                icon: "folder",
                isEnabled: true
            ),
            ToolConfiguration(
                id: "read_file",
                name: "Read File",
                summary: "Read text content from a file",
                icon: "doc.text",
                isEnabled: true
            ),
            ToolConfiguration(
                id: "write_file",
                name: "Write File",
                summary: "Create or overwrite a file with content",
                icon: "square.and.pencil",
                isEnabled: true
            ),
            ToolConfiguration(
                id: "search_code",
                name: "Search Code",
                summary: "Search JavaScript files for a text pattern",
                icon: "magnifyingglass",
                isEnabled: true
            ),
            ToolConfiguration(
                id: "run_snippet",
                name: "Run Snippet",
                summary: "Execute inline JavaScript code",
                icon: "play.fill",
                isEnabled: true
            ),
            ToolConfiguration(
                id: "run_file",
                name: "Run File",
                summary: "Execute a JavaScript file from the workspace",
                icon: "play.rectangle.fill",
                isEnabled: true
            )
        ]
    }
}

// MARK: - Context Settings Manager

/// Manages customizable context settings including system prompt and tool toggles
@MainActor
@Observable
final class ContextSettingsManager {
    static let shared = ContextSettingsManager()
    
    // MARK: - Keys
    
    private enum Keys {
        static let systemPrompt = "contextSettings.systemPrompt"
        static let toolConfigurations = "contextSettings.toolConfigurations"
        static let useCustomSystemPrompt = "contextSettings.useCustomSystemPrompt"
    }
    
    // MARK: - Default System Prompt
    
    static let defaultSystemPrompt = """
        You are PocketREPL, a JavaScript coding assistant. Write, run, and fix code autonomously.
        
        Workflow: inspect files → write code → run → fix errors if needed.
        Use console.log() for output. Use assert() for tests.
        After 3 failed fixes, ask for guidance.
        """
    
    // MARK: - Properties
    
    /// Whether to use the custom system prompt instead of the default
    var useCustomSystemPrompt: Bool {
        didSet {
            UserDefaults.standard.set(useCustomSystemPrompt, forKey: Keys.useCustomSystemPrompt)
        }
    }
    
    /// The custom system prompt (if customization is enabled)
    var customSystemPrompt: String {
        didSet {
            UserDefaults.standard.set(customSystemPrompt, forKey: Keys.systemPrompt)
        }
    }
    
    /// The effective system prompt to use
    var effectiveSystemPrompt: String {
        useCustomSystemPrompt ? customSystemPrompt : Self.defaultSystemPrompt
    }
    
    /// Tool configurations with enable/disable state
    var toolConfigurations: [ToolConfiguration] {
        didSet {
            saveToolConfigurations()
        }
    }
    
    /// Set of enabled tool IDs for quick lookup
    var enabledToolIds: Set<String> {
        Set(toolConfigurations.filter(\.isEnabled).map(\.id))
    }
    
    /// Count of enabled tools
    var enabledToolCount: Int {
        toolConfigurations.filter(\.isEnabled).count
    }
    
    /// Total number of tools
    var totalToolCount: Int {
        toolConfigurations.count
    }
    
    /// Estimated tokens for the current configuration
    var estimatedBaseTokens: Int {
        // System prompt tokens
        let promptTokens = max(1, effectiveSystemPrompt.count / 4)
        
        // Tool schema tokens (only count enabled tools)
        // Each tool is roughly 50 tokens for its @Generable schema
        let toolTokens = enabledToolCount * 50
        
        // Project context baseline
        let contextTokens = 125
        
        return promptTokens + toolTokens + contextTokens
    }
    
    // MARK: - Initialization
    
    private init() {
        // Load use custom prompt setting
        self.useCustomSystemPrompt = UserDefaults.standard.bool(forKey: Keys.useCustomSystemPrompt)
        
        // Load custom system prompt
        self.customSystemPrompt = UserDefaults.standard.string(forKey: Keys.systemPrompt) ?? Self.defaultSystemPrompt
        
        // Load tool configurations
        self.toolConfigurations = Self.loadToolConfigurations()
    }
    
    // MARK: - Tool Configuration Persistence
    
    private static func loadToolConfigurations() -> [ToolConfiguration] {
        guard let data = UserDefaults.standard.data(forKey: Keys.toolConfigurations),
              let configs = try? JSONDecoder().decode([ToolConfiguration].self, from: data) else {
            return ToolConfiguration.defaultTools()
        }
        
        // Merge with defaults to pick up any new tools
        let defaults = ToolConfiguration.defaultTools()
        var merged: [ToolConfiguration] = []
        
        for defaultTool in defaults {
            if let saved = configs.first(where: { $0.id == defaultTool.id }) {
                // Use saved enabled state, but update name/summary in case they changed
                merged.append(ToolConfiguration(
                    id: saved.id,
                    name: defaultTool.name,
                    summary: defaultTool.summary,
                    icon: defaultTool.icon,
                    isEnabled: saved.isEnabled
                ))
            } else {
                merged.append(defaultTool)
            }
        }
        
        return merged
    }
    
    private func saveToolConfigurations() {
        if let data = try? JSONEncoder().encode(toolConfigurations) {
            UserDefaults.standard.set(data, forKey: Keys.toolConfigurations)
        }
    }
    
    // MARK: - Actions
    
    /// Toggle a specific tool's enabled state
    func toggleTool(_ id: String) {
        if let index = toolConfigurations.firstIndex(where: { $0.id == id }) {
            toolConfigurations[index].isEnabled.toggle()
        }
    }
    
    /// Enable all tools
    func enableAllTools() {
        for index in toolConfigurations.indices {
            toolConfigurations[index].isEnabled = true
        }
    }
    
    /// Disable all tools
    func disableAllTools() {
        for index in toolConfigurations.indices {
            toolConfigurations[index].isEnabled = false
        }
    }
    
    /// Reset system prompt to default
    func resetSystemPrompt() {
        customSystemPrompt = Self.defaultSystemPrompt
        useCustomSystemPrompt = false
    }
    
    /// Reset all settings to defaults
    func resetAll() {
        resetSystemPrompt()
        toolConfigurations = ToolConfiguration.defaultTools()
    }
    
    /// Check if a tool is enabled
    func isToolEnabled(_ id: String) -> Bool {
        enabledToolIds.contains(id)
    }
}
