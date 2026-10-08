# Contributing to TabType

Thanks for helping! TabType is an **alpha** open-source project and contributions of every size are welcome — bug reports especially.

## Ways to help right now

- **Report app-specific bugs.** "Ghost text is misplaced in _X_" or "no suggestions in _Y_" reports are gold. Include the app, macOS version, and (if you can) a screenshot. Screenshots don't dismiss the ghost.
- **Per-app extraction recipes.** Some apps expose text cleanly, others don't. If an app misbehaves, `AppPolicy.swift` is where per-app behavior lives — small, self-contained additions.
- **More autocorrect languages** (`Sources/TabType/Core/Spelling/`, dictionaries in `Resources/`).
- **UI/UX polish** across the settings panes.
- **Notarization** — if you have an Apple Developer ID and want to help ship notarized builds, please reach out on an issue.

## Building & testing

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
./Scripts/setup-signing.sh                            # one-time, stable local identity
CONFIG=Release ./Scripts/build.sh app && open dist/TabType.app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

`swift build` compiles, but use `Scripts/build.sh app` to get a signed `.app` with its resources. Debug builds still compile `TabTypeKit` with `-O`, because the decoder is too slow unoptimised. Use the eval harness (`tabtype-eval`, see [eval/README.md](eval/README.md)) to measure any change to prompting or decoding before and after.

## Where things live

| Area | File(s) |
|---|---|
| Keystroke capture + orchestration | `Core/Engine.swift` (incl. the local field copy and lookahead), `Core/KeystrokeMonitor.swift` (listen-only tap), `Core/HotKeyCenter.swift` (Tab & shortcuts as hotkeys) |
| Context gathering | `Core/ContextReader.swift`, `Core/ScreenContextProvider.swift` (OCR above the field), `Core/TranscriptExtractor.swift` (accessibility fallback), `Core/TerminalPrompt.swift` |
| Prompt assembly | `TabTypeKit/Prompting/` (`PromptAssembler`, `ModelTemplate`) |
| Local inference | `TabTypeKit/Inference/` (llama.cpp runtime), `TabTypeKit/Decoding/` (token healing, phrase beam search, confidence gate), `Core/Engines/LlamaEngine.swift` |
| Models | `TabTypeKit/Catalog/` (`models.json`, downloader), `UI/` model settings |
| Rendering | `Core/SuggestionOverlay.swift` (ghost, text mirror), `Core/AccessibilityBridge.swift` (caret, AX font), `Core/FieldFitCache.swift`, `TabTypeKit/Placement/` (font fitting) |
| Suggestion lifecycle | `TabTypeKit/Session/` (type-through, Tab accept) |
| Personalization | `Core/WritingStore.swift`, `TabTypeKit/Personalization/` (suffix index) |
| Per-app rules | `Core/AppPolicy.swift` |
| Settings UI | `UI/SettingsView.swift`, `UI/Panes/ExtraPanes.swift` |

The [README architecture section](README.md#-architecture) shows how they connect.

## Conventions

- Match the surrounding style; keep comments about *why*, not *what*.
- Pure logic (trimming, filtering, budgeting, candidate assembly) belongs in testable static helpers — see `Tests/TabTypeTests/`. Add a test when you add such logic.
- Keep everything on-device. No network calls except model download.

## PRs

Small, focused PRs with a clear description. Note which apps/macOS versions you tested on. Run `swift test` before submitting.
