# Prediction preferences and reproducible replay

`run --style careful|balanced|frequent` uses the live app's boundary/midword gate
and phrase-extension policy. Without `--style`, the legacy fixed gate remains
available for old comparisons. To compare all styles on one identical search:

```bash
.build/release/tabtype-eval run --model <file.gguf> --cases eval/cases/quality-holdout-v1.jsonl \
    --template base --header --author 'Taylor Chen' --max-words 4 --extend 0 --threshold 0 --out raw.json
.build/release/tabtype-eval profiles raw.json --threshold 0.2 --out profiles
```

Replay requires a new run recorded with `--extend 0`; it rejects legacy/truncated
word records. Latencies stay the original measurements. Run metadata records
model, case-file and executable hashes, effective decoder settings and prompting
options. Record the source commit alongside that output.

`--history corpus.jsonl` is leave-one-document-out and must be the source corpus
from which the cases were generated. A mismatch is rejected. `--history-scope
currentApp` restricts hints to the case's app label; `allApps` is the legacy CLI
default. The app defaults to This app only. App labels in synthetic corpora stand
in for bundle IDs; they do not identify people or browser sites.

See [the locked synthetic comparison](reports/prediction-styles-2026-11-08.md)
and [holdout provenance](corpus/quality-holdout-v1.PROVENANCE.md). Keep the
holdout frozen; future tuning needs a new independent holdout.
