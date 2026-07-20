#!/usr/bin/env bash
# test_sail_100_convergence_reappearance.sh
# Issue #100 — deterministic guard against re-flagging a dispositioned blocking finding.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
LOG_FILE="$TMP_ROOT/python.log"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  if [ -s "$LOG_FILE" ]; then
    echo "---- python output ----" >&2
    sed 's/^/  /' "$LOG_FILE" >&2 || true
    echo "-----------------------" >&2
  fi
  exit 1
}

converge() { python3 -m sail converge "$@" 2>"$LOG_FILE"; }

seed_run_dir() {
  local dir="$1"
  local log_text="$2"
  local review_json="$3"

  mkdir -p "$dir"
  {
    printf '%s\n' '# /sail decision log'
    if [ -n "$log_text" ]; then
      printf '%s\n' "$log_text"
    fi
  } > "$dir/decision-log.md"
  printf '%s' "$review_json" > "$dir/review.json"
}

cd "$REPO_ROOT"
# Hermetic (.ship/domain.md #102): a real shell exports SAIL_* codex knobs (settings.json);
# clear them so each subtest controls its own backend (subtests set theirs via command prefix).
unset "${!SAIL_@}"

# 1. rejected finding reappears as HIGH -> park and name the id.
RD1="$TMP_ROOT/rd1"
seed_run_dir "$RD1" $'- resolution: [ID1] rejected — because' '{"round":2,"findings":[{"id":"ID1","severity":"HIGH"}]}'
out=$(converge --rc 1 --round 2 --run-dir "$RD1") || fail "case 1 exited non-zero"
[ "$out" = "park" ] || fail "case 1 expected park, got '$out'"
grep -q 'ID1' "$LOG_FILE" || fail "case 1 stderr must name ID1"

# 2. unrelated HIGH finding -> revise.
RD2="$TMP_ROOT/rd2"
seed_run_dir "$RD2" "" '{"round":2,"findings":[{"id":"OTHER","severity":"HIGH"}]}'
out=$(converge --rc 1 --round 2 --run-dir "$RD2") || fail "case 2 exited non-zero"
[ "$out" = "revise" ] || fail "case 2 expected revise, got '$out'"

# 3. deferred finding reappears as HIGH -> park.
RD3="$TMP_ROOT/rd3"
seed_run_dir "$RD3" $'- resolution: [ID1] deferred — later' '{"round":2,"findings":[{"id":"ID1","severity":"HIGH"}]}'
out=$(converge --rc 1 --round 2 --run-dir "$RD3") || fail "case 3 exited non-zero"
[ "$out" = "park" ] || fail "case 3 expected park, got '$out'"
grep -q 'ID1' "$LOG_FILE" || fail "case 3 stderr must name ID1"

# 4. addressed finding reappears as HIGH -> revise.
RD4="$TMP_ROOT/rd4"
seed_run_dir "$RD4" $'- resolution: [ID1] addressed — fixed' '{"round":2,"findings":[{"id":"ID1","severity":"HIGH"}]}'
out=$(converge --rc 1 --round 2 --run-dir "$RD4") || fail "case 4 exited non-zero"
[ "$out" = "revise" ] || fail "case 4 expected revise, got '$out'"

# 5. reappeared finding is LOW, while a new HIGH exists -> revise.
RD5="$TMP_ROOT/rd5"
seed_run_dir "$RD5" $'- resolution: [ID1] rejected — because' '{"round":2,"findings":[{"id":"ID1","severity":"LOW"},{"id":"NEWB","severity":"HIGH"}]}'
out=$(converge --rc 1 --round 2 --run-dir "$RD5") || fail "case 5 exited non-zero"
[ "$out" = "revise" ] || fail "case 5 expected revise, got '$out'"

# 6. findings:null and findings:123 both degrade to revise.
RD6A="$TMP_ROOT/rd6a"
seed_run_dir "$RD6A" $'- resolution: [ID1] rejected — because' '{"round":2,"findings":null}'
out=$(converge --rc 1 --round 2 --run-dir "$RD6A") || fail "case 6a exited non-zero"
[ "$out" = "revise" ] || fail "case 6a expected revise, got '$out'"

RD6B="$TMP_ROOT/rd6b"
seed_run_dir "$RD6B" $'- resolution: [ID1] rejected — because' '{"round":2,"findings":123}'
out=$(converge --rc 1 --round 2 --run-dir "$RD6B") || fail "case 6b exited non-zero"
[ "$out" = "revise" ] || fail "case 6b expected revise, got '$out'"

# 7. exact-id limitation: a same-suffix cross-lens re-flag does not trip the guard.
RD7="$TMP_ROOT/rd7"
seed_run_dir "$RD7" $'- resolution: [lens1-AAA] rejected — because' '{"round":2,"findings":[{"id":"lens2-AAA","severity":"HIGH"}]}'
out=$(converge --rc 1 --round 2 --run-dir "$RD7") || fail "case 7 exited non-zero"
[ "$out" = "revise" ] || fail "case 7 expected revise, got '$out'"

# 8. empty run-dir -> revise.
RD8="$TMP_ROOT/rd8"
mkdir -p "$RD8"
out=$(converge --rc 1 --round 2 --run-dir "$RD8") || fail "case 8 exited non-zero"
[ "$out" = "revise" ] || fail "case 8 expected revise, got '$out'"

# 9. no --run-dir -> revise.
out=$(converge --rc 1 --round 2) || fail "case 9 exited non-zero"
[ "$out" = "revise" ] || fail "case 9 expected revise, got '$out'"

# 10. green result stays proceed even when a dispositioned finding reappears.
RD10="$TMP_ROOT/rd10"
seed_run_dir "$RD10" $'- resolution: [ID1] rejected — because' '{"round":2,"findings":[{"id":"ID1","severity":"HIGH"}]}'
cat > "$RD10/run-state.json" <<'JSON'
{"gates":[{"name":"ruff","status":"passed","new_failures":0}]}
JSON
out=$(converge --rc 0 --round 2 --run-dir "$RD10") || fail "case 10 exited non-zero"
[ "$out" = "proceed" ] || fail "case 10 expected proceed, got '$out'"

# 11. round cap still parks unchanged.
RD11="$TMP_ROOT/rd11"
seed_run_dir "$RD11" $'- resolution: [ID1] rejected — because' '{"round":3,"findings":[{"id":"ID1","severity":"HIGH"}]}'
out=$(converge --rc 1 --round 3 --run-dir "$RD11") || fail "case 11 exited non-zero"
[ "$out" = "park" ] || fail "case 11 expected park, got '$out'"

# 12. multiple reappeared ids are sorted and force park.
RD12="$TMP_ROOT/rd12"
seed_run_dir "$RD12" $'- resolution: [ID1] rejected — because\n- resolution: [ID2] rejected — because' '{"round":2,"findings":[{"id":"ID1","severity":"HIGH"},{"id":"ID2","severity":"CRITICAL"}]}'
out=$(converge --rc 1 --round 2 --run-dir "$RD12") || fail "case 12 exited non-zero"
[ "$out" = "park" ] || fail "case 12 expected park, got '$out'"
grep -Fxq 'non-convergence: blocking finding re-flagged after rejected/deferred disposition: ID1,ID2' "$LOG_FILE" \
  || fail "case 12 stderr must list sorted IDs"

# 13. stale review.json from an earlier round is ignored.
RD13="$TMP_ROOT/rd13"
seed_run_dir "$RD13" $'- resolution: [ID1] rejected — because' '{"round":1,"findings":[{"id":"ID1","severity":"HIGH"}]}'
out=$(converge --rc 1 --round 2 --run-dir "$RD13") || fail "case 13 exited non-zero"
[ "$out" = "revise" ] || fail "case 13 expected revise, got '$out'"

echo "PASS: test_sail_100_convergence_reappearance.sh"
