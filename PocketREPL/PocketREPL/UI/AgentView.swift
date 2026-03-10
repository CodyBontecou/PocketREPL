import SwiftUI

struct AgentView: View {
    @ObservedObject var session: AgentSession
    let workspaceInfo: WorkspaceInfo

    @State private var showingToolTrace = false
    @State private var showingSessionMenu = false

    var body: some View {
        ChatView(session: session)
            .navigationTitle("PocketREPL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        toolTraceButton
                        sessionMenuButton
                    }
                }
            }
            .sheet(isPresented: $showingToolTrace) {
                ToolTraceSheet(session: session)
            }
    }

    private var toolTraceButton: some View {
        Button {
            showingToolTrace = true
        } label: {
            Image(systemName: "list.bullet.rectangle")
                .symbolRenderingMode(.hierarchical)
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
            Image(systemName: "ellipsis.circle")
                .symbolRenderingMode(.hierarchical)
        }
    }
}

// MARK: - Tool Trace Sheet

struct ToolTraceSheet: View {
    @ObservedObject var session: AgentSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if session.toolTrace.isEmpty {
                    ContentUnavailableView {
                        Label("No Tool Activity", systemImage: "wrench.and.screwdriver")
                    } description: {
                        Text("Tool calls and results will appear here as you interact with PocketREPL.")
                    }
                } else {
                    ForEach(session.toolTrace.reversed()) { event in
                        ToolTraceRow(event: event)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Tool Trace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Tool Trace Row

struct ToolTraceRow: View {
    let event: ToolTraceEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(event.toolName)
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Spacer()

                    Text(kindLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }

                Text(event.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: some View {
        Image(systemName: iconName)
            .foregroundStyle(statusColor)
            .font(.system(size: 18, weight: .medium))
    }

    private var iconName: String {
        switch event.status {
        case .pending: return "hourglass"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "arrow.uturn.forward.circle"
        }
    }

    private var statusColor: Color {
        switch event.status {
        case .pending: return .orange
        case .succeeded: return .green
        case .failed: return .red
        case .skipped: return .secondary
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
