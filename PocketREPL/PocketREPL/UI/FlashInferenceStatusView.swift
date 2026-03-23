import SwiftUI
import Observation

// MARK: - Flash Inference Status View
//
// Real-time display of flash inference performance metrics.
// Shows the key metrics from Apple's "LLM in a Flash" paper:
//   - Cache hit rate (how many neurons came from DRAM vs. NVMe)
//   - Flash bandwidth (GB/s of SSD reads)
//   - DRAM usage (how much memory the cache is consuming)
//   - Tokens per second

// MARK: - Flash Metrics State

@Observable
@MainActor
final class FlashInferenceMetrics {

    var tokensPerSecond: Double = 0
    var cacheHitRate: Double = 0
    var dramUsedMB: Double = 0
    var flashBandwidthGBps: Double = 0
    var totalFlashLoadMB: Double = 0
    var predictedSparsity: Double = 0
    var isGenerating: Bool = false
    var generationStats: [TokenStat] = []

    struct TokenStat: Identifiable {
        let id = UUID()
        let tokenIndex: Int
        let latencyMs: Double
        let cacheHitRate: Double
        let flashBytes: Int64
    }

    func reset() {
        tokensPerSecond = 0
        cacheHitRate = 0
        dramUsedMB = 0
        flashBandwidthGBps = 0
        totalFlashLoadMB = 0
        predictedSparsity = 0
        generationStats = []
    }
}

// MARK: - Flash Status View

struct FlashInferenceStatusView: View {
    var metrics: FlashInferenceMetrics  // @Observable — no property wrapper needed
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            if showDetails {
                detailMetrics
            }
        }
        .background(Color.adaptiveBackground.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.flashAccent.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Header Row

    private var headerRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showDetails.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                // Flash icon
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.flashAccent)

                // Speed
                metricBadge(
                    value: String(format: "%.1f", metrics.tokensPerSecond),
                    unit: "tok/s",
                    color: speedColor
                )

                // Cache hit rate
                metricBadge(
                    value: String(format: "%.0f%%", metrics.cacheHitRate * 100),
                    unit: "cache",
                    color: cacheColor
                )

                Spacer()

                // Label
                Text("Flash")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.flashAccent)

                Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail Metrics

    private var detailMetrics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.horizontal, 10)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 6) {
                flashMetricCell(
                    label: "SSD Bandwidth",
                    value: String(format: "%.1f GB/s", metrics.flashBandwidthGBps),
                    icon: "internaldrive"
                )

                flashMetricCell(
                    label: "DRAM Cache",
                    value: String(format: "%.0f MB", metrics.dramUsedMB),
                    icon: "memorychip"
                )

                flashMetricCell(
                    label: "Flash Read",
                    value: String(format: "%.1f MB", metrics.totalFlashLoadMB),
                    icon: "arrow.down.to.line"
                )

                flashMetricCell(
                    label: "FFN Sparsity",
                    value: String(format: "%.0f%%", metrics.predictedSparsity * 100),
                    icon: "waveform.path.ecg"
                )
            }
            .padding(.horizontal, 10)

            // Sparkline of recent token latencies
            if !metrics.generationStats.isEmpty {
                latencySparkline
                    .padding(.horizontal, 10)
            }

            // Theory vs actual comparison
            paperComparisonRow
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
    }

    // MARK: - Latency Sparkline

    private var latencySparkline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TOKEN LATENCY")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.secondary)

            GeometryReader { geo in
                let maxLatency = (metrics.generationStats.map(\.latencyMs).max() ?? 1)
                let barWidth = max(2, geo.size.width / CGFloat(max(1, metrics.generationStats.count)))

                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(metrics.generationStats.suffix(40)) { stat in
                        let height = CGFloat(stat.latencyMs / maxLatency) * geo.size.height
                        Rectangle()
                            .fill(latencyColor(stat.latencyMs))
                            .frame(width: barWidth - 1, height: max(2, height))
                    }
                    Spacer()
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 32)
        }
    }

    // MARK: - Paper Comparison

    private var paperComparisonRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text")
                .font(.system(size: 9))
                .foregroundStyle(Color.secondary)

            Text("Paper (M1 Max):")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.secondary)

            Text("87ms/tok")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.secondary)

            Text("·")
                .foregroundStyle(Color.secondary)

            Text("This device:")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.secondary)

            Text(String(format: "%.0fms/tok", metrics.tokensPerSecond > 0 ? 1000.0 / metrics.tokensPerSecond : 0))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(metrics.tokensPerSecond > 0 ? Color.flashAccent : Color.secondary)
        }
    }

    // MARK: - Helpers

    private func metricBadge(value: String, unit: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(unit)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.secondary)
        }
    }

    private func flashMetricCell(label: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.secondary)
                Text(label)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.secondary)
            }
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(Color.adaptiveSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Computed Colors

    private var speedColor: Color {
        switch metrics.tokensPerSecond {
        case 5...:  return .green
        case 2..<5: return .yellow
        default:    return .orange
        }
    }

    private var cacheColor: Color {
        switch metrics.cacheHitRate {
        case 0.8...: return .green
        case 0.5..<0.8: return .yellow
        default:     return .orange
        }
    }

    private func latencyColor(_ ms: Double) -> Color {
        switch ms {
        case ..<100:  return .green
        case ..<300:  return .yellow
        default:      return .red
        }
    }
}

// MARK: - Flash Model Card

/// Card shown in ModelManagementView for flash-compatible models.
struct FlashModelCard: View {
    let modelName: String
    let fileSizeGB: Double
    let availableDRAMGB: Double
    let estimatedSpeedTPS: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(Color.flashAccent)
                Text(modelName)
                    .font(.headline)
                Spacer()
                Text("LLM in Flash")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.flashAccent.opacity(0.15))
                    .foregroundStyle(Color.flashAccent)
                    .clipShape(Capsule())
            }

            // Memory comparison
            HStack(spacing: 12) {
                memoryBar(
                    label: "Model Size",
                    value: fileSizeGB,
                    max: max(fileSizeGB, availableDRAMGB),
                    color: .blue
                )
                memoryBar(
                    label: "DRAM Used",
                    value: fileSizeGB * 0.5,
                    max: max(fileSizeGB, availableDRAMGB),
                    color: .green
                )
                memoryBar(
                    label: "Available",
                    value: availableDRAMGB,
                    max: max(fileSizeGB, availableDRAMGB),
                    color: .secondary
                )
            }

            // Speed estimate
            HStack {
                Image(systemName: "speedometer")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                Text("Estimated: ")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                Text(String(format: "%.1f tok/s", estimatedSpeedTPS))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if fileSizeGB > availableDRAMGB {
                    Label("Exceeds DRAM — flash enabled", systemImage: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.flashAccent)
                } else {
                    Label("Fits in DRAM", systemImage: "checkmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(12)
        .background(Color.adaptiveSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func memoryBar(label: String, value: Double, max: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Color.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.1))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: max > 0 ? geo.size.width * CGFloat(value / max) : 0)
                }
            }
            .frame(height: 4)
            Text(String(format: "%.1f GB", value))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}

// MARK: - Flash Paper Info Sheet

struct FlashPaperInfoSheet: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    VStack(alignment: .leading, spacing: 4) {
                        Label("LLM in a Flash", systemImage: "bolt.fill")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Color.flashAccent)

                        Text("Alizadeh et al., Apple (2023)")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }

                    Divider()

                    // Key insight
                    infoSection(
                        icon: "lightbulb.fill",
                        title: "Core Idea",
                        body: "Store model weights on flash (NVMe SSD). Load only the neuron weights you need for each token. Apple Silicon's unified memory architecture lets the CPU, GPU, and SSD controller share the same data bus — no PCIe overhead."
                    )

                    // Techniques
                    infoSection(
                        icon: "list.bullet",
                        title: "Techniques",
                        body: """
                        1. Activation Sparsity: ReLU-activated FFNs are 90–97% sparse. Only ~3–10% of neurons activate for any given token.

                        2. Sparsity Predictor: A tiny low-rank linear model predicts which neurons will activate, so we can pre-fetch them.

                        3. Sliding Window Cache: Keep the last k tokens' active neurons in DRAM. Incremental loading is 10–50× faster.

                        4. Row-Column Bundling: Store each neuron's up-proj column AND down-proj row together. One I/O read fetches both (2× throughput).

                        5. Parallel I/O: 32 concurrent reads saturate the NVMe controller.
                        """
                    )

                    // Results
                    infoSection(
                        icon: "chart.bar.fill",
                        title: "Paper Results (M1 Max)",
                        body: "OPT-6.7B: 87 ms/token (vs. 2196 ms naive loading) — 25× speedup on GPU. Enables models 2× larger than available DRAM."
                    )

                    // Flash-MoE project
                    infoSection(
                        icon: "cpu",
                        title: "Flash-MoE Extension",
                        body: "The danveloper/flash-moe project applied these techniques to Qwen 3.5 397B (a 209 GB MoE model), running at 5.7 tok/s sustained on an M3 Max with only 48 GB DRAM. The key addition: 2-bit expert quantization reducing storage to 120 GB."
                    )

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("About Flash Inference")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func infoSection(icon: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))

            Text(body)
                .font(.callout)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.adaptiveSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Color Extensions

extension Color {
    static let flashAccent = Color(red: 0.95, green: 0.65, blue: 0.1)  // Amber

    static var adaptiveBackground: Color {
        Color(UIColor.systemBackground)
    }

    static var adaptiveSecondaryBackground: Color {
        Color(UIColor.secondarySystemBackground)
    }
}

// MARK: - Preview

#Preview("Flash Status") {
    @Previewable @State var metrics = FlashInferenceMetrics()

    FlashInferenceStatusView(metrics: metrics)
        .padding()
        .frame(width: 300)
        .task {
            metrics.tokensPerSecond = 5.7
            metrics.cacheHitRate = 0.73
            metrics.dramUsedMB = 2800
            metrics.flashBandwidthGBps = 4.2
            metrics.totalFlashLoadMB = 142
            metrics.predictedSparsity = 0.93
            metrics.generationStats = (0..<20).map { i in
                FlashInferenceMetrics.TokenStat(
                    tokenIndex: i,
                    latencyMs: Double.random(in: 80...250),
                    cacheHitRate: Double.random(in: 0.6...0.9),
                    flashBytes: Int64.random(in: 1_000_000...10_000_000)
                )
            }
        }
}

#Preview("Flash Model Card") {
    FlashModelCard(
        modelName: "Llama-2-7B-Flash",
        fileSizeGB: 14.0,
        availableDRAMGB: 8.0,
        estimatedSpeedTPS: 6.2
    )
    .padding()
}

#Preview("Paper Info") {
    FlashPaperInfoSheet()
}
