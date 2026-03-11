# PocketREPL Internationalization Implementation

## Context

PocketREPL is an iOS app that provides a JavaScript coding assistant with AI capabilities. It has two AI backends:

1. **Apple Foundation Models** (primary) - Available on iOS 26+ devices with Apple Intelligence enabled. Requires English system prompts and schema descriptions.

2. **Local LLM models** (fallback) - Qwen2.5-Coder and DeepSeek models that support 29+ languages. Used when Foundation Models is unavailable.

The app currently has ~115 hardcoded English strings across UI, error messages, and status indicators.

## Objective

Implement internationalization (i18n) using Swift String Catalogs (`.xcstrings`) while preserving English-only requirements for Foundation Models compatibility.

## Requirements

### 1. Create String Catalog Infrastructure

Create `Localizable.xcstrings` in the project and configure build settings:
- Enable "Use Compiler to Extract Swift Strings" 
- Set development language to English
- Add initial target languages: Japanese, Chinese (Simplified), Spanish

### 2. Localize UI Strings

Convert all user-facing strings in these files to use `String(localized:)` or rely on SwiftUI's automatic localization:

**ChatView.swift** (~15 strings)
```swift
// Before
.alert("Apple Intelligence Required", isPresented: $showingAIAlert)
Text("Thinking...")
TextField("Enter your message...", text: $draft)

// After  
.alert(String(localized: "Apple Intelligence Required"), isPresented: $showingAIAlert)
Text("Thinking...", comment: "Shown while AI is processing")
TextField(String(localized: "Enter your message..."), text: $draft)
```

Key strings:
- "Apple Intelligence Required"
- "Open Settings" 
- "Continue Without AI"
- "Enter your message..."
- "Thinking..."
- "Executing..."
- "Completed" / "Failed" / "Processing" / "Skipped"
- "Collapse" / "Expand"
- "PocketREPL" (keep as brand name, don't localize)

**ModelManagementView.swift** (~45 strings)
- Section headers: "ACTIVE MODEL", "STORAGE", "INSTALLED", "AVAILABLE FOR DOWNLOAD", etc.
- Status labels: "Ready", "Generating", "Error", "No Model Loaded"
- Actions: "Unload Model", "Load Model", "Delete Model", "Download", "Cancel", "Done"
- Stats: "Memory", "Context", "Disk", "Parameters"
- Confirmation: "This will remove %@ from your device. This action cannot be undone."

**AgentView.swift** (~12 strings)
- "Tool Trace", "Done", "No Tool Activity"
- "Reset Runtime", "New Session"
- Status labels: "Call", "Result", "Note"

**FileBrowserView.swift** (~14 strings)
- "Files", "Root", "Back", "Folder"
- "Loading files...", "Loading..."
- "Couldn't Load Files", "Try Again"
- "Workspace is Empty", "Folder is Empty"
- Empty state descriptions

**RootView.swift** (~6 strings)
- Tab labels: "Chat", "Files"
- Alert: "Model Unloaded", "Reload Model", "OK"

### 3. Localize Error Messages

These appear in alerts and status displays:

**FoundationModelsAdapter.swift**
```swift
// Before
msg = "⚠️ Apple Intelligence model is not available..."

// After
msg = String(localized: "⚠️ Apple Intelligence model is not available.\n\nTo use AI features:\n1. Go to Settings > Apple Intelligence & Siri\n2. Enable Apple Intelligence\n3. Wait for the model to finish downloading (~4GB)")
```

Key error strings:
- "I can't help with that request."
- "⚠️ Context limit reached. Starting fresh session. Please try again."
- "⚠️ Your device language/locale is not supported by Apple Intelligence."
- "⚠️ Too many requests. Please wait a moment and try again."
- "⚠️ Retry limit reached after %d consecutive failures..."
- Device eligibility messages

**AgentSession.swift**
- "PocketREPL is ready. Tools are wired to ProjectStore and JSRuntime." → Simplify to "Ready to code."
- "New session started. Tools are ready." → "New session started."
- "JavaScript runtime reset. Module cache cleared."
- "Error: %@"

### 4. DO NOT Localize (Foundation Models Requirements)

Leave these in English - they are parsed by Apple's model:

**AgentSession.swift:349-355** - System prompt
```swift
private static let defaultSystemPrompt = """
    You are PocketREPL, a JavaScript coding assistant...
    """
// ❌ Keep English - passed to LanguageModelSession(instructions:)
```

**FoundationModelsAdapter.swift:600-657** - @Guide descriptions
```swift
@Guide(description: "JavaScript code to execute.")  // ❌ Keep English
var code: String
```

**FoundationModelsAdapter.swift:572-595** - @Generable doc comments
```swift
/// Execute inline JavaScript code.  // ❌ Keep English
case runSnippet(RunSnippetAction)
```

### 5. Fallback Mode Enhancement (Optional)

When Foundation Models is unavailable, the app shows tool summaries to users. These CAN be localized since they're only shown in fallback mode where Qwen (multilingual) is used:

**ToolExecutor.swift**
```swift
// Consider adding a localized version for display
let summary = "List files and directories in the workspace."
// Could become: String(localized: "List files and directories in the workspace.")
```

### 6. Handle Pluralization

Use stringsdict or String Catalog plural rules for:
- "%d models installed"
- "%d characters"  
- "~%d remaining"
- "%d consecutive failures"

### 7. Format Localized Values

Use formatters that respect locale:
```swift
// File sizes - already correct (ByteCountFormatter respects locale)
ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)

// Numbers
Text(info.contextSize, format: .number)

// Dates
Text(model.downloadedAt, format: .dateTime)
```

### 8. RTL Considerations

SwiftUI handles most RTL automatically, but verify:
- Chat bubbles align correctly (user messages trailing, assistant leading)
- Progress bars fill in correct direction
- Navigation flows correctly

## File Checklist

```
[ ] Create Localizable.xcstrings
[ ] UI/ChatView.swift - 15 strings
[ ] UI/ModelManagementView.swift - 45 strings
[ ] UI/AgentView.swift - 12 strings
[ ] UI/FileBrowserView.swift - 14 strings
[ ] UI/RootView.swift - 6 strings
[ ] Agent/FoundationModelsAdapter.swift - 12 error strings (localize)
[ ] Agent/FoundationModelsAdapter.swift - @Guide/@Generable (DO NOT touch)
[ ] Agent/AgentSession.swift - 8 strings (localize messages, NOT systemPrompt)
[ ] Tools/ToolExecutor.swift - 6 tool summaries (optional)
[ ] Test with pseudolocalization
[ ] Test RTL with Arabic/Hebrew
[ ] Export XLIFF for translation
```

## Testing

1. **Pseudolocalization**: Settings > Developer > Pseudolanguage - verifies all strings are extracted
2. **Japanese**: Test with iOS set to Japanese, verify Foundation Models still works
3. **Arabic**: Test RTL layout, verify fallback mode works correctly
4. **String length**: German strings are ~30% longer - verify UI doesn't clip

## Architecture Notes

The localization should be transparent to the AI backends:
- Users can type in any language (both FM and Qwen understand multilingual input)
- Foundation Models requires English system prompts but handles multilingual user messages
- Qwen handles everything in 29+ languages
- UI language is independent of AI language capabilities
