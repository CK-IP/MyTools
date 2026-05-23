Set up a new project workspace from scratch — or connect to an existing one. The user is NOT a programmer — use plain, simple language throughout. No jargon. Explain everything like you're talking to a smart coworker who doesn't code.

## Step announcements

At the start of EVERY step, announce the step number and name in bold so the user can track progress:

- **"Step 1/9 — Check your toolbox"**
- **"Step 2/9 — Name the project"**
- **"Step 3/9 — Connect to GitHub"**
- **"Step 4/9 — Set up the folder structure"**
- **"Step 5/9 — Add standard files"**
- **"Step 6/9 — Set up the task board"**
- **"Step 7/9 — Learn the project"**
- **"Step 8/9 — Build the code map"**
- **"Step 9/9 — Ready check"**

Always use this format. Never skip the announcement.

## Step 1/9: Check your toolbox

Before setting up a new project, make sure the shared tools (called "cc-dotfiles") are installed. These are the slash commands (`/idea`, `/ship`, `/board`, etc.), the review crew (navigator, test writer, security reviewer), and the status bar.

Check for these files:
- `~/.claude/statusline.sh` (status bar)
- `~/.claude/hooks/notify.sh` (notification sounds)
- `~/.claude/commands/ship.md` (the build pipeline)
- `~/.claude/agents/captain.md` (the pipeline orchestrator)

If ALL exist, say: **"Your toolbox is ready — all the shared tools are installed."**

If ANY are missing, say:

**"Before we set up a new project, I need to make sure your shared tools are installed. These are the commands and reviewers that help us build code safely (like `/idea`, `/ship`, and the security reviewer).**

**Your colleague set these up in a shared kit called 'cc-dotfiles'. Do you have it downloaded already, or do we need to get it?"**

- If they have it (check for `~/projects/cc-dotfiles/`): Run `bash ~/projects/cc-dotfiles/install.sh` and tell the user: **"Tools installed! You now have all the slash commands, reviewers, and status bar ready to go."**
- If they don't have it: Say: **"You'll need to download the shared tools first. Ask your colleague for access to the cc-dotfiles repo, then run these two commands:"** and show: `git clone git@github.com:Icelandic-Provisions/cc-dotfiles.git ~/projects/cc-dotfiles` and `bash ~/projects/cc-dotfiles/install.sh`. Then STOP and wait for the user to confirm it's done before continuing.

## Step 2/9: Name the project

Ask: **"What's the name of the new tool or project? And in a sentence or two, what will it do?"**

Listen to their response. Use the name they give for folder and file naming (lowercase, hyphens for spaces). Confirm:

**"Got it — I'll set up a project called '[name]'. The main folder will be called `[name]` inside your projects directory."**

## Step 3/9: Connect to GitHub

Ask: **"Is there already a GitHub repo for this, or do we need to create one?"**

### If already created:
Ask: **"What's the link?"**

Verify the repo exists using `gh repo view`. If it does, say: **"Found it — connected."**

Clone it into `~/projects/[name]` if not already there.

### If needs to be created:
Ask: **"Do you want me to create it now, or would you rather have your colleague set it up first?"**

- **If creating now:** Create a private repo under `Icelandic-Provisions` using `gh repo create Icelandic-Provisions/[name] --private --clone`. Tell the user: **"Created the repo and downloaded it to your computer."**
- **If waiting:** Say: **"No problem. Ask your colleague to create `Icelandic-Provisions/[name]` on GitHub. Once it's ready, give me the link and I'll connect everything."** Then STOP here — save progress by telling the user exactly what command to run to resume: **"When the repo is ready, start a new conversation and type `/space` — I'll pick up where we left off."**

## Step 4/9: Set up the folder structure

Use the UF repo (https://github.com/Icelandic-Provisions/uf) as the template. The structure should be:

```
[repo-name]/                  (repo root)
  .claude/
    board.json                (created in Step 6)
  .ship/
    domain.md                 (created later in Step 7)
  .gitignore
  CLAUDE.md                   (repo-level overview)
  CONTRIBUTING.md
  README.md
  [tool-name]/                (app code subfolder)
    CLAUDE.md                 (tool-level guidance)
    README.md
    Makefile
    setup.sh
    requirements.txt
    .env.example
```

Create all directories. Tell the user:

**"I'm setting up the folder structure. Think of it like organizing a filing cabinet:**
- **The top drawer has general info about the whole project (README, contributing guide)**
- **Inside is a folder named '[tool-name]' where all the actual code will live**
- **There's also a hidden `.claude` folder where I keep my notes about the project"**

## Step 5/9: Add standard files

Create the following files with sensible defaults based on what the user described:

### Root level:
- **CLAUDE.md** — repo overview with tools table (one row for the new tool), repo layout, "Adding a New Tool" section, link to CONTRIBUTING.md. Use the recipe-builder repo's root CLAUDE.md as the template.
- **README.md** — project name, tools table, getting started (points to tool folder), contributing link, contact (Gregg Rubin).
- **CONTRIBUTING.md** — branch naming (`feature/`, `fix/`, `docs/`), commit style, PR process (request review from Gregg Rubin, squash merge), code standards.
- **.gitignore** — macOS files, `.claude/*` with exceptions for `!.claude/commands/`, `!.claude/agents/`, `!.claude/domain.md`, `!.claude/board.json`, `.claude/worktrees/`, `.code-review-graph/`, `.env`, `venv/`, Python cache, `.handoffs/`.

### Tool level:
- **CLAUDE.md** — tool description, common tasks (`make setup/test/check/serve`), key modules (leave as placeholder until code exists), architecture notes.
- **README.md** — tool description, quick start, development commands, tech stack.
- **Makefile** — standard targets: `test`, `check`, `setup`, `serve`. Leave `deploy` as a placeholder.
- **setup.sh** — bootstrap script: create venv, install deps, copy .env.example, create database. Use the recipe-builder setup.sh as template.
- **requirements.txt** — start with basics: `fastapi`, `uvicorn[standard]`, `jinja2`, `pytest`, `httpx`. Ask the user if they know what libraries they'll need, but don't require an answer.
- **.env.example** — `DATABASE_URL=postgresql://localhost/[db_name]` and `LOG_LEVEL=INFO`.

Show the user a summary of what was created:

**"Here's what I set up:**
- **README** — describes the project for anyone who visits the GitHub page
- **Contributing guide** — rules for how code changes are made (branch names, reviews, etc.)
- **CLAUDE.md** — my instruction manual for working on this project
- **Makefile** — shortcut commands like `make test` and `make serve`
- **Setup script** — one command to get everything installed on a new computer
- **.gitignore** — tells GitHub which files to skip (passwords, temporary files, etc.)"

## Step 6/9: Set up the task board

Ask: **"Does this project already have a GitHub Projects board, or should I create one?"**

### If already exists:
Ask for the board number (or look it up via `gh project list --owner Icelandic-Provisions`). Write `.claude/board.json` with `{"project_number": N}`.

### If needs to be created:
Create a project board: `gh project create --owner Icelandic-Provisions --title "[project-name]"`. Get the project number from the output. Write `.claude/board.json`.

Tell the user: **"The task board is where we track what needs to be built, what's in progress, and what's done. I just connected this project to board #[N]. When you use `/idea` or `/board`, I'll automatically use this board."**

## Step 7/9: Learn the project

Check if there's existing code in the repo (beyond what we just scaffolded).

### If existing code:
Say: **"There's already some code here. Let me scan it to learn how it works."**
Invoke `/train` in discovery mode.

### If brand new (just scaffolded):
Say: **"Since this is a brand new project, I'm going to ask you a few questions to build up my knowledge of what you're building. This helps me write better code later."**

Invoke `/train` in bootstrap mode — it will interview the user about the domain.

## Step 8/9: Build the code map

Check if the project has any source code files (Python, JavaScript, etc.) beyond the scaffolding created in Steps 4-5.

### If code exists:

Tell the user:

**"I'm going to build a code map for this project. Think of it like creating an index for a book — it helps me find the right code quickly instead of reading every page. This takes about a minute."**

Run: `uvx code-review-graph build`

Then say: **"Code map built! This will update automatically as you make changes."**

### If no code yet (just scaffolding):

Say: **"Since this is a brand new project with no code yet, I'll skip building the code map for now. It'll get built automatically the first time you use `/idea` to add a feature."**

## Step 9/9: Ready check

Verify everything is connected:
1. Local folder exists at `~/projects/[name]`
2. Git remote points to GitHub
3. `.claude/board.json` exists with a valid board number
4. `.ship/domain.md` exists
5. Standard files are all present

If anything is missing, fix it. Then commit and push everything:

**"Let me save everything and push it to GitHub so it's backed up."**

Commit with message: "Initial project setup — monorepo structure with [tool-name]"
Push to main.

Then tell the user:

**"Your workspace is ready! Here's what you have:**

**Local folder:** `~/projects/[name]`
**GitHub:** `https://github.com/Icelandic-Provisions/[name]`
**Task board:** Board #[N]

**What you can do next:**
- **`/idea`** — describe a feature and I'll build it
- **`/board`** — check or manage your task board
- **`/train`** — teach me more about the project as it grows

**To start coding, just open a new conversation in this project folder and tell me what to build!"**

## Rules

- NEVER show raw code unless the user asks to see it
- NEVER use programming terms without explaining them in parentheses
- If a step fails, explain what went wrong in plain terms and offer to retry or skip
- Be encouraging — the user is setting up real infrastructure even though they don't code
- ALWAYS announce the step number and name at the start of each step
- Use the UF repo (Icelandic-Provisions/uf) and recipe-builder repo as reference templates — match their patterns
- If the user provides arguments (e.g., `/space my-new-tool`), use that as the project name and skip asking in Step 2
