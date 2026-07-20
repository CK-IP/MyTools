#!/usr/bin/env bash
# test_sail_130_convergence_trend.sh
# Issue #130 — replace the fixed 3-round cap with a convergence-trend stop + a wall-clock cost
# backstop, retaining the round cap as the ULTIMATE hard ceiling.
#
# The oracle now layers three guards on a non-green round (after the commit-eligible floors):
#   1. cost-backstop  — wall-clock elapsed since run start > the cost ceiling. #142: ships an
#                       ACTIVE default ceiling (14400s = 4h) when SAIL_COST_CEILING_SECONDS is
#                       unset; an explicit 0/non-positive/unparseable value disables it. Still
#                       fails OPEN on bad data: an unparseable/missing start never parks (the
#                       hard ceiling is the guaranteed catch).
#   2. trend-stall    — N (SAIL_TREND_WINDOW, default 3) consecutive rounds where max blocking
#                       severity did NOT drop AND nothing was `addressed` (true churn). A round
#                       that drops severity or addresses a finding resets the streak.
#   3. hard ceiling   — round_num >= --max-rounds (default raised above 3) — ultimate backstop.
#
# #142 whack-a-mole: a blocking finding fingerprint (file+id) that is dispositioned `addressed`
# yet REAPPEARS in later rounds evades the trend-stall (each re-address resets the streak). The
# ledger rows now persist per-round blocking/addressed fingerprints, and a distinct PARK guard
# (alongside the reappeared-rejected/deferred oscillation guard, before the commit-eligible
# floors) fires when one fingerprint keeps reappearing after being addressed.
#
# Durable: the trend streak is reconstructed from trend-ledger.jsonl in the run-dir, so a
# resumed process never resets it to zero.
#
# Hermetic: pure-function imports + seeded run-dir artifacts; no live LLM backend, no git needed
# (CLI trend tests seed the ledger directly; hydration is strong-freshness-gated and no-ops without
# a fresh review.json so it never pollutes the seeded ledger).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
LOG_FILE="$TMP_ROOT/python.log"
# Clear inherited SAIL_* knobs so each subtest controls its own env.
unset "${!SAIL_@}"
SAIL_MD="$REPO_ROOT/commands/sail.md"
README="$REPO_ROOT/sail/README.md"

cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  [ -s "$LOG_FILE" ] && { echo "---- python output ----" >&2; sed 's/^/  /' "$LOG_FILE" >&2; echo "-----------------------" >&2; }
  exit 1
}

cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# T1 — pure functions: max_blocking_severity_rank / trend streak / cost
# ---------------------------------------------------------------------------
if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
from sail.convergence import (
    max_blocking_severity_rank, trend_no_progress_streak, trend_stalled,
    cost_exceeded,
)

# max_blocking_severity_rank: CRITICAL=2, HIGH=1 (no CRITICAL), none=0; MEDIUM/LOW never count.
assert max_blocking_severity_rank([{"severity": "CRITICAL"}, {"severity": "HIGH"}]) == 2
assert max_blocking_severity_rank([{"severity": "HIGH"}, {"severity": "MEDIUM"}]) == 1
assert max_blocking_severity_rank([{"severity": "MEDIUM"}, {"severity": "LOW"}]) == 0
assert max_blocking_severity_rank([]) == 0
assert max_blocking_severity_rank("not-a-list") == 0
assert max_blocking_severity_rank([{"severity": "high"}]) == 1   # case-insensitive

# trend_no_progress_streak: streak of consecutive churn rounds.
# Severity drop resets the streak.
rows_drop = [
    {"round": 1, "max_blocking_severity_rank": 2, "addressed_count": 0},
    {"round": 2, "max_blocking_severity_rank": 1, "addressed_count": 0},  # dropped 2->1: progress
    {"round": 3, "max_blocking_severity_rank": 1, "addressed_count": 0},  # flat: churn (streak 1)
]
assert trend_no_progress_streak(rows_drop) == 1, trend_no_progress_streak(rows_drop)

# Addressed>0 resets the streak even when severity is flat.
rows_addr = [
    {"round": 1, "max_blocking_severity_rank": 1, "addressed_count": 0},
    {"round": 2, "max_blocking_severity_rank": 1, "addressed_count": 0},  # churn (streak 1)
    {"round": 3, "max_blocking_severity_rank": 1, "addressed_count": 2},  # addressed: progress (reset)
]
assert trend_no_progress_streak(rows_addr) == 0, trend_no_progress_streak(rows_addr)

# Pure churn: severity flat, nothing addressed -> streak grows each round after the first.
rows_churn = [
    {"round": 1, "max_blocking_severity_rank": 1, "addressed_count": 0},
    {"round": 2, "max_blocking_severity_rank": 1, "addressed_count": 0},  # streak 1
    {"round": 3, "max_blocking_severity_rank": 1, "addressed_count": 0},  # streak 2
    {"round": 4, "max_blocking_severity_rank": 1, "addressed_count": 0},  # streak 3
]
assert trend_no_progress_streak(rows_churn) == 3, trend_no_progress_streak(rows_churn)

# A SINGLE round can never stall (no prior round to compare).
assert trend_no_progress_streak([{"round": 1, "max_blocking_severity_rank": 1, "addressed_count": 0}]) == 0

# Severity RISING is still no-progress (did not drop).
rows_rise = [
    {"round": 1, "max_blocking_severity_rank": 1, "addressed_count": 0},
    {"round": 2, "max_blocking_severity_rank": 2, "addressed_count": 0},  # rose: churn (streak 1)
]
assert trend_no_progress_streak(rows_rise) == 1, trend_no_progress_streak(rows_rise)

# trend_stalled honors the window (explicit arg).
assert trend_stalled(rows_churn, window=3) is True
assert trend_stalled(rows_churn, window=4) is False
assert trend_stalled(rows_drop, window=1) is True       # the lone flat round
assert trend_stalled(rows_addr, window=1) is False      # last round addressed

# (elapsed_seconds(run_dir) — the run-state-derived, resume-aware form — is exercised in T4.)

# cost_exceeded: fires only when both known and over; fails OPEN otherwise.
assert cost_exceeded(120.0, 60.0) is True
assert cost_exceeded(30.0, 60.0) is False
assert cost_exceeded(None, 60.0) is False     # unknown elapsed -> never park
assert cost_exceeded(120.0, None) is False    # unset ceiling -> inert
assert cost_exceeded(120.0, 0) is False       # non-positive ceiling -> inert
print("ok")
PY
then
  fail "pure-function contract (max_blocking_severity_rank / trend streak / cost) not implemented"
fi
grep -q '^ok$' "$LOG_FILE" || fail "T1 pure-function test did not reach 'ok'"

# ---------------------------------------------------------------------------
# T1b — #142: cost ceiling ships an ACTIVE documented default (14400s = 4h)
# ---------------------------------------------------------------------------
if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
import os
from sail.convergence import cost_ceiling_seconds

os.environ.pop("SAIL_COST_CEILING_SECONDS", None)
assert cost_ceiling_seconds() == 14400.0, (
    f"unset env must yield the documented 4h default, got {cost_ceiling_seconds()}")
os.environ["SAIL_COST_CEILING_SECONDS"] = "60"
assert cost_ceiling_seconds() == 60.0, "env override must win over the default"
os.environ["SAIL_COST_CEILING_SECONDS"] = "0"
assert cost_ceiling_seconds() is None, "explicit 0 must DISABLE the ceiling (escape hatch)"
os.environ["SAIL_COST_CEILING_SECONDS"] = "-5"
assert cost_ceiling_seconds() is None, "non-positive must disable, not fall back to the default"
os.environ["SAIL_COST_CEILING_SECONDS"] = "not-a-number"
assert cost_ceiling_seconds() is None, "unparseable must fail open (None), not default"
print("ok-default")
PY
then
  fail "T1b cost_ceiling_seconds default contract (#142) not implemented"
fi
grep -q '^ok-default$' "$LOG_FILE" || fail "T1b did not reach 'ok-default'"

# ---------------------------------------------------------------------------
# T2 — durable ledger: record idempotent per round + survives a fresh process
# ---------------------------------------------------------------------------
if ! python3 - "$TMP_ROOT/rd_ledger" <<'PY' >"$LOG_FILE" 2>&1
import sys
from sail.convergence import record_trend_row, read_trend, trend_no_progress_streak
rd = sys.argv[1]

assert record_trend_row(rd, 1, 1, 0) is True
assert record_trend_row(rd, 2, 1, 0) is True
# Idempotent: re-recording the same round is a no-op (no duplicate row).
assert record_trend_row(rd, 2, 1, 0) is False
rows = read_trend(rd)
assert [r["round"] for r in rows] == [1, 2], rows
print("ok-write")
PY
then
  fail "T2 ledger writer/reader not implemented"
fi
grep -q '^ok-write$' "$LOG_FILE" || fail "T2 ledger write did not reach 'ok-write'"

# Resume: a FRESH python process reads the SAME run-dir, appends one more flat round, and the
# streak is reconstructed (not reset to zero) -> parks at window 2.
if ! python3 - "$TMP_ROOT/rd_ledger" <<'PY' >"$LOG_FILE" 2>&1
import sys
from sail.convergence import record_trend_row, read_trend, trend_stalled
rd = sys.argv[1]
# Ledger already has rounds 1,2 (flat rank 1, nothing addressed) = streak 1.
assert record_trend_row(rd, 3, 1, 0) is True   # streak now 2
rows = read_trend(rd)
assert [r["round"] for r in rows] == [1, 2, 3], rows
assert trend_stalled(rows, window=2) is True, "resumed streak must survive across processes"
print("ok-resume")
PY
then
  fail "T2 resume reconstruction failed"
fi
grep -q '^ok-resume$' "$LOG_FILE" || fail "T2 resume did not reach 'ok-resume'"

# read_trend tolerates malformed lines and de-dups by round (last wins).
if ! python3 - "$TMP_ROOT/rd_messy" <<'PY' >"$LOG_FILE" 2>&1
import os, sys, json
from sail.convergence import read_trend
rd = sys.argv[1]; os.makedirs(rd, exist_ok=True)
with open(os.path.join(rd, "trend-ledger.jsonl"), "w") as fh:
    fh.write(json.dumps({"round": 1, "max_blocking_severity_rank": 1, "addressed_count": 0}) + "\n")
    fh.write("this is not json\n")
    fh.write("\n")
    fh.write(json.dumps({"round": 1, "max_blocking_severity_rank": 2, "addressed_count": 0}) + "\n")  # dup round 1
rows = read_trend(rd)
assert len(rows) == 1 and rows[0]["round"] == 1, rows
assert rows[0]["max_blocking_severity_rank"] == 2, "last write should win on duplicate round"
assert read_trend(os.path.join(rd, "does-not-exist")) == []
print("ok-messy")
PY
then
  fail "T2 read_trend robustness failed"
fi
grep -q '^ok-messy$' "$LOG_FILE" || fail "T2 read_trend robustness did not reach 'ok-messy'"

# ---------------------------------------------------------------------------
# T3 — CLI: trend-stall parks (seeded ledger), green never parks
# ---------------------------------------------------------------------------
converge() { python3 -m sail converge "$@" 2>"$TMP_ROOT/stderr.log"; }

RD_TREND="$TMP_ROOT/rd_trend"
mkdir -p "$RD_TREND"
# Seed a churn ledger: 3 flat rounds after the first (streak 3 >= default window 3).
cat > "$RD_TREND/trend-ledger.jsonl" <<'JSONL'
{"round": 1, "max_blocking_severity_rank": 1, "addressed_count": 0}
{"round": 2, "max_blocking_severity_rank": 1, "addressed_count": 0}
{"round": 3, "max_blocking_severity_rank": 1, "addressed_count": 0}
{"round": 4, "max_blocking_severity_rank": 1, "addressed_count": 0}
JSONL
# No review.json -> hydration no-ops (strong-freshness gated), so the seeded ledger is authoritative.
cat > "$RD_TREND/run-state.json" <<'JSON'
{"gates":[{"name":"ruff","status":"passed","new_failures":0}]}
JSON
out=$(converge --rc 1 --round 4 --run-dir "$RD_TREND" --max-rounds 99) || fail "converge trend-stall exited non-zero"
[ "$out" = "park" ] || fail "trend-stall should PARK, got '$out'"
grep -qi "trend.stall\|trend-stall" "$TMP_ROOT/stderr.log" || fail "trend-stall stop-reason not printed to stderr"

# A higher window keeps it converging (revise), proving the window is honored.
out=$(SAIL_TREND_WINDOW=5 converge --rc 1 --round 4 --run-dir "$RD_TREND" --max-rounds 99) || fail "converge wide-window exited non-zero"
[ "$out" = "revise" ] || fail "window 5 over a streak-3 ledger should 'revise', got '$out'"

# Green (rc 0) still proceeds when the run-state gate is green, even with a churn ledger present.
out=$(converge --rc 0 --round 4 --run-dir "$RD_TREND" --max-rounds 99) || fail "converge rc0 exited non-zero"
[ "$out" = "proceed" ] || fail "rc 0 must 'proceed' regardless of trend ledger, got '$out'"

# ---------------------------------------------------------------------------
# T4 — CLI: cost backstop parks past ceiling, inert unset, fails open on bad start
# ---------------------------------------------------------------------------
RD_COST="$TMP_ROOT/rd_cost"
mkdir -p "$RD_COST"
# run-state.json with a far-past start -> huge elapsed.
cat > "$RD_COST/run-state.json" <<'JSON'
{"run_id": "x", "started_at": "2020-01-01T00:00:00Z", "schema_version": 1, "gates": []}
JSON
# Ceiling tiny -> elapsed (years) exceeds it -> park with the cost-backstop reason.
out=$(SAIL_COST_CEILING_SECONDS=5 converge --rc 1 --round 1 --run-dir "$RD_COST" --max-rounds 99) || fail "converge cost exited non-zero"
[ "$out" = "park" ] || fail "cost backstop should PARK past ceiling, got '$out'"
grep -qi "cost.backstop\|cost-backstop" "$TMP_ROOT/stderr.log" || fail "cost-backstop stop-reason not printed to stderr"

# #142 REVERSAL: ceiling unset -> the documented DEFAULT (14400s) is enforced, no longer inert.
# The seeded start is years past, far over 4h -> park with the cost-backstop reason.
out=$(converge --rc 1 --round 1 --run-dir "$RD_COST" --max-rounds 99) || fail "converge cost-unset exited non-zero"
[ "$out" = "park" ] || fail "unset ceiling must enforce the 14400s default (park on a years-old start), got '$out'"
grep -qi "cost.backstop\|cost-backstop" "$TMP_ROOT/stderr.log" || fail "default-ceiling park must print the cost-backstop stop-reason"

# A FRESH start stays under the default -> revise (the default must not clip a normal run).
RD_FRESHSTART="$TMP_ROOT/rd_freshstart"
mkdir -p "$RD_FRESHSTART"
cat > "$RD_FRESHSTART/run-state.json" <<JSON
{"run_id": "x", "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "schema_version": 1, "gates": []}
JSON
out=$(converge --rc 1 --round 1 --run-dir "$RD_FRESHSTART" --max-rounds 99) || fail "converge fresh-start exited non-zero"
[ "$out" = "revise" ] || fail "a fresh run under the default ceiling must 'revise' (no false park), got '$out'"

# Explicit escape hatch: SAIL_COST_CEILING_SECONDS=0 disables the ceiling entirely.
out=$(SAIL_COST_CEILING_SECONDS=0 converge --rc 1 --round 1 --run-dir "$RD_COST" --max-rounds 99) || fail "converge cost-disabled exited non-zero"
[ "$out" = "revise" ] || fail "explicit 0 must disable the ceiling ('revise'), got '$out'"

# Fail OPEN: unparseable started_at -> elapsed unknown -> NEVER park (revise).
RD_BADSTART="$TMP_ROOT/rd_badstart"
mkdir -p "$RD_BADSTART"
cat > "$RD_BADSTART/run-state.json" <<'JSON'
{"run_id": "x", "started_at": "not-a-timestamp", "schema_version": 1, "gates": []}
JSON
out=$(SAIL_COST_CEILING_SECONDS=5 converge --rc 1 --round 1 --run-dir "$RD_BADSTART" --max-rounds 99) || fail "converge bad-start exited non-zero"
[ "$out" = "revise" ] || fail "unparseable start must fail OPEN ('revise'), got '$out'"

# Surfacing: per-run cost (wall-time) is printed to stderr when the run-dir carries a start time.
SAIL_COST_CEILING_SECONDS=999999999 converge --rc 1 --round 1 --run-dir "$RD_COST" --max-rounds 99 >/dev/null
grep -qiE "elapsed|wall.?time|cost" "$TMP_ROOT/stderr.log" || fail "per-run cost (wall-time) not surfaced to stderr"

# Resume-aware clock (#130 review HIGH): the cost clock measures from the LATER of started_at and
# the most-recent decision-log resume marker, so a parked-then-resumed run gets a fresh budget and
# does NOT spuriously trip on the original (now-stale) started_at. Far-past start + a recent resume
# marker => small effective elapsed => no cost park even under a tiny ceiling.
RD_RESUME="$TMP_ROOT/rd_resume"
mkdir -p "$RD_RESUME"
cat > "$RD_RESUME/run-state.json" <<'JSON'
{"run_id": "x", "started_at": "2020-01-01T00:00:00Z", "schema_version": 1, "gates": []}
JSON
# Seed a resume marker dated "now" via the engine so the format matches the reader exactly.
python3 - "$RD_RESUME" <<'PY'
import sys
from sail.decisionlog import DecisionLog
DecisionLog(sys.argv[1]).resume_marker()   # writes "- ↺ resume <iso-now>"
PY
out=$(SAIL_COST_CEILING_SECONDS=5 converge --rc 1 --round 1 --run-dir "$RD_RESUME" --max-rounds 99) || fail "converge resume-clock exited non-zero"
[ "$out" = "revise" ] || fail "a recent resume marker must reset the cost clock (no spurious park), got '$out'"

# ---------------------------------------------------------------------------
# T4b — cost-clock reset is gated to a GENUINE cross-session resume (#130 review r3 HIGH)
# ---------------------------------------------------------------------------
# A resume marker resets the cost clock, but `sail run` must write one ONLY on a genuine
# cross-session re-entry (the run was parked, a NEW session picked it up) — NOT on every
# same-session convergence-round re-run, which would collapse the cumulative cost window to
# the current round and defeat the PRIMARY runaway guard. The decision is the pure, tested
# is_cross_session_resume(); a reset fires only when both sessions are KNOWN and differ.
if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
from sail.convergence import is_cross_session_resume
# fresh init (not resumed) never writes a resume marker
assert is_cross_session_resume(False, None, "sessA") is False
# same-session round re-run must NOT reset the clock (the r3 defect)
assert is_cross_session_resume(True, "sessA", "sessA") is False
# genuine cross-session re-entry (parked → new session) DOES reset
assert is_cross_session_resume(True, "sessA", "sessB") is True
# no prior session recorded (old run-state) => fail safe to NO reset (cumulative)
assert is_cross_session_resume(True, None, "sessB") is False
# the unknown sentinel ("_nosession") on either side never resets (can't detect re-entry)
assert is_cross_session_resume(True, "sessA", "_nosession") is False
assert is_cross_session_resume(True, "_nosession", "sessB") is False
print("ok-xsession")
PY
then
  fail "T4b is_cross_session_resume failed"
fi
grep -q '^ok-xsession$' "$LOG_FILE" || fail "T4b did not reach 'ok-xsession'"

# ---------------------------------------------------------------------------
# T4c — cost clock measures from the durable run-state anchor, NOT same-session resume markers
# ---------------------------------------------------------------------------
# The r3 regression: a long multi-round run appends a resume marker every round, but the
# cumulative cost window must survive. A far-past cost_anchor_at + several recent resume markers
# (as same-session rounds write) must STILL trip the cost-backstop — the markers are audit-only
# once an anchor is present.
RD_ANCHOR="$TMP_ROOT/rd_anchor"
mkdir -p "$RD_ANCHOR"
cat > "$RD_ANCHOR/run-state.json" <<'JSON'
{"run_id": "x", "started_at": "2020-01-01T00:00:00Z", "cost_anchor_at": "2020-01-01T00:00:00Z", "schema_version": 1, "gates": []}
JSON
python3 - "$RD_ANCHOR" <<'PY'
import sys
from sail.decisionlog import DecisionLog
dl = DecisionLog(sys.argv[1])
dl.resume_marker(); dl.resume_marker(); dl.resume_marker()   # recent same-session round markers
PY
out=$(SAIL_COST_CEILING_SECONDS=5 converge --rc 1 --round 4 --run-dir "$RD_ANCHOR" --max-rounds 99) || fail "converge anchor exited non-zero"
[ "$out" = "park" ] || fail "a far-past cost anchor must PARK despite recent same-session resume markers (r3 cumulative fix), got '$out'"

# ---------------------------------------------------------------------------
# T8 — #142 whack-a-mole: an `addressed`-then-reappearing fingerprint trips a PARK
# ---------------------------------------------------------------------------
# Pure predicate: addressed_reappearance_streak counts, for a fingerprint still blocking in the
# LATEST round, the rounds where it reappeared after having been dispositioned `addressed`.
if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
from sail.convergence import addressed_reappearance_streak

F = "sail/foo.py::F1"
whack = lambda n: [
    {"round": r, "max_blocking_severity_rank": 1, "addressed_count": 1,
     "blocking_fingerprints": [F], "addressed_fingerprints": [F]}
    for r in range(1, n + 1)
]
# 4 rounds re-addressing the same reappearing fingerprint: F reappears at rounds 2,3,4 -> streak 3.
assert addressed_reappearance_streak(whack(4)) == 3, addressed_reappearance_streak(whack(4))
# 2 rounds -> one reappearance -> streak 1.
assert addressed_reappearance_streak(whack(2)) == 1, addressed_reappearance_streak(whack(2))
# A single round can never be a reappearance.
assert addressed_reappearance_streak(whack(1)) == 0

# Genuine progress: each round addresses a DISTINCT finding that then stays gone -> 0.
progress = [
    {"round": 1, "max_blocking_severity_rank": 1, "addressed_count": 1,
     "blocking_fingerprints": ["a.py::1"], "addressed_fingerprints": ["a.py::1"]},
    {"round": 2, "max_blocking_severity_rank": 1, "addressed_count": 1,
     "blocking_fingerprints": ["b.py::2"], "addressed_fingerprints": ["b.py::2"]},
    {"round": 3, "max_blocking_severity_rank": 1, "addressed_count": 0,
     "blocking_fingerprints": ["c.py::3"], "addressed_fingerprints": []},
]
assert addressed_reappearance_streak(progress) == 0, "distinct fingerprints must never count"

# Latest-round gating: stale whack history but the CURRENT round no longer carries the
# fingerprint -> 0 (never park on history the run has moved past).
moved_on = whack(3) + [
    {"round": 4, "max_blocking_severity_rank": 1, "addressed_count": 0,
     "blocking_fingerprints": ["new.py::9"], "addressed_fingerprints": []},
]
assert addressed_reappearance_streak(moved_on) == 0, "must gate on the latest round's fingerprints"

# Legacy rows lacking the fingerprint keys (pre-#142 ledger) -> 0, resume-safe.
legacy = [
    {"round": 1, "max_blocking_severity_rank": 1, "addressed_count": 1},
    {"round": 2, "max_blocking_severity_rank": 1, "addressed_count": 1},
]
assert addressed_reappearance_streak(legacy) == 0, "legacy ledgers must default fingerprints to []"

# Robustness: junk input never raises.
assert addressed_reappearance_streak("not-a-list") == 0
assert addressed_reappearance_streak(None) == 0
assert addressed_reappearance_streak([{"round": "x"}, "junk"]) == 0
print("ok-whack-pure")
PY
then
  fail "T8 addressed_reappearance_streak predicate (#142) not implemented"
fi
grep -q '^ok-whack-pure$' "$LOG_FILE" || fail "T8 pure predicate did not reach 'ok-whack-pure'"

# Persistence round-trip: record_trend_row persists the fingerprint fields; read_trend reads them
# back and defaults them to [] on legacy rows (AC1/AC2 backward-compatible resume).
if ! python3 - "$TMP_ROOT/rd_fp" <<'PY' >"$LOG_FILE" 2>&1
import json, os, sys
from sail.convergence import record_trend_row, read_trend

rd = sys.argv[1]
F = "sail/foo.py::F1"
assert record_trend_row(rd, 1, 1, 1, area="sail/foo.py",
                        blocking_fingerprints=[F], addressed_fingerprints=[F]) is True
# A legacy row with no fingerprint keys, as a pre-#142 process would have written.
with open(os.path.join(rd, "trend-ledger.jsonl"), "a") as fh:
    fh.write(json.dumps({"round": 2, "max_blocking_severity_rank": 1, "addressed_count": 0}) + "\n")
rows = read_trend(rd)
assert rows[0]["blocking_fingerprints"] == [F], rows[0]
assert rows[0]["addressed_fingerprints"] == [F], rows[0]
assert rows[1]["blocking_fingerprints"] == [], "legacy row must default blocking_fingerprints to []"
assert rows[1]["addressed_fingerprints"] == [], "legacy row must default addressed_fingerprints to []"
print("ok-whack-roundtrip")
PY
then
  fail "T8 fingerprint ledger round-trip (#142) not implemented"
fi
grep -q '^ok-whack-roundtrip$' "$LOG_FILE" || fail "T8 round-trip did not reach 'ok-whack-roundtrip'"

# Hydrate extraction: the PRODUCTION path that feeds the whack-a-mole guard — hydrate_trend_row
# reading a real review.json + real decision-log resolutions — persists the correct fingerprints.
# Monkeypatch only the strong-freshness gate (same recipe as test_sail_132 T4, no git needed);
# the extraction itself (severity filter, disposition filter, file::id shape) runs for real.
if ! python3 - "$TMP_ROOT/rd_hydrate_fp" <<'PY' >"$LOG_FILE" 2>&1
import os, sys, json
import sail.convergence as C
from sail.decisionlog import DecisionLog

rd = sys.argv[1]; os.makedirs(rd, exist_ok=True)
C.review_current_and_clean = lambda run_dir, target, round: True
with open(os.path.join(rd, "review.json"), "w") as fh:
    json.dump({
        "status": "completed", "round": 3,
        "findings": [
            {"id": "f1", "severity": "HIGH", "file": "sail/foo.py"},   # addressed this round
            {"id": "f2", "severity": "HIGH", "file": "sail/bar.py"},   # deferred -> NOT addressed
            {"id": "f3", "severity": "LOW", "file": "sail/baz.py"},    # non-blocking -> excluded
        ],
    }, fh)
dl = DecisionLog(rd)
dl.finding_resolution("f1", "addressed", "fixed the guard", round=3)
dl.finding_resolution("f2", "deferred", "follow-up filed", round=3)

C.hydrate_trend_row(rd, ".", 3)
row = next(r for r in C.read_trend(rd) if r["round"] == 3)
assert sorted(row["blocking_fingerprints"]) == ["sail/bar.py::f2", "sail/foo.py::f1"], row
assert row["addressed_fingerprints"] == ["sail/foo.py::f1"], (
    "only the finding with a real `addressed` disposition may be recorded as addressed", row)
print("ok-hydrate-fp")
PY
then
  fail "T8b hydrate fingerprint extraction (review.json + decision-log) not proven"
fi
grep -q '^ok-hydrate-fp$' "$LOG_FILE" || fail "T8b did not reach 'ok-hydrate-fp'"

# CLI: a seeded whack-a-mole ledger PARKs with a DISTINCT stderr stop-reason. Note the seeded
# rounds each have addressed_count=1, so the ORIGINAL trend-stall would reset every round and
# never fire — this case discriminates exactly the #142 gap.
RD_WHACK="$TMP_ROOT/rd_whack"
mkdir -p "$RD_WHACK"
cat > "$RD_WHACK/run-state.json" <<'JSON'
{"gates":[{"name":"ruff","status":"passed","new_failures":0}]}
JSON
cat > "$RD_WHACK/trend-ledger.jsonl" <<'JSONL'
{"round": 1, "max_blocking_severity_rank": 1, "addressed_count": 1, "area": "sail/foo.py", "blocking_fingerprints": ["sail/foo.py::F1"], "addressed_fingerprints": ["sail/foo.py::F1"]}
{"round": 2, "max_blocking_severity_rank": 1, "addressed_count": 1, "area": "sail/foo.py", "blocking_fingerprints": ["sail/foo.py::F1"], "addressed_fingerprints": ["sail/foo.py::F1"]}
{"round": 3, "max_blocking_severity_rank": 1, "addressed_count": 1, "area": "sail/foo.py", "blocking_fingerprints": ["sail/foo.py::F1"], "addressed_fingerprints": ["sail/foo.py::F1"]}
{"round": 4, "max_blocking_severity_rank": 1, "addressed_count": 1, "area": "sail/foo.py", "blocking_fingerprints": ["sail/foo.py::F1"], "addressed_fingerprints": ["sail/foo.py::F1"]}
JSONL
out=$(converge --rc 1 --round 4 --run-dir "$RD_WHACK" --max-rounds 99) || fail "converge whack exited non-zero"
[ "$out" = "park" ] || fail "an addressed-then-reappearing fingerprint (streak 3) must PARK, got '$out'"
grep -qiE "whack|re-?addressed|addressed.*reappear" "$TMP_ROOT/stderr.log" || fail "whack-a-mole PARK must emit a distinct stderr stop-reason"

# The window is honored: a wider SAIL_TREND_WINDOW keeps the same ledger on 'revise'.
out=$(SAIL_TREND_WINDOW=5 converge --rc 1 --round 4 --run-dir "$RD_WHACK" --max-rounds 99) || fail "converge whack-window exited non-zero"
[ "$out" = "revise" ] || fail "window 5 over a whack-streak-3 ledger must 'revise', got '$out'"

# Green still wins: rc 0 proceeds regardless of the whack ledger.
out=$(converge --rc 0 --round 4 --run-dir "$RD_WHACK" --max-rounds 99) || fail "converge whack-green exited non-zero"
[ "$out" = "proceed" ] || fail "rc 0 must 'proceed' regardless of whack history, got '$out'"

# ---------------------------------------------------------------------------
# T5 — hard ceiling is the ultimate backstop (round cap still parks); default raised above 3
# ---------------------------------------------------------------------------
# No run-dir => no trend/cost data; pure round-vs-ceiling behavior.
out=$(converge --rc 1 --round 3) || fail "converge round 3 exited non-zero"
[ "$out" = "revise" ] || fail "round 3 must NO LONGER park at the default ceiling (>3), got '$out'"

out=$(converge --rc 1 --round 10 --max-rounds 10) || fail "converge hard-ceiling exited non-zero"
[ "$out" = "park" ] || fail "round 10 at --max-rounds 10 must PARK (hard ceiling), got '$out'"
# AC#5: each of the three PARK guards emits a DISTINCT stderr stop-reason (cost-backstop /
# trend-stall already do; the hard ceiling must too, for symmetric observability).
grep -qiE "hard.ceiling" "$TMP_ROOT/stderr.log" || fail "hard-ceiling PARK must emit a distinct stderr stop-reason (AC#5)"

# SAIL_HARD_ROUND_CEILING overrides the raised default when --max-rounds is not passed (AC#7).
out=$(SAIL_HARD_ROUND_CEILING=4 converge --rc 1 --round 4) || fail "converge HARD_ROUND_CEILING exited non-zero"
[ "$out" = "park" ] || fail "SAIL_HARD_ROUND_CEILING=4 at round 4 must PARK, got '$out'"
out=$(SAIL_HARD_ROUND_CEILING=4 converge --rc 1 --round 3) || fail "converge HARD_ROUND_CEILING r3 exited non-zero"
[ "$out" = "revise" ] || fail "SAIL_HARD_ROUND_CEILING=4 at round 3 must 'revise', got '$out'"
# An explicit --max-rounds still wins over the env default.
out=$(SAIL_HARD_ROUND_CEILING=4 converge --rc 1 --round 4 --max-rounds 99) || fail "converge override exited non-zero"
[ "$out" = "revise" ] || fail "explicit --max-rounds must win over SAIL_HARD_ROUND_CEILING, got '$out'"

# Even with a still-converging trend, the hard ceiling parks as the last resort.
RD_HC="$TMP_ROOT/rd_hc"
mkdir -p "$RD_HC"
cat > "$RD_HC/trend-ledger.jsonl" <<'JSONL'
{"round": 1, "max_blocking_severity_rank": 2, "addressed_count": 0}
{"round": 2, "max_blocking_severity_rank": 1, "addressed_count": 3}
JSONL
out=$(converge --rc 1 --round 4 --run-dir "$RD_HC" --max-rounds 4) || fail "converge hc-with-trend exited non-zero"
[ "$out" = "park" ] || fail "hard ceiling must park even when trend is converging, got '$out'"

# ---------------------------------------------------------------------------
# T6 — the new backstops layer ALONGSIDE the existing floors (do not remove them)
# ---------------------------------------------------------------------------
# loop_decision still exists and the default ceiling is now > 3 (the repurposed hard ceiling).
if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
from sail.convergence import loop_decision
assert loop_decision(0, 1) == "proceed"
assert loop_decision(1, 3) == "revise", "round 3 must no longer park at the raised default ceiling"
# The repurposed hard ceiling default is above 3.
import inspect
default = inspect.signature(loop_decision).parameters["max_rounds"].default
assert default > 3, f"hard-ceiling default must be raised above 3, got {default}"
assert loop_decision(1, default) == "park", "at the hard ceiling it must still park"
print("ok-loop")
PY
then
  fail "T6 loop_decision hard-ceiling repurpose failed"
fi
grep -q '^ok-loop$' "$LOG_FILE" || fail "T6 did not reach 'ok-loop'"

# ---------------------------------------------------------------------------
# T7 — docs: commands/sail.md + sail/README.md document the new model + env vars
# ---------------------------------------------------------------------------
assert_md() { grep -qiE "$1" "$2" || fail "$3"; }
assert_md 'trend.stall|convergence.trend' "$SAIL_MD" "sail.md missing the convergence-trend stop"
assert_md 'cost.backstop|cost ceiling|SAIL_COST_CEILING' "$SAIL_MD" "sail.md missing the cost backstop"
assert_md 'hard ceiling|ultimate backstop' "$SAIL_MD" "sail.md missing the hard-ceiling reframing"
assert_md 'SAIL_COST_CEILING_SECONDS' "$SAIL_MD" "sail.md must document the cost-ceiling env var"
assert_md 'SAIL_TREND_WINDOW' "$SAIL_MD" "sail.md must document the trend-window env var"
assert_md 'SAIL_HARD_ROUND_CEILING' "$SAIL_MD" "sail.md must document the hard-ceiling override env var"
[ -f "$README" ] && assert_md 'trend.stall|cost.backstop|hard ceiling' "$README" "README missing the layered oracle decision order"

# #142: the default ceiling and the whack-a-mole stop are documented, and the reference config
# carries the SAIL_COST_CEILING_SECONDS override guidance.
assert_md '14400' "$SAIL_MD" "sail.md must document the 14400s (4h) default cost ceiling"
assert_md 'whack.a.mole|re-?addressed|addressed.*reappear' "$SAIL_MD" "sail.md missing the addressed-reappearance (whack-a-mole) stop"
grep -q 'SAIL_COST_CEILING_SECONDS' "$REPO_ROOT/home/settings.reference.json" \
  || fail "settings.reference.json must document the SAIL_COST_CEILING_SECONDS default/override (#142)"

echo "PASS: test_sail_130_convergence_trend.sh"
