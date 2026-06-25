#!/usr/bin/env bash
# test_bandit_sarif.sh
# Issue #106: doctor.sh must own the bandit SARIF *capability* layer. The sail bandit gate runs
# `bandit -f sarif` (sail/checkers.py); a bare `command -v bandit` passes while the formatter is
# silently broken (rc=2). doctor.sh adds a capability check that actually exercises `bandit -f sarif`.
#
# Decision (Chris, #106): capability-check-only. Current bandit ships SARIF built-in, so install.sh
# does NOT inject the redundant `bandit-sarif-formatter` plugin (it would create a duplicate `sarif`
# entry point). This test pins that decision and the #104-parser-safety constraint.
#
# This test reads the scripts; it never runs install.sh/doctor.sh, hits the network, or installs anything.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCTOR_SH="${DOCTOR_SH:-$REPO_ROOT/doctor.sh}"
INSTALL_SH="${INSTALL_SH:-$REPO_ROOT/install.sh}"
GUARD_SH="${GUARD_SH:-$REPO_ROOT/tests/test_install_tools.sh}"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- (1) doctor.sh exercises `bandit -f sarif` (the capability check exists) ---
if grep -Eq 'bandit[[:space:]]+-f[[:space:]]+sarif' "$DOCTOR_SH"; then
  pass "doctor.sh has a bandit -f sarif capability check"
else
  fail "doctor.sh does NOT invoke 'bandit -f sarif' — the SARIF capability check is missing (#106)"
fi

# --- (2) install.sh does NOT inject the redundant bandit-sarif-formatter plugin ---
if grep -Eq 'pipx[[:space:]]+inject[[:space:]]+bandit[[:space:]]+bandit-sarif-formatter' "$INSTALL_SH"; then
  fail "install.sh injects bandit-sarif-formatter — #106 chose capability-check-only (built-in SARIF; no redundant plugin)"
else
  pass "install.sh does not inject the redundant bandit-sarif-formatter plugin"
fi

# --- (3) the #104 sync guard's CANONICAL set does NOT list the plugin (not a top-level tool) ---
if grep -Eq '^CANONICAL=' "$GUARD_SH" && grep '^CANONICAL=' "$GUARD_SH" | grep -q 'bandit-sarif-formatter'; then
  fail "test_install_tools.sh CANONICAL lists bandit-sarif-formatter — it is a plugin, not a top-level tool"
else
  pass "test_install_tools.sh CANONICAL does not list bandit-sarif-formatter (doctor.sh owns the plugin layer)"
fi

# --- (4) the doctor.sh check introduces no NEW `for t in` gate loop (protects the #104 parser) ---
# The #104 guard extracts DOCTOR_SET from `for t in <tools>; do` lines (minus the `for t in claude`
# required-tools loop). doctor.sh must contain exactly ONE non-claude `for t in` loop (the gate loop).
for_t_count="$(grep -Ec 'for t in ' "$DOCTOR_SH" || true)"
claude_loop="$(grep -Ec 'for t in claude' "$DOCTOR_SH" || true)"
non_claude_for_t=$((for_t_count - claude_loop))
if [ "$non_claude_for_t" -eq 1 ]; then
  pass "doctor.sh still has exactly one non-claude 'for t in' gate loop (#104 parser unaffected)"
else
  fail "doctor.sh has $non_claude_for_t non-claude 'for t in' loops (expected 1) — would corrupt the #104 DOCTOR_SET parse"
fi

echo ""
echo "test_bandit_sarif.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
