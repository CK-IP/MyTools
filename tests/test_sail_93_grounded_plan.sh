#!/usr/bin/env bash
# test_sail_93_grounded_plan.sh — issue #93: risk-gated grounded plan pass.
#
# The plan stage gains a repo-exploring grounded pass (mirrors review.py's #66 red-team):
# on a plan-risky spec it shells a TOOL-CAPABLE backend with cwd=target, EVIDENCE-REQUIRED,
# emitting the FULL plan schema so it can both (a) union its evidenced CRITICAL/HIGH risks
# into the author plan and (b) serve as the plan body when the author backend is absent.
# Backend chain: SAIL_PLAN_GROUNDED_CMD (codex) -> author backend (claude) -> blind.
#
# Hermetic per .ship/domain.md: throwaway target, mock backends, env-vars PREFIX the command,
# assertions on exit codes + plan.json only — never live git state.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"

# Hermetic (.ship/domain.md): a real shell exports SAIL_* codex knobs (settings.json) — the
# grounded backend (SAIL_PLAN_GROUNDED_CMD) and the plan adversary (SAIL_PLAN_CMD2) would invoke
# LIVE codex and flake the risky-spec subtests. Subtests that need a backend set it explicitly in
# their command prefix; clear everything else so the test controls its own backends.
unset "${!SAIL_@}"

fail() { echo "FAIL: $*"; exit 1; }

TARGET="$WORK/target"; mkdir -p "$TARGET"

AUTHOR="$WORK/author.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "%s" "${AUTHOR_OUT:-}"' 'exit ${AUTHOR_RC:-0}' > "$AUTHOR"
chmod +x "$AUTHOR"

GROUNDED="$WORK/grounded.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' '[ -n "${GROUNDED_SENTINEL:-}" ] && pwd >> "$GROUNDED_SENTINEL"' 'printf "%s" "${GROUNDED_OUT:-}"' 'exit ${GROUNDED_RC:-0}' > "$GROUNDED"
chmod +x "$GROUNDED"

AUTHOR_CLEAN='{"status":"completed","approach":"do the thing","simpler_alternative":"none","design_alternatives":[],"acceptance_criteria":["a"],"test_plan":[{"behavior":"b","test":"t"}],"risks":[],"scope":{"in":["x"],"out":["y"]},"summary":"clean blind plan"}'
GROUNDED_EVIDENCED='{"status":"completed","approach":"grounded approach","simpler_alternative":"none","design_alternatives":[],"acceptance_criteria":["a"],"test_plan":[{"behavior":"b","test":"t"}],"risks":[{"severity":"HIGH","area":"design","issue":"spec assumes N=9 but doctor.sh lists N=8","evidence":"grep -c pytest doctor.sh -> 8","mitigation":"use N=8"}],"scope":{"in":["x"],"out":["y"]},"summary":"grounded plan with evidenced HIGH"}'
GROUNDED_UNEVIDENCED='{"status":"completed","approach":"grounded approach","simpler_alternative":"none","design_alternatives":[],"acceptance_criteria":["a"],"test_plan":[{"behavior":"b","test":"t"}],"risks":[{"severity":"HIGH","area":"design","issue":"feels wrong","mitigation":"hmm"}],"scope":{"in":["x"],"out":["y"]},"summary":"grounded plan, unevidenced risk"}'
GROUNDED_NOSEV='{"status":"completed","approach":"grounded approach","simpler_alternative":"none","design_alternatives":[],"acceptance_criteria":["a"],"test_plan":[{"behavior":"b","test":"t"}],"risks":[{"area":"design","issue":"missing severity but has evidence","evidence":"grep -> something","mitigation":"y"}],"scope":{"in":["x"],"out":["y"]},"summary":"s"}'

RISKY_SPEC='Tell the user to run ./install.sh, and reconcile the tool list across both files.'
PLAIN_SPEC='Improve the error message when the config file is missing.'

jget() { python3 - "$1" "$2" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
v=d
for k in sys.argv[2].split("."):
    v=v.get(k) if isinstance(v,dict) else None
print(json.dumps(v))
PY
}
assert_status() { local got; got=$(jget "$1" status); [ "$got" = "\"$2\"" ] || fail "$3: status expected $2 got $got"; }
has_grounded_high() {
  python3 - "$1" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
ok=any(isinstance(r,dict) and r.get("severity")=="HIGH" and r.get("lens")=="grounded" for r in d.get("risks",[]))
sys.exit(0 if ok else 1)
PY
}

# T1 — #55-class regression
RD="$WORK/t1"; SEN="$WORK/t1.sen"
set +e
SAIL_PLAN_CMD="$AUTHOR" AUTHOR_OUT="$AUTHOR_CLEAN" \
SAIL_PLAN_GROUNDED_CMD="$GROUNDED" GROUNDED_OUT="$GROUNDED_EVIDENCED" GROUNDED_SENTINEL="$SEN" \
  python3 -m sail plan --target "$TARGET" --run-dir "$RD" <<< "$RISKY_SPEC" >/dev/null 2>&1
RC=$?; set -e
[ "$RC" = "1" ] || fail "T1: evidenced grounded HIGH on a risky spec must block (exit 1), got $RC"
has_grounded_high "$RD/plan.json" || fail "T1: plan.json must carry the HIGH tagged lens=grounded"
{ [ -f "$SEN" ] && grep -qx "$TARGET" "$SEN"; } || fail "T1: grounded backend must run with cwd=target"
echo "PASS T1"

RD="$WORK/t1c"
set +e
SAIL_PLAN_CMD="$AUTHOR" AUTHOR_OUT="$AUTHOR_CLEAN" \
  python3 -m sail plan --target "$TARGET" --run-dir "$RD" <<< "$RISKY_SPEC" >/dev/null 2>&1
RC=$?; set -e
[ "$RC" = "0" ] || fail "T1c: blind-only clean plan must pass (exit 0), got $RC"
echo "PASS T1c"

# T2 — no uniform weight
RD="$WORK/t2"; SEN="$WORK/t2.sen"
set +e
SAIL_PLAN_CMD="$AUTHOR" AUTHOR_OUT="$AUTHOR_CLEAN" \
SAIL_PLAN_GROUNDED_CMD="$GROUNDED" GROUNDED_OUT="$GROUNDED_EVIDENCED" GROUNDED_SENTINEL="$SEN" \
  python3 -m sail plan --target "$TARGET" --run-dir "$RD" <<< "$PLAIN_SPEC" >/dev/null 2>&1
RC=$?; set -e
[ "$RC" = "0" ] || fail "T2: non-risky spec must stay blind & pass (exit 0), got $RC"
[ ! -f "$SEN" ] || fail "T2: grounded backend must NOT run on a non-risky spec"
echo "PASS T2"

# T3 — evidence-required
RD="$WORK/t3"
set +e
SAIL_PLAN_CMD="$AUTHOR" AUTHOR_OUT="$AUTHOR_CLEAN" \
SAIL_PLAN_GROUNDED_CMD="$GROUNDED" GROUNDED_OUT="$GROUNDED_UNEVIDENCED" \
  python3 -m sail plan --target "$TARGET" --run-dir "$RD" <<< "$RISKY_SPEC" >/dev/null 2>&1
RC=$?; set -e
[ "$RC" = "0" ] || fail "T3: unevidenced grounded HIGH must be dropped (exit 0), got $RC"
has_grounded_high "$RD/plan.json" && fail "T3: unevidenced grounded HIGH must NOT appear in risks"
nd=$(jget "$RD/plan.json" grounded.n_dropped); [ "$nd" = "1" ] || fail "T3: grounded.n_dropped expected 1 got $nd"
echo "PASS T3"

# T4 — fallback chain
RD="$WORK/t4"; SEN="$WORK/t4.sen"
set +e
SAIL_PLAN_CMD="$GROUNDED" GROUNDED_OUT="$GROUNDED_EVIDENCED" GROUNDED_SENTINEL="$SEN" AUTHOR_OUT="$GROUNDED_EVIDENCED" \
  python3 -m sail plan --target "$TARGET" --run-dir "$RD" <<< "$RISKY_SPEC" >/dev/null 2>&1
RC=$?; set -e
{ [ -f "$SEN" ] && grep -qx "$TARGET" "$SEN"; } || fail "T4: grounded must run via author fallback with cwd=target"
src=$(jget "$RD/plan.json" grounded.source); [ "$src" = "\"author-fallback\"" ] || fail "T4: grounded.source expected author-fallback got $src"
echo "PASS T4"

# T5 — fail closed
RD="$WORK/t5"
set +e
SAIL_PLAN_CMD="$AUTHOR" AUTHOR_OUT="$AUTHOR_CLEAN" \
SAIL_PLAN_GROUNDED_CMD="$GROUNDED" GROUNDED_OUT="garbage not json" GROUNDED_RC=3 \
  python3 -m sail plan --target "$TARGET" --run-dir "$RD" <<< "$RISKY_SPEC" >/dev/null 2>&1
RC=$?; set -e
[ "$RC" = "1" ] || fail "T5: grounded backend error must fail closed (exit 1), got $RC"
assert_status "$RD/plan.json" error "T5"
echo "PASS T5"

# T6 — clean degrade
RD="$WORK/t6"
set +e
SAIL_PLAN_CMD="$WORK/nonexistent-bin" SAIL_PLAN_GROUNDED_CMD="$WORK/also-missing" \
  python3 -m sail plan --target "$TARGET" --run-dir "$RD" <<< "$RISKY_SPEC" >/dev/null 2>&1
RC=$?; set -e
[ "$RC" = "0" ] || fail "T6: no usable backend must skip cleanly (exit 0), got $RC"
assert_status "$RD/plan.json" skipped "T6"
echo "PASS T6"

# T7 — RT-1: grounded-as-planner
RD="$WORK/t7"; SEN="$WORK/t7.sen"
set +e
SAIL_PLAN_CMD="$WORK/nonexistent-bin" \
SAIL_PLAN_GROUNDED_CMD="$GROUNDED" GROUNDED_OUT="$GROUNDED_EVIDENCED" GROUNDED_SENTINEL="$SEN" \
  python3 -m sail plan --target "$TARGET" --run-dir "$RD" <<< "$RISKY_SPEC" >/dev/null 2>&1
RC=$?; set -e
[ "$RC" = "1" ] || fail "T7: grounded-as-planner with evidenced HIGH must block (exit 1), got $RC"
{ [ -f "$SEN" ] && grep -qx "$TARGET" "$SEN"; } || fail "T7: grounded must run with author backend absent"
role=$(jget "$RD/plan.json" grounded.role); [ "$role" = "\"planner\"" ] || fail "T7: grounded.role expected planner got $role"
ap=$(jget "$RD/plan.json" approach); [ "$ap" = "\"grounded approach\"" ] || fail "T7: plan body must come from grounded plan, got $ap"
echo "PASS T7"

# T8 — explicit severity contract
RD="$WORK/t8"
set +e
SAIL_PLAN_CMD="$AUTHOR" AUTHOR_OUT="$AUTHOR_CLEAN" \
SAIL_PLAN_GROUNDED_CMD="$GROUNDED" GROUNDED_OUT="$GROUNDED_NOSEV" \
  python3 -m sail plan --target "$TARGET" --run-dir "$RD" <<< "$RISKY_SPEC" >/dev/null 2>&1
RC=$?; set -e
[ "$RC" = "0" ] || fail "T8: grounded risk missing severity but with evidence must be dropped (exit 0), got $RC"
has_grounded_high "$RD/plan.json" && fail "T8: grounded risk missing severity must NOT normalize into a HIGH union"
nd=$(jget "$RD/plan.json" grounded.n_dropped); [ "$nd" = "1" ] || fail "T8: grounded.n_dropped expected 1 got $nd"
echo "PASS T8"

echo "ALL PASS: test_sail_93_grounded_plan.sh"
