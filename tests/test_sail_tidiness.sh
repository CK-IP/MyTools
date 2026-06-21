#!/usr/bin/env bash
# test_sail_tidiness.sh — issue #63: a post-build tidiness/simplification review lens for /sail.
# Tidiness is a SEPARATE, ADVISORY (non-blocking), size-gated lens distinct from the correctness
# review (#67 craft) and the cross-family codex dual-lens (#47): codex = different bugs; tidiness =
# cleanup (reuse/duplication/dead-code/naming/efficiency, ported from Anthropic /code-review & /simplify).
# Hermetic: mocks backends via SAIL_REVIEW_CMD / SAIL_TIDINESS_CMD and uses throwaway git targets.
# Never calls a real CLI.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
export SAIL_CHECKERS=ruff,pytest
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"

fail() { echo "FAIL: $*"; exit 1; }

# Mock LLM: discards stdin, emits $MOCK_OUT, exits $MOCK_RC.
mk_mock() { # $1=path $2=outvar-env-name (the env var holding the JSON to emit)
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' "printf '%s' \"\${$2:-}\"" 'exit ${RC:-0}' > "$1"
  chmod +x "$1"
}
REVIEW_MOCK="$WORK/review_mock.sh"; mk_mock "$REVIEW_MOCK" REVIEW_OUT
TIDY_MOCK="$WORK/tidy_mock.sh";     mk_mock "$TIDY_MOCK"   TIDY_OUT

# Clean git target with a multi-line working-tree change (gates pass; diff non-empty).
new_target() { # $1=dir
  mkdir -p "$1"
  printf 'def f():\n    return 1\n' > "$1/mod.py"
  git -C "$1" init -q
  git -C "$1" add -A
  git -C "$1" -c user.email=t@t -c user.name=t commit -qm base
  printf 'def f():\n    x = 1\n    y = 2\n    return x + y  # changed\n' > "$1/mod.py"
}

CLEAN='{"findings":[],"summary":"no issues"}'
# A tidiness backend that reports a HIGH cleanup. Advisory: must NOT fail the run.
TIDY_HIGH='{"findings":[{"severity":"HIGH","category":"other","file":"mod.py","line":2,"issue":"dead local var x/y can be inlined","recommendation":"return 1 + 2"}],"summary":"1 cleanup"}'

# --- T1: --tidiness runs the tidiness lens, records a separate advisory `tidiness` block,
#         and a HIGH tidiness finding does NOT fail the run (gates clean + correctness clean → exit 0). ---
TGT="$WORK/t1"; new_target "$TGT"; RD="$WORK/rd1"
set +e
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="bash $TIDY_MOCK" TIDY_OUT="$TIDY_HIGH" \
  python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD" --tidiness >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = "0" ] || fail "T1: advisory tidiness HIGH must NOT fail the run (expected 0), got $rc"
[ -f "$RD/review.json" ] || fail "T1: review.json not written"
python3 - "$RD/review.json" <<'PY' || fail "T1: tidiness block missing/malformed or leaked into blocking findings"
import json, sys
d = json.load(open(sys.argv[1]))
t = d.get("tidiness")
assert isinstance(t, dict), "no tidiness block"
assert t.get("status") == "completed", f"tidiness status={t.get('status')}"
assert len(t.get("findings", [])) == 1, "tidiness finding not recorded"
assert t["findings"][0].get("lens") == "tidiness", "tidiness finding not lens-tagged"
# Tidiness must NOT pollute the blocking correctness findings or counts.
assert d.get("findings") == [], "tidiness leaked into blocking findings"
assert d["counts"]["HIGH"] == 0, "tidiness HIGH leaked into blocking counts"
PY
echo "PASS T1: --tidiness records a separate advisory tidiness block; HIGH cleanup is non-blocking"

# --- T2: default (no --tidiness) does NOT run the tidiness lens — review.json has no tidiness block. ---
TGT="$WORK/t2"; new_target "$TGT"; RD="$WORK/rd2"
set +e
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="bash $TIDY_MOCK" TIDY_OUT="$TIDY_HIGH" \
  python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = "0" ] || fail "T2: clean run without --tidiness should exit 0, got $rc"
python3 -c "import json,sys; d=json.load(open('$RD/review.json')); sys.exit(0 if d.get('tidiness') is None else 1)" \
  || fail "T2: tidiness must be absent when --tidiness not passed"
echo "PASS T2: tidiness lens is opt-in (absent by default)"

# --- T3: size gate — SAIL_TIDINESS_MIN_LINES above the diff size skips the lens cleanly. ---
TGT="$WORK/t3"; new_target "$TGT"; RD="$WORK/rd3"
set +e
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="bash $TIDY_MOCK" TIDY_OUT="$TIDY_HIGH" \
SAIL_TIDINESS_MIN_LINES=9999 \
  python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD" --tidiness >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = "0" ] || fail "T3: size-gated skip must not fail the run, got $rc"
python3 - "$RD/review.json" <<'PY' || fail "T3: size gate did not record a clean skip"
import json, sys
t = json.load(open(sys.argv[1])).get("tidiness")
assert isinstance(t, dict) and t.get("status") == "skipped", f"expected skipped, got {t}"
assert "min" in (t.get("reason","").lower()) or "line" in (t.get("reason","").lower()), "skip reason not size-gate"
PY
echo "PASS T3: size gate (SAIL_TIDINESS_MIN_LINES) skips small diffs cleanly"

# --- T4: --tidiness with no tidiness backend degrades cleanly (skipped, NOT a hard error). ---
TGT="$WORK/t4"; new_target "$TGT"; RD="$WORK/rd4"
set +e
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="/nonexistent/tidy-xyz" \
  python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD" --tidiness >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = "0" ] || fail "T4: missing tidiness backend must degrade cleanly (advisory), got $rc"
python3 - "$RD/review.json" <<'PY' || fail "T4: missing tidiness backend not recorded as clean skip"
import json, sys
t = json.load(open(sys.argv[1])).get("tidiness")
assert isinstance(t, dict) and t.get("status") == "skipped", f"expected skipped, got {t}"
PY
echo "PASS T4: --tidiness degrades cleanly when no tidiness backend is available"

# --- T5: tidiness does NOT mask a real correctness HIGH — correctness review still blocks. ---
TGT="$WORK/t5"; new_target "$TGT"; RD="$WORK/rd5"
REVIEW_HIGH='{"findings":[{"severity":"HIGH","category":"correctness","file":"mod.py","line":2,"issue":"real bug","recommendation":"fix"}],"summary":"1 high"}'
set +e
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$REVIEW_HIGH" \
SAIL_TIDINESS_CMD="bash $TIDY_MOCK" TIDY_OUT="$CLEAN" \
  python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD" --tidiness >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = "1" ] || fail "T5: a real correctness HIGH must still block even with tidiness on, got $rc"
echo "PASS T5: tidiness lens does not weaken correctness blocking"

# --- T6: `sail review --tidiness` (standalone review subcommand) also runs the lens. ---
TGT="$WORK/t6"; new_target "$TGT"; RD="$WORK/rd6"
set +e
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="bash $TIDY_MOCK" TIDY_OUT="$TIDY_HIGH" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD" --tidiness >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = "0" ] || fail "T6: standalone review --tidiness advisory should exit 0, got $rc"
python3 -c "import json,sys; t=json.load(open('$RD/review.json')).get('tidiness'); sys.exit(0 if (isinstance(t,dict) and t.get('status')=='completed') else 1)" \
  || fail "T6: standalone review --tidiness did not record a tidiness block"
echo "PASS T6: sail review --tidiness runs the lens standalone"

# --- T7: a resumed same-scope `sail run --tidiness` over a run-dir whose cached review.json has
#         NO tidiness block must NOT reuse the stale cache — it must re-review and add the block
#         (mirrors the --dual-lens reuse-invalidation guard; flagged by red-team). ---
TGT="$WORK/t7"; new_target "$TGT"; RD="$WORK/rd7"
# First run: no --tidiness → review.json written WITHOUT a tidiness block + run-state.json.
set +e
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
  python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = "0" ] || fail "T7: first (non-tidiness) run should exit 0, got $rc"
python3 -c "import json,sys; sys.exit(0 if json.load(open('$RD/review.json')).get('tidiness') is None else 1)" \
  || fail "T7: first run unexpectedly wrote a tidiness block"
# Second run: SAME run-dir/target/diff (a resume), now WITH --tidiness → must re-review.
set +e
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="bash $TIDY_MOCK" TIDY_OUT="$TIDY_HIGH" \
  python3 -m sail run --target "$TGT" --diff HEAD --run-dir "$RD" --tidiness >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = "0" ] || fail "T7: resumed --tidiness run should exit 0 (advisory), got $rc"
python3 -c "import json,sys; t=json.load(open('$RD/review.json')).get('tidiness'); sys.exit(0 if (isinstance(t,dict) and t.get('status')=='completed' and len(t.get('findings',[]))==1) else 1)" \
  || fail "T7: resumed --tidiness reused a stale cache and skipped the lens (no tidiness block)"
grep -qi "tidiness requested but cache has no tidiness block" "$RD/decision-log.md" \
  || fail "T7: missing reuse-invalidation marker for tidiness"
echo "PASS T7: resumed --tidiness invalidates a stale cache and re-runs the lens"

# --- T8: the size-gate line counter is hunk-aware — `---`/`+++` FILE headers are excluded, but
#         hunk-body content lines whose own text starts with +/- (rendered ---/+++ ) ARE counted
#         (red-team round 2 edge case). ---
python3 - <<'PY' || fail "T8: _diff_changed_lines miscounts hunk-body lines"
from sail.review import _diff_changed_lines
diff = "".join(line + "\n" for line in [
    "diff --git a/f b/f",
    "index 1111111..2222222 100644",
    "--- a/f",
    "+++ b/f",
    "@@ -1,2 +1,3 @@",
    " context",
    "-- removed line whose content starts with a dash",
    "++ added line whose content starts with a plus",
    "+normal added line",
])
# 3 changed content lines in the hunk body; the ---/+++ FILE headers must NOT count.
got = _diff_changed_lines(diff)
assert got == 3, f"expected 3 changed lines, got {got}"
PY
echo "PASS T8: size-gate counter is hunk-aware (file headers excluded, +/-prefixed content counted)"

echo "ALL PASS: test_sail_tidiness.sh"
