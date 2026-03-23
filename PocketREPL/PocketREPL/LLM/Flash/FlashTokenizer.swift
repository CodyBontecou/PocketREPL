import Foundation
import llama

// MARK: - Flash Tokenizer
//
// Real tokenization using llama.cpp's built-in BPE/SentencePiece tokenizer.
//
// The tokenizer is loaded from a GGUF file — either the full model file,
// a tokenizer-only GGUF, or a companion file alongside the FlashPack.
//
// Companion file resolution order for model.flashpack:
//   1. model.flashpack.tokenizer.gguf   (explicit tokenizer sidecar)
//   2. model.gguf                        (original source model)
//   3. Any .gguf in the same directory   (fallback scan)
//
// The model is loaded with `n_gpu_layers = 0` and a tiny context so only
// the vocabulary is allocated — negligible memory (< 10 MB).

// MARK: - Tokenizer

/// Thread-safe tokenizer backed by llama.cpp's vocabulary.
final class FlashTokenizer: @unchecked Sendable {

    // MARK: - Types

    struct TokenInfo: Sendable {
        let text: String
        let score: Float
        let isBOS: Bool
        let isEOS: Bool
        let isSpecial: Bool
    }

    // MARK: - Properties

    private let model: OpaquePointer
    let vocab: OpaquePointer

    let vocabSize: Int
    let bosToken: Int32
    let eosToken: Int32
    let eotToken: Int32
    let unknownToken: Int32

    private let lock = NSLock()

    // MARK: - Initialization

    /// Load tokenizer from a GGUF model file.
    ///
    /// - Parameter path: Path to any GGUF file that contains the vocabulary.
    ///   This can be a full model file or a tokenizer-only GGUF.
    init(modelPath path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw FlashModelError.fileNotFound(path: path)
        }

        // Load model with vocab-only settings:
        // - Zero GPU layers (no inference needed)
        // - Minimal memory allocation (just vocab tables)
        var params = llama_model_default_params()
        params.n_gpu_layers = 0
        params.use_mmap = true       // mmap the file — fast vocab load
        params.vocab_only = true     // Only load vocabulary, skip weights

        guard let m = llama_model_load_from_file(path, params) else {
            throw FlashModelError.headerParseFailure(
                "Failed to load tokenizer vocabulary from: \(path)"
            )
        }

        self.model = m
        let v = llama_model_get_vocab(m)!
        self.vocab = v

        self.vocabSize = Int(llama_vocab_n_tokens(v))
        self.bosToken = llama_vocab_bos(v)
        self.eosToken = llama_vocab_eos(v)
        self.eotToken = llama_vocab_eot(v)
        self.unknownToken = 0  // Token 0 is typically the unknown token
    }

    deinit {
        llama_model_free(model)
    }

    // MARK: - Tokenization

    /// Convert text to a sequence of token IDs.
    ///
    /// - Parameters:
    ///   - text:    Input text to tokenize.
    ///   - addBOS:  Prepend BOS (beginning-of-sequence) token.
    ///   - special: Allow special tokens in the output (e.g., `<|im_start|>`).
    /// - Returns: Array of token IDs.
    func tokenize(_ text: String, addBOS: Bool = true, special: Bool = true) -> [Int32] {
        lock.lock()
        defer { lock.unlock() }

        // Initial estimate: assume ~4 chars/token. If too small, we re-run.
        var estimatedCount = text.count / 3 + 16
        var tokens = [llama_token](repeating: 0, count: estimatedCount)

        let utf8 = text.utf8CString
        let result = utf8.withUnsafeBufferPointer { buf -> Int32 in
            llama_tokenize(
                vocab,
                buf.baseAddress,
                Int32(text.utf8.count),
                &tokens,
                Int32(estimatedCount),
                addBOS,
                special
            )
        }

        if result < 0 {
            // Buffer too small — reallocate and retry
            estimatedCount = Int(-result) + 4
            tokens = [llama_token](repeating: 0, count: estimatedCount)
            let actual = utf8.withUnsafeBufferPointer { buf -> Int32 in
                llama_tokenize(
                    vocab,
                    buf.baseAddress,
                    Int32(text.utf8.count),
                    &tokens,
                    Int32(estimatedCount),
                    addBOS,
                    special
                )
            }
            return actual > 0 ? Array(tokens.prefix(Int(actual))) : [bosToken]
        }

        return result > 0 ? Array(tokens.prefix(Int(result))) : [bosToken]
    }

    /// Convert a single token ID to its string representation.
    func tokenToPiece(_ token: Int32, special: Bool = true) -> String {
        lock.lock()
        defer { lock.unlock() }

        var buffer = [CChar](repeating: 0, count: 256)
        let length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, special)

        if length < 0 {
            let needed = Int(-length)
            buffer = [CChar](repeating: 0, count: needed + 1)
            let actual = llama_token_to_piece(vocab, token, &buffer, Int32(needed + 1), 0, special)
            return actual > 0 ? String(bytes: buffer.prefix(Int(actual)).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? "" : ""
        }

        return length > 0 ? String(bytes: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? "" : ""
    }

    /// Convert a sequence of token IDs back to text.
    func detokenize(_ tokens: [Int32], special: Bool = false) -> String {
        tokens.map { tokenToPiece($0, special: special) }.joined()
    }

    /// Check whether a token signals end-of-generation.
    func isEndOfGeneration(_ token: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return llama_vocab_is_eog(vocab, token)
    }

    /// Retrieve metadata about a specific token.
    func tokenInfo(_ token: Int32) -> TokenInfo {
        lock.lock()
        defer { lock.unlock() }
        let text = String(cString: llama_vocab_get_text(vocab, token))
        let score = llama_vocab_get_score(vocab, token)
        let attr = llama_vocab_get_attr(vocab, token)
        return TokenInfo(
            text: text,
            score: score,
            isBOS: token == bosToken,
            isEOS: token == eosToken || token == eotToken,
            isSpecial: (attr.rawValue & LLAMA_TOKEN_ATTR_CONTROL.rawValue) != 0
        )
    }

    // MARK: - Chat Template Helpers

    /// Wrap a user message in the model's instruction format.
    ///
    /// Supports common templates:
    ///   - LLaMA-2: `[INST] {msg} [/INST]`
    ///   - ChatML:  `<|im_start|>user\n{msg}<|im_end|>\n<|im_start|>assistant\n`
    ///   - Phi-3:   `<|user|>\n{msg}<|end|>\n<|assistant|>`
    func wrapUserMessage(_ message: String, systemPrompt: String? = nil) -> String {
        // Detect template from vocabulary by looking for special tokens
        if llama_vocab_fim_pre(vocab) > 0 {
            // FIM-capable model (code completion) — use basic format
            return message
        }

        // Check for ChatML format
        let chatMLStart = tokenize("<|im_start|>", addBOS: false, special: true)
        if chatMLStart.count == 1 && chatMLStart[0] > 0 {
            var prompt = ""
            if let sys = systemPrompt {
                prompt += "<|im_start|>system\n\(sys)<|im_end|>\n"
            }
            prompt += "<|im_start|>user\n\(message)<|im_end|>\n<|im_start|>assistant\n"
            return prompt
        }

        // Check for LLaMA-2 format
        if let sys = systemPrompt {
            return "[INST] <<SYS>>\n\(sys)\n<</SYS>>\n\n\(message) [/INST]"
        }
        return "[INST] \(message) [/INST]"
    }
}

// MARK: - Companion Tokenizer Discovery

extension FlashTokenizer {

    /// Find the best companion GGUF file to use as a tokenizer for a FlashPack model.
    ///
    /// Search order:
    ///   1. `<modelBaseName>.tokenizer.gguf`  (explicit sidecar)
    ///   2. `<modelBaseName>.gguf`            (matching-name GGUF)
    ///   3. First `.gguf` in the same directory
    static func companionGGUFPath(for flashPackPath: String) -> String? {
        let url = URL(fileURLWithPath: flashPackPath)
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ".flashpack", with: "")

        let fm = FileManager.default

        // 1. Explicit tokenizer sidecar
        let sidecar = dir.appendingPathComponent("\(base).tokenizer.gguf").path
        if fm.fileExists(atPath: sidecar) { return sidecar }

        // 2. Matching-name GGUF
        let matchingGGUF = dir.appendingPathComponent("\(base).gguf").path
        if fm.fileExists(atPath: matchingGGUF) { return matchingGGUF }

        // 3. Any GGUF in same directory
        let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        if let first = contents.first(where: { $0.hasSuffix(".gguf") }) {
            return dir.appendingPathComponent(first).path
        }

        return nil
    }

    /// Load a tokenizer for a FlashPack model, searching for a companion GGUF.
    static func forFlashPack(at flashPackPath: String) throws -> FlashTokenizer {
        guard let ggufPath = companionGGUFPath(for: flashPackPath) else {
            throw FlashModelError.headerParseFailure(
                "No companion .gguf tokenizer found for \(flashPackPath). " +
                "Place a .gguf tokenizer file in the same directory."
            )
        }
        return try FlashTokenizer(modelPath: ggufPath)
    }
}

// MARK: - FlashInferenceBackend tokenizer integration

/// Holds a loaded tokenizer alongside the inference engine.
/// Loaded once at model load time and reused for all generation requests.
actor FlashTokenizerHolder {
    private(set) var tokenizer: FlashTokenizer?

    func set(_ t: FlashTokenizer) { tokenizer = t }
    func clear()                  { tokenizer = nil }

    func tokenize(_ text: String, addBOS: Bool = true) -> [Int32] {
        tokenizer?.tokenize(text, addBOS: addBOS) ?? []
    }

    func detokenize(_ tokens: [Int32]) -> String {
        tokenizer?.detokenize(tokens) ?? ""
    }

    func tokenToPiece(_ token: Int32) -> String {
        tokenizer?.tokenToPiece(token) ?? ""
    }

    func isEOG(_ token: Int32) -> Bool {
        tokenizer?.isEndOfGeneration(token) ?? (token <= 2)
    }
}
