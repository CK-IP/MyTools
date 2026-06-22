# CK-Skills — Project Rules

Custom Claude Code skills repo. Changes here are symlinked into `~/.claude/` and affect every Claude Code session.

## Structure

- `commands/` — slash commands (symlinked to `~/.claude/commands/`)
- `agents/` — subagent definitions (symlinked to `~/.claude/agents/`)
- `hooks/` — shell hooks for PreToolUse/PostToolUse/Stop events (symlinked to `~/.claude/hooks/`)
- `skills/` — multi-file skill packages (symlinked as directories to `~/.claude/skills/`)
- `home/` — global config files (`CLAUDE.md`, `settings.reference.json`) — symlinked or referenced from `~/.claude/`
- `config/` — macOS LaunchAgent plists
- `tests/` — shell test scripts (`test_*.sh`)

## Key rules

- **Symlinks are post-merge only.** Never create symlinks into this repo during a ship run — the target doesn't exist at the main-repo path until the branch merges. Document symlink steps in INSTALL.md.
- **Shell scripts use `set -euo pipefail`.** All `.sh` files include this near the top.
- **Test changes with the test scripts.** Run the relevant `tests/test_*.sh` after modifying a skill.
- **INSTALL.md is the source of truth** for setup steps. When adding a new command, agent, hook, or skill, add its symlink command to INSTALL.md Step 2.
- **settings.reference.json is a reference, not a symlink.** It shows recommended settings — users merge into their own `~/.claude/settings.json`.

## Infrastructure placement — where each kind of logic lives

Three homes. Match logic to its home; don't mix.

- **Judgment** (planning, reviewing — anything needing reasoning) → an **LLM call**. Never hard-code it; never fake it in bash.
- **Deterministic decisions** that must not drift and must be testable (gate pass/fail, exit codes, parsing model output, risk heuristics) → **tested Python** (`sail/`). Never in the markdown prompt (it drifts run-to-run) or in complex bash (it's fragile).
- **Side-effects & glue** (git, gh, file moves, sequencing) → **thin shell**, kept short.

**Rule of thumb (the tell):** if a bash block needs `set -e` foot-gun comments, or a `case`/`if` that interprets another command's exit code or parsed output, it's doing Python's job — lift the *decision* into `sail/` (with a test) and leave the shell to only *call* and *move bytes*.

## Dependencies

- **cc-dotfiles** — org-level base skills (`/ship`, `/skiff`, `/implement`, `/board`, `/train`, agents, hooks). Read-only — build improvements here in CK-Skills, not there.
- **code-review-graph** — MCP server for code maps and semantic search. Optional but recommended.
- **Codex CLI** — optional, for token-efficient substep delegation via `codex-worker` skill.
