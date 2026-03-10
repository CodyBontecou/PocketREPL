import Foundation

enum ProjectStoreError: LocalizedError, Sendable {
    case emptyWorkspaceName
    case absolutePathNotAllowed(String)
    case parentTraversalNotAllowed(String)
    case reservedPathComponent(String)
    case invalidPathComponent(String)
    case missingFile(String)
    case expectedFile(String)
    case expectedDirectory(String)
    case invalidLineRange(start: Int, total: Int)
    case unreadableTextFile(String)
    case emptyPath

    var errorDescription: String? {
        switch self {
        case .emptyWorkspaceName:
            return "Workspace names must not be empty."
        case .absolutePathNotAllowed(let path):
            return "Absolute paths are not allowed: \(path)"
        case .parentTraversalNotAllowed(let path):
            return "Parent traversal is not allowed: \(path)"
        case .reservedPathComponent(let component):
            return "The path component is reserved for PocketREPL metadata: \(component)"
        case .invalidPathComponent(let component):
            return "Invalid path component: \(component)"
        case .missingFile(let path):
            return "No file or directory exists at \(path)."
        case .expectedFile(let path):
            return "Expected a file at \(path)."
        case .expectedDirectory(let path):
            return "Expected a directory at \(path)."
        case .invalidLineRange(let start, let total):
            return "Cannot start reading at line \(start) for a file with \(total) lines."
        case .unreadableTextFile(let path):
            return "Could not decode \(path) as UTF-8 text."
        case .emptyPath:
            return "A non-empty relative path is required for this operation."
        }
    }
}

actor ProjectStore {
    nonisolated let workspaceInfo: WorkspaceInfo

    private static let appDirectoryName = "PocketREPL"
    private static let workspacesDirectoryName = "Workspaces"
    private static let metadataDirectoryName = ".pocketrepl"
    private static let metadataFilename = "workspace.json"
    private static let activeWorkspaceBookmarkKey = "PocketREPL.activeWorkspaceBookmark"
    private static let javascriptExtensions: Set<String> = ["js", "mjs", "cjs", "jsx"]

    init(workspaceName: String, storageLocation: WorkspaceStorageLocation? = nil, now: Date = .now) {
        let resolvedStorageLocation = storageLocation ?? .localApplicationSupport
        let trimmedName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedName.isEmpty ? "PocketREPL" : trimmedName
        let slug = Self.slug(for: displayName)
        let rootURL = Self.baseDirectoryURL(for: resolvedStorageLocation).appendingPathComponent(slug, isDirectory: true)
        self.workspaceInfo = WorkspaceInfo(
            displayName: displayName,
            slug: slug,
            storageLocation: resolvedStorageLocation,
            rootURL: rootURL,
            createdAt: now,
            lastOpenedAt: now
        )
    }

    nonisolated static func restore(defaultWorkspaceName: String = "PocketREPL") -> ProjectStore {
        if let bookmark = loadActiveWorkspaceBookmark() {
            return ProjectStore(workspaceName: bookmark.displayName, storageLocation: bookmark.storageLocation, now: bookmark.lastOpenedAt)
        }

        return ProjectStore(workspaceName: defaultWorkspaceName)
    }

    nonisolated static func listKnownWorkspaces(storageLocation: WorkspaceStorageLocation? = nil) -> [WorkspaceBookmark] {
        let resolvedStorageLocation = storageLocation ?? .localApplicationSupport
        let fileManager = FileManager.default
        let baseURL = baseDirectoryURL(for: resolvedStorageLocation)

        guard let directoryContents = try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return directoryContents.compactMap { candidate in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }

            let metadataURL = candidate
                .appendingPathComponent(metadataDirectoryName, isDirectory: true)
                .appendingPathComponent(metadataFilename)

            if let data = try? Data(contentsOf: metadataURL),
               let workspace = try? JSONDecoder().decode(WorkspaceInfo.self, from: data) {
                return workspace.bookmark
            }

            return WorkspaceBookmark(
                displayName: candidate.lastPathComponent,
                slug: candidate.lastPathComponent,
                storageLocation: resolvedStorageLocation,
                lastOpenedAt: .distantPast
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func createWorkspaceIfNeeded() throws -> WorkspaceInfo {
        let fileManager = FileManager.default
        let workspaceRoot = workspaceInfo.rootURL
        let metadataDirectory = workspaceRoot.appendingPathComponent(Self.metadataDirectoryName, isDirectory: true)
        let metadataFile = metadataDirectory.appendingPathComponent(Self.metadataFilename)

        try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)

        let metadata = loadWorkspaceMetadata(from: metadataFile) ?? workspaceInfo
        let persisted = WorkspaceInfo(
            displayName: metadata.displayName,
            slug: metadata.slug,
            storageLocation: metadata.storageLocation,
            rootURL: workspaceRoot,
            createdAt: metadata.createdAt,
            lastOpenedAt: .now
        )

        let encoded = try JSONEncoder.prettyPrinted.encode(persisted)
        try encoded.write(to: metadataFile, options: .atomic)
        persistActiveWorkspaceBookmark(persisted.bookmark)
        return persisted
    }

    func workspaceMetadata() throws -> WorkspaceInfo {
        let metadataFile = workspaceInfo.rootURL
            .appendingPathComponent(Self.metadataDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.metadataFilename)

        if let metadata = loadWorkspaceMetadata(from: metadataFile) {
            return metadata
        }

        return try createWorkspaceIfNeeded()
    }

    nonisolated func resolve(relativePath: String, allowEmpty: Bool = true) throws -> URL {
        let normalizedPath = try Self.normalize(relativePath, allowEmpty: allowEmpty)
        let workspaceRoot = workspaceInfo.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = normalizedPath.isEmpty
            ? workspaceRoot
            : workspaceRoot.appendingPathComponent(normalizedPath, isDirectory: false)
        let resolvedCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()

        if resolvedCandidate.path != workspaceRoot.path,
           !resolvedCandidate.path.hasPrefix(workspaceRoot.path + "/") {
            throw ProjectStoreError.parentTraversalNotAllowed(relativePath)
        }

        return resolvedCandidate
    }

    func createDirectory(at relativePath: String) throws -> ProjectFileEntry {
        let url = try resolve(relativePath: relativePath, allowEmpty: false)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try entry(for: url)
    }

    func readFile(at relativePath: String, startingAtLine startLine: Int = 1, maxLines: Int? = nil) throws -> ProjectFileContents {
        try readFileSynchronously(at: relativePath, startingAtLine: startLine, maxLines: maxLines)
    }

    nonisolated func readFileSynchronously(at relativePath: String, startingAtLine startLine: Int = 1, maxLines: Int? = nil) throws -> ProjectFileContents {
        let normalizedPath = try Self.normalize(relativePath, allowEmpty: false)
        let url = try resolve(relativePath: normalizedPath, allowEmpty: false)
        return try Self.readFileContents(at: url, relativePath: normalizedPath, startLine: startLine, maxLines: maxLines)
    }

    @discardableResult
    func writeFile(_ text: String, to relativePath: String) throws -> ProjectFileEntry {
        let url = try resolve(relativePath: relativePath, allowEmpty: false)
        let parentDirectory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return try entry(for: url)
    }

    func deleteItem(at relativePath: String) throws {
        let url = try resolve(relativePath: relativePath, allowEmpty: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectStoreError.missingFile(relativePath)
        }
        try FileManager.default.removeItem(at: url)
    }

    func listFiles(in relativePath: String = "", recursive: Bool = false) throws -> [ProjectFileEntry] {
        let directoryURL = try resolve(relativePath: relativePath, allowEmpty: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
            throw ProjectStoreError.missingFile(relativePath.isEmpty ? "." : relativePath)
        }
        guard isDirectory.boolValue else {
            throw ProjectStoreError.expectedDirectory(relativePath.isEmpty ? "." : relativePath)
        }

        return try listEntries(at: directoryURL, recursive: recursive)
            .filter { $0.relativePath != Self.metadataDirectoryName && !$0.relativePath.hasPrefix(Self.metadataDirectoryName + "/") }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return lhs.kind == .directory
                }

                return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
            }
    }

    func searchJavaScript(query: String, limit: Int = 100) throws -> [ProjectSearchMatch] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let entries = try listFiles(in: "", recursive: true)
            .filter { $0.kind == .file }
            .filter { entry in
                let `extension` = URL(fileURLWithPath: entry.relativePath).pathExtension.lowercased()
                return Self.javascriptExtensions.contains(`extension`)
            }

        var matches: [ProjectSearchMatch] = []

        for entry in entries {
            let file = try readFile(at: entry.relativePath)
            let lines = file.text.isEmpty
                ? []
                : file.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

            for (index, line) in lines.enumerated() {
                let ranges = Self.matchRanges(in: line, query: trimmedQuery)
                guard !ranges.isEmpty else { continue }

                matches.append(
                    ProjectSearchMatch(
                        relativePath: entry.relativePath,
                        lineNumber: index + 1,
                        lineText: line,
                        matchedRanges: ranges
                    )
                )

                if matches.count >= limit {
                    return matches
                }
            }
        }

        return matches
    }

    private func listEntries(at directoryURL: URL, recursive: Bool) throws -> [ProjectFileEntry] {
        let fileManager = FileManager.default
        let children = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsPackageDescendants]
        )

        var collected: [ProjectFileEntry] = []

        for child in children where child.lastPathComponent != Self.metadataDirectoryName {
            let childEntry = try entry(for: child)
            collected.append(childEntry)

            if recursive, childEntry.kind == .directory {
                collected.append(contentsOf: try listEntries(at: child, recursive: true))
            }
        }

        return collected
    }

    private func entry(for url: URL) throws -> ProjectFileEntry {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let normalizedRoot = workspaceInfo.rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let normalizedURL = url.standardizedFileURL.resolvingSymlinksInPath().path
        let relativePath = normalizedURL == normalizedRoot
            ? ""
            : String(normalizedURL.dropFirst(normalizedRoot.count + 1))

        return ProjectFileEntry(
            relativePath: relativePath,
            name: url.lastPathComponent,
            kind: values.isDirectory == true ? .directory : .file,
            sizeBytes: values.fileSize.map(Int64.init),
            modifiedAt: values.contentModificationDate
        )
    }

    private func loadWorkspaceMetadata(from url: URL) -> WorkspaceInfo? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? JSONDecoder().decode(WorkspaceInfo.self, from: data)
    }

    private func persistActiveWorkspaceBookmark(_ bookmark: WorkspaceBookmark) {
        guard let data = try? JSONEncoder().encode(bookmark) else {
            return
        }

        UserDefaults.standard.set(data, forKey: Self.activeWorkspaceBookmarkKey)
    }

    private nonisolated static func loadActiveWorkspaceBookmark() -> WorkspaceBookmark? {
        guard let data = UserDefaults.standard.data(forKey: activeWorkspaceBookmarkKey) else {
            return nil
        }

        return try? JSONDecoder().decode(WorkspaceBookmark.self, from: data)
    }

    private nonisolated static func baseDirectoryURL(for storageLocation: WorkspaceStorageLocation) -> URL {
        let fileManager = FileManager.default

        switch storageLocation.kind {
        case .applicationSupport:
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory.appendingPathComponent("ApplicationSupport", isDirectory: true)
            return base
                .appendingPathComponent(appDirectoryName, isDirectory: true)
                .appendingPathComponent(workspacesDirectoryName, isDirectory: true)

        case .ubiquitousContainer:
            let container = fileManager.url(forUbiquityContainerIdentifier: storageLocation.containerIdentifier)
            let base = container
                ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory.appendingPathComponent("ApplicationSupport", isDirectory: true)
            return base
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(appDirectoryName, isDirectory: true)
                .appendingPathComponent(workspacesDirectoryName, isDirectory: true)
        }
    }

    private nonisolated static func slug(for displayName: String) -> String {
        let allowedScalars = displayName.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }

            return "-"
        }

        let collapsed = String(allowedScalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")

        return collapsed.isEmpty ? "workspace" : collapsed
    }

    private nonisolated static func normalize(_ relativePath: String, allowEmpty: Bool) throws -> String {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if allowEmpty {
                return ""
            }
            throw ProjectStoreError.emptyPath
        }

        if trimmed.hasPrefix("/") || NSString(string: trimmed).isAbsolutePath {
            throw ProjectStoreError.absolutePathNotAllowed(relativePath)
        }

        let rawComponents = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var normalizedComponents: [String] = []

        for component in rawComponents {
            if component.isEmpty || component == "." {
                continue
            }

            if component == ".." {
                throw ProjectStoreError.parentTraversalNotAllowed(relativePath)
            }

            if component == metadataDirectoryName {
                throw ProjectStoreError.reservedPathComponent(component)
            }

            let invalidCharacters = CharacterSet.newlines.union(.illegalCharacters).union(.controlCharacters)
            if component.rangeOfCharacter(from: invalidCharacters) != nil || component.contains(":") {
                throw ProjectStoreError.invalidPathComponent(component)
            }

            normalizedComponents.append(component)
        }

        if normalizedComponents.isEmpty {
            if allowEmpty {
                return ""
            }
            throw ProjectStoreError.emptyPath
        }

        return normalizedComponents.joined(separator: "/")
    }

    private nonisolated static func readFileContents(
        at url: URL,
        relativePath: String,
        startLine: Int,
        maxLines: Int?
    ) throws -> ProjectFileContents {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ProjectStoreError.missingFile(relativePath)
        }
        guard !isDirectory.boolValue else {
            throw ProjectStoreError.expectedFile(relativePath)
        }

        guard let text = try String(contentsOf: url, encoding: .utf8) as String? else {
            throw ProjectStoreError.unreadableTextFile(relativePath)
        }

        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let allLines = normalizedText.isEmpty
            ? []
            : normalizedText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let totalLineCount = allLines.count

        guard startLine > 0 else {
            throw ProjectStoreError.invalidLineRange(start: startLine, total: totalLineCount)
        }

        if totalLineCount > 0, startLine > totalLineCount {
            throw ProjectStoreError.invalidLineRange(start: startLine, total: totalLineCount)
        }

        let requestedMaxLines = maxLines ?? totalLineCount
        let safeMaxLines = max(requestedMaxLines, 0)

        guard totalLineCount > 0, safeMaxLines > 0 else {
            return ProjectFileContents(
                relativePath: relativePath,
                text: "",
                startLine: 0,
                endLine: 0,
                totalLineCount: totalLineCount,
                isTruncated: false,
                byteCount: 0
            )
        }

        let startIndex = startLine - 1
        let endIndex = min(startIndex + safeMaxLines, totalLineCount)
        let selectedLines = Array(allLines[startIndex..<endIndex])
        let joined = selectedLines.joined(separator: "\n")

        return ProjectFileContents(
            relativePath: relativePath,
            text: joined,
            startLine: startLine,
            endLine: endIndex,
            totalLineCount: totalLineCount,
            isTruncated: endIndex < totalLineCount,
            byteCount: joined.utf8.count
        )
    }

    private nonisolated static func matchRanges(in line: String, query: String) -> [ProjectTextRange] {
        guard !line.isEmpty, !query.isEmpty else { return [] }

        var collected: [ProjectTextRange] = []
        var searchStart = line.startIndex
        let lowercasedLine = line.lowercased()
        let lowercasedQuery = query.lowercased()

        while searchStart < line.endIndex,
              let foundRange = lowercasedLine.range(of: lowercasedQuery, range: searchStart..<line.endIndex) {
            let lowerBound = lowercasedLine.distance(from: lowercasedLine.startIndex, to: foundRange.lowerBound)
            let upperBound = lowercasedLine.distance(from: lowercasedLine.startIndex, to: foundRange.upperBound)
            collected.append(ProjectTextRange(lowerBound: lowerBound, upperBound: upperBound))
            searchStart = foundRange.upperBound
        }

        return collected
    }
}

private extension JSONEncoder {
    nonisolated static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
