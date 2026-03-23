import SwiftUI

// MARK: - Flash Conversion View
//
// Converts a .gguf model file to .flashpack format in-app.
// The conversion runs in the background while showing live progress.

struct FlashConversionView: View {
    @Environment(\.dismiss) var dismiss
    let sourcePath: String
    let modelName: String

    @State private var progress = FlashConversionProgress()
    @State private var selectedOptions = FlashConversionOptions.default
    @State private var showOptions = false
    @State private var conversionTask: Task<Void, Never>?

    private var outputPath: String {
        let url = URL(fileURLWithPath: sourcePath)
        let base = url.deletingPathExtension().path
        return base + ".flashpack"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Header card
                    headerCard

                    // Options
                    optionsCard

                    // Progress (shown during conversion)
                    if progress.isConverting || progress.fraction > 0 {
                        progressCard
                    }

                    // Done state
                    if let output = progress.outputPath {
                        successCard(output: output)
                    }

                    // Error state
                    if let error = progress.error {
                        errorCard(error: error)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Convert to Flash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        conversionTask?.cancel()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Cards

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("LLM in a Flash Converter", systemImage: "bolt.fill")
                .font(.headline)
                .foregroundStyle(Color.flashAccent)

            Text("Converts **\(modelName)** from GGUF to FlashPack format, enabling it to run on devices where it wouldn't fit in DRAM.")
                .font(.callout)
                .foregroundStyle(Color.secondary)

            // Source → Output arrow
            HStack(spacing: 8) {
                fileTag(URL(fileURLWithPath: sourcePath).lastPathComponent, icon: "doc")
                Image(systemName: "arrow.right")
                    .foregroundStyle(Color.secondary)
                fileTag(URL(fileURLWithPath: outputPath).lastPathComponent, icon: "bolt.doc")
            }
            .font(.caption)
        }
        .padding(14)
        .background(Color.adaptiveSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation { showOptions.toggle() }
            } label: {
                HStack {
                    Label("Conversion Options", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: showOptions ? "chevron.up" : "chevron.down")
                        .foregroundStyle(Color.secondary)
                }
            }
            .foregroundStyle(.primary)

            if showOptions {
                Divider()

                // FFN Quantization picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("FFN Weight Precision")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)

                    Picker("", selection: $selectedOptions.ffnQuantization) {
                        Text("Float16 (best quality, 2× compression)").tag(FlashDType.float16)
                        Text("INT8 (good quality, 4× compression)").tag(FlashDType.int8)
                        Text("INT4/Q2 (experimental, 8× compression)").tag(FlashDType.int4)
                    }
                    .pickerStyle(.menu)

                    if selectedOptions.ffnQuantization == .int4 {
                        Label("Q2 quantization may reduce output quality. RMSE typically 0.001–0.003.", systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                // Importance scores toggle
                Toggle(isOn: $selectedOptions.computeImportance) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Compute Neuron Importance")
                            .font(.subheadline)
                        Text("Pre-warm cache with most-active neurons")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }

            // Start button
            if !progress.isConverting && progress.outputPath == nil {
                Button {
                    startConversion()
                } label: {
                    HStack {
                        Image(systemName: "bolt.fill")
                        Text("Convert Now")
                    }
                    .font(.headline)
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

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(Color.flashAccent)
                Text("Converting…")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if progress.isConverting {
                    Button("Stop") {
                        conversionTask?.cancel()
                        progress.isConverting = false
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }

            ProgressView(value: progress.fraction)
                .tint(Color.flashAccent)

            HStack {
                Text(progress.message)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
                Spacer()
                Text(String(format: "%.0f%%", progress.fraction * 100))
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
            }

            // Compression preview
            if progress.fraction > 0.1 {
                let sourceGB = (try? FileManager.default.attributesOfItem(atPath: sourcePath)[.size] as? Int64).map { Double($0) / 1e9 } ?? 0
                if sourceGB > 0 {
                    let ratio = selectedOptions.ffnQuantization == .int4 ? 3.0 :
                                selectedOptions.ffnQuantization == .int8 ? 2.0 : 1.4
                    HStack(spacing: 8) {
                        compressionBadge("Original", value: String(format: "%.1f GB", sourceGB), color: .secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        compressionBadge("FlashPack", value: String(format: "%.1f GB", sourceGB / ratio), color: .flashAccent)
                        Text(String(format: "%.1f× smaller", ratio))
                            .font(.caption2)
                            .foregroundStyle(Color.flashAccent)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.adaptiveSecondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func successCard(output: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)

            Text("Conversion Complete!")
                .font(.headline)

            Text(URL(fileURLWithPath: output).lastPathComponent)
                .font(.caption)
                .foregroundStyle(Color.secondary)

            Button("Use This Model") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.flashAccent)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func errorCard(error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Conversion Failed", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.subheadline.weight(.semibold))

            Text(error)
                .font(.caption)
                .foregroundStyle(Color.secondary)

            Button("Try Again") {
                progress.error = nil
                progress.fraction = 0
                progress.outputPath = nil
                startConversion()
            }
            .font(.caption)
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    private func fileTag(_ name: String, icon: String) -> some View {
        Label(name, systemImage: icon)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .clipShape(Capsule())
    }

    private func compressionBadge(_ label: String, value: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(Color.secondary)
            Text(value).font(.caption.weight(.bold)).foregroundStyle(color)
        }
    }

    // MARK: - Conversion

    private func startConversion() {
        progress.isConverting = true
        progress.fraction = 0
        progress.error = nil
        progress.outputPath = nil

        let opts = selectedOptions
        let src = sourcePath
        let out = outputPath

        conversionTask = Task {
            do {
                try await FlashModelConverter.convert(
                    ggufPath: src,
                    outputPath: out,
                    options: opts
                ) { [weak progress] fraction, message in
                    Task { @MainActor in
                        progress?.fraction = fraction
                        progress?.message = message
                    }
                }

                await MainActor.run {
                    progress.isConverting = false
                    progress.fraction = 1.0
                    progress.outputPath = out
                }
            } catch {
                await MainActor.run {
                    progress.isConverting = false
                    progress.error = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    FlashConversionView(
        sourcePath: "/Documents/Models/llama-2-7b.gguf",
        modelName: "LLaMA-2-7B-Q4_K_M"
    )
}
