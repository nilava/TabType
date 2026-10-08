# TabType v2 — Rewrite Plan

Goal: rebuild TabType's suggestion pipeline around the architecture that makes the
reference product (Cotypist) feel right: a llama.cpp engine with a **custom decoder**,
**direct text continuation** instead of chat-style instruction, **confidence-gated
short completions**, and **screenshot-fitted ghost-text rendering**. This is a rewrite,
not a tuning pass — most of `Core/` is replaced.

> Ground rule: replicate *techniques and behaviour*, never copy the reference product's
> code, prompt wording, or assets. All prompts, heuristics and code here are our own.
> Bundled fonts must be OFL/Apache-licensed; Gemma models require showing Google's
> Gemma Terms notice before download.

---

## 1. What we are replicating (target behaviour)

| Area | Target behaviour | Why it matters |
|---|---|---|
| Inference | llama.cpp (Metal) + GGUF models, direct C API | Raw logits, multi-sequence KV cache, LoRA — none of which MLX's high-level API gives cheaply |
| Decoding | Own decoder on raw logits: parallel candidate sequences, scored by **average log-probability**; no stock sampler | Confidence is the core product decision: show only what the model is sure of |
| Mid-word | Back up to the word start and **constrain** decoding to tokens consistent with the typed letters ("token healing") | Correct completions of half-typed words, names and jargon with no dictionary heuristics |
| Prompting | **Base models continue raw text.** Instruct models get per-model templates where the typed text is **prefilled into the assistant turn** (Qwen3: thinking disabled) | The model *is* the author; reply drift disappears, so the reply-detection filter stack goes away |
| Length | Mostly **one word at a time** (real-world usage: ~10.9k accepts averaging 1.0 word / 4.6 chars vs 44 long ones), optional longer phrase | Accuracy of the next word is the product |
| Context | AX field snapshot (value, selection, placeholder, title, window title, app, URL host, OS user name), web text markers, screenshot + Vision OCR, opt-in clipboard, **secret sanitizer** over everything | Relevant context without leaking credentials |
| Placement | Caret rect with retry plan + line-height cache; **font fitting**: render candidate fonts/sizes and pick the best match to a screenshot of the line by RMSE → font, size, vertical offset, colour, confidence; **text-mirror overlay** when caret geometry is unreliable; anchored pill fallback | Ghost text that looks typed by the app itself |
| Interaction | Tab = accept word, separate full-accept key, type-through, Esc pause, secure-input detection banner, per-app & per-domain overrides, size thresholds | Polished feel |
| Personalisation | Opt-in writing recording (encrypted), retrieval over own writing, global + per-app custom instructions, LoRA adapters | "Sounds like me" |

---

## 2. Target architecture

```
KeystrokeMonitor ──► InputSession (field state machine)
                          │
          ┌───────────────┼────────────────────┐
          ▼               ▼                    ▼
   FieldSnapshotter  EnvironmentContext   Placement pipeline
   (AX + text marks) (OCR, clipboard,     (CaretResolver →
          │           window, app)         FontFitter → GhostRenderer
          │               │                 / TextMirror / Pill)
          ▼               ▼                    ▲
       PromptAssembler (per-model template,    │
        SecretSanitizer, token healing split)  │
                          │                    │
                          ▼                    │
     LlamaRuntime (model, context, KV seqs) ◄─ CompletionDecoder
                          │   (candidates, constraints, scoring,
                          │    confidence gate, stop rules)
                          ▼
                  CompletionResult {text, words[], logprobs, confidence,
                                     leadingWS, predictedTrailingSpace, alternatives}
```

### New modules (Sources/TabType/…)

| Module | Responsibility |
|---|---|
| `Inference/LlamaRuntime.swift` | Load GGUF, create context (n_ctx, n_batch, flash-attn, full Metal offload), tokenize/detokenize, vocab text table, batched decode, KV sequence ops (`seq_rm/cp/keep/add`), shift support detection (`memory_can_shift`, `n_swa`), LoRA attach/detach. Single serial actor. |
| `Inference/VocabIndex.swift` | Precomputed token → piece text (with leading-space flag), prefix trie for constraint lookups, special/control token mask. |
| `Inference/PromptCache.swift` | Longest-common-prefix reuse on sequence 0; tail `seq_rm`; front-trim via `seq_rm`+`seq_add` shift when supported, full rebuild otherwise. |
| `Decoding/CompletionDecoder.swift` | Candidate search (see §4), constraint masks, scoring, stop rules, confidence gate, alternatives. |
| `Decoding/TokenHealing.swift` | Split typed text at the last word boundary; build per-step allowed-token sets from remaining typed chars. |
| `Prompting/ModelTemplate.swift` | Per-model template (kind: base/instruct; user prefix; assistant prefix; optional system prefix; extra directives e.g. no-think block; stop tokens). |
| `Prompting/PromptAssembler.swift` | Builds token sequence: [template head][instructions + context][assistant prefix][typed text up to heal point]. Stable-first ordering for KV reuse. |
| `Context/FieldSnapshot.swift` | AX value, selection, placeholder, role/subrole, title, window title, app, URL host, caret line text, text-after-caret, web `AXTextMarker` path. |
| `Context/EnvironmentContext.swift` | OCR transcript of focused window (scoped to caret region/column), clipboard (opt-in, fresh only), recent sent messages, source descriptor. |
| `Context/SecretSanitizer.swift` | Regex scrub of API keys, tokens, signed-URL params, `password=`/`kennwort:` values, env-var assignments, IBANs, private-key blocks, card numbers — applied to every context string before it reaches the model. |
| `Placement/CaretResolver.swift` | Caret rect via `AXBoundsForRange` (zero-length, then char-before, then line), web text markers, retry plan with backoff, `LineHeightCache` per app/field. |
| `Placement/FontFitter.swift` | Screenshot the caret line; render the known line text with candidate fonts × sizes via CoreText; compare normalized column/row ink profiles; RMSE → best font/size/baseline offset, ink colour, dark-mode flag, confidence; cache per (app, field, line height). |
| `Placement/GhostRenderer.swift` | Borderless non-activating overlay window drawing ghost text in the fitted font at the fitted baseline; `TextMirror` mode re-draws the caret line + ghost when geometry is unreliable; `AnchoredPanel` pill fallback. |
| `Session/InputSession.swift` | Field-level state machine (idle → requesting → showing → accepting → typed-through), replaces the 1,800-line `Engine.swift`. Owns cancellation tokens, remainder protection, type-through, Esc pause. |
| `Catalog/ModelCatalog.swift` | Remote JSON catalog (hosted in this repo, e.g. `catalog/models.json` via raw GitHub) + bundled fallback; tiers by RAM; quant-name parsing; custom models folder; memory/disk warnings; "recommended model update" notice. |
| `Personalization/WritingStore.swift` | Opt-in per-app/per-domain recording into an encrypted SQLite DB (GRDB); erase controls. |
| `Personalization/SuffixIndex.swift` | Suffix array over recorded writing; retrieve continuations matching the current tail → injected as context / logit bias. |
| `Telemetry/LatencyTelemetry.swift` | Local-only per-cycle timings (snapshot, prompt, prefill, decode, placement) + short/long accept stats. |

### Kept and adapted

`KeystrokeMonitor`, `TextInserter`, `KeyBinding`, `AccessibilityBridge` (trimmed into
`FieldSnapshot`/`CaretResolver`), `InlineCommand/*` (emoji/macros), `Spelling/*`
(autocorrect only — **no longer used to gate or reconcile completions**), `ModelDownloader`
(re-pointed at GGUF files), `ModelStorage`, `Statistics` funnel, `Log`, `PowerMonitor`,
Settings UI shell, `LaunchAtLogin`, onboarding.

### Deleted

`Engines/MLXEngine.swift`, `Predictor.swift`, `PromptBuilder.swift`,
`CompletionInstructions.swift`, `SuggestionTrimmer`, `GhostAppearanceProbe.swift`
(superseded by `FontFitter`), `TranscriptNormalizer`, `OCRCleaner` (replaced by scoped
OCR), `PhraseMemory` (replaced by `SuffixIndex`), most of `Engine.swift`
(`stripEcho`, `stripAssistantSpeak`, `reconcileMidWord`, typo gate, parked/speculative
machinery), MLX / swift-transformers / swift-jinja dependencies.
`FoundationModelEngine` (Apple Intelligence) is dropped — it can't expose logits, so it
can't participate in confidence gating.

---

## 3. Inference engine (llama.cpp)

- Dependency: llama.cpp release **XCFramework** as a SwiftPM `.binaryTarget` (pin a
  build recent enough for Gemma 4 + Qwen3). Wrap the C API in `LlamaRuntime` only.
- Context params: `n_ctx` 4096 (configurable), `n_batch` 512, `n_seq_max` = 1 + max
  candidates (e.g. 5), flash attention on, all layers on Metal, `use_mmap`.
- Threading: one serial actor owns model + context. Every request carries a generation
  id; a newer keystroke cancels by id, and decoding checks the id between steps (llama.cpp
  calls are synchronous and short, so cooperative cancellation is safe — no "zombie"
  generations).
- KV reuse: sequence 0 holds the prompt. New request → LCP against cached tokens →
  `seq_rm(0, lcp, -1)` → decode only the suffix. If the *front* of the prompt changes
  (context window slid), and `memory_can_shift` is true and the model has no SWA layers,
  `seq_rm` the dropped span and `seq_add` to shift; otherwise rebuild.
- Candidates use sequences 1…k: `seq_cp(0 → i)` then decode in one batch; finished →
  `seq_rm(i)`.
- Warm-up: decode the static template head on model load and on app focus change.
- Memory: refuse/ warn when model size > safe fraction of RAM; unload after idle.

## 4. Decoder (the core of quality)

Inputs: prompt tokens up to the heal point, the "healed" partial word (may be empty),
mode (short = next word, long = phrase), limits.

1. **Token healing.** Split the typed text at the last word boundary. The partial word
   is removed from the prompt; decoding must regenerate it. At each step, allowed tokens
   are those whose piece text is consistent with the remaining partial
   (`piece.hasPrefix(remaining)` or `remaining.hasPrefix(piece)`), honoring the leading
   space flag. Implemented as a logit mask from `VocabIndex`. Once the partial is
   consumed, decoding is unconstrained. The healed partial is stripped from the shown
   ghost text.
2. **Candidate expansion.** Take the top-k first tokens (k≈4) above a minimum
   probability; fork each into its own KV sequence; continue all candidates greedily in
   one batched decode per step.
3. **Stop rules.** Short mode: stop each candidate at the end of the first complete word
   (next token starts with whitespace/punctuation), recording `predictedTrailingSpace`.
   Long mode: stop at sentence end, newline, max words, or when token logprob falls
   below a floor. EOS/EOT and control tokens always stop.
4. **Scoring.** Per candidate: total and **average logprob**; merge candidates that
   detokenize to the same text (sum probabilities).
5. **Confidence gate.** Show the best candidate only if average logprob ≥ threshold
   (tuned per model on the eval set) and the first word clears its own threshold. Long
   mode: truncate to the longest prefix whose running average stays above the threshold.
6. **Output.** `CompletionResult` with text, per-word logprobs, confidence,
   leading-whitespace handling, predicted trailing space, and the runner-up first words
   as **alternatives** (for the word picker).
7. **Alternatives / synonyms.** Word picker = other candidates' first words with
   probabilities. Synonyms for a selected word = re-run decoding at that position with
   the selected word's tokens masked out.

No echo filters, no assistant-speak filters, no dictionary plausibility checks: the
continuation format and the confidence gate make them unnecessary.

## 5. Prompting

- **Base models (default).** Prompt = a short natural document header built from
  context (e.g. app/site and window title, OCR'd conversation or page excerpt, custom
  instructions phrased as notes about the author), then a blank line, then the typed
  text. The model simply continues the document.
- **Instruct models.** `ModelTemplate` per family (ChatML/Qwen3 with thinking disabled,
  Gemma turn markers, Llama 3 headers, Phi). User turn = our own short continuation
  instruction + custom instructions + context. Assistant turn is opened and **prefilled
  with the typed text**, so generation continues the author's text.
- Ordering for cache reuse: template head → custom instructions → stable context
  (window title, document start) → volatile context (OCR, clipboard) → typed text.
- All context passes through `SecretSanitizer` and per-section character budgets.

## 6. Context capture

- `FieldSnapshot`: one AX read per cycle; web views use `AXTextMarker` /
  `AXStringForTextMarkerRange` for text and bounds when `AXValue` is truncated;
  detect editors that focus a hidden input (CodeMirror/Monaco) and read the visible
  editor instead.
- `EnvironmentContext`: Vision OCR (`VNRecognizeTextRequest`, accurate, language
  correction) on the focused window, scoped to the content column around the caret;
  capture only while idle, never mid-burst; keyed by window + content hash so the KV
  prefix stays stable.
- Clipboard: opt-in, only if changed recently, prose-only.
- Recent sent messages per app (from AX snapshots, not the keystroke buffer).
- Skip entirely for secure fields, credential-labelled fields and secure-input mode.

## 7. Placement & rendering

1. `CaretResolver`: zero-length `AXBoundsForRange` → bounds of the char before caret →
   line bounds; web: text markers. Retry with short backoff while the app's AX lags;
   cache line height per app/field.
2. `FontFitter`: capture the caret line strip (Screen Recording permission); take the
   line's text from AX; for each candidate font (AX-reported font first, then system
   fonts, then bundled OFL fonts: Inter, Roboto, Open Sans, Source Sans/Code Pro, Lato,
   Nunito, JetBrains Mono) and sizes around the line height, render with CoreText,
   compare normalized ink profiles, compute RMSE. Best fit → font, size, baseline offset,
   ink colour (for ghost tint), dark-mode flag, confidence = 1 − RMSE. Cache; refit when
   the field or zoom changes. Debug mode dumps captured/rendered PNGs.
3. `GhostRenderer`: draw the ghost at the fitted baseline in the fitted font, tinted from
   the ink colour; wrap within the field width. If confidence is low or caret geometry
   is inconsistent → **TextMirror** (render the caret line + ghost as one overlay) → else
   anchored pill.
4. Per-app overrides: font-size scale, vertical offset, mirror on/off, minimum field
   size thresholds.

## 8. Interaction

Tab accepts one word (remainder protected until exhausted or typed over); a separate
key accepts all; type-through shrinks the ghost; Esc pauses briefly; clicks/focus changes
clear; secure-input detection shows a banner naming the culprit app; per-app and
per-domain enable/disable/timed pause; mid-line suggestions opt-in per app.

## 9. Personalisation

- Global + per-app custom instructions (prompt section).
- Opt-in writing recording per app/domain → encrypted SQLite; erase-all control.
- `SuffixIndex`: longest-match retrieval of the current tail in recorded writing; top
  continuation fed as context and as a mild logit bias.
- LoRA: load/unload `.gguf` adapters from a folder; training pipeline is a later,
  separate project.

## 10. Evaluation (build this first)

- `tabtype-eval` CLI (replaces GenCLI): replays (context, typed prefix, true
  continuation) cases through the full prompt + decoder pipeline.
- Data: opt-in export of the user's own recorded writing + a public chat/email corpus;
  cases sampled at every word boundary and mid-word.
- Metrics: next-word exact match, accepted chars per suggestion (simulated Tab), show
  rate at threshold, wrong-show rate, p50/p95 latency.
- Every phase must beat the previous build on this harness before merging.

## 11. Risks

- llama.cpp build must support Gemma 4 (SWA) and Qwen3; SWA models cannot shift KV —
  fall back to rebuild on front-trim.
- Base-model GGUFs for Gemma 4: verify availability and quant quality; keep instruct
  fallback path.
- Font fitting needs Screen Recording; must degrade gracefully without it.
- Custom decoder bugs are subtle: unit-test token healing against several tokenizers
  (SentencePiece and BPE) with fixtures.
- Binary size and memory: one model loaded at a time; idle unload.

---

## TODO

### Phase 0 — Foundations ✅
- [x] Create branch `v2-rewrite`; freeze v1 on `main`
- [x] Add llama.cpp XCFramework binaryTarget (b11490); embed + sign via `Scripts/build.sh`
- [x] Spike: load a GGUF, tokenize, decode, read logits from Swift (`tabtype-eval smoke`)
- [x] `tabtype-eval` CLI with JSONL case format, Tab-simulation metrics, reports
- [x] Seed eval set (32 entries → 192 cases); v1 baseline recorded via app `--eval` mode (see `eval/README.md`)
- [ ] Add a larger corpus: opt-in export of own writing + a public chat/email corpus

### Phase 1 — Inference runtime ✅
- [x] `LlamaRuntime` (`TokenModel`) + `InferenceEngine` actor on a dedicated serial queue: load/unload, Metal offload, cancellation by generation id (`GenerationGate`)
- [x] `VocabIndex`: piece bytes, blocked/EOG masks, first-byte buckets for constraint lookups
- [x] Batched multi-sequence decode on a unified KV cache (`fork`/`decode`/`drop`)
- [x] Prompt cache: LCP reuse + tail trim; opt-in splice (shift) for window slides on non-SWA models — approximate by design, so never used for changed context
- [x] Warm-up API, idle unload, memory-pressure unload (app wiring in Phase 6)
- [x] Tests: fake-model decoder suite + real-model integration (round-trips, cache reuse = fresh, splice, healing) over `models/*.gguf`

### Phase 2 — Decoder ✅
- [x] `HealSplit` + constrained steps (verified on SentencePiece/Gemma and BPE/Qwen)
- [x] Candidate expansion (top-k first tokens → parallel sequences, batched)
- [x] Word stop rules, probability-gated phrase extension, trailing-space prediction
- [x] Scoring (log-prob, duplicate merge) and confidence; `tabtype-eval sweep` for threshold tuning
- [x] Alternatives output for the word picker
- [x] ~~Synonyms via masked re-decode~~ — superseded: synonyms are ranked by P(word + following text | before) (Phase 6)
- [x] Tuned defaults on seed-v1 (Gemma 4 E2B): extension 0.3, ≤4 words, show ≥0.2 — re-tune per model in Phase 3

### Phase 3 — Models & prompting ✅ (kit-level; UI in Phase 6)
- [x] `ModelTemplate`: base, ChatML, ChatML no-think (Qwen3 hybrid), Gemma 2/3, Gemma 4 (`<|turn>`), Llama 3, Phi; detection for custom GGUFs (name first — base GGUFs embed chat templates too)
- [x] `PromptAssembler`: stable-first ordering, per-section budgets, reserved-marker stripping
- [x] Assistant-prefill path for instruct models; author-labelled continuation for base models
- [x] Catalog (`Sources/TabTypeKit/Catalog/models.json`, refreshed from `main`, cached, bundled fallback); RAM tiers; per-model tuned thresholds; GGUF name/quant parsing
- [x] Resumable, SHA-256-verified GGUF downloader; `ModelStore` with custom-models folder; memory/disk fit checks. Gemma 4 is Apache-2.0, so no Gemma-terms gate is needed (`requiresTermsNotice` stays for future models)
- [x] `RecommendationTracker` for the one-time "recommended model changed" notice (UI in Phase 6)
- [x] Eval: base beats instruct at equal noise on both families; 8 GB → Qwen3-1.7B base, 16 GB+ → Qwen3-4B base (see `eval/README.md`)
- [ ] Larger tier candidate (Qwen3-8B base) and a multilingual case set before trusting tiers for non-English writers

### Phase 4 — Context ✅ (core)
- [x] Measured: screen context is worth +13.5 pts recall overall, +18 pts in chats (Qwen3-4B base, seed-v1)
- [x] Field snapshot: one AX value read per keystroke; UTF-16-correct caret split (fixes drift after emoji); window title + field placeholder captured
- [x] Situation header ("App — window title — placeholder") for base models: +2.1 recall / +2.6 precision on Qwen3-4B (within noise, consistent direction); chat templates use it as "where I'm typing"
- [x] Page URL via the enclosing web area (Chromium), cached per focused element
- [x] Screen snapshots keyed by normalized window title, so a previous channel/thread never passes as the current conversation
- [x] `SecretSanitizer` (keys, tokens, JWTs, PEM, passwords, signed URLs, credentials in URLs, Luhn-valid cards, IBANs, random tokens) applied to prompt context, screen history, typing history, phrase memory and recent messages
- [x] Clipboard (opt-in, fresh, prose-only), recent sent messages from AX, credential/secure-field skip — already in place
- [x] Hidden-input editors (Monaco, CodeMirror 5): the hidden textarea's frame is the caret (v2.1)
- [ ] Web text-marker reading when AXValue is missing

### Phase 5 — Placement ✅ (core)
- [x] Bundled OFL fonts (Inter, Roboto, Open Sans, Source Sans 3, Source Code Pro, Lato, Nunito, JetBrains Mono) with licences, registered at launch
- [x] `FontFitter`: renders the line text in candidate fonts/sizes with CoreText and matches column/row ink profiles against the screenshot → family, size (¼ pt), baseline, ink/background colour, confidence. Coarse search at ~1 px/pt, family shortlist (+ system font), full-resolution decision. Tests recover Lato 15 pt, the system font on dark, Inter vs Roboto vs Open Sans, cropped lines; ~50 ms per fit
- [x] `FieldFitCache`: one fit per field (app + window + caret height + field frame), reused for every ghost and every Tab-remainder repaint; ≥0.8 confidence or fall back to the ink-band heuristic; verbose mode dumps captured strips to ~/Library/Logs/TabType/fit
- [x] Screen capture at the display's real pixel scale, excluding TabType's own windows, with the window list cached
- [x] Text mirror uses the fitted font/baseline/colours when available
- [x] Fixed: mirror backdrop/caret could linger under a later inline ghost
- [x] TabTypeKit is compiled with -O even in Debug (decoder + fitter are hot loops)
- [ ] Caret: AXBoundsForLine fallback, collapsed text-marker caret, line-height cache
- [x] Per-app font scale / vertical offset in the overrides UI
- [ ] Manual test matrix in real apps — done live (v2.1): TextEdit, Chrome, Safari, Terminal (agent prompt), Claude, Slack; still to do: Notes, Mail, Messages, VS Code chat, WhatsApp

### Phase 6a — v2 engine in the app (pulled forward) ✅
- [x] `LlamaEngine` plugs into the existing engine slot; v2 output bypasses v1's echo/assistant-speak/mid-word repair (exact insertion text); dictionary instant layer off for v2
- [x] Request carries app name, author name and raw custom instructions for the prompt assembler; warm-up/prewarm become cache prefills
- [x] `LlamaModelManager`: catalog refresh, selection, download with progress, load, delete, custom models, self-test on load
- [x] Settings ▸ Engine: v2 as the default ("Local model"), classic MLX kept as an option; one-time migration from v1
- [x] Only the selected engine's model loads; unload on quit (ggml exit rule); menu bar shows v2 status
- [x] Word picker uses the decoder's scored alternatives

### Phase 6 — Session & interaction ✅
- [x] `SuggestionSession` (TabTypeKit): the ghost lifecycle as a tested state model — type-through, Tab word-accept with protected remainder, stale/held/repeated results; `Engine` delegates all suggestion state to it (no scattered flags left)
- [x] Word split fixed: with "include trailing punctuation" off, "look? " now accepts "look" (punctuation used to slip through)
- [x] Accept word / accept all / type-through / remainder protection / Esc pause — via the session
- [x] Secure-input notice names the app holding it (kCGSSessionSecureInputPID)
- [x] Synonyms for a selected word: candidates from left context + asking the model directly, ranked by P(word + following text | before) — "the quick turnaround" → "fast"; picker replaces the selection
- [x] Word picker: "…" placeholder can no longer be inserted
- [x] Per-app ghost text size (80–120%) and vertical offset (±6 pt) in app overrides; applied to measured fonts too
- [x] Pause menu: "In ‹App› for 1 Hour"
- [x] Placement from live data (Claude desktop): strip clamped to the input field; caret bar excluded from scoring; when the app's font isn't available, measured size/baseline/colour are used with the system font (vertical confidence ≥ 0.8); real-strip replay test for offline tuning

### Phase 7 — Personalisation ✅
- [x] `SuffixIndex` (TabTypeKit): suffix array over the author's writing; longest-tail, case/whitespace-insensitive retrieval with support counts; mid-word aware; 4,000 messages index in ~30 ms
- [x] Decoder hint: the author's continuation joins the candidates, follows their phrasing with TRUE probabilities (honest confidence), wins ties via a log-space bonus, and extends along their phrase with a gentler bar; app lowers the show threshold for phrases used ≥2 times
- [x] Eval (repeat-writer synthetic corpus, leave-one-out): chars/case 2.15 → 2.42 (+13%), precision 60.5 → 65.1%, wrong-show 31.2 → 26.4%. Seed corpus (unrelated texts): neutral. Real gains depend on the user's own writing
- [x] `WritingStore`: encrypted (shared key file), secret-scrubbed, capped; records sent messages and field text on leaving a field; imports the old typing history once; per-app "Learn from my writing here"; erase in Settings
- [x] Global + per-app custom instructions reach the prompt (since Phase 6a)
- [x] LoRA "voice" adapters: load/clear on the running model (cache reset), mismatch errors surfaced, Settings picker + folder; verified with a real Qwen3-0.6B adapter
- [ ] Training adapters from recorded writing (separate project)

### Phase 8 — Cutover ✅
- [x] Remove MLX, swift-transformers, swift-jinja, Apple Intelligence engine (Package.swift has no remote dependencies)
- [x] Delete superseded v1 files (§2 "Deleted")
- [x] Settings migration from v1 keys (retired keys removed on launch)
- [x] Local latency telemetry + short/long accept stats in Statistics pane
- [x] README/COMPARISON update; `release.sh` now builds `CONFIG=Release` (Release build verified locally; versioning, DMG and tag left to the maintainer)

### Phase 9 — Cotypist parity pass (v2.1) ✅
Reconstructed from Cotypist's behaviour and app structure (no code or prompt text copied); each change measured on `tabtype-eval` or verified live.
- [x] Placement: AX font/colour (`AXFont` / `AXForegroundColor`), family-only fit when only the size is reported, capture squeeze + transparent-hole fixes, own ghost view, Cotypist's caret checks, single-line snap, visual line start, full-width wrapping, field notifications, no fade-in
- [x] Latency: no fixed settles (ready when the caret reaches its expected position), local field copy with timestamped keys, in-flight generation kept and spliced, lookahead for instant Tab chains, 30 s result cache, 0.25 s AX timeout
- [x] Decoder: 9-wide phrase beam from the best first word (exact pruning), extension bar 0.2, show bar 0.10 / 0.15 (boundary / mid-word); Cotypist's length steps 2 / 4 / 7 / 10
- [x] Context: OCR above the field (≤800pt, column ±70pt), capture on pause, wait for a chat's first capture, context held steady per message, AX transcript as fallback
- [x] Keyboard: listen-only tap; Tab / accept-all / Esc as hotkeys only while a suggestion is up; Chromium same-field focus echo ignored
- [x] Gating: typo check on the current word only, minimum field size, terminals only inside AI-agent prompts
- [x] Text mirror preview (per app); settings pruned (timing, battery, context size, crop mode, mirroring, voice adapter, Tab-inserts-all)
- [x] Prompt sections with token budgets — built, measured worse with our own delimiters, kept off (`--sections`)
- [x] Personalization strength, record-only-with-accepts, On battery power, caret retry plan + line-height cache, hotkey-conflict notice
- [x] Insertion workarounds + grey colour, alternatives/synonyms after a pause, emoji gender/neutral, in-app updates from GitHub Releases (verified), sync between Macs via iCloud Drive (E2E, passphrase)
- [ ] Not possible without a paid Apple Developer ID: notarization (CloudKit sync / Sparkle replaced as above)
