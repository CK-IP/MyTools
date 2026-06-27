#!/usr/bin/env bash
# test_sail_74_dual_lens_signal.sh — issue #74 (AC#3): review.json must carry a
# machine-readable `dual_lens_requested` boolean alongside the existing `lenses` list,
# so an orchestrator can deterministically distinguish:
#   - dual-lens DEGRADED to single  (dual_lens_requested=true  AND lens2_ran=false)
#   - single-lens BY DESIGN          (dual_lens_requested=false)
# NOTE: keyed off lens2_ran, NOT len(lenses) — a redteam lens makes len==2 while still degraded.
# Hermetic: mock LLM CLI, real `python3 -m sail review`. Mirrors test_sail_review.sh.
# SC2016: the single-quoted strings written into the mock script are LITERAL by design —
# `${MOCK_OUT:-}` must expand when the mock RUNS, not when this test writes it. Disable file-wide.
# shellcheck disable=SC2016
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"
# Hermeticity: clear any inherited review backends so each case controls its own — otherwise a
# globally-set SAIL_REVIEW_CMD2 leaks a real lens2 into the "no second lens" fixtures (#74 round-3).
unset "${!SAIL_@}" 2>/dev/null || true

# Mock LLM CLI: ignores stdin, echoes a clean (no-findings) review, exit 0.
MOCK="$WORK/mock_llm.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "%s" "${MOCK_OUT:-}"' 'exit ${MOCK_RC:-0}' > "$MOCK"
chmod +x "$MOCK"

# Tiny git target with a committed base + a working-tree change to diff against.
TGT="$WORK/target"; mkdir -p "$TGT"
printf 'def f():\n    return 1\n' > "$TGT/mod.py"
git -C "$TGT" init -q
git -C "$TGT" add -A
git -C "$TGT" -c user.email=t@t -c user.name=t commit -qm base
printf 'def f():\n    return 2  # changed\n' > "$TGT/mod.py"

CLEAN_JSON='{"findings":[],"summary":"no issues"}'
field()   { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$1" "$2"; }
nlenses() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("lenses",[])))' "$1"; }

# T1: --dual-lens with a working second backend → requested=true, 2 lenses ran.
RD1="$WORK/rd1"
set +e; SAIL_REVIEW_CMD="bash $MOCK" SAIL_REVIEW_CMD2="bash $MOCK" MOCK_OUT="$CLEAN_JSON" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD1" --dual-lens >/dev/null 2>&1; set -e
[ "$(field "$RD1/review.json" dual_lens_requested)" = "True" ] || { echo "FAIL T1: dual_lens_requested != True"; exit 1; }
[ "$(field "$RD1/review.json" lens2_ran)" = "True" ] || { echo "FAIL T1: lens2_ran != True"; exit 1; }
[ "$(nlenses "$RD1/review.json")" = "2" ] || { echo "FAIL T1: expected 2 lenses"; exit 1; }
echo "PASS T1: dual-lens + lens2 available → requested=true, lens2_ran=true, 2 lenses"

# T2: --dual-lens requested but second backend MISSING → requested=true, 1 lens (DEGRADED, detectable).
RD2="$WORK/rd2"
set +e; SAIL_REVIEW_CMD="bash $MOCK" SAIL_REVIEW_CMD2="/nonexistent/llm-xyz" MOCK_OUT="$CLEAN_JSON" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD2" --dual-lens >/dev/null 2>&1; set -e
[ "$(field "$RD2/review.json" dual_lens_requested)" = "True" ] || { echo "FAIL T2: dual_lens_requested != True"; exit 1; }
[ "$(field "$RD2/review.json" lens2_ran)" = "False" ] || { echo "FAIL T2: lens2_ran != False on degraded run"; exit 1; }
[ "$(nlenses "$RD2/review.json")" = "1" ] || { echo "FAIL T2: expected 1 lens (degraded)"; exit 1; }
echo "PASS T2: dual-lens requested + lens2 missing → requested=true, lens2_ran=false (degradation detectable)"

# T3: no --dual-lens → requested=false (single-lens BY DESIGN, not a degradation).
RD3="$WORK/rd3"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD3" >/dev/null 2>&1; set -e
[ "$(field "$RD3/review.json" dual_lens_requested)" = "False" ] || { echo "FAIL T3: dual_lens_requested != False"; exit 1; }
[ "$(field "$RD3/review.json" lens2_ran)" = "False" ] || { echo "FAIL T3: lens2_ran != False"; exit 1; }
echo "PASS T3: no dual-lens → requested=false, lens2_ran=false (design, not degradation)"

# T4: the /surf guard's degradation classifier is the SHIPPED function `dual_lens_status`
# (sail.review) — applied to the REAL review.json artifacts produced above (no re-implementation).
python3 - "$RD2/review.json" "$RD3/review.json" <<'PY'
import json, sys
from sail.review import dual_lens_status
deg = json.load(open(sys.argv[1])); des = json.load(open(sys.argv[2]))
assert dual_lens_status(deg) == "degraded",         "real degraded run must classify degraded"
assert dual_lens_status(des) == "single-by-design", "by-design single-lens must NOT be degraded"
print("PASS T4: dual_lens_status() classifies real degraded vs by-design artifacts correctly")
PY

# T5: truth table of the SHIPPED classifier dual_lens_status — the single source of truth the
# /surf pre-merge guard calls to decide degraded vs ok vs single-by-design. (Blocking is the
# engine's own exit code, NOT re-derived here — see the guard in commands/surf.md.)
python3 - <<'PY'
from sail.review import dual_lens_status
assert dual_lens_status({"dual_lens_requested": False}) == "single-by-design"
assert dual_lens_status({"dual_lens_requested": True, "lens2_ran": True}) == "ok"
assert dual_lens_status({"dual_lens_requested": True, "lens2_ran": False}) == "degraded"
# keyed off lens2_ran, NOT len(lenses): lens1+redteam with no lens2 is still degraded.
assert dual_lens_status({"dual_lens_requested": True, "lens2_ran": False,
                         "lenses": ["lens1", "redteam"]}) == "degraded"
print("PASS T5: dual_lens_status truth table (shipped classifier)")
PY

# T6: REAL review.json with an extra (redteam) lens but NO lens2 — proves the classifier keys off
# lens2_ran, not list length, against an artifact the CODE actually produced (not a hand-built dict).
RD6="$WORK/rd6"
set +e; SAIL_REVIEW_CMD="bash $MOCK" SAIL_REDTEAM_CMD="bash $MOCK" MOCK_OUT="$CLEAN_JSON" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD6" --dual-lens --red-team >/dev/null 2>&1; set -e
python3 - "$RD6/review.json" <<'PY'
import json, sys
from sail.review import dual_lens_status
d = json.load(open(sys.argv[1]))
lenses = d.get("lenses", [])
assert "lens2" not in lenses, "fixture must have NO lens2: %r" % lenses
assert len(lenses) >= 2, "fixture must carry an extra non-lens2 lens (redteam): %r" % lenses
assert d.get("dual_lens_requested") is True and d.get("lens2_ran") is False, "want requested+no-lens2"
assert dual_lens_status(d) == "degraded", "real lens1+redteam (no lens2) must classify degraded"
print("PASS T6: real review.json with extra lens, no lens2 → degraded (length-independent)")
PY
echo "ALL PASS: test_sail_74_dual_lens_signal.sh"
