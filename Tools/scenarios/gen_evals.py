#!/usr/bin/env python3
"""Generate `claude plugin eval` cases from the scenario library.

Usage: python3 -I Tools/scenarios/gen_evals.py <screens dir> <out plugin dir> [--only id,id,…]

Copies buddy-plugin to <out plugin dir> (a scratch location, never committed) and writes one case
per scenario under its evals/. The product sends the screenshot inline; plugin eval can't, so the
case exposes it read-only (case.yaml add_dirs) and the prompt points at it. Quick's instructions are
the buddy-quick agent body plus the buddy-answer skill, appended as the product appends them.

Only questions that reach Quick in the product become cases: "research…" and "go deep…" /
"think hard…" / "go deeper…" go straight to Research or Deep (BuddyBridge's Router, mirrored in
buddy_rules.py; its unit tests cover them). "quick answer…" gets `<handoff>off</handoff>`, as
the cascade sends it.

Graders in the case:
  block     regex  a ```buddy block with `say` first (every case needs one grader)
  facts     llm    the key facts, nothing invented (Quick answers)
  narration llm    card_html doesn't repeat the spoken line (Quick answers)
Lane, shape and the headline are graded in code from the parsed block by summarize.py (only when
the block is valid), and cards in both themes by render.cjs; plugin eval can do neither exactly.

Run evals through run_eval.sh: it always sets a cost ceiling and keeps generated cases out of
the repo.
"""
import json
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import buddy_rules  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PLUGIN = os.path.join(ROOT, "buddy-plugin")
CASES = os.path.join(ROOT, "Scenarios", "cases")
MODEL = "claude-haiku-5-5"


def strip_frontmatter(text):
    return re.sub(r"\A---\n.*?\n---\n", "", text, flags=re.S).strip()


def yaml_block(text, indent=2):
    pad = " " * indent
    return "|\n" + "\n".join(pad + line if line else "" for line in text.splitlines())


def yq(s):
    """Single-quoted YAML scalar."""
    return "'" + s.replace("'", "''") + "'"


def grader(path, front, body=""):
    with open(path, "w", encoding="utf-8") as f:
        f.write("---\n" + "\n".join(f"{k}: {v}" for k, v in front.items()) + "\n---\n" + body)


def system_prompt():
    agent = strip_frontmatter(open(os.path.join(PLUGIN, "agents", "buddy-quick.md"), encoding="utf-8").read())
    rules = os.path.join(PLUGIN, "skills", "buddy-answer")
    # As the app gives Quick its rules (AnswerRules): the shared core, then Quick's own notes.
    core = strip_frontmatter(open(os.path.join(rules, "SKILL.md"), encoding="utf-8").read()).strip()
    quick = open(os.path.join(rules, "quick.md"), encoding="utf-8").read().strip()
    return agent + "\n\n" + core + "\n\n" + quick + "\n"


# As the app shows the packet to the model (BuddyPrompt.modelOmits): no `utterance` (it's the
# <question>), no screen coordinates or IDs.
MODEL_OMITS = [["utterance"], ["selection", "bounds"], ["selection", "bounds_source"],
               ["cursor", "x"], ["cursor", "y"], ["display", "id"], ["display", "scale"], ["conversation", "id"]]


def model_packet(packet):
    out = json.loads(json.dumps(packet))
    for path in MODEL_OMITS:
        if len(path) == 1:
            out.pop(path[0], None)
        elif isinstance(out.get(path[0]), dict):
            out[path[0]].pop(path[1], None)
            if not out[path[0]]:
                out.pop(path[0])
    return out


HANDOFF_OFF = "\n<handoff>off</handoff> Answer yourself from what you have; `handoff` must be null."


def write_case(s, screens, evals_dir, sysprompt):
    """Writes the case; returns False when the question never reaches Quick."""
    route = buddy_rules.start(s["question"])
    if route in ("research", "deep", "deeper"):
        return False
    cid = s["id"]
    case = os.path.join(evals_dir, cid)
    res = os.path.join(case, "resources")
    gdir = os.path.join(case, "graders")
    os.makedirs(res)
    os.makedirs(gdir)
    e = s["expected"]
    # Like the product: when the packet says the screenshot is unavailable, none is attached.
    shot = None
    packet = dict(s["packet"])
    if "screenshot_unavailable" not in packet:
        shot = os.path.join(res, "screen.png")
        shutil.copyfile(os.path.join(screens, cid + ".png"), shot)
        packet["screenshot"] = shot
    tags = [s["app"], s["type"], "lane-" + e["lane"]] + (["routing"] if s["routing"] else [])

    with open(os.path.join(case, "case.yaml"), "w", encoding="utf-8") as f:
        f.write(f'schema_version: "1.1"\nname: {cid}\ncontext:\n  add_dirs: [resources]\n')
    body = ("<buddy-packet>\n" + json.dumps(model_packet(packet), ensure_ascii=False, sort_keys=True) + "\n</buddy-packet>\n"
            f"<question>{s['question']}</question>"
            + (HANDOFF_OFF if route == "quick-noh" else "") +
            (f"\n(The screenshot is {shot}; read it first.)\n" if shot else "\n"))
    with open(os.path.join(case, "prompt.md"), "w", encoding="utf-8") as f:
        f.write("---\n"
                f"description: {yq(s['app'] + ' · ' + s['type'] + ' · expect ' + e['lane'] + (' ' + e.get('shape', '') if e['lane'] == 'quick' else ''))}\n"
                f"tags: [{', '.join(tags)}]\n"
                f"model: {MODEL}\n"
                "max_turns: 4\n"
                "timeout_seconds: 180\n"
                "allowed_tools: [Read]\n"
                f"append_system_prompt: {yaml_block(sysprompt)}\n"
                "---\n" + body)

    grader(os.path.join(gdir, "block.md"), {"type": "regex", "pattern": yq(r'```buddy\s*\{\s*"say"\s*:')})
    if e["lane"] == "quick":
        key, rest = e["facts"][0], e["facts"][1:]
        must_not = "\n".join(f"- {x}" for x in e.get("must_not", []))
        context = json.dumps(s["packet"], ensure_ascii=False)
        # The judge can't see the screenshot, so it gets the screen's text: without it, true details
        # read off the screen ("$60 billion") look invented.
        visible = screen_text(os.path.join(CASES, cid, "screen.html"))
        grader(os.path.join(gdir, "facts.md"), {"type": "llm"},
               "The reply ends with a fenced ```buddy JSON block; judge its `say` and `card_html` together.\n"
               f"The answer was given from a screenshot and this context packet:\n{context}\n"
               f"The text visible in the screenshot (counts as on screen and as support):\n{visible}\n"
               f"PASS if the answer conveys this key fact correctly (wording may differ):\n- {key}\n"
               "and nothing in it contradicts these facts, or states something the screen text, packet and facts don't support:\n"
               + ("\n".join(f"- {x}" for x in rest) or "- (no other facts)")
               + ("\nand it does none of these:\n" + must_not if must_not else "")
               + "\nA short answer that leaves out the supporting facts still PASSES. FAIL if the key fact is missing "
                 "or wrong, or anything stated is false or unsupported. Be strict about figures: a number, name or "
                 "measurement that isn't on screen, in the packet or in the facts FAILS even when plausible, including "
                 "estimates that can't be computed from values shown (e.g. distances from a line whose equation "
                 "isn't shown).\n")
        grader(os.path.join(gdir, "narration.md"), {"type": "llm"},
               "The reply ends with a fenced ```buddy JSON block. `say` is spoken aloud; `card_html` is shown beside it. "
               "The rule (never print the spoken words as well) bans printing what is spoken.\n"
               "FAIL if `card_html` restates the spoken line: `say`'s sentence, or a paraphrase of it with the "
               "same content and no added detail, appears in it as text. Also FAIL if every item or line in the card "
               "is already spoken in `say`, so the card adds nothing new (e.g. say reads out all six translations "
               "and the card lists the same six). A card that repeats one point from `say` among details `say` "
               "doesn't speak PASSES.\n"
               "PASS if `card_html` is null or empty, or if it shows the detail that the spoken line sums up, even "
               "when that detail covers the same ground: the full translation behind a spoken gist, the original "
               "text, the steps of a diagram whose gist is spoken, the items the line names with their details, the "
               "working for a computed result (the result value may appear again next to it), a table, a before/after.\n")
    return True


def screen_text(path, limit=4000):
    """The visible text of a scenario's screen.html: tags, styles and SVG markup removed."""
    import html as html_mod
    raw = open(path, encoding="utf-8").read()
    raw = re.sub(r"(?is)<(style|script|head)\b.*?</\1>", " ", raw)
    text = html_mod.unescape(re.sub(r"(?s)<[^>]+>", " ", raw))
    return re.sub(r"\s+", " ", text).strip()[:limit]


MARKER = ".buddy-evals"


def _key(path):
    """Comparable form of a path: resolved, and case-folded (APFS is case-insensitive by default)."""
    return os.path.realpath(path).casefold()


def _contains(outer, inner):
    o, i = _key(outer), _key(inner)
    return i == o or i.startswith(o.rstrip(os.sep) + os.sep)


def check_out(out):
    """Refuse any output folder that could hold something we didn't create: the repo, anything
    inside it or containing it, home, or root; and a non-empty folder without our marker."""
    home = os.path.expanduser("~")
    for protected in (ROOT, home, "/"):
        if _contains(out, protected) or (protected == ROOT and _contains(ROOT, out)):
            sys.exit(f"refusing to use {out}: it is, contains or is inside {protected}. Use a scratch folder.")
    if os.path.exists(out):
        if os.path.samefile(out, ROOT) or os.path.samefile(out, home):
            sys.exit(f"refusing to use {out}")
        if not os.path.isdir(out):
            sys.exit(f"refusing to use {out}: not a folder")
        if os.listdir(out) and not os.path.exists(os.path.join(out, MARKER)):
            sys.exit(f"refusing to delete {out}: it isn't empty and wasn't made by gen_evals ({MARKER} missing)")


def check_screens(screens, ids):
    missing = [i for i in ids if not os.path.isfile(os.path.join(screens, i + ".png"))]
    if missing:
        sys.exit(f"{len(missing)} screens missing in {screens} (e.g. {missing[0]}): render them first")


def main():
    screens, out = sys.argv[1], sys.argv[2]
    only = set(sys.argv[4].split(",")) if len(sys.argv) > 4 and sys.argv[3] == "--only" else None
    scenarios = []
    for cid in sorted(os.listdir(CASES)):
        p = os.path.join(CASES, cid, "scenario.json")
        if os.path.isfile(p) and (not only or cid in only):
            scenarios.append(json.load(open(p, encoding="utf-8")))
    # Everything is checked before anything is deleted.
    check_out(out)
    check_screens(screens, [s["id"] for s in scenarios if buddy_rules.start(s["question"]) in ("quick", "quick-noh")])
    if os.path.exists(out):
        shutil.rmtree(out)
    shutil.copytree(PLUGIN, out, ignore=shutil.ignore_patterns("evals"))
    open(os.path.join(out, MARKER), "w").close()
    evals = os.path.join(out, "evals")
    os.makedirs(evals)
    sysprompt = system_prompt()
    n = skipped = 0
    for s in scenarios:
        if write_case(s, screens, evals, sysprompt):
            n += 1
        else:
            skipped += 1
    print(f"{n} cases → {evals} ({skipped} skipped: the Router sends them straight to Deep or Research)")


if __name__ == "__main__":
    main()
