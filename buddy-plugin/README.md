# buddy plugin

The Claude Code plugin behind Lumi's Quick, Deep and Research lanes. The app copies it to
`~/Library/Application Support/com.loomtable.lumi/plugin` and passes `--plugin-dir` to each of those `claude` processes.
Open sessions (typed turns, and Quick's hand-offs within a session) are the user's own Claude Code and don't load the plugin:
on voice turns only, Lumi sends `buddy-answer`'s rules plus `open.md` inside a `<lumi-voice>` envelope.

| Part | Role |
| --- | --- |
| `skills/buddy-answer` | How to answer: the `buddy` block (`say` first), shapes, voice, card HTML, handoff. `open.md` adds the rules for voice turns in an open session. |
| `skills/find-context` | Deep: packet → project, files, recent session, git, browser. |
| `agents/buddy-quick.md` | Quick lane main agent (Haiku, low effort, Read/Glob/Grep only). |
| `agents/buddy-deep.md`, `buddy-research.md` | Deep and Research lanes (Opus; high and max effort). |
| `evals/` | One hand-written `claude plugin eval` case. The 140 scenarios in `Scenarios/cases` are generated into eval cases outside the repo by `Tools/scenarios/run_eval.sh`. |

**How Quick loads the rules (measured).** Quick runs as `--agent buddy:buddy-quick` with
`--append-system-prompt-file skills/buddy-answer/SKILL.md`. The agent body replaces Claude Code's
default system prompt (a small, cacheable prompt), and the appended file puts the rules in context with
no tool call. Two alternatives measured worse: an agent `skills:` preload does not load for a
main-session `--agent` (the answer format broke), and leaving the model to invoke the skill costs a
round trip and it was never invoked.

Check: `claude plugin validate --strict buddy-plugin`. Evals cost real model calls:
`claude plugin eval buddy-plugin --model claude-haiku-5-5`.
