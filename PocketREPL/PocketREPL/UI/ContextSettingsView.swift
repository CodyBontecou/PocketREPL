import SwiftUI

// MARK: - Context Settings View

struct ContextSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var session: AgentSession
    @State private var settingsManager = ContextSettingsManager.shared
    @State private var showingResetAlert = false
    @State private var showingNewSessionAlert = false
    
    private var tokens: Int { session.estimatedContextTokens }
    private var limit: Int { AgentSession.estimatedContextLimit }
    private var fraction: Double { session.contextUsageFraction }
    
    var body: some View {
        NavigationStack {
            ZStack {
                EscherBackground()
                
                ScrollView {
                    VStack(spacing: 20) {
                        // Context Usage Overview
                        contextOverviewSection
                        
                        // System Prompt Section
                        systemPromptSection
                        
                        // Tools Section
                        toolsSection
                        
                        // Actions Section
                        actionsSection
                    }
                    .padding(16)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.escherFootnote.weight(.semibold))
                            .foregroundStyle(Color.escherPrism)
                        
                        Text("Context Settings", comment: "Navigation title")
                            .font(.escherHeadline)
                            .foregroundStyle(Color.escherForeground)
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done", comment: "Button to dismiss")
                            .font(.escherSubheadline)
                            .foregroundStyle(Color.escherPrism)
                    }
                }
            }
            .escherNavigationStyle()
        }
        .presentationDragIndicator(.visible)
        .alert(String(localized: "Reset All Settings?"), isPresented: $showingResetAlert) {
            Button(String(localized: "Reset"), role: .destructive) {
                settingsManager.resetAll()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("This will reset the system prompt and enable all tools. Your current conversation will not be affected.")
        }
        .alert(String(localized: "Start New Session?"), isPresented: $showingNewSessionAlert) {
            Button(String(localized: "New Session"), role: .destructive) {
                Task {
                    await session.newSession()
                    dismiss()
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("This will clear all messages and reset the context. Your settings will be preserved.")
        }
    }
    
    // MARK: - Context Overview Section
    
    private var contextOverviewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CONTEXT USAGE", comment: "Section header")
                .font(.escherCaption2)
                .tracking(1)
                .foregroundStyle(Color.escherSecondaryText)
            
            VStack(spacing: 16) {
                // Usage bar
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(tokens) / \(limit) tokens")
                            .font(.escherCallout.weight(.semibold))
                            .foregroundStyle(Color.escherForeground)
                        
                        Spacer()
                        
                        Text("\(Int(fraction * 100))%")
                            .font(.escherCaption.weight(.semibold))
                            .foregroundStyle(statusColor)
                    }
                    
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(colorScheme == .dark ? Color(white: 0.2) : Color.escherMidtone.opacity(0.15))
                            
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(statusColor)
                                .frame(width: geo.size.width * min(fraction, 1.0))
                        }
                    }
                    .frame(height: 8)
                }
                
                // Breakdown
                VStack(spacing: 8) {
                    BreakdownRow(
                        icon: "text.bubble",
                        label: String(localized: "System Prompt"),
                        value: "~\(settingsManager.effectiveSystemPrompt.count / 4) tokens"
                    )
                    
                    BreakdownRow(
                        icon: "wrench.and.screwdriver",
                        label: String(localized: "Tool Schemas"),
                        value: "~\(settingsManager.enabledToolCount * 50) tokens (\(settingsManager.enabledToolCount) tools)"
                    )
                    
                    BreakdownRow(
                        icon: "folder",
                        label: String(localized: "Project Context"),
                        value: "~125 tokens"
                    )
                    
                    BreakdownRow(
                        icon: "bubble.left.and.bubble.right",
                        label: String(localized: "Messages"),
                        value: "\(session.messages.count) messages"
                    )
                }
                .padding(.top, 4)
            }
        }
        .padding(18)
        .escherCard()
    }
    
    private var statusColor: Color {
        if session.isContextOverLimit {
            return .escherError
        } else if session.isContextNearLimit {
            return .escherWarning
        } else {
            return .escherSuccess
        }
    }
    
    // MARK: - System Prompt Section
    
    private var systemPromptSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("SYSTEM PROMPT", comment: "Section header")
                    .font(.escherCaption2)
                    .tracking(1)
                    .foregroundStyle(Color.escherSecondaryText)
                
                Spacer()
                
                // Token estimate badge
                Text("~\(settingsManager.effectiveSystemPrompt.count / 4) tokens")
                    .font(.escherCaption2)
                    .foregroundStyle(Color.escherSecondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.escherSurface)
                    )
            }
            
            VStack(spacing: 12) {
                // Custom prompt toggle
                Toggle(isOn: $settingsManager.useCustomSystemPrompt) {
                    HStack(spacing: 10) {
                        Image(systemName: settingsManager.useCustomSystemPrompt ? "pencil.circle.fill" : "pencil.circle")
                            .font(.escherBody)
                            .foregroundStyle(settingsManager.useCustomSystemPrompt ? Color.escherPrism : Color.escherSecondaryText)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Custom Prompt", comment: "Toggle label")
                                .font(.escherCallout)
                                .foregroundStyle(Color.escherForeground)
                            
                            Text("Override the default system instructions", comment: "Toggle description")
                                .font(.escherCaption)
                                .foregroundStyle(Color.escherSecondaryText)
                        }
                    }
                }
                .toggleStyle(EscherToggleStyle())
                
                // Prompt editor (when custom is enabled)
                if settingsManager.useCustomSystemPrompt {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $settingsManager.customSystemPrompt)
                            .font(.escherMonoSmall)
                            .foregroundStyle(Color.escherForeground)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 150)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(colorScheme == .dark ? Color(white: 0.12) : Color.escherPaper)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.escherMidtone.opacity(0.2), lineWidth: 1)
                            )
                        
                        HStack {
                            Button {
                                settingsManager.customSystemPrompt = ContextSettingsManager.defaultSystemPrompt
                            } label: {
                                Label(String(localized: "Reset to Default"), systemImage: "arrow.counterclockwise")
                                    .font(.escherCaption)
                                    .foregroundStyle(Color.escherPrism)
                            }
                            
                            Spacer()
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                
                // Default prompt preview (when not using custom)
                if !settingsManager.useCustomSystemPrompt {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Default prompt:", comment: "Label for default prompt preview")
                            .font(.escherCaption)
                            .foregroundStyle(Color.escherSecondaryText)
                        
                        Text(ContextSettingsManager.defaultSystemPrompt)
                            .font(.escherMonoSmall)
                            .foregroundStyle(Color.escherSecondaryText)
                            .lineLimit(4)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(colorScheme == .dark ? Color(white: 0.08) : Color.escherMidtone.opacity(0.08))
                            )
                    }
                }
            }
        }
        .padding(18)
        .escherCard()
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: settingsManager.useCustomSystemPrompt)
    }
    
    // MARK: - Tools Section
    
    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("TOOLS", comment: "Section header")
                    .font(.escherCaption2)
                    .tracking(1)
                    .foregroundStyle(Color.escherSecondaryText)
                
                Spacer()
                
                // Quick actions
                HStack(spacing: 12) {
                    Button(String(localized: "All On")) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            settingsManager.enableAllTools()
                        }
                    }
                    .font(.escherCaption2.weight(.semibold))
                    .foregroundStyle(Color.escherPrism)
                    
                    Text("•")
                        .foregroundStyle(Color.escherSecondaryText)
                    
                    Button(String(localized: "All Off")) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            settingsManager.disableAllTools()
                        }
                    }
                    .font(.escherCaption2.weight(.semibold))
                    .foregroundStyle(Color.escherSecondaryText)
                }
            }
            
            VStack(spacing: 0) {
                ForEach(Array(settingsManager.toolConfigurations.enumerated()), id: \.element.id) { index, tool in
                    ToolToggleRow(
                        tool: tool,
                        isEnabled: tool.isEnabled
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            settingsManager.toggleTool(tool.id)
                        }
                    }
                    
                    if index < settingsManager.toolConfigurations.count - 1 {
                        Rectangle()
                            .fill(Color.escherMidtone.opacity(0.1))
                            .frame(height: 1)
                            .padding(.leading, 52)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.escherSurface.opacity(0.6))
            )
            
            // Tools info note
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.escherCaption)
                    .foregroundStyle(Color.escherSecondaryText)
                
                Text("Disabling tools reduces context usage but limits what the AI can do.", comment: "Info note about disabling tools")
                    .font(.escherCaption)
                    .foregroundStyle(Color.escherSecondaryText)
            }
            .padding(.top, 4)
        }
        .padding(18)
        .escherCard()
    }
    
    // MARK: - Actions Section
    
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ACTIONS", comment: "Section header")
                .font(.escherCaption2)
                .tracking(1)
                .foregroundStyle(Color.escherSecondaryText)
            
            VStack(spacing: 12) {
                // New Session button
                Button {
                    showingNewSessionAlert = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .font(.escherBody)
                            .foregroundStyle(Color.escherPrism)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("New Session", comment: "Button label")
                                .font(.escherCallout)
                                .foregroundStyle(Color.escherForeground)
                            
                            Text("Clear messages and reset context", comment: "Button description")
                                .font(.escherCaption)
                                .foregroundStyle(Color.escherSecondaryText)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.escherCaption)
                            .foregroundStyle(Color.escherSecondaryText)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.escherSurface.opacity(0.6))
                    )
                }
                .buttonStyle(.plain)
                
                // Reset Settings button
                Button {
                    showingResetAlert = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.escherBody)
                            .foregroundStyle(Color.escherWarning)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reset All Settings", comment: "Button label")
                                .font(.escherCallout)
                                .foregroundStyle(Color.escherForeground)
                            
                            Text("Restore default prompt and enable all tools", comment: "Button description")
                                .font(.escherCaption)
                                .foregroundStyle(Color.escherSecondaryText)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.escherCaption)
                            .foregroundStyle(Color.escherSecondaryText)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.escherSurface.opacity(0.6))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .escherCard()
    }
}

// MARK: - Breakdown Row

private struct BreakdownRow: View {
    let icon: String
    let label: String
    let value: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.escherCaption)
                .foregroundStyle(Color.escherSecondaryText)
                .frame(width: 20)
            
            Text(label)
                .font(.escherCaption)
                .foregroundStyle(Color.escherSecondaryText)
            
            Spacer()
            
            Text(value)
                .font(.escherCaption)
                .foregroundStyle(Color.escherForeground)
        }
    }
}

// MARK: - Tool Toggle Row

private struct ToolToggleRow: View {
    let tool: ToolConfiguration
    let isEnabled: Bool
    let onToggle: () -> Void
    
    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                // Tool icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isEnabled ? Color.escherPrism.opacity(0.15) : Color.escherMidtone.opacity(0.1))
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: tool.icon)
                        .font(.escherCallout)
                        .foregroundStyle(isEnabled ? Color.escherPrism : Color.escherSecondaryText)
                }
                
                // Tool info
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name)
                        .font(.escherCallout)
                        .foregroundStyle(isEnabled ? Color.escherForeground : Color.escherSecondaryText)
                    
                    Text(tool.summary)
                        .font(.escherCaption)
                        .foregroundStyle(Color.escherSecondaryText)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // Toggle indicator
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isEnabled ? Color.escherPrism : Color.escherMidtone.opacity(0.3))
                        .frame(width: 44, height: 26)
                    
                    Circle()
                        .fill(Color.white)
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                        .offset(x: isEnabled ? 9 : -9)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Escher Toggle Style

struct EscherToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            HStack {
                configuration.label
                
                Spacer()
                
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(configuration.isOn ? Color.escherPrism : Color.escherMidtone.opacity(0.3))
                        .frame(width: 44, height: 26)
                    
                    Circle()
                        .fill(Color.white)
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                        .offset(x: configuration.isOn ? 9 : -9)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview("Context Settings - Light") {
    ContextSettingsView(session: AppContainer.preview.agentSession)
        .preferredColorScheme(.light)
}

#Preview("Context Settings - Dark") {
    ContextSettingsView(session: AppContainer.preview.agentSession)
        .preferredColorScheme(.dark)
}
