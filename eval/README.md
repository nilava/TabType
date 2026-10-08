# Suggestion quality harness

Every change to the suggestion pipeline is measured here before it merges.

```
eval/corpus/   source writing (JSONL: category, app, context, text)
eval/cases/    generated cases (prefix + what the author really typed next)
eval/results/  run outputs (per-case suggestions + summary)
```

## Workflow

```bash
./Scripts/build.sh eval                                   # builds .build/release/tabtype-eval
.build/release/tabtype-eval make-cases eval/corpus/seed.jsonl --out eval/cases/seed-v1.jsonl

# v2 (llama.cpp) backend
.build/release/tabtype-eval run --model <file.gguf> --cases eval/cases/seed-v1.jsonl \
    --baseline eval/results/phase0-v1-mlx-qwen3-4b.json

# v1 (MLX) baseline — runs the real app pipeline headlessly
./Scripts/build.sh app
dist/TabType.app/Contents/MacOS/TabType --eval eval/cases/seed-v1.jsonl --out eval/results/v1.json

.build/release/tabtype-eval report <run.json> --baseline <other.json>
```

Keep `seed-v1.jsonl` frozen so numbers stay comparable; add new case sets under a new
name instead of regenerating it. Add your own writing as extra corpus files (keep
private text out of git).

## Metrics

Each suggestion is scored by simulating Tab presses word by word against what the
author actually typed, stopping at the first chunk that differs.

| Metric | Meaning |
|---|---|
| accepted chars / case | Characters saved per suggestion opportunity — the headline number |
| next-word recall | Cases where the first accepted chunk was right |
| precision | Of suggestions shown, how many had a right first chunk |
| wrong-show rate | Cases where a wrong suggestion was shown (noise the user sees) |
| latency p50/p95 | Wall time per suggestion |

Tune the show threshold from one ungated decoder run:

```bash
.build/release/tabtype-eval run --model <file.gguf> --cases eval/cases/seed-v1.jsonl --out ungated.json
.build/release/tabtype-eval sweep ungated.json
```

## Phase 3 — model and prompt selection (seed-v1, 192 cases)

Each model runs the v2 decoder with its catalog prompt template. The show threshold
is tuned per model: the highest accepted chars/case with wrong-shows ≤ 25% of cases.

| Model | Size | Prompt | Threshold | Recall | Precision | Wrong-show | Chars/case | p50 |
|---|---|---|---|---|---|---|---|---|
| **Qwen3-4B base** | 2.5 GB | base | 0.20 | **56.2%** | 70.6% | 23.4% | **3.49** | 104 ms |
| **Qwen3-1.7B base** | 1.1 GB | base | 0.20 | 52.1% | 69.4% | 22.9% | 3.07 | 44 ms |
| Gemma 4 E2B base | 3.4 GB | base | 0.20 | 50.0% | 67.1% | 24.5% | 2.93 | 76 ms |
| Gemma 4 E4B base | 5.3 GB | base | 0.25 | 47.4% | 74.0% | 16.7% | 2.86 | 117 ms |
| Qwen3-4B Instruct 2507 | 2.5 GB | chat (prefill) | 0.60 | 44.8% | 64.2% | 25.0% | 3.22 | 124 ms |
| Gemma 4 E2B Instruct | 3.4 GB | chat (prefill) | 0.75 | 43.8% | 64.1% | 24.5% | 3.02 | 82 ms |
| Qwen3-0.6B base | 0.4 GB | base | 0.25 | 38.0% | 62.4% | 22.9% | 1.95 | 23 ms |
| *v1 (MLX, Qwen3-4B Instruct)* | 2.3 GB | v1 | — | 37.0% | 37.8% | 60.9% | 2.19 | 296 ms |

Findings:
- **Base models win.** Instruct models are overconfident (peaky probabilities), so at
  equal noise they must be gated much harder and lose ~10 points of recall. They stay
  in the catalog for people who want instruction-following, with their own thresholds.
- The author-labelled base prompt (`Name: reply` under the conversation) beat the
  Phase 2 generic prompt by 1–2 points on every model (within noise on this set).
- Bigger is not automatically better: Gemma 4 E4B trails Qwen3-4B here. The set is
  English-only, so multilingual strengths are untested.
- Recommendations: 8 GB → Qwen3-1.7B base; 16 GB+ → Qwen3-4B base.

## Results (seed-v1, 192 cases)

| | v1 MLX · Qwen3-4B-Instruct | v2 decoder · Gemma 4 E2B base | v2 decoder · Qwen3-0.6B base |
|---|---|---|---|
| accepted chars / case | 2.19 | **2.79** | 2.04 |
| next-word recall | 37.0% | **48.4%** | 39.6% |
| boundary recall | 32.8% | 39.1% | 23.4% |
| mid-word recall | 45.3% | 67.2% | **71.9%** |
| precision | 37.8% | **66.0%** | 58.0% |
| wrong-show rate | 60.9% | **25.0%** | 28.6% |
| latency p50 | 296 ms | 73 ms | **21 ms** |

v2 numbers use the default decoder (4 candidates, extension 0.3, ≤4 words) and
show threshold 0.2. Ungated, Gemma 4 E2B reaches 53.6% recall / 3.13 chars per case.

## Phase 0 baseline (seed-v1, 192 cases)

| | v1 MLX · Qwen3-4B-Instruct 4-bit | llama.cpp greedy spike · Gemma 4 E2B base Q4_K_M |
|---|---|---|
| accepted chars / case | 2.19 | 1.72 |
| next-word recall | 37.0% | 28.1% |
| boundary recall | 32.8% | **39.1%** |
| mid-word recall | 45.3% | 6.2% (no token healing yet) |
| precision | 37.8% | 29.7% |
| wrong-show rate | 60.9% | 66.7% (no confidence gate yet) |
| latency p50 / p95 | 296 / 478 ms | **83 / 129 ms** |
