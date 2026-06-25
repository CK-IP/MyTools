#!/usr/bin/env bash
# test_sail_67_redteam_craft.sh — issue #67: red-team prompt-craft ported into
# sail/review.py REVIEW_PROMPT and sail/plan.py build_adversary_prompt.
# Prompt-text-only port: bias self-guards, >80% confidence + a "Do NOT flag" list,
# a file-type strategy matrix (review only), and required adversarial probes.
# Hermetic: imports the modules and inspects the built prompt strings — no LLM call.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# Hermetic (.ship/domain.md #102): a real shell exports SAIL_* codex knobs (settings.json);
# clear them so each subtest controls its own backend (subtests set theirs via command prefix).
unset "${!SAIL_@}"

fails=0

REVIEW_TXT="$(mktemp)"; ADV_TXT="$(mktemp)"
trap 'rm -f "$REVIEW_TXT" "$ADV_TXT"' EXIT

# Building the prompts ALSO exercises REVIEW_PROMPT.format(diff=...) and AC_PROMPT.format(acs=...);
# a stray unescaped brace in the ported craft would raise here (brace-safety guard).
python3 - "$REVIEW_TXT" "$ADV_TXT" <<'PY'
import sys
import sail.review as r
import sail.plan as p
review_prompt = r.build_prompt("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n", acs=["AC one"])
adv_prompt = p.build_adversary_prompt("Some spec text for the adversary.")
open(sys.argv[1], "w").write(review_prompt)
open(sys.argv[2], "w").write(adv_prompt)
PY

has() { grep -qiF -- "$2" "$1"; }
check() { # <file> <label> <substring...>
  local file="$1" label="$2"; shift 2
  for sub in "$@"; do
    if has "$file" "$sub"; then echo "PASS $label: contains '$sub'";
    else echo "FAIL $label: missing '$sub'"; fails=$((fails+1)); fi
  done
}

# REVIEW_PROMPT (reviews a code diff): all four craft families
check "$REVIEW_TXT" "review/bias-guards" "verification avoidance" "anchoring" "reasoning-only"
check "$REVIEW_TXT" "review/confidence" ">80%" "do not flag" "style preference"
check "$REVIEW_TXT" "review/strategy-matrix" "shell" "test file" "config" "installer"
check "$REVIEW_TXT" "review/probes" "concurrency" "boundary" "idempoten" "injection"

# build_adversary_prompt (reviews a spec, no code): bias guards + threshold + design-level probes
check "$ADV_TXT" "adversary/bias-guards" "verification avoidance" "anchoring"
check "$ADV_TXT" "adversary/confidence" ">80%" "do not flag"
check "$ADV_TXT" "adversary/probes" "concurrency" "boundary" "idempoten" "injection"

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails missing craft marker(s)"; exit 1; fi
echo "PASS: red-team prompt-craft (#67) ported into REVIEW_PROMPT + build_adversary_prompt"
