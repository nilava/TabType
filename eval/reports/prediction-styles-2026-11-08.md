# Prediction styles: locked synthetic comparison

The profiles were defined before the holdout was evaluated. Balanced preserves the existing app gates and stays the default. No model weights or model download changed. The new Careful and Frequent choices adjust first-word confidence gates and contiguous phrase length; they are preferences, not calibrated correctness probabilities.

## Configuration

- Qwen3-4B-Base.i1-Q4_K_M, llama.cpp b11490, base template, situation header, fictional author Taylor Chen, maximum 4 words, no learned history or synthetic capture noise.
- Seed: 32 documents / 192 cases. Holdout: 24 independently authored fictional documents / 144 cases. Multiple prefixes per document are correlated. Predominantly English; no multilingual or competitor certification.
- A raw run records all word scores with `--extend 0 --threshold 0`; `profiles --threshold 0.2` applies the same shared gates and trimming as the app. Replay latency is the original inference timing, not a new timing sample per style.

| Style | Boundary factor | Midword factor | Extension threshold |
| --- | ---: | ---: | ---: |
| Careful | 1.0 | 0.5 | 0.15 |
| Balanced | 0.75 | 0.4 | 0.05 |
| Frequent | 0.5 | 0.25 | 0.025 |

Factors multiply the catalog base threshold (0.2 here). Repeated learned phrases retain the existing strength-dependent discount; this no-history comparison does not measure that effect.

## Results

| Set | Style | Correct first chunk / cases | Correct / shown | Wrong shown / cases | Saved chars / case | Wrong words / case |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| seed | careful | 111/192 (57.8%) | 111/156 (71.2%) | 45/192 (23.4%) | 3.422 | 1.042 |
| seed | balanced | 113/192 (58.9%) | 113/168 (67.3%) | 55/192 (28.6%) | 3.583 | 1.630 |
| seed | frequent | 114/192 (59.4%) | 114/177 (64.4%) | 63/192 (32.8%) | 3.589 | 1.786 |
| holdout | careful | 70/144 (48.6%) | 70/115 (60.9%) | 45/144 (31.2%) | 2.646 | 1.167 |
| holdout | balanced | 72/144 (50.0%) | 72/127 (56.7%) | 55/144 (38.2%) | 2.722 | 1.764 |
| holdout | frequent | 72/144 (50.0%) | 72/134 (53.7%) | 62/144 (43.1%) | 2.722 | 1.924 |

Careful reduces exact-match wrong shows on this holdout by 6.94 percentage points (55 to 45 of 144 opportunities), while accepted characters decrease by 2.8% (392 to 381). Frequent adds seven wrong shows and no accepted characters versus Balanced on the holdout. This does not justify making Frequent the default. Valid alternative continuations count as misses; these numbers do not predict an individual user's experience.

Original raw inference p50/p95: seed 177/257 ms, holdout 163/248 ms. The synthetic fixture is not an end-to-end keyboard, battery, memory-pressure or long-session test.

## Regressions and provenance

- A separate native Careful run matched all 144 replayed holdout suggestions exactly (native p50/p95 167/252 ms).
- All 192 original baseline phrases match the new raw scores replayed with extension threshold 0.05 and no show gate. This checks the shared trimming refactor, not independent live-app acceptance.
- Separate PR #16 retrieval regressions verify dominant repeated full continuations and caret-anchored UTF-8-safe matching for long inputs. Scope tests verify app-specific ambiguity, no unknown-app fallback, per-app reuse denial and erase/rebuild revocation.
- Raw evidence and per-style summaries are kept locally with checksums. They contain only public/synthetic inputs. The following hashes identify the locked corpus/cases:

- `eval/cases/seed-v1.jsonl`: `1c653978c2e512313b4525dbc6df858ea9a0d8eab84ebc1d513e9adf7b0f1cc5`
- `eval/corpus/quality-holdout-v1.jsonl`: `9f674b719a935e90925fec662e6e9570e7662ebaef8069c765e8c872f0a1b968`
- `eval/cases/quality-holdout-v1.jsonl`: `63a96c0a9543980859a11e5007b1b50eab39c8d26bd1d137d8832f0edee1fd00`
- Model: `ff17d19ad5f8c7ddc205d1b8c6fadc360449f06a499440dce8c81db6302f19ac`.

Real keyboard acceptance and macOS permission refresh remain deferred until the owner returns to the Mac. No Cotypist parity or contact-specific learning claim is made.

## Learned-history scope check

The existing 24-document / 144-case fictional repeat-writer corpus was also run
with Balanced, excluding each case's entire source document. This app only saved
374 characters (75 correct first chunks; 121 suggestions shown), versus All apps
at 382 characters (76 correct; 121 shown). Current-app p50/p95 was 155/254 ms;
shared scope was 175/282 ms in separate runs. These are small non-randomized
measurements, not evidence of a speed or accuracy advantage for either scope.
The stricter default is a context-isolation choice. Neither scope identifies
contacts or individual browser sites. This run used the integrated fork including
the retrieval correction contributed separately in PR #16.
