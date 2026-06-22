#!/usr/bin/env bash
# test_sail_70_test_adequacy.sh — issue #70: a test-adequacy probe in sail/review.py
# REVIEW_PROMPT. The single existing adversarial review pass is told to ask whether a
# plausible mutation to the diff's core behavior change would be caught by the new/changed
# tests, and to flag vacuous/tautological tests as a finding (category "test-adequacy").
# Pure prompt addition: no second LLM call, no new code path. Hermetic — builds the prompt
# string and exercises the finding pipeline; no LLM is invoked.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

fails=0

REVIEW_TXT="$(mktemp)"
trap 'rm -f "$REVIEW_TXT"' EXIT

# Building the prompt also exercises REVIEW_PROMPT.format(diff=...) — a stray unescaped brace
# in the added probe would raise here (brace-safety guard).
python3 - "$REVIEW_TXT" <<'PY'
import sys
import sail.review as r
# A diff that adds a test — the probe is always-on, so it must appear regardless.
prompt = r.build_prompt("--- a/x.py\n+++ b/x.py\n@@ -1 +1 @@\n-old\n+new\n", acs=["AC one"])
open(sys.argv[1], "w").write(prompt)
PY

has() { grep -qiF -- "$2" "$1"; }
check() { # <file> <label> <substring...>
  local file="$1" label="$2"; shift 2
  for sub in "$@"; do
    if has "$file" "$sub"; then echo "PASS $label: contains '$sub'";
    else echo "FAIL $label: missing '$sub'"; fails=$((fails+1)); fi
  done
}

# 1. The probe semantics are present in the built review prompt.
check "$REVIEW_TXT" "probe/mutation"   "mutation"
check "$REVIEW_TXT" "probe/vacuous"    "vacuous" "tautological"
check "$REVIEW_TXT" "probe/test-adeq"  "test-adequacy"
# 2. No-false-positive guard: the probe must pin the actual no-op contract — emit NO finding
#    when the diff changes no test behavior — not just the loose words "no test". A reviewer-prompt
#    mutation that weakened/inverted the no-op instruction would no longer match this clause.
check "$REVIEW_TXT" "probe/no-op"      "changes no test behavior" "code-only or docs-only"
# 3. Deferral of the heavyweight mutation-testing tool to a later /fortify stage is noted.
check "$REVIEW_TXT" "probe/defer"      "fortify"

# 4. A flagged vacuous test surfaces as a NORMAL finding: it parses, counts, and a HIGH one
#    blocks via the existing pipeline (no new exit-code path). Would catch a mutation that
#    special-cased test-adequacy findings out of findings/has_blocking.
python3 - <<'PY'
import sail.review as r
high = '{"findings":[{"severity":"HIGH","category":"test-adequacy","file":"t.py","line":1,"issue":"vacuous test: passes under a plausible mutation","recommendation":"assert the real output"}],"summary":"x"}'
f = r.parse_findings(high)
assert f is not None and len(f) == 1, "test-adequacy finding must parse"
assert f[0]["category"] == "test-adequacy", "category preserved"
assert r.severity_counts(f)["HIGH"] == 1, "must count toward HIGH"
assert r.has_blocking(f), "a HIGH test-adequacy finding must block the gate"

# A borderline (reviewer-assigned MEDIUM) test-adequacy finding must NOT block — proves
# severity stays reviewer-assigned rather than force-blocking every such finding.
med = '{"findings":[{"severity":"MEDIUM","category":"test-adequacy","file":"t.py","line":1,"issue":"weak assertion","recommendation":"tighten"}],"summary":"x"}'
fm = r.parse_findings(med)
assert fm is not None and not r.has_blocking(fm), "a MEDIUM test-adequacy finding must NOT block"
print("PASS pipeline: test-adequacy finding parses/counts/blocks-at-HIGH, non-blocking at MEDIUM")
PY

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails missing probe marker(s)"; exit 1; fi
echo "PASS: test-adequacy probe (#70) present in REVIEW_PROMPT + flows through finding pipeline"
