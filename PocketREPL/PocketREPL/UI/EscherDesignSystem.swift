import SwiftUI

// MARK: - Escher Design System
// Combining M.C. Escher's impossible geometry with Apple's liquid design
// Now with full light/dark mode support

// MARK: - Color Palette

extension Color {
    // MARK: - Base Colors (Non-Adaptive)
    
    // Primary - Deep lithographic blacks and paper whites
    static let escherInk = Color(red: 0.08, green: 0.06, blue: 0.10)
    static let escherPaper = Color(red: 0.98, green: 0.97, blue: 0.95)
    static let escherMidtone = Color(red: 0.55, green: 0.53, blue: 0.58)
    
    // Accent - Impossible geometry highlights
    static let escherPrism = Color(red: 0.36, green: 0.54, blue: 0.66)  // Steel blue
    static let escherMirror = Color(red: 0.82, green: 0.76, blue: 0.68) // Warm stone
    static let escherVoid = Color(red: 0.22, green: 0.18, blue: 0.28)   // Deep purple-black
    
    // Semantic
    static let escherSuccess = Color(red: 0.42, green: 0.60, blue: 0.48)
    static let escherWarning = Color(red: 0.78, green: 0.62, blue: 0.38)
    static let escherError = Color(red: 0.72, green: 0.38, blue: 0.38)
    
    // MARK: - Adaptive Semantic Colors
    // Note: escherForeground, escherBackground, escherSurface, escherSurfaceSecondary,
    // and escherSecondaryText are auto-generated from Assets.xcassets color sets.
    // 
    // escherSecondaryText: WCAG AA compliant (4.5:1+ contrast) for secondary text
    //   - Light mode: rgb(0.40, 0.38, 0.44) - darker for contrast vs light backgrounds
    //   - Dark mode: rgb(0.70, 0.68, 0.73) - lighter for contrast vs dark backgrounds
    // Use escherSecondaryText for text, escherMidtone for decorative elements (borders, fills)
    
    // MARK: - Fallback Adaptive Colors (when Assets not available)
    
    /// Foreground that adapts to color scheme (fallback)
    static func adaptiveForeground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? escherPaper : escherInk
    }
    
    /// Background that adapts to color scheme (fallback)
    static func adaptiveBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.10, green: 0.08, blue: 0.12) : Color(red: 0.96, green: 0.95, blue: 0.93)
    }
    
    /// Surface that adapts to color scheme (fallback)
    static func adaptiveSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.14, green: 0.12, blue: 0.16) : escherPaper
    }
    
    // Gradients
    static let escherGradientLight = LinearGradient(
        colors: [Color(white: 0.96), Color(white: 0.92)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    static let escherGradientDark = LinearGradient(
        colors: [Color(red: 0.12, green: 0.10, blue: 0.15), Color(red: 0.08, green: 0.06, blue: 0.12)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Impossible Shape Components

/// A Penrose triangle outline for decorative use
struct PenroseTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let scale = size / 100
        
        // Outer triangle
        path.move(to: CGPoint(x: center.x, y: center.y - 40 * scale))
        path.addLine(to: CGPoint(x: center.x + 35 * scale, y: center.y + 20 * scale))
        path.addLine(to: CGPoint(x: center.x - 35 * scale, y: center.y + 20 * scale))
        path.closeSubpath()
        
        // Inner triangle (creates impossible effect)
        path.move(to: CGPoint(x: center.x, y: center.y - 20 * scale))
        path.addLine(to: CGPoint(x: center.x + 18 * scale, y: center.y + 10 * scale))
        path.addLine(to: CGPoint(x: center.x - 18 * scale, y: center.y + 10 * scale))
        path.closeSubpath()
        
        return path
    }
}

/// Tessellation pattern inspired by Escher's reptiles
struct TessellationPattern: View {
    @Environment(\.colorScheme) private var colorScheme
    let density: Int
    let opacity: Double
    
    init(density: Int = 8, opacity: Double = 0.03) {
        self.density = density
        self.opacity = opacity
    }
    
    var body: some View {
        Canvas { context, size in
            let cellSize = size.width / CGFloat(density)
            // Use appropriate color based on color scheme
            let strokeColor = colorScheme == .dark ? Color.escherPaper : Color.escherInk
            
            for row in 0..<(Int(size.height / cellSize) + 2) {
                for col in 0..<(density + 1) {
                    let isOffset = row % 2 == 1
                    let x = CGFloat(col) * cellSize + (isOffset ? cellSize / 2 : 0)
                    let y = CGFloat(row) * cellSize
                    
                    // Hexagonal tessellation
                    var path = Path()
                    let hexRadius = cellSize * 0.45
                    
                    for i in 0..<6 {
                        let angle = CGFloat(i) * .pi / 3 - .pi / 6
                        let px = x + cos(angle) * hexRadius
                        let py = y + sin(angle) * hexRadius
                        if i == 0 {
                            path.move(to: CGPoint(x: px, y: py))
                        } else {
                            path.addLine(to: CGPoint(x: px, y: py))
                        }
                    }
                    path.closeSubpath()
                    
                    context.stroke(
                        path,
                        with: .color(strokeColor.opacity(opacity)),
                        lineWidth: 0.5
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Metamorphosis wave - elements that transform
struct MetamorphosisWave: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0
    
    var body: some View {
        Canvas { context, size in
            let stepCount = 30
            let waveHeight: CGFloat = 8
            
            for step in 0..<stepCount {
                let progress = CGFloat(step) / CGFloat(stepCount)
                let y = size.height * progress
                
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                
                for x in stride(from: 0, through: size.width, by: 4) {
                    let wave = sin((x / 30) + phase + progress * .pi) * waveHeight * (1 - progress)
                    path.addLine(to: CGPoint(x: x, y: y + wave))
                }
                
                context.stroke(
                    path,
                    with: .color(.escherMidtone.opacity(0.1 * (1 - progress))),
                    lineWidth: 0.5
                )
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
        .accessibilityHidden(true)
    }
}

/// Infinite staircase indicator (for loading states)
struct InfiniteStairs: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Int = 0
    @State private var animationTimer: Timer?
    let size: CGFloat
    
    init(size: CGFloat = 40) {
        self.size = size
    }
    
    var body: some View {
        Canvas { context, canvasSize in
            let stairCount = 8
            let stairHeight = size / CGFloat(stairCount)
            let stairWidth = size / CGFloat(stairCount)
            let strokeColor = colorScheme == .dark ? Color.escherPaper : Color.escherInk
            
            for i in 0..<stairCount {
                let index = (i + step) % stairCount
                let opacity = 0.3 + (Double(index) / Double(stairCount)) * 0.7
                
                let x = CGFloat(i) * stairWidth
                let y = canvasSize.height / 2 - CGFloat(index) * stairHeight / 2
                
                var path = Path()
                // Horizontal
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x + stairWidth, y: y))
                // Vertical
                path.addLine(to: CGPoint(x: x + stairWidth, y: y + stairHeight))
                
                context.stroke(
                    path,
                    with: .color(strokeColor.opacity(opacity)),
                    lineWidth: 2
                )
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion else {
                step = 4 // Show static middle state when reduce motion is enabled
                return
            }
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.1)) {
                    step = (step + 1) % 8
                }
            }
        }
        .onDisappear {
            animationTimer?.invalidate()
            animationTimer = nil
        }
        .accessibilityLabel(String(localized: "Loading"))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Glass & Material Effects

struct EscherGlass: ViewModifier {
    let cornerRadius: CGFloat
    let depth: Double
    
    init(cornerRadius: CGFloat = 20, depth: Double = 0.5) {
        self.cornerRadius = cornerRadius
        self.depth = depth
    }
    
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // Frosted glass base
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    
                    // Subtle tessellation overlay
                    TessellationPattern(density: 12, opacity: 0.015)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    
                    // Edge highlight
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.3 * depth),
                                    Color.white.opacity(0.1 * depth),
                                    Color.black.opacity(0.05 * depth)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                }
            )
            .shadow(color: .black.opacity(0.08 * depth), radius: 8, x: 0, y: 4)
    }
}

extension View {
    func escherGlass(cornerRadius: CGFloat = 20, depth: Double = 0.5) -> some View {
        modifier(EscherGlass(cornerRadius: cornerRadius, depth: depth))
    }
}

// MARK: - Impossible Geometry Button Style

struct ImpossibleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.escherSubheadline)
            .foregroundStyle(isEnabled ? Color.escherPaper : Color.escherSecondaryText)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    // Base shape
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isEnabled ? Color.escherInk : Color.escherMidtone.opacity(0.3))
                    
                    // Impossible edge effect
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(configuration.isPressed ? 0.1 : 0.2),
                                    Color.white.opacity(0),
                                    Color.black.opacity(0.3)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Typography (Dynamic Type Support)

extension Font {
    // MARK: - Display & Titles (Rounded Design)
    
    /// Large display text (28pt equivalent) - for prominent headers
    static var escherDisplay: Font {
        .system(.title, design: .rounded).weight(.bold)
    }
    
    /// Main title text (22pt equivalent) - for section headers
    static var escherTitle: Font {
        .system(.title2, design: .rounded).weight(.semibold)
    }
    
    /// Headline text (17pt equivalent) - for list row titles
    static var escherHeadline: Font {
        .system(.headline, design: .rounded).weight(.semibold)
    }
    
    /// Subheadline text (15pt equivalent) - for secondary titles
    static var escherSubheadline: Font {
        .system(.subheadline, design: .rounded).weight(.semibold)
    }
    
    // MARK: - Body Text
    
    /// Standard body text (16pt equivalent)
    static var escherBody: Font {
        .system(.body, design: .default)
    }
    
    /// Callout text (15pt equivalent) - for emphasized body
    static var escherCallout: Font {
        .system(.callout, design: .rounded).weight(.medium)
    }
    
    /// Footnote text (13pt equivalent) - for secondary info
    static var escherFootnote: Font {
        .system(.footnote, design: .rounded).weight(.medium)
    }
    
    /// Caption text (12pt equivalent) - for labels and metadata
    static var escherCaption: Font {
        .system(.caption, design: .rounded).weight(.medium)
    }
    
    /// Small caption text (11pt equivalent) - for section headers, badges
    static var escherCaption2: Font {
        .system(.caption2, design: .rounded).weight(.bold)
    }
    
    /// Extra small text (10pt equivalent) - for tiny labels
    static var escherMini: Font {
        .system(.caption2, design: .rounded).weight(.medium)
    }
    
    // MARK: - Monospace (For Code)
    
    /// Code text (14pt equivalent)
    static var escherMono: Font {
        .system(.subheadline, design: .monospaced)
    }
    
    /// Small code text (12pt equivalent)
    static var escherMonoSmall: Font {
        .system(.caption, design: .monospaced)
    }
    
    /// Tiny code text (10pt equivalent)
    static var escherMonoMini: Font {
        .system(.caption2, design: .monospaced)
    }
    
    // MARK: - Special Weights (Call these on existing fonts)
    
    /// Thin weight for large decorative icons
    static var escherThin: Font {
        .system(.title, design: .default).weight(.thin)
    }
    
    /// Medium weight variant
    static var escherMedium: Font {
        .system(.body, design: .rounded).weight(.medium)
    }
}

// MARK: - Message Bubble Shapes

/// An Escher-inspired bubble with impossible corners
struct EscherBubble: Shape {
    let isUser: Bool
    
    func path(in rect: CGRect) -> Path {
        let cornerRadius: CGFloat = 18
        let tailSize: CGFloat = 6
        
        var path = Path()
        
        if isUser {
            // User bubble with tail on right
            path.addRoundedRect(
                in: CGRect(x: 0, y: 0, width: rect.width - tailSize, height: rect.height),
                cornerSize: CGSize(width: cornerRadius, height: cornerRadius),
                style: .continuous
            )
            
            // Geometric tail
            path.move(to: CGPoint(x: rect.width - tailSize - 2, y: rect.height - 20))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height - 8))
            path.addLine(to: CGPoint(x: rect.width - tailSize - 2, y: rect.height - 8))
        } else {
            // Assistant bubble with tail on left
            path.addRoundedRect(
                in: CGRect(x: tailSize, y: 0, width: rect.width - tailSize, height: rect.height),
                cornerSize: CGSize(width: cornerRadius, height: cornerRadius),
                style: .continuous
            )
            
            // Geometric tail
            path.move(to: CGPoint(x: tailSize + 2, y: rect.height - 20))
            path.addLine(to: CGPoint(x: 0, y: rect.height - 8))
            path.addLine(to: CGPoint(x: tailSize + 2, y: rect.height - 8))
        }
        
        return path
    }
}

// MARK: - Animated Background

struct EscherBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var animationPhase: CGFloat = 0
    
    var body: some View {
        ZStack {
            // Base gradient - adapts to color scheme
            LinearGradient(
                colors: colorScheme == .dark ? [
                    Color(red: 0.08, green: 0.06, blue: 0.10),
                    Color(red: 0.10, green: 0.08, blue: 0.12)
                ] : [
                    Color(red: 0.96, green: 0.95, blue: 0.93),
                    Color(red: 0.94, green: 0.93, blue: 0.90)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            
            // Tessellation layer - adapts opacity for dark mode
            TessellationPattern(
                density: 10, 
                opacity: colorScheme == .dark ? 0.04 : 0.025
            )
            
            // Subtle metamorphosis waves
            MetamorphosisWave()
                .opacity(colorScheme == .dark ? 0.3 : 0.5)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Navigation Bar Appearance

struct EscherNavigationStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

extension View {
    func escherNavigationStyle() -> some View {
        modifier(EscherNavigationStyle())
    }
}

// MARK: - Input Field Style

struct EscherTextField: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    
    func body(content: Content) -> some View {
        content
            .font(.escherBody)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(fieldBackground)
                    
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.escherMidtone.opacity(colorScheme == .dark ? 0.3 : 0.2), lineWidth: 1)
                }
            )
    }
    
    private var fieldBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.14, green: 0.12, blue: 0.16)
            : Color.escherPaper
    }
}

extension View {
    func escherTextField() -> some View {
        modifier(EscherTextField())
    }
}

// MARK: - Card Style

struct EscherCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let isElevated: Bool
    
    init(elevated: Bool = true) {
        self.isElevated = elevated
    }
    
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(cardBackground)
                    
                    // Subtle pattern overlay
                    TessellationPattern(density: 20, opacity: colorScheme == .dark ? 0.02 : 0.01)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    
                    // Border
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.escherMidtone.opacity(colorScheme == .dark ? 0.25 : 0.15),
                                    Color.escherMidtone.opacity(colorScheme == .dark ? 0.10 : 0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                }
            )
            .shadow(
                color: .black.opacity(isElevated ? (colorScheme == .dark ? 0.3 : 0.06) : 0),
                radius: isElevated ? 12 : 0,
                x: 0,
                y: isElevated ? 4 : 0
            )
    }
    
    private var cardBackground: Color {
        colorScheme == .dark 
            ? Color(red: 0.14, green: 0.12, blue: 0.16)
            : Color.escherPaper
    }
}

extension View {
    func escherCard(elevated: Bool = true) -> some View {
        modifier(EscherCard(elevated: elevated))
    }
}

// MARK: - Preview

#Preview("Design System") {
    ScrollView {
        VStack(spacing: 32) {
            // Colors
            VStack(alignment: .leading, spacing: 12) {
                Text("Colors")
                    .font(.escherTitle)
                
                HStack(spacing: 12) {
                    Circle().fill(Color.escherInk).frame(width: 40)
                    Circle().fill(Color.escherPaper).frame(width: 40)
                        .overlay(Circle().stroke(Color.escherMidtone.opacity(0.3), lineWidth: 1))
                    Circle().fill(Color.escherMidtone).frame(width: 40)
                    Circle().fill(Color.escherPrism).frame(width: 40)
                    Circle().fill(Color.escherMirror).frame(width: 40)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Components
            VStack(spacing: 16) {
                Text("Components")
                    .font(.escherTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                Button("Impossible Button") {}
                    .buttonStyle(ImpossibleButtonStyle())
                
                HStack {
                    InfiniteStairs()
                    Text("Loading...")
                        .font(.escherCaption)
                        .foregroundStyle(Color.escherMidtone)
                }
                .padding()
                .escherCard()
            }
            
            // Penrose
            PenroseTriangle()
                .stroke(Color.escherInk, lineWidth: 2)
                .frame(width: 100, height: 100)
        }
        .padding(24)
    }
    .background(EscherBackground())
}
