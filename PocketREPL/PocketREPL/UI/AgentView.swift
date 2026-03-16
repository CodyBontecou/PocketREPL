import SwiftUI

struct AgentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var session: AgentSession
    @ObservedObject var modelManager: ModelBackendManager
    var projectStore: ProjectStore? = nil
    var onModelButtonTapped: (() -> Void)? = nil

    @State private var showingToolTrace = false
    @State private var showingFiles = false

    var body: some View {
        ChatView(session: session)
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
                        toolTraceButton
                        resetConversationButton
                    }
                }
            }
            .sheet(isPresented: $showingToolTrace) {
                ToolTraceSheet(session: session)
            }
            .sheet(isPresented: $showingFiles) {
                if let projectStore = projectStore {
                    FileBrowserSheet(projectStore: projectStore)
                }
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
    
    private var toolTraceButton: some View {
        Button {
            showingToolTrace = true
        } label: {
            ZStack {
                Circle()
                    .fill(colorScheme == .dark ? Color(white: 0.18) : Color.escherPaper)
                    .frame(width: 32, height: 32)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.06), radius: 4, x: 0, y: 2)
                
                Image(systemName: "list.bullet.rectangle")
                    .font(.escherFootnote)
                    .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
            }
        }
        .accessibilityLabel(String(localized: "Tool Trace"))
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

// MARK: - Tool Trace Sheet

struct ToolTraceSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var session: AgentSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                EscherBackground()
                
                if session.toolTrace.isEmpty {
                    emptyState
                } else {
                    traceList
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.escherFootnote.weight(.semibold))
                            .foregroundStyle(Color.escherPrism)
                        
                        Text("Tool Trace", comment: "Navigation title for tool trace view")
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
                            .foregroundStyle(Color.escherPrism)
                    }
                }
            }
            .escherNavigationStyle()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    
    private var emptyState: some View {
        VStack(spacing: 24) {
            // Decorative impossible shape
            ZStack {
                Circle()
                    .fill(Color.escherMidtone.opacity(0.08))
                    .frame(width: 120, height: 120)
                
                PenroseTriangle()
                    .stroke(Color.escherMidtone.opacity(0.4), lineWidth: 2)
                    .frame(width: 50, height: 50)
            }
            
            VStack(spacing: 8) {
                Text("No Tool Activity", comment: "Empty state title for tool trace")
                    .font(.escherTitle)
                    .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
                
                Text("Tool calls and results will appear here\nas you interact with PocketREPL.", comment: "Empty state description")
                    .font(.escherFootnote)
                    .foregroundStyle(Color.escherSecondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }
    
    private var traceList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(session.toolTrace.reversed()) { event in
                    ToolTraceRow(event: event)
                }
            }
            .padding(16)
        }
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

// MARK: - Tool Trace Row

struct ToolTraceRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let event: ToolTraceEvent
    @State private var appeared = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Status icon with geometric frame
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                
                Image(systemName: iconName)
                    .foregroundStyle(statusColor)
                    .font(.escherFootnote.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(event.toolName)
                        .font(.escherSubheadline)
                        .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)

                    Spacer()

                    Text(kindLabel)
                        .font(.escherMini.weight(.bold))
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(statusColor.opacity(0.12))
                        )
                }

                Text(event.summary)
                    .font(.escherMonoSmall)
                    .foregroundStyle(Color.escherSecondaryText)
                    .lineLimit(4)
            }
        }
        .padding(14)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(colorScheme == .dark ? Color(white: 0.10) : Color.escherPaper)

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.escherMidtone.opacity(colorScheme == .dark ? 0.2 : 0.1), lineWidth: 0.5)
            }
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.04), radius: 8, x: 0, y: 4)
        .opacity(appeared ? 1 : 0)
        .offset(x: appeared ? 0 : -10)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                appeared = true
            }
        }
    }

    private var iconName: String {
        switch event.status {
        case .pending: return "hourglass"
        case .succeeded: return "checkmark"
        case .failed: return "xmark"
        case .skipped: return "arrow.uturn.forward"
        }
    }

    private var statusColor: Color {
        switch event.status {
        case .pending: return .escherWarning
        case .succeeded: return .escherSuccess
        case .failed: return .escherError
        case .skipped: return .escherSecondaryText
        }
    }

    private var kindLabel: String {
        switch event.kind {
        case .call: return String(localized: "Call")
        case .result: return String(localized: "Result")
        case .note: return String(localized: "Note")
        }
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
