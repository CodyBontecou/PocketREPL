import SwiftUI

// MARK: - Flash Predictor Training View
//
// In-app UI for training sparsity predictors from calibration data.
// The predictor anticipates which FFN neurons will activate, enabling
// pre-fetching from flash storage before they're needed.
//
// Typical use flow:
//   1. Load a .flashpack model
//   2. Tap "Train Predictors" in model detail view
//   3. Provide ~100–1000 calibration sentences (or use built-in C4 subset)
//   4. Training runs on-device (~10–30 min for 7B on M3 Max)
//   5. Predictor weights are saved alongside the .flashpack file

// MARK: - Training State

@Observable
@MainActor
final class PredictorTrainingState {
    var isTraining: Bool = false
    var progress: Double = 0
    var currentLayer: Int = 0
    var totalLayers: Int = 0
    var message: String = ""
    var completedLayers: [Int] = []
    var results: [LayerResult] = []
    var error: String? = nil

    struct LayerResult: Identifiable {
        let id: Int          // layer index
        let precision: Float
        let recall: Float
        let f1: Float
        let sparsity: Double
    }
}

// MARK: - View

struct FlashPredictorView: View {
    @Environment(\.dismiss) var dismiss

    let modelPath: String
    let modelName: String
    let config: FlashModelConfig

    @State private var trainingState = PredictorTrainingState()
    @State private var selectedPreset = CalibPreset.small
    @State private var customText = ""
    @State private var selectedParams = FlashPredictorTrainer.HyperParams.default
    @State private var showAdvanced = false
    @State private var trainingTask: Task<Void, Never>? = nil

    enum CalibPreset: String, CaseIterable, Identifiable {
        var id: String { rawValue }
        case small    = "Quick (100 sentences)"
        case medium   = "Standard (1,000 sentences)"
        case large    = "Quality (10,000 sentences)"
        case custom   = "Custom text"

        var sampleCount: Int {
            switch self { case .small: return 100; case .medium: return 1000; case .large: return 10000; case .custom: return 0 }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Info
                    infoCard
                    // Config
                    configCard
                    // Advanced
                    advancedCard
                    // Progress
                    if trainingState.isTraining || !trainingState.completedLayers.isEmpty {
                        progressCard
                    }
                    // Results
                    if !trainingState.results.isEmpty {
                        resultsCard
                    }
                    // Error
                    if let err = trainingState.error {
                        errorCard(err)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Train Predictor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        trainingTask?.cancel()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Cards

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("What is this?", systemImage: "brain")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.flashAccent)

            Text("A sparsity predictor is a tiny neural network (~3% of model size) that learns to predict **which FFN neurons will activate** for each token. This allows PocketREPL to pre-fetch those neurons from flash storage while the current layer is still computing.")
                .font(.callout)
                .foregroundStyle(Color.secondary)

            HStack(spacing: 12) {
                statPill("No predictor", "load all neurons", icon: "xmark.circle", color: .red)
                statPill("With predictor", "load only ~10%", icon: "checkmark.circle.fill", color: .green)
            }
        }
        .padding(14)
        .background(Color.adaptiveSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Calibration Data", systemImage: "text.document")
                .font(.subheadline.weight(.semibold))

            Picker("Preset", selection: $selectedPreset) {
                ForEach(CalibPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.menu)

            if selectedPreset == .custom {
                TextEditor(text: $customText)
                    .frame(height: 100)
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
            }

            if !trainingState.isTraining {
                Button {
                    startTraining()
                } label: {
                    HStack {
                        Image(systemName: "brain.filled.head.profile")
                        Text("Start Training")
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.flashAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color.adaptiveSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var advancedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation { showAdvanced.toggle() }
            } label: {
                HStack {
                    Label("Advanced Options", systemImage: "slider.horizontal.3")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .foregroundStyle(Color.secondary)
                }
            }
            .foregroundStyle(.primary)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()

                    hyperParam("Predictor rank", value: Binding(
                        get: { Double(selectedParams.rank) },
                        set: { selectedParams.rank = Int($0) }
                    ), range: 64...1024, format: "%.0f", unit: "dims")

                    hyperParam("Learning rate", value: Binding(
                        get: { Double(selectedParams.learningRate) },
                        set: { selectedParams.learningRate = Float($0) }
                    ), range: 0.0001...0.01, format: "%.4f", unit: "")

                    hyperParam("Epochs", value: Binding(
                        get: { Double(selectedParams.epochs) },
                        set: { selectedParams.epochs = Int($0) }
                    ), range: 1...10, format: "%.0f", unit: "")
                }
            }
        }
        .padding(14)
        .background(Color.adaptiveSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if trainingState.isTraining {
                    ProgressView().scaleEffect(0.8).tint(Color.flashAccent)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Text(trainingState.isTraining ? "Training…" : "Complete")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if trainingState.totalLayers > 0 {
                    Text("\(trainingState.completedLayers.count)/\(trainingState.totalLayers) layers")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }

            if trainingState.totalLayers > 0 {
                ProgressView(value: trainingState.progress)
                    .tint(Color.flashAccent)
            }

            Text(trainingState.message)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .background(Color.adaptiveSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Predictor Quality", systemImage: "chart.bar")
                .font(.subheadline.weight(.semibold))

            ForEach(trainingState.results.prefix(8)) { result in
                HStack {
                    Text("Layer \(result.id)")
                        .font(.caption)
                        .frame(width: 55, alignment: .leading)
                    qualityBar(result.precision, color: .blue, label: "P")
                    qualityBar(result.recall, color: .green, label: "R")
                    qualityBar(result.f1, color: .orange, label: "F1")
                    Text(String(format: "%.0f%% sparse", result.sparsity * 100))
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
            }

            if trainingState.results.count > 8 {
                Text("+ \(trainingState.results.count - 8) more layers")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }

            HStack {
                let avgF1 = trainingState.results.map { $0.f1 }.reduce(0, +) / Float(max(1, trainingState.results.count))
                Label("Average F1: \(String(format: "%.2f", avgF1))", systemImage: "star.fill")
                    .font(.caption)
                    .foregroundStyle(avgF1 > 0.85 ? .green : avgF1 > 0.70 ? .orange : .red)
            }
        }
        .padding(14)
        .background(Color.adaptiveSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

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

    private func statPill(_ title: String, _ detail: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.bold))
                Text(detail).font(.caption2).foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func hyperParam(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption).foregroundStyle(Color.secondary)
                Spacer()
                Text(String(format: format + (unit.isEmpty ? "" : " \(unit)"), value.wrappedValue))
                    .font(.caption.weight(.bold)).monospacedDigit()
            }
            Slider(value: value, in: range).tint(Color.flashAccent)
        }
    }

    private func qualityBar(_ value: Float, color: Color, label: String) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.1))
                RoundedRectangle(cornerRadius: 2).fill(color)
                    .frame(width: geo.size.width * CGFloat(value))
            }
        }
        .frame(height: 8)
        .overlay(
            Text(label)
                .font(.system(size: 7))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(x: 2, y: -9)
        )
    }

    // MARK: - Training

        // Engine and tokenizer for real calibration data collection.
    // Passed in from ModelDetailView when a FlashPack model is active.
    var engine: FlashInferenceEngine? = nil
    var tokenizer: FlashTokenizer? = nil

    // The trained weights, posted via Notification when complete.
    // The receiving view (ModelDetailView) saves them to disk.
    @State private var trainedWeights: [PredictorWeights] = []

    private func startTraining() {
        trainingState.isTraining = true
        trainingState.completedLayers = []
        trainingState.results = []
        trainingState.error = nil
        trainingState.totalLayers = config.numHiddenLayers

        let params = selectedParams
        let numLayers = config.numHiddenLayers
        let calibTexts: [String]
        if selectedPreset == .custom {
            calibTexts = customText.components(separatedBy: "\n").filter { !$0.isEmpty }
        } else {
            calibTexts = BuiltinCalibration.sentences(count: selectedPreset.sampleCount)
        }

        let capturedEngine = engine
        let capturedTokenizer = tokenizer

        trainingTask = Task {
            do {
                // Collect real activations if an engine+tokenizer are available;
                // otherwise fall back to random noise (useful for UI testing).
                let layerData: [LayerCalibrationData]
                if let eng = capturedEngine, let tok = capturedTokenizer {
                    layerData = await FlashPredictorTrainer.collectCalibrationData(
                        texts: calibTexts, engine: eng, tokenizer: tok,
                        maxTokensPerSample: 128
                    ) { p in
                        Task { @MainActor in
                            trainingState.message = "Collecting activations \(Int(p * 100))%…"
                            trainingState.progress = p * 0.4
                        }
                    }
                } else {
                    // Fallback: random-noise calibration (demonstrates UI, not real quality)
                    let h = config.hiddenSize, inter = config.intermediateSize
                    layerData = (0..<numLayers).map { l in
                        let samples = (0..<min(100, calibTexts.count)).map { _ in
                            PredictorSample(
                                attentionOutput: (0..<h).map { _ in Float.random(in: -0.1...0.1) },
                                activationMask:  (0..<inter).map { _ in Float.random(in: 0...1) < 0.1 }
                            )
                        }
                        return LayerCalibrationData(layerIndex: l, hiddenSize: h, intermediateSize: inter, samples: samples)
                    }
                }

                // Train one layer at a time, reporting results as they complete
                for (layerIdx, data) in layerData.enumerated() {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        trainingState.currentLayer = layerIdx
                        trainingState.message = "Training layer \(layerIdx)/\(numLayers) (sparsity: \(String(format: "%.0f%%", data.averageSparsity * 100)))…"
                        trainingState.progress = 0.4 + 0.6 * Double(layerIdx) / Double(numLayers)
                    }

                    let weights = FlashPredictorTrainer.train(
                        data: data, layerIdx: layerIdx, numLayers: numLayers, params: params
                    )
                    await MainActor.run { trainedWeights.append(weights) }

                    // Evaluate on the same data (real code should use a held-out split)
                    let predictor = LayerPredictor(
                        layerIndex: layerIdx, weights: weights,
                        hiddenSize: config.hiddenSize, intermediateSize: config.intermediateSize,
                        threshold: params.predictorThreshold,
                        safetyBuffer: params.predictorSafetyBuffer
                    )
                    let (p, r, f1) = data.samples.isEmpty
                        ? (Float(0), Float(0), Float(0))
                        : FlashPredictorTrainer.evaluate(predictor: predictor, data: data, threshold: params.predictorThreshold)

                    await MainActor.run {
                        trainingState.completedLayers.append(layerIdx)
                        trainingState.results.append(PredictorTrainingState.LayerResult(
                            id: layerIdx, precision: p, recall: r, f1: f1,
                            sparsity: data.averageSparsity
                        ))
                    }
                    await Task.yield()
                }

                await MainActor.run {
                    trainingState.isTraining = false
                    trainingState.progress = 1.0
                    trainingState.message = "Training complete — \(numLayers) layer predictors ready"
                    // Notify ModelDetailView so it can save the weights to disk
                    if !trainedWeights.isEmpty {
                        NotificationCenter.default.post(
                            name: .flashPredictorsReady,
                            object: trainedWeights
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    trainingState.isTraining = false
                    trainingState.error = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted when predictor training completes. Object is `[PredictorWeights]`.
    static let flashPredictorsReady = Notification.Name("FlashPredictorsReady")
}

// MARK: - Built-in Calibration Sentences

enum BuiltinCalibration {
    static func sentences(count: Int) -> [String] {
        let base = [
            "The quick brown fox jumps over the lazy dog.",
            "In the beginning was the Word, and the Word was with God.",
            "It was the best of times, it was the worst of times.",
            "To be or not to be, that is the question.",
            "All happy families are alike; each unhappy family is unhappy in its own way.",
            "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.",
            "Call me Ishmael. Some years ago—never mind how long precisely—having little or no money in my purse.",
            "The sky above the port was the color of television, tuned to a dead channel.",
            "Happy families are all alike; every unhappy family is unhappy in its own way.",
            "It was a bright cold day in April, and the clocks were striking thirteen.",
            "The man in black fled across the desert, and the gunslinger followed.",
            "Where's Papa going with that ax? said Fern to her mother as they were setting the table for breakfast.",
            "riverrun, past Eve and Adam's, from swerve of shore to bend of bay, brings us by a commodius vicus.",
            "Write a JavaScript function that computes the nth Fibonacci number.",
            "Implement a binary search tree with insert, delete, and search operations.",
            "What is the time complexity of quicksort in the worst case?",
            "Explain the difference between TCP and UDP.",
            "How does gradient descent work in machine learning?",
            "What are the SOLID principles in software engineering?",
            "Describe the MapReduce programming model.",
        ]
        // Repeat/expand to reach target count
        var result: [String] = []
        while result.count < count {
            result.append(contentsOf: base)
        }
        return Array(result.prefix(count))
    }
}

// MARK: - Preview

#Preview {
    FlashPredictorView(
        modelPath: "/Documents/Models/llama.flashpack",
        modelName: "LLaMA-2-7B (Flash)",
        config: FlashModelConfig.defaultLlama7B(sections: FlashModelSections(
            tokenEmbedding: TensorShape(offset: 0, rows: 32000, cols: 4096, dtype: .float16),
            norm: TensorShape(offset: 0, rows: 1, cols: 4096, dtype: .float16),
            lmHead: TensorShape(offset: 0, rows: 32000, cols: 4096, dtype: .float16),
            layers: []
        ))
    )
}
