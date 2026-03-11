# PocketREPL

A JavaScript coding assistant that runs entirely on your iPhone or Mac. Chat with an AI agent that can write, run, and fix JavaScript code autonomously—all without sending your code to the cloud.

![Platform](https://img.shields.io/badge/platform-iOS%2026%2B%20%7C%20macOS%2026%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **On-Device AI** — Uses Apple Intelligence (Foundation Models) for natural language interaction when available
- **JavaScript Runtime** — Built-in JavaScriptCore engine with CommonJS module support
- **File Management** — Create, read, write, and organize JavaScript files in your workspace
- **Code Search** — Search across all JavaScript files in your project
- **Autonomous Agent** — Write → Run → Fix loop that iterates until code works
- **Privacy First** — All processing happens locally on your device

## Requirements

- **iOS 26.0+** or **macOS 26.0+** (requires Apple Intelligence-capable device)
- **Xcode 26+** (for building from source)
- Apple Intelligence enabled for AI features (optional—fallback mode available)

### Supported Devices (Apple Intelligence)

- iPhone 15 Pro, iPhone 15 Pro Max, or later
- iPad with M1 chip or later
- Mac with Apple Silicon (M1 or later)

> **Note:** PocketREPL works without Apple Intelligence in fallback mode, allowing direct tool invocation.

## Getting Started

### Building from Source

1. Clone the repository:
   ```bash
   git clone https://github.com/codybontecou/PocketREPL.git
   cd PocketREPL/PocketREPL
   ```

2. Open the Xcode project:
   ```bash
   open PocketREPL.xcodeproj
   ```

3. Select your target device (iPhone, iPad, or Mac)

4. Build and run (⌘R)

### First Launch

1. **Enable Apple Intelligence** (for AI features):
   - Go to **Settings → Apple Intelligence & Siri**
   - Enable Apple Intelligence and wait for the model to download (~4GB)

2. **Create Your First Script**:
   - Ask the assistant: "Create a hello world script"
   - Or manually create files using the file browser

## How It Works

### Chat Interface

Talk to PocketREPL in natural language:

```
You: Create a function that calculates factorial

PocketREPL: I'll create a factorial function for you.
[✓ write_file] path: factorial.js
[✓ run_file] path: factorial.js
=> 120

I've created factorial.js with a recursive factorial function 
and verified it works by testing factorial(5) = 120.
```

### Available Tools

PocketREPL has access to these tools for working with your code:

| Tool | Description |
|------|-------------|
| `list_files` | List files and directories in the workspace |
| `read_file` | Read content from a file with optional line ranges |
| `write_file` | Create or overwrite files |
| `search_code` | Search JavaScript files for patterns |
| `run_snippet` | Execute inline JavaScript code |
| `run_file` | Execute a JavaScript file from the workspace |

### JavaScript Runtime

The built-in runtime supports:

- **CommonJS modules** — `require()` and `module.exports`
- **Console methods** — `console.log()`, `console.warn()`, `console.error()`
- **Assertions** — `assert()`, `assert.equal()`, `assert.deepEqual()`
- **Test runner** — `test("name", () => { ... })`

Example:
```javascript
// math.js
function add(a, b) {
  return a + b;
}
module.exports = { add };

// test.js
const { add } = require('./math');

test("addition works", () => {
  assert.equal(add(2, 3), 5);
});
// Output: ✓ addition works
```

### Fallback Mode

If Apple Intelligence isn't available, you can still use tools directly:

```
list_files
read_file {"path": "index.js"}
run_snippet {"code": "console.log('Hello!')"}
```

## Architecture

```
PocketREPL/
├── Agent/
│   ├── AgentSession.swift      # Main session coordinator
│   ├── FoundationModelsAdapter.swift  # Apple Intelligence integration
│   └── ContextManager.swift    # Conversation context tracking
├── Runtime/
│   └── JSRuntime.swift         # JavaScriptCore wrapper with module support
├── Tools/
│   ├── ToolExecutor.swift      # Tool dispatch and execution
│   ├── FilesystemTools.swift   # File operations
│   ├── RunSnippetTool.swift    # Code execution
│   └── RunFileTool.swift       # File execution
├── LLM/
│   ├── LlamaBackend.swift      # llama.cpp integration (optional)
│   ├── ModelBackend.swift      # Backend protocol
│   └── ModelDownloadManager.swift  # Model management
├── Project/
│   ├── ProjectStore.swift      # Workspace file management
│   └── WorkspaceModels.swift   # Data models
└── UI/
    ├── RootView.swift          # Main app view
    ├── ChatView.swift          # Chat interface
    ├── FileBrowserView.swift   # File explorer
    └── AgentView.swift         # Agent controls
```

## Advanced: Local LLM Support

PocketREPL includes optional support for running local GGUF models via llama.cpp:

1. Download a compatible model (recommended: Qwen2.5-Coder-1.5B-Q4_K_M)
2. Place the `.gguf` file in the app's Documents/Models folder
3. The model will be detected automatically

Recommended models for mobile:
- **Qwen2.5-Coder-1.5B** — Best balance of quality and size
- **CodeGemma-2B** — Alternative coding model
- **Phi-3-mini** — Small general model with coding ability

Use Q4_K_M or Q4_K_S quantization for optimal mobile performance.

## Troubleshooting

### "Apple Intelligence Unavailable"

1. Check device compatibility (requires A17 Pro or M1+)
2. Go to **Settings → Apple Intelligence & Siri**
3. Enable Apple Intelligence
4. Wait for model download to complete

### "Model is downloading"

Apple Intelligence models (~4GB) download in the background. Check progress in Settings.

### Runtime Errors

- Check the tool trace for detailed error messages
- Use `console.log()` for debugging
- Module paths must be relative (`./` or `../`)

## Contributing

Contributions welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Submit a pull request

## License

MIT License. See [LICENSE](LICENSE) for details.

## Acknowledgments

- [llama.cpp](https://github.com/ggerganov/llama.cpp) — Local LLM inference
- Apple Foundation Models — On-device AI capabilities
- JavaScriptCore — JavaScript runtime engine
