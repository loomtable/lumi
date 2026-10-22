---
name: find-context
description: Finds the project, files and recent work behind what is on the user's screen, starting from a Lumi <buddy-packet>. Use in Deep answers before reading code.
---

# Finding context for a Lumi question

Start from the packet, then widen only as needed:

1. `local_server.cwd`, `editor.workspace`, `terminal.cwd` and `window.document` name the project and file. Prefer them over guessing.
2. What the user and Claude Code were just doing: the newest `~/.claude/projects/<encoded cwd>/*.jsonl` for that folder. The encoded name is the absolute path with every non-alphanumeric character replaced by `-`. List the directory to find it; don't construct the name for long paths.
3. `git status --short` and `git log --oneline -5` in the project.
4. The page itself: the user's browser tools (Playwright, Claude in Chrome) if they are connected.

Read the smallest thing that answers the question. Report each step briefly; the app shows your tool calls as status lines.
