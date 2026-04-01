import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var appearanceManager = AppearanceManager.shared
    @State private var showingMailCompose = false
    @State private var showingPaywall = false
    @State private var paywallManager = PaywallManager.shared
    private let usageTracker = UsageTracker.shared

    var body: some View {
        NavigationStack {
            ZStack {
                EscherBackground()
                
                ScrollView {
                    VStack(spacing: 20) {
                        // Pro Section
                        proSection

                        // Appearance Section
                        appearanceSection
                        
                        // AI Section
                        aiSection
                        
                        // Support Section
                        supportSection
                        
                        // About Section
                        aboutSection
                    }
                    .padding(16)
                }
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
                    .presentationDragIndicator(.visible)
                    .presentationDetents([.large])
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape.fill")
                            .font(.escherFootnote.weight(.semibold))
                            .foregroundStyle(Color.escherSecondaryText)
                        
                        Text("Settings", comment: "Navigation title for settings")
                            .font(.escherHeadline)
                            .foregroundStyle(Color.escherForeground)
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done", comment: "Button to dismiss settings")
                            .font(.escherSubheadline)
                            .foregroundStyle(Color.escherForeground)
                    }
                }
            }
            .escherNavigationStyle()
        }
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showingMailCompose) {
            MailComposeView()
        }
    }
    
    // MARK: - Pro Section

    private var proSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PRO", comment: "Section header for pro/upgrade settings")
                .font(.escherCaption2)
                .tracking(1)
                .foregroundStyle(Color.escherSecondaryText)

            VStack(spacing: 0) {
                if usageTracker.isPurchased {
                    // Already unlocked
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.escherSuccess.opacity(0.15))
                                .frame(width: 40, height: 40)
                            Image(systemName: "checkmark.seal.fill")
                                .font(.escherBody)
                                .foregroundStyle(Color.escherSuccess)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("PocketREPL Pro", comment: "Pro unlock status title")
                                .font(.escherCallout)
                                .foregroundStyle(Color.escherForeground)
                            Text("Unlimited access unlocked", comment: "Pro unlock status subtitle")
                                .font(.escherCaption)
                                .foregroundStyle(Color.escherSecondaryText)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.escherSuccess)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                } else {
                    // Upgrade row
                    Button {
                        showingPaywall = true
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(colorScheme == .dark
                                          ? Color(white: 0.16)
                                          : Color.escherMidtone.opacity(0.10))
                                    .frame(width: 40, height: 40)
                                PenroseTriangle()
                                    .stroke(
                                        colorScheme == .dark ? Color.escherPaper : Color.escherInk,
                                        style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)
                                    )
                                    .frame(width: 18, height: 18)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Upgrade to Pro", comment: "Upgrade to pro button title")
                                    .font(.escherCallout)
                                    .foregroundStyle(Color.escherForeground)
                                let remaining = usageTracker.remainingFreeMessages
                                Text("\(remaining) free message\(remaining == 1 ? "" : "s") remaining", comment: "Shows remaining free messages")
                                    .font(.escherCaption)
                                    .foregroundStyle(remaining == 0 ? Color.escherError : Color.escherSecondaryText)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.escherCaption.weight(.semibold))
                                .foregroundStyle(Color.escherSecondaryText)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Rectangle()
                        .fill(Color.escherMidtone.opacity(0.15))
                        .frame(height: 1)
                        .padding(.leading, 56)

                    // Restore row
                    Button {
                        Task { await paywallManager.restorePurchases() }
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(colorScheme == .dark
                                          ? Color(white: 0.16)
                                          : Color.escherMidtone.opacity(0.10))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "arrow.clockwise")
                                    .font(.escherBody)
                                    .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
                            }
                            Text("Restore Purchases", comment: "Restore purchases button title")
                                .font(.escherCallout)
                                .foregroundStyle(Color.escherForeground)
                            Spacer()
                            if paywallManager.isPurchasing {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(paywallManager.isPurchasing)

                    if let error = paywallManager.purchaseError {
                        Text(error)
                            .font(.escherCaption)
                            .foregroundStyle(Color.escherError)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.escherSurface.opacity(0.6))
            )
        }
        .padding(18)
        .escherCard()
        .task {
            await paywallManager.loadProducts()
            await paywallManager.checkExistingEntitlements()
        }
    }

    // MARK: - Appearance Section
    
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("APPEARANCE", comment: "Section header for appearance settings")
                .font(.escherCaption2)
                .tracking(1)
                .foregroundStyle(Color.escherSecondaryText)
            
            VStack(spacing: 12) {
                // Mode Picker
                HStack(spacing: 8) {
                    ForEach(AppearanceMode.allCases) { mode in
                        AppearanceModeButton(
                            mode: mode,
                            isSelected: appearanceManager.mode == mode
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                appearanceManager.mode = mode
                            }
                        }
                    }
                }
                
                // Preview
                AppearancePreview(colorScheme: colorScheme)
            }
        }
        .padding(18)
        .escherCard()
    }
    
    // MARK: - AI Section

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI", comment: "Section header for AI settings")
                .font(.escherCaption2)
                .tracking(1)
                .foregroundStyle(Color.escherSecondaryText)

            // Model Routing Section
            modelRoutingSection

            VStack(spacing: 0) {
                // Context Settings Row - Note: Opens via the context counter in chat
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .font(.escherBody)
                        .foregroundStyle(Color.escherSecondaryText)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Context Settings", comment: "Row title for context settings")
                            .font(.escherCallout)
                            .foregroundStyle(Color.escherForeground)

                        Text("Tap the context counter in chat to customize", comment: "Row subtitle")
                            .font(.escherCaption)
                            .foregroundStyle(Color.escherSecondaryText)
                    }

                    Spacer()

                    // Token count indicator
                    let settings = ContextSettingsManager.shared
                    Text("~\(settings.estimatedBaseTokens) tokens")
                        .font(.escherCaption)
                        .foregroundStyle(Color.escherSecondaryText)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.escherSurface.opacity(0.6))
            )

            // Info note
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.escherCaption)
                    .foregroundStyle(Color.escherSecondaryText)

                Text("Customize the AI's system prompt and enable/disable tools from the context counter.", comment: "Info text for AI section")
                    .font(.escherCaption)
                    .foregroundStyle(Color.escherSecondaryText)
            }
            .padding(.top, 4)
        }
        .padding(18)
        .escherCard()
    }

    // MARK: - Model Routing Section

    @State private var settingsManager = ContextSettingsManager.shared

    private var modelRoutingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MODEL ROUTING", comment: "Section header for model routing")
                .font(.escherCaption2)
                .tracking(1)
                .foregroundStyle(Color.escherSecondaryText)

            VStack(spacing: 0) {
                ForEach(ModelRoutingMode.allCases) { mode in
                    ModelRoutingModeRow(
                        mode: mode,
                        isSelected: settingsManager.modelRoutingMode == mode,
                        isAvailable: isModeAvailable(mode),
                        unavailabilityReason: unavailabilityReason(for: mode)
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            settingsManager.modelRoutingMode = mode
                        }
                    }

                    if mode != ModelRoutingMode.allCases.last {
                        Rectangle()
                            .fill(Color.escherMidtone.opacity(0.15))
                            .frame(height: 1)
                            .padding(.leading, 56)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.escherSurface.opacity(0.6))
            )

            if settingsManager.isAppleIntelligenceCapableDevice {
                HStack(spacing: 8) {
                    Image(systemName: settingsManager.advancedOfflineModeEnabled ? "cpu" : "lock.fill")
                        .foregroundStyle(Color.escherSecondaryText)
                    Text(settingsManager.advancedOfflineModeEnabled
                         ? String(localized: "Advanced Offline Mode is enabled. Local model routing is available.")
                         : String(localized: "Advanced Offline Mode is off. Enable it in the Models screen to unlock local model routing."))
                        .font(.escherCaption)
                        .foregroundStyle(Color.escherSecondaryText)
                }
                .padding(.top, 4)
            }

            // Availability warning if needed
            if !settingsManager.isFoundationModelsAvailable
                && settingsManager.modelRoutingMode == .foundationModelOnly {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.escherMidtone)
                    Text(settingsManager.foundationModelsUnavailabilityReason ?? String(localized: "Unavailable"))
                        .font(.escherCaption)
                        .foregroundStyle(Color.escherSecondaryText)
                }
                .padding(.top, 4)
            }
        }
        .padding(.bottom, 12)
        .onAppear {
            enforceSupportedRoutingSelection()
        }
        .onChange(of: settingsManager.advancedOfflineModeEnabled) { _, _ in
            enforceSupportedRoutingSelection()
        }
    }

    private func enforceSupportedRoutingSelection() {
        if settingsManager.shouldGateLocalModelDownloads,
           settingsManager.modelRoutingMode != .foundationModelOnly {
            settingsManager.modelRoutingMode = .foundationModelOnly
        }
    }

    private func isModeAvailable(_ mode: ModelRoutingMode) -> Bool {
        switch mode {
        case .foundationModelOnly:
            return true
        case .localModelOnly, .hybrid:
            return !settingsManager.shouldGateLocalModelDownloads
        }
    }

    private func unavailabilityReason(for mode: ModelRoutingMode) -> String? {
        switch mode {
        case .foundationModelOnly:
            return settingsManager.foundationModelsUnavailabilityReason
        case .localModelOnly, .hybrid:
            if settingsManager.shouldGateLocalModelDownloads {
                return String(localized: "Enable Advanced Offline Mode in Models to use local routing")
            }
            return nil
        }
    }
    
    // MARK: - Support Section
    
    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SUPPORT", comment: "Section header for support options")
                .font(.escherCaption2)
                .tracking(1)
                .foregroundStyle(Color.escherSecondaryText)
            
            Button {
                if FeedbackHelper.canSendMail {
                    showingMailCompose = true
                } else if let url = FeedbackHelper.mailtoURL() {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack {
                    Image(systemName: "envelope.fill")
                        .font(.escherBody)
                        .foregroundStyle(Color.escherSecondaryText)
                    
                    Text("Send Feedback", comment: "Button to send feedback email")
                        .font(.escherCallout)
                        .foregroundStyle(Color.escherForeground)
                    
                    Spacer()
                    
                    Image(systemName: "arrow.up.right")
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
        .padding(18)
        .escherCard()
    }
    
    // MARK: - About Section
    
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ABOUT", comment: "Section header for about information")
                .font(.escherCaption2)
                .tracking(1)
                .foregroundStyle(Color.escherSecondaryText)
            
            VStack(spacing: 0) {
                AboutRow(label: String(localized: "Version"), value: appVersion)
                AboutDivider()
                AboutRow(label: String(localized: "Build"), value: buildNumber)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.escherSurface.opacity(0.6))
            )
        }
        .padding(18)
        .escherCard()
    }
    
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

// MARK: - Appearance Mode Button

struct AppearanceModeButton: View {
    let mode: AppearanceMode
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? Color.escherForeground.opacity(0.12) : Color.escherSurface)
                        .frame(width: 56, height: 56)
                    
                    Image(systemName: mode.icon)
                        .font(.escherTitle)
                        .foregroundStyle(isSelected ? Color.escherForeground : Color.escherSecondaryText)
                }
                
                Text(mode.rawValue)
                    .font(isSelected ? .escherCaption.weight(.semibold) : .escherCaption)
                    .foregroundStyle(isSelected ? Color.escherForeground : Color.escherSecondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.escherForeground.opacity(0.06) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.escherForeground.opacity(0.2) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Appearance Preview

struct AppearancePreview: View {
    let colorScheme: ColorScheme
    
    var body: some View {
        VStack(spacing: 12) {
            Text("Preview", comment: "Label for appearance preview")
                .font(.escherCaption2)
                .tracking(1)
                .foregroundStyle(Color.escherSecondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack(spacing: 12) {
                // Mock chat bubbles
                VStack(alignment: .leading, spacing: 8) {
                    // User message
                    Text("Hello!", comment: "Sample user message in preview")
                        .font(.escherCaption)
                        .foregroundStyle(Color.escherBackground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.escherForeground)
                        )
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    
                    // Assistant message
                    Text("Hi there! 👋", comment: "Sample assistant message in preview")
                        .font(.escherCaption)
                        .foregroundStyle(Color.escherForeground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.escherSurface)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.escherBackground)
                        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
                )
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - About Row

struct AboutRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.escherCallout)
                .foregroundStyle(Color.escherForeground)
            
            Spacer()
            
            Text(value)
                .font(.escherCallout.weight(.regular))
                .foregroundStyle(Color.escherSecondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

struct AboutDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.escherMidtone.opacity(0.15))
            .frame(height: 1)
            .padding(.leading, 16)
    }
}

// MARK: - Model Routing Mode Row

struct ModelRoutingModeRow: View {
    let mode: ModelRoutingMode
    let isSelected: Bool
    let isAvailable: Bool
    let unavailabilityReason: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // Icon
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.escherForeground.opacity(0.12) : Color.escherSurface)
                        .frame(width: 40, height: 40)

                    Image(systemName: mode.icon)
                        .font(.escherBody)
                        .foregroundStyle(isSelected ? Color.escherForeground : Color.escherSecondaryText)
                }

                // Text
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(mode.displayName)
                            .font(.escherCallout)
                            .foregroundStyle(isAvailable ? Color.escherForeground : Color.escherSecondaryText)

                        // Unavailable indicator
                        if !isAvailable {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.escherCaption)
                                .foregroundStyle(Color.escherMidtone)
                        }
                    }

                    Text(mode.description)
                        .font(.escherCaption)
                        .foregroundStyle(Color.escherSecondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if !isAvailable, let unavailabilityReason {
                        Text(unavailabilityReason)
                            .font(.escherMini)
                            .foregroundStyle(Color.escherMidtone)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                // Selection indicator
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.escherForeground)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
    }
}

// MARK: - Settings Content View (For Tab Bar)

struct SettingsContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var appearanceManager = AppearanceManager.shared
    @State private var showingMailCompose = false
    @State private var showingPaywall = false
    @State private var paywallManager = PaywallManager.shared
    private let usageTracker = UsageTracker.shared

    var body: some View {
        ZStack {
            EscherBackground()
            
            ScrollView {
                VStack(spacing: 20) {
                    // Pro Section
                    proSection

                    // Appearance Section
                    appearanceSection
                    
                    // Support Section
                    supportSection
                    
                    // About Section
                    aboutSection
                }
                .padding(16)
            }
        }
        .navigationTitle(String(localized: "Settings"))
        .navigationBarTitleDisplayMode(.large)
        .escherNavigationStyle()
        .sheet(isPresented: $showingMailCompose) {
            MailComposeView()
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
                .presentationDragIndicator(.visible)
                .presentationDetents([.large])
        }
    }

    // MARK: - Pro Section

    private var proSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PRO", comment: "Section header for pro/upgrade settings")
                .font(.escherCaption2)
                .tracking(1)
                .foregroundStyle(Color.escherSecondaryText)

            VStack(spacing: 0) {
                if usageTracker.isPurchased {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.escherSuccess.opacity(0.15))
                                .frame(width: 40, height: 40)
                            Image(systemName: "checkmark.seal.fill")
                                .font(.escherBody)
                                .foregroundStyle(Color.escherSuccess)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("PocketREPL Pro", comment: "Pro unlock status title")
                                .font(.escherCallout)
                                .foregroundStyle(Color.escherForeground)
                            Text("Unlimited access unlocked", comment: "Pro unlock status subtitle")
                                .font(.escherCaption)
                                .foregroundStyle(Color.escherSecondaryText)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.escherSuccess)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                } else {
                    Button {
                        showingPaywall = true
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(colorScheme == .dark
                                          ? Color(white: 0.16)
                                          : Color.escherMidtone.opacity(0.10))
                                    .frame(width: 40, height: 40)
                                PenroseTriangle()
                                    .stroke(
                                        colorScheme == .dark ? Color.escherPaper : Color.escherInk,
                                        style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)
                                    )
                                    .frame(width: 18, height: 18)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Upgrade to Pro", comment: "Upgrade to pro button title")
                                    .font(.escherCallout)
                                    .foregroundStyle(Color.escherForeground)
                                let remaining = usageTracker.remainingFreeMessages
                                Text("\(remaining) free message\(remaining == 1 ? "" : "s") remaining", comment: "Shows remaining free messages")
                                    .font(.escherCaption)
                                    .foregroundStyle(remaining == 0 ? Color.escherError : Color.escherSecondaryText)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.escherCaption.weight(.semibold))
                                .foregroundStyle(Color.escherSecondaryText)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Rectangle()
                        .fill(Color.escherMidtone.opacity(0.15))
                        .frame(height: 1)
                        .padding(.leading, 56)

                    Button {
                        Task { await paywallManager.restorePurchases() }
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(colorScheme == .dark
                                          ? Color(white: 0.16)
                                          : Color.escherMidtone.opacity(0.10))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "arrow.clockwise")
                                    .font(.escherBody)
                                    .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
                            }
                            Text("Restore Purchases", comment: "Restore purchases button title")
                                .font(.escherCallout)
                                .foregroundStyle(Color.escherForeground)
                            Spacer()
                            if paywallManager.isPurchasing {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(paywallManager.isPurchasing)

                    if let error = paywallManager.purchaseError {
                        Text(error)
                            .font(.escherCaption)
                            .foregroundStyle(Color.escherError)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.escherSurface.opacity(0.6))
            )
        }
        .padding(18)
        .escherCard()
        .task {
            await paywallManager.loadProducts()
            await paywallManager.checkExistingEntitlements()
        }
    }
    
    // MARK: - Appearance Section
    
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("APPEARANCE", comment: "Section header")
                .font(.escherCaption2)
                .tracking(1)
                .foregroundStyle(Color.escherSecondaryText)
            
            VStack(spacing: 12) {
                // Mode Picker
                HStack(spacing: 8) {
                    ForEach(AppearanceMode.allCases) { mode in
                        AppearanceModeButton(
                            mode: mode,
                            isSelected: appearanceManager.mode == mode
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                appearanceManager.mode = mode
                            }
                        }
                    }
                }
                
                // Preview
                AppearancePreview(colorScheme: colorScheme)
            }
        }
        .padding(18)
        .escherCard()
    }
    
    // MARK: - Support Section
    
    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SUPPORT", comment: "Section header for support options")
                .font(.escherCaption2)
                .tracking(1)
                .foregroundStyle(Color.escherSecondaryText)
            
            Button {
                if FeedbackHelper.canSendMail {
                    showingMailCompose = true
                } else if let url = FeedbackHelper.mailtoURL() {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack {
                    Image(systemName: "envelope.fill")
                        .font(.escherBody)
                        .foregroundStyle(Color.escherSecondaryText)
                    
                    Text("Send Feedback", comment: "Button to send feedback email")
                        .font(.escherCallout)
                        .foregroundStyle(Color.escherForeground)
                    
                    Spacer()
                    
                    Image(systemName: "arrow.up.right")
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
        .padding(18)
        .escherCard()
    }
    
    // MARK: - About Section
    
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ABOUT", comment: "Section header")
                .font(.escherCaption2)
                .tracking(1)
                .foregroundStyle(Color.escherSecondaryText)
            
            VStack(spacing: 0) {
                AboutRow(label: String(localized: "Version"), value: appVersion)
                AboutDivider()
                AboutRow(label: String(localized: "Build"), value: buildNumber)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.escherSurface.opacity(0.6))
            )
        }
        .padding(18)
        .escherCard()
    }
    
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

// MARK: - Preview

#Preview("Settings - Light") {
    SettingsView()
        .preferredColorScheme(.light)
}

#Preview("Settings - Dark") {
    SettingsView()
        .preferredColorScheme(.dark)
}

#Preview("Settings Content - Light") {
    NavigationStack {
        SettingsContentView()
    }
    .preferredColorScheme(.light)
}

#Preview("Settings Content - Dark") {
    NavigationStack {
        SettingsContentView()
    }
    .preferredColorScheme(.dark)
}
