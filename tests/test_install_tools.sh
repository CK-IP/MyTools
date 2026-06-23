#!/usr/bin/env bash
# test_install_tools.sh
# Issue #104: guard that the installer-supplied gate-tool set stays in sync across
# three places — install.sh (brew + pipx), doctor.sh (the gate loop), and a CANONICAL
# list declared in THIS test. Asserts all three are identical. Adding a tool in the
# future forces an edit to CANONICAL here, and the test won't pass until install.sh
# and doctor.sh both agree — that's the "won't let you forget" guarantee.
#
# Complementary to tests/test_gate_tool_messaging.sh (#55), which checks individual
# tools (diff-cover present, radon/pylint absent) and the messaging wording but NOT
# the full set-equality. This test reads the scripts; it never runs install.sh, hits
# the network, or installs anything.
#
# Deliberate EXCLUSIONS (must NOT be in the canonical installer set):
#   pytest, coverage — per-project (installed in each project venv), not globally supplied.
#   radon, pylint    — optional /fortify analysis extras, not sail gates.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Path seams so the negative cases (a doctored copy with a tool removed/added) are testable.
INSTALL_SH="${INSTALL_SH:-$REPO_ROOT/install.sh}"
DOCTOR_SH="${DOCTOR_SH:-$REPO_ROOT/doctor.sh}"

# Single source of truth for what the installer must supply (sorted).
CANONICAL="bandit diff-cover gitleaks mypy pip-audit ruff semgrep shellcheck"
EXCLUDED="coverage pylint pytest radon"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Normalize a space/newline-separated tool list to a sorted, deduped, blank-free list.
norm() { tr ' ' '\n' | sort -u | grep -v '^$'; }

# --- Extract the three sets from source -----------------------------------------
# Extraction assumes each tool list lives on a single physical line (the current
# install.sh/doctor.sh form). A non-match leaves the set empty so the non-empty
# guards below fail loudly; the trailing `|| true` keeps a no-match grep from
# tripping `set -e` (via pipefail) BEFORE that guard can report it cleanly.
#
# brew gate set: EVERY line-start 'brew install <tools> || ...' line — no `head -1`,
# so a second brew gate line cannot be silently dropped (the false-pass #104 guards
# against). The '^[[:space:]]*' anchor excludes the mid-line 'brew install pipx'
# (it sits after '||', not at line start).
BREW_SET="$(grep -E '^[[:space:]]*brew install ' "$INSTALL_SH" \
  | sed -E 's/^[[:space:]]*brew install //; s/[[:space:]]*\|\|.*//' || true)"
# pipx gate loop: 'for pkg in <tools>; do'.
PIPX_SET="$(sed -nE 's/.*for pkg in (.*); do.*/\1/p' "$INSTALL_SH" || true)"
# doctor gate loop: the 'for t in <tools>; do' that is NOT the required-tools loop
# ('for t in claude git python3'). Exclude that loop by its 'for t in claude' prefix
# — more precise than a bare 'claude' substring, which could over-match a gate line
# that merely mentions claude. If the gate loop vanishes, the set is empty and the
# non-empty guard below fires.
DOCTOR_SET="$(grep -E 'for t in ' "$DOCTOR_SH" | grep -v 'for t in claude' \
  | sed -E 's/.*for t in (.*); do.*/\1/' || true)"

INSTALL_SET="$(printf '%s %s' "$BREW_SET" "$PIPX_SET" | norm | tr '\n' ' ')"
DOCTOR_SET="$(printf '%s' "$DOCTOR_SET" | norm | tr '\n' ' ')"
CANON_SORTED="$(printf '%s' "$CANONICAL" | norm)"

# --- (a) Non-empty guards: a parse break must fail loudly, not silently pass ---
if [ -n "$(printf '%s' "$BREW_SET" | tr -d '[:space:]')" ]; then
  pass "parsed brew gate set from install.sh ($(printf '%s' "$BREW_SET" | norm | tr '\n' ' '))"
else
  fail "could not parse the brew gate set from install.sh (^brew install <tools> || ...)"
fi
if [ -n "$(printf '%s' "$PIPX_SET" | tr -d '[:space:]')" ]; then
  pass "parsed pipx gate set from install.sh ($(printf '%s' "$PIPX_SET" | norm | tr '\n' ' '))"
else
  fail "could not parse the pipx gate set from install.sh (for pkg in <tools>; do)"
fi
if [ -n "$(printf '%s' "$DOCTOR_SET" | tr -d '[:space:]')" ]; then
  pass "parsed gate set from doctor.sh ($DOCTOR_SET)"
else
  fail "could not parse the gate loop from doctor.sh (for t in <tools>; do, minus claude loop)"
fi

# --- compare helper: name what is missing / unexpected vs the canonical list ---
# $1 = label, $2 = actual set (space-separated, will be normalized)
compare_to_canonical() {
  local label="$1" actual
  actual="$(printf '%s' "$2" | norm)"
  local missing extra
  missing="$(comm -23 <(printf '%s\n' "$CANON_SORTED") <(printf '%s\n' "$actual") | tr '\n' ' ' | sed 's/ *$//')"
  extra="$(comm -13 <(printf '%s\n' "$CANON_SORTED") <(printf '%s\n' "$actual") | tr '\n' ' ' | sed 's/ *$//')"
  if [ -z "$missing" ] && [ -z "$extra" ]; then
    pass "$label matches the canonical installer tool set"
  else
    if [ -n "$missing" ]; then
      fail "$label is MISSING: $missing — add it to $label or remove it from CANONICAL in this test"
    fi
    if [ -n "$extra" ]; then
      fail "$label has UNEXPECTED: $extra — add it to CANONICAL in this test (and the other script) or remove it from $label"
    fi
  fi
  # Always succeed: pass/fail counters carry the result; a non-zero return here would
  # trip `set -e` and abort before the footer/remaining assertions (the "missing, no
  # extra" path otherwise short-circuits to non-zero).
  return 0
}

# --- (b) install.sh (brew ∪ pipx) == CANONICAL ---
compare_to_canonical "install.sh" "$INSTALL_SET"

# --- (c) doctor.sh gate set == CANONICAL ---
compare_to_canonical "doctor.sh" "$DOCTOR_SET"

# --- (d) Exclusions: per-project / non-gate extras must not be in the canonical set ---
excluded_hit=""
for x in $EXCLUDED; do
  if printf '%s\n' "$CANON_SORTED" | grep -qx "$x"; then
    excluded_hit="${excluded_hit:+$excluded_hit }$x"
  fi
done
if [ -z "$excluded_hit" ]; then
  pass "canonical set excludes per-project/non-gate tools ($EXCLUDED)"
else
  fail "canonical set wrongly includes excluded tool(s): $excluded_hit (pytest/coverage are per-project; radon/pylint are /fortify extras)"
fi

echo ""
echo "test_install_tools.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
