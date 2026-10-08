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

### Phase 1 — Inference runtime
- [ ] `LlamaRuntime` actor: load/unload, context params, Metal offload, cancellation by generation id
- [ ] `VocabIndex`: piece text table, leading-space flags, control-token mask, prefix trie
- [ ] Batched multi-sequence decode API (`seq_cp`, `seq_rm`, `seq_keep`)
- [ ] `PromptCache`: LCP reuse, tail trim, front shift (non-SWA) / rebuild (SWA)
- [ ] Warm-up of template head; idle unload; memory-pressure handling
- [ ] Unit tests: tokenization round-trips, cache reuse correctness (logits equal with/without cache)

### Phase 2 — Decoder
- [ ] `TokenHealing`: boundary split + per-step allowed-token masks (tests for SPM + BPE vocabularies)
- [ ] Candidate expansion (top-k first tokens → parallel sequences)
- [ ] Stop rules for short (word) and long (phrase) modes; trailing-space prediction
- [ ] Scoring (total/avg logprob, duplicate merge) and confidence gate
- [ ] Alternatives output for word picker; synonyms via masked re-decode
- [ ] Tune thresholds per model on eval set; commit tuned defaults

### Phase 3 — Models & prompting
- [ ] `ModelTemplate` for base, ChatML/Qwen3 (thinking off), Gemma, Llama 3, Phi
- [ ] `PromptAssembler` with stable-first ordering + per-section budgets
- [ ] Assistant-prefill path for instruct models; raw-continuation path for base models
- [ ] `catalog/models.json` (hosted in repo) + bundled fallback; RAM tiers; quant parsing
- [ ] GGUF downloader + custom models folder; memory/disk warnings; Gemma terms notice
- [ ] "Recommended model update" notice when catalog recommendation changes
- [ ] Eval: base vs instruct per model family; pick defaults per RAM tier

### Phase 4 — Context
- [ ] `FieldSnapshot` (AX + text markers + hidden-input editor detection)
- [ ] `EnvironmentContext`: scoped Vision OCR, idle-only capture, content-hash keys
- [ ] Clipboard (opt-in, fresh, prose-only); recent sent messages from AX
- [ ] `SecretSanitizer` with fixture tests for each secret class
- [ ] Credential/secure-field/secure-input skip

### Phase 5 — Placement
- [ ] `CaretResolver` with retry plan + `LineHeightCache`
- [ ] Bundle OFL fonts (Inter, Roboto, Open Sans, Source Sans 3, Source Code Pro, Lato, Nunito, JetBrains Mono) with licences
- [ ] `FontFitter` (CoreText render, profile RMSE, colour + dark-mode, confidence, cache, debug PNG dump)
- [ ] `GhostRenderer` inline mode with wrapping
- [ ] `TextMirror` overlay mode
- [ ] Anchored pill fallback; per-app font scale / vertical offset / size thresholds
- [ ] Manual test matrix: TextEdit, Notes, Mail, Messages, Slack, Claude desktop, Safari/Chrome (Gmail, Docs), VS Code, Terminal

### Phase 6 — Session & interaction
- [ ] `InputSession` state machine replacing `Engine.swift`
- [ ] Accept word / accept all / type-through / remainder protection / Esc pause
- [ ] Secure-input detection banner (culprit app)
- [ ] Per-app and per-domain overrides UI; timed disable from menu bar
- [ ] Word picker + synonyms UI

### Phase 7 — Personalisation
- [ ] Encrypted `WritingStore` (per-app/domain opt-in, erase)
- [ ] `SuffixIndex` retrieval + logit bias; measure on eval set
- [ ] Global + per-app custom instructions in prompt
- [ ] LoRA adapter loading UI

### Phase 8 — Cutover
- [ ] Remove MLX, swift-transformers, swift-jinja, Apple Intelligence engine
- [ ] Delete superseded v1 files (§2 "Deleted")
- [ ] Settings migration from v1 keys
- [ ] Local latency telemetry + short/long accept stats in Statistics pane
- [ ] README/COMPARISON update; release build via `Scripts/release.sh`
