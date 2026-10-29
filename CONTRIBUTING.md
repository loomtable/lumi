# Contributing to Lumi

Every recipe, translation and fix makes the moment better for the next person who taps the Lumi key: the answer on their screen, with a ring on the exact spot.

| Path | Good for | Time |
| --- | --- | --- |
| [Recipes](#recipes) | Anyone who does real work on a Mac: founders, designers, analysts, writers, students, operators, developers and everyone in between | 20 to 40 minutes |
| [Translations](#translations) | Native speakers | 1 to 2 hours |
| [Code and docs](#code-and-docs) | Swift developers and docs writers | One evening for a good first issue |

- **Questions and ideas:** [Discussions](https://github.com/loomtable/lumi/discussions), or hello@loomtable.com.
- **Bugs:** open an [issue](https://github.com/loomtable/lumi/issues/new/choose) with your macOS, Lumi and Claude Code versions and the steps to reproduce it.
- **Security problems:** email security@loomtable.com instead; see [SECURITY.md](SECURITY.md).

Everyone here follows the [code of conduct](CODE_OF_CONDUCT.md).

## What every change keeps true

These are product facts. A pull request that breaks one doesn't merge.

- Lumi looks at the screen only when the key is pressed, and skips password managers and apps the person blocks.
- Changes Lumi proposes wait for the person's OK. Insert puts text into the field the person is writing in and never sends it. Lumi never sends an email or message for anyone.
- No servers of ours, no account, no analytics. No change adds them.
- Speech-to-text and the default voice run on the Mac, and the voice recording never leaves it. Screenshots stay on the Mac for 24 hours at most.
- Lumi uses only the tools the person has connected. Write "the tools you've connected", never "any tool".
- Cards stay short: at most 5 bullets, a table of up to 5 rows, one labelled diagram, or a set of images.
- Lumi needs macOS 26 on Apple Silicon. Don't add claims or code paths for Intel, Windows, Linux, older macOS or offline use.

Anything you share (recipes, screenshots, test files) uses fictional names and `.example` domains: no real people, companies, client files or credentials.

## Recipes

A recipe is one spoken ask for one real moment: what you say, the tools it assumes, an optional CLAUDE.md snippet, and the answer you get. See [recipes/](recipes/).

1. Copy [`recipes/recipe-template.md`](recipes/recipe-template.md) to `recipes/<profession>/<short-name>.md`.
2. Run it on your Mac and fill in the tested-on line (Lumi version, macOS version, date). If you couldn't run it, mark it `untested`.
3. Name only the tools you connected and used.
4. Open a pull request. Not ready for one? Post it under Recipes in Discussions and we'll help shape it.

## Translations

Translations live in [`docs/i18n/`](docs/i18n/), one file per language: `README.<language-code>.md`. The language row at the top of the README links them all. Want another language? Suggest it under Ideas in Discussions.

1. Comment on the issue for your language so nobody duplicates the work.
2. Translate the meaning, not the words, in the register people in that language actually read.
3. Keep these exact: `Lumi by Loomtable` on first mention, right Option, macOS 26, Apple Silicon, 2.1.312, and every link.
4. Keep the claims as written in English: when Lumi looks, what stays on the Mac, what goes to Anthropic, and the Open Anyway step. Don't soften them or add to them.
5. Use the labels your own System Settings shows, and leave an HTML comment (`<!-- confirm: … -->`) on any you're unsure of.
6. Add the language to the row at the top of `README.md` and of every file in `docs/i18n/`.

Every translation is read by a second native speaker before it merges.

## Code and docs

### Find something to work on

- Issues labelled [`good first issue`](https://github.com/loomtable/lumi/labels/good%20first%20issue) fit one evening. Each lists the files to touch and what done looks like.
- Comment "I'll take this" before you start, so work isn't duplicated.
- For your own idea, start a Discussion under Ideas first, so we can agree on scope before you write code.

### Build from source

You need a Mac on macOS 26 with Apple Silicon, Xcode 27 (Swift 6.4) or its command-line tools, and Claude Code 2.1.312 or newer, installed and signed in. Questions you ask while testing count against your own Claude plan or API usage.

```sh
git clone https://github.com/loomtable/lumi.git && cd lumi
Scripts/make-dev-cert.sh   # once: a stable signing identity, so permission grants survive rebuilds
Scripts/build-app.sh       # build, sign and install /Applications/Lumi.app
open -a Lumi
```

`make-dev-cert.sh` asks for your login password once, to trust the certificate for code signing. The first build may ask whether codesign can use the "Lumi Dev" key: choose Always Allow. `INSTALL=0 Scripts/build-app.sh` builds `dist/Lumi.app` without installing it. Run the tests with `Scripts/test.sh`.

`build-app.sh` signs with the first identity it finds: `SIGN_IDENTITY`, then "Loomtable Release", then "Lumi Dev", then ad-hoc. It prints the one it used. On a Mac that has the release certificate, dev builds and releases share one designated requirement, so permission grants carry over between them. Without it, your builds use "Lumi Dev" or ad-hoc. That's fine: the grants are only on your Mac and belong to your builds.

The app icon needs Xcode (for `actool`). Without Xcode, the build uses the generic icon.

Always open Lumi from Applications, Spotlight or Finder, never from a terminal. A copy started from a terminal borrows the terminal's permissions.

### Repository layout

| Path | What |
| --- | --- |
| `Sources/BuddyCore` | Shared value types: context packet, answer block, sessions, modes and models, feature switches |
| `Sources/BuddyKeys` | Lumi key gestures, the Tab switcher keys, the dictation key, scoped Esc handling, chords |
| `Sources/BuddyContext` | Builds the context packet from the front app |
| `Sources/BuddyAct` | Inserts text into your app |
| `Sources/BuddyVoice` | Mic, speech-to-text, text-to-speech, meters, sounds |
| `Sources/BuddyOverlay` | Pill, chip, card, capsules, the Panel, the switcher strip, placement, motion, themes |
| `Sources/BuddyBridge` | Runs your Claude Code (Quick, Deep and the session pool) and parses its stream |
| `Sources/BuddyConversations` | Session index and routing, attention rules, Claude Code session files |
| `Sources/BuddyTrace` | The optional trace log |
| `Sources/BuddyApp` | The coordinator that runs each question, session delivery and the app runtime |
| `Sources/BuddyCompanion` | The Lumi window (sessions, Home, Settings), onboarding |
| `Sources/Lumi` | Menu-bar app shell |
| `buddy-plugin/` | The Claude Code plugin that does the thinking; it ships inside the app |
| `App/` | Info.plist, entitlements and the app icon (Icon Composer) |
| `Scripts/` | Build, test and signing scripts |
| `Scenarios/`, `Tools/` | Answer scenarios and the tools that check them |
| `recipes/` | Spoken asks that work, by profession |
| `docs/` | Manual release checks ([QA_CHECKLIST.md](docs/QA_CHECKLIST.md)), translations, repository settings and good-first-issue drafts |

### Pull requests

1. Keep each pull request to one change: a bug fix, one context reader, one wording fix or one doc page. Large or cross-cutting changes start as a Discussion.
2. Say what it changes and how you checked it on a Mac. Add a test or an answer scenario in `Scenarios/` when behaviour changes.
3. Run `Scripts/test.sh` before you open it. Warnings are errors, so the build must be clean.
4. Follow the style of the code around your change.
5. Add a screenshot or a short recording when the change is visible, with anything private cropped or blurred.

**AI-assisted pull requests are welcome; you still own them.** You built and ran the change yourself, you explain it in your own words and answer review questions yourself, you note that AI tools helped, and the change stays in scope: no sweeping rewrites, unrelated reformatting, or invented files or APIs.

We reply to every pull request, and say why when we ask for changes or decline one.

## Credit

Merged authors are named by GitHub handle in the release notes for the release that ships their change. Recipe authors keep their handle in the recipe; translators and native reviewers are credited in the release notes too. If you'd rather not be named, say so in the pull request.

## License

Lumi is licensed under GPL-3.0-or-later. By opening a pull request, you agree that your contribution is licensed under GPL-3.0-or-later, like the rest of Lumi, and that you wrote it or have the right to share it under those terms.
