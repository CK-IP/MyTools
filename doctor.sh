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
  for h in codex-redirect.sh research-gate.sh sail-tdd-guard.sh; do
    if grep -q "$h" "$SETTINGS"; then green "$h registered"; else yellow "$h NOT in settings.json — hook will not fire (see home/settings.reference.json)"; fi
  done
else
  yellow "no ~/.claude/settings.json — CK-Skills hooks are not registered (see home/settings.reference.json)"
fi

echo ""
echo "Gate tools (sail deterministic gates + /fortify — availability-gated, skipped if absent):"
for t in gitleaks shellcheck semgrep ruff mypy pytest bandit pip-audit; do
  if command -v "$t" >/dev/null 2>&1; then green "$t"; else yellow "$t not installed — its gate is skipped"; fi
done

echo ""
if [ "$bad" -gt 0 ]; then
  printf '\033[31mSetup INCOMPLETE: %d required item(s) missing.\033[0m See INSTALL.md (or run install.sh).\n' "$bad"
  exit 1
elif [ "$warn" -gt 0 ]; then
  printf '\033[33mCore setup OK — %d optional item(s) missing.\033[0m To install the gate tools:\n' "$warn"
  echo "  brew install gitleaks shellcheck semgrep && pipx install ruff mypy pip-audit bandit"
  echo "(Hook registration in settings.json, if flagged above, is manual — see home/settings.reference.json.)"
  exit 0
else
  printf '\033[32mAll good — CK-Skills is fully set up.\033[0m\n'
  exit 0
fi
