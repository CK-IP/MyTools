#!/usr/bin/env bash
# test_sail_132_same_area_saturation.sh
# Issue #132 — same-area saturation signal in the convergence loop.
#
# The by-id oscillation park (#100) only fires when a finding REAPPEARS by id. On #124 the run
# spent 4+ consecutive rounds in ONE area (worker spawn/lifecycle mechanics) but each round produced
# NEW finding ids (deeper layers of one hard domain), so the oracle read it as pure progress and
# never surfaced "stuck in one corner for N rounds." This adds a deterministic, advisory same-area
# saturation signal: N consecutive rounds whose blocking findings concentrate on the same file/area
# → an advisory stderr callout (a steer: widen budget / rethink the design). It is INFORMATIONAL —
# it NEVER changes the proceed/revise/park decision or the exit code, and is explicitly distinct
# from the by-id genuine-oscillation PARK.
#
# Hermetic: pure-function imports + seeded run-dir artifacts; no live LLM backend. The CLI subtest
# seeds the trend ledger directly (hydration is strong-freshness gated and no-ops without a fresh
# review.json, so it never pollutes the seeded ledger); the hydrate subtest monkeypatches the
# freshness gate so it needs no git.

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
# T1 — dominant_area_for_findings: modal blocking-finding `file`
# ---------------------------------------------------------------------------
if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
from sail.convergence import dominant_area_for_findings

# Modal non-null file among BLOCKING (CRITICAL/HIGH) findings.
assert dominant_area_for_findings(
    [{"severity": "HIGH", "file": "a"}, {"severity": "HIGH", "file": "a"}, {"severity": "CRITICAL", "file": "b"}]
) == "a"

# MEDIUM/LOW are NOT blocking — never counted (so a round of only non-blocking findings has no area).
assert dominant_area_for_findings(
    [{"severity": "MEDIUM", "file": "a"}, {"severity": "LOW", "file": "a"}]
) is None
# A blocking finding's file wins even when a non-blocking finding piles onto another file.
assert dominant_area_for_findings(
    [{"severity": "HIGH", "file": "a"}, {"severity": "LOW", "file": "b"}, {"severity": "LOW", "file": "b"}]
) == "a"

# Degenerate inputs -> None.
assert dominant_area_for_findings([]) is None
assert dominant_area_for_findings("not-a-list") is None
assert dominant_area_for_findings(None) is None

# All-null files -> None.
assert dominant_area_for_findings([{"severity": "HIGH", "file": None}, {"severity": "CRITICAL"}]) is None

# A clean TIE with no single mode -> None (only fires on a genuine single concentration).
assert dominant_area_for_findings(
    [{"severity": "HIGH", "file": "a"}, {"severity": "CRITICAL", "file": "b"}]
) is None

# Case-insensitive severity, and null files are ignored when computing the mode.
assert dominant_area_for_findings(
    [{"severity": "high", "file": "x"}, {"severity": "high", "file": "x"}, {"severity": "high", "file": None}]
) == "x"
print("ok-area")
PY
then
  fail "dominant_area_for_findings not implemented to contract"
fi
grep -q '^ok-area$' "$LOG_FILE" || fail "T1 dominant_area_for_findings did not reach 'ok-area'"

# ---------------------------------------------------------------------------
# T2 — saturation streak + reset semantics + window knob
# ---------------------------------------------------------------------------
if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
import os
from sail.convergence import (
    same_area_saturation_streak, area_saturated, saturation_window,
)

def rows(areas):
    return [{"round": i + 1, "area": a} for i, a in enumerate(areas)]

# Trailing consecutive rounds sharing one non-null area.
assert same_area_saturation_streak(rows(["a", "a", "a"])) == 3
# Change in the latest area resets the trailing streak.
assert same_area_saturation_streak(rows(["a", "a", "b"])) == 1
# A None area resets the streak (a round with no single concentration breaks the run).
assert same_area_saturation_streak(rows(["a", None, "a"])) == 1
# Latest area None -> streak 0.
assert same_area_saturation_streak(rows(["a", "a", None])) == 0
# A single round can be a streak of 1 (its own area).
assert same_area_saturation_streak(rows(["a"])) == 1
# Empty / non-list -> 0, never raises.
assert same_area_saturation_streak([]) == 0
assert same_area_saturation_streak("nope") == 0

# area_saturated honors the window.
assert area_saturated(rows(["a", "a", "a"]), window=3) is True
assert area_saturated(rows(["a", "a", "a"]), window=4) is False
assert area_saturated(rows(["a", "a", "b"]), window=1) is True
assert area_saturated(rows(["a", "a", None]), window=1) is False  # latest None -> streak 0

# Window knob: default 3, override, garbled/non-positive -> 3.
assert saturation_window() == 3
os.environ["SAIL_SATURATION_WINDOW"] = "2"
assert saturation_window() == 2
os.environ["SAIL_SATURATION_WINDOW"] = "0"
assert saturation_window() == 3
os.environ["SAIL_SATURATION_WINDOW"] = "x"
assert saturation_window() == 3
del os.environ["SAIL_SATURATION_WINDOW"]
# area_saturated(window=None) reads saturation_window() (default 3).
assert area_saturated(rows(["a", "a", "a"])) is True
assert area_saturated(rows(["a", "a"])) is False
print("ok-streak")
PY
then
  fail "saturation streak / window contract not implemented"
fi
grep -q '^ok-streak$' "$LOG_FILE" || fail "T2 saturation streak did not reach 'ok-streak'"

# ---------------------------------------------------------------------------
# T3 — ledger threads `area`; backward-compatible with pre-#132 area-less rows
# ---------------------------------------------------------------------------
if ! python3 - "$TMP_ROOT/rd_area" "$TMP_ROOT/rd_legacy" <<'PY' >"$LOG_FILE" 2>&1
import os, sys, json
from sail.convergence import (
    record_trend_row, read_trend, same_area_saturation_streak,
)
rd = sys.argv[1]
# record_trend_row gains an optional `area` threaded into the row and read back.
assert record_trend_row(rd, 1, 1, 0, area="sail/lifecycle.py") is True
assert record_trend_row(rd, 2, 1, 0, area="sail/lifecycle.py") is True
assert record_trend_row(rd, 3, 1, 0, area="sail/lifecycle.py") is True
rows = read_trend(rd)
assert [r["round"] for r in rows] == [1, 2, 3], rows
assert all(r.get("area") == "sail/lifecycle.py" for r in rows), rows
assert same_area_saturation_streak(rows) == 3, rows
# area defaults to None when omitted (still backward-compatible signature).
assert record_trend_row(rd + "_b", 1, 1, 0) is True
assert read_trend(rd + "_b")[0].get("area") is None

# Backward-compat: a ledger seeded with PRE-#132 rows that lack the `area` key must read without
# raising, with area treated as None, and the streak degrades safely to 0.
legacy = sys.argv[2]; os.makedirs(legacy, exist_ok=True)
with open(os.path.join(legacy, "trend-ledger.jsonl"), "w") as fh:
    fh.write(json.dumps({"round": 1, "max_blocking_severity_rank": 1, "addressed_count": 0}) + "\n")
    fh.write(json.dumps({"round": 2, "max_blocking_severity_rank": 1, "addressed_count": 0}) + "\n")
    fh.write(json.dumps({"round": 3, "max_blocking_severity_rank": 1, "addressed_count": 0}) + "\n")
rows = read_trend(legacy)
assert len(rows) == 3, rows
assert all(r.get("area") is None for r in rows), rows
assert same_area_saturation_streak(rows) == 0, "area-less legacy rows must never fire saturation"
print("ok-ledger")
PY
then
  fail "T3 ledger area threading / backward-compat not implemented"
fi
grep -q '^ok-ledger$' "$LOG_FILE" || fail "T3 ledger did not reach 'ok-ledger'"

# ---------------------------------------------------------------------------
# T4 — hydration records the dominant area from the round's review.json findings
# ---------------------------------------------------------------------------
# Monkeypatch the strong-freshness gate so the test needs no git; this isolates the area-recording
# behavior of hydrate_trend_row (proving hydrate-before-decision ordering: the row carries the area).
if ! python3 - "$TMP_ROOT/rd_hydrate" <<'PY' >"$LOG_FILE" 2>&1
import os, sys, json
import sail.convergence as C
rd = sys.argv[1]; os.makedirs(rd, exist_ok=True)
C.review_current_and_clean = lambda run_dir, target, round: True
with open(os.path.join(rd, "review.json"), "w") as fh:
    json.dump({
        "status": "completed", "round": 5,
        "findings": [
            {"id": "f1", "severity": "HIGH", "file": "sail/lifecycle.py"},
            {"id": "f2", "severity": "CRITICAL", "file": "sail/lifecycle.py"},
            {"id": "f3", "severity": "LOW", "file": "sail/other.py"},
        ],
    }, fh)
C.hydrate_trend_row(rd, ".", 5)
rows = C.read_trend(rd)
row = next(r for r in rows if r["round"] == 5)
assert row.get("area") == "sail/lifecycle.py", row
assert row.get("max_blocking_severity_rank") == 2, row
print("ok-hydrate")
PY
then
  fail "T4 hydrate_trend_row does not record the dominant area"
fi
grep -q '^ok-hydrate$' "$LOG_FILE" || fail "T4 hydrate did not reach 'ok-hydrate'"

# ---------------------------------------------------------------------------
# T5 — CLI: advisory callout fires, decision is BYTE-IDENTICAL to the non-saturated run
# ---------------------------------------------------------------------------
converge() { python3 -m sail converge "$@" 2>"$TMP_ROOT/stderr.log"; }

# A saturated ledger (trailing 3 rounds in one area). SAIL_TREND_WINDOW high + big --max-rounds +
# no cost ceiling => the decision is plain "revise"; only the saturation callout differs.
RD_SAT="$TMP_ROOT/rd_sat"; mkdir -p "$RD_SAT"
cat > "$RD_SAT/trend-ledger.jsonl" <<'JSONL'
{"round": 1, "max_blocking_severity_rank": 1, "addressed_count": 0, "area": "sail/lifecycle.py"}
{"round": 2, "max_blocking_severity_rank": 1, "addressed_count": 0, "area": "sail/lifecycle.py"}
{"round": 3, "max_blocking_severity_rank": 1, "addressed_count": 0, "area": "sail/lifecycle.py"}
JSONL

# A non-saturated ledger: same ranks/addressed (=> same decision) but DIFFERENT areas each round.
RD_NOSAT="$TMP_ROOT/rd_nosat"; mkdir -p "$RD_NOSAT"
cat > "$RD_NOSAT/trend-ledger.jsonl" <<'JSONL'
{"round": 1, "max_blocking_severity_rank": 1, "addressed_count": 0, "area": "sail/a.py"}
{"round": 2, "max_blocking_severity_rank": 1, "addressed_count": 0, "area": "sail/b.py"}
{"round": 3, "max_blocking_severity_rank": 1, "addressed_count": 0, "area": "sail/c.py"}
JSONL

sat_out=$(SAIL_TREND_WINDOW=99 converge --rc 1 --round 3 --run-dir "$RD_SAT" --max-rounds 99) || fail "converge saturated exited non-zero"
grep -qi "same.area.saturation" "$TMP_ROOT/stderr.log" || fail "saturated ledger must emit the same-area-saturation callout to stderr"
grep -qi "lifecycle.py" "$TMP_ROOT/stderr.log" || fail "the callout must name the saturated area"

nosat_out=$(SAIL_TREND_WINDOW=99 converge --rc 1 --round 3 --run-dir "$RD_NOSAT" --max-rounds 99) || fail "converge non-saturated exited non-zero"
grep -qi "same.area.saturation" "$TMP_ROOT/stderr.log" && fail "a non-saturated (different-area) ledger must NOT emit the saturation callout"

# The decision (stdout) must be byte-identical between the saturated and non-saturated runs —
# proving the saturation check is purely advisory and never alters the decision.
[ "$sat_out" = "revise" ] || fail "saturated run decision must be 'revise', got '$sat_out'"
[ "$sat_out" = "$nosat_out" ] || fail "saturation must not change the decision: '$sat_out' != '$nosat_out'"

# Green (rc 0) never emits the steer (green is done — no steering needed).
SAIL_TREND_WINDOW=99 converge --rc 0 --round 3 --run-dir "$RD_SAT" --max-rounds 99 >/dev/null
grep -qi "same.area.saturation" "$TMP_ROOT/stderr.log" && fail "rc 0 (green) must not emit the saturation steer"
true

# ---------------------------------------------------------------------------
# T6 — docs: commands/sail.md + sail/README.md document the advisory signal
# ---------------------------------------------------------------------------
assert_md() { grep -qiE "$1" "$2" || fail "$3"; }
assert_md 'same.area.saturation|same-area saturation|stuck.in.one.corner' "$SAIL_MD" "sail.md missing the same-area saturation signal"
assert_md 'SAIL_SATURATION_WINDOW' "$SAIL_MD" "sail.md must document the SAIL_SATURATION_WINDOW env var"
[ -f "$README" ] && assert_md 'same.area.saturation|same-area saturation|SAIL_SATURATION_WINDOW' "$README" "README missing the same-area saturation signal"

echo "PASS: test_sail_132_same_area_saturation.sh"
