import SwiftUI

// MARK: - Escher Design System
// Combining M.C. Escher's impossible geometry with Apple's liquid design

// MARK: - Color Palette

extension Color {
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
    let density: Int
    let opacity: Double
    
    init(density: Int = 8, opacity: Double = 0.03) {
        self.density = density
        self.opacity = opacity
    }
    
    var body: some View {
        Canvas { context, size in
            let cellSize = size.width / CGFloat(density)
            
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
                        with: .color(.escherInk.opacity(opacity)),
                        lineWidth: 0.5
                    )
                }
            }
        }
    }
}

/// Metamorphosis wave - elements that transform
struct MetamorphosisWave: View {
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
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }
}

/// Infinite staircase indicator (for loading states)
struct InfiniteStairs: View {
    @State private var step: Int = 0
    let size: CGFloat
    
    init(size: CGFloat = 40) {
        self.size = size
    }
    
    var body: some View {
        Canvas { context, canvasSize in
            let stairCount = 8
            let stairHeight = size / CGFloat(stairCount)
            let stairWidth = size / CGFloat(stairCount)
            
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
                    with: .color(.escherInk.opacity(opacity)),
                    lineWidth: 2
                )
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.1)) {
                    step = (step + 1) % 8
                }
            }
        }
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
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(isEnabled ? Color.escherPaper : Color.escherMidtone)
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

// MARK: - Typography

extension Font {
    // Display - For headers, uses geometric characteristics
    static let escherDisplay = Font.system(size: 28, weight: .bold, design: .rounded)
    static let escherTitle = Font.system(size: 22, weight: .semibold, design: .rounded)
    static let escherHeadline = Font.system(size: 17, weight: .semibold, design: .rounded)
    
    // Body - Readable with subtle character
    static let escherBody = Font.system(size: 16, weight: .regular, design: .default)
    static let escherCaption = Font.system(size: 13, weight: .medium, design: .rounded)
    
    // Monospace - For code
    static let escherMono = Font.system(size: 14, weight: .regular, design: .monospaced)
    static let escherMonoSmall = Font.system(size: 12, weight: .regular, design: .monospaced)
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
    @State private var animationPhase: CGFloat = 0
    
    var body: some View {
        ZStack {
            // Base gradient
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.95, blue: 0.93),
                    Color(red: 0.94, green: 0.93, blue: 0.90)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            
            // Tessellation layer
            TessellationPattern(density: 10, opacity: 0.025)
            
            // Subtle metamorphosis waves
            MetamorphosisWave()
                .opacity(0.5)
        }
        .ignoresSafeArea()
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
    func body(content: Content) -> some View {
        content
            .font(.escherBody)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.escherPaper)
                    
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.escherMidtone.opacity(0.2), lineWidth: 1)
                }
            )
    }
}

extension View {
    func escherTextField() -> some View {
        modifier(EscherTextField())
    }
}

// MARK: - Card Style

struct EscherCard: ViewModifier {
    let isElevated: Bool
    
    init(elevated: Bool = true) {
        self.isElevated = elevated
    }
    
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.escherPaper)
                    
                    // Subtle pattern overlay
                    TessellationPattern(density: 20, opacity: 0.01)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    
                    // Border
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.escherMidtone.opacity(0.15),
                                    Color.escherMidtone.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                }
            )
            .shadow(
                color: .escherInk.opacity(isElevated ? 0.06 : 0),
                radius: isElevated ? 12 : 0,
                x: 0,
                y: isElevated ? 4 : 0
            )
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
