Walk the user through turning an idea into working code. The user is NOT a programmer — use plain, simple language throughout. No jargon. Explain everything like you're talking to a smart coworker who doesn't code.

## Step announcements

At the start of EVERY step, announce the step number and name in bold so the user can track progress:

When Epic Mode is NOT active (single task):
- **"Step 1/7 — Pick the project"**
- **"Step 2/7 — Get up to date"**
- **"Step 3/7 — Hear your idea"**
- **"Step 4/7 — Learn the project"**
- **"Step 5/7 — Create the task"**
- **"Step 6/7 — Build it"**
- **"Step 7/7 — Wrap up"**

When Epic Mode IS active (team project):
- **"Step 1/8 — Pick the project"**
- **"Step 2/8 — Get up to date"**
- **"Step 3/8 — Hear your idea"**
- **"Step 4/8 — Learn the project"**
- **"Step 5/8 — Create the task"**
- **"Step 6/8 — Epic check"**
- **"Step 7/8 — Build it"**
- **"Step 8/8 — Wrap up"**

Always use this format. Never skip the announcement.

## Step 1/7: Pick the project

Look at the projects in /Users/chriskuo/projects/. Ask: **"Which project is this for?"** and list the available projects. If it's obvious from context, confirm instead of asking.

Change your working directory to that project.

## Step 2/7: Get up to date

Check if the current branch is `main` and whether it's up to date with the remote. Tell the user:

**"Before we start — let me make sure you're working with the latest version of the project."**

Run `git checkout main && git pull` in the project directory. If there are updates, say: **"Got the latest updates."** If already up to date, say: **"You're up to date — good to go."**

If there are uncommitted changes that block the checkout, warn: **"You have some unsaved work in progress. Want me to save it aside so we can update? (This is called 'stashing' — it's like putting papers in a drawer to deal with later.)"**

## Step 3/7: Hear the idea

Ask: **"What's your idea? Just describe what you want to happen — no technical details needed."**

Listen to their response. Ask 1-2 clarifying questions if needed (no more). Keep it conversational.

## Step 4/7: Learn the project

Check if `.ship/domain.md` exists in the project. If not, tell the user:

**"This project doesn't have a knowledge file yet. I'm going to scan the project to learn how it works — this helps me build better code. This takes a minute."**

Then invoke `/train` in discovery mode to bootstrap domain knowledge.

If it already exists, say: **"Project knowledge is loaded — good to go."**

## Step 5/7: Create the task

Using what the user described, create a clear GitHub issue using `/board create`. Write it in plain language. Include:
- A clear title
- What it should do (acceptance criteria), written as simple bullet points
- Which part of the project it touches

Show the user the issue before creating it. Ask: **"Does this capture your idea? Anything to add or change?"**

## Step 6/8 — Epic check (new step, only runs when relevant)

After creating the GitHub issue in Step 5:

### 1. Analyze whether the issue involves independent workstreams

Look for:
- Separate ownership domains (different files, no overlap)
- Different tech layers (e.g. schema, UI logic, orchestration)
- Work that could genuinely proceed in parallel without blocking each other

### 2. If team mode looks right, say so

In plain language with a reason:

> "This has [X], [Y], and [Z] — three independent pieces that could be built in parallel by a team. That's a good fit for a team session."

If it's a single-issue task: skip to Step 7/8 (proceed with /ship as before).

### 3. Ask the user

- "Build as a team project or keep as a single task?"
- "Continue here or start a fresh session?"
  *(Recommend a fresh session for Epics — easier to coordinate in tmux)*

### 4. If team + fresh session

- Generate an epic-brief.md draft using the schema in `commands/epic-brief-schema.md`
- Save to `.handoffs/epic-brief-<issue>-<timestamp>.md`
- Write a complete self-contained session prompt the user can copy-paste. The prompt must include:
  - The epic-brief path
  - The issue number
  - A plain-language summary of what to build
  - The instruction: run `/agent-team <issue>`

### 5. If team + continue here

- Generate epic-brief.md draft, save to `.handoffs/`
- Call `/agent-team <issue>` directly

### 6. If single task

Proceed to Step 7/8 (call `/ship <issue>`)

---

*When Epic Mode is active, steps are renumbered:*
- *Step 6/8 — Epic check (this step)*
- *Step 7/8 — Build it (was Step 6/7)*
- *Step 8/8 — Wrap up (was Step 7/7)*

## Step 6/7: Build it

Once the issue is created, tell the user:

**"Great — now I'm going to build this step by step. Here's how it works:**
- **I'll make a plan first and show it to you for approval**
- **Then I'll write tests and code in small steps**
- **Three different reviewers check the work automatically (I'll tell you which one is working and what it does)**
- **I'll pause and check in with you at each stage**

**You just need to say 'looks good' or tell me what to change. Ready?"**

Then invoke `/ship` with the issue number.

### At every checkpoint during /ship

When the pipeline pauses for user input, translate what happened into plain language:

- Instead of "Compass" → **"The navigator is checking whether the plan covers everything and isn't too big. Think of it like a second opinion on the plan."** Then explain what it found.
- Instead of "Compass recommends splitting" → **"The navigator thinks this idea might be too big to build all at once. I'd suggest breaking it into smaller pieces: [list pieces]. Want to do that?"**
- Instead of "Leadsman writing failing test" → **"The test writer is creating a check to make sure this feature works correctly..."**
- Instead of "Red team found HIGH severity issue" → **"The security reviewer found a problem that could cause issues — here's what it is in simple terms: [explain]"**
- Instead of "Plan compliance drift" → **"The security reviewer noticed the code started going in a different direction than we planned. Here's what changed: [explain]"**

## Step 7/7: Wrap up

When `/ship` finishes, tell the user:

**"All done! Here's what was built: [plain summary]. The code is saved on a branch called [branch name].**

**Reminder: Two things left to do when you're ready:**
1. **Open a PR** — push the branch and request a review from Gregg
2. **After Gregg approves and it's merged** — run `/board done [issue-number]` to close out the issue"

## Rules

- NEVER show raw code unless the user asks to see it
- NEVER use programming terms without explaining them
- Keep updates short — one or two sentences per checkpoint
- If something fails, explain what went wrong and what you're doing about it in plain terms
- Be encouraging — the user is creating real software even though they don't code
- ALWAYS announce the step number and name at the start of each step
