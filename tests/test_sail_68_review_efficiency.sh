#!/usr/bin/env bash
# test_sail_68_review_efficiency.sh — issue #68: review-efficiency helpers (red test).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# --- T1: DecisionLog.read_resolutions() on a fresh run-dir returns {} and never raises. ---
RUN1="$WORK/read-empty"
mkdir -p "$RUN1"
if RUN_DIR="$RUN1" python3 -c '
import os
from sail.decisionlog import DecisionLog

run_dir = os.environ["RUN_DIR"]
log = DecisionLog(run_dir)
assert log.read_resolutions() == {}, log.read_resolutions()
'; then
  echo "PASS T1: empty run-dir → read_resolutions() == {}"
else
  fail "T1: DecisionLog.read_resolutions() is missing or does not return {} for a fresh run-dir"
fi

# --- T2: DecisionLog.read_resolutions() round-trips multiple findings + skips garbage lines. ---
RUN2="$WORK/read-roundtrip"
mkdir -p "$RUN2"
if RUN_DIR="$RUN2" python3 -c '
import os
from sail.decisionlog import DecisionLog

run_dir = os.environ["RUN_DIR"]
log = DecisionLog(run_dir)
log.finding_resolution("f1", "addressed", "fixed it")
log.finding_resolution("f2", "deferred", "tracked #99")

with open(log.path, "a", encoding="utf-8") as fh:
    fh.write("noise line that should be ignored\n")
    fh.write("- resolution: [garbled] addressed -- wrong separator\n")
    fh.write("- resolution: garbled addressed — missing brackets\n")

assert log.read_resolutions() == {
    "f1": {"disposition": "addressed", "rationale": "fixed it"},
    "f2": {"disposition": "deferred", "rationale": "tracked #99"},
}, log.read_resolutions()
'; then
  echo "PASS T2: round-trip multiple findings and skip non-markers"
else
  fail "T2: DecisionLog.read_resolutions() did not round-trip markers or skipped garbage incorrectly"
fi

# --- T3: DecisionLog.read_resolutions() is last-wins for duplicate finding ids. ---
RUN3="$WORK/read-lastwins"
mkdir -p "$RUN3"
if RUN_DIR="$RUN3" python3 -c '
import os
from sail.decisionlog import DecisionLog

run_dir = os.environ["RUN_DIR"]
log = DecisionLog(run_dir)
log.finding_resolution("f1", "addressed", "first")
log.finding_resolution("f1", "rejected", "second")
resolved = log.read_resolutions()
assert resolved["f1"]["disposition"] == "rejected", resolved
assert resolved["f1"]["rationale"] == "second", resolved
'; then
  echo "PASS T3: duplicate ids resolve with last-wins"
else
  fail "T3: DecisionLog.read_resolutions() is not last-wins for duplicate finding ids"
fi

# --- T4: load_prior_findings() returns findings only when target and diff_ref match. ---
RUN4="$WORK/load-prior-match"
mkdir -p "$RUN4"
if RUN_DIR="$RUN4" python3 -c '
import json
import os
from pathlib import Path

from sail.review import load_prior_findings

run_dir = os.environ["RUN_DIR"]
review_path = Path(run_dir) / "review.json"
review_path.write_text(
    json.dumps(
        {
            "status": "completed",
            "target": "/abs/x",
            "diff_ref": "HEAD",
            "findings": [
                {
                    "id": "lens1-aaa",
                    "severity": "HIGH",
                    "issue": "i",
                    "file": "f.py",
                    "line": 1,
                }
            ],
        },
        indent=2,
    ),
    encoding="utf-8",
)

findings = load_prior_findings(run_dir, "/abs/x", "HEAD")
assert findings == [
    {
        "id": "lens1-aaa",
        "severity": "HIGH",
        "issue": "i",
        "file": "f.py",
        "line": 1,
    }
], findings

assert load_prior_findings(run_dir, "/abs/OTHER", "HEAD") == [], "target mismatch must return []"
assert load_prior_findings(run_dir, "/abs/x", "HEAD~1") == [], "diff_ref mismatch must return []"
'; then
  echo "PASS T4: matching review.json scope returns stored findings, mismatches return []"
else
  fail "T4: load_prior_findings() did not return the stored findings for a matching target/diff_ref"
fi

# --- T5: load_prior_findings() is pure and fail-closed on absent, malformed, and incomplete review.json. ---
RUN5="$WORK/load-prior-safety"
mkdir -p "$RUN5"
if RUN_DIR="$RUN5" python3 -c '
import json
import os
from pathlib import Path

from sail.review import load_prior_findings

run_dir = os.environ["RUN_DIR"]

absent_dir = Path(run_dir) / "absent"
absent_dir.mkdir()
assert load_prior_findings(str(absent_dir), "/abs/x", "HEAD") == [], "absent review.json must return []"

malformed_dir = Path(run_dir) / "malformed"
malformed_dir.mkdir()
(malformed_dir / "review.json").write_text("{not json", encoding="utf-8")
assert load_prior_findings(str(malformed_dir), "/abs/x", "HEAD") == [], "malformed review.json must return []"

nofindings_dir = Path(run_dir) / "nofindings"
nofindings_dir.mkdir()
(nofindings_dir / "review.json").write_text(
    json.dumps({"target": "/abs/x", "diff_ref": "HEAD"}),
    encoding="utf-8",
)
assert load_prior_findings(str(nofindings_dir), "/abs/x", "HEAD") == [], "missing findings key must return []"
'; then
  echo "PASS T5: absent/malformed/incomplete review.json all return []"
else
  fail "T5: load_prior_findings() must be pure, fail-closed, and never raise on bad review.json input"
fi

# ===== STEP 2 =====

MOCK_CAPTURE="$WORK/mock-capture.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'cat > "${CAPTURE:?}"' \
  'printf "%s" "${MOCK_OUT:-}"' \
  'exit ${MOCK_RC:-0}' > "$MOCK_CAPTURE"
chmod +x "$MOCK_CAPTURE"

MOCK_SENTINEL="$WORK/mock-sentinel.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[ -n "${CALLED:-}" ] && touch "$CALLED"' \
  'printf "%s" "${MOCK_OUT:-}"' \
  'exit ${MOCK_RC:-0}' > "$MOCK_SENTINEL"
chmod +x "$MOCK_SENTINEL"

make_throwaway_target() {
  local target_dir="$1"

  mkdir -p "$target_dir"
  printf 'def f():\n    return 1\n' > "$target_dir/mod.py"
  git -C "$target_dir" init -q
  git -C "$target_dir" add -A
  git -C "$target_dir" -c user.email=t@t -c user.name=t commit -qm base
  printf 'def f():\n    return 2  # edit\n' > "$target_dir/mod.py"
}

# --- T6: build_prompt(prior=...) adds a prior-round section; omitted prior stays byte-identical. ---
if python3 -c '
import sail.review as r

diff_text = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n"
prior = [{
    "id": "lens1-aaa",
    "severity": "HIGH",
    "issue": "prior issue",
    "file": "f.py",
    "line": 1,
    "disposition": "addressed",
    "rationale": "fixed",
}]

base = r.build_prompt(diff_text)
with_prior = r.build_prompt(diff_text, prior=prior)
base_prefix = base.split("=== DIFF ===", 1)[0]
prior_prefix = with_prior.split("=== DIFF ===", 1)[0]

assert "lens1-aaa" in prior_prefix, prior_prefix
assert any(k in prior_prefix.lower() for k in ("prior-round", "inter-round", "multi-round")), prior_prefix
assert "addressed" in prior_prefix.lower(), prior_prefix
assert prior_prefix.count("HIGH") > base_prefix.count("HIGH"), prior_prefix
assert "lens1-aaa" not in base_prefix, base_prefix
assert not any(k in base_prefix.lower() for k in ("prior-round", "inter-round", "multi-round")), base_prefix
assert r.build_prompt(diff_text, prior=None) == base, "prior=None must be byte-identical to today"
assert r.build_prompt(diff_text, prior=[]) == base, "prior=[] must be byte-identical to today"
'; then
  echo "PASS T6: build_prompt prior=... adds prior-round guidance and omitting prior is byte-identical"
else
  fail "T6: build_prompt(prior=...) is missing or does not preserve the no-prior prompt"
fi

# --- T7: python3 -m sail run --round 2 must parse and invoke the backend. ---
TGT7="$WORK/round2-run-target"
make_throwaway_target "$TGT7"
RUN7="$WORK/round2-run"
mkdir -p "$RUN7"
CAPTURE7="$WORK/round2-run.prompt"
set +e
SAIL_CHECKERS="ruff,pytest" SAIL_REVIEW_CMD="bash $MOCK_CAPTURE" CAPTURE="$CAPTURE7" MOCK_OUT='{"findings":[],"summary":"ok"}' \
  python3 -m sail run --target "$TGT7" --diff HEAD --run-dir "$RUN7" --round 2 \
  >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] || fail "T7: --round 2 on sail run must parse and invoke the backend, got rc=$rc"
[ -f "$CAPTURE7" ] || fail "T7: backend was not invoked for sail run --round 2"

# --- T8: python3 -m sail review --round 2 must parse and invoke the backend. ---
TGT8="$WORK/round2-review-target"
make_throwaway_target "$TGT8"
RUN8="$WORK/round2-review"
mkdir -p "$RUN8"
CAPTURE8="$WORK/round2-review.prompt"
set +e
SAIL_REVIEW_CMD="bash $MOCK_CAPTURE" CAPTURE="$CAPTURE8" MOCK_OUT='{"findings":[],"summary":"ok"}' \
  python3 -m sail review --target "$TGT8" --diff HEAD --run-dir "$RUN8" --round 2 \
  >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] || fail "T8: --round 2 on sail review must parse and invoke the backend, got rc=$rc"
[ -f "$CAPTURE8" ] || fail "T8: backend was not invoked for sail review --round 2"

# --- T9: run_review persists target and diff_ref into review.json after a clean run. ---
TGT9="$WORK/scope-persistence-target"
make_throwaway_target "$TGT9"
RUN9="$WORK/scope-persistence"
mkdir -p "$RUN9"
set +e
SAIL_CHECKERS="ruff,pytest" SAIL_REVIEW_CMD="bash $MOCK_CAPTURE" CAPTURE="$WORK/scope-persistence.prompt" MOCK_OUT='{"findings":[],"summary":"ok"}' \
  python3 -m sail run --target "$TGT9" --diff HEAD --run-dir "$RUN9" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] || fail "T9: clean sail run --diff must succeed before checking review.json scope keys"
python3 -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
assert "target" in data and "diff_ref" in data, data
' "$RUN9/review.json" || fail "T9: review.json must persist target and diff_ref for reuse matching"

# --- T10: round-1 prompt capture must not contain a prior-round section. ---
TGT10="$WORK/round1-no-prior-target"
make_throwaway_target "$TGT10"
RUN10="$WORK/round1-no-prior"
mkdir -p "$RUN10"
CAPTURE10="$WORK/round1-no-prior.prompt"
set +e
SAIL_REVIEW_CMD="bash $MOCK_CAPTURE" CAPTURE="$CAPTURE10" MOCK_OUT='{"findings":[],"summary":"ok"}' \
  python3 -m sail review --target "$TGT10" --diff HEAD --run-dir "$RUN10" \
  >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] || fail "T10: round-1 review must still run cleanly, got rc=$rc"
[ -f "$CAPTURE10" ] || fail "T10: round-1 backend prompt was not captured"
if python3 -c '
import sys
from pathlib import Path

prefix = Path(sys.argv[1]).read_text(encoding="utf-8").split("=== DIFF ===", 1)[0]
raise SystemExit(0 if not any(k in prefix.lower() for k in ("lens1-aaa", "prior-round", "inter-round", "multi-round")) else 1)
' "$CAPTURE10"; then
  : 
else
  fail "T10: round-1 prompt must not contain a prior-round section"
fi

# --- T11: round-2 prompt capture must include prior finding context and discipline text. ---
TGT11="$WORK/round2-prior-context-target"
make_throwaway_target "$TGT11"
RUN11="$WORK/round2-prior-context"
mkdir -p "$RUN11"
python3 -c '
import json
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])
target = sys.argv[2]
review = {
    "status": "completed",
    "target": target,
    "diff_ref": "HEAD",
    "findings": [
        {
            "id": "lens1-aaa",
            "severity": "HIGH",
            "issue": "prior issue",
            "file": "f.py",
            "line": 1,
        }
    ],
}
run_dir.joinpath("review.json").write_text(json.dumps(review, indent=2), encoding="utf-8")
run_dir.joinpath("decision-log.md").write_text(
    "\n".join(
        [
            "# /sail decision log",
            "- resolution: [lens1-aaa] addressed — fixed the bug",
        ]
    )
    + "\n",
    encoding="utf-8",
)
' "$RUN11" "$TGT11"
CAPTURE11="$WORK/round2-prior-context.prompt"
set +e
SAIL_REVIEW_CMD="bash $MOCK_CAPTURE" CAPTURE="$CAPTURE11" MOCK_OUT='{"findings":[],"summary":"ok"}' \
  python3 -m sail review --target "$TGT11" --diff HEAD --run-dir "$RUN11" --round 2 \
  >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] || fail "T11: round-2 review must parse, reuse scope, and invoke the backend, got rc=$rc"
[ -f "$CAPTURE11" ] || fail "T11: round-2 prompt was not captured"
python3 -c '
import sys
from pathlib import Path

base = Path(sys.argv[1]).read_text(encoding="utf-8").split("=== DIFF ===", 1)[0]
prior = Path(sys.argv[2]).read_text(encoding="utf-8").split("=== DIFF ===", 1)[0]

assert "lens1-aaa" in prior, prior
assert "addressed" in prior.lower(), prior
assert any(k in prior.lower() for k in ("prior-round", "inter-round", "multi-round")), prior
assert prior.count("HIGH") > base.count("HIGH"), prior
' "$CAPTURE10" "$CAPTURE11" || fail "T11: round-2 prompt must include the prior finding id, severity, disposition, and discipline text"

# --- T12: round>1 must bypass reuse and re-invoke the backend for a completed same-scope review. ---
TGT12="$WORK/round2-bypass-target"
make_throwaway_target "$TGT12"
RUN12="$WORK/round2-bypass-reuse"
mkdir -p "$RUN12"
python3 -c '
import json
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])
target = sys.argv[2]
review = {
    "status": "completed",
    "target": target,
    "diff_ref": "HEAD",
    "findings": [],
}
run_dir.joinpath("review.json").write_text(json.dumps(review, indent=2), encoding="utf-8")
' "$RUN12" "$TGT12"
CALLED12="$WORK/round2-bypass.called"
set +e
SAIL_CHECKERS="ruff,pytest" SAIL_REVIEW_CMD="bash $MOCK_SENTINEL" CALLED="$CALLED12" MOCK_OUT='{"findings":[],"summary":"ok"}' \
  python3 -m sail run --target "$TGT12" --diff HEAD --run-dir "$RUN12" --round 2 \
  >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] || fail "T12: round-2 run must parse and re-invoke the backend, got rc=$rc"
[ -f "$CALLED12" ] || fail "T12: round-2 run reused the cached review instead of re-invoking the backend"

# --- T13: round-1 resume reuse behavior must remain unchanged. ---
TGT13="$WORK/target13"
mkdir -p "$TGT13"
printf 'def f():\n    return 1\n' > "$TGT13/mod.py"
printf 'def test_smoke():\n    assert True\n' > "$TGT13/test_smoke.py"
git -C "$TGT13" init -q
git -C "$TGT13" add -A
git -C "$TGT13" -c user.email=t@t -c user.name=t commit -qm base
printf 'def f():\n    return 2  # edit\n' > "$TGT13/mod.py"
RUN13="$WORK/round1-reuse"
MOCK="$WORK/mock_llm_t13.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'cat >/dev/null' \
  'printf "%s" "${MOCK_OUT:-}"' \
  'exit ${MOCK_RC:-0}' > "$MOCK"
chmod +x "$MOCK"
set +e
SAIL_CHECKERS="ruff,pytest" SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT='{"findings":[],"summary":"ok"}' \
  python3 -m sail run --target "$TGT13" --diff HEAD --run-dir "$RUN13" \
  >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] || fail "T13 setup: run1 clean review should exit 0, got $rc"
python3 -c "import json,sys;d=json.load(open('$RUN13/review.json'));sys.exit(0 if d.get('status')=='completed' else 1)" || fail "T13 setup: run1 review.json not completed"
[ -f "$RUN13/run-state.json" ] || fail "T13 setup: run1 must create run-state.json for genuine resume"
CALLED13="$WORK/round1-reuse.called"
set +e
SAIL_CHECKERS="ruff,pytest" SAIL_REVIEW_CMD="bash $MOCK_SENTINEL" CALLED="$CALLED13" MOCK_OUT='{"findings":[],"summary":"ok"}' \
  python3 -m sail run --target "$TGT13" --diff HEAD --run-dir "$RUN13" \
  >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] || fail "T13: round-1 resume should still be able to reuse the cached review, got rc=$rc"
[ ! -e "$CALLED13" ] || fail "T13: round-1 same-scope same-diff resume must keep reusing the cached review"

# ===== STEP 3 =====

MOCK_DEFAULT_REVIEW="$WORK/mock-default-review.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[ -n "${CALLED_DEFAULT:-}" ] && touch "$CALLED_DEFAULT"' \
  'printf "%s" "${MOCK_OUT:-}"' \
  'exit ${MOCK_RC:-0}' > "$MOCK_DEFAULT_REVIEW"
chmod +x "$MOCK_DEFAULT_REVIEW"

MOCK_ESCALATED_REVIEW="$WORK/mock-escalated-review.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[ -n "${CALLED_ESC:-}" ] && touch "$CALLED_ESC"' \
  'printf "%s" "${MOCK_OUT:-}"' \
  'exit ${MOCK_RC:-0}' > "$MOCK_ESCALATED_REVIEW"
chmod +x "$MOCK_ESCALATED_REVIEW"

# --- T14: escalate_round() defaults to 3, honors the env override, and fail-safes on bad input. ---
if python3 -c '
import os
import sail.review as r

os.environ.pop("SAIL_REVIEW_ESCALATE_ROUND", None)
assert r.escalate_round() == 3, r.escalate_round()
os.environ["SAIL_REVIEW_ESCALATE_ROUND"] = "2"
assert r.escalate_round() == 2, r.escalate_round()
os.environ["SAIL_REVIEW_ESCALATE_ROUND"] = "abc"
assert r.escalate_round() == 3, r.escalate_round()
'; then
  echo "PASS T14: escalate_round() defaults to 3, honors overrides, and fail-safes on invalid env"
else
  fail "T14: escalate_round() must default to 3, honor SAIL_REVIEW_ESCALATE_ROUND, and fall back to 3 on bad input"
fi

# --- T15: escalated_available() is false when unset, true for a runnable mock, and false for a missing path. ---
if MOCK_ESCALATED="$MOCK_SENTINEL" python3 -c '
import os
import sail.review as r

os.environ.pop("SAIL_REVIEW_CMD_ESCALATED", None)
assert r.escalated_available() is False, r.escalated_available()
os.environ["SAIL_REVIEW_CMD_ESCALATED"] = os.environ["MOCK_ESCALATED"]
assert r.escalated_available() is True, r.escalated_available()
os.environ["SAIL_REVIEW_CMD_ESCALATED"] = "/nonexistent/x"
assert r.escalated_available() is False, r.escalated_available()
'; then
  echo "PASS T15: escalated_available() tracks unset/runnable/missing backend states"
else
  fail "T15: escalated_available() must detect a runnable SAIL_REVIEW_CMD_ESCALATED and fail closed otherwise"
fi

# --- T16: select_review_argv(round) chooses default vs escalated argv by threshold and availability. ---
if MOCK_DEFAULT="$MOCK_DEFAULT_REVIEW" MOCK_ESCALATED="$MOCK_ESCALATED_REVIEW" python3 -c '
import os
import shlex

import sail.review as r

os.environ["SAIL_REVIEW_CMD"] = os.environ["MOCK_DEFAULT"]
os.environ["SAIL_REVIEW_CMD_ESCALATED"] = os.environ["MOCK_ESCALATED"]
os.environ["SAIL_REVIEW_ESCALATE_ROUND"] = "3"

default_argv = r._backend_argv()
escalated_argv = shlex.split(os.environ["SAIL_REVIEW_CMD_ESCALATED"])

assert r.select_review_argv(2) == default_argv, r.select_review_argv(2)
assert r.select_review_argv(3) == escalated_argv, r.select_review_argv(3)

os.environ["SAIL_REVIEW_CMD_ESCALATED"] = "/nonexistent/x"
assert r.select_review_argv(3) == default_argv, r.select_review_argv(3)
'; then
  echo "PASS T16: select_review_argv(round) falls back to default or escalates when available"
else
  fail "T16: select_review_argv(round) must choose the default argv below threshold and the escalated argv at/above the threshold when available"
fi

# --- T17: end-to-end review backend selection escalates only at round >= 3 and falls back at round 1. ---
TGT14="$WORK/round-select-target"
make_throwaway_target "$TGT14"
RUN14A="$WORK/round-select-r3"
RUN14B="$WORK/round-select-r1"
mkdir -p "$RUN14A" "$RUN14B"
CALLED_DEFAULT14="$WORK/round-select.default.called"
CALLED_ESC14="$WORK/round-select.escalated.called"
set +e
SAIL_REVIEW_ESCALATE_ROUND=3 \
SAIL_CHECKERS="ruff,pytest" \
SAIL_REVIEW_CMD="$MOCK_DEFAULT_REVIEW" \
SAIL_REVIEW_CMD_ESCALATED="$MOCK_ESCALATED_REVIEW" \
MOCK_OUT='{"findings":[],"summary":"ok"}' \
CALLED_DEFAULT="$CALLED_DEFAULT14" CALLED_ESC="$CALLED_ESC14" \
  python3 -m sail review --target "$TGT14" --diff HEAD --run-dir "$RUN14A" --round 3 \
  >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] || fail "T17: round 3 review must succeed and use the escalated backend, got rc=$rc"
[ -f "$CALLED_ESC14" ] || fail "T17: round 3 review did not run the escalated backend"
[ ! -e "$CALLED_DEFAULT14" ] || fail "T17: round 3 review should not run the default backend"

rm -f "$CALLED_DEFAULT14" "$CALLED_ESC14"
set +e
SAIL_REVIEW_ESCALATE_ROUND=3 \
SAIL_CHECKERS="ruff,pytest" \
SAIL_REVIEW_CMD="$MOCK_DEFAULT_REVIEW" \
SAIL_REVIEW_CMD_ESCALATED="$MOCK_ESCALATED_REVIEW" \
MOCK_OUT='{"findings":[],"summary":"ok"}' \
CALLED_DEFAULT="$CALLED_DEFAULT14" CALLED_ESC="$CALLED_ESC14" \
  python3 -m sail review --target "$TGT14" --diff HEAD --run-dir "$RUN14B" --round 1 \
  >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] || fail "T17: round 1 review must succeed and use the default backend, got rc=$rc"
[ -f "$CALLED_DEFAULT14" ] || fail "T17: round 1 review did not run the default backend"
[ ! -e "$CALLED_ESC14" ] || fail "T17: round 1 review should not run the escalated backend"

# --- T18: escalated-only later rounds must run, not fail closed, via both review and run preflight. ---
TGT18="$WORK/round3-escalated-only-target"
make_throwaway_target "$TGT18"
RUN18A="$WORK/round3-escalated-only-review"
RUN18B="$WORK/round3-escalated-only-run"
mkdir -p "$RUN18A" "$RUN18B"
CALLED_ESC18A="$WORK/round3-escalated-only.review.called"
CALLED_ESC18B="$WORK/round3-escalated-only.run.called"
set +e
SAIL_REVIEW_ESCALATE_ROUND=3 \
SAIL_REVIEW_CMD_ESCALATED="$MOCK_ESCALATED_REVIEW" \
MOCK_OUT='{"findings":[],"summary":"ok"}' \
CALLED_ESC="$CALLED_ESC18A" \
  python3 -m sail review --target "$TGT18" --diff HEAD --run-dir "$RUN18A" --round 3 \
  >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] || fail "T18: escalated-only round 3 review must exit 0 instead of failing closed, got rc=$rc"
[ -f "$CALLED_ESC18A" ] || fail "T18: escalated-only round 3 review did not run the escalated backend"
[ -f "$RUN18A/review.json" ] || fail "T18: round 3 review must write review.json when only the escalated backend is available"

set +e
SAIL_REVIEW_ESCALATE_ROUND=3 \
SAIL_CHECKERS="ruff,pytest" \
SAIL_REVIEW_CMD_ESCALATED="$MOCK_ESCALATED_REVIEW" \
MOCK_OUT='{"findings":[],"summary":"ok"}' \
CALLED_ESC="$CALLED_ESC18B" \
  python3 -m sail run --target "$TGT18" --diff HEAD --run-dir "$RUN18B" --round 3 \
  >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] || fail "T18: escalated-only round 3 run must exit 0 instead of failing closed, got rc=$rc"
[ -f "$CALLED_ESC18B" ] || fail "T18: escalated-only round 3 run did not run the escalated backend"
[ -f "$RUN18B/review.json" ] || fail "T18: round 3 run must write review.json when only the escalated backend is available"

# --- T19: commands/sail.md must document the new round flag and escalated review backend env. ---
grep -q -- '--round' commands/sail.md || fail "T19: commands/sail.md must mention --round for the stage 3 loop"
grep -q 'SAIL_REVIEW_CMD_ESCALATED' commands/sail.md || fail "T19: commands/sail.md must document SAIL_REVIEW_CMD_ESCALATED"

# --- T20: round-3 review falls back loudly when escalation is requested but missing. ---
TGT20="$WORK/round3-escalation-fallback-target"
make_throwaway_target "$TGT20"
RUN20="$WORK/round3-escalation-fallback"
mkdir -p "$RUN20"
CALLED_DEFAULT20="$WORK/round3-escalation-fallback.default.called"
set +e
SAIL_REVIEW_ESCALATE_ROUND=3 \
SAIL_REVIEW_CMD="$MOCK_DEFAULT_REVIEW" \
SAIL_REVIEW_CMD_ESCALATED="/nonexistent/esc" \
MOCK_OUT='{"findings":[],"summary":"ok"}' \
CALLED_DEFAULT="$CALLED_DEFAULT20" \
  python3 -m sail review --target "$TGT20" --diff HEAD --run-dir "$RUN20" --round 3 \
  >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = "0" ] || fail "T20: round-3 review must degrade to the default backend and exit 0 when the escalated backend is missing, got rc=$rc"
[ -f "$RUN20/review.json" ] || fail "T20: round-3 degraded review must still write review.json via the default backend"
[ -f "$CALLED_DEFAULT20" ] || fail "T20: round-3 degraded review did not invoke the default backend"
grep -q 'escalation requested' "$RUN20/decision-log.md" || fail "T20: round-3 degraded review must log the escalation-requested fallback marker"

# --- T21: load_prior_findings() must ignore errored review artifacts even when findings exist. ---
RUN21="$WORK/load-prior-status"
mkdir -p "$RUN21/error" "$RUN21/completed"
python3 -c '
import json
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])
target = "/abs/x"
diff_ref = "HEAD"
findings = [
    {
        "id": "lens1-aaa",
        "severity": "HIGH",
        "issue": "i",
        "file": "f.py",
        "line": 1,
    }
]
for status, name in (("error", "error"), ("completed", "completed")):
    review = {
        "status": status,
        "target": target,
        "diff_ref": diff_ref,
        "findings": findings,
    }
    (run_dir / name / "review.json").write_text(json.dumps(review, indent=2), encoding="utf-8")

from sail.review import load_prior_findings

assert load_prior_findings(str(run_dir / "error"), target, diff_ref) == [], "errored review.json must return []"
assert load_prior_findings(str(run_dir / "completed"), target, diff_ref) == findings, "completed review.json must return findings"
' "$RUN21" || fail "T21: load_prior_findings() must gate reuse on status == completed"

echo "PASS: sail review-efficiency step 1 + step 2 + step 3 coverage verified"
