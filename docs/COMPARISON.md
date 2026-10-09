# TabType vs the alternatives

An honest, detailed comparison. TabType's goal is Cotypist-grade quality as a free, open-source, on-device app. This page is kept truthful — including where others still lead.

## TabType vs Cotypist

[Cotypist](https://cotypist.app/) is the closest product and our reference point. It is closed-source and freemium; TabType is open-source (MIT) and free with no account.

TabType's design follows Cotypist's, reconstructed from its observable behaviour and the structure of its app (no Cotypist code or prompt text is used). Status as of v2.1:

### Matches Cotypist
| Area | How |
|---|---|
| Model + decoding | Base GGUF model via llama.cpp on raw logits; 9-wide beam over phrases ranked by total probability; token healing for half-typed words; confidence-gated display |
| Length | Short / medium / long / very long = 2 / 4 / 7 / 10 words |
| Placement | Font, size and colour read from the app over accessibility (measured from the screen when only the size is reported); Cotypist's caret sanity checks; single-line snap; wraps across the field from the visual line start; hidden-input editors (Monaco); re-placed on the field's own notifications |
| Keyboard | Listen-only key tap; Tab / accept-all / Esc are system hotkeys only while a suggestion is up |
| Speed | No fixed waits; a local copy of the field so prediction starts before the app publishes the keystroke; a running generation is kept and spliced when you type ahead; the continuation after a suggestion is precomputed (instant Tab chains); 30 s result cache |
| Context | OCR of the area above the input field (≤800pt, field column ±70pt); capture on pause; a message keeps the context it started with |
| Gating | Typo check on the word being typed only; minimum field size; terminals only inside AI-agent prompts; mid-line per app |
| Extras | Per-app insertion workarounds (typing / per character / chunks / paste / first word typed, non-breaking spaces, Space key events, Paste and Match Style, Backspace after paste, straight quotes) and grey suggestion colour; alternatives and synonyms after a pause (Labs); emoji gender preference and neutral variant; text mirror preview per app; word alternatives and synonyms; per-app font size / offset; custom instructions; learning from your writing with a strength setting (gentle / balanced / strong) and "record only when I used a suggestion"; On battery power (on demand only, shorter suggestions, a smaller model); caret retry plan and line-height cache |

### Deliberately different (measured on `tabtype-eval`, seed-v1, Qwen3-4B base)
- **The beam starts from the model's best first word.** Letting it swap the first word (as Cotypist does) cost 3.6 points of next-word recall.
- **Plain prompt layout.** Cotypist wraps prompt parts in delimited, token-budgeted sections; its delimiters are encrypted, and ours measured worse (recall 58.3 → 55.7%). The sectioned layout is kept as an experiment (`--sections`).
- **Default model.** Qwen3-4B base on 16 GB+ Macs (Cotypist ships its own Gemma 4 E2B quantization). Run locally in TabType, Cotypist's model file was ~50 ms faster but saved 20% fewer characters on the author's writing (1.17 vs 1.46 per case) and 14% fewer on seed-v1 (3.12 vs 3.64), and is a larger file (3.4 vs 2.5 GB).
- **Thresholds** are tuned on our eval (show: 0.15 at a word boundary, 0.08 mid-word; extend while each word ≥ 0.05) — Cotypist's values couldn't be recovered.
- **Accessibility fallback** for chats when OCR finds nothing (Cotypist reads chats from the screen only).

### Done differently because there's no Apple Developer account
- **Updates:** TabType checks its GitHub Releases and installs in place after verifying the release's SHA-256 and code-signing identity (Cotypist uses Sparkle).
- **Sync between Macs:** iCloud Drive with passphrase-based end-to-end encryption (Cotypist uses iCloud with end-to-end encryption; CloudKit needs a paid developer account).

### Not in TabType
- Notarization (needs a paid Apple Developer ID) — first launch needs "Open Anyway"
- A rich-text editor support switch (no equivalent subsystem in TabType; the insertion workarounds cover the same problems)

**Measured, not guessed:** on the 192-case seed set the v2 engine reaches ~58–60% next-word recall at ~66–73% precision (by threshold), with ~48% of shown phrases right in full — up from 37% / 38% in v1. We have no comparable public numbers for Cotypist, so we don't claim parity.

**Where Cotypist still leads:** notarized (no Gatekeeper dance), auto-updating, tested across far more apps, and more polished. TabType is an alpha closing that gap in the open.

## TabType vs other open-source / indie tools

- **[Sombra](https://github.com/andlsac/Sombra)** — llama.cpp + macOS dictionary completions. Great lightweight approach; TabType shares the llama.cpp foundation and adds screen context above the field, a confidence-gated phrase search, instant Tab chains, and ghost text in the app's own font.
- **[KeyType](https://github.com/johnbean393/KeyType)** — explores constrained/grammar decoding. Impressive technique; TabType prioritizes context quality and per-app UX parity instead.
- **cotabby** — focused-window OCR context. TabType narrows it to the area above the field you're typing in, with an accessibility-tree fallback and per-app settings.

## TabType vs GitHub Copilot / macOS predictive text

- **Copilot & code assistants** — optimized for code in editors, often cloud-backed. TabType is for **prose, everywhere, fully private**, and deliberately stays out of the main code editor.
- **macOS inline predictive text** — single-word, OS-limited. TabType predicts multi-word continuations with real context.

*Have a correction? This comparison should stay honest — open an issue.*
