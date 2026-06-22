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

# AC#1 — teammate engine invocation enables dual-lens + a second backend.
# Must co-occur with the teammate `sail run` command (not the unrelated human-input
# `--dual-lens` mention elsewhere in surf.md), so the assertion is meaningful.
grep -qE 'sail run.*--dual-lens|--dual-lens.*sail run' "$SURF" \
  && pass "AC1: surf.md teammate sail-run invocation enables --dual-lens" \
  || fail "AC1: --dual-lens not on the teammate sail-run invocation"
grep -qF 'SAIL_REVIEW_CMD2' "$SURF" \
  && pass "AC1: surf.md sets SAIL_REVIEW_CMD2 (second lens backend)" \
  || fail "AC1: SAIL_REVIEW_CMD2 missing from surf.md"

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
