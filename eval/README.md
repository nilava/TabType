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
