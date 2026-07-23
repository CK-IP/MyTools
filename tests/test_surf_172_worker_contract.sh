#!/usr/bin/env bash
# test_surf_172_worker_contract.sh — pins the #172 hardening of the headless-worker contract clause
# emitted by surf_worker_command in config/surf-worker.sh.
#
# #172: on a heavy MULTI-ROUND issue the headless `claude -p` /sail worker re-tripped the #139
# turn-end trap by backgrounding a LATER-round stage ("Re-run plan round 2", "Round-3 mutation-verify
# + escalated review") — the original clause named only the initial build/review, so the worker read
# it as not covering later convergence rounds. This test asserts the strengthened clause explicitly
# forbids backgrounding ANY stage on EVERY convergence round (plan re-runs, per-round mutation-verify,
# escalated/red-team review) and carries a pre-turn-end SELF-ATTESTATION directive. The enforcement
# surface is the emitted prompt text (an LLM-followed contract), so these are text assertions on the
# clause surf_worker_command emits.
#
# shellcheck disable=SC2015
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKER_SRC="$SRC_DIR/config/surf-worker.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

[ -f "$WORKER_SRC" ] || { echo "FAIL: surf-worker.sh not found at $WORKER_SRC"; exit 1; }
# shellcheck source=/dev/null
. "$WORKER_SRC"

CMD="$(surf_worker_command 42 2>/dev/null || true)"
[ -n "$CMD" ] || { echo "FAIL: surf_worker_command 42 emitted nothing"; exit 1; }

# (172-a) round-N coverage: the clause must make the every-convergence-round scope explicit, not just
# the initial build/review — so a heavy multi-round issue cannot read it as first-round-only.
# Case-insensitive: the clause capitalizes EVERY for emphasis, but the assertion is about coverage.
case "$(printf '%s' "$CMD" | tr '[:upper:]' '[:lower:]')" in
  *"every convergence round"*) pass "(172-a) clause states 'every convergence round'" ;;
  *) fail "(172-a) clause does not state every-convergence-round coverage (CMD lacks 'every convergence round')" ;;
esac

# (172-b) the specific later-round stages the trap re-trips on are named: plan re-runs, mutation-verify,
# and escalation — so none is read as out-of-scope.
for marker in 'plan re-run' 'mutation-verify' 'escalat'; do
  case "$CMD" in
    *"$marker"*) pass "(172-b) later-round stage named: $marker" ;;
    *) fail "(172-b) clause omits later-round stage marker: $marker" ;;
  esac
done

# (172-c) the concrete background primitive observed in the #126 re-trip is forbidden by name.
case "$CMD" in
  *"local_bash"*) pass "(172-c) clause forbids a local_bash background task by name" ;;
  *) fail "(172-c) clause does not name the local_bash background-task primitive" ;;
esac

# (172-d) a pre-turn-end SELF-ATTESTATION directive is present (checkable, not purely aspirational).
case "$CMD" in
  *"SELF-ATTESTATION"*) pass "(172-d) SELF-ATTESTATION directive present" ;;
  *) fail "(172-d) SELF-ATTESTATION directive missing" ;;
esac
case "$CMD" in
  *"before ending your turn"*) pass "(172-d) self-attestation is anchored to before-turn-end" ;;
  *) fail "(172-d) self-attestation not anchored to ending the turn" ;;
esac

# (172-e) the clause references #172 (this hardening) alongside the #139 origin already in the source.
case "$CMD" in
  *"#172"*) pass "(172-e) clause references #172" ;;
  *) fail "(172-e) clause does not reference #172" ;;
esac

# (172-f) regression guard: the pre-existing #139 markers the current contract test relies on stay present.
for marker in 'HEADLESS-WORKER CONTRACT' 'run_in_background' 'ScheduleWakeup' 'SYNCHRONOUSLY' 'commit terminus'; do
  case "$CMD" in
    *"$marker"*) pass "(172-f) pre-existing contract marker intact: $marker" ;;
    *) fail "(172-f) regressed a pre-existing contract marker: $marker" ;;
  esac
done

echo "----"
echo "test_surf_172_worker_contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
