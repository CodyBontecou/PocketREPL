import SwiftUI

// MARK: - Chat View

struct ChatView: View {
    @ObservedObject var session: AgentSession
    @State private var draft = ""
    @FocusState private var inputFocused: Bool
    @Namespace private var bottomID

    var body: some View {
        VStack(spacing: 0) {
            messageList
            inputBar
        }
        .background(Color(.systemGroupedBackground))
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

// MARK: - Preview

#Preview {
    ChatView(session: AppContainer.preview.agentSession)
}
