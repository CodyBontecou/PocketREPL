import SwiftUI

// MARK: - Conversation History Sheet

struct ConversationHistorySheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var session: AgentSession
    @Environment(\.dismiss) private var dismiss
    @State private var conversationToDelete: ConversationMetadata?

    var body: some View {
        NavigationStack {
            ZStack {
                EscherBackground()

                if session.conversations.isEmpty {
                    emptyState
                } else {
                    conversationList
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.escherFootnote.weight(.semibold))
                            .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)

                        Text("History", comment: "Navigation title for conversation history")
                            .font(.escherHeadline)
                            .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done", comment: "Button to dismiss sheet")
                            .font(.escherSubheadline)
                            .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
                    }
                }
            }
            .escherNavigationStyle()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .alert(
            String(localized: "Delete Conversation?"),
            isPresented: Binding(
                get: { conversationToDelete != nil },
                set: { if !$0 { conversationToDelete = nil } }
            ),
            presenting: conversationToDelete
        ) { conversation in
            Button(String(localized: "Cancel"), role: .cancel) {
                conversationToDelete = nil
            }
            Button(String(localized: "Delete"), role: .destructive) {
                Task {
                    await session.deleteConversation(id: conversation.id)
                }
                conversationToDelete = nil
            }
        } message: { conversation in
            Text(""\(conversation.title)" will be permanently deleted.")
        }
        .task {
            await session.loadConversations()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.escherMidtone.opacity(0.08))
                    .frame(width: 120, height: 120)

                PenroseTriangle()
                    .stroke(Color.escherMidtone.opacity(0.4), lineWidth: 2)
                    .frame(width: 50, height: 50)
            }

            VStack(spacing: 8) {
                Text("No Conversations Yet", comment: "Empty state title for conversation history")
                    .font(.escherTitle)
                    .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)

                Text("Your conversation history will appear here\nas you chat with PocketREPL.", comment: "Empty state description")
                    .font(.escherFootnote)
                    .foregroundStyle(Color.escherSecondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }

    // MARK: - Conversation List

    private var conversationList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(session.conversations) { conversation in
                    ConversationRow(
                        conversation: conversation,
                        isActive: conversation.id == session.currentConversationId,
                        onTap: {
                            Task {
                                await session.loadConversation(id: conversation.id)
                                dismiss()
                            }
                        }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            conversationToDelete = conversation
                        } label: {
                            Label(String(localized: "Delete"), systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: ConversationMetadata
    let isActive: Bool
    let onTap: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // Conversation icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isActive ? Color.escherPrism.opacity(0.15) : Color.escherMidtone.opacity(0.12))
                        .frame(width: 44, height: 44)

                    Image(systemName: isActive ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                        .font(.escherCallout)
                        .foregroundStyle(isActive ? Color.escherPrism : Color.escherMidtone)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(conversation.title)
                            .font(.escherCallout)
                            .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
                            .lineLimit(1)

                        Spacer()

                        if isActive {
                            Text("Active", comment: "Label for currently active conversation")
                                .font(.escherMini.weight(.bold))
                                .foregroundStyle(Color.escherPrism)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.escherPrism.opacity(0.12))
                                )
                        }
                    }

                    HStack(spacing: 8) {
                        Text(formatDate(conversation.updatedAt))
                            .font(.escherCaption)
                            .foregroundStyle(Color.escherSecondaryText)

                        Text("\(conversation.messageCount) messages")
                            .font(.escherCaption)
                            .foregroundStyle(Color.escherSecondaryText)
                    }

                    if !conversation.preview.isEmpty {
                        Text(conversation.preview)
                            .font(.escherCaption)
                            .foregroundStyle(Color.escherSecondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(colorScheme == .dark ? Color(white: 0.10) : Color.escherPaper)

                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            isActive ? Color.escherPrism.opacity(0.3) : Color.escherMidtone.opacity(colorScheme == .dark ? 0.2 : 0.08),
                            lineWidth: isActive ? 1.5 : 0.5
                        )
                }
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.04), radius: 6, x: 0, y: 2)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(conversationAccessibilityLabel)
        .accessibilityHint(isActive
            ? String(localized: "This is the current conversation")
            : String(localized: "Double-tap to open this conversation")
        )
    }

    private var conversationAccessibilityLabel: String {
        var parts: [String] = []
        parts.append(conversation.title)
        parts.append(formatDate(conversation.updatedAt))
        parts.append("\(conversation.messageCount) " + String(localized: "messages"))
        if isActive {
            parts.append(String(localized: "Active"))
        }
        return parts.joined(separator: ", ")
    }

    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        } else if calendar.isDateInYesterday(date) {
            return String(localized: "Yesterday")
        } else if let daysAgo = calendar.dateComponents([.day], from: date, to: .now).day, daysAgo < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        } else {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
    }
}

// MARK: - Preview

#Preview {
    ConversationHistorySheet(session: AppContainer.preview.agentSession)
}
