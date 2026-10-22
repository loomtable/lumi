#!/bin/bash
# Runs the scenario evals the only supported way: generated cases in a scratch folder outside the
# repo, a hard cost ceiling, traces kept for the code-graded bars, then the summary and the card
# check. Every run spends your Claude plan: check the cost first.
#
#   Tools/scenarios/run_eval.sh <scratch dir> <max cost USD> [runs per case] [extra plugin-eval args…]
#
# --trust-plugin is the documented flag for a non-interactive run of a plugin you would run
# yourself; it only skips the first-run trust prompt.
set -euo pipefail
[[ $# -ge 2 ]] || { echo "usage: $0 <scratch dir> <max cost USD> [runs] [args…]" >&2; exit 2; }
# Resolve the scratch folder before changing directory, so a relative path means what you typed.
scratch=$(python3 -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1")
max_cost=$2; runs=${3:-1}; shift $(( $# >= 3 ? 3 : 2 ))
cd "$(dirname "$0")/../.."
repo=$(pwd -P)
[[ $max_cost =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "max cost must be a number of USD" >&2; exit 2; }
for arg in "$@"; do
  [[ $arg == --max-cost-usd* ]] && { echo "the cost ceiling is the second argument; don't pass --max-cost-usd" >&2; exit 2; }
done
python3 -I - "$scratch" "$repo" <<'PY' || exit 2
import os, sys
s, r = (os.path.realpath(p).casefold().rstrip("/") for p in sys.argv[1:3])
home = os.path.realpath(os.path.expanduser("~")).casefold()
if s in ("", "/", home) or s == r or s.startswith(r + "/") or r.startswith(s + "/"):
    sys.exit(f"refusing scratch folder {sys.argv[1]}: use a folder outside the repo (not home, not /)")
PY
mkdir -p "$scratch"
stamp=$(date +%Y%m%d-%H%M%S)
python3 -I Tools/scenarios/validate.py
Tools/scenarios/pw Tools/scenarios/render.cjs screens Scenarios/cases "$scratch/screens"
python3 -I Tools/scenarios/gen_evals.py "$scratch/screens" "$scratch/plugin"
out="$scratch/runs/$stamp"
mkdir -p "$out"
# Keep the parent Claude Code session's variables out of the eval's children.
env -u CLAUDECODE -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_SESSION_ID \
    -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_PID -u CLAUDE_EFFORT \
    -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_EXECPATH \
  claude plugin eval "$scratch/plugin" --trust-plugin --ablation none --runs "$runs" --concurrency 4 \
    --max-cost-usd "$max_cost" --no-publish --keep-temp --output-dir "$out" --json "$out/result.json" "$@" \
    > "$out/eval.log" 2>&1 || true   # exit 1 just means some case is below the threshold
python3 -I Tools/scenarios/summarize.py "$out/result.json" "$out/cards.jsonl" | tee "$out/summary.txt"
Tools/scenarios/pw Tools/scenarios/render.cjs cards "$out/cards.jsonl" "$out/cards-report.json" | tee -a "$out/summary.txt"
echo "results: $out"
