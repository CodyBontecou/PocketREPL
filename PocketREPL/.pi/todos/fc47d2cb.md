{
  "id": "fc47d2cb",
  "title": "🟠 Improve Dynamic Type support",
  "tags": [
    "accessibility",
    "high"
  ],
  "status": "closed",
  "created_at": "2026-03-11T01:23:30.769Z"
}

## Completed

Replaced 157 hardcoded `.font(.system(size:` calls with dynamic semantic font styles that respect user's preferred text size.

### Changes Made:

**EscherDesignSystem.swift** - Updated Font extension with Dynamic Type-compatible fonts:
- `escherDisplay` → `.title` (28pt equivalent)
- `escherTitle` → `.title2` (22pt equivalent)
- `escherHeadline` → `.headline` (17pt equivalent)
- `escherSubheadline` → `.subheadline` (15pt equivalent)
- `escherBody` → `.body` (16pt equivalent)
- `escherCallout` → `.callout` (15pt equivalent)
- `escherFootnote` → `.footnote` (13pt equivalent)
- `escherCaption` → `.caption` (12pt equivalent)
- `escherCaption2` → `.caption2` (11pt equivalent)
- `escherMini` → `.caption2` (10pt equivalent)
- `escherMono` → `.subheadline.monospaced` (14pt equivalent)
- `escherMonoSmall` → `.caption.monospaced` (12pt equivalent)
- `escherMonoMini` → `.caption2.monospaced` (10pt equivalent)
- `escherThin` → `.title.weight(.thin)` (for decorative icons)
- `escherMedium` → `.body.weight(.medium)` (medium weight variant)

**Files Updated:**
- ChatView.swift - 9 instances
- RootView.swift - 2 instances
- AgentView.swift - 8 instances
- SettingsView.swift - 8 instances
- FileBrowserView.swift - 9 instances
- ModelManagementView.swift - 90 instances

**Remaining:**
- 1 intentional dynamic scaled font (`size * 0.4`) for proportional icon rendering in ModelProviderIcon

All text now scales with iOS Accessibility text size settings.
