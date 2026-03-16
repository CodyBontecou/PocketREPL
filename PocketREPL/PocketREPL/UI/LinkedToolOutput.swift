import SwiftUI

// MARK: - File Path Parsing

/// Represents a parsed line with optional file path
struct ParsedOutputLine: Identifiable {
    let id = UUID()
    let prefix: String      // Text before the file path
    let filePath: String?   // The file path (if any)
    let suffix: String      // Text after the file path
}

/// Parses tool output to identify file paths that can be made tappable
struct FilePathLinker {

    /// Parse tool output into lines with identified file paths
    static func parseLines(_ text: String, toolName: String?) -> [ParsedOutputLine] {
        let lines = text.components(separatedBy: "\n")
        return lines.enumerated().map { index, line in
            parseLine(line, toolName: toolName, isFirstLine: index == 0)
        }
    }

    private static func parseLine(_ line: String, toolName: String?, isFirstLine: Bool) -> ParsedOutputLine {
        switch toolName {
        case "list_files":
            return parseListFilesLine(line, isFirstLine: isFirstLine)
        case "read_file":
            return parseReadFileLine(line)
        case "write_file":
            return parseWriteFileLine(line)
        case "search_code":
            return parseSearchCodeLine(line)
        default:
            return ParsedOutputLine(prefix: line, filePath: nil, suffix: "")
        }
    }

    // MARK: - Tool-Specific Line Parsers

    /// Parse list_files line: "path/" (dir) or "path (1 KB)" (file)
    private static func parseListFilesLine(_ line: String, isFirstLine: Bool) -> ParsedOutputLine {
        // First line is header
        if isFirstLine || line.hasPrefix("Contents of") || line.hasPrefix("No files") {
            return ParsedOutputLine(prefix: line, filePath: nil, suffix: "")
        }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return ParsedOutputLine(prefix: line, filePath: nil, suffix: "")
        }

        // Directory: ends with /
        if trimmed.hasSuffix("/") {
            let path = String(trimmed.dropLast())
            return ParsedOutputLine(prefix: "", filePath: path, suffix: "/")
        }

        // File with size: "filename (1 KB)"
        if let parenIndex = trimmed.lastIndex(of: "(") {
            let beforeParen = trimmed[..<parenIndex].trimmingCharacters(in: .whitespaces)
            let sizeInfo = String(trimmed[parenIndex...])
            return ParsedOutputLine(prefix: "", filePath: beforeParen, suffix: " \(sizeInfo)")
        }

        // Plain filename (shouldn't happen normally, but handle it)
        return ParsedOutputLine(prefix: "", filePath: trimmed, suffix: "")
    }

    /// Parse read_file line: "File: path (lines X-Y of Z)"
    private static func parseReadFileLine(_ line: String) -> ParsedOutputLine {
        // Match "File: path" at start of line
        if line.hasPrefix("File: ") {
            let afterPrefix = line.dropFirst(6) // "File: ".count
            // Find where path ends (space or paren)
            if let spaceIndex = afterPrefix.firstIndex(where: { $0 == " " || $0 == "(" }) {
                let path = String(afterPrefix[..<spaceIndex])
                let suffix = String(afterPrefix[spaceIndex...])
                return ParsedOutputLine(prefix: "File: ", filePath: path, suffix: suffix)
            }
            // Entire rest is path
            return ParsedOutputLine(prefix: "File: ", filePath: String(afterPrefix), suffix: "")
        }
        return ParsedOutputLine(prefix: line, filePath: nil, suffix: "")
    }

    /// Parse write_file line: "Wrote path (N lines, N bytes)"
    private static func parseWriteFileLine(_ line: String) -> ParsedOutputLine {
        if line.hasPrefix("Wrote ") {
            let afterPrefix = line.dropFirst(6) // "Wrote ".count
            // Find where path ends (space before paren)
            if let spaceIndex = afterPrefix.firstIndex(where: { $0 == " " }) {
                let path = String(afterPrefix[..<spaceIndex])
                let suffix = String(afterPrefix[spaceIndex...])
                return ParsedOutputLine(prefix: "Wrote ", filePath: path, suffix: suffix)
            }
            return ParsedOutputLine(prefix: "Wrote ", filePath: String(afterPrefix), suffix: "")
        }
        return ParsedOutputLine(prefix: line, filePath: nil, suffix: "")
    }

    /// Parse search_code line: file paths appear as "path:" on their own lines
    private static func parseSearchCodeLine(_ line: String) -> ParsedOutputLine {
        // Skip indented lines (match results)
        if line.hasPrefix(" ") || line.hasPrefix("\t") {
            return ParsedOutputLine(prefix: line, filePath: nil, suffix: "")
        }

        // Skip header lines
        if line.hasPrefix("Found ") || line.contains("match") {
            return ParsedOutputLine(prefix: line, filePath: nil, suffix: "")
        }

        // File paths end with ":"
        if line.hasSuffix(":") && line.count > 1 {
            let path = String(line.dropLast())
            return ParsedOutputLine(prefix: "", filePath: path, suffix: ":")
        }

        return ParsedOutputLine(prefix: line, filePath: nil, suffix: "")
    }
}

// MARK: - Interactive Tool Output View

/// A view that renders tool output with tappable file path links
struct InteractiveToolOutput: View {
    let text: String
    let toolName: String?
    let onFileTap: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var parsedLines: [ParsedOutputLine] {
        FilePathLinker.parseLines(text, toolName: toolName)
    }

    private var textColor: Color {
        colorScheme == .dark ? Color.escherPaper : Color.escherInk
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(parsedLines) { line in
                lineView(line)
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: ParsedOutputLine) -> some View {
        HStack(spacing: 0) {
            // Prefix text
            if !line.prefix.isEmpty {
                Text(line.prefix)
                    .font(.escherMonoSmall)
                    .foregroundStyle(textColor)
            }

            // File path (tappable)
            if let path = line.filePath {
                Button {
                    onFileTap(path)
                } label: {
                    Text(path)
                        .font(.escherMonoSmall)
                        .foregroundStyle(Color.escherPrism)
                        .underline()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "File: \(path)"))
                .accessibilityHint(String(localized: "Tap to preview this file"))
            }

            // Suffix text
            if !line.suffix.isEmpty {
                Text(line.suffix)
                    .font(.escherMonoSmall)
                    .foregroundStyle(textColor)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
