import Foundation

/// A mock model backend for testing without real model inference.
/// Useful for UI development and testing the orchestration flow.
actor MockModelBackend: ModelBackend {
    private(set) var state: ModelState = .unloaded
    private(set) var modelInfo: ModelInfo?
    
    private var isCancelled = false
    private var configuration: ModelConfiguration?
    
    /// Simulated generation delay in seconds per token.
    var simulatedTokenDelay: Double = 0.05
    
    /// Whether to simulate errors.
    var simulateErrors: Bool = false
    
    // MARK: - Context Tracking (Mock)
    
    /// Simulated current context tokens (increases with each generation)
    private var _currentContextTokens: Int = 0
    
    var currentContextTokens: Int {
        _currentContextTokens
    }
    
    var maxContextTokens: Int {
        configuration?.contextSize ?? 4096
    }
    
    func load(configuration: ModelConfiguration) async throws {
        guard state == .unloaded || state == .error(.cancelled) else {
            throw ModelError.invalidConfiguration(reason: "Model already loaded or loading")
        }
        
        self.configuration = configuration
        
        // Simulate loading progress
        for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
            state = .loading(progress: progress)
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
        
        // Check if model file exists (for realistic behavior)
        if !FileManager.default.fileExists(atPath: configuration.modelPath) {
            // In mock mode, we don't require the actual file
            // but we simulate the check
        }
        
        modelInfo = ModelInfo(
            name: "MockModel-1.5B",
            parameterCount: "1.5B",
            contextSize: configuration.contextSize,
            memoryUsage: 1_500_000_000, // 1.5GB simulated
            quantization: "Q4_K_M"
        )
        
        state = .ready
    }
    
    func unload() async {
        state = .unloaded
        modelInfo = nil
        configuration = nil
    }
    
    func generate(request: GenerationRequest) async throws -> GenerationResponse {
        guard state.isReady else {
            throw ModelError.invalidConfiguration(reason: "Model not ready")
        }
        
        if simulateErrors {
            throw ModelError.inferenceError(reason: "Simulated error for testing")
        }
        
        isCancelled = false
        let startTime = Date()
        
        let response = generateMockResponse(for: request)
        
        // Simulate generation time
        let tokenCount = estimateTokens(for: response)
        let totalDelay = Double(tokenCount) * simulatedTokenDelay
        try await Task.sleep(nanoseconds: UInt64(totalDelay * 1_000_000_000))
        
        if isCancelled {
            throw ModelError.cancelled
        }
        
        let duration = Date().timeIntervalSince(startTime)
        
        return GenerationResponse(
            text: response,
            promptTokens: estimateTokens(for: request.prompt + (request.existingCode ?? "")),
            completionTokens: tokenCount,
            durationSeconds: duration,
            finishReason: .complete
        )
    }
    
    func generateStreaming(request: GenerationRequest) async throws -> StreamedGeneration {
        guard state.isReady else {
            throw ModelError.invalidConfiguration(reason: "Model not ready")
        }
        
        isCancelled = false
        let response = generateMockResponse(for: request)
        
        let stream = AsyncThrowingStream<GenerationToken, Error> { continuation in
            Task {
                // Split response into "tokens" (words/chunks for simulation)
                let tokens = response.components(separatedBy: .whitespaces)
                
                for (index, token) in tokens.enumerated() {
                    if self.isCancelled {
                        continuation.finish(throwing: ModelError.cancelled)
                        return
                    }
                    
                    // Add space before word (except first)
                    let text = index == 0 ? token : " " + token
                    
                    continuation.yield(GenerationToken(
                        text: text,
                        tokenIndex: index,
                        isLast: index == tokens.count - 1
                    ))
                    
                    // Simulate token generation delay
                    try? await Task.sleep(nanoseconds: UInt64(self.simulatedTokenDelay * 1_000_000_000))
                }
                
                continuation.finish()
            }
        }
        
        return StreamedGeneration(stream)
    }
    
    func cancel() async {
        isCancelled = true
    }
    
    nonisolated func estimateTokens(for text: String) -> Int {
        // Rough estimate: ~4 characters per token for code
        return max(1, text.count / 4)
    }
    
    // MARK: - Mock Response Generation
    
    private func generateMockResponse(for request: GenerationRequest) -> String {
        switch request.task {
        case .generate:
            return generateCodeMock(prompt: request.prompt)
        case .fix:
            return fixCodeMock(code: request.existingCode ?? "", error: request.errorMessage ?? "Unknown error")
        case .complete:
            return completeCodeMock(code: request.existingCode ?? "")
        case .explain:
            return explainCodeMock(code: request.existingCode ?? "")
        }
    }
    
    private func generateCodeMock(prompt: String) -> String {
        // Simple mock that returns template code based on keywords in prompt
        let lowerPrompt = prompt.lowercased()
        
        if lowerPrompt.contains("hello") || lowerPrompt.contains("greeting") {
            return """
                // Hello World example
                function greet(name) {
                    return `Hello, ${name}!`;
                }
                
                console.log(greet('World'));
                """
        }
        
        if lowerPrompt.contains("fibonacci") || lowerPrompt.contains("fib") {
            return """
                // Fibonacci sequence
                function fibonacci(n) {
                    if (n <= 1) return n;
                    return fibonacci(n - 1) + fibonacci(n - 2);
                }
                
                for (let i = 0; i < 10; i++) {
                    console.log(`fib(${i}) = ${fibonacci(i)}`);
                }
                """
        }
        
        if lowerPrompt.contains("sort") || lowerPrompt.contains("array") {
            return """
                // Array sorting example
                function quickSort(arr) {
                    if (arr.length <= 1) return arr;
                    const pivot = arr[0];
                    const left = arr.slice(1).filter(x => x < pivot);
                    const right = arr.slice(1).filter(x => x >= pivot);
                    return [...quickSort(left), pivot, ...quickSort(right)];
                }
                
                const numbers = [5, 2, 8, 1, 9, 3];
                console.log('Sorted:', quickSort(numbers));
                """
        }
        
        // Default response
        return """
            // Generated code for: \(prompt.prefix(50))
            function main() {
                console.log('Hello from generated code!');
            }
            
            main();
            """
    }
    
    private func fixCodeMock(code: String, error: String) -> String {
        // Simple mock that returns the code with a comment about the fix
        return """
            // Fixed: \(error.prefix(50))
            \(code)
            // Note: This is a mock fix. Real model would analyze and correct the issue.
            """
    }
    
    private func completeCodeMock(code: String) -> String {
        // Simple completion that adds a closing brace or semicolon
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed.hasSuffix("{") {
            return """
                    console.log('Completed!');
                }
                """
        }
        
        if trimmed.hasSuffix("(") {
            return ");"
        }
        
        return "\n    // Completion generated by mock model"
    }
    
    private func explainCodeMock(code: String) -> String {
        let lineCount = code.components(separatedBy: "\n").count
        return """
            This code contains \(lineCount) lines. It appears to be JavaScript code.
            
            (This is a mock explanation. A real model would provide detailed analysis.)
            """
    }
}

// MARK: - Preview Helpers

extension MockModelBackend {
    /// Create a pre-loaded mock backend for previews.
    static func preloaded() async -> MockModelBackend {
        let backend = MockModelBackend()
        try? await backend.load(configuration: ModelConfiguration(
            modelPath: "/mock/model.gguf",
            contextSize: 4096
        ))
        return backend
    }
}
