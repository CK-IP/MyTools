#!/usr/bin/env bash
# test_sail_148_review_depth.sh — issue #148: risk-scaled review depth. On a high-stakes diff the
# review widens to a SECOND, differently-focused perspective with NO flag required — WITHOUT adding
# codex consumption by default (the 2026-06-27 codex-conservation policy). The second perspective is
# either the already-auto repo-exploring red-team (where it fires) OR, when red-team is NOT the
# second perspective, a SAME-FAMILY (reuse the primary review backend) diff-only pass with a DISTINCT
# security/spec-compliance FOCUS prompt, tagged lens="focus" in review.json. Low-stakes diffs are
# unchanged and pay nothing. Degrades cleanly (focus shares the primary review backend).
#
# Coverage:
#   Part A (pure)        — review_perspectives depth selector (low-stakes / high-stakes+focus /
#                          high-stakes+redteam / advisory / empty); build_focus_prompt craft
#                          (distinct security+spec-compliance focus, diff-only, NOT a correctness copy).
#   Part B (integration) — full `sail run --diff`: non-spine high-stakes auto-fires focus (no flag),
#                          focus HIGH blocks and is tagged lens=focus; low-stakes no-fires; red-team
#                          active => no redundant focused third pass; NO codex/lens2 backend invoked
#                          by default; focus backend-error fails closed; primary-backend-absent skips
#                          cleanly; resume-freshness (a high-stakes cache lacking focus is re-reviewed).
# Hermetic per #64: mocks the review backend (SAIL_REVIEW_CMD, also the focus backend), the codex
# lens2 backend (SAIL_REVIEW_CMD2) and the red-team backend (SAIL_REDTEAM_CMD); throwaway git targets;
# never calls a real CLI; never asserts on live git.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
# A real shell exports SAIL_* codex knobs (settings.json); clear them so each subtest controls its
# own backend (subtests set theirs via command prefix).
unset "${!SAIL_@}"
export SAIL_CHECKERS=ruff   # one fast checker so the deterministic gates never mask the review arm
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"

fail() { echo "FAIL: $*"; exit 1; }

# ---------------------------------------------------------------------------
# Part A — pure unit checks (no LLM, no git): the depth selector + prompt craft.
# ---------------------------------------------------------------------------
python3 - <<'PY' || fail "Part A: pure depth-selector / focus-prompt craft checks failed"
import sail.review as r

def diff(files=1, body_lines=2, security=False):
    out = []
    for i in range(files):
        out += [f"diff --git a/f{i}.py b/f{i}.py", "index 000..111 100644",
                f"--- a/f{i}.py", f"+++ b/f{i}.py", "@@ -1 +1 @@"]
        for j in range(body_lines):
            line = "+    subprocess.run(['x'])" if (security and i == 0 and j == 0) else f"+    a{i}_{j} = {j}"
            out.append(line)
    return "\n".join(out) + "\n"

low = diff(files=1, body_lines=2)
hs_files = diff(files=5, body_lines=1)   # non-spine high-stakes (cross-cutting)
hs_lines = diff(files=1, body_lines=90)  # non-spine high-stakes (large)

# --- review_perspectives: the deterministic depth selector (AC#1) ---
# Low-stakes => single perspective (unchanged, pays nothing).
assert r.review_perspectives(low, redteam_running=False) == ["lens1"], "low-stakes must be single-lens"
# High-stakes + red-team NOT the second perspective => same-family focused fallback fires.
assert r.review_perspectives(hs_files, redteam_running=False) == ["lens1", "focus"], "non-spine high-stakes (files) => +focus"
assert r.review_perspectives(hs_lines, redteam_running=False) == ["lens1", "focus"], "non-spine high-stakes (lines) => +focus"
# High-stakes + red-team IS the second perspective => NO redundant focused third pass.
assert r.review_perspectives(hs_files, redteam_running=True) == ["lens1", "redteam"], "red-team active => no focus (no third pass)"
# Advisory / empty => single perspective (pays nothing).
assert r.review_perspectives(hs_files, redteam_running=False, advisory=True) == ["lens1"], "advisory => single-lens"
assert r.review_perspectives("", redteam_running=False) == ["lens1"], "empty diff => single-lens"
assert r.review_perspectives(None, redteam_running=False) == ["lens1"], "None diff => single-lens"

# --- build_focus_prompt craft: a DISTINCT security/spec-compliance focus, diff-only, NOT a copy ---
fp = r.build_focus_prompt("DIFFBODY")
fpl = fp.lower()
assert "DIFFBODY" in fp, "focus prompt must carry the diff body"
assert "spec-compliance" in fpl, "focus prompt must declare its spec-compliance focus (mock keys off this token)"
assert "security" in fpl, "focus prompt must declare its security focus"
assert ">80%" in fpl, "focus prompt must keep the confidence bar"
# It is a SECOND, differently-focused perspective — not a duplicate of the correctness lens...
assert fp != r.REVIEW_PROMPT.format(diff="DIFFBODY"), "focus prompt must differ from the correctness prompt"
# ...and it is DIFF-ONLY (not the repo-exploring red-team): it must not instruct beyond-diff exploration.
assert "beyond the diff" not in fpl, "focus is diff-only; must not instruct repo exploration (that is the red-team)"
# Same output schema so parse_findings works.
assert '"findings"' in fp and '"severity"' in fp, "focus prompt must request the findings JSON schema"

# --- lens2-aware depth (round-2 fix): an explicit --dual-lens second lens IS a second
# perspective — focus never runs redundantly alongside it (no triple-review of one diff).
assert r.review_perspectives(hs_files, redteam_running=False, lens2_running=True) == ["lens1", "lens2"], "lens2 active => no redundant focus"
assert r.review_perspectives(hs_files, redteam_running=True, lens2_running=True) == ["lens1", "lens2", "redteam"], "lens2 + redteam => both, never focus"
assert r.review_perspectives(low, redteam_running=False, lens2_running=True) == ["lens1", "lens2"], "lens2 tag recorded on low-stakes too"
assert r.review_perspectives(hs_files, redteam_running=False, lens2_running=True, advisory=True) == ["lens1"], "advisory stays single-lens regardless of lens2"

# --- focus prompt carries the plan ACs (round-2 fix): the spec-compliance axis judges the REAL
# acceptance criteria, never guessed-from-the-diff ones.
fpa = r.build_focus_prompt("DIFFBODY", acs=["AC-ALPHA-TOKEN", "AC-BETA-TOKEN"])
assert "AC-ALPHA-TOKEN" in fpa and "AC-BETA-TOKEN" in fpa, "focus prompt must embed the plan ACs"
assert "AC-ALPHA-TOKEN" not in r.build_focus_prompt("DIFFBODY"), "no ACs => no AC block"

# --- depth_reuse_ok: the depth-reuse decision is COMPUTED IN review.py (owner of depth
# semantics) and merely consulted by the runner — no duplicated recomputation at the call site.
import os as _os
_orig_git_diff = r._git_diff
try:
    r._git_diff = lambda target, ref: hs_files
    assert r.depth_reuse_ok({"lenses": ["lens1"]}, ".", "HEAD") is False, "high-stakes single-lens cache must NOT be reused"
    assert r.depth_reuse_ok({"lenses": ["lens1", "focus"]}, ".", "HEAD") is True, "focus-bearing cache reuses"
    _os.environ["SAIL_REVIEW_CMD2"] = "true"   # runnable => lens2 is the designated 2nd perspective
    assert r.depth_reuse_ok({"lenses": ["lens1", "lens2"]}, ".", "HEAD", dual_lens=True) is True, "dual-lens cache satisfies depth (lens2 is the 2nd perspective)"
    _os.environ.pop("SAIL_REVIEW_CMD2", None)
    r._git_diff = lambda target, ref: low
    assert r.depth_reuse_ok({"lenses": ["lens1"]}, ".", "HEAD") is True, "low-stakes single-lens cache reuses"
finally:
    r._git_diff = _orig_git_diff
    _os.environ.pop("SAIL_REVIEW_CMD2", None)

# --- metrics telemetry mirrors the focus depth signals (round-2 fix, #146 parity): a run whose
# review widened to the focus perspective is distinguishable in the persisted ledger.
import json as _json, tempfile as _tempfile
import sail.metrics as _metrics
_d = _tempfile.mkdtemp()
with open(_os.path.join(_d, "run-state.json"), "w") as fh:
    _json.dump({"run_id": "t-148", "started_at": "2026-01-01T00:00:00Z"}, fh)
with open(_os.path.join(_d, "review.json"), "w") as fh:
    _json.dump({"status": "completed", "findings": [], "round": 1,
                "focus_requested": True, "focus_ran": True}, fh)
_rec = _metrics.build_record(run_dir=_d, issue="148", terminus="parked+test")
assert _rec is not None, "metrics build_record must produce a record"
_flags = _rec["degraded_flags"] if isinstance(_rec, dict) else _rec.degraded_flags
assert _flags.get("focus_requested") is True and _flags.get("focus_ran") is True, \
    "metrics degraded_flags must mirror focus_requested/focus_ran"
print("Part A OK")
PY
echo "PASS A: depth selector (low/high-stakes/redteam/advisory/empty) + distinct diff-only focus prompt craft"

# ---------------------------------------------------------------------------
# Part B — integration via `sail run --diff` (mocked backends, throwaway targets).
# ---------------------------------------------------------------------------
# Review backend mock (serves BOTH lens1 and the focus pass — focus reuses the primary review
# backend). It captures each received prompt to a unique file in $REVIEW_CAPDIR and branches its
# output on the FOCUS marker: a focus-flavored prompt => $FOCUS_OUT, otherwise => $LENS1_OUT. This
# lets a subtest make lens1 CLEAN while focus emits a blocking finding, proving focus contributes
# independently. Exits 0 (or $REVIEW_RC when set, to exercise fail-closed).
REVIEW_MOCK="$WORK/review_mock.sh"
cat > "$REVIEW_MOCK" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
p="$(cat)"
if [ -n "${REVIEW_CAPDIR:-}" ]; then mkdir -p "$REVIEW_CAPDIR"; f="$(mktemp "$REVIEW_CAPDIR/p.XXXXXX")"; printf '%s' "$p" > "$f"; fi
if printf '%s' "$p" | grep -qi "spec-compliance"; then
  printf '%s' "${FOCUS_OUT:-${LENS1_OUT:-}}"; exit "${FOCUS_RC:-${REVIEW_RC:-0}}"
fi
printf '%s' "${LENS1_OUT:-}"; exit "${REVIEW_RC:-0}"
EOF
chmod +x "$REVIEW_MOCK"

# Codex lens2 backend mock: TOUCHES a sentinel so we can prove it is NEVER invoked without --dual-lens.
CODEX_MOCK="$WORK/codex_mock.sh"
cat > "$CODEX_MOCK" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
[ -n "${CODEX_SENTINEL:-}" ] && : > "$CODEX_SENTINEL"
printf '%s' '{"findings":[],"summary":"no issues"}'
EOF
chmod +x "$CODEX_MOCK"

# Red-team backend mock: TOUCHES a sentinel, emits $RT_OUT.
RT_MOCK="$WORK/rt_mock.sh"
cat > "$RT_MOCK" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
[ -n "${RT_SENTINEL:-}" ] && : > "$RT_SENTINEL"
printf '%s' "${RT_OUT:-{\"findings\":[],\"summary\":\"no issues\"}}"
EOF
chmod +x "$RT_MOCK"

CLEAN='{"findings":[],"summary":"no issues"}'
FOCUS_HIGH='{"findings":[{"severity":"HIGH","category":"security","file":"f0.py","line":1,"issue":"untrusted input flows into subprocess","recommendation":"validate/escape"}],"summary":"1 high"}'

# Throwaway git target. $1=dir, $2=kind (files|ordinary|big).
new_target() {
  local d="$1" kind="${2:-ordinary}"
  mkdir -p "$d"
  printf 'def helper(a):\n    return a\n' > "$d/mod.py"
  git -C "$d" init -q
  git -C "$d" add -A
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm base
  case "$kind" in
    files) for i in 0 1 2 3 4; do printf 'x%d = %d\n' "$i" "$i" > "$d/f$i.py"; done ;;   # 5 files => cross-cutting
    big)   { echo 'def helper(a):'; for i in $(seq 1 90); do echo "    v$i = $i"; done; echo '    return a'; } > "$d/mod.py" ;;
    *)     printf 'def helper(a):\n    return a + 1  # changed\n' > "$d/mod.py" ;;
  esac
}

run_sail() { # $1=target $2=run-dir ; extra args -> sail run ; sets RC_OUT
  set +e
  python3 -m sail run --target "$1" --diff HEAD --run-dir "$2" "${@:3}" >/dev/null 2>&1
  RC_OUT=$?
  set -e
}
py_review() { python3 - "$@"; }

# --- T1: a NON-SPINE high-stakes diff (5 files), NO red-team backend => focus AUTO-fires (no flag).
#         lens1 is CLEAN, focus emits a HIGH => the run blocks BECAUSE of focus; the finding is tagged
#         lens=focus; review.json records focus_ran=true, "focus" in lenses, "redteam" absent. ---
TGT="$WORK/t1"; new_target "$TGT" files; RD="$WORK/rd1"; CAPD="$WORK/cap1"
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_CAPDIR="$CAPD" LENS1_OUT="$CLEAN" FOCUS_OUT="$FOCUS_HIGH" \
  run_sail "$TGT" "$RD"
[ "$RC_OUT" = "1" ] || fail "T1: focus HIGH on a high-stakes diff must block (expected 1), got $RC_OUT"
grep -rqi "spec-compliance" "$CAPD" || fail "T1: focus pass prompt was never sent (focus did not fire)"
py_review "$RD/review.json" <<'PY' || fail "T1: focus depth/tagging assertions failed"
import json, sys
d = json.load(open(sys.argv[1]))
foc = [f for f in d["findings"] if f.get("lens") == "focus"]
assert len(foc) == 1 and foc[0]["severity"] == "HIGH", f"focus HIGH not unioned/tagged: {d['findings']}"
assert d.get("focus_ran") is True, "focus_ran must be true"
assert d.get("focus_requested") is True, "focus_requested must be true"
assert "focus" in d["lenses"] and "redteam" not in d["lenses"], f"lenses wrong: {d['lenses']}"
assert not [f for f in d["findings"] if f.get("lens") == "lens1"], "lens1 was supposed to be clean"
print("T1 inner OK")
PY
echo "PASS B-T1: non-spine high-stakes auto-fires the focus pass (no flag); focus HIGH blocks; lens=focus"

# --- T2: an ORDINARY low-stakes diff => focus does NOT fire (pays nothing); rc 0; no focus in lenses. ---
TGT="$WORK/t2"; new_target "$TGT" ordinary; RD="$WORK/rd2"; CAPD="$WORK/cap2"
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_CAPDIR="$CAPD" LENS1_OUT="$CLEAN" FOCUS_OUT="$FOCUS_HIGH" \
  run_sail "$TGT" "$RD"
[ "$RC_OUT" = "0" ] || fail "T2: an ordinary low-stakes diff must not fire focus/block (expected 0), got $RC_OUT"
[ -z "$(grep -rli 'spec-compliance' "$CAPD" 2>/dev/null || true)" ] || fail "T2: focus pass fired on an ordinary diff (over-fired)"
py_review "$RD/review.json" <<'PY' || fail "T2: focus signals present on a low-stakes diff"
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("focus_ran") is False and d.get("focus_requested") is False, "focus must not be requested/run on low-stakes"
assert "focus" not in d["lenses"], "focus must not be in lenses on a low-stakes diff"
PY
echo "PASS B-T2: low-stakes diff is unchanged and pays nothing (no focus fired)"

# --- T3: high-stakes diff WITH the red-team backend available => red-team is the second perspective;
#         focus does NOT fire (no redundant third pass). ---
TGT="$WORK/t3"; new_target "$TGT" files; RD="$WORK/rd3"; CAPD="$WORK/cap3"; SEN="$WORK/rtsen3"
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_CAPDIR="$CAPD" LENS1_OUT="$CLEAN" FOCUS_OUT="$FOCUS_HIGH" \
SAIL_REDTEAM_CMD="bash $RT_MOCK" RT_OUT="$CLEAN" RT_SENTINEL="$SEN" \
  run_sail "$TGT" "$RD"
[ -f "$SEN" ] || fail "T3: red-team backend was not invoked on a high-stakes diff"
[ -z "$(grep -rli 'spec-compliance' "$CAPD" 2>/dev/null || true)" ] || fail "T3: focus fired though red-team is the second perspective (redundant third pass)"
py_review "$RD/review.json" <<'PY' || fail "T3: focus fired alongside red-team"
import json, sys
d = json.load(open(sys.argv[1]))
assert "redteam" in d["lenses"], f"red-team must be the second perspective: {d['lenses']}"
assert d.get("focus_ran") is False and "focus" not in d["lenses"], "focus must NOT run when red-team is the second perspective"
PY
echo "PASS B-T3: red-team active => no redundant focused third pass"

# --- T4: NO codex by default — SAIL_REVIEW_CMD2 points at a codex sentinel but NO --dual-lens flag;
#         a high-stakes focus run must NOT invoke the codex lens2 backend (focus is same-family). ---
TGT="$WORK/t4"; new_target "$TGT" files; RD="$WORK/rd4"; CSEN="$WORK/csen4"
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" LENS1_OUT="$CLEAN" FOCUS_OUT="$CLEAN" \
SAIL_REVIEW_CMD2="bash $CODEX_MOCK" CODEX_SENTINEL="$CSEN" \
  run_sail "$TGT" "$RD"
[ ! -f "$CSEN" ] || fail "T4: the codex lens2 backend was invoked WITHOUT --dual-lens (codex consumed by default — policy violation)"
py_review "$RD/review.json" <<'PY' || fail "T4: lens2 leaked into a default high-stakes run"
import json, sys
d = json.load(open(sys.argv[1]))
assert "lens2" not in d["lenses"], "lens2 must never run by default"
assert d.get("dual_lens_requested") is False, "dual-lens must not be auto-requested"
assert d.get("focus_ran") is True, "focus (same-family) should be the second perspective here"
PY
echo "PASS B-T4: no codex/lens2 consumption by default (focus is same-family)"

# --- T5: focus backend ERROR fails closed (never-mask), like lens2/red-team. ---
TGT="$WORK/t5"; new_target "$TGT" files; RD="$WORK/rd5"
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" LENS1_OUT="$CLEAN" FOCUS_OUT="garbage-not-json" FOCUS_RC=0 \
  run_sail "$TGT" "$RD"
[ "$RC_OUT" = "1" ] || fail "T5: an unparseable focus response on a high-stakes diff must fail closed (expected 1), got $RC_OUT"
py_review "$RD/review.json" <<'PY' || fail "T5: focus backend-error not recorded as error"
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("status") == "error", f"unusable focus response must set status=error, got {d.get('status')}"
PY
echo "PASS B-T5: focus backend error fails closed (never-mask)"

# --- T6: #116 consistency (AC#5) — focus is SAME-family, so it must NEVER be reported as a degraded
#         CROSS-family lens, and its presence must not manufacture a spurious ALERT. On a high-stakes
#         focus run with no red-team backend configured, degraded_lenses() reports no `focus` entry
#         and the tone stays INFO (unconfigured red-team is the operator's expected setup), NOT ALERT. ---
TGT="$WORK/t6"; new_target "$TGT" files; RD="$WORK/rd6"
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" LENS1_OUT="$CLEAN" FOCUS_OUT="$CLEAN" \
  run_sail "$TGT" "$RD"
[ "$RC_OUT" = "0" ] || fail "T6: a clean high-stakes focus run must pass (expected 0), got $RC_OUT"
py_review "$RD/review.json" <<'PY' || fail "T6: #116 degraded-classification consistency failed"
import json, sys
import sail.review as r
d = json.load(open(sys.argv[1]))
assert d.get("focus_ran") is True, "focus should have run (high-stakes, same-family)"
deg = r.degraded_lenses(d)
assert not any(x["lens"] == "focus" for x in deg), f"focus (same-family) must never be a cross-family degradation: {deg}"
# focus running does not fabricate a real-deviation ALERT (unconfigured red-team is INFO, not ALERT).
assert r.degraded_tone(deg) != "ALERT", f"focus run must not raise a spurious ALERT tone: {deg}"
PY
echo "PASS B-T6: #116 consistency — focus is same-family (never a cross-family degradation; no spurious ALERT)"

# --- T7: resume freshness includes depth (AC#6). A resumed high-stakes run whose cached review.json
#         is single-lens (no focus, no red_team) must be treated as STALE and re-reviewed so focus
#         runs — not reused as if it were reviewed at the right depth. ---
TGT="$WORK/t7"; new_target "$TGT" files; RD="$WORK/rd7"; CAPD="$WORK/cap7"
# Seed run-state as a resume of the SAME scope (resumed = run-state.json exists; diff_ref stored as
# the RESOLVED SHA so scope_match holds) and a completed SINGLE-LENS cached review fresh by
# diff_hash/plan_hash — so ONLY the missing-focus-depth guard can invalidate reuse (a pre-#148 /
# degraded single-lens high-stakes cache).
mkdir -p "$RD"
python3 - "$TGT" "$RD" <<'PY'
import json, os, sys
import sail.review as review_mod
from sail.runner import _resolve_diff_base, _prestage_untracked
from sail.runstate import RunState
target, rd = os.path.abspath(sys.argv[1]), sys.argv[2]
# Prestage the untracked f-files exactly as the runner does before fingerprinting, so the seeded
# diff_hash matches the run-time diff_hash — isolating the focus-depth guard as the ONLY invalidator
# (not the #45 diff-content gate).
_prestage_untracked(target, rd)
base = _resolve_diff_base(target, "HEAD")           # the immutable SHA the runner will pin to
dh = review_mod.diff_fingerprint(target, base)
ph = review_mod.plan_fingerprint(rd)
# A valid resume run-state of the SAME scope (target + resolved diff_ref).
st = RunState.init(rd, ["ruff"])
st.data["target"] = target
st.data["diff_ref"] = base
st.save()
# A completed SINGLE-LENS cache (lenses == ["lens1"]) fresh by diff_hash/plan_hash but lacking focus.
json.dump({"status": "completed", "rc": 0, "parse_ok": True, "round": 1, "empty_diff": False,
           "counts": {"CRITICAL": 0, "HIGH": 0, "MEDIUM": 0, "LOW": 0}, "findings": [],
           "lenses": ["lens1"], "diff_hash": dh, "plan_hash": ph,
           "plan_verification": {"status": "no-plan", "acceptance_criteria": []},
           "target": target, "diff_ref": base},
          open(os.path.join(rd, "review.json"), "w"))
PY
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_CAPDIR="$CAPD" LENS1_OUT="$CLEAN" FOCUS_OUT="$CLEAN" \
  run_sail "$TGT" "$RD" --round 1
grep -rqi "spec-compliance" "$CAPD" || fail "T7: a single-lens high-stakes cache was reused (focus never re-ran on resume)"
py_review "$RD/review.json" <<'PY' || fail "T7: resume did not widen to focus"
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("focus_ran") is True and "focus" in d["lenses"], "resumed high-stakes run must re-review at focus depth"
PY
echo "PASS B-T7: resume-freshness — a single-lens high-stakes cache is re-reviewed at focus depth (AC#6)"

echo "ALL PASS: test_sail_148_review_depth"
