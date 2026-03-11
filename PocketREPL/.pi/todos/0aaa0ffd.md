{
  "id": "0aaa0ffd",
  "title": "🟡 Add accessibility custom actions for swipe gestures",
  "tags": [
    "accessibility",
    "medium"
  ],
  "status": "closed",
  "created_at": "2026-03-11T01:23:30.851Z"
}

## Completed

Added `.accessibilityAction(named:)` to provide alternatives to swipe gestures:

### ModelManagementView.swift
- ✅ InstalledModelRow
  - `.accessibilityAction(named: "Load model") { onLoad() }`
  - `.accessibilityAction(named: "Delete model") { onDelete() }`
- ✅ DownloadableModelRow
  - `.accessibilityAction(named: "Download model") { onDownload() }`
- ✅ DownloadProgressRow
  - `.accessibilityAction(named: "Cancel download") { onCancel() }`

VoiceOver users can now use the Actions rotor to access load, delete, download, and cancel actions without needing to perform swipe gestures.
