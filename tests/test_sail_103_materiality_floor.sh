#!/usr/bin/env bash
# test_sail_103_materiality_floor.sh
# Issue #103 — two-lens materiality floor + round-aware dispositions.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

TARGET="$WORK/target"
mkdir -p "$TARGET"
cd "$TARGET"

git init -q
git config user.email "codex@example.com"
git config user.name "Codex"

cat > core.py <<'PY'
line1
line2
line3
line4
line5
PY
printf '%s\n' 'untouched' > other.py

git add core.py other.py
git commit -q -m "base"
BASE="$(git rev-parse HEAD)"

export PYTHONPATH="$REPO_ROOT${PYTHONPATH:+:$PYTHONPATH}"

python3 - "$TARGET/core.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
lines[2] = "CHANGED3"
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
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
import json
import os
import subprocess
from pathlib import Path

from sail import convergence as conv
from sail import review as review_mod
from sail.decisionlog import DecisionLog

repo_root = Path(os.environ["REPO_ROOT"])
target = os.environ["TARGET"]
base = os.environ["BASE"]
dh = os.environ["DH"]
work = Path(os.environ["WORK"])


def seed(run_dir, review, run_state=None, plan_criteria=None):
    run_dir = Path(run_dir)
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "decision-log.md").write_text("# /sail decision log\n", encoding="utf-8")
    if plan_criteria is not None:
        (run_dir / "plan.json").write_text(
            json.dumps({"status": "completed", "acceptance_criteria": plan_criteria}),
            encoding="utf-8",
        )
    review_payload = dict(review)
    if plan_criteria is not None:
        review_payload["plan_hash"] = review_mod.plan_fingerprint(str(run_dir))
    (run_dir / "review.json").write_text(json.dumps(review_payload), encoding="utf-8")
    if run_state is None:
        run_state = {"gates": [{"name": "ruff", "status": "passed"}]}
    (run_dir / "run-state.json").write_text(json.dumps(run_state), encoding="utf-8")


def converge(*args):
    return subprocess.run(
        ["python3", "-m", "sail", "converge", *args],
        cwd=repo_root,
        capture_output=True,
        text=True,
    )


def base_review(finding_id="RT-1", file="core.py", line=3, severity="HIGH", round_num=2):
    return {
        "status": "completed",
        "target": target,
        "diff_ref": base,
        "diff_hash": dh,
        "round": round_num,
        "findings": [
            {
                "id": finding_id,
                "severity": severity,
                "file": file,
                "line": line,
            }
        ],
        "plan_verification": {
            "acceptance_criteria": [
                {"criterion": "one", "status": "met", "evidence": "ok"},
            ]
        },
        "tidiness": {"blocking": []},
    }


def clean_review():
    review = base_review()
    review["findings"] = []
    return review


def set_backend(cmd):
    if cmd is None:
        os.environ.pop("SAIL_MATERIALITY_CMD", None)
    else:
        os.environ["SAIL_MATERIALITY_CMD"] = cmd


def write_stub(path):
    path.write_text(
        """#!/usr/bin/env python3
import json
import sys

mode = sys.argv[1]
payload = json.load(sys.stdin)
required = {"instruction", "finding", "diff"}
missing = sorted(required - set(payload))
if missing:
    raise SystemExit(2)
if "INDEPENDENT reviewer" not in payload["instruction"]:
    raise SystemExit(3)
if not payload["diff"].strip():
    raise SystemExit(4)
if mode == "immaterial":
    print(json.dumps({"material": False}))
elif mode == "material":
    print(json.dumps({"material": True}))
else:
    raise SystemExit(5)
""",
        encoding="utf-8",
    )
    path.chmod(0o755)


def write_plan(run_dir, acceptance_criteria):
    run_dir = Path(run_dir)
    (run_dir / "plan.json").write_text(
        json.dumps({"status": "completed", "acceptance_criteria": acceptance_criteria}),
        encoding="utf-8",
    )


# A1: audit checks remain conservative and plan hashes stay fresh.
clean = work / "clean"
seed(clean, clean_review(), plan_criteria=["one"])
assert conv.review_current_and_clean(str(clean), target, 2) is True
assert conv.acs_all_met(str(clean)) is True
assert conv.tidiness_clear(str(clean)) is True
assert conv.gates_all_green(str(clean)) is True

unmet = work / "unmet"
unmet_review = clean_review()
unmet_review["plan_verification"] = {
    "acceptance_criteria": [{"criterion": "one", "status": "unmet", "evidence": "no"}],
}
seed(unmet, unmet_review)
assert conv.acs_all_met(str(unmet)) is False

unknown = work / "unknown"
unknown_review = clean_review()
unknown_review["plan_verification"] = {
    "acceptance_criteria": [{"criterion": "one", "status": "unknown", "evidence": "?"}],
}
seed(unknown, unknown_review)
assert conv.acs_all_met(str(unknown)) is False

absent = work / "absent"
seed(absent, {k: v for k, v in clean_review().items() if k != "plan_verification"})
assert conv.acs_all_met(str(absent)) is False

tidy_blocked = work / "tidy-blocked"
tidy_review = clean_review()
tidy_review["tidiness"] = {"blocking": [{"id": "x"}]}
seed(tidy_blocked, tidy_review)
assert conv.tidiness_clear(str(tidy_blocked)) is False

backend_error = work / "backend-error"
backend_error_review = clean_review()
backend_error_review["backend_error"] = "boom"
seed(backend_error, backend_error_review)
assert conv.review_current_and_clean(str(backend_error), target, 2) is False
assert conv.review_current_and_clean(str(clean), target, 3) is False

hash_mismatch = work / "hash-mismatch"
hash_mismatch_review = clean_review()
hash_mismatch_review["diff_hash"] = "not-the-real-hash"
seed(hash_mismatch, hash_mismatch_review)
assert conv.review_current_and_clean(str(hash_mismatch), target, 2) is False

plan_stale = work / "plan-stale"
seed(plan_stale, clean_review(), plan_criteria=["one"])
stale_review = clean_review()
stale_review["plan_hash"] = "stale"
(plan_stale / "review.json").write_text(json.dumps(stale_review), encoding="utf-8")
assert conv.review_current_and_clean(str(plan_stale), target, 2) is False

plan_match = work / "plan-match"
seed(plan_match, clean_review(), plan_criteria=["one"])
matching_review = clean_review()
matching_review["plan_hash"] = review_mod.plan_fingerprint(str(plan_match))
(plan_match / "review.json").write_text(json.dumps(matching_review), encoding="utf-8")
assert conv.review_current_and_clean(str(plan_match), target, 2) is True

run_state_dirty = work / "run-state-dirty"
seed(run_state_dirty, clean_review(), {"gates": [{"name": "ruff", "status": "passed", "new_failures": 2}]})
assert conv.gates_all_green(str(run_state_dirty)) is False

run_state_missing = work / "run-state-missing"
seed(run_state_missing, clean_review())
(run_state_missing / "run-state.json").unlink()
assert conv.gates_all_green(str(run_state_missing)) is False
assert conv.materiality_floor(1, str(run_state_missing), target, 2) == (False, [])

run_state_skipped = work / "run-state-skipped"
seed(run_state_skipped, clean_review(), {"checkers": [{"name": "ruff", "status": "skipped"}, {"name": "mypy", "status": "skipped"}]})
assert conv.gates_all_green(str(run_state_skipped)) is True

run_state_failed = work / "run-state-failed"
seed(run_state_failed, clean_review(), {"checkers": [{"name": "ruff", "status": "failed"}]})
assert conv.gates_all_green(str(run_state_failed)) is False

# A2: Lens B backend contract.
stub = work / "materiality-stub.py"
write_stub(stub)

materiality_target = work / "lens-b"
seed(materiality_target, base_review("RT-8", "core.py", 3), plan_criteria=["one"])
DecisionLog(str(materiality_target)).finding_resolution("RT-8", "deferred", "x", round=2)

set_backend(f"python3 {stub} immaterial")
assert conv.finding_is_immaterial({"id": "RT-8", "file": "core.py", "line": 3}, str(materiality_target), target) is True

set_backend(f"python3 {stub} material")
assert conv.finding_is_immaterial({"id": "RT-8", "file": "core.py", "line": 3}, str(materiality_target), target) is False

set_backend(None)
assert conv.finding_is_immaterial({"id": "RT-8", "file": "core.py", "line": 3}, str(materiality_target), target) is False


def floor_case(run_dir, finding_id, disposition=None, round_num=2, file="core.py", severity="HIGH", run_state=None, plan_criteria=("one",)):
    review = base_review(finding_id, file, 3, severity, round_num)
    seed(run_dir, review, run_state=run_state, plan_criteria=list(plan_criteria))
    if disposition is not None:
        DecisionLog(str(run_dir)).finding_resolution(finding_id, disposition, "x", round=round_num)
    return review


# A3-A9: materiality floor end-to-end.
floor_ok = work / "floor-ok"
floor_case(floor_ok, "RT-9", "deferred")
set_backend(f"python3 {stub} immaterial")
assert conv.materiality_floor(1, str(floor_ok), target, 2) == (True, ["RT-9"])

set_backend(f"python3 {stub} material")
assert conv.materiality_floor(1, str(floor_ok), target, 2) == (False, [])

set_backend(None)
assert conv.materiality_floor(1, str(floor_ok), target, 2) == (False, [])

floor_rejected = work / "floor-rejected"
floor_case(floor_rejected, "RT-10", "rejected")
set_backend(f"python3 {stub} immaterial")
assert conv.materiality_floor(1, str(floor_rejected), target, 2) == (False, [])

floor_addressed = work / "floor-addressed"
floor_case(floor_addressed, "RT-11", "addressed")
set_backend(f"python3 {stub} immaterial")
assert conv.materiality_floor(1, str(floor_addressed), target, 2) == (False, [])

floor_open = work / "floor-open"
floor_case(floor_open, "RT-12", None)
set_backend(f"python3 {stub} immaterial")
assert conv.materiality_floor(1, str(floor_open), target, 2) == (False, [])

floor_dirty = work / "floor-dirty"
floor_dirty_review = base_review("RT-13", "core.py", 3)
floor_dirty_review["plan_verification"] = {
    "acceptance_criteria": [{"criterion": "one", "status": "unmet", "evidence": "no"}],
}
seed(floor_dirty, floor_dirty_review, plan_criteria=["one"])
DecisionLog(str(floor_dirty)).finding_resolution("RT-13", "deferred", "x", round=2)
set_backend(f"python3 {stub} immaterial")
assert conv.materiality_floor(1, str(floor_dirty), target, 2) == (False, [])

floor_stale = work / "floor-stale"
floor_case(floor_stale, "RT-14", "deferred")
(floor_stale / "review.json").write_text(
    json.dumps({**base_review("RT-14", "core.py", 3), "plan_hash": "stale"}),
    encoding="utf-8",
)
set_backend(f"python3 {stub} immaterial")
assert conv.materiality_floor(1, str(floor_stale), target, 2) == (False, [])

# B1: floor-eligible converge -> proceed-hardening.
set_backend(f"python3 {stub} immaterial")
proc = converge("--rc", "1", "--round", "2", "--run-dir", str(floor_ok), "--target", target)
assert proc.returncode == 0, proc
assert proc.stdout.strip() == "proceed-hardening", proc.stdout
assert "materiality-floor" in proc.stderr, proc.stderr
assert "RT-9" in proc.stderr, proc.stderr

# B2: prior-round disposition wins oscillation -> park.
floor_osc = work / "floor-osc"
floor_osc_review = base_review("RT-15", "core.py", 3, round_num=2)
seed(floor_osc, floor_osc_review, plan_criteria=["one"])
DecisionLog(str(floor_osc)).finding_resolution("RT-15", "deferred", "x", round=1)
set_backend(f"python3 {stub} immaterial")
proc = converge("--rc", "1", "--round", "2", "--run-dir", str(floor_osc), "--target", target)
assert proc.returncode == 0, proc
assert proc.stdout.strip() == "park", proc.stdout
assert "non-convergence" in proc.stderr, proc.stderr

# B3: dirty audit keeps the oracle on the normal revise path.
set_backend(f"python3 {stub} immaterial")
proc = converge("--rc", "1", "--round", "2", "--run-dir", str(floor_dirty), "--target", target)
assert proc.returncode == 0, proc
assert proc.stdout.strip() == "revise", proc.stdout

# B4: regression for the legacy oracle outputs.
proc = converge("--rc", "0", "--round", "1")
assert proc.stdout.strip() == "proceed", proc.stdout
proc = converge("--rc", "1", "--round", "1")
assert proc.stdout.strip() == "revise", proc.stdout
proc = converge("--rc", "1", "--round", "3")
assert proc.stdout.strip() == "park", proc.stdout

print("PASS: Python contract checks for issue #103")
PY

grep -qF 'proceed-hardening' "$REPO_ROOT/commands/sail.md" \
  || fail "commands/sail.md missing proceed-hardening"
grep -qF 'never-dry-hardening' "$REPO_ROOT/commands/sail.md" \
  || fail "commands/sail.md missing never-dry-hardening"
grep -qF 'converged-green' "$REPO_ROOT/commands/sail.md" \
  || fail "commands/sail.md missing converged-green"
grep -qF 'genuine-oscillation' "$REPO_ROOT/commands/sail.md" \
  || fail "commands/sail.md missing genuine-oscillation"
grep -qiE 'real defect to FIX.*never defer|never defer.*real defect to FIX' "$REPO_ROOT/commands/sail.md" \
  || fail "commands/sail.md missing caller-break fix/never-defer guidance"
grep -qiE 'SAIL_MATERIALITY_CMD.*different model family|different model family.*SAIL_MATERIALITY_CMD' "$REPO_ROOT/commands/sail.md" \
  || fail "commands/sail.md missing cross-family independence guidance for SAIL_MATERIALITY_CMD"
grep -qF 'proceed-hardening' "$REPO_ROOT/commands/surf.md" \
  || fail "commands/surf.md missing proceed-hardening"

echo "PASS: test_sail_103_materiality_floor.sh"
