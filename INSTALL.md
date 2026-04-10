# MyTools — Setup Guide

Personal Claude Code skills and workflow tools for Chris Kuo.

---

## First-Time Setup

### 1. Clone the repo

```bash
git clone git@github.com:CK-IP/MyTools.git ~/projects/CK-Skills
cd ~/projects/CK-Skills
```

### 2. Set up the `/idea` skill symlink

Replace the loose `idea.md` file in `~/.claude/commands/` with a symlink pointing to this repo so the skill is version-controlled.

**Run from inside the repo root:**

```bash
# Verify the source file exists first
ls commands/idea.md

# Ensure the commands directory exists
mkdir -p ~/.claude/commands

# Remove the old loose file if present (safe even if it doesn't exist)
rm -f ~/.claude/commands/idea.md

# Create the symlink using $(pwd) so the path is always correct
ln -s "$(pwd)/commands/idea.md" ~/.claude/commands/idea.md

# Verify the symlink — confirm target path and that it resolves
ls -la ~/.claude/commands/idea.md
cat ~/.claude/commands/idea.md | head -1
```

> **Note:** The symlink target is an absolute path derived from `$(pwd)`. Run this command from the repo root (e.g. `~/projects/CK-Skills`), not from a subdirectory.

> **Recovery:** If the symlink is broken (e.g. after moving the repo), re-run the `ln -s` command above from the new repo location.

---

## Personal Path Note

`commands/idea.md` contains a hardcoded reference to `/Users/chriskuo/projects/`. If you are setting this up on a different machine or with a different username, search for that path and update it to match your local setup.

---

## Out of Scope (Follow-up Issues)

The following skill files in `~/.claude/commands/` are currently plain files (not symlinked to this repo). Migrating them is tracked as follow-up work:

- `prompt.md`
- `space.md`

All other commands (`ship.md`, `board.md`, `implement.md`, etc.) are symlinked to the org's `cc-dotfiles` repo and should not be modified here.

---

## Adding New Personal Skills

To add a new personal skill to this repo:

1. Create the file under `commands/` (e.g. `commands/my-skill.md`)
2. Symlink it: `ln -s "$(pwd)/commands/my-skill.md" ~/.claude/commands/my-skill.md`
3. Commit and push
