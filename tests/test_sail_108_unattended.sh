#!/usr/bin/env bash
# test_sail_108_unattended.sh
# Issue #108 — standalone unattended /sail: deterministic terminus decisions.
#
# Covers the tested-Python core of the unattended path (the side-effects —
# gh issue create, git commit, land-block — live in commands/sail.md):
#   1. terminus_action(unattended, interactive) -> auto | ask | park-loud
#   2. spec_conflict_floor -> `proceed-dissent` when ALL current-round blocking
#      findings are validly dispositioned spec-conflict and the audit is green.
#   3. no-laundering: a spec-conflict tag with an empty rationale does NOT defuse.
#   4. mixed / undispositioned blocking findings keep the run on revise
#      (spec-conflict is driver-territory; the engine never auto-classifies).
#   5. regression: green still proceeds.
#   6. write_handoff emits a durable wip-handoff.md with reason + ids + resume cmd.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# ---- 1. terminus_action 3-way decision (AC5/AC9) ---------------------------
term() { python3 -m sail terminus "$@"; }

out="$(term --unattended 1 --interactive 1)"; [ "$out" = "auto" ] || fail "unattended=1 -> auto, got '$out'"
out="$(term --unattended 1 --interactive 0)"; [ "$out" = "auto" ] || fail "unattended=1 (any interactive) -> auto, got '$out'"
out="$(term --unattended 0 --interactive 1)"; [ "$out" = "ask" ] || fail "hands-on -> ask, got '$out'"
out="$(term --unattended 0 --interactive 0)"; [ "$out" = "park-loud" ] || fail "headless-no-flag -> park-loud, got '$out'"

# ---- 6. handoff writer (AC6) -----------------------------------------------
RDH="$WORK/handoff"
mkdir -p "$RDH"
python3 -m sail handoff --run-dir "$RDH" --reason oscillation \
  --resume "python3 -m sail run --target . --diff main" \
  --issue 108 --finding-ids RT-1,RT-2 >/dev/null
[ -f "$RDH/wip-handoff.md" ] || fail "handoff did not write wip-handoff.md"
grep -q "oscillation" "$RDH/wip-handoff.md" || fail "handoff missing stop reason"
grep -q "RT-1" "$RDH/wip-handoff.md" || fail "handoff missing finding id"
grep -q "python3 -m sail run --target . --diff main" "$RDH/wip-handoff.md" || fail "handoff missing resume command"
grep -q "108" "$RDH/wip-handoff.md" || fail "handoff missing issue ref"

# ---- 1b. headless-without-flag terminus kernel: park-loud -> handoff -------
# Pins the AC5 resolution: the deterministic guard returns park-loud, and the handoff
# (not a prompt) is what resolves it. The prompt path itself is markdown discipline.
RDP="$WORK/parkloud"
mkdir -p "$RDP"
act="$(term --unattended 0 --interactive 0)"
[ "$act" = "park-loud" ] || fail "park-loud kernel: expected park-loud, got '$act'"
python3 -m sail handoff --run-dir "$RDP" --reason park-loud \
  --resume "python3 -m sail run --target . --diff main" >/dev/null
[ -f "$RDP/wip-handoff.md" ] || fail "park-loud kernel: handoff not written"
grep -q "park-loud" "$RDP/wip-handoff.md" || fail "park-loud kernel: reason missing"

# ---- 2-5. spec_conflict_floor via `converge` (audit-dependent) -------------
TARGET="$WORK/target"
mkdir -p "$TARGET"
cd "$TARGET"
git init -q
git config user.email "t@example.com"
git config user.name "T"
printf 'a\nb\nc\nd\ne\n' > core.py
git add core.py
git commit -q -m base
BASE="$(git rev-parse HEAD)"
export PYTHONPATH="$REPO_ROOT${PYTHONPATH:+:$PYTHONPATH}"
python3 - "$TARGET/core.py" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1]); L = p.read_text().splitlines(); L[2] = "CHANGED"
p.write_text("\n".join(L) + "\n")
PY
DH="$(TARGET="$TARGET" BASE="$BASE" python3 - <<'PY'
import os
from sail import review
print(review.diff_fingerprint(os.environ["TARGET"], os.environ["BASE"]))
PY
)"
export REPO_ROOT TARGET BASE DH WORK
cd "$REPO_ROOT"

python3 - <<'PY'
import json, os, subprocess
from pathlib import Path
from sail import review as review_mod

repo_root = Path(os.environ["REPO_ROOT"])
target = os.environ["TARGET"]; base = os.environ["BASE"]; dh = os.environ["DH"]
work = Path(os.environ["WORK"])

def seed(run_dir, findings, resolutions, *, round_num=2, gate_status="passed",
         ac_status="met", tidiness_blocking=None):
    run_dir = Path(run_dir); run_dir.mkdir(parents=True, exist_ok=True)
    log = ["# /sail decision log"]
    for fid, (disp, rat) in resolutions.items():
        log.append(f"- resolution: [{fid}] {disp} — {rat} [round={round_num}]")
    (run_dir / "decision-log.md").write_text("\n".join(log) + "\n")
    (run_dir / "plan.json").write_text(json.dumps(
        {"status": "completed", "acceptance_criteria": ["one"]}))
    review = {
        "status": "completed", "target": target, "diff_ref": base, "diff_hash": dh,
        "round": round_num, "findings": findings,
        "plan_verification": {"acceptance_criteria": [{"criterion": "one", "status": ac_status}]},
        "tidiness": {"blocking": tidiness_blocking if tidiness_blocking is not None else []},
    }
    review["plan_hash"] = review_mod.plan_fingerprint(str(run_dir))
    (run_dir / "review.json").write_text(json.dumps(review))
    (run_dir / "run-state.json").write_text(json.dumps(
        {"gates": [{"name": "ruff", "status": gate_status}]}))

def converge(run_dir):
    return subprocess.run(
        ["python3", "-m", "sail", "converge", "--rc", "1", "--round", "2",
         "--run-dir", str(run_dir), "--target", target],
        cwd=repo_root, capture_output=True, text=True)

HIGH = lambda fid: {"id": fid, "severity": "HIGH", "file": "core.py", "line": 3}

# case 2: all blocking findings validly dispositioned spec-conflict -> proceed-dissent
rd = work / "c2"
seed(rd, [HIGH("RT-1")], {"RT-1": ("spec-conflict", "objects to the mandated pre-staging design")})
r = converge(rd)
assert r.stdout.strip() == "proceed-dissent", f"case2 expected proceed-dissent, got {r.stdout!r} / {r.stderr!r}"
assert "RT-1" in r.stderr, f"case2 stderr must name the finding id, got {r.stderr!r}"

# case 3: spec-conflict tag with EMPTY rationale -> no laundering -> revise
rd = work / "c3"
seed(rd, [HIGH("RT-1")], {"RT-1": ("spec-conflict", "")})
r = converge(rd)
assert r.stdout.strip() == "revise", f"case3 expected revise, got {r.stdout!r}"

# case 4: mixed — one spec-conflict + one undispositioned HIGH -> revise
rd = work / "c4"
seed(rd, [HIGH("RT-1"), HIGH("BUG-2")],
     {"RT-1": ("spec-conflict", "objects to mandate")})
r = converge(rd)
assert r.stdout.strip() == "revise", f"case4 expected revise, got {r.stdout!r}"

# case 5 (driver-territory): HIGH finding with NO recorded disposition -> revise
rd = work / "c5"
seed(rd, [HIGH("RT-1")], {})
r = converge(rd)
assert r.stdout.strip() == "revise", f"case5 expected revise, got {r.stdout!r}"

# case 6 (audit-green guard): valid spec-conflict disposition BUT a FAILING gate audit
# -> the floor stays shut (mechanically unsound) -> revise, NOT proceed-dissent.
rd = work / "c6"
seed(rd, [HIGH("RT-1")], {"RT-1": ("spec-conflict", "objects to mandate")}, gate_status="failed")
r = converge(rd)
assert r.stdout.strip() == "revise", f"case6 expected revise (red audit), got {r.stdout!r}"

# case 7 (driver-territory): a finding that carries an ENGINE-EMITTED `disposition: spec-conflict`
# in review.json, with NO driver decision-log resolution, must be IGNORED -> revise. The disposition
# is honored only from the driver-written decision log, never from a finding the engine emitted.
rd = work / "c7"
engine_finding = {"id": "RT-1", "severity": "HIGH", "file": "core.py", "line": 3,
                  "disposition": "spec-conflict", "rationale": "engine should not be trusted here"}
seed(rd, [engine_finding], {})
r = converge(rd)
assert r.stdout.strip() == "revise", f"case7 expected revise (engine-emitted disposition ignored), got {r.stdout!r}"

# case 8 (acs_all_met conjunct): valid spec-conflict disposition + green gates BUT an UNMET AC
# -> floor stays shut -> revise. Pins the acs_all_met conjunct independently (#108 review LOW).
rd = work / "c8"
seed(rd, [HIGH("RT-1")], {"RT-1": ("spec-conflict", "objects to mandate")}, ac_status="unmet")
r = converge(rd)
assert r.stdout.strip() == "revise", f"case8 expected revise (unmet AC), got {r.stdout!r}"

# case 9 (tidiness_clear conjunct): valid spec-conflict disposition + green audit BUT a blocking
# tidiness finding -> floor stays shut -> revise. Pins the tidiness_clear conjunct independently.
rd = work / "c9"
seed(rd, [HIGH("RT-1")], {"RT-1": ("spec-conflict", "objects to mandate")},
     tidiness_blocking=[{"id": "TIDY-1"}])
r = converge(rd)
assert r.stdout.strip() == "revise", f"case9 expected revise (dirty tidiness), got {r.stdout!r}"

print("python spec_conflict_floor cases passed")
PY

# ---- 5b. regression: green still proceeds ----------------------------------
out="$(python3 -m sail converge --rc 0 --round 1)"
[ "$out" = "proceed" ] || fail "green regression: expected proceed, got '$out'"

echo "PASS: test_sail_108_unattended.sh"
