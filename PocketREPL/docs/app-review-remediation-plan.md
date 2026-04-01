# App Review Remediation Plan (Guideline 2.5.2)

## What was implemented in the app

1. **Local model download UI is now gated** on Apple Intelligence-capable devices.
   - By default, users see Apple Intelligence onboarding.
   - Hugging Face model downloads are hidden unless users explicitly enable **Advanced Offline Mode**.

2. **Apple Intelligence onboarding card added** to Models screen.
   - Clear explanation that Apple Intelligence is the default path.
   - Button to open Apple Intelligence settings when unavailable.

3. **Advanced Offline Mode confirmation flow added**.
   - Explicit destructive-style confirmation before unlocking local model downloads.

4. **Routing safeguards added** in settings manager.
   - On Apple Intelligence-capable devices with Advanced Offline Mode off, routing is forced to Foundation Models to avoid accidental local fallback.

5. **Settings UI updated**.
   - Local/Hybrid routing options are disabled until Advanced Offline Mode is enabled.
   - Unavailability reasons now shown inline.

6. **Chat AI-unavailable messaging updated**.
   - Clarifies Apple Intelligence is the primary path.
   - Notes local downloads are optional Advanced Offline Mode.

## ASC actions executed

- ✅ Updated App Review notes (`asc review details-update`) with explicit technical context:
  - Foundation Models is primary path on AI-capable devices.
  - Offline mode is optional.
  - GGUF files are model weights.
  - JS execution is user-authored and editable in app.

- ⚠️ Availability blocker remains and must be initialized in App Store Connect UI (or web-session flow):
  - `app availability not found` means there is no initial availability record yet.

## Suggested reviewer reply (copy/paste)

Hello App Review Team,

Thank you for the feedback. We have made changes to ensure our primary AI path is clearly Apple Intelligence on supported devices.

- On Apple Intelligence-capable devices, PocketREPL now defaults to Foundation Models (`SystemLanguageModel`) and local model downloads are hidden by default.
- Local downloads are now behind an explicit **Advanced Offline Mode** opt-in.
- The optional `.gguf` files are neural network weight data used for offline inference.
- JavaScript execution uses Apple's JavaScriptCore and is limited to user-authored code that is fully visible and editable in-app.

We hope this addresses your concerns under Guideline 2.5.2. If you’d like, we can provide a short walkthrough of the exact user flow tested for this submission.

Thank you.
