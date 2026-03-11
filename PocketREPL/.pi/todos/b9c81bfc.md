{
  "id": "b9c81bfc",
  "title": "🟢 Add Voice Control input labels",
  "tags": [
    "accessibility",
    "low"
  ],
  "status": "closed",
  "created_at": "2026-03-11T01:23:30.893Z"
}

## Completed

Added `.accessibilityInputLabels()` to key interactive elements for Voice Control support:

### ChatView.swift
- **Send button:** "Send", "Send message", "Submit"
- **Keyboard toggle:** "Keyboard", "Toggle keyboard", "Hide keyboard", "Show keyboard"

### ModelManagementView.swift
- **Installed model rows:** Model name as input label
- **Downloadable model rows:** Model name + "Download {name}"

### FileBrowserView.swift
- **File/folder rows:** File name + "Open {name}"
- **Back button:** "Back", "Go back", "Parent folder", "Up"

Voice Control users can now say any of these phrases to activate the corresponding buttons.

### Build Status
✅ BUILD SUCCEEDED
