import SwiftUI

struct AgentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var session: AgentSession
    @ObservedObject var modelManager: ModelBackendManager
    let workspaceInfo: WorkspaceInfo
    let onModelButtonTapped: () -> Void

    @State private var showingToolTrace = false
    @State private var showingSessionMenu = false

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
                        modelButton
                        toolTraceButton
                        sessionMenuButton
                    }
                }
            }
            .sheet(isPresented: $showingToolTrace) {
                ToolTraceSheet(session: session)
            }
            .escherNavigationStyle()
    }

    private var modelButton: some View {
        Button {
            onModelButtonTapped()
        } label: {
            ModelStatusCompactView(modelManager: modelManager)
        }
        .accessibilityLabel("Model Selection")
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
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
            }
        }
        .accessibilityLabel(String(localized: "Tool Trace"))
    }

    private var sessionMenuButton: some View {
        Menu {
            Section(String(localized: "Workspace: \(workspaceInfo.displayName)")) {
                Button(role: .destructive) {
                    Task {
                        await session.resetRuntime()
                    }
                } label: {
                    Label(String(localized: "Reset Runtime"), systemImage: "arrow.counterclockwise")
                }

                Button(role: .destructive) {
                    Task {
                        await session.newSession()
                    }
                } label: {
                    Label(String(localized: "New Session"), systemImage: "trash")
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(colorScheme == .dark ? Color(white: 0.18) : Color.escherPaper)
                    .frame(width: 32, height: 32)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.06), radius: 4, x: 0, y: 2)
                
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
            }
        }
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
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.escherPrism)
                        
                        Text("Tool Trace", comment: "Navigation title for tool trace view")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done", comment: "Button to dismiss sheet")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
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
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
                
                Text("Tool calls and results will appear here\nas you interact with PocketREPL.", comment: "Empty state description")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.escherMidtone)
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
                    .font(.system(size: 14, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(event.toolName)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)

                    Spacer()

                    Text(kindLabel)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
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
                    .foregroundStyle(Color.escherMidtone)
                    .lineLimit(4)
            }
        }
        .padding(14)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(colorScheme == .dark ? Color(red: 0.14, green: 0.12, blue: 0.16) : Color.escherPaper)
                
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
        case .skipped: return .escherMidtone
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
            modelManager: AppContainer.preview.modelManager,
            workspaceInfo: AppContainer.preview.workspaceInfo,
            onModelButtonTapped: {}
        )
    }
}
