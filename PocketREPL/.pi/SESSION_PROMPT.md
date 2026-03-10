# PocketREPL Implementation Session

## What is PocketREPL?

PocketREPL is an iOS app that provides an **offline JavaScript coding workspace with an autonomous AI agent**. The core concept: a user gives a prompt, and an AI agent writes JavaScript code, runs it in a sandboxed JavaScriptCore runtime, observes failures, and iterates until the code works—all locally on-device.

## Current State

The project has **solid foundation layers implemented**:

| Layer | Status | Key Files |
|-------|--------|-----------|
| **ProjectStore** | ✅ Complete | `Project/ProjectStore.swift`, `Project/WorkspaceModels.swift` |
| **JSRuntime** | ✅ Complete | `Runtime/JSRuntime.swift` |
| **AgentModels** | ✅ Complete | `Agent/AgentModels.swift` |
| **ContextManager** | ✅ Basic | `Agent/ContextManager.swift` |
| **AgentSession** | ⚠️ Scaffold | `Agent/AgentSession.swift` — placeholder replies, no real orchestration |
| **Tools** | ⚠️ Scaffold | `Tools/FilesystemTools.swift`, `Tools/RunSnippetTool.swift`, `Tools/RunFileTool.swift` — descriptors only |
| **UI** | ⚠️ Scaffold | `UI/RootView.swift`, `UI/AgentView.swift`, `UI/FileBrowserView.swift` |

### What Works
- **ProjectStore**: Full filesystem abstraction for workspace-scoped file operations (list, read, write, delete, search)
- **JSRuntime**: JavaScriptCore-based runtime with CommonJS `require()`, module cache, `console.log/warn/error`, `assert`, and `test()` helpers
- **Execution model**: `runSnippet(code:)` and `runFile(path:)` return structured `JSExecutionResult` with output, errors, assertion failures, and loaded module paths

### What's Missing
1. **Tool implementations** that call ProjectStore/JSRuntime and return structured results
2. **AgentSession orchestration** that talks to Foundation Models API and executes tools
3. **Write-run-fix loop** with bounded retries and failure handling
4. **Real UI** for chat, tool trace, and file browsing

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                     SwiftUI Views                    │
│   RootView → AgentView / FileBrowserView / Chat     │
└─────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────┐
│                   AgentSession                       │
│   - Holds conversation state                         │
│   - Orchestrates Foundation Models calls             │
│   - Dispatches tool calls, records trace             │
│   - Implements bounded retry on failures             │
└─────────────────────────────────────────────────────┘
         │                           │
         ▼                           ▼
┌─────────────────┐       ┌─────────────────────────┐
│  ProjectStore   │       │       JSRuntime         │
│  (filesystem)   │       │   (JavaScriptCore)      │
│                 │       │                         │
│  list_files     │       │  runSnippet(code:)      │
│  read_file      │       │  runFile(path:)         │
│  write_file     │       │  require() + cache      │
│  search_code    │       │  console/assert/test    │
└─────────────────┘       └─────────────────────────┘
```

## Tools to Implement

The agent needs these tools (defined in `FilesystemTools.swift`):

| Tool | Purpose | Backend |
|------|---------|---------|
| `list_files` | List workspace contents | `ProjectStore.listFiles()` |
| `read_file` | Read file with line range | `ProjectStore.readFile()` |
| `write_file` | Create/update file | `ProjectStore.writeFile()` |
| `search_code` | Grep JavaScript files | `ProjectStore.searchJavaScript()` |
| `run_snippet` | Execute inline JS | `JSRuntime.runSnippet()` |
| `run_file` | Execute JS file | `JSRuntime.runFile()` |

Each tool should:
1. Accept JSON-decodable parameters
2. Call the appropriate backend
3. Return a structured result for the agent to observe
4. Be callable from AgentSession's orchestration loop

## Priority Tasks

### Phase 1: Wire the Tools (Current Focus)
1. Implement concrete tool execution in `FilesystemTools.swift` or a new `ToolExecutor`
2. Define a `Tool` protocol with `name`, `parameters`, and `execute()` 
3. Connect tools to `ProjectStore` and `JSRuntime`

### Phase 2: Agent Orchestration
1. Integrate Foundation Models framework in `AgentSession`
2. Build the prompt → tool call → observe → iterate loop
3. Add bounded retry (e.g., max 5 fix attempts before asking user)
4. Record tool trace events for UI display

### Phase 3: UI Polish
1. Real chat view with user/assistant messages
2. Collapsible tool trace showing calls and results
3. File browser with syntax-highlighted preview
4. Session controls (new session, reset runtime)

## Key Constraints

- **Offline-first**: Must work without network (except optional Foundation Models)
- **Sandbox safety**: JSRuntime confined to workspace, no `eval` escapes
- **Actor isolation**: `ProjectStore` and `JSRuntime` are actors; `AgentSession` is `@MainActor`
- **No blocking UI**: JS evaluation must not freeze the main thread

## File Reference

```
PocketREPL/
├── Agent/
│   ├── AgentModels.swift      # Message, ToolTrace, JSExecutionResult types
│   ├── AgentSession.swift     # Main orchestrator (needs real implementation)
│   └── ContextManager.swift   # Tracks recent activity for context window
├── Project/
│   ├── ProjectStore.swift     # Filesystem abstraction (complete)
│   └── WorkspaceModels.swift  # WorkspaceInfo, FileEntry, SearchMatch types
├── Runtime/
│   └── JSRuntime.swift        # JavaScriptCore runtime (complete)
├── Tools/
│   ├── FilesystemTools.swift  # Tool descriptors (needs execution impl)
│   ├── RunSnippetTool.swift   # Placeholder
│   └── RunFileTool.swift      # Placeholder
├── UI/
│   ├── RootView.swift         # Navigation shell
│   ├── AgentView.swift        # Chat + trace view
│   └── FileBrowserView.swift  # File listing
├── ContentView.swift          # Entry point
└── PocketREPLApp.swift        # App lifecycle
```

## Getting Started

1. Check todos: `todo list` — see assigned tasks for current session focus
2. Claim a task before working: `todo claim --id <id>`
3. Build and run to verify current state compiles
4. Implement tools, then wire AgentSession, then polish UI

## Notes

- The JSRuntime already handles CommonJS `require()` with proper module resolution
- `JSExecutionResult` includes everything needed: output, errors, assertion failures, loaded modules
- ProjectStore operations are path-safe (rejects `..`, absolute paths, escapes)
- Foundation Models integration should use the on-device API for offline operation
