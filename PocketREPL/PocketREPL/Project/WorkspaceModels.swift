import Foundation

nonisolated struct WorkspaceStorageLocation: Codable, Hashable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case applicationSupport
        case ubiquitousContainer
    }

    var kind: Kind
    var containerIdentifier: String?

    static let localApplicationSupport = WorkspaceStorageLocation(kind: .applicationSupport, containerIdentifier: nil)

    static func ubiquitousContainer(identifier: String? = nil) -> WorkspaceStorageLocation {
        WorkspaceStorageLocation(kind: .ubiquitousContainer, containerIdentifier: identifier)
    }
}

nonisolated struct WorkspaceInfo: Identifiable, Codable, Hashable, Sendable {
    var id: String { slug }

    let displayName: String
    let slug: String
    let storageLocation: WorkspaceStorageLocation
    let rootURL: URL
    let createdAt: Date
    let lastOpenedAt: Date

    var bookmark: WorkspaceBookmark {
        WorkspaceBookmark(
            displayName: displayName,
            slug: slug,
            storageLocation: storageLocation,
            lastOpenedAt: lastOpenedAt
        )
    }
}

nonisolated struct WorkspaceBookmark: Codable, Hashable, Sendable, Identifiable {
    var id: String { slug }

    let displayName: String
    let slug: String
    let storageLocation: WorkspaceStorageLocation
    let lastOpenedAt: Date
}

nonisolated enum ProjectFileKind: String, Codable, Hashable, Sendable {
    case file
    case directory
}

nonisolated struct ProjectFileEntry: Identifiable, Hashable, Sendable {
    var id: String { relativePath.isEmpty ? "." : relativePath }

    let relativePath: String
    let name: String
    let kind: ProjectFileKind
    let sizeBytes: Int64?
    let modifiedAt: Date?
}

nonisolated struct ProjectFileContents: Hashable, Sendable {
    let relativePath: String
    let text: String
    let startLine: Int
    let endLine: Int
    let totalLineCount: Int
    let isTruncated: Bool
    let byteCount: Int
}

nonisolated struct ProjectTextRange: Hashable, Sendable {
    let lowerBound: Int
    let upperBound: Int
}

nonisolated struct ProjectSearchMatch: Identifiable, Hashable, Sendable {
    var id: String { "\(relativePath):\(lineNumber):\(lineText)" }

    let relativePath: String
    let lineNumber: Int
    let lineText: String
    let matchedRanges: [ProjectTextRange]
}
