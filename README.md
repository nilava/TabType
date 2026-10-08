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
> **Built by a senior full-stack engineer (5+ years), in the open, with heavy use of AI.** Full transparency: AI was a real power tool throughout. The **code** was written with AI coding-assistant help; the **app icon/artwork and the documentation are AI-generated**; and **suggestions come from a third-party open-weights LLM** (Qwen3 base, via llama.cpp) running locally — TabType trains no models and reviews no output. This is still **not** a thin "AI generated a wrapper" app — it's a native macOS app with a hand-tuned local-inference pipeline and 130+ tests, with a human accountable for the architecture, debugging, and result. **See the complete [AI disclosure below](#-full-ai-disclosure--who-and-what-built-this).**

## 🙌 Help wanted — let's build the best open autocomplete for Mac

TabType is a solo, spare-time, non-commercial project, and it will only get better with a community around it. **If you find it useful, please pitch in** — every bit genuinely moves the needle:

- ⭐ **Star the repo** so others can find a free, private Cotypist alternative.
- 🐞 **Report bugs** — especially "ghost text is off in _app X_" or "no suggestions in _app Y_." These are the highest-value reports right now. [Open an issue »](../../issues/new/choose)
- 🧑‍💻 **Send a PR** — per-app fixes, more languages, UI polish. See [good first issues](../../issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22) and [CONTRIBUTING.md](CONTRIBUTING.md).
- 🍎 **Have an Apple Developer ID?** Help with notarization so new users skip the Gatekeeper warning.
- 💬 **Share feedback & ideas** in [Discussions](../../discussions).

No corporate backing, no paid tier, no ads — just trying to make something great and give it away. Thank you. 🙏

## What it is

As you type, TabType shows a dimmed **ghost-text** prediction of what comes next. Press **Tab** to accept a word, again for the next, or accept the whole thing at once. A local **base** language model (Qwen3-4B on 16 GB+ Macs, Qwen3-1.7B on 8 GB, as GGUF via [llama.cpp](https://github.com/ggml-org/llama.cpp) on Metal) continues your text directly — no chat prompt, no "assistant voice" — and a confidence-gated decoder only shows a suggestion when the model is actually sure. Personalized to how *you* write, and it all happens on-device.

## ✨ Features

**Completions**
- Inline ghost text everywhere you type, with pixel-matched placement and a text-mirroring mode for web apps
- Type-through: keep typing and the suggestion shrinks to match, never flickers
- Word-by-word or whole-suggestion accept; **word alternatives** popup (⌃⌥Space) when you want options
- **Confidence-gated**: every suggestion carries the model's own probability; low-confidence guesses are never shown, and multi-word phrases only extend while confidence holds
- **Token healing**: mid-word completions are re-tokenized so the model finishes the word you're typing instead of starting a new one
- **Font-fitted ghost text**: TabType renders candidate fonts and matches them against the pixels of the field, so the ghost matches the app's font and baseline

**Context awareness** — suggestions that actually fit what you're doing
- Reads the whole visible conversation in **15+ chat apps** (Slack, WhatsApp, Telegram, Signal, Teams, Discord…) **and chat websites** (claude.ai, ChatGPT, Gemini…) via the **accessibility tree** — clean, no screenshots — with screenshot OCR as the fallback elsewhere
- **Document-aware long-form context**: in writing apps (Pages, Word, Notes, Ulysses…) it reads a large window around your cursor *plus* the document's opening lines, so mid-document suggestions stay on topic
- **Per-app transparency**: Settings → Apps shows exactly what context recipe applies to every app (Chat / Document / Code editor badges + a plain-English summary) — and lets you change it per app
- Remembers **your recent messages** in a conversation and **your previous writing** so it continues your train of thought
- **Learns from your writing** (opt-in): an encrypted local index of what you've written nudges suggestions toward your names, phrases, and sign-offs

**Private by design**
- 100% on-device inference; the only network call is the one-time model download from Hugging Face
- Optional writing history is **AES-GCM encrypted** on disk (key file readable only by you) and never leaves the Mac
- Password fields and password managers are never read

**Models**
- Curated GGUF catalog (Qwen3 0.6B–4B base, Gemma 4) with RAM-based recommendations; resumable, SHA-256-verified downloads
- Optional **voice adapter**: load your own LoRA adapter (GGUF) to steer the model's style

**Control**
- Per-app and per-website policies (tone, language, enable/disable, mid-line behavior)
- Code editors get suggestions only in chat panels, never the main editor
- Low Power Mode tuning, force-activate & per-app pause shortcuts
- Inline `/macros` (`/date`, `/uuid`, `10km->mi`, `2+2*3`), `:emoji`, and local autocorrect (incl. 6 Indian languages)

## 🆚 How TabType compares

| | **TabType** | **Cotypist** | **Copilot / OS predictive text** |
|---|:---:|:---:|:---:|
| Price | **Free forever** | Freemium (paid tier) | Free / paid |
| Open source | **✅ MIT** | ❌ | ❌ |
| Runs on-device | ✅ | ✅ | ⚠️ mixed |
| Works in any app (prose) | ✅ | ✅ | ❌ code / single-word |
| Learns your voice | ✅ | ✅ | ❌ |
| Screen / conversation context | ✅ AX tree + OCR | ✅ | ❌ |
| Notarized / polished | ⚠️ alpha, unnotarized | ✅ | ✅ |

**vs [Cotypist](https://cotypist.app/)** — the closest comparison and our north star. TabType matches its core: on-device models, screen/accessibility context, personalization, text mirroring, speculative "parked" generation, and word alternatives. Cotypist is more polished, notarized, and has a paid tier; TabType is **free, open-source, and account-free**. We're the open project working toward Cotypist-grade quality.

### vs the open-source alternatives

There are a few other open-source macOS autocomplete projects — each great in its own way. Here's how TabType compares (and huge thanks to all of them for charting the path):

| | **TabType** | **[Sombra](https://github.com/andlsac/Sombra)** | **[KeyType](https://github.com/johnbean393/KeyType)** | **cotabby** |
|---|:---:|:---:|:---:|:---:|
| Open source | ✅ MIT | ✅ | ✅ | ✅ |
| Inference backend | llama.cpp (Qwen3 base) | llama.cpp | on-device LLM | on-device LLM |
| Context: screen OCR | ✅ | ✅ | — | ✅ focused window |
| Context: accessibility-tree transcript | ✅ | — | — | — |
| Remembers your recent messages / writing | ✅ | — | — | — |
| Learns from your writing (encrypted index) | ✅ | dictionary | — | — |
| Speculative "parked" generation + KV cache | ✅ | — | — | — |
| Word alternatives | ✅ | — | — | — |
| Text mirroring / baseline-probed rendering | ✅ | — | — | — |
| Per-app & per-domain policies | ✅ | per-app | — | — |
| Confidence-gated decoding + token healing | ✅ | — | — | — |
| Font-fitted ghost text | ✅ | — | — | — |

**Where each shines:** [Sombra](https://github.com/andlsac/Sombra) pairs llama.cpp with fast macOS-dictionary completions — a clean, lightweight approach. [KeyType](https://github.com/johnbean393/KeyType) explores constrained/grammar decoding for tightly-shaped output. cotabby pioneered focused-window OCR context. TabType's bet is **deeper context** (accessibility-tree transcripts, your recent messages, your own writing) plus a **confidence-gated base-model decoder** and **Cotypist-grade UX** (speculative parking, mirror rendering, per-app policies). See the [detailed comparison](docs/COMPARISON.md).

## 📦 Install

> [!NOTE]
> TabType has no Apple Developer account behind it (it's free and non-commercial — see below), so it is **not notarized**. macOS will warn you the first time. This is expected for open-source Mac apps; here's the one-time approval.

1. **Download** the latest `TabType-x.y.z.dmg` from [Releases](../../releases).
2. Open the DMG and **drag TabType to Applications**.
3. Launch it. macOS says *"TabType cannot be opened because Apple cannot check it for malicious software."* Click **Done** (not Move to Trash).
4. Open **System Settings ▸ Privacy & Security**, scroll down, and click **"Open Anyway"** next to TabType. Confirm.
   - *Power users, instead of steps 3–4:* `xattr -dr com.apple.quarantine /Applications/TabType.app`
5. Grant **Accessibility** when prompted (required — it's how TabType reads the text field and inserts completions). **Screen Recording** is optional (improves context in non-chat apps).
6. **First launch downloads the model** (~1.1–2.5 GB from Hugging Face, depending on your Mac's RAM tier). The menu-bar icon shows progress; suggestions start once it's ready.

**Requirements:** Apple Silicon Mac (M1 or later), macOS 14+.

## 🔒 Privacy

Nothing you type leaves your machine. Inference is 100% local. The only network requests TabType makes are downloading the model from Hugging Face and refreshing the public model list (`models.json`) from this repository — neither carries any of your text. Learning from your writing is opt-in; that history is AES-GCM encrypted on disk and never leaves the Mac.

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
KeystrokeMonitor (CGEventTap)
   → ContextReader / ScreenContextProvider / TranscriptExtractor   (what you typed + surrounding context)
   → PromptAssembler + ModelTemplate                               (budgeted, cache-friendly prompt)
   → InferenceEngine / LlamaRuntime (llama.cpp, prefix-cached KV)  (local generation)
   → CompletionDecoder                                             (token healing, parallel candidates, confidence gate)
   → SuggestionSession → SuggestionOverlay + FontFitter            (type-through, Tab accept, font-fitted ghost)
```

The model-agnostic pieces (runtime, decoder, prompt assembly, catalog, font fitting, personal index) live in the `TabTypeKit` library so the `tabtype-eval` harness exercises exactly what the app runs. Personalization (`WritingStore`, `PersonalIndex`/`SuffixIndex`), per-app rules (`AppPolicy`), and the settings UI (`SettingsView`) hang off this core. See [CONTRIBUTING.md](CONTRIBUTING.md) for a fuller tour.

## 🙋 Full AI disclosure — who and what built this

TabType is built by a **senior full-stack engineer with 5+ years of experience**, in the open, **with heavy use of AI**. In the spirit of transparency, here is a complete accounting of what in this project is AI-generated:

**Code** — Written with heavy AI coding-assistant help (in the [Claude Code](https://claude.com/claude-code) style), directed, reviewed, debugged, and architected by the author. This is **not** a thin "AI generated a wrapper" app: it's a native macOS application with a hand-tuned local-inference pipeline, reverse-engineering work to reach parity with the best in the category, careful Accessibility/Gatekeeper/AppKit integration, and 130+ tests. AI accelerated the typing; the engineering judgment and the hundreds of small correctness decisions are the author's.

**Icons & artwork** — The app icon and other visual assets are **AI-generated**.

**Documentation** — This README and the other docs (`CONTRIBUTING.md`, `RELEASING.md`, `docs/COMPARISON.md`, issue templates) were **written with AI assistance** and reviewed by the author.

**The completion model** — Suggestions come from a **third-party, open-weights language model** (by default the [Qwen3-4B base model](https://huggingface.co/Qwen/Qwen3-4B-Base) from Alibaba's Qwen team, as a community GGUF quantization; Google's Gemma and others are also selectable). TabType did **not** train or fine-tune any model — it runs these pre-trained weights locally via [llama.cpp](https://github.com/ggml-org/llama.cpp). Optional LoRA adapters are ones you supply yourself. Their training data and behavior are the model authors', governed by their respective licenses (e.g. the Qwen and Gemma terms).

**Runtime output provenance** — Every suggestion you see is **generated on-device by that language model** from your local context (the text you're typing, your recent messages/writing, and — with permission — nearby on-screen text). Outputs are probabilistic and **not curated, fact-checked, or reviewed** by a human or by us; treat them like any LLM output — they can be wrong, biased, or inappropriate. Nothing is sent to a server; generation is 100% local. TabType does not collect, transmit, or train on your text.

**What is *not* AI** — the product direction, architecture, the decision of what to build and how it should feel, the debugging, and the responsibility for the result. A human is accountable for this software.

## 🤝 Contributing

This is an alpha that wants collaborators. Great first contributions: per-app extraction recipes for apps that misbehave, more autocorrect languages, UI polish, and — if you have an Apple Developer ID — help with notarization. See [CONTRIBUTING.md](CONTRIBUTING.md).

## 📄 License

[MIT](LICENSE) — free for anyone to use, modify, and distribute. **There is no paid tier and no plan to ever commercialize TabType.** Built for the community.

## 🙏 Credits

[llama.cpp / ggml](https://github.com/ggml-org/llama.cpp) · [Qwen](https://github.com/QwenLM/Qwen) & [Gemma](https://ai.google.dev/gemma) models · GGUF quantizations by [mradermacher](https://huggingface.co/mradermacher) and [Unsloth](https://huggingface.co/unsloth) · bundled fonts under the [SIL Open Font License](https://openfontlicense.org). Inspiration from [Cotypist](https://cotypist.app/), [Sombra](https://github.com/andlsac/Sombra), and [KeyType](https://github.com/johnbean393/KeyType).
