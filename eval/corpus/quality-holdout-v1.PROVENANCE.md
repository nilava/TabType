# Quality holdout v1

These 24 entries were newly authored with AI assistance on 2026-11-08 as synthetic evaluation material. People, conversations and situations are fictional. No private writing, clipboard contents, messages, application captures or user logs were imported.

The corpus covers personal and work chat, email, documents, notes, code comments, an issue, a review and a social update. It includes punctuation, line breaks and a few non-ASCII names/words, but is predominantly English and is not a multilingual certification.

Generate the frozen cases once with `tabtype-eval make-cases eval/corpus/quality-holdout-v1.jsonl --out eval/cases/quality-holdout-v1.jsonl --seed 1729`. Record their SHA-256 before tuning. Select parameters on the existing seed set, then use this holdout for the locked candidate comparison. Do not regenerate cases to improve reported results.

Several prefixes come from each entry and are correlated. Exact author-continuation matching treats valid alternatives as misses; results on this small synthetic set do not establish real-world accuracy or parity with another product.
