# Lumi recipes

An analyst has a dashboard open. Tuesday's sign-ups dipped, and the weekly review starts in eight minutes. One tap on right Option: "Why did sign-ups drop on Tuesday?" Lumi reads the CSV in Downloads, runs the breakdown, checks the notes in the connected Drive, and rings the dip on the chart with a three-row table beside it.

That ask, the tools it used and the shape of the answer make up a recipe. This folder collects them by profession: founders, product managers, designers, researchers, analysts, marketers, sales, writers, students, consultants, operators and developers.

## What a recipe is

Each recipe is one Markdown file with four parts:

1. **The spoken ask:** the exact words you say after tapping right Option, or type after a double-tap.
2. **The tools it assumes:** named tools from the tools you've connected, such as Slack, Notion, Linear or Drive. Many recipes need none, because Lumi already sees your screen, finds your files and works on your Mac.
3. **A CLAUDE.md snippet (optional):** a few lines you can add to your own setup to shape the answer, for example "name the source file and cell". Remove them at any time.
4. **The answer shape:** one spoken line, plus a card with up to 5 bullets, a table of up to 5 rows, one labelled diagram or a set of images, and where the ring lands.

Every recipe also carries a status (`tested` or `untested`), a tested-on line (Lumi version, macOS version and date) and the contributor's handle.

## Use a recipe

1. Open the profession folder and pick the recipe that matches your moment.
2. Check the tools line. If it names a tool you haven't connected, add it in Settings › Connections, or skip the recipe.
3. If the recipe has a CLAUDE.md snippet you want, add it to your own CLAUDE.md.
4. Open the work in front of you, tap right Option and say the ask.

Changes Lumi proposes wait for your OK. Insert puts text into the field you're writing in and never sends it. Student recipes cover study and assignments only.

## Add a recipe

1. Fork the repo and copy [`recipe-template.md`](recipe-template.md) to `recipes/<profession>/<short-name>.md`.
2. Fill in every field. Use fictional names, fictional companies and `.example` domains, never real personal or company data.
3. Run the ask on your own Mac and fill in the tested-on line.
4. Open a pull request.

Reviewers check that:

- the data is fictional;
- the tools are named, and the recipe never claims Lumi works with every tool;
- the answer fits the card;
- there are no claims about offline use, Intel Macs or other platforms;
- student recipes stay with study and assignments.

Your handle stays on the recipe you wrote, and every merged recipe is credited by handle in the release notes. Recipes are licensed under GPL-3.0-or-later, like the rest of the repository.

Share recipes that worked in the Recipes category of [Discussions](https://github.com/loomtable/lumi/discussions). Requirements and install steps are in the [main README](../README.md#install).
