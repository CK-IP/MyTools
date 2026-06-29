#!/usr/bin/env bash
# test_surf_worker.sh — unit tests for config/surf-worker.sh, the thin helpers for /surf's
# harness-backgrounded worker (#124). Sources the helper and drives its functions with fixtures.
# Asserts: numeric-id injection guard; surf_worker_command emits the exact injection-safe
# `/sail <n> --unattended` command (and refuses a non-numeric id); NO pure-bash daemonization /
# process-group kill / pid-file liveness remains (the harness owns the worker lifecycle); the
# FAIL-CLOSED result/merge contract read from /sail's durable run-dir artifacts (run-state.json
# gates + review.json status/findings/non-empty-ACs-all-met/tidiness + the R7-2 currency check),
# NEVER the claude -p exit code; and safe cleanup (no rm -rf, git worktree remove without --force).
#
# `pass`/`fail` always succeed (echo + arithmetic increment), so the SC2015 "C may run when A is
# true" caveat does not apply to the `[ … ] && pass … || fail …` idiom here; disable it file-wide.
# shellcheck disable=SC2015
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKER_SRC="$SRC_DIR/config/surf-worker.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

[ -f "$WORKER_SRC" ] || { echo "FAIL: surf-worker.sh not found at $WORKER_SRC"; exit 1; }

# --- source-level (static) assertions on the helper itself --------------------
# Inspect CODE ONLY (strip whole-line comments) so the helper's explanatory comments — which by
# design mention what was REMOVED (setsid, worker.pid, --force, the deleted functions) — never trip
# a "still present" grep. Inline trailing comments in this helper carry no banned tokens.
WORKER_CODE="$(grep -vE '^[[:space:]]*#' "$WORKER_SRC")"

# Cleanup must never rm -rf, and must use git worktree remove WITHOUT --force.
if ! printf '%s' "$WORKER_CODE" | grep -q 'rm -rf'; then pass "helper never uses 'rm -rf'"; else fail "helper uses 'rm -rf' (unsafe cleanup)"; fi
if printf '%s' "$WORKER_CODE" | grep -q 'worktree remove' && ! printf '%s' "$WORKER_CODE" | grep -qE 'worktree remove.*--force|--force.*worktree remove'; then
  pass "git worktree remove used WITHOUT --force"
else
  fail "git worktree remove missing or uses --force"
fi
# No eval.
if ! printf '%s' "$WORKER_CODE" | grep -qE '(^|[^[:alnum:]_])eval([^[:alnum:]_]|$)'; then pass "helper contains no 'eval'"; else fail "helper uses 'eval'"; fi
# #124 final decision: NO pure-bash worker daemonization remains — the harness backgrounds the
# worker (run_in_background) and owns its kill. So the helper CODE must NOT fork/daemonize or do its
# own process-group kill / pid-file liveness.
if ! printf '%s' "$WORKER_CODE" | grep -qE 'setsid|set -m|kill -TERM|kill -KILL|kill -0|-pgid|worker\.pid|surf_worker_pgkill|surf_worker_wait|surf_worker_start_token|surf_worker_identity_ok'; then
  pass "no pure-bash daemonization / process-group kill / pid-file liveness in the helper code"
else
  fail "helper code still contains bash daemonization or process-group-kill mechanics (should be harness-owned)"
fi
# The deleted functions must be gone.
if ! grep -qE '^surf_worker_(spawn|pgkill|wait|start_token|identity_ok)\(\)' "$WORKER_SRC"; then
  pass "obsolete spawn/pgkill/wait/start_token/identity_ok functions removed"
else
  fail "an obsolete bash-daemonization function is still defined"
fi
# The command emitter exists.
if grep -qE '^surf_worker_command\(\)' "$WORKER_SRC"; then pass "surf_worker_command emitter present"; else fail "surf_worker_command emitter missing"; fi
# #124 R2-1: result contract reads /sail's durable artifacts (run-state.json + wip-handoff.md),
# not the claude exit code as the green signal.
if grep -q 'run-state.json' "$WORKER_SRC" && grep -q 'wip-handoff.md' "$WORKER_SRC"; then
  pass "result contract reads run-state.json + wip-handoff.md (not the exit code)"
else
  fail "result contract does not read run-state.json + wip-handoff.md"
fi

# --- behavioral assertions: source the helper and call its functions ----------
# shellcheck source=/dev/null
source "$WORKER_SRC"

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT   # the TEST may clean its own tmpdir; the helper under test must not.

# (1) surf_worker_command — numeric id emits the EXACT injection-safe worker command; a non-numeric
# / injection id is REFUSED (the supervisor must not run anything), and nothing is forked.
CMD="$(surf_worker_command 42 2>/dev/null || true)"
if [ "$CMD" = 'claude --dangerously-bypass-permissions -p "/sail 42 --unattended"' ]; then
  pass "(1) surf_worker_command 42 → exact /sail 42 --unattended command"
else
  fail "(1) surf_worker_command emitted unexpected text: '$CMD'"
fi
# (1b) injection guard: a non-numeric id is rejected (non-zero) and emits no command.
OUT="$(surf_worker_command '5; rm -rf /tmp/should_not_happen' 2>/dev/null || true)"
if [ -z "$OUT" ]; then pass "(1b) non-numeric/injection id → rejected, no command emitted"; else fail "(1b) injection id wrongly emitted: '$OUT'"; fi
if surf_worker_command '5; rm -rf x' >/dev/null 2>&1; then fail "(1b) command emitter returned 0 on a bad id"; else pass "(1b) command emitter returns non-zero on a bad id"; fi
[ ! -e /tmp/should_not_happen ] && pass "(1b) no injection side effect" || fail "(1b) injection side effect fired"
# (1c) an answer-file is referenced by PATH only (never inlined as answer text).
CMDF="$(surf_worker_command 7 /tmp/surf-answers-7.md 2>/dev/null || true)"
if printf '%s' "$CMDF" | grep -q '/tmp/surf-answers-7.md' && printf '%s' "$CMDF" | grep -q '/sail 7 --unattended'; then
  pass "(1c) answer-file referenced by path in the emitted command"
else
  fail "(1c) answer-file path not referenced as expected: '$CMDF'"
fi

# --- (2)-(4): the #124 R2-1 RESULT/merge contract is FAIL-CLOSED and reads /sail's DURABLE
# run-dir artifacts (run-state.json gates + review.json findings + wip-handoff.md), NEVER the
# claude -p process exit code (which reflects the claude process, not /sail's terminus).

# #124 R7-2: surf_worker_result now also enforces review CURRENCY (diff_hash/plan_hash/target must
# match the live diff via sail.review.diff_fingerprint/plan_fingerprint). A synthetic review.json can
# no longer be "green" — it must be CURRENT against a real worktree. So the green-path fixtures are
# built from a REAL tiny git repo + a REAL review.json produced by sail.review.run_review (mock
# backend). make_real_green echoes the run-dir; the worktree root is the shared $GREEN_REPO.
GREEN_REPO="$FIX/green-repo"
GREEN_RUNSTATE='{"schema_version":1,"run_id":"t","started_at":"x","gates":[{"name":"ruff","status":"passed","rc":0},{"name":"pytest","status":"skipped","rc":0}]}'

# Set up ONE real git worktree the green run-dirs are fingerprinted against. Returns non-zero if git
# is unavailable (callers then skip the currency-bearing green cases).
setup_green_repo() {
  command -v git >/dev/null 2>&1 || return 1
  [ -d "$GREEN_REPO/.git" ] && return 0
  mkdir -p "$GREEN_REPO"
  git -C "$GREEN_REPO" init -q || return 1
  printf 'def f():\n    return 1\n' >"$GREEN_REPO/m.py"
  git -C "$GREEN_REPO" add -A; git -C "$GREEN_REPO" -c user.email=t@t -c user.name=t commit -qm base
  printf 'def f():\n    return 2\n' >"$GREEN_REPO/m.py"
  git -C "$GREEN_REPO" add -A; git -C "$GREEN_REPO" -c user.email=t@t -c user.name=t commit -qm change
  return 0
}

# make_real_green <run-dir> : write a green run-state.json AND a REAL, CURRENT review.json (status
# completed, no findings, one met AC, no blocking tidiness, diff_hash/plan_hash/target matching the
# live $GREEN_REPO diff vs HEAD~1) via sail.review.run_review with a mock backend.
make_real_green() {
  local rd="$1"; mkdir -p "$rd"
  printf '%s\n' "$GREEN_RUNSTATE" >"$rd/run-state.json"
  printf '%s\n' '{"status":"completed","acceptance_criteria":["the function returns 2"]}' >"$rd/plan.json"
  local mock="$rd/mock.sh"
  cat >"$mock" <<'MK'
#!/usr/bin/env bash
cat >/dev/null
cat <<'JSON'
{"findings": [], "ac_results": [{"criterion": "the function returns 2", "status": "met", "evidence": "return 2"}], "summary": "clean"}
JSON
MK
  chmod +x "$mock"
  SAIL_REVIEW_CMD="$mock" python3 - "$GREEN_REPO" "$rd" "$SRC_DIR" <<'PY' >/dev/null 2>&1
import sys; sys.path.insert(0, sys.argv[3])
from sail.review import run_review
run_review(sys.argv[1], "HEAD~1", run_dir=sys.argv[2], dual_lens=False)
PY
}

GREEN_OK=0
if setup_green_repo; then GREEN_OK=1; fi

# Synthetic green review (status/findings/ACs/tidiness all green) — used ONLY for PARK-arm tests
# that corrupt one EARLIER-checked field and never reach the currency check. Green-RESULT tests use
# make_real_green (a CURRENT review) instead, since R7-2 now also enforces diff/plan/target currency.
GREEN_REVIEW='{"status":"completed","findings":[],"plan_verification":{"status":"verified","acceptance_criteria":[{"criterion":"a","status":"met"}]},"tidiness":{"status":"completed","blocking":[]}}'
gs() {  # gs <run-dir> — synthetic (NOT currency-fresh; only valid for park-before-currency arms)
  mkdir -p "$1"
  printf '%s\n' "$GREEN_RUNSTATE" >"$1/run-state.json"
  printf '%s\n' "$GREEN_REVIEW" >"$1/review.json"
}

# (2) GREEN: a REAL current run-dir (green gates + clean+CURRENT review) → green (the verdict comes
# from the durable artifacts, NOT the exit code — proven by (2b)/(2c) which vary the exit code arg).
if [ "$GREEN_OK" -eq 1 ]; then
  RD0="$FIX/runs/100"; make_real_green "$RD0"
  if surf_worker_result "$RD0" 0 "$GREEN_REPO"; then pass "(2) green+current run-dir → green"; else fail "(2) positively-green current run wrongly parked"; fi

  # (2b) #124 R5-1: the exit code is IGNORED. A green+current run-dir with a NON-ZERO exit code arg
  # is STILL green (the macOS set-m spawn returns 127 on a clean exit — must not park on that).
  RD0b="$FIX/runs/100b"; make_real_green "$RD0b"
  if surf_worker_result "$RD0b" 127 "$GREEN_REPO"; then pass "(2b) green+current + nonzero exit → still green (exit code ignored)"; else fail "(2b) exit code wrongly forced a park on a green run-dir"; fi

  # (2d) result works with NO exit-code arg (poll model: artifacts are the sole input).
  RD0d="$FIX/runs/100d"; make_real_green "$RD0d"
  if surf_worker_result "$RD0d" "" "$GREEN_REPO"; then pass "(2d) result decides from artifacts with no exit-code arg"; else fail "(2d) result requires an exit-code arg (regression)"; fi
else
  pass "(2) git unavailable — skipped green+current cases (2/2b/2d)"
fi

# (2c) #124 R5-1: a PARKED run-dir with a CLEAN exit code (0) still parks — artifact-driven in both
# directions. (wip-handoff parks before the currency check, so a synthetic run-dir is fine here.)
RD0c="$FIX/runs/100c"; gs "$RD0c"
printf '# /sail WIP handoff\n- stop reason: parked\n' >"$RD0c/wip-handoff.md"
if surf_worker_result "$RD0c" 0; then fail "(2c) clean exit wrongly merged a parked run-dir"; else pass "(2c) parked run-dir + exit 0 → park (exit code ignored)"; fi

# (3) PARK on a wip-handoff.md (the run PARKED) — even with green gates + clean review present.
RD1="$FIX/runs/101"; gs "$RD1"
printf '# /sail WIP handoff\n- stop reason: parked\n' >"$RD1/wip-handoff.md"
if surf_worker_result "$RD1" 0; then fail "(3) wip-handoff present wrongly merged"; else pass "(3) wip-handoff.md present → park"; fi

# (3b) PARK on a FAILED gate in run-state.json (exit 0 does not prove the terminus).
RD2="$FIX/runs/102"; mkdir -p "$RD2"
printf '%s\n' '{"gates":[{"name":"ruff","status":"passed"},{"name":"pytest","status":"failed"}]}' >"$RD2/run-state.json"
printf '%s\n' '{"findings":[]}' >"$RD2/review.json"
if surf_worker_result "$RD2" 0; then fail "(3b) failed gate wrongly merged"; else pass "(3b) failed gate in run-state.json → park"; fi

# (3c) PARK on a CRITICAL/HIGH finding in review.json (parks at the findings arm, before currency).
RD2c="$FIX/runs/102c"; gs "$RD2c"
printf '%s\n' '{"status":"completed","findings":[{"severity":"HIGH","msg":"x"}],"plan_verification":{"acceptance_criteria":[{"criterion":"a","status":"met"}]},"tidiness":{"blocking":[]}}' >"$RD2c/review.json"
if surf_worker_result "$RD2c" 0; then fail "(3c) HIGH finding wrongly merged"; else pass "(3c) HIGH finding in review.json → park"; fi

# (4) FAIL-CLOSED on ambiguity: MISSING run-state.json → park (never merge an unconfirmed run).
RD3="$FIX/runs/103"; mkdir -p "$RD3"   # no run-state.json, no review.json at all
if surf_worker_result "$RD3" 0; then fail "(4) missing run-state wrongly merged"; else pass "(4) missing run-state.json → fail-closed park"; fi
# (4b) FAIL-CLOSED on GARBAGE run-state.json → park.
RD4="$FIX/runs/104"; mkdir -p "$RD4"
printf 'not json at all {{{\n' >"$RD4/run-state.json"
printf '%s\n' "$GREEN_REVIEW" >"$RD4/review.json"
if surf_worker_result "$RD4" 0; then fail "(4b) garbage run-state wrongly merged"; else pass "(4b) garbage run-state.json → fail-closed park"; fi
# (4c) FAIL-CLOSED: green gates but MISSING review.json → cannot confirm review clean → park.
RD4c="$FIX/runs/104c"; mkdir -p "$RD4c"
printf '%s\n' '{"gates":[{"name":"ruff","status":"passed"}]}' >"$RD4c/run-state.json"
if surf_worker_result "$RD4c" 0; then fail "(4c) missing review wrongly merged"; else pass "(4c) green gates + missing review.json → fail-closed park"; fi

# --- #124 R3-1: green must mirror /sail's FULL green definition (not a subset). ---------------
# (R3-1a) review.json status:"skipped" → park (a skipped/error review is not a confirmed green).
RDr1="$FIX/runs/110"; gs "$RDr1"
printf '%s\n' '{"status":"skipped","reason":"no LLM backend","findings":[]}' >"$RDr1/review.json"
if surf_worker_result "$RDr1" 0; then fail "(R3-1a) skipped review wrongly merged"; else pass "(R3-1a) review status:skipped → park"; fi

# (R3-1b) an UNMET plan_verification acceptance criterion → park (the #47 traceability spine).
RDr2="$FIX/runs/111"; gs "$RDr2"
printf '%s\n' '{"status":"completed","findings":[],"plan_verification":{"status":"verified","acceptance_criteria":[{"criterion":"a","status":"met"},{"criterion":"b","status":"unmet"}]},"tidiness":{"blocking":[]}}' >"$RDr2/review.json"
if surf_worker_result "$RDr2" 0; then fail "(R3-1b) unmet AC wrongly merged"; else pass "(R3-1b) unmet plan_verification AC → park"; fi

# (R3-1b2) an UNKNOWN acceptance criterion likewise → park.
RDr2b="$FIX/runs/111b"; gs "$RDr2b"
printf '%s\n' '{"status":"completed","findings":[],"plan_verification":{"acceptance_criteria":[{"criterion":"a","status":"unknown"}]},"tidiness":{"blocking":[]}}' >"$RDr2b/review.json"
if surf_worker_result "$RDr2b" 0; then fail "(R3-1b2) unknown AC wrongly merged"; else pass "(R3-1b2) unknown plan_verification AC → park"; fi

# (R3-1c) a non-empty tidiness.blocking (confirmed block-tier finding) → park.
RDr3="$FIX/runs/112"; gs "$RDr3"
printf '%s\n' '{"status":"completed","findings":[],"plan_verification":{"acceptance_criteria":[{"criterion":"a","status":"met"}]},"tidiness":{"status":"completed","blocking":[{"id":"t1","tier":"block"}]}}' >"$RDr3/review.json"
if surf_worker_result "$RDr3" 0; then fail "(R3-1c) blocking tidiness wrongly merged"; else pass "(R3-1c) non-empty tidiness.blocking → park"; fi

# (R3-1d) the all-green case (status completed, no findings, all ACs met, no blocking tidiness,
# review CURRENT) → green.
if [ "$GREEN_OK" -eq 1 ]; then
  RDr4="$FIX/runs/113"; make_real_green "$RDr4"
  if surf_worker_result "$RDr4" 0 "$GREEN_REPO"; then pass "(R3-1d) full /sail-green+current run-dir → green"; else fail "(R3-1d) full-green run wrongly parked"; fi
else
  pass "(R3-1d) git unavailable — skipped full-green case"
fi

# --- #124 R3-2: defensive SHAPE guards (fail-closed), never crash, never pass. ----------------
# (R3-2a) findings:null → park.
RDs1="$FIX/runs/120"; gs "$RDs1"
printf '%s\n' '{"status":"completed","findings":null,"plan_verification":{"acceptance_criteria":[{"criterion":"a","status":"met"}]},"tidiness":{"blocking":[]}}' >"$RDs1/review.json"
if surf_worker_result "$RDs1" 0; then fail "(R3-2a) findings:null wrongly merged"; else pass "(R3-2a) findings:null (non-list) → park"; fi

# (R3-2b) findings:"x" (non-list string) → park.
RDs2="$FIX/runs/121"; gs "$RDs2"
printf '%s\n' '{"status":"completed","findings":"x","plan_verification":{"acceptance_criteria":[{"criterion":"a","status":"met"}]},"tidiness":{"blocking":[]}}' >"$RDs2/review.json"
if surf_worker_result "$RDs2" 0; then fail "(R3-2b) findings:string wrongly merged"; else pass "(R3-2b) findings:\"x\" (non-list) → park"; fi

# (R3-2c) plan_verification not a dict → park.
RDs3="$FIX/runs/122"; gs "$RDs3"
printf '%s\n' '{"status":"completed","findings":[],"plan_verification":"nope","tidiness":{"blocking":[]}}' >"$RDs3/review.json"
if surf_worker_result "$RDs3" 0; then fail "(R3-2c) plan_verification non-dict wrongly merged"; else pass "(R3-2c) plan_verification non-dict → park"; fi

# (R3-2d) acceptance_criteria not a list → park.
RDs4="$FIX/runs/123"; gs "$RDs4"
printf '%s\n' '{"status":"completed","findings":[],"plan_verification":{"acceptance_criteria":"nope"},"tidiness":{"blocking":[]}}' >"$RDs4/review.json"
if surf_worker_result "$RDs4" 0; then fail "(R3-2d) acceptance_criteria non-list wrongly merged"; else pass "(R3-2d) acceptance_criteria non-list → park"; fi

# (R3-2e) tidiness not a dict → park.
RDs5="$FIX/runs/124"; gs "$RDs5"
printf '%s\n' '{"status":"completed","findings":[],"plan_verification":{"acceptance_criteria":[{"criterion":"a","status":"met"}]},"tidiness":"nope"}' >"$RDs5/review.json"
if surf_worker_result "$RDs5" 0; then fail "(R3-2e) tidiness non-dict wrongly merged"; else pass "(R3-2e) tidiness non-dict → park"; fi

# (R3-2f) tidiness ABSENT (not run) + everything else green+current → green (absent is allowed,
# only a non-empty blocking list parks). Start from a real green, then strip the tidiness key
# (preserving the currency-bearing diff_hash/plan_hash/target fields).
if [ "$GREEN_OK" -eq 1 ]; then
  RDs6="$FIX/runs/125"; make_real_green "$RDs6"
  python3 - "$RDs6/review.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d.pop("tidiness", None)
json.dump(d, open(p, "w"))
PY
  if surf_worker_result "$RDs6" 0 "$GREEN_REPO"; then pass "(R3-2f) absent tidiness + otherwise green → green"; else fail "(R3-2f) absent tidiness wrongly parked"; fi
else
  pass "(R3-2f) git unavailable — skipped absent-tidiness green case"
fi

# --- #124 R5-3: GOLDEN FIXTURES — pin the contract against REAL /sail artifacts (generated via the
# actual sail.runstate.RunState + sail.review writers; see tests/fixtures/surf-worker/). These guard
# against /sail SCHEMA drift silently breaking the merge contract. (Currency, #124 R7-2, is proven
# separately by the (R7-2*) tests against a live repo — the checked-in green fixture is necessarily
# STALE, so it asserts the currency guard fires on a stale artifact rather than green.)
GOLDEN_DIR="$SRC_DIR/tests/fixtures/surf-worker"
if [ -d "$GOLDEN_DIR" ]; then
  # (R5-3a-schema) The REAL green review fixture has the exact shape the contract reads — every
  # non-currency green arm is satisfied (status completed, no blocking findings, non-empty ACs all
  # met, no blocking tidiness). Asserted directly so /sail schema drift in those fields is caught.
  if python3 - "$GOLDEN_DIR/green.review.json" "$GOLDEN_DIR/green.run-state.json" <<'PY'
import json, sys
rj = json.load(open(sys.argv[1])); rs = json.load(open(sys.argv[2]))
ok = (rj.get("status") == "completed"
      and isinstance(rj.get("findings"), list)
      and not ({str(f.get("severity","")).upper() for f in rj["findings"]} & {"CRITICAL","HIGH"})
      and isinstance(rj.get("plan_verification"), dict)
      and isinstance(rj["plan_verification"].get("acceptance_criteria"), list)
      and rj["plan_verification"]["acceptance_criteria"]
      and all(a.get("status") == "met" for a in rj["plan_verification"]["acceptance_criteria"])
      and (rj.get("tidiness") is None or not rj["tidiness"].get("blocking"))
      and isinstance(rs.get("gates"), list) and rs["gates"]
      and all(g.get("status") in ("passed","skipped") for g in rs["gates"])
      and rj.get("target") and rj.get("diff_ref") and rj.get("diff_hash") and rj.get("plan_hash"))
sys.exit(0 if ok else 1)
PY
  then pass "(R5-3a) REAL /sail green fixture matches the schema the contract reads"; else fail "(R5-3a) green fixture schema drift — contract fields changed"; fi

  # (R5-3a-currency) The checked-in green fixture is STALE (its target repo is gone), so the contract
  # PARKS on it — proving the R7-2 currency guard catches a stale-but-otherwise-green artifact.
  RDg="$FIX/runs/golden-green"; mkdir -p "$RDg"
  cp "$GOLDEN_DIR/green.run-state.json" "$RDg/run-state.json"
  cp "$GOLDEN_DIR/green.review.json" "$RDg/review.json"
  if surf_worker_result "$RDg"; then fail "(R5-3a) stale green fixture wrongly merged (currency guard missed it)"; else pass "(R5-3a) stale green fixture → park on currency (R7-2 guard fires)"; fi

  # (R5-3b) REAL parked review (HIGH finding + unmet AC) over a green run-state → park (findings/AC
  # arms fire before currency).
  RDp="$FIX/runs/golden-parked"; mkdir -p "$RDp"
  cp "$GOLDEN_DIR/green.run-state.json" "$RDp/run-state.json"
  cp "$GOLDEN_DIR/parked.review.json" "$RDp/review.json"
  if surf_worker_result "$RDp"; then fail "(R5-3b) real parked review wrongly merged"; else pass "(R5-3b) REAL /sail parked review (HIGH + unmet AC) → park"; fi

  # (R5-3c) REAL failed run-state (a gate 'failed') + green review → park (the gate arm).
  RDf="$FIX/runs/golden-failed"; mkdir -p "$RDf"
  cp "$GOLDEN_DIR/failed.run-state.json" "$RDf/run-state.json"
  cp "$GOLDEN_DIR/green.review.json" "$RDf/review.json"
  if surf_worker_result "$RDf"; then fail "(R5-3c) real failed-gate run-state wrongly merged"; else pass "(R5-3c) REAL /sail failed-gate run-state → park"; fi
else
  fail "(R5-3) golden fixtures missing at $GOLDEN_DIR (run the fixture generator)"
fi

# --- #124 R7-1: an EMPTY plan_verification.acceptance_criteria list must PARK (was fail-open).
# Mirrors sail.convergence.acs_all_met, which returns False on an empty/missing list. Parks at the
# AC arm (before currency), so a synthetic run-dir is sufficient.
RD71="$FIX/runs/r71-empty"; gs "$RD71"
printf '%s\n' '{"status":"completed","findings":[],"plan_verification":{"status":"verified","acceptance_criteria":[]},"tidiness":{"blocking":[]}}' >"$RD71/review.json"
if surf_worker_result "$RD71" 0; then fail "(R7-1) empty acceptance_criteria wrongly merged (fail-open)"; else pass "(R7-1) empty acceptance_criteria → park (mirrors acs_all_met)"; fi
# A MISSING plan_verification already parks (R3-2c covers non-dict; this covers absent entirely).
RD71b="$FIX/runs/r71-missing"; mkdir -p "$RD71b"
printf '%s\n' "$GREEN_RUNSTATE" >"$RD71b/run-state.json"
printf '%s\n' '{"status":"completed","findings":[],"tidiness":{"blocking":[]}}' >"$RD71b/review.json"
if surf_worker_result "$RD71b" 0; then fail "(R7-1) missing plan_verification wrongly merged"; else pass "(R7-1) missing plan_verification → park"; fi

# --- #124 R7-2: review CURRENCY. A clean-but-STALE review (diff_hash for an earlier diff) must PARK;
# the matching-fresh review → green. Built against the live $GREEN_REPO so diff_fingerprint is real.
if [ "$GREEN_OK" -eq 1 ]; then
  # Fresh: make_real_green produces a review.json whose diff_hash matches HEAD~1 of $GREEN_REPO.
  RD72="$FIX/runs/r72-fresh"; make_real_green "$RD72"
  if surf_worker_result "$RD72" 0 "$GREEN_REPO"; then pass "(R7-2) fresh review (diff_hash matches live diff) → green"; else fail "(R7-2) fresh current review wrongly parked"; fi

  # Stale: corrupt diff_hash so it no longer matches the live diff → must PARK.
  RD72s="$FIX/runs/r72-stale"; make_real_green "$RD72s"
  python3 - "$RD72s/review.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["diff_hash"] = "stale" + (d.get("diff_hash") or "x")
json.dump(d, open(p, "w"))
PY
  if surf_worker_result "$RD72s" 0 "$GREEN_REPO"; then fail "(R7-2) STALE diff_hash wrongly merged (fail-open)"; else pass "(R7-2) stale diff_hash (≠ live diff) → park"; fi

  # Stale plan: corrupt plan_hash → must PARK (a changed plan was never re-reviewed).
  RD72p="$FIX/runs/r72-staleplan"; make_real_green "$RD72p"
  python3 - "$RD72p/review.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["plan_hash"] = "stale" + (d.get("plan_hash") or "x")
json.dump(d, open(p, "w"))
PY
  if surf_worker_result "$RD72p" 0 "$GREEN_REPO"; then fail "(R7-2) STALE plan_hash wrongly merged"; else pass "(R7-2) stale plan_hash → park"; fi

  # Missing target/diff_ref → PARK (cannot prove currency).
  RD72m="$FIX/runs/r72-notarget"; make_real_green "$RD72m"
  python3 - "$RD72m/review.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d.pop("target", None); d.pop("diff_ref", None)
json.dump(d, open(p, "w"))
PY
  if surf_worker_result "$RD72m" 0 "$GREEN_REPO"; then fail "(R7-2) missing target/diff_ref wrongly merged"; else pass "(R7-2) missing target/diff_ref → park"; fi

  # Target mismatch: build dir != reviewed target → PARK. (Pass a DIFFERENT real worktree.)
  OTHER="$FIX/other-repo"; mkdir -p "$OTHER"; git -C "$OTHER" init -q
  git -C "$OTHER" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base 2>/dev/null || true
  RD72t="$FIX/runs/r72-mismatch"; make_real_green "$RD72t"
  if surf_worker_result "$RD72t" 0 "$OTHER"; then fail "(R7-2) target mismatch wrongly merged"; else pass "(R7-2) explicit target != reviewed target → park"; fi
else
  pass "(R7-2) git unavailable — skipped currency cases"
fi

# --- (R8 #128) surf_worker_result sourced via the ~/.claude/lib SYMLINK must still locate the sail
# module. It derives the repo root from its own source path to `import sail.review`; under the symlink
# a naive dirname lands in ~/.claude/lib (no sail/) → import fails → it PARKS every run. Source via a
# real symlink and assert a fresh-green fixture still reaches GREEN (proving realpath resolution).
if [ "$GREEN_OK" -eq 1 ] && command -v python3 >/dev/null 2>&1; then
  SYM="$FIX/surf-worker-symlink.sh"; ln -sf "$WORKER_SRC" "$SYM"
  RD8="$FIX/runs/r8-symlink"; make_real_green "$RD8"
  # Two things make this test genuinely discriminating (a naive dirname must FAIL it):
  #  - Pass the symlink as a NON-$0 positional ($0='_') so the helper's bottom guard sees
  #    BASH_SOURCE[0] ($SYM) != $0 and does NOT take the don't-execute-me `exit 0` branch (else the
  #    source exits before surf_worker_result is even defined → vacuous pass). Production is safe too:
  #    there $0 is "bash", not the file.
  #  - Run from a NEUTRAL cwd ($FIX, which has no sail/) so the `import sail.review` cannot succeed via
  #    cwd-on-sys.path — it must come from the repo root the helper derives from its own (symlinked)
  #    source path. Without realpath resolution that root is wrong and the import fails → park. #128.
  if ( cd "$FIX" && bash -c '. "$1" && surf_worker_result "$2" 0 "$3"' _ "$SYM" "$RD8" "$GREEN_REPO" ); then
    pass "(R8 #128) result sourced via symlink resolves repo root via realpath → green"
  else
    fail "(R8 #128) sourced via symlink → parked: repo root not realpath-resolved, sail import failed"
  fi
else
  pass "(R8 #128) git/python unavailable — skipped symlink repo-root case"
fi

# --- cleanup is safe (#124): NEVER force-delete; git worktree remove WITHOUT --force. Process
# liveness is the HARNESS's job now (no bash worker.pid live-guard), so these only exercise the
# safe-worktree-removal logic.

# (6) cleanup does not blow away unrelated state.
RDC="$FIX/runs/105"; mkdir -p "$RDC"
KEEP="$FIX/keepme"; mkdir -p "$KEEP"; printf 'keep\n' >"$KEEP/file"
surf_worker_cleanup "$RDC" "surf/105" >/dev/null 2>&1 || true
[ -e "$KEEP/file" ] && pass "(6) cleanup left unrelated state intact" || fail "(6) cleanup destroyed unrelated state"

# (6b) a real git worktree recorded at $run_dir/worktree is removed WITHOUT --force.
GIT_CLEANUP_TEST() {
  command -v git >/dev/null 2>&1 || { pass "(6b) git unavailable — skipped worktree cleanup case"; return 0; }
  local repo wt rd
  repo="$FIX/repo"; mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  wt="$FIX/wt-106"
  git -C "$repo" worktree add -q -b surf/106 "$wt" >/dev/null 2>&1 || { pass "(6b) worktree add unsupported — skipped"; return 0; }
  rd="$FIX/runs/106"; mkdir -p "$rd"
  printf '%s\n' "$wt" >"$rd/worktree"
  ( cd "$repo" && surf_worker_cleanup "$rd" "surf/106" ) >/dev/null 2>&1 || true
  [ ! -d "$wt" ] && pass "(6b) recorded worktree removed (no --force)" || fail "(6b) worktree not removed"
}
GIT_CLEANUP_TEST

# (6c) cleanup with uncommitted work in the worktree LEAVES it intact (git refuses without --force,
# and we never pass --force) — the safety net that replaces the old pid live-guard.
GIT_CLEANUP_DIRTY_TEST() {
  command -v git >/dev/null 2>&1 || { pass "(6c) git unavailable — skipped dirty-worktree case"; return 0; }
  local repo wt rd
  repo="$FIX/repo2"; mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  wt="$FIX/wt-108"
  git -C "$repo" worktree add -q -b surf/108 "$wt" >/dev/null 2>&1 || { pass "(6c) worktree add unsupported — skipped"; return 0; }
  printf 'uncommitted\n' >"$wt/dirty.txt"   # uncommitted work → remove must refuse
  rd="$FIX/runs/108"; mkdir -p "$rd"
  printf '%s\n' "$wt" >"$rd/worktree"
  ( cd "$repo" && surf_worker_cleanup "$rd" "surf/108" ) >/dev/null 2>&1 || true
  [ -e "$wt/dirty.txt" ] && pass "(6c) uncommitted work left intact (remove without --force refuses)" || fail "(6c) cleanup clobbered uncommitted work"
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true   # test-side teardown only
}
GIT_CLEANUP_DIRTY_TEST

# --- (7) #128: source-safe under the zsh RUNTIME. The /surf runtime (the Claude Code Bash tool) is
# /bin/zsh, not bash. The bash-only tests above hid two zsh failures: under zsh `set -u` the bottom
# guard `${BASH_SOURCE[0]}` was unbound (source aborted), and the helper's top-level `set -euo
# pipefail` leaked into the caller. This drives the helper under zsh exactly as the runtime does.
if command -v zsh >/dev/null 2>&1; then
  # 7a. Sources cleanly under zsh AND surf_worker_command emits the exact command.
  zout="$(zsh -c ". '$WORKER_SRC' && surf_worker_command 42" 2>&1)" && zrc=0 || zrc=$?
  { [ "${zrc:-1}" -eq 0 ] && [ "$zout" = 'claude --dangerously-bypass-permissions -p "/sail 42 --unattended"' ]; } \
    && pass "(7a) helper sources + emits under the zsh runtime" \
    || fail "(7a) helper not source-safe under zsh (rc=${zrc:-?}, out='$zout')"
  # 7b. The bad id must be REJECTED (non-zero) AND that non-zero return must NOT abort the zsh caller
  # (i.e. sourcing did not leak set -e). Assert BOTH, so the test can't pass just because the command
  # silently accepted a bad id.
  zleak="$(zsh -c ". '$WORKER_SRC'; if surf_worker_command 'bad; rm -rf /' >/dev/null 2>&1; then echo ACCEPTED; else echo REJECTED; fi; echo ALIVE" 2>&1)"
  [ "$zleak" = "$(printf 'REJECTED\nALIVE')" ] \
    && pass "(7b) bad id rejected (non-zero) AND set -e not leaked (caller survives)" \
    || fail "(7b) expected REJECTED+ALIVE, got '$zleak'"
else
  fail "(7) zsh not available — cannot verify the zsh runtime contract (#128)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
