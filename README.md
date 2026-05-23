# MyTools — Claude Code Skills

Custom Claude Code skills for structured development workflows — from quick fixes to parallel team builds.

---

## What's in here

| Skill | Command | What it does |
|-------|---------|--------------|
| Idea to issue | `/idea` | Turns an idea into a GitHub issue, t-shirt sizes it (S/M/L/XL), and routes to the right pipeline |
| Standard pipeline | `/ship-lite <issue>` | Plan (1 red-team round) → implement → red-team → commit on branch → merge. Middle ground between `/skiff` and `/ship` |
| Epic orchestrator | `/agent-team <epic-issue>` | Runs a parallel team build: spawns worker agents + rolling QA, coordinates via contracts |
| Epic brief schema | `/epic-brief-schema` | Reference template for writing `epic-brief.md` files used by `/agent-team` |
| Security & quality gate | `/fortify [issue]` | Automated security scan, coverage check, and static analysis on a branch — catches what LLM review misses |
| Memory audit | `/memory-audit` | Audits memory files for staleness, broken refs, and contradictions — cross-references against filesystem and CRG graph |
| Project setup | `/space [name]` | Sets up a new project workspace — folder structure, GitHub repo, task board, code map |

These skills extend the base workflow from `cc-dotfiles` (the org's shared tooling). They don't replace it — `/ship`, `/skiff`, `/implement`, `/board` etc. still come from there.

---

## Prerequisites

Before setting up these skills you need:

1. **Claude Code** — the CLI (`claude` command in your terminal). [Install guide](https://docs.anthropic.com/en/docs/claude-code)
2. **cc-dotfiles** — the org's base skills (`/ship`, `/board`, `/implement`, etc.). Get access from your team lead.
3. **Git** and a GitHub account with access to this repo.

---

## Setup

See **[INSTALL.md](INSTALL.md)** for full step-by-step instructions.

Quick version:
```bash
git clone git@github.com:CK-IP/MyTools.git ~/projects/CK-Skills
cd ~/projects/CK-Skills && bash install.sh   # coming soon — manual steps in INSTALL.md for now
```

---

## Workflow guide

**[Dev_Work_Flow.md](Dev_Work_Flow.md)** — step-by-step walkthrough of the full development lifecycle (issue → branch → plan → implement → PR → merge).

---

## Access

This is a private repo. Collaborators have **read-only access** — skills are maintained by the repo owner. If you find a bug or want a change, open a GitHub issue.
