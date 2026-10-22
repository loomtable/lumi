# Recipe template

A recipe is one real moment, written so anyone can run it. Copy this file to `recipes/<profession>/<short-name>.md`, fill in each field, and open a pull request. Delete the guidance lines in italics before you submit.

Before you start, read these four rules:
- Use fictional names and `.example` domains only. No real people, companies, customers or files.
- Name tools only if you have connected them yourself. Write "the tools you've connected", never "any tool".
- Students: study and assignments only.
- Mark a recipe `tested` only after you ran it on a real Mac.

---

## Template

````markdown
# [Recipe title: the job, in plain words]

**Profession:** [one of: founder, product manager, designer, researcher, analyst, marketer, sales, writer, student, consultant, operator, developer]

**Moment:**
[One or two sentences. Where you are, what is on your screen, what you need. Start with the person, not the product.]

**The spoken ask:**
> "[Exactly what you say after tapping right Option. One sentence. Keep it natural.]"

**Tools you've connected (optional):**
- [Tool name, for example Slack, Notion, Linear, GitHub, Jira, Drive, Calendar, a browser]
- [Delete this section if the recipe needs only the screen, your files and your Mac.]

**CLAUDE.md snippet (optional):**
```text
[3 to 6 lines that shape the answer. Put them in your own CLAUDE.md. Delete this section if the recipe works without one.]
```

**Expected answer shape:**
- Spoken line: [what Lumi says, in one short sentence]
- Card: [choose one: up to 5 bullets, a table of up to 5 rows, one labelled diagram, a set of images, or no card]
- Ring target: [the exact spot Lumi points at: a cell, a clause, a name, a button, or none]
- Insert (optional): [text Lumi puts into the field you are writing in. Insert never sends.]
- Waits for your OK (optional): [any change Lumi proposes that you approve first]

**Status:** [tested | untested]

**Tested on:**
- Lumi version: [for example 0.1.0]
- macOS version: [macOS 26.x]
- Date: [YYYY-MM-DD]

**Contributor:** [@your-github-handle]
````

---

## Field guide

| Field | What to write | Limit |
|---|---|---|
| Profession | One profession from the list. Pick the person the moment belongs to. | One |
| Moment | The situation on screen, in the person's words. | 2 sentences |
| The spoken ask | The words you say. Quote them. | 1 sentence |
| Tools you've connected | Names only, for tools connected through MCP in your own setup. | Optional |
| CLAUDE.md snippet | Lines that shape the answer, such as naming the source file or preferring a table. Claim only what you have seen work. | 3 to 6 lines, optional |
| Expected answer shape | One spoken line, plus one card form, plus the ring target. | Card: 5 bullets, or 5 table rows, or 1 diagram, or a set of images |
| Status | `untested` until you have run it. Then `tested`. | One word |
| Tested on | Lumi version, macOS version (macOS 26 or newer, Apple Silicon), and the date you ran it. | Required if tested |
| Contributor | Your GitHub handle. We credit you by name in release notes. | One handle |

---

## Filled example: analyst

````markdown
# Find out why sign-ups dipped on Tuesday

**Profession:** analyst

**Moment:**
A dashboard chart is open and sign-ups dip on Tuesday. A stakeholder message is waiting. You need the likely cause and where it shows up, without leaving the chart.

**The spoken ask:**
> "Why did sign-ups drop on Tuesday?"

**Tools you've connected (optional):**
- Drive (for the team's weekly notes)

**CLAUDE.md snippet (optional):**
```text
When I ask about a chart or a sheet, name the source file and the cell or range.
Keep the spoken answer to one sentence.
Show comparisons as a table of up to five rows.
Say what you could not check.
```

**Expected answer shape:**
- Spoken line: one sentence naming the most likely cause and the file it came from
- Card: a table of three rows (day, sign-ups, note), built from the fictional file `signups-weekly.csv.example` in Downloads
- Ring target: the Tuesday point on the chart
- Insert (optional): a two-line summary placed in the reply field of the stakeholder message, not sent
- Waits for your OK: none

**Status:** untested

**Tested on:**
- Lumi version: (untested)
- macOS version: (untested)
- Date: (untested)

**Contributor:** Loomtable
````

---

## Before you open the pull request

- [ ] File saved as `recipes/<profession>/<short-name>.md`
- [ ] Every name is fictional and every address ends in `.example`
- [ ] No claim of offline use, Intel, Windows or Linux support
- [ ] Tools listed are ones you have connected
- [ ] Status and "Tested on" match what you ran
- [ ] Students: the recipe is about study or an assignment

Tell us what it did for your week.

Loomtable

**Free, open source and local. Works with your Claude Code, on your Mac.**
