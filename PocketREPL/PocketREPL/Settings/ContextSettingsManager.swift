import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Foundation Models Availability

enum FoundationModelsAvailabilityDetail: Equatable {
    case available
    case unavailableDeviceNotEligible
    case unavailableAppleIntelligenceDisabled
    case unavailableModelNotReady
    case unavailableOther
    case unavailableUnsupportedOS
}

// MARK: - Model Routing Mode

/// The user's preference for which model to use for agent operations.
enum ModelRoutingMode: String, Codable, CaseIterable, Identifiable {
    /// Use only Apple Intelligence (Foundation Models).
    /// Shows error if unavailable on device.
    case foundationModelOnly = "foundation"

    /// Use only local llama.cpp models (Qwen, CodeGemma, etc.).
    case localModelOnly = "local"

    /// User assigns each tool to either Foundation Models or Local Model.
    case hybrid = "hybrid"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .foundationModelOnly:
            return String(localized: "Apple Intelligence")
        case .localModelOnly:
            return String(localized: "Local Model")
        case .hybrid:
            return String(localized: "Hybrid")
        }
    }

    var icon: String {
        switch self {
        case .foundationModelOnly:
            return "apple.intelligence"
        case .localModelOnly:
            return "cpu"
        case .hybrid:
            return "arrow.triangle.branch"
        }
    }

    var description: String {
        switch self {
        case .foundationModelOnly:
            return String(localized: "Use Apple Intelligence for all AI operations. Requires iOS 26+ and eligible device.")
        case .localModelOnly:
            return String(localized: "Use downloaded local models for all AI operations. Works offline.")
        case .hybrid:
            return String(localized: "Assign each tool to either Apple Intelligence or local model.")
        }
    }
}

// MARK: - Model Assignment

/// Which model should handle a specific tool in hybrid mode.
enum ModelAssignment: String, Codable, CaseIterable, Identifiable {
    case foundationModel = "foundation"
    case localModel = "local"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .foundationModel:
            return "\u{F8FF}" // Apple logo
        case .localModel:
            return String(localized: "Local")
        }
    }
}

// MARK: - Tool Configuration

/// Represents the configuration for a single tool
struct ToolConfiguration: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let summary: String
    let icon: String
    var isEnabled: Bool
    /// Which model handles this tool in hybrid mode.
    var modelAssignment: ModelAssignment

    static func defaultTools() -> [ToolConfiguration] {
        [
            ToolConfiguration(
                id: "list_files",
                name: "List Files",
                summary: "List files and directories in the workspace",
                icon: "folder",
                isEnabled: true,
                modelAssignment: .foundationModel
            ),
            ToolConfiguration(
                id: "read_file",
                name: "Read File",
                summary: "Read text content from a file",
                icon: "doc.text",
                isEnabled: true,
                modelAssignment: .foundationModel
            ),
            ToolConfiguration(
                id: "write_file",
                name: "Write File",
                summary: "Create or overwrite a file with content",
                icon: "square.and.pencil",
                isEnabled: true,
                modelAssignment: .foundationModel
            ),
            ToolConfiguration(
                id: "search_code",
                name: "Search Code",
                summary: "Search JavaScript files for a text pattern",
                icon: "magnifyingglass",
                isEnabled: true,
                modelAssignment: .foundationModel
            ),
            ToolConfiguration(
                id: "run_snippet",
                name: "Run Snippet",
                summary: "Execute inline JavaScript code",
                icon: "play.fill",
                isEnabled: true,
                modelAssignment: .foundationModel
            ),
            ToolConfiguration(
                id: "run_file",
                name: "Run File",
                summary: "Execute a JavaScript file from the workspace",
                icon: "play.rectangle.fill",
                isEnabled: true,
                modelAssignment: .foundationModel
            ),
            ToolConfiguration(
                id: "generate_code",
                name: "Generate Code",
                summary: "Generate JavaScript code using AI",
                icon: "wand.and.stars",
                isEnabled: true,
                modelAssignment: .localModel
            ),
            ToolConfiguration(
                id: "fix_code",
                name: "Fix Code",
                summary: "Fix broken code using error context",
                icon: "wrench.adjustable",
                isEnabled: true,
                modelAssignment: .localModel
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
        static let modelRoutingMode = "contextSettings.modelRoutingMode"
        static let advancedOfflineModeEnabled = "contextSettings.advancedOfflineModeEnabled"
    }
    
    // MARK: - Default System Prompt
    
    static let defaultSystemPrompt = """
        You are PocketREPL. Write and run code autonomously.
        
        Workflow: write code → run → fix errors if needed. Ask for guidance after 3 failures.
        Keep responses brief. Read only needed file sections.
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

    /// The user's selected model routing mode
    var modelRoutingMode: ModelRoutingMode {
        didSet {
            UserDefaults.standard.set(modelRoutingMode.rawValue, forKey: Keys.modelRoutingMode)
        }
    }

    /// Whether local model downloads are explicitly enabled as an advanced mode.
    ///
    /// On Apple Intelligence-capable devices, this defaults to false so users are
    /// guided toward Foundation Models first.
    var advancedOfflineModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(advancedOfflineModeEnabled, forKey: Keys.advancedOfflineModeEnabled)

            // When advanced mode is off on Apple Intelligence-capable devices,
            // keep routing on Foundation Models to avoid accidental local fallback.
            if shouldGateLocalModelDownloads, modelRoutingMode != .foundationModelOnly {
                modelRoutingMode = .foundationModelOnly
            }
        }
    }

    /// Detailed Foundation Models availability for nuanced UI decisions.
    var foundationModelsAvailabilityDetail: FoundationModelsAvailabilityDetail {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailableDeviceNotEligible
                case .appleIntelligenceNotEnabled:
                    return .unavailableAppleIntelligenceDisabled
                case .modelNotReady:
                    return .unavailableModelNotReady
                @unknown default:
                    return .unavailableOther
                }
            @unknown default:
                return .unavailableOther
            }
        }
        #endif
        return .unavailableUnsupportedOS
    }

    /// Check if Foundation Models is available on this device
    var isFoundationModelsAvailable: Bool {
        foundationModelsAvailabilityDetail == .available
    }

    /// Whether this device is capable of Apple Intelligence in principle.
    ///
    /// True for devices where Foundation Models is available, disabled, or still
    /// preparing. False for unsupported OS / ineligible hardware.
    var isAppleIntelligenceCapableDevice: Bool {
        switch foundationModelsAvailabilityDetail {
        case .available, .unavailableAppleIntelligenceDisabled, .unavailableModelNotReady, .unavailableOther:
            return true
        case .unavailableDeviceNotEligible, .unavailableUnsupportedOS:
            return false
        }
    }

    /// True when local model downloads should remain behind explicit advanced-mode opt-in.
    var shouldGateLocalModelDownloads: Bool {
        isAppleIntelligenceCapableDevice && !advancedOfflineModeEnabled
    }

    /// Human-readable reason why Foundation Models is unavailable
    var foundationModelsUnavailabilityReason: String? {
        switch foundationModelsAvailabilityDetail {
        case .available:
            return nil
        case .unavailableDeviceNotEligible:
            return String(localized: "This device doesn't support Apple Intelligence")
        case .unavailableAppleIntelligenceDisabled:
            return String(localized: "Apple Intelligence is not enabled. Enable it in Settings > Apple Intelligence & Siri")
        case .unavailableModelNotReady:
            return String(localized: "Apple Intelligence is still downloading. Please wait.")
        case .unavailableOther:
            return String(localized: "Apple Intelligence is unavailable")
        case .unavailableUnsupportedOS:
            return String(localized: "Requires iOS 26 or later")
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

        // Load model routing mode (default to hybrid for existing behavior)
        if let savedMode = UserDefaults.standard.string(forKey: Keys.modelRoutingMode),
           let mode = ModelRoutingMode(rawValue: savedMode) {
            self.modelRoutingMode = mode
        } else {
            self.modelRoutingMode = .hybrid
        }

        // Local downloads are an explicit advanced mode on Apple Intelligence-capable devices.
        self.advancedOfflineModeEnabled = UserDefaults.standard.bool(forKey: Keys.advancedOfflineModeEnabled)

        if shouldGateLocalModelDownloads, modelRoutingMode != .foundationModelOnly {
            modelRoutingMode = .foundationModelOnly
        }
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
                // Use saved enabled/assignment state, but update name/summary in case they changed
                merged.append(ToolConfiguration(
                    id: saved.id,
                    name: defaultTool.name,
                    summary: defaultTool.summary,
                    icon: defaultTool.icon,
                    isEnabled: saved.isEnabled,
                    modelAssignment: saved.modelAssignment
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
        modelRoutingMode = .hybrid
        advancedOfflineModeEnabled = false
    }
    
    /// Check if a tool is enabled
    func isToolEnabled(_ id: String) -> Bool {
        enabledToolIds.contains(id)
    }

    // MARK: - Model Assignment

    /// Get the model assignment for a specific tool
    func modelAssignment(for toolId: String) -> ModelAssignment {
        toolConfigurations.first(where: { $0.id == toolId })?.modelAssignment ?? .foundationModel
    }

    /// Update model assignment for a tool (hybrid mode)
    func setModelAssignment(_ assignment: ModelAssignment, for toolId: String) {
        if let index = toolConfigurations.firstIndex(where: { $0.id == toolId }) {
            toolConfigurations[index].modelAssignment = assignment
        }
    }
}
