import Foundation

/// Metadata for a conversation, stored separately from messages for fast listing
struct ConversationMetadata: Identifiable, Codable, Sendable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var messageCount: Int
    var preview: String

    init(
        id: UUID = UUID(),
        title: String = "New Conversation",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        messageCount: Int = 0,
        preview: String = ""
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.preview = preview
    }
}

/// Full conversation data including messages and tool trace
struct ConversationData: Codable, Sendable {
    let id: UUID
    var messages: [AgentMessage]
    var toolTrace: [ToolTraceEvent]

    init(id: UUID, messages: [AgentMessage], toolTrace: [ToolTraceEvent]) {
        self.id = id
        self.messages = messages
        self.toolTrace = toolTrace
    }
}

/// Manages persistence of conversations to disk
actor ConversationStore {
    private let baseURL: URL
    private let metadataFileName = "metadata.json"
    private let messagesFileName = "messages.json"
    private let fileManager = FileManager.default

    /// Cached metadata for fast listing
    private var cachedMetadata: [UUID: ConversationMetadata] = [:]
    private var metadataLoaded = false

    init(workspaceURL: URL) {
        self.baseURL = workspaceURL
            .appendingPathComponent(".pocketrepl", isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
    }

    /// Ensure the conversations directory exists
    private func ensureDirectoryExists() throws {
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    /// Directory for a specific conversation
    private func conversationDirectory(for id: UUID) -> URL {
        baseURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: - Metadata Operations

    /// List all conversations, sorted by most recently updated
    func listConversations() throws -> [ConversationMetadata] {
        try loadMetadataIfNeeded()
        return cachedMetadata.values
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Get metadata for a specific conversation
    func getMetadata(for id: UUID) throws -> ConversationMetadata? {
        try loadMetadataIfNeeded()
        return cachedMetadata[id]
    }

    /// Load all metadata from disk if not already cached
    private func loadMetadataIfNeeded() throws {
        guard !metadataLoaded else { return }

        try ensureDirectoryExists()

        let contents = try fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for item in contents {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let metadataFile = item.appendingPathComponent(metadataFileName)
            guard let data = try? Data(contentsOf: metadataFile),
                  let metadata = try? JSONDecoder.conversationDecoder.decode(ConversationMetadata.self, from: data) else {
                continue
            }

            cachedMetadata[metadata.id] = metadata
        }

        metadataLoaded = true
    }

    // MARK: - Conversation Operations

    /// Create a new conversation and return its metadata
    @discardableResult
    func createConversation(
        title: String = "New Conversation",
        messages: [AgentMessage] = [],
        toolTrace: [ToolTraceEvent] = []
    ) throws -> ConversationMetadata {
        try ensureDirectoryExists()

        let id = UUID()
        let directory = conversationDirectory(for: id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Generate title from first user message if available
        let generatedTitle = generateTitle(from: messages) ?? title
        let preview = generatePreview(from: messages)

        let metadata = ConversationMetadata(
            id: id,
            title: generatedTitle,
            createdAt: .now,
            updatedAt: .now,
            messageCount: messages.count,
            preview: preview
        )

        let conversationData = ConversationData(
            id: id,
            messages: messages,
            toolTrace: toolTrace
        )

        // Write metadata
        let metadataFile = directory.appendingPathComponent(metadataFileName)
        let metadataData = try JSONEncoder.conversationEncoder.encode(metadata)
        try metadataData.write(to: metadataFile, options: .atomic)

        // Write messages
        let messagesFile = directory.appendingPathComponent(messagesFileName)
        let messagesData = try JSONEncoder.conversationEncoder.encode(conversationData)
        try messagesData.write(to: messagesFile, options: .atomic)

        cachedMetadata[id] = metadata
        return metadata
    }

    /// Save/update an existing conversation
    func saveConversation(
        id: UUID,
        messages: [AgentMessage],
        toolTrace: [ToolTraceEvent],
        title: String? = nil
    ) throws {
        let directory = conversationDirectory(for: id)

        // Ensure directory exists
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // Update or create metadata
        let existingMetadata = cachedMetadata[id]
        let generatedTitle = title ?? generateTitle(from: messages) ?? existingMetadata?.title ?? "Conversation"
        let preview = generatePreview(from: messages)

        let metadata = ConversationMetadata(
            id: id,
            title: generatedTitle,
            createdAt: existingMetadata?.createdAt ?? .now,
            updatedAt: .now,
            messageCount: messages.count,
            preview: preview
        )

        let conversationData = ConversationData(
            id: id,
            messages: messages,
            toolTrace: toolTrace
        )

        // Write metadata
        let metadataFile = directory.appendingPathComponent(metadataFileName)
        let metadataData = try JSONEncoder.conversationEncoder.encode(metadata)
        try metadataData.write(to: metadataFile, options: .atomic)

        // Write messages
        let messagesFile = directory.appendingPathComponent(messagesFileName)
        let messagesData = try JSONEncoder.conversationEncoder.encode(conversationData)
        try messagesData.write(to: messagesFile, options: .atomic)

        cachedMetadata[id] = metadata
    }

    /// Load a conversation's full data
    func loadConversation(id: UUID) throws -> ConversationData? {
        let directory = conversationDirectory(for: id)
        let messagesFile = directory.appendingPathComponent(messagesFileName)

        guard let data = try? Data(contentsOf: messagesFile) else {
            return nil
        }

        return try JSONDecoder.conversationDecoder.decode(ConversationData.self, from: data)
    }

    /// Delete a conversation
    func deleteConversation(id: UUID) throws {
        let directory = conversationDirectory(for: id)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        cachedMetadata.removeValue(forKey: id)
    }

    /// Update just the title of a conversation
    func updateTitle(id: UUID, title: String) throws {
        guard var metadata = cachedMetadata[id] else { return }
        metadata.title = title
        metadata.updatedAt = .now

        let directory = conversationDirectory(for: id)
        let metadataFile = directory.appendingPathComponent(metadataFileName)
        let metadataData = try JSONEncoder.conversationEncoder.encode(metadata)
        try metadataData.write(to: metadataFile, options: .atomic)

        cachedMetadata[id] = metadata
    }

    // MARK: - Helpers

    /// Generate a title from the first user message
    private func generateTitle(from messages: [AgentMessage]) -> String? {
        guard let firstUserMessage = messages.first(where: { $0.role == .user }) else {
            return nil
        }

        let text = firstUserMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }

        // Truncate to first line or 50 chars
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        if firstLine.count <= 50 {
            return firstLine
        }
        return String(firstLine.prefix(47)) + "..."
    }

    /// Generate a preview from the last assistant message
    private func generatePreview(from messages: [AgentMessage]) -> String {
        guard let lastAssistant = messages.last(where: { $0.role == .assistant }) else {
            return ""
        }

        let text = lastAssistant.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count <= 80 {
            return text
        }
        return String(text.prefix(77)) + "..."
    }
}

// MARK: - JSON Coding Extensions

private extension JSONEncoder {
    nonisolated static var conversationEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    nonisolated static var conversationDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
