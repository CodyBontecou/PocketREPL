import SwiftUI

// MARK: - Documentation View

struct DocsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedSections: Set<DocSection> = []
    
    enum DocSection: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case foundationModel = "Foundation Model"
        case localModel = "Local Model"
        case contextLimits = "Context Limits"
        case tools = "Tools"
        case workspace = "Workspace"
        case runtime = "JavaScript Runtime"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .overview: return "info.circle"
            case .foundationModel: return "apple.logo"
            case .localModel: return "cpu"
            case .contextLimits: return "slider.horizontal.3"
            case .tools: return "wrench.and.screwdriver"
            case .workspace: return "folder"
            case .runtime: return "play"
            }
        }
    }
    
    var body: some View {
        ZStack {
            EscherBackground()
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        // Header
                        headerSection
                        
                        // Documentation Sections
                        ForEach(DocSection.allCases) { section in
                            DocSectionCard(
                                section: section,
                                isExpanded: expandedSections.contains(section),
                                onToggle: {
                                    let isExpanding = !expandedSections.contains(section)
                                    
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        if expandedSections.contains(section) {
                                            expandedSections.remove(section)
                                        } else {
                                            expandedSections.insert(section)
                                        }
                                    }
                                    
                                    // Scroll to show the accordion header at top when expanding
                                    if isExpanding {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                                proxy.scrollTo(section.id, anchor: .top)
                                            }
                                        }
                                    }
                                }
                            )
                            .id(section.id)
                        }
                        
                        // Footer
                        footerSection
                    }
                    .padding(16)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .escherNavigationStyle()
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.escherMidtone.opacity(0.1))
                    .frame(width: 72, height: 72)
                
                Image(systemName: "book.closed")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.escherForeground)
            }
            
            Text("Documentation", comment: "Documentation header")
                .font(.escherTitle)
                .foregroundStyle(Color.escherForeground)
            
            Text("Learn how PocketREPL works", comment: "Documentation subtitle")
                .font(.escherCallout)
                .foregroundStyle(Color.escherSecondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 20)
    }
    
    // MARK: - Footer
    
    private var footerSection: some View {
        Spacer()
            .frame(height: 40)
    }
}

// MARK: - Documentation Section Card

struct DocSectionCard: View {
    let section: DocsView.DocSection
    let isExpanded: Bool
    let onToggle: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (always visible)
            Button(action: onToggle) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.escherMidtone.opacity(0.15))
                            .frame(width: 36, height: 36)
                        
                        Image(systemName: section.icon)
                            .font(.escherCallout)
                            .foregroundStyle(Color.escherForeground)
                    }
                    
                    Text(section.rawValue)
                        .font(.escherHeadline)
                        .foregroundStyle(Color.escherForeground)
                    
                    Spacer()
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.escherCaption.weight(.semibold))
                        .foregroundStyle(Color.escherSecondaryText)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            // Content (expanded)
            if isExpanded {
                Divider()
                    .background(Color.escherMidtone.opacity(0.2))
                
                sectionContent
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .escherCard()
    }
    
    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .overview:
            OverviewContent()
        case .foundationModel:
            FoundationModelContent()
        case .localModel:
            LocalModelContent()
        case .contextLimits:
            ContextLimitsContent()
        case .tools:
            ToolsContent()
        case .workspace:
            WorkspaceContent()
        case .runtime:
            RuntimeContent()
        }
    }
}

// MARK: - Content Sections

struct OverviewContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DocParagraph("""
            PocketREPL is an AI-powered JavaScript coding environment that runs entirely on your device. \
            It combines intelligent code assistance with a sandboxed JavaScript runtime.
            """)
            
            DocSubheading("Key Features")
            
            DocBulletList([
                "On-device AI models — no internet required",
                "Write, run, and debug JavaScript code",
                "AI-assisted code generation and fixing",
                "File management with search capabilities",
                "Context-aware assistance using your project files"
            ])
            
            DocSubheading("How It Works")
            
            DocParagraph("""
            When you send a message, the AI analyzes your request and can use various tools to help you: \
            reading files, writing code, searching your project, and executing JavaScript. \
            The AI sees error messages and can iteratively fix issues.
            """)
        }
    }
}

struct FoundationModelContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DocParagraph("""
            PocketREPL uses Apple's Foundation Models framework to run AI inference directly on your device \
            using Apple Intelligence. This is the primary and recommended model.
            """)
            
            DocSubheading("Requirements")
            
            DocBulletList([
                "iOS 26.0 or later",
                "Device with Apple Intelligence support",
                "Apple Intelligence enabled in Settings"
            ])
            
            DocSubheading("Capabilities")
            
            DocBulletList([
                "Optimized for Apple Silicon",
                "Fast, low-latency responses",
                "No data leaves your device",
                "Supports all PocketREPL tools",
                "Multi-turn conversation context"
            ])
            
            DocSubheading("How It's Used")
            
            DocParagraph("""
            When available, the Foundation Model handles all chat interactions. It receives your messages \
            along with project context and tool definitions. The model can call tools iteratively to \
            accomplish complex tasks.
            """)
        }
    }
}

struct LocalModelContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DocParagraph("""
            For code generation tasks, PocketREPL can use downloadable local models based on llama.cpp. \
            These models are specifically trained for coding tasks and run via GPU acceleration.
            """)
            
            DocSubheading("Available Models")
            
            DocCodeBlock("""
            • Qwen 2.5 Coder (0.5B, 1.5B, 3B)
              - Optimized for code generation
              - Smaller variants for older devices
            
            • DeepSeek Coder (1.3B)
              - Specialized for code completion
            """)
            
            DocSubheading("Model Management")
            
            DocBulletList([
                "Download models from the Models tab",
                "Models are stored locally on device",
                "Load/unload to manage memory",
                "Last used model auto-loads on launch"
            ])
            
            DocSubheading("Memory Considerations")
            
            DocParagraph("""
            Local models require significant memory. The app automatically unloads models when the system \
            is under memory pressure. Larger models (3B+) may not work on devices with limited RAM.
            """)
            
            DocSubheading("Tools Integration")
            
            DocParagraph("""
            Two tools use the local model: 'generate_code' creates new code from descriptions, \
            and 'fix_code' repairs broken code using error messages. The Foundation Model orchestrates \
            when to call these tools.
            """)
        }
    }
}

struct ContextLimitsContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DocParagraph("""
            AI models have limited "context windows" — the amount of text they can process at once. \
            PocketREPL manages this carefully to maximize what the AI can see and do.
            """)
            
            DocSubheading("Context Budget")
            
            DocCodeBlock("""
            • System prompt: ~300-500 tokens
            • Tool definitions: ~200 tokens per tool
            • Project manifest: ~50-200 tokens
            • Conversation history: Variable
            • File contents: Up to 100 lines default
            """)
            
            DocSubheading("Automatic Truncation")
            
            DocBulletList([
                "File reads capped at 100 lines by default",
                "Tool output limited to 2000 characters",
                "Console output limited to 30 entries",
                "Search results capped at 20 matches",
                "File listings limited to 30 entries"
            ])
            
            DocSubheading("Customization")
            
            DocParagraph("""
            Tap the context counter in the chat view to customize the system prompt and enable/disable \
            individual tools. Disabling unused tools frees up context space.
            """)
            
            DocSubheading("Token Estimation")
            
            DocParagraph("""
            Roughly 1 token ≈ 4 characters of English text. Code often uses more tokens due to \
            punctuation and special characters. The context counter shows approximate token usage.
            """)
        }
    }
}

struct ToolsContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DocParagraph("""
            Tools extend what the AI can do. The model can call tools to interact with your project, \
            run code, and get information.
            """)
            
            DocSubheading("File Tools")
            
            DocToolEntry(
                name: "list_files",
                icon: "folder",
                description: "Lists files and directories in the workspace. Returns names, types, and sizes."
            )
            
            DocToolEntry(
                name: "read_file",
                icon: "doc.text",
                description: "Reads text content from a file. Supports line range selection (default limit: 100 lines)."
            )
            
            DocToolEntry(
                name: "write_file",
                icon: "square.and.pencil",
                description: "Creates or overwrites a file with new content."
            )
            
            DocToolEntry(
                name: "search_code",
                icon: "magnifyingglass",
                description: "Searches JavaScript files for text patterns. Returns matching lines with context."
            )
            
            DocSubheading("Execution Tools")
            
            DocToolEntry(
                name: "run_snippet",
                icon: "play.fill",
                description: "Executes inline JavaScript code and returns the result."
            )
            
            DocToolEntry(
                name: "run_file",
                icon: "play.rectangle.fill",
                description: "Executes a JavaScript file from the workspace."
            )
            
            DocSubheading("AI Tools")
            
            DocToolEntry(
                name: "generate_code",
                icon: "wand.and.stars",
                description: "Uses the local coding model to generate code from a description."
            )
            
            DocToolEntry(
                name: "fix_code",
                icon: "wrench.fill",
                description: "Uses the local coding model to fix broken code using error messages."
            )
        }
    }
}

struct WorkspaceContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DocParagraph("""
            Your workspace is a sandboxed directory where all your JavaScript files live. \
            The AI can see and modify files within this workspace.
            """)
            
            DocSubheading("File Structure")
            
            DocCodeBlock("""
            PocketREPL/
            ├── main.js          # Entry point
            ├── utils/
            │   └── helpers.js   # Utility functions
            └── tests/
                └── test.js      # Test files
            """)
            
            DocSubheading("Supported Operations")
            
            DocBulletList([
                "Create new files and folders",
                "Read and edit existing files",
                "Delete files (swipe in Files tab)",
                "Search across all JavaScript files",
                "View file sizes and line counts"
            ])
            
            DocSubheading("Project Context")
            
            DocParagraph("""
            The AI automatically receives a "project manifest" containing your file tree and recent activity. \
            This helps it understand your project structure without reading every file.
            """)
            
            DocSubheading("Persistence")
            
            DocParagraph("""
            Your workspace persists between app launches. Files are stored in the app's sandboxed container.
            """)
        }
    }
}

struct RuntimeContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DocParagraph("""
            PocketREPL includes a JavaScript runtime powered by JavaScriptCore. \
            Code runs in a sandboxed environment with a subset of standard JavaScript features.
            """)
            
            DocSubheading("Supported Features")
            
            DocBulletList([
                "ES6+ syntax (let, const, arrow functions)",
                "Classes and modules",
                "Promises and async/await",
                "Standard built-ins (Array, Object, String, etc.)",
                "JSON parsing and serialization",
                "Math operations",
                "console.log() for output"
            ])
            
            DocSubheading("Limitations")
            
            DocBulletList([
                "No network access (fetch, XMLHttpRequest)",
                "No DOM or browser APIs",
                "No Node.js APIs (fs, path, etc.)",
                "No timers (setTimeout, setInterval)",
                "Limited to ~30 seconds execution time"
            ])
            
            DocSubheading("Console Output")
            
            DocCodeBlock("""
            console.log("Hello!")    // Standard output
            console.warn("Warning")  // Warning level
            console.error("Error")   // Error level
            """)
            
            DocSubheading("Error Handling")
            
            DocParagraph("""
            Runtime errors are captured and categorized (syntax errors, type errors, reference errors, etc.). \
            The AI sees these categorized errors and can use them to fix code.
            """)
        }
    }
}

// MARK: - Documentation Components

struct DocParagraph: View {
    let text: String
    
    init(_ text: String) {
        self.text = text
    }
    
    var body: some View {
        Text(text)
            .font(.escherCallout)
            .foregroundStyle(Color.escherForeground)
            .lineSpacing(4)
    }
}

struct DocSubheading: View {
    let text: String
    
    init(_ text: String) {
        self.text = text
    }
    
    var body: some View {
        Text(text)
            .font(.escherSubheadline.weight(.semibold))
            .foregroundStyle(Color.escherForeground)
            .padding(.top, 8)
    }
}

struct DocBulletList: View {
    let items: [String]
    
    init(_ items: [String]) {
        self.items = items
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 10) {
                    Text("•")
                        .font(.escherCallout)
                        .foregroundStyle(Color.escherSecondaryText)
                    
                    Text(item)
                        .font(.escherCallout)
                        .foregroundStyle(Color.escherForeground)
                }
            }
        }
    }
}

struct DocCodeBlock: View {
    let code: String
    
    init(_ code: String) {
        self.code = code
    }
    
    var body: some View {
        Text(code)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Color.escherForeground)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.escherSurface)
            )
    }
}

struct DocToolEntry: View {
    let name: String
    let icon: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.escherCaption)
                .foregroundStyle(Color.escherSecondaryText)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(Color.escherForeground)
                
                Text(description)
                    .font(.escherCaption)
                    .foregroundStyle(Color.escherSecondaryText)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview("Docs - Light") {
    NavigationStack {
        DocsView()
    }
    .preferredColorScheme(.light)
}

#Preview("Docs - Dark") {
    NavigationStack {
        DocsView()
    }
    .preferredColorScheme(.dark)
}
