# Writing Lumi scenarios

The scenario library is what `buddy-answer` is evaluated against. Each scenario is one
moment: a synthetic screen, the context packet the engine would build, the question, and what a
good answer must do. Target: 120+ scenarios, all 17 answer types across 8 apps, about 50 on routing.

## Layout

```
Scenarios/cases/<app>-<slug>/
  scenario.json   the packet, question and expectations
  screen.html     the screen, rendered to a 1280×800 screenshot
```

`browser-define-term` is the worked example. Validate with
`python3 -I Tools/scenarios/validate.py` and render one screen with
`npx -y playwright@1.64.0 screenshot --viewport-size "1280,800" file://$PWD/Scenarios/cases/<id>/screen.html /tmp/x.png`
(add `--color-scheme dark` for dark-appearance scenarios).

## scenario.json

| Field | Meaning |
| --- | --- |
| `id` | Folder name, `<app>-<slug>`, kebab-case. |
| `app` | `browser`, `chat`, `video`, `spreadsheet`, `pdf`, `editor`, `terminal`, `finder`. |
| `type` | One of the 17 answer types below. |
| `routing` | `true` when the point of the scenario is the lane decision. |
| `question` | What the user said, as speech-to-text gives it: lower case, no trailing punctuation fuss, sometimes a small slip. |
| `packet` | The context packet. Same keys as `ContextPacket`. `utterance` equals `question`. Leave out `screenshot`. |
| `expected.lane` | `quick`, `deep` or `research`. |
| `expected.shape` | `chip`, `card` or `rich` (required for quick). |
| `expected.facts` | 1–4 short statements a correct answer must convey, checkable against the screen. For deep/research, what Quick's hand-off line should be about. |
| `expected.must_not` | Optional: things a good answer must not do. |
| `notes` | Optional: why this case exists. |

Packet fields per app kind: browser `url, host, tab_title` and `local_server {port, pid, cwd, command}` for localhost; editor `editor {workspace, file}` and `window.document`; terminal `terminal {cwd, command}`; chat `chat {channel, thread}`; document (PDF, spreadsheet) `window.document`; finder `finder {folder, selected}`. Add `selection {text, length, truncated}` when something is selected, `cursor {x, y, element {role, label}}` when it matters, `recent` for recent apps, and `conversation {id, turn, previous}` (previous: up to 3 earlier turns as text, for follow-ups). `display {id, scale, appearance}`. `screenshot_unavailable` (`not_granted` or `capture_failed`) when the capture failed: the case then gets no screenshot, as in the product. `editable {field, selection}` when the focused element is a text field the user can type into (absent otherwise). `features {rings, insert}` when the user turned rings or Insert & Replace off in Settings (absent when both are on). On a follow-up the bridge leaves out what the session already has: `unchanged` lists omitted fields (same as last time), and `screenshot_unchanged_since_turn: N` replaces the image when the screen hasn't changed since turn N's screenshot. `screenshot_detail {x, y, width, height}` places a second image, a full-resolution close-up around the selected text, when one was attached.

## Answer types and the expected form

| type | spoken | shape |
| --- | --- | --- |
| define | the meaning, one line | chip |
| summarise | the bottom line | card |
| catch-up | where things stand | card |
| rewrite | what changed | card (with insert) |
| translate | the first line | card |
| compare | which fits and why | rich |
| how-to | "three steps" | chip |
| diagram | the gist | rich |
| annotate | "I've marked three" | card |
| video-moment | what's happening | card |
| compute | the result | chip |
| draft-reply | what it says | card (with insert) |
| find-images | "six options" | card (usually deep: needs the web) |
| research | "On it…" | lane research |
| explain-code | the cause in one line | card |
| approval | what it will do | rich |
| cant-do | why, one line | chip |

## Routing (about 6 of 15 cases)

Quick answers when the screen and packet are enough. Deep when the answer needs files, a repo,
commands, the web, a browser session, or careful multi-step work. Research only for explicit
research or report requests. Write a mix:
- clear deep cases (localhost bug → the repo; "fix this failing test"; "what changed in this branch");
- hard negatives that look technical but are answerable from what is visible (quick);
- overrides: "quick answer …" (quick even if deep would be better), "go deep …" / "think hard …" (deep);
- research requests ("research …", "write me a report on …").

## Content rules

- Fictional but realistic: invented people, companies, products, channels, repos. Domains only
  `example.com`, `example.org`, `example-*.com`, or `localhost`. Paths under `/Users/me/…`.
- No real people's private data, no real company internals, no data from the maintainers' own Macs.
- `screen.html` is self-contained: inline CSS only, no scripts, no external images or fonts (use
  CSS shapes, emoji or inline SVG for images and charts). Make it look like the app (Slack-like
  chat, VS Code-like editor, Terminal, Numbers/Excel-like grid, Preview-like PDF page, YouTube-like
  player with a frame drawn in SVG and a timestamp, Finder window). 1280×800, `margin: 0`.
- Facts in `expected.facts` must be visible on the screen or in the packet. Don't expect anything
  the model would have to guess.
- The screen must contain what the question refers to (the selection highlighted, the error shown,
  the cell visible).

## Running evals

Every eval run spends your Claude plan, so check the cost ceiling before each one. Run them only through the wrapper:

```sh
Tools/scenarios/run_eval.sh <scratch dir outside the repo> <max cost USD> [runs per case]
```

It validates the library, renders the screens, generates the cases into `<scratch>/plugin` (the
generator refuses any path inside the repo), runs `claude plugin eval` with `--trust-plugin
--ablation none --keep-temp` and the cost ceiling, then prints the quality bars and checks every card
in light and dark. A 1 × 120 run cost about $0.55 on Haiku 5.5 (Oct 2026); set the ceiling a
little above the estimate and report the actual spend.

What is graded where:
- In the case (plugin eval): a valid `buddy` block (regex), the key facts and no duplicated
  narration (Haiku judge, 3 votes).
- In `summarize.py`, in code from the parsed block: lane, shape and the ≤15-word headline. They
  count only when the block is valid.
- In `render.cjs cards`: overflow and contrast in both themes, with JavaScript off.

Questions that start with "research", "go deep", "think hard" or "go deeper" never reach Quick
(the app's Router), so they don't become Quick cases; "quick answer" cases get
`<handoff>off</handoff>`. `buddy_rules.py` mirrors the Router.
