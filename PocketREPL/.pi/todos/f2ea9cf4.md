{
  "id": "f2ea9cf4",
  "title": "🟡 Add accessibility hints for text selection",
  "tags": [
    "accessibility",
    "medium"
  ],
  "status": "closed",
  "created_at": "2026-03-11T01:23:30.861Z"
}

## Completed

Added `.accessibilityHint(String(localized: "Double tap and hold to select text"))` to all 4 text selection locations:

1. **ChatView.swift:264** - Message text in chat bubbles
2. **ChatView.swift:398** - Tool call parameters text
3. **ChatView.swift:519** - Tool result output text
4. **FileBrowserView.swift:524** - File content preview text

VoiceOver users will now be informed that text can be selected via double-tap-and-hold gesture.

### Build Status
✅ BUILD SUCCEEDED
