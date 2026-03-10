import SwiftUI

// MARK: - File Browser View

struct FileBrowserView: View {
    let projectStore: ProjectStore

    @State private var currentPath: String = ""
    @State private var entries: [ProjectFileEntry] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var selectedFile: ProjectFileEntry?

    var body: some View {
        List(selection: $selectedFile) {
            if !currentPath.isEmpty {
                Button {
                    navigateUp()
                } label: {
                    Label {
                        Text("Back")
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "chevron.left")
                    }
                }
                .listRowBackground(Color.clear)
            }

            if isLoading {
                ProgressView("Loading files…")
            } else if let errorMessage {
                ContentUnavailableView(
                    "Couldn't load files",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if entries.isEmpty {
                ContentUnavailableView(
                    currentPath.isEmpty ? "Workspace is empty" : "Folder is empty",
                    systemImage: "folder",
                    description: Text("Files will appear here as you create them.")
                )
            } else {
                ForEach(entries) { entry in
                    FileRow(entry: entry, onTap: { handleTap(entry) })
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(currentPath.isEmpty ? "Files" : URL(fileURLWithPath: currentPath).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedFile) { file in
            FilePreviewSheet(projectStore: projectStore, file: file)
        }
        .task {
            await reload()
        }
        .refreshable {
            await reload()
        }
    }

    private func handleTap(_ entry: ProjectFileEntry) {
        if entry.kind == .directory {
            navigateTo(entry.relativePath)
        } else {
            selectedFile = entry
        }
    }

    private func navigateTo(_ path: String) {
        currentPath = path
        Task {
            await reload()
        }
    }

    private func navigateUp() {
        let components = currentPath.split(separator: "/").dropLast()
        currentPath = components.joined(separator: "/")
        Task {
            await reload()
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        errorMessage = nil

        do {
            _ = try await projectStore.createWorkspaceIfNeeded()
            entries = try await projectStore.listFiles(in: currentPath)
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - File Row

struct FileRow: View {
    let entry: ProjectFileEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 22))
                    .foregroundStyle(iconColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.body)
                        .foregroundStyle(.primary)

                    if let size = entry.sizeBytes, entry.kind == .file {
                        Text(formatBytes(size))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if entry.kind == .directory {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        if entry.kind == .directory {
            return "folder.fill"
        }

        let ext = URL(fileURLWithPath: entry.name).pathExtension.lowercased()
        switch ext {
        case "js", "mjs", "cjs", "jsx":
            return "doc.text.fill"
        case "json":
            return "curlybraces"
        case "md", "txt":
            return "doc.plaintext"
        default:
            return "doc"
        }
    }

    private var iconColor: Color {
        if entry.kind == .directory {
            return .accentColor
        }

        let ext = URL(fileURLWithPath: entry.name).pathExtension.lowercased()
        switch ext {
        case "js", "mjs", "cjs", "jsx":
            return .yellow
        case "json":
            return .orange
        default:
            return .secondary
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes / (1024 * 1024)) MB"
    }
}

// MARK: - File Preview Sheet

struct FilePreviewSheet: View {
    let projectStore: ProjectStore
    let file: ProjectFileEntry

    @Environment(\.dismiss) private var dismiss
    @State private var content: String = ""
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Couldn't read file",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else {
                    ScrollView {
                        Text(content)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await loadContent()
        }
    }

    @MainActor
    private func loadContent() async {
        isLoading = true
        errorMessage = nil

        do {
            let fileContent = try await projectStore.readFile(at: file.relativePath)
            content = fileContent.text.isEmpty ? "(empty file)" : fileContent.text
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        FileBrowserView(projectStore: AppContainer.preview.projectStore)
    }
}
