import SwiftUI
import WebKit

// MARK: - File Browser View

struct FileBrowserView: View {
    let projectStore: ProjectStore

    @State private var currentPath: String = ""
    @State private var entries: [ProjectFileEntry] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var selectedFile: ProjectFileEntry?
    @State private var pathHistory: [String] = []
    @State private var fileToDelete: ProjectFileEntry?
    @State private var isDeleting = false

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
        .navigationTitle(currentPath.isEmpty ? "" : URL(fileURLWithPath: currentPath).lastPathComponent)
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
        .alert(
            fileToDelete?.kind == .directory
                ? String(localized: "Delete Folder?")
                : String(localized: "Delete File?"),
            isPresented: Binding(
                get: { fileToDelete != nil },
                set: { if !$0 { fileToDelete = nil } }
            ),
            presenting: fileToDelete
        ) { file in
            Button(String(localized: "Cancel"), role: .cancel) {
                fileToDelete = nil
            }
            Button(String(localized: "Delete"), role: .destructive) {
                Task {
                    await deleteFile(file)
                }
            }
        } message: { file in
            if file.kind == .directory {
                Text("\"\(file.name)\" and all its contents will be permanently deleted.")
            } else {
                Text("\"\(file.name)\" will be permanently deleted.")
            }
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
                            .font(.escherCaption)
                        Text("Root", comment: "Button to navigate to root directory")
                            .font(.escherFootnote)
                    }
                    .foregroundStyle(Color.escherInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.escherMidtone.opacity(0.15))
                    )
                }
                .accessibilityLabel(String(localized: "Root folder"))
                .accessibilityHint(String(localized: "Navigate to the root directory"))
                
                ForEach(pathComponents, id: \.self) { component in
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.escherMini.weight(.bold))
                            .foregroundStyle(Color.escherSecondaryText)
                        
                        Text(component)
                            .font(.escherFootnote)
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
            
            Text("Loading files...", comment: "Loading state message for file browser")
                .font(.escherFootnote)
                .foregroundStyle(Color.escherSecondaryText)
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
                    .font(.escherDisplay)
                    .foregroundStyle(Color.escherError)
            }
            
            VStack(spacing: 8) {
                Text("Couldn't Load Files", comment: "Error title when files fail to load")
                    .font(.escherTitle)
                    .foregroundStyle(Color.escherInk)
                
                Text(message)
                    .font(.escherFootnote)
                    .foregroundStyle(Color.escherSecondaryText)
                    .multilineTextAlignment(.center)
            }
            
            Button {
                Task { await reload() }
            } label: {
                Text("Try Again", comment: "Button to retry a failed action")
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
                    .font(.escherThin)
                    .foregroundStyle(Color.escherMidtone.opacity(0.6))
            }
            
            VStack(spacing: 8) {
                Text(currentPath.isEmpty ? String(localized: "Workspace is Empty") : String(localized: "Folder is Empty"))
                    .font(.escherTitle)
                    .foregroundStyle(Color.escherInk)
                
                Text("Files will appear here as you create them\nthrough the AI assistant.", comment: "Empty state description")
                    .font(.escherFootnote)
                    .foregroundStyle(Color.escherSecondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var fileGrid: some View {
        List {
            // Back button if in subdirectory
            if !currentPath.isEmpty {
                backRow
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 16))
            }

            ForEach(entries) { entry in
                FileRow(entry: entry, onTap: { handleTap(entry) })
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            fileToDelete = entry
                        } label: {
                            Label(String(localized: "Delete"), systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
    
    private var backRow: some View {
        Button {
            navigateUp()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.escherMidtone.opacity(0.15))
                        .frame(width: 40, height: 40)
                    
                    Image(systemName: "arrow.left")
                        .font(.escherCallout.weight(.semibold))
                        .foregroundStyle(Color.escherInk)
                }
                
                Text("Back", comment: "Button to navigate to parent directory")
                    .font(.escherCallout)
                    .foregroundStyle(Color.escherInk)
                
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.escherPaper.opacity(0.5))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Go back"))
        .accessibilityHint(String(localized: "Navigate to the parent folder"))
        .accessibilityInputLabels([
            String(localized: "Back"),
            String(localized: "Go back"),
            String(localized: "Parent folder"),
            String(localized: "Up")
        ])
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

    @MainActor
    private func deleteFile(_ file: ProjectFileEntry) async {
        isDeleting = true

        do {
            try await projectStore.deleteItem(at: file.relativePath)
            // Remove from local entries with animation
            withAnimation(.easeInOut(duration: 0.25)) {
                entries.removeAll { $0.id == file.id }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isDeleting = false
        fileToDelete = nil
    }
}

// MARK: - File Row

struct FileRow: View {
    let entry: ProjectFileEntry
    let onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        .font(.escherHeadline)
                        .foregroundStyle(iconColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name)
                        .font(.escherCallout)
                        .foregroundStyle(Color.escherInk)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if entry.kind == .directory {
                            Text("Folder", comment: "Label indicating an item is a folder")
                                .font(.escherCaption)
                                .foregroundStyle(Color.escherSecondaryText)
                        } else if let size = entry.sizeBytes {
                            Text(formatBytes(size))
                                .font(.escherCaption)
                                .foregroundStyle(Color.escherSecondaryText)
                        }
                        
                        // File extension badge
                        if entry.kind == .file {
                            let ext = URL(fileURLWithPath: entry.name).pathExtension.uppercased()
                            if !ext.isEmpty {
                                Text(ext)
                                    .font(.escherMini.weight(.bold))
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
                        .font(.escherCaption.weight(.bold))
                        .foregroundStyle(Color.escherSecondaryText)
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
        .offset(x: appeared ? 0 : (reduceMotion ? 0 : -8))
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8).delay(Double.random(in: 0...0.1))) {
                    appeared = true
                }
            }
        }
        .accessibilityIdentifier("file_row_\(entry.name)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(fileAccessibilityLabel)
        .accessibilityHint(entry.kind == .directory ? String(localized: "Double-tap to open folder") : String(localized: "Double-tap to preview file"))
        .accessibilityInputLabels([entry.name, String(localized: "Open \(entry.name)")])
    }
    
    private var fileAccessibilityLabel: String {
        var parts: [String] = []
        
        if entry.kind == .directory {
            parts.append(String(localized: "Folder"))
        } else {
            let ext = URL(fileURLWithPath: entry.name).pathExtension.uppercased()
            if !ext.isEmpty {
                parts.append("\(ext) " + String(localized: "file"))
            } else {
                parts.append(String(localized: "File"))
            }
        }
        
        parts.append(entry.name)
        
        if let size = entry.sizeBytes, entry.kind != .directory {
            parts.append(formatBytes(size))
        }
        
        return parts.joined(separator: ", ")
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
        case "html", "htm":
            return "globe"
        default:
            return "doc"
        }
    }
    
    private var iconColor: Color {
        if entry.kind == .directory {
            return .escherMidtone
        }
        return .escherMidtone
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
    @State private var showingWebPreview = true
    
    private var isHTMLFile: Bool {
        let ext = URL(fileURLWithPath: file.name).pathExtension.lowercased()
        return ext == "html" || ext == "htm"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                EscherBackground()
                
                Group {
                    if isLoading {
                        VStack(spacing: 20) {
                            InfiniteStairs(size: 40)
                            Text("Loading...", comment: "Generic loading message")
                                .font(.escherFootnote)
                                .foregroundStyle(Color.escherSecondaryText)
                        }
                    } else if let errorMessage {
                        VStack(spacing: 24) {
                            ZStack {
                                Circle()
                                    .fill(Color.escherError.opacity(0.1))
                                    .frame(width: 60, height: 60)
                                
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.escherTitle)
                                    .foregroundStyle(Color.escherError)
                            }
                            
                            Text(errorMessage)
                                .font(.escherFootnote)
                                .foregroundStyle(Color.escherSecondaryText)
                                .multilineTextAlignment(.center)
                        }
                        .padding(32)
                    } else if isHTMLFile && showingWebPreview {
                        htmlPreviewView
                    } else {
                        codeView
                    }
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isHTMLFile && !isLoading && errorMessage == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingWebPreview.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showingWebPreview ? "chevron.left.forwardslash.chevron.right" : "globe")
                                    .font(.escherCaption)
                                Text(showingWebPreview ? "Code" : "Preview", comment: "Toggle between code and web preview")
                                    .font(.escherCaption)
                            }
                            .foregroundStyle(Color.escherInk)
                        }
                        .accessibilityLabel(showingWebPreview ? String(localized: "View source code") : String(localized: "View web preview"))
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done", comment: "Button to dismiss sheet")
                            .font(.escherSubheadline)
                            .foregroundStyle(Color.escherInk)
                    }
                }
            }
            .escherNavigationStyle()
        }
        .task {
            await loadContent()
        }
    }
    
    private var htmlPreviewView: some View {
        HTMLWebView(htmlContent: content, baseURL: projectStore.workspaceInfo.rootURL)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(16)
    }
    
    private var codeView: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            Text(content)
                .font(.escherMono)
                .foregroundStyle(Color.escherInk)
                .textSelection(.enabled)
                .accessibilityHint(String(localized: "Double tap and hold to select text"))
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

// MARK: - HTML Web View

struct HTMLWebView: UIViewRepresentable {
    let htmlContent: String
    let baseURL: URL?
    
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.showsHorizontalScrollIndicator = true
        webView.scrollView.showsVerticalScrollIndicator = true
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(htmlContent, baseURL: baseURL)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        FileBrowserView(projectStore: AppContainer.preview.projectStore)
    }
}
