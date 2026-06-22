#!/usr/bin/env bash
# test_sail_66_redteam_escalation.sh — issue #66: risk-gated repo-exploring red-team escalation
# on high-stakes diffs (evidence-required, beyond-diff). The review/implementation-side analogue of
# the #62 plan-adversary. On a HIGH-STAKES diff (cross-cutting / large / security-relevant) /sail
# escalates to a TOOL-USING adversarial pass invoked with cwd=target (so it can Read/Grep beyond the
# diff) whose findings are EVIDENCE-REQUIRED (a finding with no tool-execution evidence is dropped,
# never blocks). Its evidenced findings union into the correctness `findings` (lens="redteam") —
# kept DISTINCT from the tidiness/code-health lens. Risk-gated: ordinary diffs never trigger it.
#
# Coverage:
#   Part A (pure, fast)  — is_high_stakes gate (file-count / line-count / security / ordinary / empty),
#                          _has_security_signal, build_redteam_prompt craft (repo-exploring + evidence
#                          + STRIDE 6-threats), _has_evidence, no .format brace bug.
#   Part B (integration) — full `sail run --diff`: auto-trigger + block + lens-separation + STRIDE in
#                          the ACTUAL prompt; ordinary-diff no-trigger (backend never called);
#                          evidence-drop; no-backend clean degrade; backend-error fail-closed;
#                          --red-team force flag.
# Hermetic per #64: mocks the red-team backend (SAIL_REDTEAM_CMD) and the review backend
# (SAIL_REVIEW_CMD); uses throwaway git targets; never calls a real CLI; never asserts on live git.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
# Keep the gate registry to one fast checker so the deterministic gates never mask the review arm
# under test (the red-team pass is a review-stage concern).
export SAIL_CHECKERS=ruff
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"

fail() { echo "FAIL: $*"; exit 1; }

# ---------------------------------------------------------------------------
# Part A — pure unit checks (no LLM, no git): the gate + prompt craft.
# ---------------------------------------------------------------------------
python3 - <<'PY' || fail "Part A: pure gate/prompt-craft checks failed"
import sail.review as r

# --- is_high_stakes gate ---
def diff(files=1, body_lines=2, security=False):
    # Build a synthetic unified diff with `files` file-headers and `body_lines` added lines.
    out = []
    for i in range(files):
        out += [f"diff --git a/f{i}.py b/f{i}.py", "index 000..111 100644",
                f"--- a/f{i}.py", f"+++ b/f{i}.py", "@@ -1 +1 @@"]
        for j in range(body_lines):
            line = "+    subprocess.run(['x'])" if (security and i == 0 and j == 0) else f"+    a{i}_{j} = {j}"
            out.append(line)
    return "\n".join(out) + "\n"

assert r.is_high_stakes(diff(files=5, body_lines=1)) is True, "5-file diff must be high-stakes (cross-cutting)"
assert r.is_high_stakes(diff(files=1, body_lines=90)) is True, "90-line diff must be high-stakes (large)"
assert r.is_high_stakes(diff(files=1, body_lines=2, security=True)) is True, "security-token diff must be high-stakes"
assert r.is_high_stakes(diff(files=1, body_lines=2)) is False, "small non-security diff must NOT be high-stakes"
assert r.is_high_stakes(diff(files=4, body_lines=1)) is False, "4 files is below the default file threshold"
assert r.is_high_stakes("") is False, "empty diff is never high-stakes"
assert r.is_high_stakes(None) is False, "None diff is never high-stakes"

# --- decision-spine / core-interface path trigger (AC#1/#3): a SMALL change to a declared spine
#     path is high-stakes regardless of size; default (no SAIL_REDTEAM_SPINE_PATHS) never fires. ---
import os
small_spine = "diff --git a/sail/runner.py b/sail/runner.py\n--- a/sail/runner.py\n+++ b/sail/runner.py\n@@ -1 +1 @@\n+    x = 1\n"
os.environ.pop("SAIL_REDTEAM_SPINE_PATHS", None)
assert r.is_high_stakes(small_spine) is False, "no declared spine paths => small core-file change stays low-stakes"
os.environ["SAIL_REDTEAM_SPINE_PATHS"] = "sail/runner.py, sail/checkers.py"
assert r.is_high_stakes(small_spine) is True, "a small change to a DECLARED spine path must be high-stakes"
assert r.is_high_stakes(small_spine.replace("sail/runner.py", "docs/readme.md")) is False, "non-spine small change stays low-stakes"
assert r._diff_changed_paths(small_spine) == ["sail/runner.py"], "changed-path extraction wrong"
os.environ.pop("SAIL_REDTEAM_SPINE_PATHS", None)

# A file-header line that merely CONTAINS a token must not be mistaken for added content.
assert r._has_security_signal("+++ b/password_reset.py\n") is False, "file-header token must not trip security signal"
assert r._has_security_signal(diff(files=1, body_lines=1, security=True)) is True, "added subprocess line is a security signal"

# --- build_redteam_prompt craft (repo-exploring + evidence-required) ---
base = r.build_redteam_prompt("DIFFBODY", stride=False).lower()
for needle in ("beyond the diff", "grep", "caller", "evidence", "red-team", "diffbody"):
    assert needle in base, f"red-team prompt missing '{needle}'"
assert "verification avoidance" in base and ">80%" in base, "red-team prompt missing review craft"
assert "untrusted data" in base, "red-team prompt missing OWASP LLM01 untrusted-diff framing"
# STRIDE-lite is OMITTED unless security-relevant.
assert "spoofing" not in base, "STRIDE-lite must be absent on a non-security prompt"

stride = r.build_redteam_prompt("DIFFBODY", stride=True).lower()
for threat in ("spoofing", "tampering", "repudiation", "information disclosure",
               "denial of service", "elevation of privilege"):
    assert threat in stride, f"STRIDE-lite block missing '{threat}'"

# --- _has_evidence filter (isinstance, not str() coercion) ---
assert r._has_evidence({"evidence": "grep -rn foo -> 3 callers"}) is True
assert r._has_evidence({"evidence": "   "}) is False
assert r._has_evidence({"evidence": None}) is False
assert r._has_evidence({}) is False
assert r._has_evidence({"evidence": []}) is False, "non-string evidence must not pass (no str() coercion)"

# --- backend opt-in: no SAIL_REDTEAM_CMD => unavailable (purely additive) ---
import os
os.environ.pop("SAIL_REDTEAM_CMD", None)
assert r.redteam_available() is False, "with no SAIL_REDTEAM_CMD the escalation is unavailable"
print("Part A OK")
PY
echo "PASS A: high-stakes gate + repo-exploring/evidence prompt craft + STRIDE-lite + opt-in backend"

# ---------------------------------------------------------------------------
# Part B — integration via `sail run --diff` (mocked backends, throwaway targets).
# ---------------------------------------------------------------------------
# Review backend mock: discards stdin, emits $REVIEW_OUT, exits 0 (isolates the red-team arm).
REVIEW_MOCK="$WORK/review_mock.sh"
# shellcheck disable=SC2016  # the ${REVIEW_OUT:-} expansion is written LITERALLY into the mock script
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "%s" "${REVIEW_OUT:-}"' 'exit 0' > "$REVIEW_MOCK"
chmod +x "$REVIEW_MOCK"

# Red-team backend mock: CAPTURES the prompt it received (so we can assert STRIDE folds in only for
# security diffs), TOUCHES a sentinel (so we can prove it was/ wasn't invoked), emits $RT_OUT, exits $RT_RC.
RT_MOCK="$WORK/rt_mock.sh"
cat > "$RT_MOCK" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat > "${RT_PROMPT:-/dev/null}"
[ -n "${RT_SENTINEL:-}" ] && : > "$RT_SENTINEL"
printf '%s' "${RT_OUT:-}"
exit "${RT_RC:-0}"
EOF
chmod +x "$RT_MOCK"

CLEAN='{"findings":[],"summary":"no issues"}'
# Evidenced HIGH red-team finding (must block).
RT_EVIDENCED='{"findings":[{"severity":"HIGH","category":"correctness","file":"caller.py","line":7,"issue":"out-of-diff caller breaks","evidence":"grep -rn helper( -> caller.py:7 passes 1 arg; diff made helper require 2","recommendation":"update caller"}],"summary":"1 high"}'
# Unevidenced HIGH red-team finding (must be DROPPED — evidence-required).
RT_UNEVIDENCED='{"findings":[{"severity":"HIGH","category":"correctness","file":"x.py","line":1,"issue":"looks wrong","recommendation":"fix"}],"summary":"speculation"}'

# Throwaway git target. $1=dir, $2=kind (security|ordinary|big).
new_target() {
  local d="$1" kind="${2:-ordinary}"
  mkdir -p "$d"
  printf 'def helper(a):\n    return a\n' > "$d/mod.py"
  git -C "$d" init -q
  git -C "$d" add -A
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm base
  case "$kind" in
    security) printf 'def helper(a):\n    import subprocess\n    return subprocess.run([a])\n' > "$d/mod.py" ;;
    big)      { echo 'def helper(a):'; for i in $(seq 1 90); do echo "    v$i = $i"; done; echo '    return a'; } > "$d/mod.py" ;;
    *)        printf 'def helper(a):\n    return a + 1  # changed\n' > "$d/mod.py" ;;
  esac
}

run_sail() { # $1=target $2=run-dir ; extra args after -> passed to sail run ; sets RC_OUT
  set +e
  python3 -m sail run --target "$1" --diff HEAD --run-dir "$2" "${@:3}" >/dev/null 2>&1
  RC_OUT=$?
  set -e
}

py_review() { python3 - "$@"; }

# --- T1: a SECURITY-relevant (=> high-stakes) diff auto-triggers the red-team; an evidenced HIGH
#         finding blocks; the finding is tagged lens=redteam in `findings` (NOT in tidiness); and
#         the ACTUAL prompt the backend received carries the STRIDE-lite block. ---
TGT="$WORK/t1"; new_target "$TGT" security; RD="$WORK/rd1"; CAP="$WORK/cap1"; SEN="$WORK/sen1"
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_REDTEAM_CMD="bash $RT_MOCK" RT_OUT="$RT_EVIDENCED" RT_PROMPT="$CAP" RT_SENTINEL="$SEN" \
  run_sail "$TGT" "$RD"
[ "$RC_OUT" = "1" ] || fail "T1: an evidenced HIGH red-team finding on a high-stakes diff must block (expected 1), got $RC_OUT"
[ -f "$SEN" ] || fail "T1: red-team backend was not invoked on a high-stakes diff"
grep -qi "spoofing" "$CAP" || fail "T1: STRIDE-lite not folded into the prompt for a security-relevant diff"
py_review "$RD/review.json" <<'PY' || fail "T1: lens-separation / red_team block assertions failed"
import json, sys
d = json.load(open(sys.argv[1]))
rt = [f for f in d["findings"] if f.get("lens") == "redteam"]
assert len(rt) == 1 and rt[0]["severity"] == "HIGH", "evidenced red-team HIGH not unioned into correctness findings"
assert rt[0].get("evidence"), "evidenced finding lost its evidence"
# Lens-separation: the red-team finding must NOT pollute the tidiness block (tidiness not even run here).
assert "tidiness" not in d, "tidiness block present though --tidiness not passed"
b = d["red_team"]
assert b["triggered"] is True and b["stride"] is True and b["error"] is False, f"red_team block wrong: {b}"
assert b["n_evidenced"] == 1, "n_evidenced wrong"
print("T1 inner OK")
PY
echo "PASS B-T1: security high-stakes diff auto-triggers red-team; evidenced HIGH blocks; STRIDE folded in; lens=redteam"

# --- T2: an ORDINARY low-stakes diff does NOT trigger the red-team (backend never invoked, no
#         red_team block, no regression vs current behavior). ---
TGT="$WORK/t2"; new_target "$TGT" ordinary; RD="$WORK/rd2"; SEN="$WORK/sen2"
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_REDTEAM_CMD="bash $RT_MOCK" RT_OUT="$RT_EVIDENCED" RT_SENTINEL="$SEN" \
  run_sail "$TGT" "$RD"
[ "$RC_OUT" = "0" ] || fail "T2: an ordinary diff must not be escalated/blocked (expected 0), got $RC_OUT"
[ ! -f "$SEN" ] || fail "T2: red-team backend was invoked on an ORDINARY diff (gate over-fired)"
py_review "$RD/review.json" <<'PY' || fail "T2: red_team block present on an ordinary diff"
import json, sys
assert "red_team" not in json.load(open(sys.argv[1])), "red_team block written though gate did not trip"
PY
echo "PASS B-T2: ordinary diff does not trigger the red-team (no spawn, no block, no regression)"

# --- T3: evidence-required — an UNEVIDENCED HIGH red-team finding is DROPPED (does not block; it is
#         recorded under red_team.unevidenced for audit). ---
TGT="$WORK/t3"; new_target "$TGT" security; RD="$WORK/rd3"
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_REDTEAM_CMD="bash $RT_MOCK" RT_OUT="$RT_UNEVIDENCED" \
  run_sail "$TGT" "$RD"
[ "$RC_OUT" = "0" ] || fail "T3: an unevidenced red-team finding must be dropped, not block (expected 0), got $RC_OUT"
py_review "$RD/review.json" <<'PY' || fail "T3: evidence filter assertions failed"
import json, sys
d = json.load(open(sys.argv[1]))
assert not [f for f in d["findings"] if f.get("lens") == "redteam"], "unevidenced finding leaked into blocking findings"
b = d["red_team"]
assert b["n_evidenced"] == 0 and len(b["unevidenced"]) == 1, f"unevidenced not recorded: {b}"
assert "dropped" in b["unevidenced"][0], "drop reason not recorded on the dropped finding"
PY
echo "PASS B-T3: evidence-required — a finding without tool evidence is dropped, never blocks"

# --- T4: high-stakes diff but NO red-team backend configured → degrades cleanly to single-lens
#         (no block, no red_team block, logged), purely additive. ---
TGT="$WORK/t4"; new_target "$TGT" security; RD="$WORK/rd4"
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
  run_sail "$TGT" "$RD"
[ "$RC_OUT" = "0" ] || fail "T4: no red-team backend must degrade cleanly (expected 0), got $RC_OUT"
py_review "$RD/review.json" <<'PY' || fail "T4: degrade-clean assertions failed"
import json, sys
assert "red_team" not in json.load(open(sys.argv[1])), "red_team block written with no backend available"
PY
grep -qi "no SAIL_REDTEAM_CMD" "$RD/decision-log.md" || fail "T4: clean-degrade not logged"
echo "PASS B-T4: high-stakes diff with no SAIL_REDTEAM_CMD degrades cleanly to single-lens (additive)"

# --- T5: red-team backend ERROR (non-zero rc) fails closed (never-mask), like dual-lens lens2. ---
TGT="$WORK/t5"; new_target "$TGT" security; RD="$WORK/rd5"
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_REDTEAM_CMD="bash $RT_MOCK" RT_OUT="garbage-not-json" RT_RC=3 \
  run_sail "$TGT" "$RD"
[ "$RC_OUT" = "1" ] || fail "T5: a red-team backend error must fail closed (expected 1), got $RC_OUT"
py_review "$RD/review.json" <<'PY' || fail "T5: fail-closed status assertions failed"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["status"] == "error", f"errored red-team must mark review status=error, got {d['status']}"
assert d["red_team"]["error"] is True, "red_team block did not record the error"
PY
echo "PASS B-T5: red-team backend error fails closed (never-mask)"

# --- T6: --red-team FORCE flag escalates even on an ORDINARY (non-high-stakes) diff. ---
TGT="$WORK/t6"; new_target "$TGT" ordinary; RD="$WORK/rd6"; SEN="$WORK/sen6"; CAP="$WORK/cap6"
SAIL_REVIEW_CMD="bash $REVIEW_MOCK" REVIEW_OUT="$CLEAN" \
SAIL_REDTEAM_CMD="bash $RT_MOCK" RT_OUT="$RT_EVIDENCED" RT_SENTINEL="$SEN" RT_PROMPT="$CAP" \
  run_sail "$TGT" "$RD" --red-team
[ "$RC_OUT" = "1" ] || fail "T6: --red-team must force escalation even on an ordinary diff (expected 1), got $RC_OUT"
[ -f "$SEN" ] || fail "T6: --red-team did not invoke the red-team backend"
# An ordinary (non-security) diff: STRIDE-lite must be OMITTED even when forced.
grep -qi "spoofing" "$CAP" && fail "T6: STRIDE-lite leaked onto a non-security forced run" || true
echo "PASS B-T6: --red-team force flag escalates an ordinary diff; STRIDE stays gated on security-relevance"

echo "ALL PASS: test_sail_66_redteam_escalation.sh"
