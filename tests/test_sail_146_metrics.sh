#!/usr/bin/env bash
# test_sail_146_metrics.sh — #146: sail metrics — per-run telemetry ledger + cross-run rollup.
#
# A deterministic `sail/metrics.py` module + `sail metrics {record|report|escape}` CLI. This is the
# enabler for every future /sail tuning decision — you can't tune what you don't measure. The module
# is the ONLY home for the logic (schema/append/aggregation/escape linkage); the CLI shim and the
# markdown driver only parse args and move bytes (CLAUDE.md infra-placement).
#
# Repo is SHELL-TEST-ONLY (no pytest suite), so the deterministic Python is unit-tested INLINE via
# python3 (the established test_sail_95/113/131 pattern). All assertions run against a TEMP ledger in
# a tmp dir with SAIL_* cleared — hermetic, no live git/working-tree/backend dependence (except Part
# G, which builds a throwaway git repo + worktree to pin ledger-path durability).
#
# shellcheck disable=SC1091
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
unset "${!SAIL_@}" || true   # hermetic: a real shell exports SAIL_* backend knobs — clear them
cd "$REPO_ROOT"
fail() { echo "FAIL: $*"; exit 1; }

# ============================================================================
# Part A — the record SCHEMA is built from run-dir artifacts and round-trips (AC#1)
#   build_record reads run-state.json + review.json + decision-log.md and assembles ONE record;
#   append_record writes exactly ONE JSON line; tokens/cost default to null (never fabricated).
# ============================================================================
python3 - "$WORK" <<'PY' || fail "A: build_record schema + append one line + null cost"
import os, sys, json
from sail import metrics
from sail.runstate import RunState
from sail.decisionlog import DecisionLog

rd = os.path.join(sys.argv[1], "rd_a"); os.makedirs(rd, exist_ok=True)
# Minimal run-state.json (as RunState.init would write it) + a couple of gate verdicts.
st = RunState.init(rd, ["ruff", "pytest", "bandit"])
st.gates[0]["status"] = "passed"
st.gates[1]["status"] = "passed"
st.gates[2]["status"] = "skipped"
st.data["mode"] = "diff"
st.save()
# A completed review.json with findings across lenses + severities.
review = {
    "status": "completed", "round": 2,
    "counts": {"CRITICAL": 0, "HIGH": 0, "MEDIUM": 1, "LOW": 2},
    "findings": [
        {"severity": "MEDIUM", "lens": "lens1"},
        {"severity": "LOW", "lens": "lens1"},
        {"severity": "LOW", "lens": "redteam"},
    ],
    "lenses": ["lens1", "redteam"],
    "dual_lens_requested": False, "lens2_ran": False, "lens2_configured": False, "lens2_latched": False,
    "redteam_requested": True, "redteam_ran": True, "redteam_configured": True, "redteam_latched": False,
    "empty_diff": False,
}
json.dump(review, open(os.path.join(rd, "review.json"), "w"))
log = DecisionLog(rd)
log.finding_resolution("f1", "addressed", "fixed the guard", round=1)
log.finding_resolution("f2", "deferred", "out of scope", round=2)

rec = metrics.build_record(
    rd, issue="146", terminus="merged-green",
    backends={"build": "codex exec", "review": "claude -p", "review2": None, "redteam": "claude -p"},
    now="2026-07-20T18:00:00Z",
)
# Core identity + schema fields
assert rec["type"] == "cycle", rec
assert rec["issue"] == "146"
assert rec["run_id"] == st.run_id, "run_id must come from run-state.json"
assert rec["started_at"] == st.started_at
assert rec["finished_at"] == "2026-07-20T18:00:00Z"
assert rec["terminus"] == "merged-green"
assert rec["mode"] == "diff"
# Rounds
assert rec["review_rounds"] == 2, rec["review_rounds"]
# Gate outcome summary
assert rec["gate_summary"]["passed"] == 2 and rec["gate_summary"]["skipped"] == 1 and rec["gate_summary"]["failed"] == 0, rec["gate_summary"]
# Findings by severity AND by lens
assert rec["finding_counts"]["by_severity"]["MEDIUM"] == 1 and rec["finding_counts"]["by_severity"]["LOW"] == 2, rec
assert rec["finding_counts"]["by_lens"]["lens1"] == 2 and rec["finding_counts"]["by_lens"]["redteam"] == 1, rec
# Disposition mix
assert rec["disposition_mix"].get("addressed") == 1 and rec["disposition_mix"].get("deferred") == 1, rec
# Degraded flags (#116): redteam configured+ran, lens2 unconfigured -> NOT degraded
assert rec["degraded"] is False, rec
# Backends recorded
assert rec["backends"]["build"] == "codex exec" and rec["backends"]["review2"] is None
# tokens/cost default to null — NEVER fabricated
assert rec["tokens"] is None and rec["cost_usd"] is None, "cost must be null when no backend usage supplied"

# append_record writes exactly ONE JSON line and creates the file + dir
ledger = os.path.join(sys.argv[1], "sub", "metrics.jsonl")
metrics.append_record(rec, ledger)
lines = open(ledger).read().splitlines()
assert len(lines) == 1, f"expected 1 line, got {len(lines)}"
assert json.loads(lines[0])["run_id"] == st.run_id, "round-trip lost run_id"
PY

# ============================================================================
# Part B — append is IDEMPOTENT on run_id (AC: resume/re-run must not double-count) (risk 1)
# ============================================================================
python3 - "$WORK" <<'PY' || fail "B: append_record idempotent on run_id"
import os, sys, json
from sail import metrics
ledger = os.path.join(sys.argv[1], "idem", "metrics.jsonl")
rec = {"type": "cycle", "run_id": "RID-1", "issue": "146", "terminus": "merged-green"}
metrics.append_record(rec, ledger)
metrics.append_record(dict(rec, terminus="parked"), ledger)   # same run_id, second attempt
lines = [json.loads(x) for x in open(ledger).read().splitlines()]
cycles = [r for r in lines if r.get("type") == "cycle" and r.get("run_id") == "RID-1"]
assert len(cycles) == 1, f"run_id RID-1 double-appended: {len(cycles)} lines"
# a DIFFERENT run_id still appends
metrics.append_record({"type": "cycle", "run_id": "RID-2", "issue": "9", "terminus": "parked"}, ledger)
assert sum(1 for r in [json.loads(x) for x in open(ledger).read().splitlines()] if r.get("type")=="cycle") == 2
PY

# ============================================================================
# Part C — report() aggregates across runs (AC#2): counts, rates, avg rounds, cost-per-merged
#   null-cost lines are EXCLUDED from the cost denominator (never counted as 0) (risk 2)
# ============================================================================
python3 - "$WORK" <<'PY' || fail "C: aggregate rates + avg rounds + cost-per-merged"
import os, sys, json
from sail import metrics
ledger = os.path.join(sys.argv[1], "agg", "metrics.jsonl")
rows = [
    {"type":"cycle","run_id":"a","issue":"1","terminus":"merged-green","review_rounds":1,"plan_rounds":1,"degraded":False,"cost_usd":0.50},
    {"type":"cycle","run_id":"b","issue":"2","terminus":"merged-green","review_rounds":3,"plan_rounds":1,"degraded":True,"cost_usd":None},
    {"type":"cycle","run_id":"c","issue":"3","terminus":"proceed-hardening","review_rounds":2,"plan_rounds":1,"degraded":False,"cost_usd":1.50},
    {"type":"cycle","run_id":"d","issue":"4","terminus":"parked","park_reason":"oscillation","review_rounds":4,"plan_rounds":2,"degraded":False,"cost_usd":None},
    # A PARKED run that nonetheless burned real cost (a run can churn many rounds then park). It MUST
    # be excluded from cost-per-merged (the metric is per SHIPPED issue) but still shows in the honest
    # total. This row makes merged-count (2), shipped-with-cost (2) and runs_with_cost (3) all diverge,
    # so a divisor swap ('merged/shipped' vs 'any costed run') cannot survive unnoticed (test-adequacy).
    {"type":"cycle","run_id":"e","issue":"5","terminus":"parked","park_reason":"cost-backstop","review_rounds":1,"plan_rounds":1,"degraded":False,"cost_usd":5.00},
]
for r in rows: metrics.append_record(r, ledger)
agg = metrics.aggregate(metrics.read_ledger(ledger))
assert agg["cycles"] == 5, agg
# merged-green counts as merged; proceed-hardening/dissent are shipped but not "merged-green"
assert agg["merged"] == 2, agg["merged"]
assert agg["shipped"] == 3, agg["shipped"]           # merged-green x2 + hardening x1
assert agg["parked"] == 2, agg["parked"]             # d + e
assert abs(agg["merge_rate"] - 0.4) < 1e-9, agg["merge_rate"]
assert abs(agg["park_rate"] - 0.4) < 1e-9, agg["park_rate"]
assert abs(agg["avg_review_rounds"] - 2.2) < 1e-9, agg["avg_review_rounds"]  # (1+3+2+4+1)/5
assert agg["degraded_runs"] == 1 and abs(agg["degraded_rate"] - 0.2) < 1e-9, agg
# TOTAL cost is honest across ALL costed rows (0.50+1.50+5.00 = 7.00 over 3 runs) ...
assert agg["cost"]["runs_with_cost"] == 3, agg["cost"]
assert abs(agg["cost"]["total_usd"] - 7.00) < 1e-9, agg["cost"]
# ... but COST-PER-MERGED is over SHIPPED-with-cost ONLY: (0.50 merged + 1.50 hardening)/2 = 1.00.
# The parked-but-costed 'e' (5.00) is EXCLUDED — else the number would be 7.00/3 = 2.33 (the bug).
assert agg["cost"]["cost_per_merged"] is not None and abs(agg["cost"]["cost_per_merged"] - 1.00) < 1e-9, agg["cost"]
PY

# ============================================================================
# Part D — escape linkage (AC#3) + escape RATE consumer (AC: no inert promise)
#   record_escape links to the MOST-RECENT shipped run for the issue (tie-break = latest finished);
#   report's escape rate consumes those escape records.
# ============================================================================
python3 - "$WORK" <<'PY' || fail "D: record_escape links latest shipped run + report escape rate"
import os, sys, json
from sail import metrics
ledger = os.path.join(sys.argv[1], "esc", "metrics.jsonl")
# Two shipped runs for issue 130; the LATER-finished one must be the escape's linked run.
metrics.append_record({"type":"cycle","run_id":"old","issue":"130","terminus":"merged-green","finished_at":"2026-07-01T00:00:00Z"}, ledger)
metrics.append_record({"type":"cycle","run_id":"new","issue":"130","terminus":"merged-green","finished_at":"2026-07-05T00:00:00Z"}, ledger)
metrics.append_record({"type":"cycle","run_id":"other","issue":"999","terminus":"merged-green","finished_at":"2026-07-09T00:00:00Z"}, ledger)
esc = metrics.record_escape("130", "regression in report()", ledger, now="2026-07-10T00:00:00Z")
assert esc is not None and esc["type"] == "escape", esc
assert esc["run_id"] == "new", f"escape linked wrong run: {esc['run_id']}"
assert esc["issue"] == "130" and "regression" in esc["note"]
# It was persisted...
lines = [json.loads(x) for x in open(ledger).read().splitlines()]
assert any(r.get("type") == "escape" and r.get("run_id") == "new" for r in lines), "escape not appended"
# ...and report's escape rate consumes it: 1 escape over 3 shipped runs.
agg = metrics.aggregate(metrics.read_ledger(ledger))
assert agg["escapes"] == 1, agg["escapes"]
assert agg["shipped"] == 3, agg["shipped"]
assert abs(agg["escape_rate"] - (1/3)) < 1e-9, agg["escape_rate"]
# An escape for an issue with NO shipped run returns None and appends nothing (fail-safe).
before = len(open(ledger).read().splitlines())
assert metrics.record_escape("nonesuch", "x", ledger) is None
assert len(open(ledger).read().splitlines()) == before, "escape for unknown issue must not append"
# A SECOND, DISTINCT escape against the SAME shipped run must PERSIST — escapes are events, not
# idempotent-per-run. (Regression: keying escape dedup on the linked shipped run_id silently dropped
# the 2nd defect traced to one merge.) Both escape lines must survive; escape count must reach 2.
esc2 = metrics.record_escape("130", "a SECOND distinct post-land defect", ledger, now="2026-07-11T00:00:00Z")
assert esc2 is not None and esc2["run_id"] == "new", esc2
agg2 = metrics.aggregate(metrics.read_ledger(ledger))
assert agg2["escapes"] == 2, f"a distinct second escape against the same run must not be de-duplicated away: {agg2['escapes']}"
PY

# ============================================================================
# Part E — TOLERANT reader: a malformed/truncated line is skipped, valid lines still aggregate
#          (risk 2 — a naive reader would raise or miscount) (AC#4)
# ============================================================================
python3 - "$WORK" <<'PY' || fail "E: tolerant reader skips malformed lines"
import os, sys, json
from sail import metrics
ledger = os.path.join(sys.argv[1], "tol", "metrics.jsonl")
os.makedirs(os.path.dirname(ledger), exist_ok=True)
with open(ledger, "w") as fh:
    fh.write(json.dumps({"type":"cycle","run_id":"ok1","issue":"1","terminus":"merged-green"}) + "\n")
    fh.write("{not valid json at all\n")                 # garbage line
    fh.write("\n")                                        # blank line
    fh.write('{"type":"cycle","run_id":"ok2","issue":"2","terminus":"parked"}\n')
    fh.write('{"type":"cycle","run_id":"ok3","issue":"3","terminus":"merged-gr')  # truncated last line (no newline)
rows = metrics.read_ledger(ledger)
ids = sorted(r.get("run_id") for r in rows if r.get("type") == "cycle")
assert ids == ["ok1", "ok2"], f"tolerant reader should yield only the 2 well-formed complete lines, got {ids}"
agg = metrics.aggregate(rows)   # must not raise on the malformed history
assert agg["cycles"] == 2, agg
PY

# ============================================================================
# Part F — FAIL-OPEN (AC: any metrics error logs a note and NEVER blocks/fails a run)
#   record_cycle swallows every exception (unwritable ledger, missing artifacts) and returns None;
#   the CLI `record` path ALWAYS exits 0 (telemetry must never fail the enclosing run).
# ============================================================================
python3 - "$WORK" <<'PY' || fail "F: record_cycle fail-open on unwritable ledger + missing run-dir"
import os, sys
from sail import metrics
# Unwritable ledger path (parent is a FILE, not a dir) -> must not raise, returns None.
blocker = os.path.join(sys.argv[1], "blocker"); open(blocker, "w").write("x")
bad_ledger = os.path.join(blocker, "metrics.jsonl")   # can't mkdir under a file
out = metrics.record_cycle(os.path.join(sys.argv[1], "rd_a"), issue="146", terminus="merged-green", ledger_path=bad_ledger)
assert out is None, "record_cycle must return None (fail-open) on an unwritable ledger, not raise"
# Missing run-dir entirely -> still fail-open.
out2 = metrics.record_cycle(os.path.join(sys.argv[1], "does-not-exist"), issue="146", terminus="parked", ledger_path=os.path.join(sys.argv[1], "fo", "m.jsonl"))
assert out2 is None or isinstance(out2, dict)   # either safely skipped or wrote a defaulted record; must not raise
PY
# CLI record on an unwritable ledger STILL exits 0 (never blocks the run)
BLK="$WORK/blk"; : > "$BLK"
python3 -m sail metrics record --run-dir "$WORK/rd_a" --issue 146 --terminus merged-green --ledger "$BLK/metrics.jsonl" >/dev/null 2>&1 \
  || fail "F-CLI: 'sail metrics record' must exit 0 even when the ledger is unwritable (fail-open)"

# ============================================================================
# Part G — the ledger is DURABLE per-repo: resolve_ledger_path points at the PRIMARY worktree's
#   .sail/ even when called from inside a linked worktree (so a worktree prune at land never drops
#   the history). Uses a throwaway git repo — the one place a live git is needed.
# ============================================================================
G="$WORK/grepo"; mkdir -p "$G"; ( cd "$G"
  git init -q; git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m init
  git worktree add -q wt >/dev/null 2>&1
)
python3 - "$G" <<'PY' || fail "G: resolve_ledger_path resolves to the PRIMARY repo .sail from a worktree"
import os, sys
from sail import metrics
primary = sys.argv[1]
wt = os.path.join(primary, "wt")
p = metrics.resolve_ledger_path(wt)
assert os.path.basename(p) == "metrics.jsonl", p
# Must land under the PRIMARY root's .sail, NOT the linked worktree's .sail (durability).
assert os.path.realpath(p) == os.path.realpath(os.path.join(primary, ".sail", "metrics.jsonl")), \
    f"ledger must resolve to primary .sail, got {p}"
PY

# ============================================================================
# Part H — the CLI subcommands are REACHABLE and delegate (no logic in the shim) (AC: thin CLI)
# ============================================================================
LEDGER="$WORK/cli/metrics.jsonl"
python3 -m sail metrics record --run-dir "$WORK/rd_a" --issue 146 --terminus merged-green --ledger "$LEDGER" \
  || fail "H1: 'sail metrics record' rc!=0"
[ -f "$LEDGER" ] && grep -q '"issue": *"146"' "$LEDGER" || grep -q '"issue":"146"' "$LEDGER" || fail "H2: record did not append the cycle line"
# report reads the ledger and prints an aggregation (human-readable), exit 0
python3 -m sail metrics report --ledger "$LEDGER" | grep -qiE "run|cycle|merge" || fail "H3: 'sail metrics report' produced no rollup"
# escape via CLI (no shipped run for 146 in THIS fresh ledger? there is one merged-green -> links it)
python3 -m sail metrics escape 146 --note "late defect" --ledger "$LEDGER" >/dev/null 2>&1 || fail "H4: 'sail metrics escape' rc!=0"
grep -q '"type": *"escape"' "$LEDGER" || grep -q '"type":"escape"' "$LEDGER" || fail "H5: escape record not appended by CLI"

# ============================================================================
# Part K — a duplicate cycle line (same run_id) is collapsed at READ/aggregate time, so a
#   concurrent-append race (check-then-act with no lock — this repo's orphan-resume double-ownership
#   class) can never DOUBLE-COUNT a run in any rate. Distinct escapes are NOT collapsed (Part D).
# ============================================================================
python3 - "$WORK" <<'PY' || fail "K: aggregate collapses duplicate cycle run_ids"
import os, sys, json
from sail import metrics
ledger = os.path.join(sys.argv[1], "dup", "metrics.jsonl")
os.makedirs(os.path.dirname(ledger), exist_ok=True)
with open(ledger, "w") as fh:  # write raw duplicate lines, bypassing append's best-effort guard
    fh.write(json.dumps({"type":"cycle","run_id":"dupe","issue":"1","terminus":"merged-green"}) + "\n")
    fh.write(json.dumps({"type":"cycle","run_id":"dupe","issue":"1","terminus":"merged-green"}) + "\n")
    fh.write(json.dumps({"type":"cycle","run_id":"other","issue":"2","terminus":"parked"}) + "\n")
agg = metrics.aggregate(metrics.read_ledger(ledger))
assert agg["cycles"] == 2, f"duplicate cycle run_id must collapse to one: {agg['cycles']}"
assert agg["merged"] == 1, agg["merged"]
PY

# ============================================================================
# Part L — build_record NEVER defaults an unresolved terminus to the OPTIMISTIC 'merged-green'
#   (that would silently inflate the merge rate for any direct API caller). An absent terminus with
#   no review-recorded terminus records the honest 'unknown' bucket (excluded from every rate).
# ============================================================================
python3 - "$WORK" <<'PY' || fail "L: build_record defaults unresolved terminus to 'unknown', not 'merged-green'"
import os, sys
from sail import metrics
rec = metrics.build_record(os.path.join(sys.argv[1], "rd_a"), issue="146", terminus=None)
assert rec is not None
assert rec["terminus"] == "unknown", f"unresolved terminus must be 'unknown', got {rec['terminus']!r}"
# and 'unknown' counts in neither merged nor parked nor shipped
agg = metrics.aggregate([rec])
assert agg["merged"] == 0 and agg["parked"] == 0 and agg["shipped"] == 0, agg
PY

# ============================================================================
# Part I — DOCS carry the feature (AC#6)
# ============================================================================
grep -qi "sail metrics" commands/sail.md || fail "I1: commands/sail.md must document 'sail metrics'"
grep -qi "metrics.jsonl" commands/sail.md || fail "I2: commands/sail.md must name the ledger .sail/metrics.jsonl"
grep -qi "escape" commands/sail.md || fail "I3: commands/sail.md must document the escape subcommand"
grep -qi "metrics" sail/README.md || fail "I4: sail/README.md must note the metrics module"
# The emit must be WIRED at the Stage-4 terminus, not left as a preamble-only note (redteam #146):
# require the concrete `sail metrics record` invocation to appear at least twice (overview + the
# actual terminus bash block) so collection doesn't depend on the driver recalling a preamble line.
[ "$(grep -c 'sail metrics record' commands/sail.md)" -ge 2 ] || fail "I5: 'sail metrics record' must be wired inline at the Stage-4 terminus block, not only in the preamble"

# ============================================================================
# Part J — the emit is DRIVER-owned, NOT wired into the per-ROUND runner (structural pin).
#   `run()` is invoked once per convergence ROUND and cannot know the cycle TERMINUS (proceed /
#   park / proceed-hardening / proceed-dissent — a driver/converge-oracle decision). A per-round
#   emit inside run() would, with run_id idempotence, LATCH the first round's guessed terminus for
#   the whole cycle and corrupt every merge/park rate. So the metrics emit must live at the driver's
#   Stage-4 terminus (`sail metrics record --terminus <converge-decision>`), never in runner.run().
#   Pinned structurally (the established sail-test pattern) — grep for the CALL, not the word.
# ============================================================================
if grep -Eq 'record_cycle|metrics_mod|from sail import metrics|import metrics' sail/runner.py; then
  fail "J: sail/runner.py must NOT wire the metrics emit into the per-round run() — the emit is driver-owned at the converge terminus (a per-round emit latches a wrong terminus under run_id idempotence)"
fi

echo "PASS: test_sail_146_metrics"
