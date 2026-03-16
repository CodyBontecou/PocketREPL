import SwiftUI

struct AgentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var session: AgentSession
    @ObservedObject var modelManager: ModelBackendManager
    var projectStore: ProjectStore? = nil
    var onModelButtonTapped: (() -> Void)? = nil

    @State private var showingFiles = false
    @State private var showingHistory = false

    var body: some View {
        ChatView(session: session, projectStore: projectStore)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    PenroseTriangle()
                        .stroke(colorScheme == .dark ? Color.escherPaper : Color.escherInk, lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if let onModelButtonTapped = onModelButtonTapped {
                            modelButton(action: onModelButtonTapped)
                        }
                        if projectStore != nil {
                            filesButton
                        }
                        historyButton
                        resetConversationButton
                    }
                }
            }
            .sheet(isPresented: $showingFiles) {
                if let projectStore = projectStore {
                    FileBrowserSheet(projectStore: projectStore)
                }
            }
            .sheet(isPresented: $showingHistory) {
                ConversationHistorySheet(session: session)
            }
            .escherNavigationStyle()
    }

    private func modelButton(action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            ModelStatusCompactView(modelManager: modelManager)
        }
        .accessibilityLabel("Model Selection")
    }
    
    private var filesButton: some View {
        Button {
            showingFiles = true
        } label: {
            ZStack {
                Circle()
                    .fill(colorScheme == .dark ? Color(white: 0.18) : Color.escherPaper)
                    .frame(width: 32, height: 32)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.06), radius: 4, x: 0, y: 2)

                Image(systemName: "folder")
                    .font(.escherFootnote)
                    .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
            }
        }
        .accessibilityLabel(String(localized: "Files"))
        .accessibilityHint(String(localized: "Browse project files and folders"))
    }

    private var historyButton: some View {
        Button {
            showingHistory = true
        } label: {
            ZStack {
                Circle()
                    .fill(colorScheme == .dark ? Color(white: 0.18) : Color.escherPaper)
                    .frame(width: 32, height: 32)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.06), radius: 4, x: 0, y: 2)

                Image(systemName: "clock.arrow.circlepath")
                    .font(.escherFootnote)
                    .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
            }
        }
        .accessibilityLabel(String(localized: "History"))
        .accessibilityHint(String(localized: "View and continue past conversations"))
    }

    private var resetConversationButton: some View {
        Button {
            Task {
                await session.newSession()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(colorScheme == .dark ? Color(white: 0.18) : Color.escherPaper)
                    .frame(width: 32, height: 32)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.06), radius: 4, x: 0, y: 2)
                
                Image(systemName: "arrow.counterclockwise")
                    .font(.escherFootnote.weight(.semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
            }
        }
        .accessibilityLabel(String(localized: "Reset Conversation"))
    }
}

// MARK: - File Browser Sheet

struct FileBrowserSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    let projectStore: ProjectStore
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            FileBrowserView(projectStore: projectStore)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .font(.escherFootnote.weight(.semibold))
                                .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
                            
                            Text("Files", comment: "Navigation title for files view")
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
        .grayscale(1.0)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        AgentView(
            session: AppContainer.preview.agentSession,
            modelManager: AppContainer.preview.modelManager
        )
    }
}
