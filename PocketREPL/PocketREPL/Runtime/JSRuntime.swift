import Foundation
import JavaScriptCore

enum JSRuntimeError: LocalizedError {
    case emptySnippet
    case emptyModuleSpecifier
    case absolutePathNotAllowed(String)
    case moduleEscapesWorkspace(String)
    case moduleNotFound(String)
    case invalidModuleWrapper(String)
    case executionFailed(String)
    case internalRuntimeUnavailable

    var errorDescription: String? {
        switch self {
        case .emptySnippet:
            return "No JavaScript snippet was provided."
        case .emptyModuleSpecifier:
            return "A non-empty JavaScript module path is required."
        case .absolutePathNotAllowed(let path):
            return "Absolute JavaScript module paths are not supported: \(path)"
        case .moduleEscapesWorkspace(let path):
            return "Module resolution escaped the active workspace: \(path)"
        case .moduleNotFound(let path):
            return "Could not find a JavaScript module for \(path)."
        case .invalidModuleWrapper(let path):
            return "Failed to prepare the JavaScript module wrapper for \(path)."
        case .executionFailed(let message):
            return message
        case .internalRuntimeUnavailable:
            return "The JavaScript runtime could not be initialized."
        }
    }
}

actor JSRuntime {
    private let projectStore: ProjectStore
    private var state: RuntimeState?

    init(projectStore: ProjectStore) {
        self.projectStore = projectStore
    }

    func reset() {
        state = nil
    }

    func runSnippet(code: String) async -> JSExecutionResult {
        do {
            _ = try await projectStore.createWorkspaceIfNeeded()
            let state = try runtimeState()
            return state.runSnippet(code)
        } catch let error as JSRuntimeError {
            return JSExecutionResult.failed(kind: .snippet, message: error.localizedDescription)
        } catch {
            return JSExecutionResult.failed(kind: .snippet, message: error.localizedDescription)
        }
    }

    func runFile(path: String) async -> JSExecutionResult {
        do {
            _ = try await projectStore.createWorkspaceIfNeeded()
            let state = try runtimeState()
            return state.runFile(path: path)
        } catch let error as JSRuntimeError {
            return JSExecutionResult.failed(kind: .file, sourcePath: path, message: error.localizedDescription)
        } catch {
            return JSExecutionResult.failed(kind: .file, sourcePath: path, message: error.localizedDescription)
        }
    }

    private func runtimeState() throws -> RuntimeState {
        if let state {
            return state
        }

        let state = try RuntimeState(projectStore: projectStore)
        self.state = state
        return state
    }
}

private nonisolated final class RuntimeState {
    private static let supportedModuleExtensions = ["js", "mjs", "cjs", "jsx"]

    private let projectStore: ProjectStore
    private let workspaceRootURL: URL
    private let virtualMachine: JSVirtualMachine
    private let bridge: RuntimeBridge
    private let context: JSContext

    private var moduleCache: [String: JSValue] = [:]

    init(projectStore: ProjectStore) throws {
        self.projectStore = projectStore
        self.workspaceRootURL = projectStore.workspaceInfo.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.virtualMachine = JSVirtualMachine()
        self.bridge = RuntimeBridge()

        guard let context = JSContext(virtualMachine: virtualMachine) else {
            throw JSRuntimeError.internalRuntimeUnavailable
        }

        self.context = context
        installBridgeBindings()
        try installStandardLibrary()
        installGlobalRequire(baseModulePath: nil)
    }

    func runSnippet(_ code: String) -> JSExecutionResult {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return JSExecutionResult.failed(kind: .snippet, message: JSRuntimeError.emptySnippet.localizedDescription)
        }

        beginExecution(kind: .snippet, sourcePath: nil)
        installGlobalRequire(baseModulePath: nil)

        let sourceURL = workspaceRootURL.appendingPathComponent("__snippet__.js")
        let value = context.evaluateScript(code, withSourceURL: sourceURL)
        return finalizeExecution(returnValue: describe(value))
    }

    func runFile(path: String) -> JSExecutionResult {
        do {
            let entryPath = try resolveModuleSpecifier(path, relativeTo: nil)
            beginExecution(kind: .file, sourcePath: entryPath)

            do {
                let exports = try loadModule(at: entryPath, bypassCache: true)
                return finalizeExecution(returnValue: describe(exports))
            } catch let error as JSRuntimeError {
                bridge.recordRuntimeError(error.localizedDescription)
                return finalizeExecution(returnValue: nil)
            } catch {
                bridge.recordRuntimeError(error.localizedDescription)
                return finalizeExecution(returnValue: nil)
            }
        } catch let error as JSRuntimeError {
            return immediateFailure(kind: .file, sourcePath: path, message: error.localizedDescription)
        } catch {
            return immediateFailure(kind: .file, sourcePath: path, message: error.localizedDescription)
        }
    }

    private func beginExecution(kind: JSExecutionKind, sourcePath: String?) {
        bridge.begin(kind: kind, sourcePath: sourcePath)
        context.exception = nil
    }

    private func finalizeExecution(returnValue: String?) -> JSExecutionResult {
        bridge.finish(returnValue: sanitizedReturnValue(returnValue))
    }

    private func immediateFailure(kind: JSExecutionKind, sourcePath: String?, message: String) -> JSExecutionResult {
        bridge.begin(kind: kind, sourcePath: sourcePath)
        bridge.recordRuntimeError(message)
        return bridge.finish(returnValue: nil)
    }

    private func loadModule(at relativePath: String, bypassCache: Bool) throws -> JSValue {
        if !bypassCache, let cachedModule = moduleCache[relativePath] {
            return cachedModule.forProperty("exports") ?? JSValue(undefinedIn: context)
        }

        if bypassCache {
            moduleCache.removeValue(forKey: relativePath)
        }

        let source = try projectStore.readFileSynchronously(at: relativePath).text
        bridge.recordLoadedModule(relativePath)

        let sourceURL = workspaceRootURL.appendingPathComponent(relativePath)
        let wrapperSource = Self.moduleWrapperSource(for: source)

        context.exception = nil
        guard let wrapper = context.evaluateScript(wrapperSource, withSourceURL: sourceURL) else {
            let message = bridge.currentError?.message ?? JSRuntimeError.invalidModuleWrapper(relativePath).localizedDescription
            moduleCache.removeValue(forKey: relativePath)
            throw JSRuntimeError.executionFailed(message)
        }

        let module = JSValue(newObjectIn: context) ?? JSValue(object: [:], in: context)
        let exports = JSValue(newObjectIn: context) ?? JSValue(object: [:], in: context)
        guard let module, let exports else {
            throw JSRuntimeError.internalRuntimeUnavailable
        }

        module.setValue(relativePath, forProperty: "id")
        module.setValue(relativePath, forProperty: "filename")
        module.setValue(false, forProperty: "loaded")
        module.setValue(exports, forProperty: "exports")
        moduleCache[relativePath] = module

        let requireBlock = makeRequireBlock(currentModulePath: relativePath)
        let requireValue = JSValue(object: requireBlock, in: context)
        let dirname = Self.dirname(for: relativePath)

        context.exception = nil
        _ = wrapper.call(withArguments: [exports, requireValue as Any, module, relativePath, dirname])

        if let error = bridge.currentError {
            moduleCache.removeValue(forKey: relativePath)
            throw JSRuntimeError.executionFailed(error.message)
        }

        module.setValue(true, forProperty: "loaded")
        moduleCache[relativePath] = module
        return module.forProperty("exports") ?? JSValue(undefinedIn: context)
    }

    private func installBridgeBindings() {
        context.exceptionHandler = { [weak bridge] _, exception in
            bridge?.recordException(exception)
        }

        let logBlock: @convention(block) (String) -> Void = { [weak bridge] message in
            bridge?.recordConsole(level: .log, message: message)
        }
        let warnBlock: @convention(block) (String) -> Void = { [weak bridge] message in
            bridge?.recordConsole(level: .warn, message: message)
        }
        let errorBlock: @convention(block) (String) -> Void = { [weak bridge] message in
            bridge?.recordConsole(level: .error, message: message)
        }
        let assertionBlock: @convention(block) (String) -> Void = { [weak bridge] message in
            bridge?.recordAssertionFailure(message)
        }

        context.setObject(logBlock, forKeyedSubscript: "__pocketreplLog" as NSString)
        context.setObject(warnBlock, forKeyedSubscript: "__pocketreplWarn" as NSString)
        context.setObject(errorBlock, forKeyedSubscript: "__pocketreplError" as NSString)
        context.setObject(assertionBlock, forKeyedSubscript: "__pocketreplAssertionFailure" as NSString)
    }

    private func installStandardLibrary() throws {
        context.exception = nil
        let result = context.evaluateScript(Self.standardLibrarySource, withSourceURL: workspaceRootURL.appendingPathComponent("__pocketrepl_stdlib__.js"))
        guard result != nil || context.exception == nil else {
            let message = RuntimeBridge.errorSummary(from: context.exception)?.message ?? "Failed to install the PocketREPL JavaScript standard library."
            throw JSRuntimeError.executionFailed(message)
        }
    }

    private func installGlobalRequire(baseModulePath: String?) {
        let requireBlock = makeRequireBlock(currentModulePath: baseModulePath)
        context.setObject(requireBlock, forKeyedSubscript: "require" as NSString)
    }

    private func makeRequireBlock(currentModulePath: String?) -> Any {
        let requireBlock: @convention(block) (String) -> JSValue? = { [weak self] specifier in
            guard let self else { return nil }

            do {
                let resolvedPath = try self.resolveModuleSpecifier(specifier, relativeTo: currentModulePath)
                return try self.loadModule(at: resolvedPath, bypassCache: false)
            } catch let error as JSRuntimeError {
                self.raiseJavaScriptError(message: error.localizedDescription)
                return nil
            } catch {
                self.raiseJavaScriptError(message: error.localizedDescription)
                return nil
            }
        }

        return requireBlock
    }

    private func raiseJavaScriptError(message: String) {
        bridge.recordRuntimeError(message)
        context.exception = JSValue(newErrorFromMessage: message, in: context)
    }

    private func resolveModuleSpecifier(_ specifier: String, relativeTo currentModulePath: String?) throws -> String {
        let trimmed = specifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw JSRuntimeError.emptyModuleSpecifier
        }

        if trimmed.hasPrefix("/") || NSString(string: trimmed).isAbsolutePath {
            throw JSRuntimeError.absolutePathNotAllowed(trimmed)
        }

        let baseURL: URL
        if trimmed.hasPrefix("./") || trimmed.hasPrefix("../") {
            if let currentModulePath {
                baseURL = workspaceRootURL.appendingPathComponent(currentModulePath).deletingLastPathComponent()
            } else {
                baseURL = workspaceRootURL
            }
        } else {
            baseURL = workspaceRootURL
        }

        let candidate = URL(fileURLWithPath: trimmed, relativeTo: baseURL)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard isInsideWorkspace(candidate) else {
            throw JSRuntimeError.moduleEscapesWorkspace(trimmed)
        }

        if let fileURL = firstMatchingFileURL(for: candidate) {
            return relativePath(for: fileURL)
        }

        throw JSRuntimeError.moduleNotFound(trimmed)
    }

    private func firstMatchingFileURL(for candidate: URL) -> URL? {
        let fileManager = FileManager.default

        if isRegularFile(candidate) {
            return candidate
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
            for fileExtension in Self.supportedModuleExtensions {
                let indexURL = candidate.appendingPathComponent("index").appendingPathExtension(fileExtension)
                if isRegularFile(indexURL) {
                    return indexURL
                }
            }
        }

        if candidate.pathExtension.isEmpty {
            for fileExtension in Self.supportedModuleExtensions {
                let withExtension = candidate.appendingPathExtension(fileExtension)
                if isRegularFile(withExtension) {
                    return withExtension
                }
            }
        }

        return nil
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func isInsideWorkspace(_ url: URL) -> Bool {
        let candidatePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = workspaceRootURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func relativePath(for url: URL) -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = workspaceRootURL.path

        guard resolved != root else { return "" }
        return String(resolved.dropFirst(root.count + 1))
    }

    private func describe(_ value: JSValue?) -> String? {
        guard let value else { return nil }
        if value.isUndefined || value.isNull {
            return nil
        }

        guard let describer = context.objectForKeyedSubscript("__pocketreplDescribe") else {
            return value.toString()
        }

        return describer.call(withArguments: [value])?.toString() ?? value.toString()
    }

    private func sanitizedReturnValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func dirname(for relativePath: String) -> String {
        let directoryPath = URL(fileURLWithPath: relativePath).deletingLastPathComponent().path
        return directoryPath == "/" ? "" : directoryPath
    }

    private static func moduleWrapperSource(for source: String) -> String {
        """
        (function(exports, require, module, __filename, __dirname) {
        \(source)
        
        })
        """
    }

    private static let standardLibrarySource = """
    globalThis.global = globalThis;

    function __pocketreplDescribe(value) {
      if (value === undefined) { return 'undefined'; }
      if (value === null) { return 'null'; }
      if (typeof value === 'string') { return value; }
      if (typeof value === 'function') { return value.toString(); }
      try {
        if (typeof value === 'object') {
          return JSON.stringify(value, null, 2);
        }
      } catch (_) {}
      try {
        return String(value);
      } catch (_) {
        return Object.prototype.toString.call(value);
      }
    }

    function __pocketreplDeepEqual(lhs, rhs) {
      if (lhs === rhs) { return true; }
      try {
        return JSON.stringify(lhs) === JSON.stringify(rhs);
      } catch (_) {
        return false;
      }
    }

    globalThis.console = {
      log: function(...args) { __pocketreplLog(args.map(__pocketreplDescribe).join(' ')); },
      warn: function(...args) { __pocketreplWarn(args.map(__pocketreplDescribe).join(' ')); },
      error: function(...args) { __pocketreplError(args.map(__pocketreplDescribe).join(' ')); },
      debug: function(...args) { __pocketreplLog(args.map(__pocketreplDescribe).join(' ')); }
    };

    function assert(condition, message) {
      if (!condition) {
        const resolved = message ? String(message) : 'Assertion failed';
        __pocketreplAssertionFailure(resolved);
        throw new Error(resolved);
      }
      return true;
    }

    assert.ok = assert;
    assert.equal = function(actual, expected, message) {
      return assert(
        actual === expected,
        message || `Expected ${__pocketreplDescribe(actual)} to equal ${__pocketreplDescribe(expected)}`
      );
    };
    assert.notEqual = function(actual, expected, message) {
      return assert(
        actual !== expected,
        message || `Expected ${__pocketreplDescribe(actual)} to not equal ${__pocketreplDescribe(expected)}`
      );
    };
    assert.deepEqual = function(actual, expected, message) {
      return assert(
        __pocketreplDeepEqual(actual, expected),
        message || `Expected ${__pocketreplDescribe(actual)} to deep-equal ${__pocketreplDescribe(expected)}`
      );
    };

    globalThis.assert = assert;

    globalThis.test = function(name, fn) {
      try {
        fn();
        console.log(`✓ ${name}`);
        return true;
      } catch (error) {
        console.error(`✗ ${name}: ${error && error.message ? error.message : __pocketreplDescribe(error)}`);
        throw error;
      }
    };
    """
}

private nonisolated final class RuntimeBridge {
    private(set) var currentCapture: ExecutionCapture?

    var currentError: JSErrorSummary? {
        currentCapture?.error
    }

    func begin(kind: JSExecutionKind, sourcePath: String?) {
        currentCapture = ExecutionCapture(kind: kind, sourcePath: sourcePath, startedAt: .now)
    }

    func recordConsole(level: JSConsoleLevel, message: String) {
        currentCapture?.console.append(JSConsoleEntry(level: level, message: message))
    }

    func recordAssertionFailure(_ message: String) {
        guard let currentCapture else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "Assertion failed." : trimmed
        currentCapture.assertionFailures.append(resolved)
    }

    func recordLoadedModule(_ relativePath: String) {
        guard let currentCapture else { return }
        currentCapture.recordLoadedModule(relativePath)
    }

    func recordRuntimeError(_ message: String) {
        let summary = JSErrorSummary(message: message, line: nil, column: nil, stack: nil)
        merge(error: summary)
    }

    func recordException(_ exception: JSValue?) {
        guard let error = Self.errorSummary(from: exception) else {
            return
        }

        merge(error: error)
    }

    func finish(returnValue: String?) -> JSExecutionResult {
        let finishedAt = Date.now
        let capture = currentCapture ?? ExecutionCapture(kind: .snippet, sourcePath: nil, startedAt: finishedAt)
        currentCapture = nil

        var outputLines = capture.console.map(\JSConsoleEntry.message)
        if !capture.assertionFailures.isEmpty {
            outputLines.append(contentsOf: capture.assertionFailures.map { "Assertion failed: \($0)" })
        }
        if let returnValue {
            outputLines.append("=> \(returnValue)")
        }

        return JSExecutionResult(
            kind: capture.kind,
            sourcePath: capture.sourcePath,
            returnValue: returnValue,
            output: outputLines.joined(separator: "\n"),
            console: capture.console,
            assertionFailures: capture.assertionFailures,
            loadedModulePaths: capture.loadedModulePaths,
            error: capture.error,
            startedAt: capture.startedAt,
            finishedAt: finishedAt
        )
    }

    static func errorSummary(from exception: JSValue?) -> JSErrorSummary? {
        guard let exception else { return nil }

        let message = exception.forProperty("message")?.toString()
            ?? exception.toString()
            ?? "JavaScript execution failed."

        let line = Self.intValue(from: exception, keys: ["line", "lineNumber"])
        let column = Self.intValue(from: exception, keys: ["column", "columnNumber"])
        let stack = exception.forProperty("stack")?.toString()

        return JSErrorSummary(message: message, line: line, column: column, stack: stack)
    }

    private func merge(error: JSErrorSummary) {
        guard let currentCapture else { return }

        if currentCapture.error == nil {
            currentCapture.error = error
            return
        }

        if currentCapture.error?.stack == nil, error.stack != nil {
            currentCapture.error = error
        }
    }

    private static func intValue(from exception: JSValue, keys: [String]) -> Int? {
        for key in keys {
            if let value = exception.forProperty(key), !value.isUndefined {
                return Int(value.toInt32())
            }
        }

        return nil
    }
}

private nonisolated final class ExecutionCapture {
    let kind: JSExecutionKind
    let sourcePath: String?
    let startedAt: Date

    var console: [JSConsoleEntry] = []
    var assertionFailures: [String] = []
    var loadedModulePaths: [String] = []
    var error: JSErrorSummary?

    private var loadedModulePathSet: Set<String> = []

    init(kind: JSExecutionKind, sourcePath: String?, startedAt: Date) {
        self.kind = kind
        self.sourcePath = sourcePath
        self.startedAt = startedAt
    }

    func recordLoadedModule(_ relativePath: String) {
        guard loadedModulePathSet.insert(relativePath).inserted else { return }
        loadedModulePaths.append(relativePath)
    }
}
