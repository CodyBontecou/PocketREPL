import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var appearanceManager = AppearanceManager.shared
    
    var body: some View {
        NavigationStack {
            ZStack {
                EscherBackground()
                
                ScrollView {
                    VStack(spacing: 20) {
                        // Appearance Section
                        appearanceSection
                        
                        // About Section
                        aboutSection
                    }
                    .padding(16)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.escherPrism)
                        
                        Text("Settings")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.escherForeground)
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
        .presentationDragIndicator(.visible)
    }
    
    // MARK: - Appearance Section
    
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("APPEARANCE")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundStyle(Color.escherMidtone)
            
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
    
    // MARK: - About Section
    
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ABOUT")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundStyle(Color.escherMidtone)
            
            VStack(spacing: 0) {
                AboutRow(label: "Version", value: appVersion)
                AboutDivider()
                AboutRow(label: "Build", value: buildNumber)
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
                        .fill(isSelected ? Color.escherPrism.opacity(0.15) : Color.escherSurface)
                        .frame(width: 56, height: 56)
                    
                    Image(systemName: mode.icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(isSelected ? Color.escherPrism : Color.escherMidtone)
                }
                
                Text(mode.rawValue)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(isSelected ? Color.escherPrism : Color.escherMidtone)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.escherPrism.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.escherPrism.opacity(0.3) : Color.clear, lineWidth: 1.5)
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
            Text("Preview")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundStyle(Color.escherMidtone)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack(spacing: 12) {
                // Mock chat bubbles
                VStack(alignment: .leading, spacing: 8) {
                    // User message
                    Text("Hello!")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.escherBackground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.escherForeground)
                        )
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    
                    // Assistant message
                    Text("Hi there! 👋")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
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
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Color.escherForeground)
            
            Spacer()
            
            Text(value)
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(Color.escherMidtone)
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

// MARK: - Settings Content View (For Tab Bar)

struct SettingsContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var appearanceManager = AppearanceManager.shared
    
    var body: some View {
        ZStack {
            EscherBackground()
            
            ScrollView {
                VStack(spacing: 20) {
                    // Appearance Section
                    appearanceSection
                    
                    // About Section
                    aboutSection
                }
                .padding(16)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .escherNavigationStyle()
    }
    
    // MARK: - Appearance Section
    
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("APPEARANCE")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundStyle(Color.escherMidtone)
            
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
    
    // MARK: - About Section
    
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ABOUT")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundStyle(Color.escherMidtone)
            
            VStack(spacing: 0) {
                AboutRow(label: "Version", value: appVersion)
                AboutDivider()
                AboutRow(label: "Build", value: buildNumber)
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
