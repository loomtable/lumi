#!/usr/bin/env python3
"""Turn a `claude plugin eval --json` result into the quality bars.

Usage: python3 -I Tools/scenarios/summarize.py <result.json> [cards.jsonl]

The run must use --keep-temp (run_eval.sh does): lane, shape and the headline are graded here, in
code, from the final ```buddy block in each run's trace, and count only when that block is valid
(a missing block fails all three). Facts and narration come from the case's LLM graders. With a
second argument, each run's card_html is written as JSONL for `render.cjs cards`.

Bars: lane ≥90%, shape ≥90%, headline ≤15 words 100%, narration 100%, cards in both themes 100%.
"""
import json
import os
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import buddy_rules  # noqa: E402

CASES = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "Scenarios", "cases")
BARS = {"lane": 0.90, "shape": 0.90, "headline": 1.0, "narration": 1.0}


def final_text(trace_path):
    text = None
    for line in open(trace_path, encoding="utf-8"):
        o = json.loads(line)
        if o.get("type") == "assistant" and not o.get("parent_tool_use_id"):
            for b in o.get("message", {}).get("content", []):
                if b.get("type") == "text":
                    text = b["text"]
    return text or ""


def main():
    result = json.load(open(sys.argv[1], encoding="utf-8"))
    cards_out = sys.argv[2] if len(sys.argv) > 2 else None
    tally = defaultdict(lambda: [0, 0])
    by_lane = defaultdict(lambda: [0, 0])
    routing = [0, 0]
    by_type = defaultdict(lambda: [0, 0])
    failures, cards = [], []
    for case in result["cases"]:
        s = json.load(open(os.path.join(CASES, case["name"], "scenario.json"), encoding="utf-8"))
        exp = s["expected"]
        for i, run in enumerate(case["arms"]["with"]):
            tag = f"{case['name']} run {i + 1}"
            if run.get("error"):
                failures.append(f"{tag}: ERROR {run['error']}")
            trace = run.get("tracePath")
            if trace and os.path.exists(trace):
                block = buddy_rules.parse_block(final_text(trace))
            else:
                # No trace (the run errored, or --keep-temp was missing): nothing to grade, so it fails.
                failures.append(f"{tag}: no trace (use run_eval.sh, which keeps traces)")
                block = None

            def score(name, ok, why=""):
                tally[name][1] += 1
                tally[name][0] += ok
                if not ok:
                    failures.append(f"{tag}: {name}{' — ' + why if why else ''}")

            score("block", block is not None, "no valid buddy block")
            got_lane = buddy_rules.lane(block) if block else None
            lane_ok = got_lane == exp["lane"]
            score("lane", lane_ok, f"expected {exp['lane']}, got {got_lane}")
            by_lane[exp["lane"]][1] += 1
            by_lane[exp["lane"]][0] += lane_ok
            if s.get("routing"):
                routing[1] += 1
                routing[0] += lane_ok
            if block is not None:
                n = buddy_rules.headline_words(block["say"])
                score("headline", n <= 15, f"{n} words: {buddy_rules.first_sentence(block['say'])[:90]}")
            else:
                score("headline", False, "no block")
            if exp["lane"] == "quick":
                got_shape = buddy_rules.shape(block) if block else None
                shape_ok = block is not None and got_shape == exp["shape"]
                score("shape", shape_ok, f"expected {exp['shape']}, got {got_shape}")
                by_type[s["type"]][1] += 1
                by_type[s["type"]][0] += lane_ok and shape_ok
            for g in run.get("graders", []):
                if g["name"] in ("facts", "narration") and g.get("scored", True):
                    score(g["name"], g["passed"], g.get("explanation", "")[:80])
            if cards_out and block and block.get("card_html"):
                cards.append({"id": case["name"], "run": i + 1, "shape": buddy_rules.shape(block) or "card",
                              "card_html": block["card_html"]})

    print(f"cost ${result.get('costUsd', 0):.4f} · {result.get('durationSeconds')} s · partial={result.get('partial')} · "
          f"{len(result['cases'])} cases")
    for name in ["block", "lane", "shape", "headline", "narration", "facts"]:
        p, t = tally.get(name, [0, 0])
        if not t:
            continue
        bar = BARS.get(name)
        verdict = "" if bar is None else ("  PASS" if p / t >= bar else f"  BELOW {bar:.0%}")
        print(f"  {name:10} {p}/{t} = {p / t:.0%}{verdict}")
    for lane, (p, t) in sorted(by_lane.items()):
        print(f"  lane={lane}: {p}/{t}")
    if routing[1]:
        print(f"  routing cases (ambiguous, no override): {routing[0]}/{routing[1]}")
    print("  by type (quick answers, lane+shape right):")
    for ctype, (p, t) in sorted(by_type.items()):
        print(f"    {ctype:13} {p}/{t}")
    if failures:
        print(f"failures ({len(failures)}):")
        for f in failures:
            print("  " + f)
    if cards_out:
        with open(cards_out, "w", encoding="utf-8") as f:
            for c in cards:
                f.write(json.dumps(c) + "\n")
        print(f"{len(cards)} cards → {cards_out}")


if __name__ == "__main__":
    main()
