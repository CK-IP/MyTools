#!/usr/bin/env bash
# test_surf_74_dual_lens.sh — issue #74: /surf teammates run genuine cross-family dual-lens
# (codex + claude CLI lenses, NOT the session-bound advisor()), and a degraded second lens is
# made loud + compensated before merge — never a silent single-lens merge.
# Doc-content assertions on commands/surf.md + INSTALL.md (mirrors test_surf.sh idiom). surf.md is
# LLM-prompt text with no executable runtime, so this file pins the documented orchestration; the
# EXECUTABLE behavior — review.json's dual-lens signal and the degraded-vs-ok merge/park decision
# (sail.review.dual_lens_status) — is pinned hermetically in test_sail_74_dual_lens_signal.sh.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SURF="$REPO_ROOT/commands/surf.md"
INSTALL="$REPO_ROOT/INSTALL.md"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

[ -s "$SURF" ] && pass "surf.md exists and not empty" || fail "surf.md missing/empty"

# AC#1 (reconciled by #136 AC5) — the worker no longer builds with `--dual-lens`. The live shipped
# default (#83) is single-lens-by-design (codex builds, one cross-family claude review,
# SAIL_REVIEW_CMD2 unset); `--dual-lens` + SAIL_REVIEW_CMD2 now appear ONLY in the degraded-path
# compensation re-review (`sail review --dual-lens`), never on the worker's primary build.
grep -qiE 'single-lens-by-design|single-lens by design' "$SURF" \
  && pass "AC1: surf.md documents the worker is single-lens-by-design (#83/#136 AC5)" \
  || fail "AC1: single-lens-by-design contract missing from surf.md"
# The guard's branch table must use the EXACT verdict string dual_lens_status() returns
# ('single-by-design'), not a paraphrase like 'single' — else a supervisor matching the literal
# verdict would not recognize the default mode and could park a green default build (#136 review).
EXPECTED_VERDICT="$(python3 -c 'import sys; sys.path.insert(0,"'"$REPO_ROOT"'"); from sail.review import dual_lens_status; print(dual_lens_status({"dual_lens_requested": False}))')"
grep -qF "$EXPECTED_VERDICT" "$SURF" \
  && pass "AC1: surf.md guard uses the exact dual_lens_status verdict token ('$EXPECTED_VERDICT')" \
  || fail "AC1: surf.md guard does not use the exact verdict token '$EXPECTED_VERDICT'"
grep -qE 'sail review.*--dual-lens|--dual-lens.*sail review' "$SURF" \
  && pass "AC1: surf.md keeps --dual-lens on the degraded-path compensation re-review" \
  || fail "AC1: degraded-path --dual-lens compensation missing"
# The compensation snippet must ACTUALLY set SAIL_REVIEW_CMD2 on (or adjacent to) the
# `sail review --dual-lens` command — not merely mention the token in prose. Assert the assignment
# `SAIL_REVIEW_CMD2=...` co-occurs with `sail review` within a 3-line window (mutation-resistant).
if grep -Pzoq 'SAIL_REVIEW_CMD2=[^\n]*(\n[^\n]*){0,2}sail review' "$SURF" 2>/dev/null \
   || awk 'BEGIN{w=0} /SAIL_REVIEW_CMD2=/{w=3} w>0 && /sail review/{print "HIT"; exit} {if(w>0)w--}' "$SURF" | grep -q HIT; then
  pass "AC1: surf.md SETS SAIL_REVIEW_CMD2 on the compensation sail-review command (not just prose)"
else
  fail "AC1: SAIL_REVIEW_CMD2 not set on the compensation sail-review command"
fi

# AC#2 — documents the CLI-lens rationale, explicitly contrasted with advisor().
grep -qi 'advisor' "$SURF" \
  && pass "AC2: surf.md references advisor() (the contrast)" \
  || fail "AC2: advisor() contrast missing"
grep -qiE 'CLI.?subprocess|subprocess lens|CLI lens' "$SURF" \
  && pass "AC2: surf.md explains CLI-subprocess lenses" \
  || fail "AC2: CLI-subprocess-lens rationale missing"

# AC#4 — explicit REQUIRED pre-merge step keyed off the degradation signal,
#        with a defined no-silent-merge failure behavior.
grep -qF 'dual_lens_requested' "$SURF" \
  && pass "AC4: surf.md pre-merge step keys off dual_lens_requested" \
  || fail "AC4: dual_lens_requested detection missing"
grep -qiE 'run the missing (second )?lens' "$SURF" \
  && pass "AC4: surf.md runs the missing lens before merge" \
  || fail "AC4: pre-merge compensation step missing"
grep -qiE 'never silently merge|no silent single-lens' "$SURF" \
  && pass "AC4: surf.md defines no-silent-merge failure behavior" \
  || fail "AC4: no-silent-merge behavior undefined"

# AC#5 — INSTALL.md documents codex as the /surf dual-lens second backend.
grep -qF 'SAIL_REVIEW_CMD2' "$INSTALL" \
  && pass "AC5: INSTALL.md documents the SAIL_REVIEW_CMD2 codex backend" \
  || fail "AC5: INSTALL.md codex-backend note missing"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
