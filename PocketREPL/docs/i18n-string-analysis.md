# PocketREPL i18n String Analysis

## Summary

| Category | Count | Can Localize? | Notes |
|----------|-------|---------------|-------|
| UI Strings | ~110 | ✅ Yes | Standard SwiftUI localization |
| Foundation Models Instructions | 1 | ❌ No | Apple requires English |
| @Guide Descriptions | 12 | ❌ No | Model schema hints, must be English |
| @Generable Case Comments | 7 | ❌ No | Compile-time, affects model behavior |
| Error Messages (User-Facing) | ~25 | ✅ Yes | Shown in alerts/UI |
| Tool Summaries (Fallback Mode) | 6 | ⚠️ Partial | Only shown when FM unavailable |
| Prompt Templates (Qwen) | 5 | ⚠️ Optional | Could localize for better Qwen UX |

---

## ❌ MUST STAY IN ENGLISH (Foundation Models)

### 1. System Instructions
**File:** `AgentSession.swift:349-355`
```swift
private static let defaultSystemPrompt = """
    You are PocketREPL, a JavaScript coding assistant. Write, run, and fix code autonomously.
    
    Workflow: inspect files → write code → run → fix errors if needed.
    Use console.log() for output. Use assert() for tests.
    After 3 failed fixes, ask for guidance.
    """
```
**Reason:** Passed to `LanguageModelSession(instructions:)`. Apple's Foundation Models requires English instructions.

---

### 2. @Guide Descriptions (Tool Schemas)
**File:** `FoundationModelsAdapter.swift:600-657`

These are compile-time hints for Foundation Models' structured output:

```swift
@Guide(description: "Your response message to the user. Be concise and helpful.")
var message: String

@Guide(description: "Optional path relative to workspace root. Leave empty for root.")
var path: String?

@Guide(description: "Whether to list recursively into subdirectories.")
var recursive: Bool

@Guide(description: "Path to the file relative to workspace root.")
var path: String

@Guide(description: "Line number to start reading from (1-indexed).")
var startLine: Int?

@Guide(description: "Maximum number of lines to read.")
var maxLines: Int?

@Guide(description: "Content to write to the file.")
var content: String

@Guide(description: "Text pattern to search for in JavaScript files.")
var query: String

@Guide(description: "Maximum number of results to return.")
var limit: Int?

@Guide(description: "JavaScript code to execute.")
var code: String

@Guide(description: "Path to the JavaScript file to execute, relative to workspace root.")
var path: String
```
**Reason:** These descriptions guide the model's JSON schema generation. Must be English for FM to understand.

---

### 3. @Generable Enum Case Comments
**File:** `FoundationModelsAdapter.swift:572-595`

```swift
@Generable
enum AgentAction {
    /// Respond to the user with a text message. Use when you have completed the task or need to ask a question.
    case respond(TextResponse)
    
    /// List files and directories in the workspace.
    case listFiles(ListFilesAction)
    
    /// Read text content from a file.
    case readFile(ReadFileAction)
    
    /// Create or overwrite a file with content.
    case writeFile(WriteFileAction)
    
    /// Search JavaScript files for a text pattern.
    case searchCode(SearchCodeAction)
    
    /// Execute inline JavaScript code.
    case runSnippet(RunSnippetAction)
    
    /// Execute a JavaScript file from the workspace.
    case runFile(RunFileAction)
}
```
**Reason:** Doc comments on `@Generable` enums are used by Foundation Models to understand when to select each case.

---

## ✅ CAN BE FULLY LOCALIZED

### 4. UI Text Strings (~110 strings)

#### ChatView.swift
```swift
// Alerts
"Apple Intelligence Required"
"Open Settings"
"Continue Without AI"

// Placeholders
"Enter your message..."

// Status
"Thinking..."
"Executing..."
"Completed"
"Failed"
"Processing"
"Skipped"
"Result"

// Tool bubbles
"Collapse"
"Expand"
"characters"
```

#### ModelManagementView.swift
```swift
// Section headers
"ACTIVE MODEL"
"STORAGE"
"INSTALLED"
"AVAILABLE FOR DOWNLOAD"
"RUNTIME STATS"
"SPECIFICATIONS"
"FILE INFORMATION"
"ABOUT"

// Status
"Ready"
"Generating"
"Error"
"No Model Loaded"
"Download and load a model to start"
"Currently Active"

// Actions
"Unload Model"
"Load Model"
"Delete Model"
"Download"
"Cancel"
"Done"
"Custom"

// Labels
"Models"
"Available"
"Memory"
"Context"
"Disk"
"Parameters"
"Quantization"
"Model Family"
"Context Window"
"Source"
"File Size"
"Downloaded"

// Messages
"This will remove X from your device. This action cannot be undone."
"Models are downloaded from Hugging Face and stored locally."
"Loading model..."
"remaining"
```

#### AgentView.swift
```swift
"PocketREPL"
"Tool Trace"
"Done"
"No Tool Activity"
"Tool calls and results will appear here as you interact with PocketREPL."
"Reset Runtime"
"New Session"
"Workspace: X"

// Trace labels
"Call"
"Result"
"Note"
```

#### FileBrowserView.swift
```swift
"Files"
"Root"
"Back"
"Folder"
"Loading files..."
"Loading..."
"Couldn't Load Files"
"Try Again"
"Workspace is Empty"
"Folder is Empty"
"Files will appear here as you create them through the AI assistant."
"(empty file)"
```

#### RootView.swift
```swift
"Chat"
"Files"
"Model Unloaded"
"Reload Model"
"OK"
"Model was unloaded automatically."
```

---

### 5. User-Facing Error Messages

#### FoundationModelsAdapter.swift
```swift
"I can't help with that request."
"⚠️ Context limit reached. Starting fresh session. Please try again."
"⚠️ Apple Intelligence model is not available..."
"⚠️ Your device language/locale is not supported by Apple Intelligence."
"⚠️ Too many requests. Please wait a moment and try again."
"⚠️ Another request is in progress. Please wait for it to complete."
"⚠️ Failed to process the response. Please try again."
"⚠️ Unsupported model configuration."
"⚠️ Retry limit reached after X consecutive failures..."
"Reached maximum tool iterations (X). Stopping."
```

#### AgentSession.swift
```swift
"PocketREPL is ready. Tools are wired to ProjectStore and JSRuntime."
"New session started. Tools are ready."
"Failed to bootstrap the workspace: X"
"JavaScript runtime reset. Module cache cleared."
"Error: X"
"Invalid JSON parameters"
```

#### ModelManagementView.swift
```swift
"Failed to load model: X"
"Download failed: X"
"Failed to delete model: X"
"Cannot load unknown model format"
```

---

## ⚠️ CONDITIONAL LOCALIZATION

### 6. Tool Summaries (Fallback Mode Only)
**File:** `ToolExecutor.swift`

Only shown when Foundation Models is unavailable:
```swift
"List files and directories in the workspace. Returns names, types, and sizes."
"Read text content from a file. Supports line range selection."
"Create or overwrite a file with the given content."
"Search JavaScript files for a text pattern. Returns matching lines with context."
"Execute inline JavaScript code and return the result."
"Execute a JavaScript file from the workspace."
```

**Recommendation:** Localize these. When in fallback mode, the user sees them and Qwen can understand localized instructions.

---

### 7. Prompt Templates (Qwen/DeepSeek Only)
**File:** `PromptTemplates.swift`

These are only used by local models, not Foundation Models:
```swift
"You are a JavaScript code generator. Write clean, working code..."
"You are a JavaScript debugger. Fix the code to resolve the error..."
"Complete the following JavaScript code..."
"Rewrite the following JavaScript code according to the instruction..."
```

**Recommendation:** Could create localized versions for better Qwen performance in non-English languages. Low priority since Qwen handles English well regardless of user's language.

---

## Implementation Recommendations

### Phase 1: UI Localization (High Value)
1. Add `Localizable.xcstrings` to project
2. Wrap all UI strings with `String(localized:)`
3. Target languages: Japanese, Chinese (Simplified), Spanish, German, French

### Phase 2: Error Message Localization
1. Create error message keys
2. Localize all user-facing warnings and errors

### Phase 3: Fallback Mode Enhancement (Optional)
1. Detect when in fallback mode
2. Use localized tool summaries
3. Consider localized prompts for Qwen

### Do NOT Localize
- `defaultSystemPrompt`
- `@Guide(description:)` strings  
- `@Generable` enum doc comments
- Anything inside `#if canImport(FoundationModels)` that's sent to the model

---

## String Extraction Checklist

```
UI/ChatView.swift          - 15 strings
UI/ModelManagementView.swift - 45 strings  
UI/AgentView.swift          - 12 strings
UI/FileBrowserView.swift    - 14 strings
UI/RootView.swift           - 6 strings
UI/EscherDesignSystem.swift - 3 strings (preview only)

Agent/FoundationModelsAdapter.swift - 12 error strings
Agent/AgentSession.swift    - 8 strings
LLM/ModelDownloadManager.swift - Model descriptions (keep English)
Tools/ToolExecutor.swift    - 6 tool summaries (localize for fallback)
```

**Total localizable strings: ~115**
