import SwiftUI

// MARK: - Chat View

struct ChatView: View {
    @ObservedObject var session: AgentSession
    @State private var draft = ""
    @State private var showingAIAlert = false
    @FocusState private var inputFocused: Bool
    @Namespace private var bottomID

    var body: some View {
        VStack(spacing: 0) {
            if !session.isAIAvailable {
                AIUnavailableBanner(status: session.aiAvailabilityStatus) {
                    showingAIAlert = true
                }
            }
            messageList
            inputBar
        }
        .background(Color(.systemGroupedBackground))
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
        // Deep link to Apple Intelligence & Siri settings
        if let url = URL(string: "prefs:root=APPLE_INTELLIGENCE") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(session.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if session.isRunning {
                        TypingIndicator()
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: session.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(bottomID)
                }
            }
            .onChange(of: session.isRunning) { _, isRunning in
                if isRunning {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(bottomID)
                    }
                }
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(alignment: .bottom, spacing: 12) {
                // Keyboard toggle button
                Button(action: toggleKeyboard) {
                    Image(systemName: inputFocused ? "keyboard.chevron.compact.down" : "keyboard")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .focused($inputFocused)
                    .lineLimit(1...5)
                    .submitLabel(.send)
                    .onSubmit(sendMessage)
                    .disabled(session.isRunning)

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(canSend ? Color.accentColor : .secondary)
                }
                .disabled(!canSend || session.isRunning)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
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

    var body: some View {
        switch message.role {
        case .toolCall:
            ToolCallBubble(message: message)
        case .toolResult:
            ToolResultBubble(message: message)
        default:
            standardBubble
        }
    }
    
    private var standardBubble: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 60)
            }

            VStack(alignment: alignment, spacing: 4) {
                if message.role != .user {
                    Text(roleLabel)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                }

                Text(LocalizedStringKey(message.text))
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleColor)
                    .foregroundStyle(textColor)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: frameAlignment)

            if message.role != .user {
                Spacer(minLength: 60)
            }
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

    private var bubbleColor: Color {
        switch message.role {
        case .user:
            return Color.accentColor
        case .assistant:
            return Color(.secondarySystemGroupedBackground)
        case .system:
            return Color(.tertiarySystemGroupedBackground)
        case .toolCall, .toolResult:
            return Color(.tertiarySystemGroupedBackground)
        }
    }

    private var textColor: Color {
        message.role == .user ? .white : .primary
    }
}

// MARK: - Tool Call Bubble

struct ToolCallBubble: View {
    let message: AgentMessage
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: toolIcon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.orange)
                        .frame(width: 20)
                    
                    Text(message.toolName ?? "Tool")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    
                    Spacer()
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            
            // Expandable parameters
            if isExpanded, let params = message.toolParameters, !params.isEmpty {
                Divider()
                    .padding(.horizontal, 12)
                
                Text(params)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
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
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(statusColor)
                    .frame(width: 16)
                
                Text(statusLabel)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(statusColor)
                
                Spacer()
                
                if isLongOutput {
                    Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                        Text(isExpanded ? "Show less" : "Show more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
            
            // Output
            if !message.text.isEmpty {
                Divider()
                    .padding(.horizontal, 12)
                
                Text(truncatedText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(resultBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(statusColor.opacity(0.3), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var statusIcon: String {
        switch message.toolStatus {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .pending: return "clock.fill"
        case .skipped: return "forward.fill"
        case .none: return "circle.fill"
        }
    }
    
    private var statusColor: Color {
        switch message.toolStatus {
        case .succeeded: return .green
        case .failed: return .red
        case .pending: return .orange
        case .skipped: return .gray
        case .none: return .secondary
        }
    }
    
    private var statusLabel: String {
        switch message.toolStatus {
        case .succeeded: return "Success"
        case .failed: return "Failed"
        case .pending: return "Running..."
        case .skipped: return "Skipped"
        case .none: return "Result"
        }
    }
    
    private var resultBackground: Color {
        switch message.toolStatus {
        case .succeeded:
            return Color(.systemGreen).opacity(0.08)
        case .failed:
            return Color(.systemRed).opacity(0.08)
        default:
            return Color(.tertiarySystemGroupedBackground)
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var animationOffset = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 8, height: 8)
                    .opacity(animationOffset == index ? 1.0 : 0.4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: false)) {
                startAnimation()
            }
        }
    }

    private func startAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            animationOffset = (animationOffset + 1) % 3
        }
    }
}

// MARK: - AI Unavailable Banner

struct AIUnavailableBanner: View {
    let status: String
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 20))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Intelligence Unavailable")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    
                    Text("Tap for details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    ChatView(session: AppContainer.preview.agentSession)
}
