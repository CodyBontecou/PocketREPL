import SwiftUI
import Observation

// MARK: - Flash Benchmark View
//
// Measures actual flash inference performance: tok/s, cache hit rate, SSD bandwidth.
// Compares against theoretical maximum and paper's reported numbers.

// MARK: - Benchmark State

@Observable
@MainActor
final class FlashBenchmarkState {
    var isRunning: Bool = false
    var currentRun: BenchmarkRun? = nil
    var history: [BenchmarkRun] = []
    var error: String? = nil

    struct BenchmarkRun: Identifiable {
        let id = UUID()
        let date: Date
        let modelName: String
        let prompt: String
        let tokensGenerated: Int
        let promptTokens: Int
        let durationSeconds: Double
        let cacheHitRate: Double
        let flashBandwidthGBps: Double
        let dramUsedMB: Double
        let gpuEnabled: Bool

        var tokensPerSecond: Double {
            durationSeconds > 0 ? Double(tokensGenerated) / durationSeconds : 0
        }

        var msPerToken: Double {
            tokensGenerated > 0 ? durationSeconds * 1000 / Double(tokensGenerated) : 0
        }

        /// Paper's reported baseline: OPT-6.7B on M1 Max = 87ms/tok
        static let paperBaseline: Double = 87.0

        var speedupVsPaper: Double {
            guard msPerToken > 0 else { return 0 }
            return Self.paperBaseline / msPerToken
        }

        var grade: String {
            switch tokensPerSecond {
            case 7...:  return "A+"
            case 5..<7: return "A"
            case 3..<5: return "B"
            case 1..<3: return "C"
            default:    return "D"
            }
        }
    }
}

// MARK: - Benchmark View

struct FlashBenchmarkView: View {
    @Environment(\.dismiss) var dismiss

    let backend: FlashInferenceBackend
    let modelName: String

    @State private var state = FlashBenchmarkState()
    @State private var selectedPromptIdx = 0
    @State private var customPrompt = ""
    @State private var tokenCount = 64

    private let builtinPrompts = [
        ("Code: Fibonacci", "Write a JavaScript function that computes fibonacci numbers using memoization."),
        ("Story: Dragon", "Once upon a time, there was a dragon who loved to write JavaScript. One day"),
        ("Math explanation", "Explain gradient descent to a 10-year-old. Use a simple analogy from everyday life."),
        ("Repeat token stress", "The quick brown fox jumps over the lazy dog. " + String(repeating: "Repeat. ", count: 20)),
    ]

    private var activePrompt: String {
        if selectedPromptIdx == builtinPrompts.count {
            return customPrompt.isEmpty ? "Hello, world!" : customPrompt
        }
        return builtinPrompts[selectedPromptIdx].1
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Configuration
                    configCard

                    // Run button
                    if !state.isRunning {
                        runButton
                    } else {
                        runningCard
                    }

                    // Current result
                    if let run = state.currentRun {
                        resultCard(run)
                    }

                    // History
                    if state.history.count > 0 {
                        historyCard
                    }

                    // Paper comparison
                    paperComparisonCard

                    if let err = state.error {
                        errorCard(err)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Flash Benchmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Config Card

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Benchmark Setup", systemImage: "stopwatch")
                .font(.subheadline.weight(.semibold))

            Text("Model: **\(modelName)**")
                .font(.caption)
                .foregroundStyle(Color.secondary)

            // Prompt selector
            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt").font(.caption).foregroundStyle(Color.secondary)
                Picker("Prompt", selection: $selectedPromptIdx) {
                    ForEach(0..<builtinPrompts.count, id: \.self) { i in
                        Text(builtinPrompts[i].0).tag(i)
                    }
                    Text("Custom").tag(builtinPrompts.count)
                }
                .pickerStyle(.menu)

                if selectedPromptIdx == builtinPrompts.count {
                    TextField("Enter prompt…", text: $customPrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3)
                }
            }

            // Token count slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Tokens to generate").font(.caption).foregroundStyle(Color.secondary)
                    Spacer()
                    Text("\(tokenCount)").font(.caption.weight(.bold)).monospacedDigit()
                }
                Slider(value: Binding(
                    get: { Double(tokenCount) },
                    set: { tokenCount = Int($0) }
                ), in: 16...256, step: 16)
                .tint(Color.flashAccent)
            }
        }
        .padding(14)
        .background(Color.adaptiveSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Run Button

    private var runButton: some View {
        Button {
            runBenchmark()
        } label: {
            HStack {
                Image(systemName: "bolt.fill")
                Text("Run Benchmark")
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.flashAccent)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Running Card

    private var runningCard: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(Color.flashAccent)

            Text("Generating \(tokenCount) tokens…")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)

            Text("Measuring flash I/O, cache hit rate, and GPU utilisation")
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color.adaptiveSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Result Card

    private func resultCard(_ run: FlashBenchmarkState.BenchmarkRun) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Latest Result", systemImage: "chart.bar.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                gradeTag(run.grade)
            }

            // Main metrics grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                metricCell(
                    value: String(format: "%.2f", run.tokensPerSecond),
                    unit: "tok/s",
                    label: "Speed",
                    accent: speedColor(run.tokensPerSecond)
                )
                metricCell(
                    value: String(format: "%.0f", run.msPerToken),
                    unit: "ms/tok",
                    label: "Latency",
                    accent: latencyColor(run.msPerToken)
                )
                metricCell(
                    value: String(format: "%.0f%%", run.cacheHitRate * 100),
                    unit: "hit rate",
                    label: "Cache",
                    accent: run.cacheHitRate > 0.7 ? .green : .orange
                )
                metricCell(
                    value: String(format: "%.1f", run.flashBandwidthGBps),
                    unit: "GB/s",
                    label: "SSD Bandwidth",
                    accent: .blue
                )
            }

            Divider()

            // Secondary metrics
            HStack(spacing: 12) {
                Label(String(format: "%.0f MB DRAM", run.dramUsedMB), systemImage: "memorychip")
                Spacer()
                Label("\(run.tokensGenerated) tokens in \(String(format: "%.1fs", run.durationSeconds))",
                      systemImage: "timer")
                Spacer()
                Label(run.gpuEnabled ? "GPU" : "CPU", systemImage: run.gpuEnabled ? "cpu.fill" : "cpu")
                    .foregroundStyle(run.gpuEnabled ? Color.flashAccent : .secondary)
            }
            .font(.caption)
            .foregroundStyle(Color.secondary)

            // vs paper
            if run.speedupVsPaper > 0 {
                HStack {
                    Image(systemName: "doc.text")
                    Text("vs. paper (M1 Max, 87ms/tok): ")
                    Text(String(format: "%.1f×", run.speedupVsPaper))
                        .fontWeight(.bold)
                        .foregroundStyle(run.speedupVsPaper > 1 ? .green : .orange)
                }
                .font(.caption)
                .foregroundStyle(Color.secondary)
            }
        }
        .padding(14)
        .background(Color.adaptiveSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - History Card

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("History", systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.semibold))

            ForEach(state.history.prefix(5)) { run in
                HStack {
                    gradeTag(run.grade)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.prompt.prefix(40) + "…")
                            .font(.caption)
                            .lineLimit(1)
                        Text(run.date.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.2f tok/s", run.tokensPerSecond))
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                        Text(String(format: "%.0f ms/tok", run.msPerToken))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .background(Color.adaptiveSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Paper Comparison Card

    private var paperComparisonCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Paper Benchmarks (M1 Max)", systemImage: "doc.text.magnifyingglass")
                .font(.subheadline.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Model").font(.caption).foregroundStyle(Color.secondary)
                    Text("Method").font(.caption).foregroundStyle(Color.secondary)
                    Text("Latency").font(.caption).foregroundStyle(Color.secondary)
                    Text("Speedup").font(.caption).foregroundStyle(Color.secondary)
                }
                Divider()
                paperRow("OPT-6.7B", "Naive",            "2196 ms", "1.0×")
                paperRow("OPT-6.7B", "All (CPU)",         "669 ms",  "3.3×")
                paperRow("OPT-6.7B", "All (Metal M1)",    "565 ms",  "3.9×")
                paperRow("OPT-6.7B", "All (Metal M2)",    "305 ms",  "7.2×")
                paperRow("Falcon-7B","All (CPU)",         "706 ms",  "4.4×")
            }
            .font(.caption)

            Text("Source: Alizadeh et al. 2023 — \"LLM in a Flash\"")
                .font(.caption2)
                .foregroundStyle(Color.secondary)
                .italic()
        }
        .padding(14)
        .background(Color.adaptiveSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func paperRow(_ model: String, _ method: String, _ latency: String, _ speedup: String) -> some View {
        GridRow {
            Text(model).foregroundStyle(.primary)
            Text(method).foregroundStyle(Color.secondary)
            Text(latency).monospacedDigit()
            Text(speedup).foregroundStyle(Color.flashAccent).monospacedDigit()
        }
    }

    // MARK: - Error Card

    private func errorCard(_ error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(error).font(.caption)
        }
        .padding(12)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

    private func gradeTag(_ grade: String) -> some View {
        Text(grade)
            .font(.caption2.weight(.black))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(gradeColor(grade).opacity(0.15))
            .foregroundStyle(gradeColor(grade))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func gradeColor(_ grade: String) -> Color {
        switch grade {
        case "A+", "A": return .green
        case "B": return .yellow
        case "C": return .orange
        default: return .red
        }
    }

    private func metricCell(value: String, unit: String, label: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(Color.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title3.weight(.bold)).monospacedDigit().foregroundStyle(accent)
                Text(unit).font(.caption2).foregroundStyle(Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(accent.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func speedColor(_ tps: Double) -> Color {
        tps > 5 ? .green : tps > 2 ? .yellow : .orange
    }

    private func latencyColor(_ ms: Double) -> Color {
        ms < 150 ? .green : ms < 300 ? .yellow : .red
    }

    // MARK: - Benchmark Execution

    private func runBenchmark() {
        state.isRunning = true
        state.error = nil

        let prompt = activePrompt
        let targetTokens = tokenCount
        let model = modelName

        Task {
            do {
                let request = GenerationRequest(
                    task: .generate,
                    prompt: prompt,
                    maxTokens: targetTokens,
                    temperature: 0.0  // Greedy for deterministic benchmark
                )

                let start = Date()
                let response = try await backend.generate(request: request)
                let elapsed = Date().timeIntervalSince(start)

                // Collect flash metrics
                let cacheMetrics = await backend.cacheMetrics()
                let ioMetrics = await backend.ioMetrics()
                let gpuEnabled = await backend.gpuPipeline != nil

                let run = FlashBenchmarkState.BenchmarkRun(
                    date: Date(),
                    modelName: model,
                    prompt: prompt.prefix(80).description,
                    tokensGenerated: response.completionTokens,
                    promptTokens: response.promptTokens,
                    durationSeconds: elapsed,
                    cacheHitRate: cacheMetrics?.averageHitRate ?? 0,
                    flashBandwidthGBps: ioMetrics.map {
                        $0.totalBytesRead > 0 ? Double($0.totalBytesRead) / elapsed / 1e9 : 0
                    } ?? 0,
                    dramUsedMB: cacheMetrics?.estimatedDRAMUsedMB ?? 0,
                    gpuEnabled: gpuEnabled
                )

                await MainActor.run {
                    state.currentRun = run
                    state.history.insert(run, at: 0)
                    if state.history.count > 20 { state.history.removeLast() }
                    state.isRunning = false
                }

            } catch {
                await MainActor.run {
                    state.error = error.localizedDescription
                    state.isRunning = false
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    FlashBenchmarkView(
        backend: FlashInferenceBackend(),
        modelName: "LLaMA-2-7B (Flash)"
    )
}
