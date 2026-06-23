# MyTools — Setup Guide

Step-by-step instructions for setting up the skills in this repo on your machine.

`sail/` is a local runner invoked as `python3 -m sail`; it is not symlinked.

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

## Quick install (recommended)

One command does the core setup — symlinks + gate tools + a verification check:

```bash
bash install.sh
```

Safe to re-run any time (idempotent). It does **not** edit `~/.claude/settings.json` — so after
running it, register the CK-Skills hooks (Step 2's "Hooks wiring" note) and do any optional extras
(Steps 4, 6, 7) by hand.

Check your setup any time without changing anything:

```bash
bash doctor.sh
```

`doctor.sh` reports which tools are installed, which symlinks are wired, whether the hooks are
registered in settings.json, and which gate tools are present — and exits non-zero if a required
item is missing.

The numbered steps below are the **manual, explained equivalent** of `install.sh` (Steps 2 + 3),
plus the optional extras the script leaves to you (Steps 4, 6, 7).

---

## Step 2: Symlink commands, agents, hooks, and skills

Run the following from inside the repo root. This creates symlinks so Claude Code picks up everything automatically.

> **Post-merge only:** run these symlink commands after the branch has merged to `main` — never during an in-progress ship/sloop/skiff run (the target files don't exist at the main-repo path until merge).

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

# /sail — plan, build, and review one issue end-to-end
rm -f ~/.claude/commands/sail.md
ln -s "$(pwd)/commands/sail.md" ~/.claude/commands/sail.md

# /sail git "opening bookend" library (#65) — sourced by commands/sail.md Stage 0.5.
# Depends on ~/.claude/lib/ship-resume-safety.sh (from cc-dotfiles) being installed too.
mkdir -p ~/.claude/lib
rm -f ~/.claude/lib/sail-git-lifecycle.sh
ln -s "$(pwd)/home/lib/sail-git-lifecycle.sh" ~/.claude/lib/sail-git-lifecycle.sh

# /refresh — check memory for staleness, broken refs, duplicates, and contradictions
rm -f ~/.claude/commands/refresh.md
ln -s "$(pwd)/commands/refresh.md" ~/.claude/commands/refresh.md

# /space — set up a new project workspace from scratch
rm -f ~/.claude/commands/space.md
ln -s "$(pwd)/commands/space.md" ~/.claude/commands/space.md

# /culture — RnD-Wiki knowledge base interaction (setup, add, search)
rm -f ~/.claude/commands/culture.md
ln -s "$(pwd)/commands/culture.md" ~/.claude/commands/culture.md

# /surf — autonomous board-working skill (drives /sail per issue)
rm -f ~/.claude/commands/surf.md
ln -s "$(pwd)/commands/surf.md" ~/.claude/commands/surf.md

# --- Agents ---

# explore-first — read-only research investigator (no edit tools)
rm -f ~/.claude/agents/explore-first.md
ln -s "$(pwd)/agents/explore-first.md" ~/.claude/agents/explore-first.md

# culture-worker — background wiki article publisher
rm -f ~/.claude/agents/culture-worker.md
ln -s "$(pwd)/agents/culture-worker.md" ~/.claude/agents/culture-worker.md

# --- Hooks ---

# codex-redirect — PreToolUse on Agent: routes /ship substeps to Codex CLI
rm -f ~/.claude/hooks/codex-redirect.sh
ln -s "$(pwd)/hooks/codex-redirect.sh" ~/.claude/hooks/codex-redirect.sh

# research-gate — PreToolUse on Edit|Write|Task: soft gate research checklist
rm -f ~/.claude/hooks/research-gate.sh
ln -s "$(pwd)/hooks/research-gate.sh" ~/.claude/hooks/research-gate.sh

# sail-tdd-guard — PreToolUse on Edit|Write: local TDD marker guard
rm -f ~/.claude/hooks/sail-tdd-guard.sh
ln -s "$(pwd)/hooks/sail-tdd-guard.sh" ~/.claude/hooks/sail-tdd-guard.sh

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
ls -la ~/.claude/commands/refresh.md
ls -la ~/.claude/commands/space.md
ls -la ~/.claude/commands/culture.md
ls -la ~/.claude/commands/surf.md

# Agents
ls -la ~/.claude/agents/explore-first.md
ls -la ~/.claude/agents/culture-worker.md

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

## Step 3: Install review-gate tools

Both `/fortify` AND the `/sail` deterministic gates run external review tools. Each tool is
**availability-gated** — a gate whose tool is missing is silently skipped — so the more you
install, the more coverage you get. **Install these so the gates actually run** (without them the
checks pass vacuously):

```bash
# Secrets + static analysis (powers sail's gitleaks/semgrep gates and /fortify)
brew install gitleaks semgrep

# Shell-script linting (powers sail's shellcheck gate — this repo is shell-heavy)
brew install shellcheck

# Python sail-gate CLI tools (use pipx to avoid venv conflicts on modern macOS/Linux)
for pkg in ruff mypy pip-audit bandit diff-cover; do pipx install "$pkg"; done
# coverage/pytest are best installed in your project venv: pip install coverage pytest
# /fortify analysis extras (optional — NOT sail gates): pipx install radon pylint

# Node projects — npm audit is built-in with npm (no install needed); powers sail's npm-audit gate
# jest --coverage is built-in if you use jest
```

**`gitleaks` and `shellcheck` specifically** power the sail hygiene gates added in #48 (secret
scanning + shell linting). The sail runner skips them cleanly if absent, so the gates are dormant
until these are installed — install them so secret/shell regressions are actually caught.

**`diff-cover` and `npm`** power the two sail gates added in #52 (see `docs/fortify-sail-parity.md`):
- **`npm-audit`** (Node dependency vulns) — needs `npm` on PATH. No-Node repos pass cleanly via an
  empty-JSON sentinel (target-aware manifest detection), so this gate is a clean no-op where
  there's no `package.json`+`package-lock.json` at the target root.
- **`diff-coverage`** (line-level coverage of changed lines) — needs `diff-cover` (`pipx install
  diff-cover`) AND the pytest gate's `coverage.xml`. Advisory by default; set
  `diff-coverage-threshold: N` on its own line in `.ship/domain.md` to make it blocking. Absent
  `diff-cover` or `coverage.xml` → the gate emits a clean sentinel (never a false-block).

Verify:

```bash
gitleaks version && shellcheck --version | head -2
```

You can install tools later — `/fortify` and `/sail` gracefully skip any tool that is not installed.

### Recommended sail Codex setup (optional — if you have Codex)

`/sail`'s smarter lenses (grounded planning, plan-adversary, cross-family review, red-team, tidiness) shell out to a **codex CLI**. They are configured by environment variables in `~/.claude/settings.json` — *not* in the repo, so a fresh clone needs this set up locally. **All of it is optional:** with no codex backend, `/sail` degrades cleanly (grounded planning falls back to Claude then to a blind plan; dual-lens/red-team fall back to single-lens; tidiness falls back to the default review backend — Claude — and skips only if that is unavailable) — nothing errors.

**Model policy — two tiers.** Pick by task type, and treat the model names as *illustrative* (they change over time — the durable part is the tier):
- **Reasoning tier** (planning, grounding a plan against the code, adversarial/cross-family review, red-team) → your **reasoning-tier** codex model, e.g. `gpt-5.5`, with `-c model_reasoning_effort=high`.
- **Quick tier** (cleanup/tidiness, low-stakes confirmations) → your **quick-tier** codex model, e.g. `gpt-5.4-mini`.

Add this `env` block to `~/.claude/settings.json` (merge into any existing `env` — see Step 4 for the merge pattern), substituting your own model names:

```json
{
  "env": {
    "SAIL_PLAN_GROUNDED_CMD": "codex exec -m gpt-5.5 -c model_reasoning_effort=high",
    "SAIL_PLAN_CMD2":         "codex exec -m gpt-5.5 -c model_reasoning_effort=high",
    "SAIL_REVIEW_CMD2":       "codex exec -m gpt-5.5 -c model_reasoning_effort=high",
    "SAIL_REDTEAM_CMD":       "codex exec -m gpt-5.5 -c model_reasoning_effort=high",
    "SAIL_TIDINESS_CMD":        "codex exec -m gpt-5.4-mini -c model_reasoning_effort=low",
    "SAIL_TIDINESS_VERIFY_CMD": "codex exec -m gpt-5.4-mini"
  }
}
```

What each knob powers:
- `SAIL_PLAN_GROUNDED_CMD` — the **grounded plan pass** (reads the real code before planning, on plan-risky specs).
- `SAIL_PLAN_CMD2` — the **plan-adversary** (independent second pass that tries to break the plan).
- `SAIL_REVIEW_CMD2` — the **`--dual-lens`** cross-family second review (also required for `/surf` to land work — see below).
- `SAIL_REDTEAM_CMD` — the repo-exploring **red-team** review on high-stakes diffs.
- `SAIL_TIDINESS_CMD` / `SAIL_TIDINESS_VERIFY_CMD` — the code-health/cleanup lens and its cross-family confirmation.

The **primary** review lens (`SAIL_REVIEW_CMD`) is intentionally left unset so it stays on Claude — the codex lenses are the *cross-family second opinion*, and keeping the primary on a different family is the point. `settings.json` `env` is read at session start (same as the Step 4 `env` pattern below).

The two subsections that follow detail the two most consequential of these knobs.

### Cross-family dual-lens second backend (codex — required for `/surf` per-teammate review, #74)

`/surf` delegates every issue build to a teammate that runs `/sail` with `--dual-lens` and a
**second review lens** pointed at a codex CLI via `SAIL_REVIEW_CMD2` (a reasoning-tier model — e.g.
`SAIL_REVIEW_CMD2="codex exec -m gpt-5.5 -c model_reasoning_effort=high"`; see the model policy above). These are ordinary CLI-subprocess lenses — *not*
the session-bound `advisor()` tool — so the second lens is reachable inside a nested teammate where
`advisor()` is not. Install a codex CLI and ensure it is on `PATH`. Without a codex (or other
`SAIL_REVIEW_CMD2`) backend reachable from **both** the teammate and the orchestrator, `/sail`'s
review degrades to single-lens and `/surf`'s pre-merge guard cannot compensate — so it **parks
every issue rather than merging a single-lens build**. In other words, codex is effectively
**required for `/surf` to land work**; it is optional only for one-off `/sail` runs you review
yourself (which degrade cleanly to single-lens).

### Grounded plan backend (codex — risk-gated, optional)

On a **plan-risky** spec (a remediation/instruction signal co-occurring with a file/list-reconciliation signal, per `is_plan_risky`), `/sail`'s plan stage can run a **grounded plan pass**: a tool-using backend that explores the repo (`cwd=target`, Read/Grep) and grounds the plan against the real code, citing concrete file/line **evidence** for every risk it raises (unevidenced risks are dropped, never block — mirrors the `--red-team` contract). Point it at a codex CLI via `SAIL_PLAN_GROUNDED_CMD` (a reasoning-tier model — e.g. `SAIL_PLAN_GROUNDED_CMD="codex exec -m gpt-5.5 -c model_reasoning_effort=high"`; see the model policy above). Backend selection falls back **Codex → Claude → blind**: the explicit `SAIL_PLAN_GROUNDED_CMD` if runnable, else the default author backend (`claude`) run in grounded mode, else (neither available) the run degrades cleanly to today's blind plan (logged, not an error). Ordinary (non-risky) specs never trigger it — no token or latency cost. Force it on any spec with `sail plan --grounded-plan`. Its evidenced CRITICAL/HIGH risks union into the plan gate (tagged `lens: grounded`); a grounding-backend error fails closed (`status: error`, exit 1).

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

Run the setup check from the repo root:

```bash
bash doctor.sh
```

It verifies required tools, that every command/agent/hook/skill is symlinked into `~/.claude`,
that the CK-Skills hooks are registered in settings.json, and that the sail/fortify gate tools are
installed — and exits non-zero if anything required is missing. Fix anything it flags (re-run
`bash install.sh`, or follow the manual step it points to) and re-run it until it's clean.

Then confirm a skill loads inside Claude Code:

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

**`install.sh` now offers these interactively** on macOS — when you run it in a terminal it prompts `y/N` for each LaunchAgent below (default No), with a plain-language description of what each does. The commands in this step are the manual/explicit fallback (and the removal reference): use them if you skipped the prompts during install, ran the installer non-interactively (piped/CI), or want to manage the agents by hand.

The three LaunchAgents:

1. **CRG daemon** (`com.crg.daemon`) — auto-starts the code-review-graph daemon on login so your code maps stay up to date
2. **Memory refresh reminder** (`com.crg.refresh-reminder`) — sends a macOS notification on the 1st of each month reminding you to run `/refresh`
3. **`/surf` revive watcher** (`com.surf.resume`) — revives a `/surf` board run **in place** inside its persistent `tmux` session after a usage limit resets (full details in the dedicated subsection below)

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

### `/surf` revive watcher LaunchAgent (optional, macOS only)

`/surf` works the board unattended and can be cut off mid-run by the Max-subscription usage
window. As of issue #73 `/surf` delegates **every** issue to an agent-team teammate, and agent
teams cannot run in headless `claude -p` mode — so the old headless relaunch is **retired**.
Instead `/surf` runs in a long-lived **named `surf` tmux session** that stays alive across the
cap window, and this LaunchAgent fires `config/surf-resume.sh` on a 30-minute interval to
**revive that still-alive session in place** with `tmux send-keys` once the usage-cap reset time
has passed and real unfinished board work remains. The wrapper is pure bash and touches no Claude
tokens to decide — so idle ticks cost zero Claude tokens, and it never spawns a headless run.

> **Reboot trade-off:** this revives across a usage-cap window but **not** a machine reboot — a
> reboot destroys the tmux session, so automatic recovery is lost. After a reboot, recover
> manually with `tmux new -s surf` → `claude --dangerously-bypass-permissions` → `/surf resume`.

Only set this up if you run `/surf` for long unattended sessions, and start `/surf` inside the
named session: `tmux new -s surf`, then `claude --dangerously-bypass-permissions`, then `/surf`.

> **Post-merge only:** install this after the branch has merged to `main`, per the symlink rule
> at the top of this guide.

**Install:**

```bash
cd ~/projects/CK-Skills

# Replace placeholder with your repo path
sed "s|__REPO_ROOT__|$(pwd)|g" config/com.surf.resume.plist \
  > ~/Library/LaunchAgents/com.surf.resume.plist
```

**Load:**

```bash
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.surf.resume.plist
```

**Verify:**

```bash
launchctl list | grep surf
```

You should see a line for `com.surf.resume`. Activity is logged to `/tmp/surf-resume.log`.

**Removing (if needed):**

```bash
launchctl bootout "gui/$(id -u)/com.surf.resume"
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
