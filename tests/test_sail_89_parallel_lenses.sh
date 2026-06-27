#!/usr/bin/env bash
# test_sail_89_parallel_lenses.sh — issue #89: parallelize the mutually-independent
# LLM passes so per-stage wall-clock is bound by the SLOWEST pass, not the SUM.
#   Review stage: lens1 ‖ lens2 ‖ tidiness (‖ redteam) dispatched concurrently;
#                 union/blocking/tagging/degrade-clean semantics UNCHANGED.
#   Plan stage:   author ‖ plan-adversary dispatched concurrently; union UNCHANGED.
#
# Concurrency is asserted by OVERLAP of the passes' execution intervals (the precise,
# timing-jitter-robust signal): each stub records [start,end] epoch-ns; concurrent
# dispatch makes the intervals overlap (max(start) < min(end)); serial dispatch makes
# them disjoint (max(start) >= min(end)). Semantics are pinned by separate regression
# guards. Hermetic: mock LLM CLIs via env, real `python3 -m sail`, throwaway git target.
# SC2016: single-quoted strings written into stub scripts are LITERAL by design — the
# env refs must expand when the stub RUNS, not when this test writes it.
# shellcheck disable=SC2016
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"
# Hermeticity: clear any inherited backends so each case controls its own.
unset "${!SAIL_@}" 2>/dev/null || true
export SAIL_CHECKERS=ruff,pytest   # keep deterministic-gate noise out of the review arm

fail() { echo "FAIL: $*"; exit 1; }

SLEEP_S=2          # per-pass stub sleep; serial=N*SLEEP_S, concurrent=~SLEEP_S
TIMING="$WORK/timing.log"

# A timestamped stub: record "<TAG> START <ns>", sleep, record "<TAG> END <ns>", emit JSON.
# $TAG/$OUT are baked per-stub (env can't differ per child of one sail process); $TIMING/$SLEEP_S shared.
make_stub() {  # $1=path  $2=tag  $3=output-json
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'cat >/dev/null' \
    "TAG='$2'" \
    "OUT='$3'" \
    'python3 -c "import time;print(\"$TAG START \"+str(time.time_ns()))" >> "$TIMING"' \
    'sleep "${SLEEP_S:-2}"' \
    'python3 -c "import time;print(\"$TAG END \"+str(time.time_ns()))" >> "$TIMING"' \
    'printf "%s" "$OUT"' \
    'exit 0' > "$1"
  chmod +x "$1"
}

# Overlap checker: every recorded pass-interval must MUTUALLY overlap (concurrent).
# Disjoint intervals (serial) => max(start) >= min(end) => assertion fails.
overlap_ok() {  # $1=timing-file  $2=expected-pass-count
  python3 - "$1" "$2" <<'PY'
import sys, collections
path, want = sys.argv[1], int(sys.argv[2])
iv = collections.defaultdict(dict)
for line in open(path):
    parts = line.split()
    if len(parts) != 3:
        continue
    tag, kind, ns = parts[0], parts[1], int(parts[2])
    iv[tag]["s" if kind == "START" else "e"] = ns
intervals = [(v["s"], v["e"]) for v in iv.values() if "s" in v and "e" in v]
if len(intervals) != want:
    print(f"expected {want} pass-intervals, got {len(intervals)}: {sorted(iv)}")
    sys.exit(2)
max_start = max(s for s, _ in intervals)
min_end = min(e for _, e in intervals)
if max_start < min_end:
    sys.exit(0)        # overlap → concurrent
print(f"intervals disjoint (serial): max_start={max_start} >= min_end={min_end}")
sys.exit(1)
PY
}

field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$1" "$2"; }

# Throwaway git target: committed base + a tiny (NOT high-stakes) working-tree change.
TGT="$WORK/target"; mkdir -p "$TGT"
printf 'def f():\n    return 1\n' > "$TGT/mod.py"
git -C "$TGT" init -q
git -C "$TGT" add -A
git -C "$TGT" -c user.email=t@t -c user.name=t commit -qm base
printf 'def f():\n    return 2  # changed\n' > "$TGT/mod.py"

CLEAN_FIND='{"findings":[],"summary":"clean"}'
CLEAN_TIDY='{"findings":[],"summary":"clean"}'

# ───────────────────────── T1: review lens1 ‖ lens2 ‖ tidiness concurrent ─────────────────────────
make_stub "$WORK/lens1.sh"    L1   "$CLEAN_FIND"
make_stub "$WORK/lens2.sh"    L2   "$CLEAN_FIND"
make_stub "$WORK/tidy.sh"     TIDY "$CLEAN_TIDY"
: > "$TIMING"
RD1="$WORK/rd1"
set +e
SLEEP_S="$SLEEP_S" TIMING="$TIMING" \
  SAIL_REVIEW_CMD="bash $WORK/lens1.sh" \
  SAIL_REVIEW_CMD2="bash $WORK/lens2.sh" \
  SAIL_TIDINESS_CMD="bash $WORK/tidy.sh" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD1" --dual-lens --tidiness >/dev/null 2>&1
rc=$?
set -e
[ -f "$RD1/review.json" ] || fail "T1: review.json not written"
[ "$(field "$RD1/review.json" lens2_ran)" = "True" ] || fail "T1: lens2 must have run"
overlap_ok "$TIMING" 3 || fail "T1: review passes (lens1/lens2/tidiness) did NOT run concurrently"
echo "PASS T1: review lens1 ‖ lens2 ‖ tidiness dispatched concurrently (intervals overlap)"

# ───────────────────────── T2: review union / tagging / blocking UNCHANGED ─────────────────────────
HIGH_L1='{"findings":[{"severity":"HIGH","category":"correctness","file":"mod.py","line":2,"issue":"h1","recommendation":"r1"}],"summary":"1 high"}'
MED_L2='{"findings":[{"severity":"MEDIUM","category":"correctness","file":"mod.py","line":2,"issue":"m2","recommendation":"r2"}],"summary":"1 med"}'
make_stub "$WORK/lens1b.sh" L1 "$HIGH_L1"
make_stub "$WORK/lens2b.sh" L2 "$MED_L2"
make_stub "$WORK/tidyb.sh"  TIDY "$CLEAN_TIDY"
RD2="$WORK/rd2"
set +e
SLEEP_S=0 TIMING="$WORK/t2.log" \
  SAIL_REVIEW_CMD="bash $WORK/lens1b.sh" \
  SAIL_REVIEW_CMD2="bash $WORK/lens2b.sh" \
  SAIL_TIDINESS_CMD="bash $WORK/tidyb.sh" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD2" --dual-lens --tidiness >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "1" ] || fail "T2: a HIGH finding must block (expected exit 1, got $rc)"
python3 - "$RD2/review.json" <<'PY' || fail "T2: union/tagging not preserved"
import json, sys
d = json.load(open(sys.argv[1]))
findings = d["findings"]
lenses = {f.get("lens") for f in findings}
assert "lens1" in lenses, f"missing lens1 tag: {lenses}"
assert "lens2" in lenses, f"missing lens2 tag: {lenses}"
assert any(f["severity"] == "HIGH" and f["lens"] == "lens1" for f in findings), "lens1 HIGH missing"
assert any(f["severity"] == "MEDIUM" and f["lens"] == "lens2" for f in findings), "lens2 MEDIUM missing"
assert d["counts"]["HIGH"] == 1 and d["counts"]["MEDIUM"] == 1, f"counts wrong: {d['counts']}"
assert "tidiness" in d and d["tidiness"]["status"] == "completed", "tidiness block missing/incomplete"
assert d["lens2_ran"] is True and d["dual_lens_requested"] is True
PY
echo "PASS T2: review union + per-lens tagging + blocking + tidiness-separation preserved"

# ───────────────────────── T3: review degrade-clean (lens2 backend missing) ─────────────────────────
RD3="$WORK/rd3"
set +e
SLEEP_S=0 \
  SAIL_REVIEW_CMD="bash $WORK/lens1.sh" \
  SAIL_REVIEW_CMD2="/nonexistent/llm-xyz" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD3" --dual-lens >/dev/null 2>&1
set -e
[ "$(field "$RD3/review.json" dual_lens_requested)" = "True" ] || fail "T3: dual_lens_requested != True"
[ "$(field "$RD3/review.json" lens2_ran)" = "False" ] || fail "T3: lens2_ran must be False (degraded)"
[ "$(field "$RD3/review.json" status)" = "completed" ] || fail "T3: missing-backend degrade must NOT error"
echo "PASS T3: review degrades cleanly when 2nd backend absent (requested=true, lens2_ran=false, no error)"

# ───────────────────────── T4: plan author ‖ adversary concurrent ─────────────────────────
PLAN_OK='{"status":"completed","approach":"do the thing","simpler_alternative":"","design_alternatives":[],"acceptance_criteria":["ac1"],"test_plan":[],"risks":[],"scope":{"in":[],"out":[]},"summary":"ok"}'
ADV_CLEAN='{"risks":[]}'
make_stub "$WORK/author.sh" AUTH "$PLAN_OK"
make_stub "$WORK/adv.sh"    ADV  "$ADV_CLEAN"
: > "$TIMING"
RD4="$WORK/rd4"
set +e
SLEEP_S="$SLEEP_S" TIMING="$TIMING" \
  SAIL_PLAN_CMD="bash $WORK/author.sh" \
  SAIL_PLAN_CMD2="bash $WORK/adv.sh" \
  bash -c 'printf "%s" "build a feature" | python3 -m sail plan --target "'"$TGT"'" --run-dir "'"$RD4"'" --plan-adversary' >/dev/null 2>&1
rc=$?
set -e
[ -f "$RD4/plan.json" ] || fail "T4: plan.json not written"
[ "$(field "$RD4/plan.json" status)" = "completed" ] || fail "T4: plan status not completed"
overlap_ok "$TIMING" 2 || fail "T4: plan author + adversary did NOT run concurrently"
echo "PASS T4: plan author ‖ adversary dispatched concurrently (intervals overlap)"

# ───────────────────────── T5: plan adversary union / tagging UNCHANGED ─────────────────────────
ADV_HIGH='{"risks":[{"severity":"HIGH","area":"design","issue":"adv-risk","mitigation":"m"}]}'
make_stub "$WORK/author5.sh" AUTH "$PLAN_OK"
make_stub "$WORK/adv5.sh"    ADV  "$ADV_HIGH"
RD5="$WORK/rd5"
set +e
SLEEP_S=0 \
  SAIL_PLAN_CMD="bash $WORK/author5.sh" \
  SAIL_PLAN_CMD2="bash $WORK/adv5.sh" \
  bash -c 'printf "%s" "build a feature" | python3 -m sail plan --target "'"$TGT"'" --run-dir "'"$RD5"'" --plan-adversary' >/dev/null 2>&1
set -e
python3 - "$RD5/plan.json" <<'PY' || fail "T5: adversary union/tagging not preserved"
import json, sys
d = json.load(open(sys.argv[1]))
risks = d.get("risks", [])
assert any(r.get("lens") == "adversary" and r.get("severity") == "HIGH" for r in risks), \
    f"adversary HIGH risk not unioned/tagged: {risks}"
PY
echo "PASS T5: plan adversary risks unioned + tagged lens=adversary (preserved)"

# ───────────────────────── T6: plan degrade-clean (adversary backend missing) ─────────────────────────
RD6="$WORK/rd6"
set +e
SLEEP_S=0 \
  SAIL_PLAN_CMD="bash $WORK/author.sh" \
  SAIL_PLAN_CMD2="/nonexistent/plan-adv-xyz" \
  bash -c 'printf "%s" "build a feature" | python3 -m sail plan --target "'"$TGT"'" --run-dir "'"$RD6"'" --plan-adversary' >/dev/null 2>&1
set -e
[ "$(field "$RD6/plan.json" status)" = "completed" ] || fail "T6: missing adversary backend must degrade cleanly (status completed)"
echo "PASS T6: plan degrades cleanly when adversary backend absent (single-pass, no error)"

echo "ALL PASS: test_sail_89_parallel_lenses.sh"
