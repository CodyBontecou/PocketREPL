import SwiftUI
import StoreKit

// MARK: - Feature Model

struct PaywallFeature {
    let icon: String
    let title: String
    let subtitle: String
}

// MARK: - Paywall View

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var manager = PaywallManager.shared
    private let tracker = UsageTracker.shared

    var body: some View {
        ZStack {
            EscherBackground()

            ScrollView {
                VStack(spacing: 0) {
                    // ── Header ──────────────────────────────────
                    headerSection
                        .padding(.top, 32)

                    // ── Features ─────────────────────────────────
                    featuresSection
                        .padding(.top, 36)

                    // ── Purchase Button ──────────────────────────
                    purchaseButton
                        .padding(.top, 32)

                    // ── Restore + Legal ──────────────────────────
                    footerSection
                        .padding(.top, 16)
                        .padding(.bottom, 48)
                }
                .padding(.horizontal, 24)
            }
        }
        .task {
            await manager.loadProducts()
            await manager.checkExistingEntitlements()
            if tracker.isPurchased {
                dismiss()
            }
        }
        .onChange(of: tracker.isPurchased) { _, purchased in
            if purchased { dismiss() }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 16) {
            // Animated Penrose triangle
            ZStack {
                Circle()
                    .fill(colorScheme == .dark
                          ? Color(white: 0.12)
                          : Color.escherPaper)
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.10),
                            radius: 16, x: 0, y: 8)

                PenroseTriangle()
                    .stroke(
                        colorScheme == .dark ? Color.escherPaper : Color.escherInk,
                        style: StrokeStyle(lineWidth: 2.5, lineJoin: .round)
                    )
                    .frame(width: 44, height: 44)
            }

            VStack(spacing: 8) {
                Text("PocketREPL Pro")
                    .font(.escherTitle)
                    .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)

                if tracker.messagesUsed >= UsageTracker.freeMessageLimit {
                    Text("You've used your \(UsageTracker.freeMessageLimit) free messages.")
                        .font(.escherSubheadline)
                        .foregroundStyle(Color.escherSecondaryText)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Upgrade to keep building.")
                        .font(.escherSubheadline)
                        .foregroundStyle(Color.escherSecondaryText)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    // MARK: - Features

    private let features: [PaywallFeature] = [
        PaywallFeature(icon: "bubble.left.and.bubble.right.fill",
                       title: "Unlimited conversations",
                       subtitle: "Chat with no message caps, ever"),
        PaywallFeature(icon: "cpu.fill",
                       title: "Local AI models",
                       subtitle: "Run Qwen & other models on-device"),
        PaywallFeature(icon: "play.rectangle.fill",
                       title: "Full JavaScript runtime",
                       subtitle: "Execute code directly on your iPhone"),
        PaywallFeature(icon: "folder.fill",
                       title: "File read & write",
                       subtitle: "Manage your project files with AI"),
        PaywallFeature(icon: "clock.fill",
                       title: "Conversation history",
                       subtitle: "Every session saved and searchable"),
    ]

    private var featuresSection: some View {
        VStack(spacing: 12) {
            ForEach(Array(features.enumerated()), id: \.offset) { _, feature in
                FeatureRow(feature: feature)
            }
        }
    }

    // MARK: - Purchase Button

    private var purchaseButton: some View {
        Button {
            Task { await manager.purchase() }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(colorScheme == .dark ? Color.escherPaper : Color.escherInk)

                TessellationPattern(density: 24, opacity: 0.06)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                if manager.isPurchasing {
                    ProgressView()
                        .tint(colorScheme == .dark ? Color.escherInk : Color.escherPaper)
                        .padding(.vertical, 18)
                } else {
                    HStack(spacing: 10) {
                        PenroseTriangle()
                            .stroke(
                                colorScheme == .dark ? Color.escherInk : Color.escherPaper,
                                lineWidth: 1.5
                            )
                            .frame(width: 18, height: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Unlock PocketREPL Pro")
                                .font(.escherHeadline)
                                .foregroundStyle(colorScheme == .dark ? Color.escherInk : Color.escherPaper)

                            if let price = manager.priceString {
                                Text("One-time purchase — \(price)")
                                    .font(.escherCaption)
                                    .foregroundStyle(
                                        (colorScheme == .dark ? Color.escherInk : Color.escherPaper)
                                            .opacity(0.65)
                                    )
                            }
                        }

                        Spacer()

                        Image(systemName: "arrow.right")
                            .font(.escherCallout.weight(.bold))
                            .foregroundStyle(colorScheme == .dark ? Color.escherInk : Color.escherPaper)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: manager.isPurchasing ? 64 : nil)
        }
        .buttonStyle(.plain)
        .disabled(manager.isPurchasing)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: manager.isPurchasing)
        .overlay(
            // Error state
            Group {
                if let error = manager.purchaseError {
                    Text(error)
                        .font(.escherCaption)
                        .foregroundStyle(Color.escherError)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity)
                        .offset(y: 52)
                }
            }
        )
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 12) {
            // Restore Purchases
            Button {
                Task { await manager.restorePurchases() }
            } label: {
                Text("Restore Purchases")
                    .font(.escherSubheadline)
                    .foregroundStyle(Color.escherSecondaryText)
                    .underline()
            }
            .buttonStyle(.plain)
            .disabled(manager.isPurchasing)

            // Legal
            Text("Payment is charged to your Apple ID account at confirmation of purchase. Prices may vary by region.")
                .font(.escherCaption2)
                .foregroundStyle(Color.escherSecondaryText.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
    }
}

// MARK: - Feature Row

private struct FeatureRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let feature: PaywallFeature

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(colorScheme == .dark
                          ? Color(white: 0.16)
                          : Color.escherMidtone.opacity(0.10))
                    .frame(width: 44, height: 44)

                Image(systemName: feature.icon)
                    .font(.escherBody)
                    .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.escherCallout)
                    .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)

                Text(feature.subtitle)
                    .font(.escherCaption)
                    .foregroundStyle(Color.escherSecondaryText)
            }

            Spacer()

            Image(systemName: "checkmark")
                .font(.escherFootnote.weight(.bold))
                .foregroundStyle(colorScheme == .dark ? Color.escherPaper : Color.escherInk)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(colorScheme == .dark
                      ? Color(white: 0.10)
                      : Color.escherPaper)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.05),
                        radius: 6, x: 0, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    Color.escherMidtone.opacity(colorScheme == .dark ? 0.2 : 0.1),
                    lineWidth: 0.5
                )
        )
    }
}

// MARK: - Previews

#Preview("Paywall — Limit Hit") {
    PaywallView()
        .preferredColorScheme(.dark)
}

#Preview("Paywall — Light") {
    PaywallView()
        .preferredColorScheme(.light)
}
