#!/usr/bin/env bash
# test_sail_152_negative_prompting.sh — issue #152: negative prompting ("do NOT flag")
# across the review, red-team, and tidiness lenses + a per-round advisory-finding count in
# the decision log. Two guards:
#   (1) prompt-assembly: the shared DO_NOT_FLAG section is present in the assembled prompt for
#       each of the three lenses (guards against prompt drift — the reason docs-impact drifted);
#   (2) DecisionLog: an advisory-count record is written per round and a re-record for the same
#       round OVERWRITES rather than appends.
# Hermetic: imports the modules and inspects the built strings / the on-disk log — no LLM call.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# Hermetic (.ship/domain.md #102): a real shell exports SAIL_* codex knobs (settings.json);
# clear them so backend selection cannot perturb prompt assembly.
unset "${!SAIL_@}"

fails=0

REVIEW_TXT="$(mktemp)"; REDTEAM_TXT="$(mktemp)"; TIDINESS_TXT="$(mktemp)"
TMP_RUN="$(mktemp -d)"
trap 'rm -f "$REVIEW_TXT" "$REDTEAM_TXT" "$TIDINESS_TXT"; rm -rf "$TMP_RUN"' EXIT

# Building the prompts ALSO exercises the .format(diff=...) sites; a stray unescaped brace in the
# shared DO_NOT_FLAG constant would raise here (brace-safety guard).
python3 - "$REVIEW_TXT" "$REDTEAM_TXT" "$TIDINESS_TXT" <<'PY'
import sys
import sail.review as r

diff = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n"
# review lens
open(sys.argv[1], "w").write(r.build_prompt(diff, acs=["AC one"]))
# red-team lens
open(sys.argv[2], "w").write(r.build_redteam_prompt(diff, stride=False))
# tidiness lens (TIDINESS_PROMPT is .format(diff=...)-ed)
open(sys.argv[3], "w").write(r.TIDINESS_PROMPT.format(diff=diff))

# The shared constant must exist and enumerate the five exclusion classes (AC1).
assert hasattr(r, "DO_NOT_FLAG"), "sail.review.DO_NOT_FLAG constant is missing"
PY

has() { grep -qiF -- "$2" "$1"; }
check() { # <file> <label> <substring...>
  local file="$1" label="$2"; shift 2
  for sub in "$@"; do
    if has "$file" "$sub"; then echo "PASS $label: contains '$sub'";
    else echo "FAIL $label: missing '$sub'"; fails=$((fails+1)); fi
  done
}

# (1) Each lens's assembled prompt carries the do-NOT-flag section header + the five exclusion
# classes from AC1. Substrings are lens-agnostic so drift in any one site is caught.
for pair in "review:$REVIEW_TXT" "red-team:$REDTEAM_TXT" "tidiness:$TIDINESS_TXT"; do
  label="${pair%%:*}"; file="${pair#*:}"
  check "$file" "$label/do-not-flag" \
    "do not flag" \
    "pre-existing" \
    "exploit path" \
    "outside the diff" \
    "phrasing" \
    "deterministic gate"
done

# (2) DecisionLog per-round advisory count: N recorded, and a re-record for the SAME round
# overwrites (no append/accretion). A different round coexists.
python3 - "$TMP_RUN" <<'PY'
import os, sys, re
from sail.decisionlog import DecisionLog

run_dir = sys.argv[1]
log = DecisionLog(run_dir)
assert hasattr(log, "record_advisory_count"), "DecisionLog.record_advisory_count is missing"

log.record_advisory_count(1, 3)
log.record_advisory_count(2, 5)
log.record_advisory_count(1, 7)   # re-record round 1 — must OVERWRITE, not append

text = open(os.path.join(run_dir, "decision-log.md"), encoding="utf-8").read()
r1 = re.findall(r"advisory-findings \[round=1\]:\s*(\d+)", text)
r2 = re.findall(r"advisory-findings \[round=2\]:\s*(\d+)", text)
assert r1 == ["7"], f"round 1 should overwrite to a single '7', got {r1!r}"
assert r2 == ["5"], f"round 2 should be a single '5', got {r2!r}"
print("PASS decisionlog/advisory-count: round-keyed overwrite works")
PY

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails missing marker(s)"; exit 1; fi
echo "PASS: negative prompting + per-round advisory count (#152)"
