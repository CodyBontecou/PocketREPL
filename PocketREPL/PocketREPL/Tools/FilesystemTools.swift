import Foundation

nonisolated struct ToolDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let summary: String

    nonisolated init(id: String, summary: String) {
        self.id = id
        self.summary = summary
    }
}

enum FilesystemTools {
    static let supportedTools: [ToolDescriptor] = [
        ToolDescriptor(id: "list_files", summary: "List files or directories inside the active workspace."),
        ToolDescriptor(id: "read_file", summary: "Read UTF-8 text from a workspace-relative file with bounded line ranges."),
        ToolDescriptor(id: "write_file", summary: "Create or overwrite a workspace-relative UTF-8 text file."),
        ToolDescriptor(id: "search_code", summary: "Search JavaScript source files in the active workspace.")
    ]
}
