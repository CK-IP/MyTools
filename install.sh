#!/usr/bin/env bash
# install.sh — one-command CK-Skills setup. Symlinks the commands/agents/hooks/skills into
# ~/.claude, installs the sail/fortify gate tools, then runs doctor.sh to verify. Safe to re-run
# (idempotent). INSTALL.md is the explained version + the optional extras this script does NOT do
# (registering hooks in settings.json, agent-teams settings, code-map search, background automation).
#
# Usage:
#   bash install.sh            # symlinks + tools + verify
#   bash install.sh --no-tools # symlinks + verify only (skip brew/pipx installs)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
INSTALL_TOOLS=1
[ "${1:-}" = "--no-tools" ] && INSTALL_TOOLS=0

printf '== CK-Skills installer ==\nrepo: %s\n' "$REPO_ROOT"

# --- 1. Symlinks -----------------------------------------------------------------
printf '\n[1/3] Linking commands, agents, hooks, skills into %s ...\n' "$CLAUDE_DIR"
mkdir -p "$CLAUDE_DIR/commands" "$CLAUDE_DIR/agents" "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/skills"
link() {
  # $1 = source in this repo, $2 = link path under ~/.claude (idempotent: replace any existing)
  rm -f "$2"
  ln -s "$1" "$2"
  echo "  linked $(basename "$2")"
}
for f in "$REPO_ROOT"/commands/*.md; do link "$f" "$CLAUDE_DIR/commands/$(basename "$f")"; done
for f in "$REPO_ROOT"/agents/*.md;  do link "$f" "$CLAUDE_DIR/agents/$(basename "$f")"; done
for f in "$REPO_ROOT"/hooks/*.sh;   do link "$f" "$CLAUDE_DIR/hooks/$(basename "$f")"; done
for d in "$REPO_ROOT"/skills/*;     do link "$d" "$CLAUDE_DIR/skills/$(basename "$d")"; done

# --- 2. Gate tools ---------------------------------------------------------------
if [ "$INSTALL_TOOLS" -eq 1 ]; then
  printf '\n[2/3] Installing review-gate tools ...\n'
  if command -v brew >/dev/null 2>&1; then
    brew install gitleaks shellcheck semgrep || echo "  WARN: some brew packages failed — install manually (INSTALL.md Step 3)."
    command -v pipx >/dev/null 2>&1 || { brew install pipx && pipx ensurepath; } || true
  else
    echo "  WARN: Homebrew not found — install gitleaks/shellcheck/semgrep manually (INSTALL.md Step 3)."
  fi
  if command -v pipx >/dev/null 2>&1; then
    for pkg in ruff mypy pip-audit bandit; do
      pipx install "$pkg" >/dev/null 2>&1 || pipx upgrade "$pkg" >/dev/null 2>&1 || echo "  WARN: pipx could not install $pkg"
    done
    echo "  installed Python CLI tools via pipx (ruff, mypy, pip-audit, bandit)"
  else
    echo "  WARN: pipx unavailable — install ruff/mypy/pip-audit/bandit manually."
  fi
  echo "  (pytest + coverage are best installed per-project: pip install pytest coverage)"
else
  printf '\n[2/3] Skipping tool install (--no-tools).\n'
fi

# --- 3. Verify -------------------------------------------------------------------
printf '\n[3/3] Verifying setup ...\n'
bash "$REPO_ROOT/doctor.sh" || true

cat <<'NOTE'

Done. Still manual (by design — install.sh does not edit settings.json):
  - Register the CK-Skills hooks in ~/.claude/settings.json (see home/settings.reference.json).
  - Optional extras: agent-teams setting, code-map smart search (.mcp.json), background automation.
See INSTALL.md for those steps.
NOTE
