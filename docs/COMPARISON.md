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
| Extras | Text mirror preview per app; word alternatives and synonyms; per-app font size / offset; custom instructions; learning from your writing |

### Deliberately different (measured on `tabtype-eval`, seed-v1, Qwen3-4B base)
- **The beam starts from the model's best first word.** Letting it swap the first word (as Cotypist does) cost 3.6 points of next-word recall.
- **Plain prompt layout.** Cotypist wraps prompt parts in delimited, token-budgeted sections; its delimiters are encrypted, and ours measured worse (recall 58.3 → 55.7%). The sectioned layout is kept as an experiment (`--sections`).
- **Default model.** Qwen3-4B base on 16 GB+ Macs (Cotypist ships its own Gemma 4 E2B quantization). Gemma 4 E2B scored lower in our harness; Qwen3-4B is about twice the size, so the phrase search runs ~150 ms median.
- **Thresholds** are tuned on our eval (show: 0.10 at a word boundary, 0.15 mid-word; extend while each word ≥ 0.2) — Cotypist's values couldn't be recovered.
- **Accessibility fallback** for chats when OCR finds nothing (Cotypist reads chats from the screen only).

### Not (yet) in TabType
- Notarization and in-app auto-update (both need an Apple Developer account)
- Personalization strength (gentle / balanced / strong); recording text you didn't accept suggestions in
- Battery mode (shorter suggestions, a smaller model on battery)
- Per-app insertion workarounds (non-breaking space, paste-and-match-style, chunk size), smart-quote and rich-text toggles, grey suggestion colour
- iCloud sync; emoji neutral/gender preferences
- Caret retry plan and line-height cache for apps whose caret reports lag

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
