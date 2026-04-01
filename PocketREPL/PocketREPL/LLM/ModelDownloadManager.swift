import Foundation
import CryptoKit

// MARK: - Model Registry

/// A downloadable model from a remote source.
struct ModelRegistryEntry: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let sizeBytes: Int64
    let downloadURL: URL
    let sha256: String?
    let quantization: String
    let parameterCount: String
    let recommendedContextSize: Int
    let family: ModelFamily
    /// Whether this is a user-added custom model
    var isCustom: Bool = false
    
    enum ModelFamily: String, Codable, Sendable {
        case qwen25Coder = "Qwen 2.5 Coder"
        case qwen3 = "Qwen 3"
        case qwen35 = "Qwen 3.5"
        case gemma3 = "Gemma 3"
        case gemma3n = "Gemma 3n"
        case codegemma = "CodeGemma"
        case starcoder = "StarCoder"
        case deepseek = "DeepSeek"
        case deepseekR1 = "DeepSeek R1"
        case phi = "Phi"
        case llama = "Llama"
        case smolLM = "SmolLM"
        /// Flash-optimised models with ReLU/ReLU²/SqReLU activation sparsity.
        /// These are the models from Apple's "LLM in a Flash" paper experiments.
        case flashInference = "Flash Inference"
        case other = "Other"
        
        // Legacy support - map old "qwen" to qwen25Coder
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            switch rawValue {
            case "Qwen", "Qwen 2.5 Coder": self = .qwen25Coder
            case "Qwen 3": self = .qwen3
            case "Qwen 3.5": self = .qwen35
            case "Gemma 3": self = .gemma3
            case "Gemma 3n": self = .gemma3n
            case "CodeGemma": self = .codegemma
            case "StarCoder": self = .starcoder
            case "DeepSeek": self = .deepseek
            case "DeepSeek R1": self = .deepseekR1
            case "Phi": self = .phi
            case "Llama": self = .llama
            case "SmolLM": self = .smolLM
            case "Flash Inference": self = .flashInference
            default: self = .other
            }
        }
        
        /// Display name for the model family
        var displayName: String { rawValue }
        
        /// Short description for each family
        var familyDescription: String {
            switch self {
            case .qwen25Coder: return "Alibaba's code generation models"
            case .qwen3: return "Next-gen Qwen with improved reasoning"
            case .qwen35: return "Latest Qwen with vision capabilities"
            case .gemma3: return "Google's latest compact models"
            case .gemma3n: return "Google's efficient on-device models"
            case .codegemma: return "Google's code-focused Gemma"
            case .starcoder: return "BigCode/HuggingFace code models"
            case .deepseek: return "DeepSeek AI code specialists"
            case .deepseekR1: return "DeepSeek R1 reasoning distillations"
            case .phi: return "Microsoft's compact powerhouse models"
            case .llama: return "Meta's open-weight mobile models"
            case .smolLM: return "HuggingFace's purpose-built on-device models"
            case .flashInference: return "ReLU-sparse models for Flash inference — run models larger than your RAM"
            case .other: return "Custom and other models"
            }
        }

        /// Whether this family benefits from Flash inference conversion.
        var isFlashCompatible: Bool { self == .flashInference }
        
        /// Sort order for displaying families
        var sortOrder: Int {
            switch self {
            case .flashInference: return 0  // Show flash models first — they're the headline feature
            case .llama: return 1
            case .phi: return 2
            case .qwen25Coder: return 3
            case .qwen3: return 4
            case .qwen35: return 5
            case .gemma3: return 6
            case .gemma3n: return 7
            case .deepseek: return 8
            case .deepseekR1: return 9
            case .smolLM: return 10
            case .codegemma: return 11
            case .starcoder: return 12
            case .other: return 99
            }
        }

        /// The company / organisation behind this model family.
        var company: String {
            switch self {
            case .flashInference:   return "Meta"
            case .llama:            return "Meta"
            case .qwen25Coder:      return "Alibaba"
            case .qwen3:            return "Alibaba"
            case .qwen35:           return "Alibaba"
            case .gemma3:           return "Google"
            case .gemma3n:          return "Google"
            case .codegemma:        return "Google"
            case .deepseek:         return "DeepSeek"
            case .deepseekR1:       return "DeepSeek"
            case .phi:              return "Microsoft"
            case .smolLM:           return "HuggingFace"
            case .starcoder:        return "BigCode"
            case .other:            return "Other"
            }
        }

        /// Approximate year the family was first released (used for date sorting).
        var releaseYear: Int {
            switch self {
            case .flashInference:   return 2022  // Meta OPT (May 2022)
            case .starcoder:        return 2023  // BigCode StarCoder (May 2023)
            case .deepseek:         return 2023  // DeepSeek Coder (Oct 2023)
            case .codegemma:        return 2024  // CodeGemma (Apr 2024)
            case .qwen25Coder:      return 2024  // Qwen2.5 Coder (Sep 2024)
            case .llama:            return 2024  // Llama 3.2 (Sep 2024)
            case .smolLM:           return 2024  // SmolLM2 (Nov 2024)
            case .deepseekR1:       return 2025  // DeepSeek R1 (Jan 2025)
            case .phi:              return 2025  // Phi-4 mini (Feb 2025)
            case .qwen35:           return 2025  // Qwen3.5 (Mar 2025)
            case .qwen3:            return 2025  // Qwen3 (Apr 2025)
            case .gemma3:           return 2025  // Gemma 3 (Mar 2025)
            case .gemma3n:          return 2025  // Gemma 3n (Jun 2025)
            case .other:            return 2020
            }
        }
    }

    /// Whether this model has ReLU-based sparsity and benefits from Flash inference.
    var isFlashCompatible: Bool { family.isFlashCompatible }

    /// Parameter count as a Double (in billions) for numeric sorting.
    /// Parses strings like "0.5B", "1.3B", "6.7B", "8B". Returns 0 if unparseable.
    var parameterCountDouble: Double {
        let raw = parameterCount
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        if raw.hasSuffix("B"), let value = Double(raw.dropLast()) {
            return value
        }
        if raw.hasSuffix("M"), let value = Double(raw.dropLast()) {
            return value / 1000.0
        }
        return Double(raw) ?? 0
    }
    
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
    
    /// Returns the Hugging Face model page URL (not the direct download URL).
    /// Converts: https://huggingface.co/{org}/{repo}/resolve/main/{file}.gguf
    /// To: https://huggingface.co/{org}/{repo}
    var huggingFacePageURL: URL? {
        guard downloadURL.host?.contains("huggingface.co") == true else {
            return nil
        }
        
        let pathComponents = downloadURL.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 2 else {
            return nil
        }
        
        let org = pathComponents[0]
        let repo = pathComponents[1]
        return URL(string: "https://huggingface.co/\(org)/\(repo)")
    }
    
    /// Create a custom model entry from a Hugging Face URL.
    /// Supports URLs like:
    /// - https://huggingface.co/{org}/{repo}/resolve/main/{filename}.gguf
    /// - https://huggingface.co/{org}/{repo}/blob/main/{filename}.gguf
    static func fromHuggingFaceURL(
        _ urlString: String,
        contextSize: Int = 4096
    ) -> ModelRegistryEntry? {
        // Clean up the URL string
        var cleanURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Convert blob URLs to resolve URLs (direct download)
        cleanURL = cleanURL.replacingOccurrences(of: "/blob/", with: "/resolve/")
        
        guard let url = URL(string: cleanURL),
              url.host?.contains("huggingface.co") == true else {
            return nil
        }
        
        // Extract filename from URL
        let filename = url.lastPathComponent
        guard filename.hasSuffix(".gguf") else {
            return nil
        }
        
        // Parse path components: /org/repo/resolve/branch/path/to/file.gguf
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 4 else {
            return nil
        }
        
        let org = pathComponents[0]
        let repo = pathComponents[1]
        
        // Generate a unique ID from the URL
        let id = "custom-\(cleanURL.hashValue)"
        
        // Extract model info from filename
        let nameWithoutExt = filename.replacingOccurrences(of: ".gguf", with: "")
        let displayName = "\(org)/\(repo)"
        
        // Try to detect quantization from filename
        let quantization = extractQuantization(from: nameWithoutExt)
        
        // Try to detect parameter count from filename or repo name
        let parameterCount = extractParameterCount(from: "\(repo) \(nameWithoutExt)")
        
        return ModelRegistryEntry(
            id: id,
            name: displayName,
            description: "Custom model: \(filename)",
            sizeBytes: 0, // Unknown until we start downloading
            downloadURL: url,
            sha256: nil,
            quantization: quantization,
            parameterCount: parameterCount,
            recommendedContextSize: contextSize,
            family: .other,
            isCustom: true
        )
    }
    
    /// Extract quantization format from filename (e.g., Q4_K_M, Q8_0, etc.)
    private static func extractQuantization(from filename: String) -> String {
        let patterns = [
            "q4_k_m", "q4_k_s", "q4_0", "q4_1",
            "q5_k_m", "q5_k_s", "q5_0", "q5_1",
            "q6_k", "q8_0", "f16", "f32",
            "iq4_xs", "iq4_nl", "iq3_xxs", "iq2_xxs"
        ]
        
        let lowercased = filename.lowercased()
        for pattern in patterns {
            if lowercased.contains(pattern) {
                return pattern.uppercased()
            }
        }
        return "Unknown"
    }
    
    /// Extract parameter count from text (e.g., "0.5B", "1.5B", "7B", etc.)
    private static func extractParameterCount(from text: String) -> String {
        let patterns = [
            ("0\\.5b", "0.5B"), ("0\\.6b", "0.6B"),
            ("1\\.3b", "1.3B"), ("1\\.5b", "1.5B"),
            ("2b", "2B"), ("3b", "3B"), ("7b", "7B"),
            ("8b", "8B"), ("13b", "13B"), ("14b", "14B"),
            ("32b", "32B"), ("70b", "70B")
        ]
        
        let lowercased = text.lowercased()
        for (pattern, result) in patterns {
            if let _ = lowercased.range(of: pattern, options: .regularExpression) {
                return result
            }
        }
        return "Unknown"
    }
}

// MARK: - Custom Model Storage

/// Manages persistence of user-added custom models.
nonisolated enum CustomModelStorage {
    private static let customModelsKey = "CustomModels"
    
    /// Load all saved custom models.
    static func loadCustomModels() -> [ModelRegistryEntry] {
        guard let data = UserDefaults.standard.data(forKey: customModelsKey),
              let models = try? JSONDecoder().decode([ModelRegistryEntry].self, from: data) else {
            return []
        }
        return models
    }
    
    /// Save a custom model.
    static func saveCustomModel(_ model: ModelRegistryEntry) {
        var models = loadCustomModels()
        // Remove existing with same ID if present
        models.removeAll { $0.id == model.id }
        models.append(model)
        
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: customModelsKey)
        }
    }
    
    /// Delete a custom model.
    static func deleteCustomModel(id: String) {
        var models = loadCustomModels()
        models.removeAll { $0.id == id }
        
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: customModelsKey)
        }
    }
    
    /// Update a custom model's size after download.
    static func updateModelSize(id: String, sizeBytes: Int64) {
        var models = loadCustomModels()
        if let index = models.firstIndex(where: { $0.id == id }) {
            let old = models[index]
            models[index] = ModelRegistryEntry(
                id: old.id,
                name: old.name,
                description: old.description,
                sizeBytes: sizeBytes,
                downloadURL: old.downloadURL,
                sha256: old.sha256,
                quantization: old.quantization,
                parameterCount: old.parameterCount,
                recommendedContextSize: old.recommendedContextSize,
                family: old.family,
                isCustom: true
            )
            
            if let data = try? JSONEncoder().encode(models) {
                UserDefaults.standard.set(data, forKey: customModelsKey)
            }
        }
    }
}

/// Built-in model registry with recommended models for code generation.
enum ModelRegistry {
    /// Recommended models for PocketREPL, sorted by size (smallest first).
    static let models: [ModelRegistryEntry] = [

        // MARK: - Qwen 2.5 Coder Family
        ModelRegistryEntry(
            id: "qwen2.5-coder-0.5b-q4km",
            name: "Qwen2.5-Coder-0.5B",
            description: "Tiny but capable. Fast inference, good for simple tasks.",
            sizeBytes: 400_000_000,
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-0.5b-instruct-q4_k_m.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "0.5B",
            recommendedContextSize: 4096,
            family: .qwen25Coder
        ),
        ModelRegistryEntry(
            id: "qwen2.5-coder-1.5b-q4km",
            name: "Qwen2.5-Coder-1.5B",
            description: "Best balance of quality and speed. Recommended for most users.",
            sizeBytes: 934_000_000,
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "1.5B",
            recommendedContextSize: 4096,
            family: .qwen25Coder
        ),
        ModelRegistryEntry(
            id: "qwen2.5-coder-3b-q4km",
            name: "Qwen2.5-Coder-3B",
            description: "Higher quality code generation. Requires more memory.",
            sizeBytes: 1_800_000_000,
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-Coder-3B-Instruct-GGUF/resolve/main/qwen2.5-coder-3b-instruct-q4_k_m.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "3B",
            recommendedContextSize: 4096,
            family: .qwen25Coder
        ),
        ModelRegistryEntry(
            id: "qwen2.5-coder-7b-q4km",
            name: "Qwen2.5-Coder-7B",
            description: "Large model for complex tasks. Requires significant memory.",
            sizeBytes: 4_700_000_000,
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "7B",
            recommendedContextSize: 8192,
            family: .qwen25Coder
        ),
        
        // MARK: - Qwen 3 Family
        ModelRegistryEntry(
            id: "qwen3-0.6b-q4km",
            name: "Qwen3-0.6B",
            description: "Ultra-compact next-gen Qwen. Great for quick tasks.",
            sizeBytes: 500_000_000,
            downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "0.6B",
            recommendedContextSize: 4096,
            family: .qwen3
        ),
        ModelRegistryEntry(
            id: "qwen3-1.7b-q4km",
            name: "Qwen3-1.7B",
            description: "Improved reasoning over Qwen 2.5. Balanced performance.",
            sizeBytes: 1_100_000_000,
            downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "1.7B",
            recommendedContextSize: 4096,
            family: .qwen3
        ),
        ModelRegistryEntry(
            id: "qwen3-4b-q4km",
            name: "Qwen3-4B",
            description: "Strong general-purpose model with great reasoning.",
            sizeBytes: 2_600_000_000,
            downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "4B",
            recommendedContextSize: 8192,
            family: .qwen3
        ),
        ModelRegistryEntry(
            id: "qwen3-8b-q4km",
            name: "Qwen3-8B",
            description: "High-quality reasoning. Excellent for complex coding.",
            sizeBytes: 5_000_000_000,
            downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "8B",
            recommendedContextSize: 8192,
            family: .qwen3
        ),
        
        // MARK: - Qwen 3.5 Family (Latest with vision capabilities)
        ModelRegistryEntry(
            id: "qwen35-0.8b-q4km",
            name: "Qwen3.5-0.8B",
            description: "Ultra-compact latest Qwen. Fast and efficient.",
            sizeBytes: 600_000_000,
            downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "0.8B",
            recommendedContextSize: 4096,
            family: .qwen35
        ),
        ModelRegistryEntry(
            id: "qwen35-2b-q4km",
            name: "Qwen3.5-2B",
            description: "Balanced performance with latest improvements.",
            sizeBytes: 1_400_000_000,
            downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "2B",
            recommendedContextSize: 4096,
            family: .qwen35
        ),
        ModelRegistryEntry(
            id: "qwen35-4b-q4km",
            name: "Qwen3.5-4B",
            description: "Strong general-purpose model. Great reasoning.",
            sizeBytes: 2_740_000_000,
            downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "4B",
            recommendedContextSize: 8192,
            family: .qwen35
        ),
        
        // MARK: - Gemma 3 Family (Google's latest compact models)
        ModelRegistryEntry(
            id: "gemma-3-1b-q4km",
            name: "Gemma 3 1B",
            description: "Google's tiny but capable model. Great for quick tasks.",
            sizeBytes: 750_000_000,
            downloadURL: URL(string: "https://huggingface.co/MaziyarPanahi/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it.Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "1B",
            recommendedContextSize: 4096,
            family: .gemma3
        ),
        ModelRegistryEntry(
            id: "gemma-3-4b-q4km",
            name: "Gemma 3 4B",
            description: "Google's balanced model. Strong quality, popular in the community.",
            sizeBytes: 2_320_000_000,
            downloadURL: URL(string: "https://huggingface.co/lmstudio-community/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "4B",
            recommendedContextSize: 8192,
            family: .gemma3
        ),

        // MARK: - Gemma 3n Family (Google's efficient on-device models)
        ModelRegistryEntry(
            id: "gemma-3n-e2b-q4km",
            name: "Gemma 3n E2B",
            description: "Google's tiniest efficient model. Lightning fast.",
            sizeBytes: 1_400_000_000,
            downloadURL: URL(string: "https://huggingface.co/google/gemma-3n-E2B-it-GGUF/resolve/main/gemma-3n-E2B-it-Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "2B",
            recommendedContextSize: 4096,
            family: .gemma3n
        ),
        ModelRegistryEntry(
            id: "gemma-3n-e4b-q4km",
            name: "Gemma 3n E4B",
            description: "Balanced Gemma 3n. Good for general tasks.",
            sizeBytes: 2_700_000_000,
            downloadURL: URL(string: "https://huggingface.co/google/gemma-3n-E4B-it-GGUF/resolve/main/gemma-3n-E4B-it-Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "4B",
            recommendedContextSize: 8192,
            family: .gemma3n
        ),
        
        // MARK: - Llama 3.2 Family (Meta's mobile-first models)
        ModelRegistryEntry(
            id: "llama-3.2-1b-q4km",
            name: "Llama 3.2 1B",
            description: "Meta's mobile-first model. Ultra-fast on iPhone, great for simple tasks.",
            sizeBytes: 807_694_464,
            downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "1B",
            recommendedContextSize: 4096,
            family: .llama
        ),
        ModelRegistryEntry(
            id: "llama-3.2-3b-q4km",
            name: "Llama 3.2 3B",
            description: "Meta's balanced mobile model. Strong quality for its size.",
            sizeBytes: 2_019_377_696,
            downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "3B",
            recommendedContextSize: 4096,
            family: .llama
        ),

        // MARK: - Phi Family (Microsoft's compact models)
        ModelRegistryEntry(
            id: "phi-4-mini-q4km",
            name: "Phi-4-mini 3.8B",
            description: "Microsoft's best small model. Excellent reasoning and code generation for its size.",
            sizeBytes: 2_491_874_272,
            downloadURL: URL(string: "https://huggingface.co/unsloth/Phi-4-mini-instruct-GGUF/resolve/main/Phi-4-mini-instruct-Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "3.8B",
            recommendedContextSize: 4096,
            family: .phi
        ),
        ModelRegistryEntry(
            id: "phi-4-mini-reasoning-q4km",
            name: "Phi-4-mini-reasoning 3.8B",
            description: "Chain-of-thought reasoning variant. Shows step-by-step thinking for complex problems.",
            sizeBytes: 2_491_874_272,
            downloadURL: URL(string: "https://huggingface.co/unsloth/Phi-4-mini-reasoning-GGUF/resolve/main/Phi-4-mini-reasoning-Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "3.8B",
            recommendedContextSize: 4096,
            family: .phi
        ),

        // MARK: - SmolLM Family (HuggingFace on-device models)
        ModelRegistryEntry(
            id: "smollm2-1.7b-q4km",
            name: "SmolLM2 1.7B",
            description: "Purpose-built for on-device. Fast and memory-efficient.",
            sizeBytes: 1_055_609_824,
            downloadURL: URL(string: "https://huggingface.co/bartowski/SmolLM2-1.7B-Instruct-GGUF/resolve/main/SmolLM2-1.7B-Instruct-Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "1.7B",
            recommendedContextSize: 4096,
            family: .smolLM
        ),
        ModelRegistryEntry(
            id: "smollm3-3b-q4km",
            name: "SmolLM3 3B",
            description: "HuggingFace's latest on-device model (July 2025). 128K context support.",
            sizeBytes: 1_910_000_000,
            downloadURL: URL(string: "https://huggingface.co/ggml-org/SmolLM3-3B-GGUF/resolve/main/SmolLM3-Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "3B",
            recommendedContextSize: 8192,
            family: .smolLM
        ),

        // MARK: - DeepSeek R1 Distill Family (Reasoning models)
        ModelRegistryEntry(
            id: "deepseek-r1-distill-qwen-1.5b-q4km",
            name: "DeepSeek-R1-Distill 1.5B",
            description: "Chain-of-thought reasoning in a tiny package. Great for logic and math.",
            sizeBytes: 1_117_320_800,
            downloadURL: URL(string: "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-1.5B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "1.5B",
            recommendedContextSize: 4096,
            family: .deepseekR1
        ),
        ModelRegistryEntry(
            id: "deepseek-r1-distill-qwen-7b-q4km",
            name: "DeepSeek-R1-Distill 7B",
            description: "Strong reasoning model. Shows chain-of-thought for complex problems.",
            sizeBytes: 4_683_073_504,
            downloadURL: URL(string: "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "7B",
            recommendedContextSize: 8192,
            family: .deepseekR1
        ),
        ModelRegistryEntry(
            id: "deepseek-r1-0528-qwen3-8b-q4km",
            name: "DeepSeek-R1-0528 8B",
            description: "May 2025 improved reasoning distillation based on Qwen3. Stronger than the original R1 distill.",
            sizeBytes: 4_680_000_000,
            downloadURL: URL(string: "https://huggingface.co/MaziyarPanahi/DeepSeek-R1-0528-Qwen3-8B-GGUF/resolve/main/DeepSeek-R1-0528-Qwen3-8B.Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "8B",
            recommendedContextSize: 8192,
            family: .deepseekR1
        ),

        // MARK: - DeepSeek Coder Family
        ModelRegistryEntry(
            id: "deepseek-coder-1.3b-q4km",
            name: "DeepSeek Coder 1.3B",
            description: "Strong code understanding. Good alternative to Qwen.",
            sizeBytes: 820_000_000,
            downloadURL: URL(string: "https://huggingface.co/TheBloke/deepseek-coder-1.3b-instruct-GGUF/resolve/main/deepseek-coder-1.3b-instruct.Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "1.3B",
            recommendedContextSize: 4096,
            family: .deepseek
        ),
        ModelRegistryEntry(
            id: "deepseek-coder-6.7b-q4km",
            name: "DeepSeek Coder 6.7B",
            description: "Powerful code generation. Requires more memory.",
            sizeBytes: 4_100_000_000,
            downloadURL: URL(string: "https://huggingface.co/TheBloke/deepseek-coder-6.7B-instruct-GGUF/resolve/main/deepseek-coder-6.7b-instruct.Q4_K_M.gguf")!,
            sha256: nil,
            quantization: "Q4_K_M",
            parameterCount: "6.7B",
            recommendedContextSize: 8192,
            family: .deepseek
        ),
    ]
    
    /// Get the recommended model for the device.
    static func recommendedModel(availableMemoryMB: Int) -> ModelRegistryEntry {
        // Leave ~2GB headroom for app and system
        let usableMemoryMB = availableMemoryMB - 2048
        let usableMemoryBytes = Int64(usableMemoryMB) * 1024 * 1024
        
        // Find the largest model that fits (models are sorted smallest-first)
        for model in models.reversed() {
            // Model typically needs ~1.5x file size in RAM
            let estimatedRAM = Int64(Double(model.sizeBytes) * 1.5)
            if estimatedRAM <= usableMemoryBytes {
                return model
            }
        }
        
        // Fall back to smallest model
        return models[0]
    }
    
    /// Find a model by ID.
    static func model(withId id: String) -> ModelRegistryEntry? {
        models.first { $0.id == id }
    }
    
    /// All models including custom user-added models.
    nonisolated static var allModels: [ModelRegistryEntry] {
        models + CustomModelStorage.loadCustomModels()
    }
    
    /// Find a model by ID, including custom models.
    nonisolated static func anyModel(withId id: String) -> ModelRegistryEntry? {
        allModels.first { $0.id == id }
    }
}

// MARK: - Installed Model

/// A model that has been downloaded to local storage.
struct InstalledModel: Identifiable, Sendable {
    let id: String
    let path: URL
    let sizeBytes: Int64
    let registryEntry: ModelRegistryEntry?
    let downloadedAt: Date

    /// For `.flashpack` models: path to companion `.gguf` used as tokenizer.
    /// `FlashTokenizer.forFlashPack(at:)` also searches automatically, but
    /// storing it here lets the UI show tokenizer info without extra I/O.
    let tokenizerPath: URL?

    var name: String {
        registryEntry?.name ?? path.deletingPathExtension().lastPathComponent
    }
    
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
    
    var isCustom: Bool {
        registryEntry?.isCustom ?? id.hasPrefix("custom-")
    }

    /// Whether this entry represents a FlashPack (not a plain GGUF).
    var isFlashPack: Bool { path.pathExtension == "flashpack" }
}

// MARK: - Download State

/// The state of a model download.
enum DownloadState: Sendable, Equatable {
    case idle
    case downloading(progress: Double, bytesDownloaded: Int64, totalBytes: Int64)
    case verifying
    case completed(URL)
    case failed(String)
    case cancelled
    
    var isActive: Bool {
        switch self {
        case .downloading, .verifying:
            return true
        default:
            return false
        }
    }
    
    var progress: Double {
        switch self {
        case .downloading(let progress, _, _):
            return progress
        case .completed:
            return 1.0
        default:
            return 0.0
        }
    }
}

// MARK: - Download Progress

/// Progress information for an active download.
struct DownloadProgress: Sendable {
    let modelId: String
    let progress: Double
    let bytesDownloaded: Int64
    let totalBytes: Int64
    let estimatedTimeRemaining: TimeInterval?
    
    var formattedProgress: String {
        let downloaded = ByteCountFormatter.string(fromByteCount: bytesDownloaded, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(downloaded) / \(total)"
    }
    
    var percentComplete: Int {
        Int(progress * 100)
    }
}

// MARK: - Model Download Manager

/// Manages downloading, storing, and deleting GGUF model files.
actor ModelDownloadManager {
    
    // MARK: - Properties
    
    /// Active download tasks keyed by model ID.
    private var activeDownloads: [String: DownloadTask] = [:]
    
    /// Download session configured for background transfers.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600 * 4 // 4 hours max for large models
        config.allowsCellularAccess = true // User can control via system settings
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }()
    
    /// Directory where models are stored.
    var modelsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let modelsDir = docs.appendingPathComponent("Models", isDirectory: true)
        
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        
        return modelsDir
    }
    
    // MARK: - Download Task Wrapper
    
    private struct DownloadTask {
        let modelId: String
        let task: URLSessionDownloadTask
        var progress: Double = 0
        var bytesDownloaded: Int64 = 0
        var totalBytes: Int64 = 0
        var startTime: Date = Date()
        var continuation: AsyncThrowingStream<DownloadProgress, Error>.Continuation?
    }
    
    // MARK: - Download Methods
    
    /// Download a model from the registry.
    /// - Parameters:
    ///   - model: The model registry entry to download.
    ///   - onProgress: Progress callback (0.0 to 1.0).
    /// - Returns: URL to the downloaded model file.
    func download(
        model: ModelRegistryEntry,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        // Check if already downloaded
        let destination = modelsDirectory.appendingPathComponent("\(model.id).gguf")
        if FileManager.default.fileExists(atPath: destination.path) {
            // Verify file size matches expected
            let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path)
            let fileSize = attrs?[.size] as? Int64 ?? 0
            
            // Allow some tolerance for size (within 10%)
            let sizeDiff = abs(fileSize - model.sizeBytes)
            if sizeDiff < model.sizeBytes / 10 {
                return destination
            }
            
            // Size mismatch - delete and re-download
            try? FileManager.default.removeItem(at: destination)
        }
        
        // Check if download already in progress
        if activeDownloads[model.id] != nil {
            throw ModelError.invalidConfiguration(reason: "Download already in progress for \(model.name)")
        }
        
        // Check available storage
        let availableSpace = availableStorage()
        if availableSpace < model.sizeBytes + 100_000_000 { // 100MB buffer
            throw ModelError.invalidConfiguration(
                reason: "Insufficient storage. Need \(model.formattedSize) but only \(ByteCountFormatter.string(fromByteCount: availableSpace, countStyle: .file)) available."
            )
        }
        
        // Create download request
        var request = URLRequest(url: model.downloadURL)
        request.setValue("PocketREPL/1.0", forHTTPHeaderField: "User-Agent")
        
        // Check for partial download to resume
        let partialPath = destination.appendingPathExtension("partial")
        var resumeData: Data?
        if FileManager.default.fileExists(atPath: partialPath.path) {
            resumeData = try? Data(contentsOf: partialPath)
        }
        
        // Create download task
        let task: URLSessionDownloadTask
        if let resumeData = resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: request)
        }
        
        var downloadTask = DownloadTask(modelId: model.id, task: task)
        downloadTask.totalBytes = model.sizeBytes
        activeDownloads[model.id] = downloadTask
        
        // Start download with progress observation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    do {
                        let result = try await self.performDownload(
                            task: task,
                            model: model,
                            destination: destination,
                            partialPath: partialPath,
                            onProgress: onProgress
                        )
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelDownload(modelId: model.id) }
        }
    }
    
    private func performDownload(
        task: URLSessionDownloadTask,
        model: ModelRegistryEntry,
        destination: URL,
        partialPath: URL,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        
        // Create progress observation
        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @Sendable [weak self] in
                guard let self = self else { return }
                let progressInfo = await self.updateProgress(
                    modelId: model.id,
                    progress: progress.fractionCompleted,
                    bytesDownloaded: task.countOfBytesReceived,
                    totalBytes: task.countOfBytesExpectedToReceive > 0 
                        ? task.countOfBytesExpectedToReceive 
                        : model.sizeBytes
                )
                if let progressInfo = progressInfo {
                    onProgress(progressInfo)
                }
            }
        }
        
        defer {
            observation.invalidate()
            Task { await self.removeDownload(modelId: model.id) }
        }
        
        task.resume()
        
        // Wait for completion
        let (tempURL, response) = try await session.download(from: model.downloadURL)
        
        // Verify response
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ModelError.loadFailed(reason: "Download failed with status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        
        // Clean up partial file
        try? FileManager.default.removeItem(at: partialPath)
        
        // Move to final destination
        try? FileManager.default.removeItem(at: destination) // Remove any existing file
        try FileManager.default.moveItem(at: tempURL, to: destination)
        
        // Verify hash if provided
        if let expectedHash = model.sha256 {
            let actualHash = try computeSHA256(of: destination)
            if actualHash.lowercased() != expectedHash.lowercased() {
                try? FileManager.default.removeItem(at: destination)
                throw ModelError.loadFailed(reason: "Hash verification failed")
            }
        }
        
        // Record download metadata
        try saveModelMetadata(model: model, path: destination)
        
        return destination
    }
    
    private func updateProgress(
        modelId: String,
        progress: Double,
        bytesDownloaded: Int64,
        totalBytes: Int64
    ) -> DownloadProgress? {
        guard var task = activeDownloads[modelId] else { return nil }
        
        task.progress = progress
        task.bytesDownloaded = bytesDownloaded
        task.totalBytes = totalBytes
        activeDownloads[modelId] = task
        
        let elapsed = Date().timeIntervalSince(task.startTime)
        let bytesPerSecond = elapsed > 0 ? Double(bytesDownloaded) / elapsed : 0
        let remainingBytes = totalBytes - bytesDownloaded
        let estimatedRemaining = bytesPerSecond > 0 ? TimeInterval(Double(remainingBytes) / bytesPerSecond) : nil
        
        return DownloadProgress(
            modelId: modelId,
            progress: progress,
            bytesDownloaded: bytesDownloaded,
            totalBytes: totalBytes,
            estimatedTimeRemaining: estimatedRemaining
        )
    }
    
    private func removeDownload(modelId: String) {
        activeDownloads.removeValue(forKey: modelId)
    }
    
    /// Cancel an active download.
    func cancelDownload(modelId: String) {
        guard let task = activeDownloads[modelId] else { return }
        
        // Save resume data for later
        task.task.cancel { resumeData in
            if let resumeData = resumeData {
                let partialPath = self.modelsDirectory
                    .appendingPathComponent("\(modelId).gguf")
                    .appendingPathExtension("partial")
                try? resumeData.write(to: partialPath)
            }
        }
        
        activeDownloads.removeValue(forKey: modelId)
    }
    
    /// Get the state of a download.
    ///
    /// Returns `.completed` if either a `.gguf` **or** a `.flashpack` file
    /// exists for the given ID (the FlashPack is the preferred form once
    /// conversion has run, but the GGUF is needed as a tokenizer companion).
    func downloadState(for modelId: String) -> DownloadState {
        if let task = activeDownloads[modelId] {
            return .downloading(
                progress: task.progress,
                bytesDownloaded: task.bytesDownloaded,
                totalBytes: task.totalBytes
            )
        }
        
        let ggufPath = modelsDirectory.appendingPathComponent("\(modelId).gguf")
        if FileManager.default.fileExists(atPath: ggufPath.path) {
            return .completed(ggufPath)
        }

        // Also count a converted FlashPack as "completed" so the registry
        // doesn't offer a redundant re-download button.
        let flashPath = modelsDirectory.appendingPathComponent("\(modelId).flashpack")
        if FileManager.default.fileExists(atPath: flashPath.path) {
            return .completed(flashPath)
        }
        
        return .idle
    }
    
    // MARK: - Storage Management
    
    /// List all installed models, including converted FlashPack files.
    ///
    /// Both `.gguf` and `.flashpack` files are returned as separate entries.
    /// For FlashPack entries the `tokenizerPath` field points to the companion
    /// `.gguf` in the same directory (if present), matching the lookup order
    /// used by `FlashTokenizer.forFlashPack(at:)`.
    func installedModels() -> [InstalledModel] {
        let fm = FileManager.default
        
        guard let contents = try? fm.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        // Build a set of all .gguf base names for fast tokenizer-companion lookup
        let ggufBaseNames: Set<String> = Set(
            contents
                .filter { $0.pathExtension == "gguf" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )

        return contents.compactMap { url -> InstalledModel? in
            let ext = url.pathExtension
            guard ext == "gguf" || ext == "flashpack" else { return nil }

            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let created = values?.creationDate ?? Date()

            // ID is the base filename without extension.
            // A .flashpack named "llama-2-7b-q4km.flashpack" gets id "llama-2-7b-q4km",
            // matching the registry entry and its companion "llama-2-7b-q4km.gguf".
            let id = url.deletingPathExtension().lastPathComponent
            let registryEntry = ModelRegistry.anyModel(withId: id)

            // For FlashPack entries, resolve companion .gguf tokenizer path
            var tokenizerPath: URL? = nil
            if ext == "flashpack" {
                // Prefer explicit sidecar, then same-name .gguf
                let sidecar = url.appendingPathExtension("tokenizer.gguf")
                if fm.fileExists(atPath: sidecar.path) {
                    tokenizerPath = sidecar
                } else if ggufBaseNames.contains(id) {
                    tokenizerPath = modelsDirectory
                        .appendingPathComponent(id)
                        .appendingPathExtension("gguf")
                }
            }

            return InstalledModel(
                id: id,
                path: url,
                sizeBytes: size,
                registryEntry: registryEntry,
                downloadedAt: created,
                tokenizerPath: tokenizerPath
            )
        }.sorted { $0.downloadedAt > $1.downloadedAt }
    }
    
    /// Download a custom model from a Hugging Face URL.
    /// - Parameters:
    ///   - urlString: The Hugging Face URL to the GGUF file.
    ///   - contextSize: The context size to use for this model.
    ///   - onProgress: Progress callback (0.0 to 1.0).
    /// - Returns: URL to the downloaded model file.
    func downloadCustomModel(
        urlString: String,
        contextSize: Int = 4096,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        // Parse the URL and create a model entry
        guard let model = ModelRegistryEntry.fromHuggingFaceURL(urlString, contextSize: contextSize) else {
            throw ModelError.invalidConfiguration(
                reason: "Invalid Hugging Face URL. Expected format: https://huggingface.co/{org}/{repo}/resolve/main/{filename}.gguf"
            )
        }
        
        // Save the custom model entry
        CustomModelStorage.saveCustomModel(model)
        
        // Download the model
        let destination = try await downloadCustomEntry(model: model, onProgress: onProgress)
        
        // Update the stored model with actual file size
        let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let fileSize = attrs?[.size] as? Int64 ?? 0
        CustomModelStorage.updateModelSize(id: model.id, sizeBytes: fileSize)
        
        return destination
    }
    
    /// Download a custom model entry (similar to registry download but with size discovery).
    private func downloadCustomEntry(
        model: ModelRegistryEntry,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        let destination = modelsDirectory.appendingPathComponent("\(model.id).gguf")
        
        // Check if already downloaded
        if FileManager.default.fileExists(atPath: destination.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path)
            let fileSize = attrs?[.size] as? Int64 ?? 0
            if fileSize > 0 {
                return destination
            }
            // Empty or corrupt file - delete and re-download
            try? FileManager.default.removeItem(at: destination)
        }
        
        // Check if download already in progress
        if activeDownloads[model.id] != nil {
            throw ModelError.invalidConfiguration(reason: "Download already in progress for this model")
        }
        
        // Create download request
        var request = URLRequest(url: model.downloadURL)
        request.setValue("PocketREPL/1.0", forHTTPHeaderField: "User-Agent")
        
        // First, do a HEAD request to get the file size
        var headRequest = request
        headRequest.httpMethod = "HEAD"
        
        var expectedSize: Int64 = 0
        if let (_, headResponse) = try? await session.data(for: headRequest),
           let httpResponse = headResponse as? HTTPURLResponse {
            expectedSize = Int64(httpResponse.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0
        }
        
        // Check available storage
        let availableSpace = availableStorage()
        if expectedSize > 0 && availableSpace < expectedSize + 100_000_000 {
            throw ModelError.invalidConfiguration(
                reason: "Insufficient storage. Need \(ByteCountFormatter.string(fromByteCount: expectedSize, countStyle: .file)) but only \(ByteCountFormatter.string(fromByteCount: availableSpace, countStyle: .file)) available."
            )
        }
        
        // Create download task
        let task = session.downloadTask(with: request)
        
        var downloadTask = DownloadTask(modelId: model.id, task: task)
        downloadTask.totalBytes = expectedSize
        activeDownloads[model.id] = downloadTask
        
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    do {
                        let partialPath = destination.appendingPathExtension("partial")
                        let result = try await self.performDownload(
                            task: task,
                            model: model,
                            destination: destination,
                            partialPath: partialPath,
                            onProgress: onProgress
                        )
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelDownload(modelId: model.id) }
        }
    }
    
    /// Delete an installed model.
    ///
    /// Removes both the `.gguf` source file and any `.flashpack` conversion
    /// with the same base ID, plus metadata sidecars.
    func deleteModel(id: String) throws {
        let ggufPath  = modelsDirectory.appendingPathComponent("\(id).gguf")
        let flashPath = modelsDirectory.appendingPathComponent("\(id).flashpack")

        let ggufExists  = FileManager.default.fileExists(atPath: ggufPath.path)
        let flashExists = FileManager.default.fileExists(atPath: flashPath.path)

        guard ggufExists || flashExists else {
            throw ModelError.modelNotFound(path: ggufPath.path)
        }

        if ggufExists {
            try FileManager.default.removeItem(at: ggufPath)
            let metadataPath = ggufPath.appendingPathExtension("meta.json")
            try? FileManager.default.removeItem(at: metadataPath)
        }

        if flashExists {
            try? FileManager.default.removeItem(at: flashPath)
            // Also remove tokenizer sidecar if present
            let sidecar = flashPath.appendingPathExtension("tokenizer.gguf")
            try? FileManager.default.removeItem(at: sidecar)
        }
        
        // If this was a custom model, remove it from storage
        if id.hasPrefix("custom-") {
            CustomModelStorage.deleteCustomModel(id: id)
        }
    }
    
    /// Delete all installed models.
    func deleteAllModels() throws {
        for model in installedModels() {
            try? deleteModel(id: model.id)
        }
    }
    
    /// Total storage used by installed models.
    func totalStorageUsed() -> Int64 {
        installedModels().reduce(0) { $0 + $1.sizeBytes }
    }
    
    /// Available storage on device.
    func availableStorage() -> Int64 {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        guard let path = paths.first else { return 0 }
        
        do {
            let values = try path.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage ?? 0
        } catch {
            return 0
        }
    }
    
    /// Check if a model is installed (as either a `.gguf` or `.flashpack`).
    func isModelInstalled(id: String) -> Bool {
        let gguf = modelsDirectory.appendingPathComponent("\(id).gguf")
        if FileManager.default.fileExists(atPath: gguf.path) { return true }
        let flash = modelsDirectory.appendingPathComponent("\(id).flashpack")
        return FileManager.default.fileExists(atPath: flash.path)
    }
    
    /// Get the best available path for an installed model.
    ///
    /// Prefers the `.flashpack` version if it exists, otherwise returns the
    /// `.gguf`. Returns `nil` if neither is present.
    func modelPath(for id: String) -> URL? {
        // Prefer FlashPack for flash-compatible registry entries
        let flash = modelsDirectory.appendingPathComponent("\(id).flashpack")
        if FileManager.default.fileExists(atPath: flash.path) { return flash }
        let gguf = modelsDirectory.appendingPathComponent("\(id).gguf")
        return FileManager.default.fileExists(atPath: gguf.path) ? gguf : nil
    }
    
    // MARK: - Verification
    
    /// Compute SHA256 hash of a file.
    private func computeSHA256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        
        var hasher = SHA256()
        
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1024 * 1024) // 1MB chunks
            if chunk.isEmpty {
                return false
            }
            hasher.update(data: chunk)
            return true
        }) {}
        
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Verify model integrity.
    func verifyModel(at url: URL, expectedHash: String?) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        
        // If no hash provided, just check file exists and is non-empty
        guard let expectedHash = expectedHash else {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = attrs?[.size] as? Int64 ?? 0
            return size > 0
        }
        
        // Verify hash
        guard let actualHash = try? computeSHA256(of: url) else {
            return false
        }
        
        return actualHash.lowercased() == expectedHash.lowercased()
    }
    
    // MARK: - Metadata
    
    private struct ModelMetadata: Codable {
        let id: String
        let name: String
        let downloadedAt: Date
        let sizeBytes: Int64
        let parameterCount: String
        let quantization: String
    }
    
    private func saveModelMetadata(model: ModelRegistryEntry, path: URL) throws {
        let metadata = ModelMetadata(
            id: model.id,
            name: model.name,
            downloadedAt: Date(),
            sizeBytes: model.sizeBytes,
            parameterCount: model.parameterCount,
            quantization: model.quantization
        )
        
        let metadataPath = path.appendingPathExtension("meta.json")
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataPath)
    }
}

// MARK: - Convenience Extensions

extension ModelDownloadManager {
    /// Download the recommended model for this device.
    func downloadRecommendedModel(
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        let availableMemoryMB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        let recommended = ModelRegistry.recommendedModel(availableMemoryMB: availableMemoryMB)
        return try await download(model: recommended, onProgress: onProgress)
    }
    
    /// Get the first installed model, or nil if none installed.
    func firstInstalledModel() -> InstalledModel? {
        installedModels().first
    }
}
