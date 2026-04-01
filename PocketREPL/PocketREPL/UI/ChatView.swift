import SwiftUI

// MARK: - Chat View

struct ChatView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var session: AgentSession
    var projectStore: ProjectStore? = nil
    @State private var draft = ""
    @State private var showingAIAlert = false
    @State private var showingPaywall = false
    @FocusState private var inputFocused: Bool
    @Namespace private var bottomID
    @State private var messageAppearance: [UUID: Bool] = [:]
    private let usageTracker = UsageTracker.shared

    var body: some View {
        ZStack {
            // Escher background
            EscherBackground()
            
            VStack(spacing: 0) {
                if !session.isAIAvailable {
                    AIUnavailableBanner(status: session.aiAvailabilityStatus) {
                        showingAIAlert = true
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                // Chat content with floating bottom controls
                ZStack(alignment: .bottom) {
                    messageList
                    
                    // Floating bottom controls
                    floatingBottomControls
                }
            }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
                .presentationDragIndicator(.visible)
                .presentationDetents([.large])
        }
        .alert(String(localized: "Apple Intelligence Required"), isPresented: $showingAIAlert) {
            Button(String(localized: "Open Settings")) {
                openAppleIntelligenceSettings()
            }
            Button(String(localized: "Continue Without AI"), role: .cancel) {}
        } message: {
            Text(session.aiAvailabilityStatus + "\n\nEnable Apple Intelligence in Settings for the primary AI path.\n\nAdvanced Offline Mode (local model downloads) is optional and available from the Models screen.")
        }
    }
    
    private func openAppleIntelligenceSettings() {
        if let url = URL(string: "prefs:root=APPLE_INTELLIGENCE") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(session.messages) { message in
                        MessageBubble(message: message, projectStore: projectStore)
                            .id(message.id)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: 10)),
                                removal: .opacity
                            ))
                    }

                    if session.isRunning {
                        EscherTypingIndicator()
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                // Extra bottom padding to account for floating input bar + context counter
                .padding(.bottom, 110)
            }
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: session.messages.count) { _, _ in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    proxy.scrollTo(bottomID)
                }
            }
            .onChange(of: session.isRunning) { oldValue, isRunning in
                if isRunning {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        proxy.scrollTo(bottomID)
                    }
                }
                // Announce state change to VoiceOver users
                if oldValue != isRunning {
                    let announcement = isRunning
                        ? String(localized: "Processing your request")
                        : String(localized: "Response received")
                    UIAccessibility.post(notification: .announcement, argument: announcement)
                }
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        let isDark = colorScheme == .dark
        
        return HStack(alignment: .bottom, spacing: 8) {
            TextField(String(localized: "Enter your message..."), text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.escherBody)
                .foregroundStyle(isDark ? Color.escherPaper : Color.escherInk)
                .focused($inputFocused)
                .lineLimit(1...6)
                .submitLabel(.send)
                .onSubmit(sendMessage)
                .disabled(session.isRunning)
                .accessibilityIdentifier("chat_message_input")
                .accessibilityLabel(String(localized: "Message input"))
                .accessibilityHint(String(localized: "Type your message to the AI assistant"))
            
            // Inline buttons
            HStack(spacing: 6) {
                // Keyboard toggle
                Button(action: toggleKeyboard) {
                    Image(systemName: inputFocused ? "keyboard.chevron.compact.down" : "keyboard")
                        .font(.escherFootnote)
                        .foregroundStyle(Color.escherSecondaryText)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(isDark ? Color(white: 0.22) : Color.escherMidtone.opacity(0.1))
                        )
                }
                .accessibilityIdentifier("chat_keyboard_toggle")
                .accessibilityLabel(inputFocused ? String(localized: "Hide keyboard") : String(localized: "Show keyboard"))
                .accessibilityHint(String(localized: "Double-tap to toggle the keyboard"))
                .accessibilityInputLabels([
                    String(localized: "Keyboard"),
                    String(localized: "Toggle keyboard"),
                    String(localized: "Hide keyboard"),
                    String(localized: "Show keyboard")
                ])
                
                // Send button (shows lock when paywall is active)
                Button(action: sendMessage) {
                    ZStack {
                        Circle()
                            .fill(
                                usageTracker.isOverLimit
                                    ? (isDark ? Color.escherPrism : Color.escherInk)
                                    : (canSend ? (isDark ? Color.escherPrism : Color.escherInk) : Color.escherMidtone.opacity(0.3))
                            )
                            .frame(width: 28, height: 28)
                        
                        if usageTracker.isOverLimit {
                            Image(systemName: "lock.fill")
                                .font(.escherCaption.weight(.bold))
                                .foregroundStyle(Color.escherPaper.opacity(0.9))
                        } else if canSend {
                            PenroseTriangle()
                                .stroke(Color.escherPaper, lineWidth: 1.2)
                                .frame(width: 11, height: 11)
                                .rotationEffect(.degrees(90))
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.escherCaption.weight(.bold))
                                .foregroundStyle(Color.escherPaper.opacity(0.5))
                        }
                    }
                }
                .disabled((!canSend && !usageTracker.isOverLimit) || session.isRunning)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: canSend)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: usageTracker.isOverLimit)
                .accessibilityIdentifier("chat_send_button")
                .accessibilityLabel(usageTracker.isOverLimit ? String(localized: "Unlock Pro to send messages") : String(localized: "Send message"))
                .accessibilityHint(usageTracker.isOverLimit ? String(localized: "Free limit reached. Tap to unlock.") : canSend ? String(localized: "Sends your message to the AI assistant") : String(localized: "Type a message first"))
                .accessibilityInputLabels([
                    String(localized: "Send"),
                    String(localized: "Send message"),
                    String(localized: "Submit")
                ])
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isDark ? Color(white: 0.14) : Color.escherPaper)
                .shadow(color: .black.opacity(isDark ? 0.4 : 0.12), radius: 12, x: 0, y: -4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.escherMidtone.opacity(isDark ? 0.2 : 0.1), lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    
    // MARK: - Floating Bottom Controls
    
    private var floatingBottomControls: some View {
        VStack(spacing: 0) {
            // Free-tier warning — shown when close to or at the limit
            if !usageTracker.isPurchased {
                freeTrialBanner
            }
            ContextCounter(session: session)
            inputBar
        }
    }
    
    // MARK: - Free Trial Banner
    
    private var freeTrialBanner: some View {
        let isDark = colorScheme == .dark
        let remaining = usageTracker.remainingFreeMessages
        let isOver = usageTracker.isOverLimit

        return Button {
            showingPaywall = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOver ? "lock.fill" : "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isOver ? Color.escherError : Color.escherWarning)
                
                if isOver {
                    Text("Free messages used up — Unlock Pro to continue")
                        .font(.escherCaption2)
                        .foregroundStyle(isOver ? Color.escherError : Color.escherSecondaryText)
                } else if remaining <= 2 {
                    Text("\(remaining) free message\(remaining == 1 ? "" : "s") left — Unlock Pro")
                        .font(.escherCaption2)
                        .foregroundStyle(Color.escherSecondaryText)
                }
                
                Spacer()
                
                Text("Upgrade →")
                    .font(.escherCaption2.weight(.semibold))
                    .foregroundStyle(Color.escherPrism)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isDark
                          ? Color(white: 0.12)
                          : Color.escherPaper.opacity(0.9))
                    .shadow(color: .black.opacity(isDark ? 0.2 : 0.04), radius: 4, x: 0, y: 2)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
        .buttonStyle(.plain)
        .opacity((isOver || remaining <= 2) ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: remaining)
    }
    
    private func toggleKeyboard() {
        if inputFocused {
            dismissKeyboard()
        } else {
            inputFocused = true
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendMessage() {
        // If over the free limit, show the paywall instead of sending
        if usageTracker.isOverLimit {
            showingPaywall = true
            return
        }

        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        draft = ""
        // Record usage before sending
        usageTracker.recordMessageSent()
        Task {
            await session.send(text)
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: AgentMessage
    var projectStore: ProjectStore? = nil
    @State private var appeared = false

    var body: some View {
        Group {
            switch message.role {
            case .toolCall:
                ToolCallBubble(message: message)
            case .toolResult:
                ToolResultBubble(message: message, projectStore: projectStore)
            default:
                standardBubble
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : (reduceMotion ? 0 : 8))
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    appeared = true
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(messageAccessibilityLabel)
    }
    
    private var messageAccessibilityLabel: String {
        let sender: String
        switch message.role {
        case .user:
            sender = String(localized: "You said")
        case .assistant:
            sender = String(localized: "PocketREPL said")
        case .system:
            sender = String(localized: "System message")
        case .toolCall:
            sender = String(localized: "Tool call")
        case .toolResult:
            sender = String(localized: "Tool result")
        }
        return "\(sender): \(message.text)"
    }
    
    private var standardBubble: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 50)
            } else {
                // Assistant avatar - small Penrose triangle
                ZStack {
                    Circle()
                        .fill(colorScheme == .dark ? Color(white: 0.18) : Color.escherPaper)
                        .frame(width: 28, height: 28)
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.08), radius: 4, x: 0, y: 2)
                    
                    PenroseTriangle()
                        .stroke(colorScheme == .dark ? Color.escherPaper : Color.escherInk, lineWidth: 1)
                        .frame(width: 12, height: 12)
                }
            }

            VStack(alignment: alignment, spacing: 6) {
                if message.role != .user {
                    Text(roleLabel)
                        .font(.escherMini.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.escherSecondaryText)
                        .tracking(1)
                }

                Text(LocalizedStringKey(message.text))
                    .font(.escherBody)
                    .textSelection(.enabled)
                    .accessibilityHint(String(localized: "Double tap and hold to select text"))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(bubbleBackground)
                    .foregroundStyle(textColor)
            }
            .frame(maxWidth: .infinity, alignment: frameAlignment)

            if message.role != .user {
                Spacer(minLength: 50)
            }
        }
    }
    
    @ViewBuilder
    private var bubbleBackground: some View {
        switch message.role {
        case .user:
            // User bubble - adapts to color scheme
            ZStack {
                EscherBubble(isUser: true)
                    .fill(colorScheme == .dark ? Color.escherPrism : Color.escherInk)
                
                // Subtle tessellation overlay
                TessellationPattern(density: 16, opacity: 0.08)
                    .clipShape(EscherBubble(isUser: true))
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.15), radius: 8, x: 0, y: 4)
            
        case .assistant:
            // Assistant bubble - adapts to color scheme
            ZStack {
                EscherBubble(isUser: false)
                    .fill(colorScheme == .dark ? Color(white: 0.10) : Color.escherPaper)
                
                EscherBubble(isUser: false)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.escherMidtone.opacity(colorScheme == .dark ? 0.25 : 0.15),
                                Color.escherMidtone.opacity(colorScheme == .dark ? 0.10 : 0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.06), radius: 8, x: 0, y: 4)
            
        default:
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.escherMidtone.opacity(0.1))
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .assistant: return "PocketREPL"
        case .system: return String(localized: "System")
        case .toolCall: return String(localized: "Tool Call")
        case .toolResult: return String(localized: "Tool Result")
        case .user: return ""
        }
    }

    private var alignment: HorizontalAlignment {
        message.role == .user ? .trailing : .leading
    }

    private var frameAlignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private var textColor: Color {
        message.role == .user ? .escherPaper : (colorScheme == .dark ? .escherPaper : .escherInk)
    }
}

// MARK: - Tool Call Bubble

struct ToolCallBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: AgentMessage
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with impossible geometry accent
            Button(action: { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { isExpanded.toggle() } }) {
                HStack(spacing: 10) {
                    // Tool icon in geometric frame
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.escherWarning.opacity(0.15))
                            .frame(width: 28, height: 28)
                        
                        Image(systemName: toolIcon)
                            .font(.escherCaption.weight(.semibold))
                            .foregroundStyle(Color.escherWarning)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.toolName ?? "Tool")
                            .font(.escherFootnote.weight(.semibold))
                            .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
                        
                        Text(executingStatusText)
                            .font(.escherCaption2)
                            .foregroundStyle(Color.escherSecondaryText)
                    }
                    
                    Spacer()
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.escherMini.weight(.bold))
                        .foregroundStyle(Color.escherSecondaryText)
                        .rotationEffect(.degrees(isExpanded ? 0 : 0))
                }
                .padding(12)
            }
            .buttonStyle(.plain)
            
            // Expandable parameters
            if isExpanded, let params = message.toolParameters, !params.isEmpty {
                Rectangle()
                    .fill(Color.escherMidtone.opacity(0.1))
                    .frame(height: 1)
                    .padding(.horizontal, 12)
                
                Text(params)
                    .font(.escherMonoSmall)
                    .foregroundStyle(Color.escherSecondaryText)
                    .textSelection(.enabled)
                    .accessibilityHint(String(localized: "Double tap and hold to select text"))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(colorScheme == .dark ? Color(white: 0.10) : Color.escherPaper)

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.escherWarning.opacity(0.3), lineWidth: 1)
            }
        )
        .shadow(color: .escherWarning.opacity(colorScheme == .dark ? 0.2 : 0.1), radius: 8, x: 0, y: 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(toolCallAccessibilityLabel)
        .accessibilityHint(String(localized: "Double-tap to \(isExpanded ? "collapse" : "expand") parameters"))
    }
    
    private var toolCallAccessibilityLabel: String {
        let toolName = message.toolName ?? String(localized: "Unknown tool")
        if let params = message.toolParameters, !params.isEmpty, isExpanded {
            return String(localized: "Executing \(toolName) with parameters: \(params)")
        }
        return String(localized: "Executing \(toolName)")
    }
    
    private var toolIcon: String {
        switch message.toolName {
        case "list_files": return "folder"
        case "read_file": return "doc.text"
        case "write_file": return "square.and.pencil"
        case "search_code": return "magnifyingglass"
        case "run_snippet": return "play.fill"
        case "run_file": return "play.rectangle.fill"
        case "generate_code", "fix_code": return "cpu"
        default: return "wrench.fill"
        }
    }
    
    /// Status text shown while a tool is executing
    private var executingStatusText: String {
        switch message.toolName {
        case "generate_code":
            return String(localized: "Generating code with llama.cpp...")
        case "fix_code":
            return String(localized: "Fixing code with llama.cpp...")
        default:
            return String(localized: "Executing...")
        }
    }
}

// MARK: - Tool Result Bubble

struct ToolResultBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: AgentMessage
    var projectStore: ProjectStore? = nil
    @State private var isExpanded = false
    @State private var selectedFilePath: String?
    
    private var isLongOutput: Bool {
        message.text.count > 150 || message.text.components(separatedBy: "\n").count > 5
    }
    
    private var truncatedText: String {
        if isLongOutput && !isExpanded {
            let lines = message.text.components(separatedBy: "\n")
            if lines.count > 3 {
                return lines.prefix(3).joined(separator: "\n") + "\n..."
            }
            return String(message.text.prefix(150)) + "..."
        }
        return message.text
    }

    /// Binding to convert selectedFilePath to ProjectFileEntry for sheet presentation
    private var selectedFileEntry: Binding<ProjectFileEntry?> {
        Binding(
            get: {
                guard let path = selectedFilePath else { return nil }
                let name = URL(fileURLWithPath: path).lastPathComponent
                return ProjectFileEntry(
                    relativePath: path,
                    name: name,
                    kind: .file,
                    sizeBytes: nil,
                    modifiedAt: nil
                )
            },
            set: { newValue in
                selectedFilePath = newValue?.relativePath
            }
        )
    }

    /// The output content - interactive with tappable file links when projectStore is available
    @ViewBuilder
    private var outputContent: some View {
        if projectStore != nil {
            InteractiveToolOutput(
                text: truncatedText,
                toolName: message.toolName,
                onFileTap: { path in
                    selectedFilePath = path
                }
            )
            .accessibilityHint(String(localized: "Contains tappable file paths. Double tap and hold to select text"))
        } else {
            Text(truncatedText)
                .font(.escherMonoSmall)
                .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
                .textSelection(.enabled)
                .accessibilityHint(String(localized: "Double tap and hold to select text"))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with status
            HStack(spacing: 10) {
                // Status indicator with geometric styling
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(statusColor.opacity(0.15))
                        .frame(width: 28, height: 28)
                    
                    Image(systemName: statusIcon)
                        .font(.escherCaption.weight(.bold))
                        .foregroundStyle(statusColor)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(statusLabel)
                            .font(.escherFootnote.weight(.semibold))
                            .foregroundStyle(statusColor)
                        
                        // Show llama.cpp badge for code generation tools
                        if isCodeGenerationTool && message.toolStatus == .succeeded {
                            Text("llama.cpp")
                                .font(.escherMini.weight(.bold))
                                .foregroundStyle(Color.escherMidtone)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.escherMidtone.opacity(0.15))
                                )
                        }
                    }
                    
                    if isLongOutput {
                        Text("\(message.text.count) characters", comment: "Shows character count")
                            .font(.escherCaption2)
                            .foregroundStyle(Color.escherSecondaryText)
                    }
                }
                
                Spacer()
                
                if isLongOutput {
                    Button(action: { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { isExpanded.toggle() } }) {
                        Text(isExpanded ? String(localized: "Collapse") : String(localized: "Expand"))
                            .font(.escherCaption2.weight(.semibold))
                            .foregroundStyle(Color.escherPrism)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(Color.escherPrism.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            
            // Output
            if !message.text.isEmpty {
                Rectangle()
                    .fill(Color.escherMidtone.opacity(0.1))
                    .frame(height: 1)
                    .padding(.horizontal, 12)

                outputContent
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(item: selectedFileEntry) { file in
            if let projectStore = projectStore {
                FilePreviewSheet(projectStore: projectStore, file: file)
            }
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(resultBackground)
                
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(statusColor.opacity(0.25), lineWidth: 1)
            }
        )
        .shadow(color: statusColor.opacity(colorScheme == .dark ? 0.15 : 0.08), radius: 8, x: 0, y: 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(resultAccessibilityLabel)
        .accessibilityHint(isLongOutput ? String(localized: "Double-tap to \(isExpanded ? "collapse" : "expand") full output") : "")
    }
    
    private var resultAccessibilityLabel: String {
        let status = statusLabel
        if message.text.isEmpty {
            return String(localized: "Tool result: \(status)")
        }
        let displayText = isExpanded || !isLongOutput ? message.text : truncatedText
        return String(localized: "Tool result: \(status). Output: \(displayText)")
    }
    
    private var statusIcon: String {
        switch message.toolStatus {
        case .succeeded: return "checkmark"
        case .failed: return "xmark"
        case .pending: return "ellipsis"
        case .skipped: return "arrow.right"
        case .none: return "circle"
        }
    }
    
    private var statusColor: Color {
        switch message.toolStatus {
        case .succeeded: return .escherSuccess
        case .failed: return .escherError
        case .pending: return .escherWarning
        case .skipped: return .escherSecondaryText
        case .none: return .escherSecondaryText
        }
    }
    
    private var statusLabel: String {
        // Special label for code generation tools
        if isCodeGenerationTool {
            switch message.toolStatus {
            case .succeeded: return String(localized: "Code Generated")
            case .failed: return String(localized: "Generation Failed")
            case .pending: return String(localized: "Generating...")
            default: break
            }
        }
        
        switch message.toolStatus {
        case .succeeded: return String(localized: "Completed")
        case .failed: return String(localized: "Failed")
        case .pending: return String(localized: "Processing")
        case .skipped: return String(localized: "Skipped")
        case .none: return String(localized: "Result")
        }
    }
    
    /// Whether this is a code generation tool (uses local llama.cpp model)
    private var isCodeGenerationTool: Bool {
        message.toolName == "generate_code" || message.toolName == "fix_code"
    }
    
    private var resultBackground: Color {
        let baseColor: Color = {
            switch message.toolStatus {
            case .succeeded:
                return Color.escherSuccess
            case .failed:
                return Color.escherError
            default:
                return colorScheme == .dark ? Color(white: 0.10) : Color.escherPaper
            }
        }()
        
        switch message.toolStatus {
        case .succeeded, .failed:
            return baseColor.opacity(colorScheme == .dark ? 0.15 : 0.05)
        default:
            return baseColor
        }
    }
}

// MARK: - Escher Typing Indicator (Infinite Stairs)

struct EscherTypingIndicator: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var phase: Int = 0
    
    var body: some View {
        HStack(spacing: 12) {
            InfiniteStairs(size: 32)
            
            Text("Thinking...", comment: "Shown while AI is processing")
                .font(.escherFootnote)
                .foregroundStyle(Color.escherSecondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(colorScheme == .dark ? Color(white: 0.10) : Color.escherPaper)

                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.escherMidtone.opacity(colorScheme == .dark ? 0.25 : 0.15), lineWidth: 0.5)
            }
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.05), radius: 8, x: 0, y: 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "AI is thinking"))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - AI Unavailable Banner

struct AIUnavailableBanner: View {
    @Environment(\.colorScheme) private var colorScheme
    let status: String
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // Warning icon with geometric frame
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.escherWarning.opacity(0.15))
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.escherWarning)
                        .font(.escherCallout)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apple Intelligence Unavailable", comment: "Banner title when AI is not available")
                        .font(.escherSubheadline)
                        .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
                    
                    Text("Tap for details and options", comment: "Banner subtitle prompting user to tap")
                        .font(.escherCaption)
                        .foregroundStyle(Color.escherSecondaryText)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.escherCaption.weight(.bold))
                    .foregroundStyle(Color.escherSecondaryText)
            }
            .padding(14)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                    
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.escherWarning.opacity(0.3), lineWidth: 1)
                }
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Apple Intelligence Unavailable"))
        .accessibilityHint(String(localized: "Double-tap to see details and options for enabling AI features"))
    }
}

// MARK: - Context Counter

struct ContextCounter: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var session: AgentSession
    @State private var showingSettings = false
    
    // Foundation Models (primary - agent conversation)
    private var fmTokens: Int { session.estimatedContextTokens }
    private var fmLimit: Int { session.effectiveContextLimit }
    private var fmFraction: Double { session.contextUsageFraction }
    private var fmIsRealTracking: Bool { session.isUsingRealContextTracking }
    
    // Local Model (llama.cpp - used to generate code)
    private var localTokens: Int? { session.localModelTokens }
    private var localLimit: Int? { session.localModelLimit }
    private var localFraction: Double? {
        guard let tokens = localTokens, let limit = localLimit, limit > 0 else { return nil }
        return Double(tokens) / Double(limit)
    }
    private var showLocalModel: Bool { session.isLocalModelActive && session.isLocalModelContextActive }
    
    private var statusColor: Color {
        if session.isContextOverLimit {
            return .escherError
        } else if session.isContextNearLimit {
            return .escherWarning
        } else {
            return .escherSecondaryText
        }
    }
    
    private var localStatusColor: Color {
        guard let fraction = localFraction else { return .escherSecondaryText }
        if fraction > 1.0 { return .escherError }
        if fraction > 0.7 { return .escherWarning }
        return .escherMidtone
    }
    
    var body: some View {
        Button(action: { showingSettings = true }) {
            HStack(spacing: 6) {
                // Foundation Models progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(colorScheme == .dark ? Color(white: 0.2) : Color.escherMidtone.opacity(0.15))
                        
                        Capsule()
                            .fill(statusColor)
                            .frame(width: geo.size.width * min(fmFraction, 1.0))
                    }
                }
                .frame(width: 32, height: 4)
                
                // Foundation Models token count with live indicator
                HStack(spacing: 2) {
                    // Live tracking indicator (filled circle when using real session data)
                    Circle()
                        .fill(fmIsRealTracking ? statusColor : statusColor.opacity(0.3))
                        .frame(width: 4, height: 4)
                    
                    Text("\(fmTokens)/\(fmLimit)")
                        .font(.escherMonoMini)
                        .foregroundStyle(statusColor)
                }
                
                // Local model indicator (when active)
                if showLocalModel, let localTok = localTokens, let localLim = localLimit {
                    Text("•")
                        .font(.escherMonoMini)
                        .foregroundStyle(Color.escherSecondaryText.opacity(0.5))
                    
                    HStack(spacing: 2) {
                        Circle()
                            .fill(localStatusColor)
                            .frame(width: 4, height: 4)
                        
                        Text("\(localTok)/\(localLim)")
                            .font(.escherMonoMini)
                            .foregroundStyle(localStatusColor)
                    }
                }
                
                // Settings indicator
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(colorScheme == .dark ? Color(white: 0.12) : Color.escherPaper.opacity(0.8))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.05), radius: 4, x: 0, y: 2)
            )
            .overlay(
                Capsule()
                    .strokeBorder(statusColor.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(contextAccessibilityLabel)
        .accessibilityHint(String(localized: "Double-tap to customize context settings, system prompt, and tools"))
        .sheet(isPresented: $showingSettings) {
            ContextSettingsView(session: session)
        }
    }
    
    private var contextAccessibilityLabel: String {
        let percentage = Int(fmFraction * 100)
        let statusDescription: String
        if session.isContextOverLimit {
            statusDescription = String(localized: "over limit")
        } else if session.isContextNearLimit {
            statusDescription = String(localized: "near limit")
        } else {
            statusDescription = String(localized: "OK")
        }
        let trackingType = fmIsRealTracking ? String(localized: "live") : String(localized: "estimated")
        
        var label = String(localized: "Agent context: \(fmTokens) of \(fmLimit) tokens, \(percentage) percent, status \(statusDescription), \(trackingType) tracking")
        
        // Add local model info if active (llama.cpp for code generation)
        if showLocalModel, let localTok = localTokens, let localLim = localLimit {
            let localPct = Int((localFraction ?? 0) * 100)
            label += String(localized: ". Code generation model (llama.cpp): \(localTok) of \(localLim) tokens, \(localPct) percent")
        }
        
        return label
    }
}

// MARK: - Preview

#Preview {
    ChatView(session: AppContainer.preview.agentSession)
}
