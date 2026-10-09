<div align="center">

# ⌨️ TabType

### A free, open-source, 100% on-device AI autocomplete for macOS

**TabType predicts your next words as you type — in almost any app — and runs entirely on your Mac. No cloud. No account. No subscription. No telemetry.** It's an open-source [Cotypist](https://cotypist.app/) alternative that learns your voice and never sends a keystroke off your machine.

![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%E2%80%93M4-blue)
![Status: Alpha](https://img.shields.io/badge/Status-Alpha-orange)
![Built with llama.cpp](https://img.shields.io/badge/Built%20with-llama.cpp-red)

<em>Keywords: Cotypist alternative · open source macOS autocomplete · local AI text prediction Mac · on-device LLM typing assistant · private ghost-text completion</em>

<p align="center">
  <img src="docs/demo.gif" alt="TabType demo — ghost-text suggestion appearing inline and being accepted word-by-word with Tab" width="820">
</p>

</div>

---

> [!IMPORTANT]
> **Alpha + AI disclosure — please read first.**
>
> **This is an early alpha.** It works and it's genuinely useful day-to-day, but expect rough edges. It's an open-source project that **needs your help** — [try it](#-install), [file issues](../../issues), and [send PRs](CONTRIBUTING.md). Bug reports on specific apps are the single most valuable contribution right now.
>
> **Built by a senior full-stack engineer (5+ years), in the open, with heavy use of AI.** Full transparency: AI was a real power tool throughout. The **code** was written with AI coding-assistant help; the **app icon/artwork and the documentation are AI-generated**; and **suggestions come from a third-party open-weights LLM** (Qwen3 base, via llama.cpp) running locally — TabType trains no models and reviews no output. This is still **not** a thin "AI generated a wrapper" app — it's a native macOS app with a hand-tuned local-inference pipeline and 150+ tests, with a human accountable for the architecture, debugging, and result. **See the complete [AI disclosure below](#-full-ai-disclosure--who-and-what-built-this).**

## 🙌 Help wanted — let's build the best open autocomplete for Mac

TabType is a solo, spare-time, non-commercial project, and it will only get better with a community around it. **If you find it useful, please pitch in** — every bit genuinely moves the needle:

- ⭐ **Star the repo** so others can find a free, private Cotypist alternative.
- 🐞 **Report bugs** — especially "ghost text is off in _app X_" or "no suggestions in _app Y_." These are the highest-value reports right now. [Open an issue »](../../issues/new/choose)
- 🧑‍💻 **Send a PR** — per-app fixes, more languages, UI polish. See [good first issues](../../issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22) and [CONTRIBUTING.md](CONTRIBUTING.md).
- 🍎 **Have an Apple Developer ID?** Help with notarization so new users skip the Gatekeeper warning.
- 💬 **Share feedback & ideas** in [Discussions](../../discussions).

No corporate backing, no paid tier, no ads — just trying to make something great and give it away. Thank you. 🙏

## What it is

As you type, TabType shows a dimmed **ghost-text** prediction of what comes next. Press **Tab** to accept a word, again for the next, or a separate shortcut to accept it all. A local **base** language model (Qwen3-4B on 16 GB+ Macs, Qwen3-1.7B on 8 GB, as GGUF via [llama.cpp](https://github.com/ggml-org/llama.cpp) on Metal) continues your text directly — no chat prompt, no "assistant voice" — and a confidence-gated decoder only shows a suggestion when the model is actually sure. Personalized to how *you* write, and it all happens on-device.

## ✨ Features

**Completions**
- Inline ghost text everywhere you type, drawn **in the app's own font, size and colour** (read from the app, measured from the screen when the app doesn't say) and wrapped like real text across the field
- **Phrase search**: 9 candidate phrases are explored together and the most probable whole phrase wins; every suggestion carries the model's own probability, and weak guesses are never shown
- **Token healing**: mid-word suggestions finish the word you're typing instead of starting a new one
- **Instant Tab chains**: the words after the suggestion are computed while it's on screen, so Tab-Tab-Tab keeps going without waiting
- **Fast**: the ghost appears as soon as the app catches up (no fixed delays); a generation already running when you type ahead is kept and reused; recent results are cached
- Type-through, **word alternatives** (⌃⌥Space), Esc to dismiss — and TabType only *listens* to the keyboard: Tab is taken from the app only while a suggestion is showing

**Context awareness** — suggestions that fit what you're doing
- Reads the conversation or document **above the field you're typing in** (on-device OCR, like Cotypist) — chats, email, docs — with the accessibility tree as a fallback; captures when you pause, waits for a chat's first capture, and keeps a message's context steady while you type it
- **Document-aware long-form context**: in writing apps it reads a large window around your cursor *plus* the document's opening lines
- **Per-app transparency**: Settings → Apps shows exactly what each app gets — and lets you change it
- **Learns from your writing** (opt-in): an encrypted local index of what you've written nudges suggestions toward your names, phrases and sign-offs; turning it on imports your existing writing history once
- **Terminals**: suggestions inside AI agents' prompts (Claude Code, Codex, Gemini CLI) — never at the shell

**Private by design**
- 100% on-device inference; the only network requests are the model download, the public model list and the update check
- Optional writing history is **AES-GCM encrypted** on disk and never leaves the Mac
- Password fields and password managers are never read; small fields (search boxes) are skipped
- The diagnostic log is capped (5 MB) and only holds typed text while *Verbose logging* is on; Settings → Advanced deletes it

**Models**
- Curated GGUF catalog (Qwen3 0.6B–4B base, Gemma 4) with RAM-based recommendations; resumable, SHA-256-verified downloads

**Control**
- Per-app and per-website settings: enable/disable, mid-line suggestions, ghost size and offset, custom instructions, a **text mirror** preview for apps where inline ghost text can't be placed
- Code editors get suggestions only in chat panels, never the main editor
- Force-activate, per-app pause and global toggle shortcuts
- Per-app insertion workarounds for apps that mangle inserted text (typing vs pasting, chunk size, non-breaking spaces, Paste and Match Style…)
- Inline `/macros` (`/date`, `/uuid`, `/10km->mi`, `/2+2*3`), `:emoji` (skin tone, gender preference), and local autocorrect (incl. 6 Indian languages)
- **On battery power**: on-demand only, shorter suggestions, or a smaller model
- **Sync between Macs** via iCloud Drive, end-to-end encrypted with your passphrase
- **In-app updates** from GitHub Releases, verified (checksum + signature) before installing

## 🔬 What changed in v2.1 — and why

v2.0 worked, but next to Cotypist it felt worse: the ghost sat in the wrong place, appeared late, was usually one word, and often missed what the conversation was about. For v2.1 we studied Cotypist's observable behaviour and the structure of its app (no Cotypist code, prompt text or model is used), live-tested in TextEdit, Chrome, Safari, Terminal, Claude and Slack, and measured every change on two eval sets: the public 192-case seed set and a private set of 867 cases built from the author's own messages (kept out of git). Here's what we found and what we did about it.

### Placement — the ghost should look typed by the app
| Found | Changed |
|---|---|
| The font was never read from the app (the code looked for a type that doesn't cross processes): 0 of 984 placements had it, so the size was guessed | Read the app's font and colour over accessibility; pixel-fit from the screen only when the app reports just a size |
| Screen captures of fractional rects were squeezed, and transparent pixels and trailing spaces threw the fitter off | Capture whole pixels and crop; transparent counts as background; the fitter keeps trailing spaces |
| Apps sometimes report a caret on the wrong line, a huge marker rect, or a frame outside the field | Cotypist-style caret sanity checks, snap to the line, retry at 40/80/160 ms, a per-field line-height cache |
| Long suggestions ran off the field's edge | Wrap across the field from the visual line start, like real text |
| Web editors with a hidden input (Monaco-style) had no caret | Treat the hidden input's frame as the caret |
| A faint box flashed as the ghost faded in | No window animation; the overlay is invisible to accessibility |

### Speed — the ghost should appear as soon as the app catches up
| Found | Changed |
|---|---|
| Fixed delays waited for typing to "settle" | Present the moment the app's caret reaches where TabType expects it — no fixed waits |
| Every keystroke waited for the app to publish its text | Keep a local copy of the field plus the keys the app hasn't shown yet, confirmed by content (an observing tap can hear a key after the app already showed it) |
| Typing ahead threw away a generation that was nearly done | Keep it and splice it when the new text is a prefix of the suggestion |
| Tab-Tab-Tab waited for a new prediction per word | Precompute what follows the suggestion while it's on screen; 30 s result cache |
| The first keystroke in a new field waited up to 0.4 s | Re-read the field once it settles after focus moves |
| The first suggestion after launch took ~2.2 s (the spelling dictionary loaded inside the typo check) | Load it in the background at launch → ~240 ms |

### Suggestions — longer, and only when the model is sure
| Found | Changed |
|---|---|
| Suggestions were almost always one word: each extra word needed ≥ 50% probability | A 9-wide **beam search over whole phrases** (Cotypist's search), started from the model's best first word, then a measured extension bar: 0.5 → 0.2 → **0.05**. On the author's writing that's 2.2 words on average (57% multi-word, was 22%) and the most typing saved (1.46 vs 1.37 chars per case) — the first word never changes |
| One confidence bar for everything showed wrong next-word guesses and hid good word endings | Split bar: lower mid-word (finishing a word is right 53–65% of the time), higher at a word boundary (21–32%) |
| Half-typed misspellings got completed | Also check the word being typed: one that can't become a real word gets no suggestion (as Cotypist does) |
| Several settings (suggestion delay, context size, screenshot mode, the voice adapter…) got in the way of suggestions | Removed; length stays (Cotypist's 2 / 4 / 7 / 10 words) |

### Context — know what the conversation is about
| Found | Changed |
|---|---|
| Context went stale: captures froze while typing and none ran at a pause — Slack had no context for 334 of 406 predictions | Capture 1.1 s after the last keystroke; keep screen context even on a message's first words |
| OCR read a band around the caret, which lost left-aligned incoming chat bubbles | OCR the area **above the field** you're typing in (≤ 800 pt, the field's column ± 70 pt), the accessibility tree as a fallback |
| Context changed under you mid-message, rewriting the prompt (and the model's cache) | Capture when you pause; a message keeps the context it started with, refreshed after 2 s idle, on Return or focus change |
| The first suggestion in a chat had no context yet | Wait up to 0.3 s for a chat's first capture |
| "Name: …" conversation framing helped labelled transcripts but hurt OCR text (31.8 → 33.4% chat recall without it) | Frame as a conversation only when the text really is a transcript |

### Keys — never get in the way
| Found | Changed |
|---|---|
| An intercepting key tap could delay or drop keys | **Listen-only** tap; Tab, ⇧Tab and Esc are system hotkeys only while a suggestion is up, re-sent to the app when there's nothing to do |
| A quick double Tab moved focus: Chromium re-announces focus on the same field, which dropped the rest of the suggestion | Ignore same-field focus echoes; don't re-place on stale WebKit caret bounds after Tab |
| The listen-only tap can hear a key after the app showed it, so the local copy sometimes added it twice | Timestamped pending keys, confirmed against the field's content |
| ⌥Tab reached the app as ⌥Tab | ⌥ + the accept key sends the plain key (a real Tab) |
| Terminals got suggestions at the shell prompt | Only inside AI agents' prompts (Claude Code, Codex, Gemini CLI) |
| Search boxes got suggestions | Skip small fields (Cotypist's size gate) |

### Reliability
- **Suggestions stopped after a while** — the model was unloaded when idle or under memory pressure and never reloaded. It's now parked and reloaded on the next keystroke.
- The public model list on `main` could override this build's tuning — only a strictly newer list is used now.
- Interrupted model downloads resume at launch. The diagnostic log is capped at 5 MB and holds typed text only while *Verbose logging* is on.

### What we tried and didn't ship
| Tried | Result |
|---|---|
| Letting the beam replace the first word (as Cotypist does) | −3.6 points next-word recall |
| A sectioned, token-budgeted prompt layout (like Cotypist's) | Recall 58.3 → 55.7%; kept as an eval experiment (`--sections`) |
| Gemma 4 E4B | Below Qwen3-4B on the author's writing (30.2 vs 31.0% recall) and slower (217 vs 148 ms) |
| Cotypist's own model file (Gemma 4 E2B), tested locally | Loads and runs fine in TabType and is ~50 ms faster, but saves 20% fewer characters on the author's writing (1.17 vs 1.46) and 14% fewer on the seed set (3.12 vs 3.64), at a larger file (3.4 vs 2.5 GB). The model isn't Cotypist's edge — Qwen3-4B stays |
| No extension bar at all | Barely more saved (1.47 vs 1.46 chars) for 15% more wrong words |

### Where it stands
On real chat, suggestion quality is limited by how predictable people are: about a third of next words are guessable (34% on the author's writing; 59% on the seed set), finishing a half-typed word is right about half the time, and guessing the word after a space about a fifth. Screen context (27.5 → 31.0% recall) and learning from your writing (+5% characters from only 177 messages) are the levers that move it, so turning on *Learn from your writing* matters. Full numbers: [eval/README.md](eval/README.md); feature-by-feature status vs Cotypist: [docs/COMPARISON.md](docs/COMPARISON.md).

## 🆚 How TabType compares

| | **TabType** | **Cotypist** | **Copilot / OS predictive text** |
|---|:---:|:---:|:---:|
| Price | **Free forever** | Freemium (paid tier) | Free / paid |
| Open source | **✅ MIT** | ❌ | ❌ |
| Runs on-device | ✅ | ✅ | ⚠️ mixed |
| Works in any app (prose) | ✅ | ✅ | ❌ code / single-word |
| Learns your voice | ✅ | ✅ | ❌ |
| Screen / conversation context | ✅ OCR + AX fallback | ✅ | ❌ |
| In-app updates | ✅ GitHub Releases, verified | ✅ | ✅ |
| Notarized | ❌ (alpha, no paid developer account) | ✅ | ✅ |

**vs [Cotypist](https://cotypist.app/)** — the closest comparison and our north star. TabType now follows its design closely: base-model phrase search, font matching from the app, context from above the field, listen-only keyboard with Tab as a hotkey, instant Tab chains, a text mirror. Cotypist is more polished, notarized, auto-updating and has a paid tier; TabType is **free, open-source and account-free**. Where they still differ (and why) is in the [detailed comparison](docs/COMPARISON.md).

### vs the open-source alternatives

There are a few other open-source macOS autocomplete projects — each great in its own way. Here's how TabType compares (and huge thanks to all of them for charting the path):

| | **TabType** | **[Sombra](https://github.com/andlsac/Sombra)** | **[KeyType](https://github.com/johnbean393/KeyType)** | **cotabby** |
|---|:---:|:---:|:---:|:---:|
| Open source | ✅ MIT | ✅ | ✅ | ✅ |
| Inference backend | llama.cpp (Qwen3 base) | llama.cpp | on-device LLM | on-device LLM |
| Context: screen OCR | ✅ above the field | ✅ | — | ✅ focused window |
| Context: accessibility-tree fallback | ✅ | — | — | — |
| Learns from your writing (encrypted index) | ✅ | dictionary | — | — |
| Phrase search + confidence gate + token healing | ✅ | — | — | — |
| Instant Tab chains (lookahead) | ✅ | — | — | — |
| Word alternatives | ✅ | — | — | — |
| Ghost in the app's own font | ✅ | — | — | — |
| Per-app & per-domain settings | ✅ | per-app | — | — |

**Where each shines:** [Sombra](https://github.com/andlsac/Sombra) pairs llama.cpp with fast macOS-dictionary completions — a clean, lightweight approach. [KeyType](https://github.com/johnbean393/KeyType) explores constrained/grammar decoding for tightly-shaped output. cotabby pioneered focused-window OCR context. TabType's bet is **Cotypist-grade behaviour in the open**: a measured, confidence-gated base-model decoder, context from the screen, and placement that looks typed by the app. See the [detailed comparison](docs/COMPARISON.md).

## 📦 Install

> [!NOTE]
> TabType has no Apple Developer account behind it (it's free and non-commercial — see below), so it is **not notarized**. macOS will warn you the first time. This is expected for open-source Mac apps; here's the one-time approval.

1. **Download** the latest `TabType-x.y.z.dmg` from [Releases](../../releases).
2. Open the DMG and **drag TabType to Applications**.
3. Launch it. macOS says *"TabType cannot be opened because Apple cannot check it for malicious software."* Click **Done** (not Move to Trash).
4. Open **System Settings ▸ Privacy & Security**, scroll down, and click **"Open Anyway"** next to TabType. Confirm.
   - *Power users, instead of steps 3–4:* `xattr -dr com.apple.quarantine /Applications/TabType.app`
5. Grant **Accessibility** when prompted (required — it's how TabType reads the text field and inserts completions). **Screen Recording** is strongly recommended: it's how TabType reads the conversation or document you're writing in, and measures fonts apps don't report.
6. **First launch downloads the model** (~1.1–2.5 GB from Hugging Face, depending on your Mac's RAM tier). The menu-bar icon shows progress; suggestions start once it's ready.

**Requirements:** Apple Silicon Mac (M1 or later), macOS 14+.

## 🔒 Privacy

Nothing you type leaves your machine. Inference is 100% local. The only network requests TabType makes are downloading the model from Hugging Face, refreshing the public model list (`models.json`) from this repository, and checking this repository's GitHub Releases for updates (daily; can be turned off in Settings ▸ About) — none carries any of your text. Learning from your writing is opt-in; that history is AES-GCM encrypted on disk and never leaves the Mac.

## 🛠 Build from source

```sh
# One-time: point at full Xcode (llama.cpp ships as a prebuilt XCFramework)
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# One-time: stable self-signed identity so macOS keeps your permission grants across builds
./Scripts/setup-signing.sh

# Build + run (use CONFIG=Release for a fast, shippable build)
CONFIG=Release ./Scripts/build.sh app && open dist/TabType.app

# Run tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

> `swift build` compiles, but use `Scripts/build.sh` to get a signed `.app` bundle with its resources (catalog, bundled fonts).
>
> Measure suggestion quality with the offline eval harness: `swift run -c release tabtype-eval --help` (see [eval/README.md](eval/README.md)).

## 🏗 Architecture

The pipeline, end to end:

```
KeystrokeMonitor (listen-only tap) + HotKeyCenter (Tab etc. while a ghost is up)
   → ContextReader + local field copy / ScreenContextProvider (OCR above the field)
                                                                   (what you typed + surrounding context)
   → PromptAssembler + ModelTemplate                               (budgeted, cache-friendly prompt)
   → InferenceEngine / LlamaRuntime (llama.cpp, prefix-cached KV)  (local generation, 9-wide beam)
   → CompletionDecoder                                             (token healing, phrase search, confidence gate)
   → SuggestionSession → SuggestionOverlay (+ lookahead)           (type-through, Tab chains, ghost in the app's font)
```

The model-agnostic pieces (runtime, decoder, prompt assembly, catalog, font fitting, personal index) live in the `TabTypeKit` library so the `tabtype-eval` harness exercises exactly what the app runs. Personalization (`WritingStore`, `PersonalIndex`/`SuffixIndex`), per-app rules (`AppPolicy`), and the settings UI (`SettingsView`) hang off this core. See [CONTRIBUTING.md](CONTRIBUTING.md) for a fuller tour.

## 🙋 Full AI disclosure — who and what built this

TabType is built by a **senior full-stack engineer with 5+ years of experience**, in the open, **with heavy use of AI**. In the spirit of transparency, here is a complete accounting of what in this project is AI-generated:

**Code** — Written with heavy AI coding-assistant help (in the [Claude Code](https://claude.com/claude-code) style), directed, reviewed, debugged, and architected by the author. This is **not** a thin "AI generated a wrapper" app: it's a native macOS application with a hand-tuned local-inference pipeline, reverse-engineering work to reach parity with the best in the category, careful Accessibility/Gatekeeper/AppKit integration, and 150+ tests. AI accelerated the typing; the engineering judgment and the hundreds of small correctness decisions are the author's.

**Icons & artwork** — The app icon and other visual assets are **AI-generated**.

**Documentation** — This README and the other docs (`CONTRIBUTING.md`, `RELEASING.md`, `docs/COMPARISON.md`, issue templates) were **written with AI assistance** and reviewed by the author.

**The completion model** — Suggestions come from a **third-party, open-weights language model** (by default the [Qwen3-4B base model](https://huggingface.co/Qwen/Qwen3-4B-Base) from Alibaba's Qwen team, as a community GGUF quantization; Google's Gemma and others are also selectable). TabType did **not** train or fine-tune any model — it runs these pre-trained weights locally via [llama.cpp](https://github.com/ggml-org/llama.cpp). Their training data and behavior are the model authors', governed by their respective licenses (e.g. the Qwen and Gemma terms).

**Runtime output provenance** — Every suggestion you see is **generated on-device by that language model** from your local context (the text you're typing, your recent messages/writing, and — with permission — nearby on-screen text). Outputs are probabilistic and **not curated, fact-checked, or reviewed** by a human or by us; treat them like any LLM output — they can be wrong, biased, or inappropriate. Nothing is sent to a server; generation is 100% local. TabType does not collect, transmit, or train on your text.

**What is *not* AI** — the product direction, architecture, the decision of what to build and how it should feel, the debugging, and the responsibility for the result. A human is accountable for this software.

## 🤝 Contributing

This is an alpha that wants collaborators. Great first contributions: per-app extraction recipes for apps that misbehave, more autocorrect languages, UI polish, and — if you have an Apple Developer ID — help with notarization. See [CONTRIBUTING.md](CONTRIBUTING.md).

## 📄 License

[MIT](LICENSE) — free for anyone to use, modify, and distribute. **There is no paid tier and no plan to ever commercialize TabType.** Built for the community.

## 🙏 Credits

[llama.cpp / ggml](https://github.com/ggml-org/llama.cpp) · [Qwen](https://github.com/QwenLM/Qwen) & [Gemma](https://ai.google.dev/gemma) models · GGUF quantizations by [mradermacher](https://huggingface.co/mradermacher) and [Unsloth](https://huggingface.co/unsloth) · bundled fonts under the [SIL Open Font License](https://openfontlicense.org). Inspiration from [Cotypist](https://cotypist.app/), [Sombra](https://github.com/andlsac/Sombra), and [KeyType](https://github.com/johnbean393/KeyType).
