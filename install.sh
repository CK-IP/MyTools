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
printf '\n[1/4] Linking commands, agents, hooks, skills into %s ...\n' "$CLAUDE_DIR"
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
  printf '\n[2/4] Installing review-gate tools ...\n'
  if command -v brew >/dev/null 2>&1; then
    brew install gitleaks shellcheck semgrep || echo "  WARN: some brew packages failed — install manually (INSTALL.md Step 3)."
    command -v pipx >/dev/null 2>&1 || brew install pipx || true
  else
    echo "  WARN: Homebrew not found — install gitleaks/shellcheck/semgrep manually (INSTALL.md Step 3)."
  fi
  if command -v pipx >/dev/null 2>&1; then
    for pkg in ruff mypy pip-audit bandit diff-cover; do
      pipx install "$pkg" >/dev/null 2>&1 || pipx upgrade "$pkg" >/dev/null 2>&1 || echo "  WARN: pipx could not install $pkg"
    done
    echo "  installed Python CLI tools via pipx (ruff, mypy, pip-audit, bandit, diff-cover)"
    # Always ensure pipx's bin dir is on PATH (idempotent) — not only on fresh brew-install.
    # Without this, the non-login shell /sail and /fortify run in may not see these tools.
    pipx ensurepath >/dev/null 2>&1 || true
    echo "  (you may need to open a new shell or 'source' your rc for these tools to appear on PATH)"
  else
    echo "  WARN: pipx unavailable — install ruff/mypy/pip-audit/bandit/diff-cover manually."
  fi
  echo "  (pytest + coverage are best installed per-project: pip install pytest coverage)"
else
  printf '\n[2/4] Skipping tool install (--no-tools).\n'
fi

# --- 3. Verify -------------------------------------------------------------------
printf '\n[3/4] Verifying setup ...\n'
bash "$REPO_ROOT/doctor.sh" || true

# --- 4. Background automation (optional, macOS only) -----------------------------
# Interactive opt-in for the LaunchAgents in config/. Default N for each. Skipped
# entirely on non-macOS and when stdin is not a TTY (piped/CI) so the installer
# stays non-interactive-safe. CK_BG_FORCE=1 forces the prompts under piped stdin
# and LAUNCHAGENTS_DIR overrides the target dir — both are test-only seams.
LA_DIR="${LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
uvx_path="$(command -v uvx || echo uvx)"

install_launchagent() {
  # $1 plist filename, $2 placeholder token, $3 replacement, $4 label.
  # Substitution assumes a sed-safe replacement (macOS repo/uvx paths have no
  # '&' or '\'); idempotent via bootout-then-bootstrap.
  local plist="$1" placeholder="$2" replacement="$3" label="$4"
  local src="$REPO_ROOT/config/$plist" dst="$LA_DIR/$plist"
  mkdir -p "$LA_DIR"
  sed "s|${placeholder}|${replacement}|g" "$src" > "$dst"
  launchctl bootout "gui/$(id -u)/${label}" >/dev/null 2>&1 || true
  if launchctl bootstrap "gui/$(id -u)" "$dst" >/dev/null 2>&1; then
    echo "  installed $label -> $dst"
  else
    echo "  WARN: launchctl bootstrap failed for $label — load manually (INSTALL.md Step 7)."
  fi
}

printf '\n[4/4] Background automation (optional, macOS only) ...\n'
if [ "$(uname -s)" != "Darwin" ]; then
  echo "  skipped — LaunchAgents are macOS-only."
elif [ ! -t 0 ] && [ -z "${CK_BG_FORCE:-}" ]; then
  echo "  skipped — non-interactive shell; see INSTALL.md Step 7 for manual setup."
else
  echo "  These run on their own in the background. Default is No — answer y to opt in."
  # label | plist | placeholder | replacement | description
  LA_ROWS=(
    "com.crg.daemon|com.crg.daemon.plist|__UVX_PATH__|${uvx_path}|CRG daemon — keeps the code-map index fresh in the background so code search stays fast and accurate; runs continuously. Recommended if you use the code map."
    "com.crg.refresh-reminder|com.crg.refresh-reminder.plist|__REPO_ROOT__|${REPO_ROOT}|Memory refresh reminder — a monthly macOS notification reminding you to run /refresh (memory upkeep). Harmless; just a reminder on the 1st."
    "com.surf.resume|com.surf.resume.plist|__REPO_ROOT__|${REPO_ROOT}|/surf auto-resume — auto-restarts an interrupted /surf board run after a usage limit resets; wakes briefly every ~30 min. Only useful for long unattended /surf runs."
  )
  for row in "${LA_ROWS[@]}"; do
    IFS='|' read -r la_label la_plist la_placeholder la_replacement la_desc <<<"$row"
    printf '\n  %s\n' "$la_desc"
    printf '  Install %s? [y/N] ' "$la_label"
    read -r ans || ans=""
    case "$ans" in
      [yY]*) install_launchagent "$la_plist" "$la_placeholder" "$la_replacement" "$la_label" ;;
      *)     echo "  skipped $la_label" ;;
    esac
  done
fi

cat <<'NOTE'

Done. Still manual (by design — install.sh does not edit settings.json):
  - Register the CK-Skills hooks in ~/.claude/settings.json (see home/settings.reference.json).
  - Optional extras: agent-teams setting, code-map smart search (.mcp.json).
Background automation (LaunchAgents) is offered interactively above on macOS; INSTALL.md Step 7
documents manual setup + removal.
See INSTALL.md for those steps.
NOTE
