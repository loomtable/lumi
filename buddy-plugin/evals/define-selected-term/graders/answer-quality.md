---
type: llm
weight: 2
---
The reply is a single fenced `buddy` JSON block, with no text before it. Pass only if all hold:
- `say` is the first key and its first sentence has at most 15 words.
- `say` explains quantitative tightening correctly (a central bank shrinking its balance sheet, e.g. by letting bonds mature without reinvesting).
- `shape` is `chip`.
- `handoff` is null.
- `card_html`, if present, does not repeat the words of `say`.
