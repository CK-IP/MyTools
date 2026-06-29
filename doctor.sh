#!/usr/bin/env bash
# doctor.sh — verify CK-Skills setup. Checks required tools, that the commands/agents/hooks/skills
# are symlinked into ~/.claude, that the CK-Skills hooks are registered in settings.json, and that
# the sail/fortify gate tools are installed. Read-only: changes nothing. Run it any time:
#   bash doctor.sh
# Exit 0 = required setup OK (gate tools may warn); exit 1 = a required item is missing.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
SETTINGS="${CLAUDE_DIR}/settings.json"

# Tool checks must see the same tools the user's shell does. pip --user CLI tools (ruff, mypy,
# pytest, bandit, pip-audit) install under the Python user-base bin, which a non-login shell may
# not have on PATH; Homebrew may live in /opt/homebrew or /usr/local. Augment PATH so a tool that
# IS installed is not falsely reported missing.
_userbase="$(python3 -m site --user-base 2>/dev/null || true)"
[ -n "$_userbase" ] && PATH="${_userbase}/bin:${PATH}"
PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
export PATH

bad=0
warn=0
green()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
yellow() { printf '  \033[33m⚠\033[0m %s\n' "$1"; warn=$((warn + 1)); }
red()    { printf '  \033[31m✗\033[0m %s\n' "$1"; bad=$((bad + 1)); }
info()   { printf '  \033[2m·\033[0m %s\n' "$1"; }

printf '\nCK-Skills setup check — repo: %s\n\n' "$REPO_ROOT"

echo "Required tools:"
for t in claude git python3; do
  if command -v "$t" >/dev/null 2>&1; then green "$t"; else red "$t — MISSING (required)"; fi
done

echo ""
echo "Symlinks (commands / agents / hooks / skills -> this repo):"
check_link() {
  # $1 = expected target (file in this repo), $2 = link path under ~/.claude.
  # Use -ef (same file: same device+inode) so a symlink that resolves to this file counts as
  # linked even across case-insensitive paths (CK-Skills vs ck-skills) or a differently-spelled
  # but equivalent clone path.
  local target="$1" link="$2" name
  name="$(basename "$link")"
  if [ "$link" -ef "$target" ]; then
    green "$name"
  elif [ -L "$link" ] || [ -e "$link" ]; then
    yellow "$name — exists but resolves elsewhere/broken (different clone?)"
  else
    red "$name — not linked (skill/agent/hook will not load)"
  fi
}
for f in "$REPO_ROOT"/commands/*.md; do check_link "$f" "$CLAUDE_DIR/commands/$(basename "$f")"; done
for f in "$REPO_ROOT"/agents/*.md;  do check_link "$f" "$CLAUDE_DIR/agents/$(basename "$f")"; done
for f in "$REPO_ROOT"/hooks/*.sh;   do check_link "$f" "$CLAUDE_DIR/hooks/$(basename "$f")"; done
for d in "$REPO_ROOT"/skills/*;     do check_link "$d" "$CLAUDE_DIR/skills/$(basename "$d")"; done

echo ""
echo "Hooks registered in settings.json:"
if [ -f "$SETTINGS" ]; then
  for h in research-gate.sh sail-tdd-guard.sh; do
    if grep -q "$h" "$SETTINGS"; then green "$h registered"; else yellow "$h NOT in settings.json — hook will not fire (see home/settings.reference.json)"; fi
  done
else
  yellow "no ~/.claude/settings.json — CK-Skills hooks are not registered (see home/settings.reference.json)"
fi

echo ""
echo "Gate tools (sail deterministic gates + /fortify — availability-gated, skipped if absent):"
# Canonical globally-installable gate set (brew + pipx). pytest/coverage are per-project, npm is
# environmental — both intentionally excluded from this count so it never under-reports.
gate_total=0
gate_have=0
gate_skipped=""
for t in gitleaks shellcheck semgrep ruff mypy pip-audit bandit diff-cover; do
  gate_total=$((gate_total + 1))
  if command -v "$t" >/dev/null 2>&1; then
    gate_have=$((gate_have + 1))
  else
    gate_skipped="${gate_skipped:+$gate_skipped }$t"
  fi
done
info "Gate coverage: $gate_have of $gate_total optional checks active."
if [ -n "$gate_skipped" ]; then
  info "Skipped (not installed): $gate_skipped"
  info "→ Run ./install.sh to enable the rest (see INSTALL.md)."
  warn=$((warn + 1))
fi
info "pytest + coverage are per-project (install in each project venv: pip install pytest coverage)."

echo ""
echo "Bandit SARIF formatter (the sail bandit gate runs 'bandit -f sarif'):"
# A bare `command -v bandit` (gate loop above) passes even when the SARIF formatter is broken —
# then every `sail run` parks on the bandit gate (rc=2, artifact-unreadable). So exercise the
# formatter for real: a clean temp file scans to rc 0; a missing 'sarif' formatter makes argparse
# reject `-f sarif` (rc 2). Single `if command -v bandit` guard — deliberately NOT a `for t in`
# loop (the #104 sync guard parses doctor.sh's `for t in` lines; a new one would corrupt it).
if command -v bandit >/dev/null 2>&1; then
  _b_src="$(mktemp -t ck-bandit-sarif.XXXXXX 2>/dev/null || mktemp)"
  _b_out="$(mktemp -t ck-bandit-out.XXXXXX 2>/dev/null || mktemp)"
  if bandit -f sarif -q -o "$_b_out" "$_b_src" >/dev/null 2>&1; then
    green "bandit -f sarif works (formatter available)"
  else
    red "bandit present but 'bandit -f sarif' fails — the sail bandit gate will error (rc=2). Upgrade bandit (built-in SARIF in current versions) or 'pipx inject bandit bandit-sarif-formatter'."
  fi
  rm -f "$_b_src" "$_b_out"
else
  info "bandit not installed — SARIF capability check skipped (gate is availability-gated)."
fi

echo ""
echo "Background agents + /surf readiness (informational — never blocks):"
if [ "$(uname -s)" = "Darwin" ]; then
  for la in com.crg.daemon com.crg.refresh-reminder com.surf.resume; do
    if launchctl list 2>/dev/null | grep -q "$la"; then
      green "$la loaded"
    else
      info "$la not loaded — optional (run install.sh or INSTALL.md Step 7)"
    fi
  done
else
  info "LaunchAgents are macOS-only — skipped"
fi
if ( cd "$REPO_ROOT" && python3 -m sail run --help ) >/dev/null 2>&1; then
  green "/surf engine (python3 -m sail run) works"
else
  yellow "/surf engine (python3 -m sail run) not runnable — /surf will not work"
fi
if [ -f "$SETTINGS" ] && grep -q "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" "$SETTINGS"; then
  green "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS set (/surf heavy-issue teammates)"
else
  yellow "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS not in settings.json — /surf supervised teammates disabled"
fi
info "autonomous /surf needs 'claude --dangerously-skip-permissions' (a launch flag — can't be auto-detected)"

echo ""
if [ "$bad" -gt 0 ]; then
  printf '\033[31mSetup INCOMPLETE: %d required item(s) missing.\033[0m See INSTALL.md (or run install.sh).\n' "$bad"
  exit 1
elif [ "$warn" -gt 0 ]; then
  printf '\033[33mCore setup OK — %d optional item(s) missing.\033[0m To install the gate tools:\n' "$warn"
  echo "  ./install.sh   (or see INSTALL.md Step 3 for the per-channel tool list)"
  echo "(Hook registration in settings.json, if flagged above, is manual — see home/settings.reference.json.)"
  exit 0
else
  printf '\033[32mAll good — CK-Skills is fully set up.\033[0m\n'
  exit 0
fi
