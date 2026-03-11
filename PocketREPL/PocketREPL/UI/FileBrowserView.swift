import SwiftUI

// MARK: - File Browser View

struct FileBrowserView: View {
    let projectStore: ProjectStore

    @State private var currentPath: String = ""
    @State private var entries: [ProjectFileEntry] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var selectedFile: ProjectFileEntry?
    @State private var pathHistory: [String] = []

    var body: some View {
        ZStack {
            // Background
            EscherBackground()
            
            VStack(spacing: 0) {
                // Breadcrumb path bar
                if !currentPath.isEmpty {
                    pathBar
                }
                
                // Content
                content
            }
        }
        .navigationTitle(currentPath.isEmpty ? "Files" : URL(fileURLWithPath: currentPath).lastPathComponent)
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $selectedFile) { file in
            FilePreviewSheet(projectStore: projectStore, file: file)
        }
        .task {
            await reload()
        }
        .refreshable {
            await reload()
        }
        .escherNavigationStyle()
    }
    
    // MARK: - Path Bar
    
    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    navigateToRoot()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 12, weight: .medium))
                        Text("Root")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(Color.escherPrism)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.escherPrism.opacity(0.1))
                    )
                }
                
                ForEach(pathComponents, id: \.self) { component in
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.escherMidtone)
                        
                        Text(component)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.escherInk)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
        )
    }
    
    private var pathComponents: [String] {
        currentPath.split(separator: "/").map(String.init)
    }
    
    // MARK: - Content
    
    @ViewBuilder
    private var content: some View {
        if isLoading {
            loadingView
        } else if let errorMessage {
            errorView(errorMessage)
        } else if entries.isEmpty {
            emptyView
        } else {
            fileGrid
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 20) {
            InfiniteStairs(size: 48)
            
            Text("Loading files...")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.escherMidtone)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.escherError.opacity(0.1))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(Color.escherError)
            }
            
            VStack(spacing: 8) {
                Text("Couldn't Load Files")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.escherInk)
                
                Text(message)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.escherMidtone)
                    .multilineTextAlignment(.center)
            }
            
            Button {
                Task { await reload() }
            } label: {
                Text("Try Again")
            }
            .buttonStyle(ImpossibleButtonStyle())
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var emptyView: some View {
        VStack(spacing: 24) {
            // Decorative folder with tessellation
            ZStack {
                Circle()
                    .fill(Color.escherMidtone.opacity(0.08))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "folder")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(Color.escherMidtone.opacity(0.6))
            }
            
            VStack(spacing: 8) {
                Text(currentPath.isEmpty ? "Workspace is Empty" : "Folder is Empty")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.escherInk)
                
                Text("Files will appear here as you create them\nthrough the AI assistant.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.escherMidtone)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var fileGrid: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                // Back button if in subdirectory
                if !currentPath.isEmpty {
                    backRow
                }
                
                ForEach(entries) { entry in
                    FileRow(entry: entry, onTap: { handleTap(entry) })
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
    
    private var backRow: some View {
        Button {
            navigateUp()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.escherPrism.opacity(0.1))
                        .frame(width: 40, height: 40)
                    
                    Image(systemName: "arrow.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.escherPrism)
                }
                
                Text("Back")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.escherPrism)
                
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.escherPaper.opacity(0.5))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Navigation
    
    private func handleTap(_ entry: ProjectFileEntry) {
        if entry.kind == .directory {
            navigateTo(entry.relativePath)
        } else {
            selectedFile = entry
        }
    }

    private func navigateTo(_ path: String) {
        pathHistory.append(currentPath)
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
    
    private func navigateToRoot() {
        currentPath = ""
        pathHistory.removeAll()
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
    @State private var appeared = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // File icon with geometric styling
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(iconBackgroundColor)
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: iconName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(iconColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.escherInk)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if entry.kind == .directory {
                            Text("Folder")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.escherMidtone)
                        } else if let size = entry.sizeBytes {
                            Text(formatBytes(size))
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.escherMidtone)
                        }
                        
                        // File extension badge
                        if entry.kind == .file {
                            let ext = URL(fileURLWithPath: entry.name).pathExtension.uppercased()
                            if !ext.isEmpty {
                                Text(ext)
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundStyle(iconColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(iconColor.opacity(0.15))
                                    )
                            }
                        }
                    }
                }

                Spacer()

                if entry.kind == .directory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.escherMidtone)
                }
            }
            .padding(12)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.escherPaper)
                    
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.escherMidtone.opacity(0.08), lineWidth: 0.5)
                }
            )
            .shadow(color: .escherInk.opacity(0.03), radius: 6, x: 0, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(appeared ? 1 : 0)
        .offset(x: appeared ? 0 : -8)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8).delay(Double.random(in: 0...0.1))) {
                appeared = true
            }
        }
    }

    private var iconName: String {
        if entry.kind == .directory {
            return "folder.fill"
        }

        let ext = URL(fileURLWithPath: entry.name).pathExtension.lowercased()
        switch ext {
        case "js", "mjs", "cjs", "jsx":
            return "chevron.left.forwardslash.chevron.right"
        case "json":
            return "curlybraces"
        case "md", "txt":
            return "doc.text"
        case "swift":
            return "swift"
        default:
            return "doc"
        }
    }
    
    private var iconColor: Color {
        if entry.kind == .directory {
            return .escherPrism
        }

        let ext = URL(fileURLWithPath: entry.name).pathExtension.lowercased()
        switch ext {
        case "js", "mjs", "cjs", "jsx":
            return Color(red: 0.95, green: 0.78, blue: 0.28)
        case "json":
            return .escherWarning
        case "md", "txt":
            return .escherMidtone
        case "swift":
            return Color(red: 0.95, green: 0.45, blue: 0.25)
        default:
            return .escherMidtone
        }
    }
    
    private var iconBackgroundColor: Color {
        iconColor.opacity(0.12)
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
            ZStack {
                EscherBackground()
                
                Group {
                    if isLoading {
                        VStack(spacing: 20) {
                            InfiniteStairs(size: 40)
                            Text("Loading...")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.escherMidtone)
                        }
                    } else if let errorMessage {
                        VStack(spacing: 24) {
                            ZStack {
                                Circle()
                                    .fill(Color.escherError.opacity(0.1))
                                    .frame(width: 60, height: 60)
                                
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundStyle(Color.escherError)
                            }
                            
                            Text(errorMessage)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.escherMidtone)
                                .multilineTextAlignment(.center)
                        }
                        .padding(32)
                    } else {
                        codeView
                    }
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.escherPrism)
                    }
                }
            }
            .escherNavigationStyle()
        }
        .task {
            await loadContent()
        }
    }
    
    private var codeView: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            Text(content)
                .font(.escherMono)
                .foregroundStyle(Color.escherInk)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .background(
            ZStack {
                Color.escherPaper
                
                // Subtle line numbers effect
                GeometryReader { geo in
                    Canvas { context, size in
                        let lineHeight: CGFloat = 20
                        var y: CGFloat = 20
                        while y < size.height {
                            var path = Path()
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: size.width, y: y))
                            context.stroke(path, with: .color(.escherMidtone.opacity(0.04)), lineWidth: 0.5)
                            y += lineHeight
                        }
                    }
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(16)
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
