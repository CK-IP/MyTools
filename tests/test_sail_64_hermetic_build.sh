#!/usr/bin/env bash
# test_sail_64_hermetic_build.sh — issue #64: tighten autonomous-build guidance
# toward genuinely-hermetic / self-verifying tests, to cut self-inflicted review churn.
#
# Background (#55-v2): /sail's autonomous TDD shipped a test whose "hermetic" PATH was
# defeated by doctor.sh's own internal PATH augmentation — the isolation was a silent
# no-op, costing a review round to catch+fix (needed a CK_DOCTOR_NO_PATH_AUGMENT seam).
# Fix: a compact, advisory build-stage subsection in commands/sail.md Stage 2 that tells
# the autonomous author to PROVE hermeticity (not assume it) and to add a code seam
# in-change when isolation otherwise can't be real. Prompt-level only — no new gate.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

SAIL_MD="commands/sail.md"
[ -f "$SAIL_MD" ] || fail "T0: $SAIL_MD not found"

# Isolate the Stage 2 (Build) section: from the "### Stage 2 — Build" heading up to the
# next "### " heading (Stage 3). The hermeticity guidance must live in the BUILD stage,
# not anywhere in the file.
STAGE2="$(awk '/^### Stage 2 — Build/{f=1} f&&/^### Stage 3/{f=0} f' "$SAIL_MD")"
[ -n "$STAGE2" ] || fail "T0: could not isolate '### Stage 2 — Build' section"

# --- T1: the build stage gains a hermetic / self-verifying tests directive. ---
echo "$STAGE2" | grep -qi 'hermetic' \
  || fail "T1: Stage 2 (Build) must contain hermetic-tests guidance"
echo "$STAGE2" | grep -qi 'isolat' \
  || fail "T1: Stage 2 guidance must speak to test isolation"
echo "PASS T1: Stage 2 (Build) contains hermetic / self-verifying tests guidance"

# --- T2: the guidance says PROVE / verify isolation, not assume it. ---
# Note: 'assert' is deliberately excluded — in the prose it appears only inside the
# anti-pattern phrase ("not assert it in the docstring and move on"), so matching it
# would let the test pass for the very behavior it means to forbid.
echo "$STAGE2" | grep -qi 'prove\|verify\|confirm' \
  || fail "T2: guidance must tell the author to prove/verify isolation, not assume it"
echo "PASS T2: guidance instructs proving isolation rather than assuming it"

# --- T3: names the concrete #55-v2 worked example so the lesson is actionable. ---
# The seam token literally contains 'DOCTOR' and 'PATH', so a separate grep for either
# would be subsumed by this check and could never independently fail — assert the seam
# token plus the failure *mechanism* (re-augmentation) instead, which is not subsumed.
echo "$STAGE2" | grep -q 'CK_DOCTOR_NO_PATH_AUGMENT' \
  || fail "T3: guidance must name the doctor.sh CK_DOCTOR_NO_PATH_AUGMENT code-seam remedy"
# 'internally' / 're-derive' name the mechanism (code re-deriving scrubbed state behind
# the test's back) and are NOT substrings of the seam token, so this is a real, independent check.
echo "$STAGE2" | grep -qi 're-derive\|internally' \
  || fail "T3: guidance must describe the failure mechanism (code re-deriving state internally)"
echo "PASS T3: guidance cites the #55-v2 doctor.sh example + CK_DOCTOR_NO_PATH_AUGMENT seam"

# --- T4: the escape hatch — add a code seam in-change when isolation can't otherwise be real. ---
# This is the consistency fix for the plan's HIGH: the prescribed isolation check must be
# paired with the seam remedy, so it never points at an action the code silently defeats.
echo "$STAGE2" | grep -qi 'seam' \
  || fail "T4: guidance must tell the author to add a code seam when isolation can't otherwise be real"
echo "PASS T4: guidance delivers the in-change code-seam escape hatch"

# --- T5: explicitly advisory / prompt-level — no new gate, exit code, or blocking step. ---
echo "$STAGE2" | grep -qi 'advisory\|reminder\|prompt-level\|not a new gate\|no new gate' \
  || fail "T5: hermeticity guidance must be marked advisory / prompt-level (not a new gate)"
# Guard: the new build-stage text must NOT introduce a fail-closed / blocking gate.
# Match only AFFIRMATIVE blocking phrasing — the advisory disclaimer ("never blocks
# convergence", "adds no exit code") is exactly what we WANT and must not trip the guard.
HERMETIC_BLOCK="$(echo "$STAGE2" | grep -i -A2 'hermetic' || true)"
if echo "$HERMETIC_BLOCK" | grep -qi 'fail closed\|fail-closed\|must block\|adds an exit code\|returns exit 1\|this gate fails'; then
  fail "T5: hermeticity guidance must not add a blocking gate / exit code"
fi
echo "PASS T5: hermeticity guidance is advisory (no new gate / exit code)"

# --- T6: scope guard — prose-only, no sail Python package changes (no new deterministic guard). ---
if ! git rev-parse --verify main >/dev/null 2>&1; then
  echo "SKIP T6: no main ref to diff against"
else
  PY_CHANGED="$(git diff --name-only main -- 'sail/*.py' 2>/dev/null || true)"
  PY_UNTRACKED="$(git ls-files --others --exclude-standard -- 'sail/*.py' 2>/dev/null || true)"
  PY_ALL="$(printf '%s\n%s\n' "$PY_CHANGED" "$PY_UNTRACKED" | grep -v '^$' || true)"
  [ -z "$PY_ALL" ] || fail "T6: #64 is advisory prose only — sail/*.py changed: $PY_ALL"
  echo "PASS T6: no sail/*.py changes — advisory prose only, no new guard"
fi

echo "PASS: sail #64 hermetic-build guidance verified"
