import SwiftUI

struct AgentView: View {
    @ObservedObject var session: AgentSession
    let workspaceInfo: WorkspaceInfo

    @State private var showingToolTrace = false
    @State private var showingSessionMenu = false

    var body: some View {
        ChatView(session: session)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // Custom title with Penrose motif
                    HStack(spacing: 8) {
                        PenroseTriangle()
                            .stroke(Color.escherInk, lineWidth: 1.5)
                            .frame(width: 18, height: 18)
                        
                        Text("PocketREPL")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.escherInk)
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
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

    private var toolTraceButton: some View {
        Button {
            showingToolTrace = true
        } label: {
            ZStack {
                Circle()
                    .fill(Color.escherPaper)
                    .frame(width: 32, height: 32)
                    .shadow(color: .escherInk.opacity(0.06), radius: 4, x: 0, y: 2)
                
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.escherInk)
            }
        }
        .accessibilityLabel("Tool Trace")
    }

    private var sessionMenuButton: some View {
        Menu {
            Section("Workspace: \(workspaceInfo.displayName)") {
                Button(role: .destructive) {
                    Task {
                        await session.resetRuntime()
                    }
                } label: {
                    Label("Reset Runtime", systemImage: "arrow.counterclockwise")
                }

                Button(role: .destructive) {
                    Task {
                        await session.newSession()
                    }
                } label: {
                    Label("New Session", systemImage: "trash")
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.escherPaper)
                    .frame(width: 32, height: 32)
                    .shadow(color: .escherInk.opacity(0.06), radius: 4, x: 0, y: 2)
                
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.escherInk)
            }
        }
    }
}

// MARK: - Tool Trace Sheet

struct ToolTraceSheet: View {
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
                        
                        Text("Tool Trace")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.escherInk)
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
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
                Text("No Tool Activity")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.escherInk)
                
                Text("Tool calls and results will appear here\nas you interact with PocketREPL.")
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
                        .foregroundStyle(Color.escherInk)

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
                    .fill(Color.escherPaper)
                
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.escherMidtone.opacity(0.1), lineWidth: 0.5)
            }
        )
        .shadow(color: .escherInk.opacity(0.04), radius: 8, x: 0, y: 4)
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
        case .call: return "Call"
        case .result: return "Result"
        case .note: return "Note"
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        AgentView(session: AppContainer.preview.agentSession, workspaceInfo: AppContainer.preview.workspaceInfo)
    }
}
