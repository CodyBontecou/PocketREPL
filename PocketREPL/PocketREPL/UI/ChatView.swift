import SwiftUI

// MARK: - Chat View

struct ChatView: View {
    @ObservedObject var session: AgentSession
    @State private var draft = ""
    @State private var showingAIAlert = false
    @FocusState private var inputFocused: Bool
    @Namespace private var bottomID
    @State private var messageAppearance: [UUID: Bool] = [:]

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
                messageList
                inputBar
            }
        }
        .alert("Apple Intelligence Required", isPresented: $showingAIAlert) {
            Button("Open Settings") {
                openAppleIntelligenceSettings()
            }
            Button("Continue Without AI", role: .cancel) {}
        } message: {
            Text(session.aiAvailabilityStatus + "\n\nWithout Apple Intelligence, you can still use tools manually by typing commands like:\n\nlist_files\nrun_snippet {\"code\": \"console.log('hi')\"}")
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
                        MessageBubble(message: message)
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
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.messages.count) { _, _ in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    proxy.scrollTo(bottomID)
                }
            }
            .onChange(of: session.isRunning) { _, isRunning in
                if isRunning {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        proxy.scrollTo(bottomID)
                    }
                }
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            // Keyboard toggle
            Button(action: toggleKeyboard) {
                ZStack {
                    Circle()
                        .fill(Color.escherPaper)
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: inputFocused ? "keyboard.chevron.compact.down" : "keyboard")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.escherMidtone)
                }
                .shadow(color: .escherInk.opacity(0.05), radius: 4, x: 0, y: 2)
            }
            
            // Text input with Escher styling
            TextField("Enter your message...", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.escherBody)
                .escherTextField()
                .shadow(color: .escherInk.opacity(0.15), radius: 12, x: 0, y: -4)
                .focused($inputFocused)
                .lineLimit(1...6)
                .submitLabel(.send)
                .onSubmit(sendMessage)
                .disabled(session.isRunning)

            // Send button - Penrose inspired
            Button(action: sendMessage) {
                ZStack {
                    // Outer ring
                    Circle()
                        .fill(canSend ? Color.escherInk : Color.escherMidtone.opacity(0.3))
                        .frame(width: 40, height: 40)
                    
                    // Inner impossible triangle hint
                    if canSend {
                        PenroseTriangle()
                            .stroke(Color.escherPaper, lineWidth: 1.5)
                            .frame(width: 16, height: 16)
                            .rotationEffect(.degrees(90))
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.escherPaper.opacity(0.5))
                    }
                }
                .shadow(color: canSend ? .escherInk.opacity(0.2) : .clear, radius: 8, x: 0, y: 4)
            }
            .disabled(!canSend || session.isRunning)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: canSend)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    
    private func toggleKeyboard() {
        inputFocused.toggle()
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendMessage() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        draft = ""
        Task {
            await session.send(text)
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: AgentMessage
    @State private var appeared = false

    var body: some View {
        Group {
            switch message.role {
            case .toolCall:
                ToolCallBubble(message: message)
            case .toolResult:
                ToolResultBubble(message: message)
            default:
                standardBubble
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                appeared = true
            }
        }
    }
    
    private var standardBubble: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 50)
            } else {
                // Assistant avatar - small Penrose triangle
                ZStack {
                    Circle()
                        .fill(Color.escherPaper)
                        .frame(width: 28, height: 28)
                        .shadow(color: .escherInk.opacity(0.08), radius: 4, x: 0, y: 2)
                    
                    PenroseTriangle()
                        .stroke(Color.escherInk, lineWidth: 1)
                        .frame(width: 12, height: 12)
                }
            }

            VStack(alignment: alignment, spacing: 6) {
                if message.role != .user {
                    Text(roleLabel)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.escherMidtone)
                        .tracking(1)
                }

                Text(LocalizedStringKey(message.text))
                    .font(.escherBody)
                    .textSelection(.enabled)
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
            // User bubble - dark with geometric pattern hint
            ZStack {
                EscherBubble(isUser: true)
                    .fill(Color.escherInk)
                
                // Subtle tessellation overlay
                TessellationPattern(density: 16, opacity: 0.08)
                    .clipShape(EscherBubble(isUser: true))
            }
            .shadow(color: .escherInk.opacity(0.15), radius: 8, x: 0, y: 4)
            
        case .assistant:
            // Assistant bubble - light paper texture
            ZStack {
                EscherBubble(isUser: false)
                    .fill(Color.escherPaper)
                
                EscherBubble(isUser: false)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.escherMidtone.opacity(0.15),
                                Color.escherMidtone.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            }
            .shadow(color: Color.escherInk.opacity(0.06), radius: 8, x: 0, y: 4)
            
        default:
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.escherMidtone.opacity(0.1))
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .assistant: return "PocketREPL"
        case .system: return "System"
        case .toolCall: return "Tool Call"
        case .toolResult: return "Tool Result"
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
        message.role == .user ? .escherPaper : .escherInk
    }
}

// MARK: - Tool Call Bubble

struct ToolCallBubble: View {
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
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.escherWarning)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.toolName ?? "Tool")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.escherInk)
                        
                        Text("Executing...")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.escherMidtone)
                    }
                    
                    Spacer()
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.escherMidtone)
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
                    .foregroundStyle(Color.escherMidtone)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.escherPaper)
                
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.escherWarning.opacity(0.3), lineWidth: 1)
            }
        )
        .shadow(color: .escherWarning.opacity(0.1), radius: 8, x: 0, y: 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var toolIcon: String {
        switch message.toolName {
        case "list_files": return "folder"
        case "read_file": return "doc.text"
        case "write_file": return "square.and.pencil"
        case "search_code": return "magnifyingglass"
        case "run_snippet": return "play.fill"
        case "run_file": return "play.rectangle.fill"
        default: return "wrench.fill"
        }
    }
}

// MARK: - Tool Result Bubble

struct ToolResultBubble: View {
    let message: AgentMessage
    @State private var isExpanded = false
    
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
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(statusColor)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusLabel)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(statusColor)
                    
                    if isLongOutput {
                        Text("\(message.text.count) characters")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.escherMidtone)
                    }
                }
                
                Spacer()
                
                if isLongOutput {
                    Button(action: { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { isExpanded.toggle() } }) {
                        Text(isExpanded ? "Collapse" : "Expand")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
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
                
                Text(truncatedText)
                    .font(.escherMonoSmall)
                    .foregroundStyle(Color.escherInk)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .shadow(color: statusColor.opacity(0.08), radius: 8, x: 0, y: 4)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        case .skipped: return .escherMidtone
        case .none: return .escherMidtone
        }
    }
    
    private var statusLabel: String {
        switch message.toolStatus {
        case .succeeded: return "Completed"
        case .failed: return "Failed"
        case .pending: return "Processing"
        case .skipped: return "Skipped"
        case .none: return "Result"
        }
    }
    
    private var resultBackground: Color {
        switch message.toolStatus {
        case .succeeded:
            return Color.escherSuccess.opacity(0.05)
        case .failed:
            return Color.escherError.opacity(0.05)
        default:
            return Color.escherPaper
        }
    }
}

// MARK: - Escher Typing Indicator (Infinite Stairs)

struct EscherTypingIndicator: View {
    @State private var phase: Int = 0
    
    var body: some View {
        HStack(spacing: 12) {
            InfiniteStairs(size: 32)
            
            Text("Thinking...")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.escherMidtone)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.escherPaper)
                
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.escherMidtone.opacity(0.15), lineWidth: 0.5)
            }
        )
        .shadow(color: .escherInk.opacity(0.05), radius: 8, x: 0, y: 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - AI Unavailable Banner

struct AIUnavailableBanner: View {
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
                        .font(.system(size: 16))
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apple Intelligence Unavailable")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.escherInk)
                    
                    Text("Tap for details and options")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.escherMidtone)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.escherMidtone)
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
    }
}

// MARK: - Preview

#Preview {
    ChatView(session: AppContainer.preview.agentSession)
}
