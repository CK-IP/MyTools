# MyTools — Setup Guide

Step-by-step instructions for setting up the skills in this repo on your machine.

---

## Prerequisites

Before starting, verify you have:

```bash
# Claude Code CLI
claude --version

# Git
git --version
```

If `claude` is not found, install Claude Code first: [docs.anthropic.com/en/docs/claude-code](https://docs.anthropic.com/en/docs/claude-code)

You also need **cc-dotfiles** (the org's base skills) already installed. These skills depend on `/ship`, `/board`, and other commands from that repo. Ask your team lead for access if you don't have it.

---

## Step 1: Clone the repo

```bash
git clone git@github.com:CK-IP/MyTools.git ~/projects/CK-Skills
cd ~/projects/CK-Skills
```

> You can clone to a different path — just replace `~/projects/CK-Skills` throughout these instructions.

---

## Step 2: Symlink commands, agents, hooks, and skills

Run the following from inside the repo root. This creates symlinks so Claude Code picks up everything automatically.

```bash
# Ensure directories exist
mkdir -p ~/.claude/commands ~/.claude/agents ~/.claude/hooks ~/.claude/skills

# --- Commands (slash skills) ---

# /idea skill
rm -f ~/.claude/commands/idea.md
ln -s "$(pwd)/commands/idea.md" ~/.claude/commands/idea.md

# /fleet skill
rm -f ~/.claude/commands/fleet.md
ln -s "$(pwd)/commands/fleet.md" ~/.claude/commands/fleet.md

# /epic-brief-schema reference
rm -f ~/.claude/commands/epic-brief-schema.md
ln -s "$(pwd)/commands/epic-brief-schema.md" ~/.claude/commands/epic-brief-schema.md

# /fortify — automated security, coverage, and static analysis review
rm -f ~/.claude/commands/fortify.md
ln -s "$(pwd)/commands/fortify.md" ~/.claude/commands/fortify.md

# /sloop — standard-weight ship pipeline (between /skiff and /ship)
rm -f ~/.claude/commands/sloop.md
ln -s "$(pwd)/commands/sloop.md" ~/.claude/commands/sloop.md

# /refresh — check memory for staleness, broken refs, duplicates, and contradictions
rm -f ~/.claude/commands/refresh.md
ln -s "$(pwd)/commands/refresh.md" ~/.claude/commands/refresh.md

# /space — set up a new project workspace from scratch
rm -f ~/.claude/commands/space.md
ln -s "$(pwd)/commands/space.md" ~/.claude/commands/space.md

# --- Agents ---

# explore-first — read-only research investigator (no edit tools)
rm -f ~/.claude/agents/explore-first.md
ln -s "$(pwd)/agents/explore-first.md" ~/.claude/agents/explore-first.md

# --- Hooks ---

# codex-redirect — PreToolUse on Agent: routes /ship substeps to Codex CLI
rm -f ~/.claude/hooks/codex-redirect.sh
ln -s "$(pwd)/hooks/codex-redirect.sh" ~/.claude/hooks/codex-redirect.sh

# research-gate — PreToolUse on Edit|Write|Task: soft gate research checklist
rm -f ~/.claude/hooks/research-gate.sh
ln -s "$(pwd)/hooks/research-gate.sh" ~/.claude/hooks/research-gate.sh

# --- Skills ---

# codex-worker — delegates leadsman/implement/red-team substeps to Codex CLI
rm -f ~/.claude/skills/codex-worker
ln -s "$(pwd)/skills/codex-worker" ~/.claude/skills/codex-worker
```

**Verify the symlinks resolved correctly:**

```bash
# Commands
ls -la ~/.claude/commands/idea.md
ls -la ~/.claude/commands/fleet.md
ls -la ~/.claude/commands/epic-brief-schema.md
ls -la ~/.claude/commands/fortify.md
ls -la ~/.claude/commands/sloop.md
ls -la ~/.claude/commands/refresh.md
ls -la ~/.claude/commands/space.md

# Agent
ls -la ~/.claude/agents/explore-first.md

# Hooks
ls -la ~/.claude/hooks/codex-redirect.sh
ls -la ~/.claude/hooks/research-gate.sh

# Skill
ls -la ~/.claude/skills/codex-worker
```

Each line should show `-> /absolute/path/to/CK-Skills/...`. If you see `broken symlink`, re-run the `ln -s` commands above from the repo root.

> **Hooks wiring:** After symlinking the hook scripts, you also need to register them in `~/.claude/settings.json`. See `home/settings.reference.json` in this repo for the exact JSON blocks to add under `hooks.PreToolUse`. cc-dotfiles' `install.sh` does not manage these hooks — they are CK-Skills additions.

---

## Step 2b: Research-first operating rules (optional)

This repo includes a `CLAUDE.md` file with research-first operating rules — read files before editing, confirm understanding in plain language, keep changes minimal. It lives at `home/CLAUDE.md`.

**Only set this up if you do NOT already have your own `~/.claude/CLAUDE.md`.**

The file contains placeholder references (name, memory path) that need to match your profile. Run this one-touch setup to copy and personalize it:

```bash
read -rp "Your first name (used in Claude's operating rules): " MY_NAME
[ -z "$MY_NAME" ] && { echo "Name cannot be empty."; return 1 2>/dev/null || exit 1; }
cp "$(pwd)/home/CLAUDE.md" ~/.claude/CLAUDE.md
MEMORY_PATH="$HOME/.claude/projects/$(echo "$HOME/projects" | sed 's|/|-|g')/memory/MEMORY.md"
# macOS sed; on Linux, drop the '' after -i
sed -i '' \
  -e "s/Chris/$MY_NAME/g" \
  -e "s|/Users/chriskuo/.claude/projects/-Users-chriskuo-projects/memory/MEMORY.md|$MEMORY_PATH|g" \
  ~/.claude/CLAUDE.md
echo "Done — ~/.claude/CLAUDE.md personalized for $MY_NAME"
```

> **Note:** This copies the file (not symlinks), so your personalized version won't change when the repo updates. To pick up new rules after a `git pull`, re-run the commands above.

> **Linux users:** Replace `sed -i ''` with `sed -i` (no empty string argument).

If you already have your own global rules, read `home/CLAUDE.md` for ideas you might want to borrow.

---

## Step 3: Install recommended review tools (optional)

`/fortify` works with whatever tools you have installed. More tools installed = more coverage.

```bash
# Core (recommended for all projects)
brew install semgrep gitleaks

# Python projects (CLI tools — use pipx to avoid venv conflicts on modern macOS/Linux)
for pkg in pip-audit bandit radon pylint; do pipx install "$pkg"; done
# coverage is best installed in your project venv: pip install coverage

# Node projects — npm audit is built-in (no install needed)
# jest --coverage is built-in if you use jest

# Shell scripts
brew install shellcheck
```

You can skip this step and install tools later — `/fortify` gracefully skips any tool that is not installed.

---

## Step 4: Enable the agent teams feature

`/fleet` requires an experimental Claude Code feature that is off by default. Enable it by adding one line to `~/.claude/settings.json`.

**Option A — one command (recommended):**

```bash
python3 -c "
import json, os
path = os.path.expanduser('~/.claude/settings.json')
s = json.load(open(path)) if os.path.exists(path) else {}
s.setdefault('env', {})['CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS'] = '1'
json.dump(s, open(path, 'w'), indent=2)
print('Done. Settings saved to', path)
"
```

**Option B — manual edit:**

Open `~/.claude/settings.json` in any text editor. If it does not exist, create it. Add the `env` block shown below — if the file already has content, merge the `env` key in rather than replacing the whole file:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

**Verify:**

```bash
cat ~/.claude/settings.json
```

You should see `"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"` in the output.

**Restart Claude Code** after saving the settings file for the change to take effect.

---

## Step 5: Verify everything works

Open Claude Code and run:

```
/fleet
```

You should see a response that starts with "For best results, the orchestrator (this session) should be running **opus**…" — that confirms the skill loaded correctly.

---

## Step 6: Enable smart search for the code map

The code map (code-review-graph) can search by meaning — not just exact names — if `sentence-transformers` is available. This requires a `.mcp.json` file in your projects directory that tells Claude Code to load the library when starting the code map server.

**Create the file:**

```bash
cat > ~/projects/.mcp.json << 'EOF'
{
  "mcpServers": {
    "code-review-graph": {
      "type": "stdio",
      "command": "uvx",
      "args": ["--with", "sentence-transformers", "code-review-graph", "serve"]
    }
  }
}
EOF
```

> If you keep your projects in a different folder, put this `.mcp.json` in that folder instead.

**Apply the change:**

Restart Claude Code (exit and relaunch), or type `/mcp` inside Claude Code to reconnect the server.

**Verify:**

In Claude Code, ask: *"Run `list_repos_tool` and test a semantic search on one of my projects."* If the search result shows `"search_mode": "hybrid"`, smart search is working. If it shows `"keyword"`, the server didn't pick up the change — try restarting Claude Code.

---

## Step 7: Set up background automation (optional, macOS only)

This step installs two macOS LaunchAgents:

1. **CRG daemon** — auto-starts the code-review-graph daemon on login so your code maps stay up to date
2. **Memory refresh reminder** — sends a macOS notification on the 1st of each month reminding you to run `/refresh`

### Install the plist files

Run from the repo root (`cd ~/projects/CK-Skills`):

```bash
cd ~/projects/CK-Skills

# CRG daemon — replace placeholder with your local uvx path
sed "s|__UVX_PATH__|$(which uvx)|g" config/com.crg.daemon.plist \
  > ~/Library/LaunchAgents/com.crg.daemon.plist

# Memory refresh reminder — replace placeholder with your repo path
sed "s|__REPO_ROOT__|$(pwd)|g" config/com.crg.refresh-reminder.plist \
  > ~/Library/LaunchAgents/com.crg.refresh-reminder.plist
```

### Load the agents

```bash
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.crg.daemon.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.crg.refresh-reminder.plist
```

### Verify

```bash
launchctl list | grep crg
```

You should see two lines — one for `com.crg.daemon` and one for `com.crg.refresh-reminder`.

To check the daemon is running:

```bash
uvx code-review-graph daemon status
```

### Removing (if needed)

To stop and remove the agents:

```bash
launchctl bootout "gui/$(id -u)/com.crg.daemon"
launchctl bootout "gui/$(id -u)/com.crg.refresh-reminder"
```

---

## Path note

Some skill files contain a hardcoded reference to `/Users/chriskuo/projects/`. If commands fail with a path error, search for that string in the relevant skill file and update it to match your local path:

```bash
grep -r "chriskuo" ~/projects/CK-Skills/commands/
```

Update any matches to use your own username or path.

> If you ran the one-touch setup in Step 2b, `~/.claude/CLAUDE.md` is already personalized — this grep only covers commands.

---

## Keeping skills up to date

Skills are updated in this repo. To pull the latest:

```bash
cd ~/projects/CK-Skills
git pull
```

The symlinks always point to the current files — no re-linking needed after a pull.

---

## Adding new items (repo owner only)

**Commands:** `commands/my-skill.md` -> symlink to `~/.claude/commands/`
**Agents:** `agents/my-agent.md` -> symlink to `~/.claude/agents/`
**Hooks:** `hooks/my-hook.sh` -> symlink to `~/.claude/hooks/` + register in `settings.json`
**Skills:** `skills/my-skill/` -> symlink directory to `~/.claude/skills/`

1. Create the file in the appropriate directory
2. Symlink it (see Step 2 for examples)
3. Add the symlink command to Step 2 of this file
4. Commit and push
