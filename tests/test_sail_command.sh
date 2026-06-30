#!/usr/bin/env bash
# test_sail_command.sh
# Asserts that commands/sail.md exists and contains the front-door orchestration contract.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/commands/sail.md"
# Hermetic (.ship/domain.md #102): a real shell exports SAIL_* codex knobs (settings.json);
# clear them so each subtest controls its own backend (subtests set theirs via command prefix).
unset "${!SAIL_@}"

fail() {
  echo "FAIL: $1"
  exit 1
}

assert_grep() {
  local pattern="$1"
  local description="$2"

  if grep -qiE "$pattern" "$SKILL" 2>/dev/null; then
    return 0
  fi

  fail "$description"
}

if [ ! -f "$SKILL" ]; then
  fail "commands/sail.md exists"
fi

# --- Contract checks ---
assert_grep 'sail plan' "references the auto-firing plan stage"
assert_grep 'converg|loop' "mentions a bounded convergence loop"
assert_grep 'trend.stall|cost.backstop|hard ceiling|max[_-]?rounds' "bounds convergence (trend-stall / cost backstop / hard ceiling — #130)"
if grep -qi 'skipped' "$SKILL" 2>/dev/null && grep -qiE 'fail|halt|stop' "$SKILL" 2>/dev/null; then
  :
else
  fail "fails closed when the plan is skipped"
fi
assert_grep 'run-dir|run dir|session' "uses a shared session run-dir"
assert_grep 'build' "hands off to build"
assert_grep 'sail run --diff' "references the review stage"

# --- #47 contract: the three seams are now LIVE Stage-3 behavior, not deferred ---
assert_grep 'plan_verification|acceptance.criteria.*plan\.json|plan.json.*acceptance' "review reads plan.json acceptance criteria (verification spine)"
assert_grep 'unmet.*block|block.*unmet' "an unmet AC blocks"
assert_grep 'dual-lens' "documents the dual-lens escalation flag"
assert_grep 'SAIL_REVIEW_CMD2' "names the second-lens backend env var"
assert_grep 'disposition|addressed.*deferred.*rejected|resolution' "records a per-finding resolution disposition"
assert_grep 'calibration' "documents the calibration validation step"
# guard against regression to 'not built here' deferral language for #47
if grep -qiE 'not built here' "$SKILL" 2>/dev/null; then
  fail "#47 must be live, not a deferred seam ('not built here' still present)"
fi

# --- #120 contract: Stage 2 ENFORCES codex-build-by-default when SAIL_BUILD_CMD is set ---
# (the bug: SAIL_BUILD_CMD was set but Stage 2 left inline as the silent default, so codex never built
#  and builder=reviewer=claude — the cross-family guarantee evaporated with no signal.)
assert_grep 'when .SAIL_BUILD_CMD. is set.*(invoke|default)|SAIL_BUILD_CMD.*set.*invoke .*sail build|invoke .*sail build. by default' \
  "Stage 2 invokes sail build by default when SAIL_BUILD_CMD is set (not inline-by-default)"
assert_grep 'inline.*set.*ALERT|set.*inline.*ALERT|ALERT.*unexpected.*inline|unexpected.*inline.*ALERT' \
  "an UNEXPECTED inline fallback (SAIL_BUILD_CMD set but build came back inline) reads as ALERT (#112)"
assert_grep 'backend-unset' "Stage 2 names the build.json inline reason backend-unset (expected → INFO)"
assert_grep 'backend-not-runnable' "Stage 2 names the build.json inline reason backend-not-runnable (unexpected → ALERT)"
assert_grep 'builder.*reviewer.*claude|same.family.*builder|builder=reviewer' \
  "Stage 2 carries the #83 same-family callout: SAIL_BUILD_CMD set + single-lens claude + inline build → builder=reviewer=claude (cross-family lost)"

echo "PASS: sail command contract verified"
