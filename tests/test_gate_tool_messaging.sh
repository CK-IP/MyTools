#!/usr/bin/env bash
# test_gate_tool_messaging.sh
# Issue #55: gate-tool availability is reported as a calm "coverage count", the
# install.sh pipx PATH bug is fixed (ensurepath runs unconditionally), and the
# tool lists are reconciled. Asserts on script SOURCE (deterministic) plus one
# doctor.sh execution (the coverage line is always printed regardless of host).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCTOR="$REPO_ROOT/doctor.sh"
INSTALL="$REPO_ROOT/install.sh"
FORTIFY="$REPO_ROOT/commands/fortify.md"
INSTALL_MD="$REPO_ROOT/INSTALL.md"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- (a) doctor.sh prints the coverage-count line and exits 0 ---
set +e
DOUT="$(bash "$DOCTOR" 2>&1)"; DRC=$?
set -e
if [ "$DRC" -eq 0 ]; then
  pass "doctor.sh exits 0 (missing optional gate tools never fail it)"
else
  fail "doctor.sh exits 0 (got exit $DRC)"
fi
if printf '%s\n' "$DOUT" | grep -q 'Gate coverage:'; then
  pass "doctor.sh prints 'Gate coverage:' line"
else
  fail "doctor.sh prints 'Gate coverage:' line"
fi
if printf '%s\n' "$DOUT" | grep -q 'of .* optional checks active'; then
  pass "doctor.sh coverage line uses 'X of N optional checks active' framing"
else
  fail "doctor.sh coverage line uses 'X of N optional checks active' framing"
fi

# --- (b) calm wording: no scary "Missing", and a Skipped line carries the install pointer ---
if printf '%s\n' "$DOUT" | grep -q 'Missing'; then
  fail "doctor.sh must NOT use the word 'Missing' for gate tools"
else
  pass "doctor.sh avoids the alarming 'Missing' wording"
fi
if printf '%s\n' "$DOUT" | grep -q 'Skipped (not installed)'; then
  if printf '%s\n' "$DOUT" | grep -q 'Run ./install.sh'; then
    pass "skipped line is paired with the 'Run ./install.sh' pointer"
  else
    fail "skipped line is paired with the 'Run ./install.sh' pointer"
  fi
else
  pass "no tools skipped on this host — pointer assertion not applicable"
fi

# --- (c) install.sh runs 'pipx ensurepath' UNCONDITIONALLY (standalone line) ---
if grep -Eq '^[[:space:]]*pipx ensurepath' "$INSTALL"; then
  pass "install.sh has a standalone 'pipx ensurepath' (PATH fix)"
else
  fail "install.sh has a standalone 'pipx ensurepath' (PATH fix)"
fi

# --- (d) install.sh canonical pipx gate set: includes diff-cover, excludes radon/pylint ---
PIPX_LOOP="$(grep -E 'for pkg in .* do' "$INSTALL" || true)"
if printf '%s' "$PIPX_LOOP" | grep -q 'diff-cover'; then
  pass "install.sh pipx loop installs diff-cover (a sail gate)"
else
  fail "install.sh pipx loop installs diff-cover (a sail gate)"
fi
if printf '%s' "$PIPX_LOOP" | grep -Eq 'radon|pylint'; then
  fail "install.sh pipx GATE loop must not list radon/pylint (not sail gates)"
else
  pass "install.sh pipx gate loop excludes non-gate extras radon/pylint"
fi

# --- (e) fortify.md instructs the coverage-count framing ---
if grep -q 'Gate coverage' "$FORTIFY"; then
  pass "fortify.md instructs the 'Gate coverage' coverage-count framing"
else
  fail "fortify.md instructs the 'Gate coverage' coverage-count framing"
fi

# --- (f) doctor.sh footer no longer hardcodes the old diff-cover-less pipx list ---
if grep -q 'pipx install ruff mypy pip-audit bandit' "$DOCTOR"; then
  fail "doctor.sh footer still hardcodes the old pipx list without diff-cover"
else
  pass "doctor.sh footer does not hardcode the stale diff-cover-less pipx list"
fi

# --- (g) INSTALL.md reconciliation: pipx sail-gate line has diff-cover; radon/pylint only as non-gate extras ---
INSTALL_PIPX_LINE="$(grep -E '^for pkg in .* do pipx install' "$INSTALL_MD" || true)"
if printf '%s' "$INSTALL_PIPX_LINE" | grep -q 'diff-cover' && ! printf '%s' "$INSTALL_PIPX_LINE" | grep -Eq 'radon|pylint'; then
  pass "INSTALL.md pipx sail-gate line includes diff-cover and excludes radon/pylint"
else
  fail "INSTALL.md pipx sail-gate line includes diff-cover and excludes radon/pylint"
fi
if grep -Eq 'NOT sail gates.*(radon|pylint)|(radon|pylint).*NOT sail gates' "$INSTALL_MD"; then
  pass "INSTALL.md documents radon/pylint as non-gate /fortify extras"
else
  fail "INSTALL.md documents radon/pylint as non-gate /fortify extras"
fi

echo ""
echo "test_gate_tool_messaging.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
