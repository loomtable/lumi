#!/usr/bin/env python3
"""Validate the Lumi scenario library (Scenarios/cases/*).

Usage: python3 -I Tools/scenarios/validate.py [Scenarios/cases]
Checks each scenario's shape against the answer, app and quality rules, then prints coverage (types × apps, lanes,
routing count). Exits 1 on any error.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import buddy_rules  # noqa: E402

APPS = {"browser", "chat", "video", "spreadsheet", "pdf", "editor", "terminal", "finder"}
TYPES = {"define", "summarise", "catch-up", "rewrite", "translate", "compare", "how-to", "diagram",
         "annotate", "video-moment", "compute", "draft-reply", "find-images", "research", "explain-code",
         "approval", "cant-do"}
LANES = {"quick", "deep", "research"}
SHAPES = {"chip", "card", "rich"}
KINDS = {"browser", "editor", "terminal", "chat", "document", "finder", "other"}
PACKET_KEYS = {"v", "asked_at", "utterance", "app", "window", "browser", "local_server", "terminal", "editor",
               "chat", "finder", "selection", "cursor", "screenshot", "display", "recent", "conversation",
               "screenshot_unavailable", "unchanged", "screenshot_unchanged_since_turn", "editable",
               "features", "screenshot_detail"}
SCREENSHOT_UNAVAILABLE = {"not_granted", "capture_failed"}
# Real-world identifiers that must never appear: a real home folder or a personal email address.
# Private names (people, employers) go in the untracked banned-local.txt, one regex per line.
BANNED_PATTERNS = [
    r"/Users/(?!me\b)",
    r"@(?:gmail|googlemail|yahoo|hotmail|outlook|live|icloud|me|mac|aol|proton(?:mail)?)\.(?:com|me)\b",
]
LOCAL_BANNED = os.path.join(os.path.dirname(os.path.abspath(__file__)), "banned-local.txt")
if os.path.isfile(LOCAL_BANNED):
    with open(LOCAL_BANNED, encoding="utf-8") as f:
        BANNED_PATTERNS += [ln.strip() for ln in f if ln.strip() and not ln.lstrip().startswith("#")]
BANNED = re.compile("|".join(f"(?:{p})" for p in BANNED_PATTERNS), re.I)
ID = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)+$")


def check(path, errors):
    d = os.path.basename(path)
    sp = os.path.join(path, "scenario.json")
    hp = os.path.join(path, "screen.html")
    def err(msg):
        errors.append(f"{d}: {msg}")
    if not os.path.isfile(sp) or not os.path.isfile(hp):
        return err("needs scenario.json and screen.html")
    raw = open(sp, encoding="utf-8").read()
    html = open(hp, encoding="utf-8").read()
    for text, name in ((raw, "scenario.json"), (html, "screen.html")):
        m = BANNED.search(text)
        if m:
            err(f"{name} contains banned identifier {m.group(0)!r}")
    if re.search(r"<script|https?://(?!www\.example|example)[^\"'\s]*\.(png|jpe?g|gif|css|js)", html, re.I):
        err("screen.html must be self-contained: no scripts, no external assets")
    try:
        s = json.loads(raw)
    except ValueError as e:
        return err(f"bad JSON: {e}")
    if s.get("id") != d or not ID.match(d):
        err("id must equal the folder name (kebab-case)")
    if s.get("app") not in APPS:
        err(f"app must be one of {sorted(APPS)}")
    if s.get("type") not in TYPES:
        err(f"type must be one of {sorted(TYPES)}")
    if not isinstance(s.get("routing"), bool):
        err("routing must be true/false")
    p = s.get("packet", {})
    extra = set(p) - PACKET_KEYS
    if extra:
        err(f"unknown packet keys {sorted(extra)}")
    if "screenshot_unavailable" in p and p["screenshot_unavailable"] not in SCREENSHOT_UNAVAILABLE:
        err(f"screenshot_unavailable must be one of {sorted(SCREENSHOT_UNAVAILABLE)}")
    if p.get("v") != 1 or not p.get("asked_at") or p.get("utterance") != s.get("question"):
        err("packet needs v=1, asked_at, and utterance equal to question")
    app = p.get("app", {})
    if app.get("kind") not in KINDS or not app.get("name"):
        err("packet.app needs name and a valid kind")
    sel = p.get("selection")
    if sel is not None and (not isinstance(sel.get("length"), int) or "truncated" not in sel):
        err("selection needs length and truncated")
    if "screenshot" in p:
        err("leave packet.screenshot out; the eval adds it")
    e = s.get("expected", {})
    if e.get("lane") not in LANES:
        err("expected.lane must be quick, deep or research")
    if e.get("lane") == "quick" and e.get("shape") not in SHAPES:
        err("quick answers need expected.shape")
    facts = e.get("facts")
    if not isinstance(facts, list) or (e.get("lane") == "quick" and not facts):
        err("expected.facts must list the key facts for quick answers")
    if len(html) < 400:
        err("screen.html is too thin to be a real screen")
    return s


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "Scenarios/cases"
    errors, cases = [], []
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name)
        if os.path.isdir(path):
            s = check(path, errors)
            if isinstance(s, dict):
                cases.append(s)
    lanes = {l: sum(1 for c in cases if c.get("expected", {}).get("lane") == l) for l in sorted(LANES)}
    print(f"{len(cases)} scenarios · lanes {lanes} · routing {sum(1 for c in cases if c.get('routing'))}")
    for t in sorted(TYPES):
        apps = sorted({c["app"] for c in cases if c.get("type") == t})
        print(f"  {t:13} {len(apps)} apps  {', '.join(apps)}")
    missing = TYPES - {c.get("type") for c in cases}
    if missing:
        print(f"  (types with no scenario yet: {sorted(missing)})")
    # Coverage the library must keep: ≥120 scenarios, all 17 types, every app with at
    # least 10, and ≥50 routing cases of which ≥20 are ambiguous (no spoken override).
    ambiguous = [c for c in cases if c.get("routing") and buddy_rules.start(c.get("question", "")) == "quick"]
    per_app = {a: sum(1 for c in cases if c.get("app") == a) for a in APPS}
    checks = [
        (len(cases) >= 120, f"at least 120 scenarios (have {len(cases)})"),
        (not missing, f"every answer type covered (missing {sorted(missing)})"),
        (all(n >= 10 for n in per_app.values()), f"every app has at least 10 (have {per_app})"),
        (sum(1 for c in cases if c.get("routing")) >= 50, "at least 50 routing cases"),
        (len(ambiguous) >= 20, f"at least 20 ambiguous routing cases (have {len(ambiguous)})"),
    ]
    for ok, what in checks:
        if not ok:
            errors.append(f"coverage: {what}")
    for e in errors:
        print("ERROR", e)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
