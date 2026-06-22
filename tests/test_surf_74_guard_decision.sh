#!/usr/bin/env bash
# test_surf_74_guard_decision.sh — issue #74: EXECUTABLE coverage of the /surf pre-merge dual-lens
# guard's decision. Unlike test_surf_74_dual_lens.sh (which pins the surf.md prose), this drives the
# real documented path — `python3 -m sail review --dual-lens` under mocked backends — and asserts the
# guard's documented merge-vs-park decision:  MERGE iff (review exit 0) AND dual_lens_status == "ok".
# Mirrors the hermetic mock-LLM idiom of test_sail_review.sh.
# SC2016: the single-quoted strings written into the mock script are LITERAL by design —
# `${MOCK_OUT:-}` must expand when the mock RUNS, not when this test writes it. Disable file-wide.
# shellcheck disable=SC2016
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"
# Hermeticity: clear inherited backends so each case controls its own (this workspace may set them).
unset SAIL_REVIEW_CMD SAIL_REVIEW_CMD2 SAIL_REDTEAM_CMD 2>/dev/null || true

# Mock LLM CLI: ignores stdin, echoes $MOCK_OUT, exit $MOCK_RC.
MOCK="$WORK/mock.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "%s" "${MOCK_OUT:-}"' 'exit ${MOCK_RC:-0}' > "$MOCK"
chmod +x "$MOCK"

# Tiny git target with a working-tree change to diff against.
TGT="$WORK/t"; mkdir -p "$TGT"
printf 'def f():\n    return 1\n' > "$TGT/m.py"
git -C "$TGT" init -q
git -C "$TGT" add -A
git -C "$TGT" -c user.email=t@t -c user.name=t commit -qm base
printf 'def f():\n    return 2  # changed\n' > "$TGT/m.py"

CLEAN='{"findings":[],"summary":"ok"}'
HIGH='{"findings":[{"severity":"HIGH","category":"correctness","file":"m.py","line":2,"issue":"x","recommendation":"y"}],"summary":"1 high"}'

# The /surf guard decision, exactly as documented in commands/surf.md step 2:
# safe to MERGE iff the compensating review exited 0 AND dual_lens_status(review.json) == "ok".
guard() {  # $1=review.json  $2=review_exit_code  -> prints "merge" | "park"
  python3 -c 'import json,sys; from sail.review import dual_lens_status; d=json.load(open(sys.argv[1])); print("merge" if (sys.argv[2]=="0" and dual_lens_status(d)=="ok") else "park")' "$1" "$2"
}

run() {  # $1=run-dir ; remaining args -> extra `sail review` flags ; env (SAIL_REVIEW_CMD*) set by caller
  local rd="$1"; shift
  set +e; python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$rd" "$@" >/dev/null 2>&1; local rc=$?; set -e
  echo "$rc"
}

# (a) genuine dual-lens, clean → MERGE
RDa="$WORK/a"
rca=$(SAIL_REVIEW_CMD="bash $MOCK" SAIL_REVIEW_CMD2="bash $MOCK" MOCK_OUT="$CLEAN" run "$RDa" --dual-lens)
[ "$(guard "$RDa/review.json" "$rca")" = "merge" ] || { echo "FAIL (a): clean dual-lens must MERGE (rc=$rca)"; exit 1; }
echo "PASS (a): clean genuine dual-lens → merge"

# (b) degraded — second lens backend missing → PARK (the #74 core: never silent single-lens merge)
RDb="$WORK/b"
rcb=$(SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN" run "$RDb" --dual-lens)
[ "$(guard "$RDb/review.json" "$rcb")" = "park" ] || { echo "FAIL (b): degraded (no lens2) must PARK (rc=$rcb)"; exit 1; }
echo "PASS (b): degraded single-lens (no lens2) → park"

# (c) genuine dual-lens but a blocking HIGH finding → PARK (exit code carries the block)
RDc="$WORK/c"
rcc=$(SAIL_REVIEW_CMD="bash $MOCK" SAIL_REVIEW_CMD2="bash $MOCK" MOCK_OUT="$HIGH" run "$RDc" --dual-lens)
[ "$(guard "$RDc/review.json" "$rcc")" = "park" ] || { echo "FAIL (c): dual-lens with HIGH must PARK (rc=$rcc)"; exit 1; }
echo "PASS (c): dual-lens with blocking HIGH → park"

echo "ALL PASS: test_surf_74_guard_decision.sh"
