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
    
    // MARK: - Greyscale Palette
    
    private var cardBackground: Color {
        colorScheme == .dark ? Color(white: 0.12) : Color.escherPaper
    }
    
    private var surfaceBackground: Color {
        colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.96)
    }
    
    private var borderColor: Color {
        colorScheme == .dark ? Color(white: 0.22) : Color(white: 0.85)
    }
    
    private var primaryText: Color {
        colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.1)
    }
    
    private var secondaryText: Color {
        colorScheme == .dark ? Color(white: 0.55) : Color(white: 0.45)
    }
    
    private var tertiaryText: Color {
        colorScheme == .dark ? Color(white: 0.38) : Color(white: 0.62)
    }
    
    private var accentGrey: Color {
        colorScheme == .dark ? Color(white: 0.7) : Color(white: 0.25)
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Minimal background
                surfaceBackground.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
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
                    .padding(.bottom, 20)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accentGrey)
                        
                        Text("Context Settings", comment: "Navigation title")
                            .font(.escherHeadline)
                            .foregroundStyle(primaryText)
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done", comment: "Button to dismiss")
                            .font(.escherSubheadline)
                            .foregroundStyle(primaryText)
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
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
        VStack(alignment: .leading, spacing: 16) {
            // Section header
            Text("CONTEXT USAGE")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(tertiaryText)
            
            VStack(spacing: 18) {
                // Usage display
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(tokens)")
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(primaryText)
                        
                        Text("/ \(limit) tokens")
                            .font(.escherCallout)
                            .foregroundStyle(secondaryText)
                        
                        Spacer()
                        
                        // Percentage badge
                        Text("\(Int(fraction * 100))%")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(statusColor.opacity(0.12))
                            )
                    }
                    
                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(colorScheme == .dark ? Color(white: 0.18) : Color(white: 0.88))
                            
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(statusColor)
                                .frame(width: geo.size.width * min(fraction, 1.0))
                        }
                    }
                    .frame(height: 6)
                }
                
                // Divider
                Rectangle()
                    .fill(borderColor)
                    .frame(height: 1)
                
                // Breakdown grid
                VStack(spacing: 10) {
                    GreyscaleBreakdownRow(
                        icon: "text.bubble",
                        label: String(localized: "System Prompt"),
                        value: "~\(settingsManager.effectiveSystemPrompt.count / 4)",
                        colorScheme: colorScheme
                    )
                    
                    GreyscaleBreakdownRow(
                        icon: "wrench.and.screwdriver",
                        label: String(localized: "Tool Schemas"),
                        value: "~\(settingsManager.enabledToolCount * 50)",
                        detail: "\(settingsManager.enabledToolCount) tools",
                        colorScheme: colorScheme
                    )
                    
                    GreyscaleBreakdownRow(
                        icon: "folder",
                        label: String(localized: "Project Context"),
                        value: "~125",
                        colorScheme: colorScheme
                    )
                    
                    GreyscaleBreakdownRow(
                        icon: "bubble.left.and.bubble.right",
                        label: String(localized: "Messages"),
                        value: "\(session.messages.count)",
                        detail: "messages",
                        colorScheme: colorScheme
                    )
                }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
        }
    }
    
    private var statusColor: Color {
        if session.isContextOverLimit {
            return Color.escherError
        } else if session.isContextNearLimit {
            return Color.escherWarning
        } else {
            return colorScheme == .dark ? Color(white: 0.5) : Color(white: 0.4)
        }
    }
    
    // MARK: - System Prompt Section
    
    private var systemPromptSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("SYSTEM PROMPT")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(tertiaryText)
                
                Spacer()
                
                // Token estimate
                Text("~\(settingsManager.effectiveSystemPrompt.count / 4) tokens")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(tertiaryText)
            }
            
            VStack(spacing: 14) {
                // Custom prompt toggle
                GreyscaleToggleRow(
                    icon: settingsManager.useCustomSystemPrompt ? "pencil.circle.fill" : "pencil.circle",
                    title: String(localized: "Custom Prompt"),
                    subtitle: String(localized: "Override the default system instructions"),
                    isOn: $settingsManager.useCustomSystemPrompt,
                    colorScheme: colorScheme
                )
                
                // Prompt editor (when custom is enabled)
                if settingsManager.useCustomSystemPrompt {
                    VStack(alignment: .leading, spacing: 10) {
                        TextEditor(text: $settingsManager.customSystemPrompt)
                            .font(.escherMonoSmall)
                            .foregroundStyle(primaryText)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 140)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.95))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(borderColor, lineWidth: 0.5)
                            )
                        
                        Button {
                            settingsManager.customSystemPrompt = ContextSettingsManager.defaultSystemPrompt
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("Reset to Default")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                            }
                            .foregroundStyle(secondaryText)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                
                // Default prompt preview (when not using custom)
                if !settingsManager.useCustomSystemPrompt {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Default prompt:")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(tertiaryText)
                        
                        Text(ContextSettingsManager.defaultSystemPrompt)
                            .font(.escherMonoSmall)
                            .foregroundStyle(secondaryText)
                            .lineLimit(4)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(colorScheme == .dark ? Color(white: 0.06) : Color(white: 0.94))
                            )
                    }
                }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: settingsManager.useCustomSystemPrompt)
    }
    
    // MARK: - Tools Section
    
    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("TOOLS")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(tertiaryText)
                
                Spacer()
                
                // Quick actions
                HStack(spacing: 10) {
                    Button(String(localized: "All On")) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            settingsManager.enableAllTools()
                        }
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(accentGrey)
                    
                    Text("·")
                        .foregroundStyle(tertiaryText)
                    
                    Button(String(localized: "All Off")) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            settingsManager.disableAllTools()
                        }
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(tertiaryText)
                }
            }
            
            VStack(spacing: 0) {
                ForEach(Array(settingsManager.toolConfigurations.enumerated()), id: \.element.id) { index, tool in
                    GreyscaleToolRow(
                        tool: tool,
                        isEnabled: tool.isEnabled,
                        isHybridMode: settingsManager.modelRoutingMode == .hybrid,
                        colorScheme: colorScheme
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            settingsManager.toggleTool(tool.id)
                        }
                    } onChangeAssignment: { assignment in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            settingsManager.setModelAssignment(assignment, for: tool.id)
                        }
                    }

                    if index < settingsManager.toolConfigurations.count - 1 {
                        Rectangle()
                            .fill(borderColor.opacity(0.5))
                            .frame(height: 0.5)
                            .padding(.leading, 56)
                    }
                }
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: settingsManager.modelRoutingMode)
            
            // Tools info note
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tertiaryText)

                if settingsManager.modelRoutingMode == .hybrid {
                    Text("Hybrid mode: assign each tool to Apple Intelligence or local model.")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(tertiaryText)
                } else {
                    Text("Disabling tools reduces context usage but limits capabilities.")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(tertiaryText)
                }
            }
        }
    }
    
    // MARK: - Actions Section
    
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ACTIONS")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(tertiaryText)
            
            VStack(spacing: 1) {
                // New Session button
                Button {
                    showingNewSessionAlert = true
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(colorScheme == .dark ? Color(white: 0.18) : Color(white: 0.9))
                                .frame(width: 36, height: 36)
                            
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(accentGrey)
                        }
                        
                        VStack(alignment: .leading, spacing: 3) {
                            Text("New Session")
                                .font(.escherCallout)
                                .foregroundStyle(primaryText)
                            
                            Text("Clear messages and reset context")
                                .font(.system(size: 12, weight: .regular, design: .rounded))
                                .foregroundStyle(secondaryText)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tertiaryText)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(cardBackground)
                }
                .buttonStyle(.plain)
                
                Rectangle()
                    .fill(borderColor.opacity(0.5))
                    .frame(height: 0.5)
                    .padding(.leading, 64)
                
                // Reset Settings button (destructive - keep red)
                Button {
                    showingResetAlert = true
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.escherError.opacity(0.15))
                                .frame(width: 36, height: 36)

                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.escherError)
                        }
                        
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Reset All Settings")
                                .font(.escherCallout)
                                .foregroundStyle(primaryText)
                            
                            Text("Restore default prompt and enable all tools")
                                .font(.system(size: 12, weight: .regular, design: .rounded))
                                .foregroundStyle(secondaryText)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tertiaryText)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(cardBackground)
                }
                .buttonStyle(.plain)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
        }
    }
}

// MARK: - Greyscale Breakdown Row

private struct GreyscaleBreakdownRow: View {
    let icon: String
    let label: String
    let value: String
    var detail: String? = nil
    let colorScheme: ColorScheme
    
    private var secondaryText: Color {
        colorScheme == .dark ? Color(white: 0.55) : Color(white: 0.45)
    }
    
    private var primaryText: Color {
        colorScheme == .dark ? Color(white: 0.8) : Color(white: 0.2)
    }
    
    private var tertiaryText: Color {
        colorScheme == .dark ? Color(white: 0.38) : Color(white: 0.62)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tertiaryText)
                .frame(width: 18)
            
            Text(label)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(secondaryText)
            
            Spacer()
            
            HStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(primaryText)
                
                if let detail = detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(tertiaryText)
                }
            }
        }
    }
}

// MARK: - Greyscale Toggle Row

private struct GreyscaleToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let colorScheme: ColorScheme
    
    private var primaryText: Color {
        colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.1)
    }
    
    private var secondaryText: Color {
        colorScheme == .dark ? Color(white: 0.55) : Color(white: 0.45)
    }
    
    private var accentGrey: Color {
        colorScheme == .dark ? Color(white: 0.7) : Color(white: 0.25)
    }
    
    var body: some View {
        Button(action: { isOn.toggle() }) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isOn ? primaryText : secondaryText)
                    .frame(width: 24)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.escherCallout)
                        .foregroundStyle(primaryText)
                    
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(secondaryText)
                }
                
                Spacer()
                
                // Minimal toggle
                ZStack {
                    Capsule()
                        .fill(isOn 
                              ? (colorScheme == .dark ? Color(white: 0.45) : Color(white: 0.25))
                              : (colorScheme == .dark ? Color(white: 0.22) : Color(white: 0.82)))
                        .frame(width: 46, height: 28)
                    
                    Circle()
                        .fill(Color.white)
                        .frame(width: 24, height: 24)
                        .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                        .offset(x: isOn ? 9 : -9)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Greyscale Tool Row

private struct GreyscaleToolRow: View {
    let tool: ToolConfiguration
    let isEnabled: Bool
    let isHybridMode: Bool
    let colorScheme: ColorScheme
    let onToggle: () -> Void
    let onChangeAssignment: (ModelAssignment) -> Void
    
    @State private var showingModelInfo = false

    private var primaryText: Color {
        colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.1)
    }

    private var secondaryText: Color {
        colorScheme == .dark ? Color(white: 0.55) : Color(white: 0.45)
    }

    private var tertiaryText: Color {
        colorScheme == .dark ? Color(white: 0.38) : Color(white: 0.62)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 14) {
                    // Tool icon
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isEnabled
                                  ? (colorScheme == .dark ? Color(white: 0.22) : Color(white: 0.88))
                                  : (colorScheme == .dark ? Color(white: 0.14) : Color(white: 0.94)))
                            .frame(width: 36, height: 36)

                        Image(systemName: tool.icon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(isEnabled ? primaryText : tertiaryText)
                    }

                    // Tool info
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name)
                            .font(.escherCallout)
                            .foregroundStyle(isEnabled ? primaryText : secondaryText)

                        Text(tool.summary)
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(tertiaryText)
                            .lineLimit(1)
                    }

                    Spacer()

                    // Minimal toggle
                    ZStack {
                        Capsule()
                            .fill(isEnabled
                                  ? (colorScheme == .dark ? Color(white: 0.45) : Color(white: 0.25))
                                  : (colorScheme == .dark ? Color(white: 0.22) : Color(white: 0.82)))
                            .frame(width: 46, height: 28)

                        Circle()
                            .fill(Color.white)
                            .frame(width: 24, height: 24)
                            .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                            .offset(x: isEnabled ? 9 : -9)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Model assignment picker (only in hybrid mode and if tool is enabled)
            if isHybridMode && isEnabled {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text("Model")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(tertiaryText)
                        
                        Button {
                            showingModelInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }

                    Picker("Model", selection: Binding(
                        get: { tool.modelAssignment },
                        set: { onChangeAssignment($0) }
                    )) {
                        ForEach(ModelAssignment.allCases) { assignment in
                            Text(assignment.displayName)
                                .tag(assignment)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)

                    Spacer()
                }
                .padding(.leading, 64)
                .sheet(isPresented: $showingModelInfo) {
                    ModelInfoSheet(colorScheme: colorScheme)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
                .padding(.trailing, 14)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Model Info Sheet

private struct ModelInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let colorScheme: ColorScheme
    
    private var primaryText: Color {
        colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.1)
    }
    
    private var secondaryText: Color {
        colorScheme == .dark ? Color(white: 0.55) : Color(white: 0.45)
    }
    
    private var surfaceBackground: Color {
        colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.96)
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Apple Intelligence section
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("\u{F8FF}")
                                .font(.system(size: 18))
                            Text("Apple Intelligence")
                                .font(.escherHeadline)
                                .foregroundStyle(primaryText)
                        }
                        
                        Text("Uses Apple's on-device Foundation Models. Fast, private, and optimized for Apple hardware. Best for general tasks like planning, file operations, and running code.")
                            .font(.escherBody)
                            .foregroundStyle(secondaryText)
                    }
                    
                    Divider()
                    
                    // Local Model section
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "cpu")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(primaryText)
                            Text("Local")
                                .font(.escherHeadline)
                                .foregroundStyle(primaryText)
                        }
                        
                        Text("Uses a downloaded local model (llama.cpp). Better for specialized tasks like code generation where you need more control or specific model capabilities.")
                            .font(.escherBody)
                            .foregroundStyle(secondaryText)
                    }
                    
                    Divider()
                    
                    // When to use which
                    VStack(alignment: .leading, spacing: 8) {
                        Text("When to use which?")
                            .font(.escherHeadline)
                            .foregroundStyle(primaryText)
                        
                        Text("• Use \u{F8FF} (Apple Intelligence) for most tasks — it's faster and uses less memory\n• Use Local for code generation tools that benefit from specialized coding models\n• You can mix and match per tool based on your needs")
                            .font(.escherBody)
                            .foregroundStyle(secondaryText)
                    }
                }
                .padding(20)
            }
            .background(surfaceBackground)
            .navigationTitle("Model Selection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.escherSubheadline)
                    .foregroundStyle(primaryText)
                }
            }
        }
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
