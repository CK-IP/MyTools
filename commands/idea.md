Walk the user through turning an idea into working code. The user is NOT a programmer — use plain, simple language throughout. No jargon. Explain everything like you're talking to a smart coworker who doesn't code.

## HARD GATES — MANDATORY COMPLIANCE

Every step below is a **mandatory gate**. You MUST execute each step in order. DO NOT SKIP, bypass, or rationalize away any step — no matter how simple the task seems.

- The **t-shirt sizing** (Step 6/8) ALWAYS runs after creating the issue. You must evaluate whether the task is a Small, Medium, Large, or XL, and you must ask the user. There are no exceptions.
- The **build step** (Step 7/8) MUST invoke `/sail`, `/skiff`, `/sloop`, `/ship`, or `/fleet`. You must NEVER start coding directly — no exceptions.
- You MUST announce every step number and name before doing any work in that step.

## Step announcements

At the start of EVERY step, announce the step number and name in bold so the user can track progress:

- **"Step 1/8 — Pick the project"**
- **"Step 2/8 — Get up to date"**
- **"Step 3/8 — Hear your idea"**
- **"Step 4/8 — Learn the project"**
- **"Step 5/8 — Create the task"**
- **"Step 6/8 — T-shirt size it"**
- **"Step 7/8 — Build it"**
- **"Step 8/8 — Wrap up"**

Always use this format. Never skip the announcement.

## Step 1/8: Pick the project

> ⛔ HARD GATE — DO NOT SKIP. You must identify and confirm the project.

Look at the projects in /Users/chriskuo/projects/. Ask: **"Which project is this for?"** and list the available projects. If it's obvious from context, confirm instead of asking.

Change your working directory to that project.

## Step 2/8: Get up to date

> ⛔ HARD GATE — DO NOT SKIP. You must check out main and pull latest.

Check if the current branch is `main` and whether it's up to date with the remote. Tell the user:

**"Before we start — let me make sure you're working with the latest version of the project."**

Run `git checkout main && git pull` in the project directory. If there are updates, say: **"Got the latest updates."** If already up to date, say: **"You're up to date — good to go."**

If there are uncommitted changes that block the checkout, warn: **"You have some unsaved work in progress. Want me to save it aside so we can update? (This is called 'stashing' — it's like putting papers in a drawer to deal with later.)"**

## Step 3/8: Hear your idea

> ⛔ HARD GATE — DO NOT SKIP. You must ask for and listen to the user's idea.

Ask: **"What's your idea? Just describe what you want to happen — no technical details needed."**

Listen to their response. Ask 1-2 clarifying questions if needed (no more). Keep it conversational.

## Step 4/8: Learn the project

> ⛔ HARD GATE — DO NOT SKIP. You must check for domain knowledge.

Check if `.ship/domain.md` exists in the project. If not, tell the user:

**"This project doesn't have a knowledge file yet. I'm going to scan the project to learn how it works — this helps me build better code. This takes a minute."**

Then invoke `/train` in discovery mode to bootstrap domain knowledge.

If it already exists, say: **"Project knowledge is loaded — good to go."**

Next, check if `.code-review-graph/` exists in the project root.

If it does NOT exist, tell the user:

**"This project doesn't have a code map yet. A code map is like an index for all the code — it helps me find things faster and give better answers. Want me to build one? It takes about a minute."**

If the user says yes, run: `uvx code-review-graph build`

Then say: **"Code map built! This will update automatically as we make changes."**

If the user says no, say: **"No problem — I can always build it later."**

If it already exists, say: **"Code map is up to date."**

Finally, check if embeddings are available by running `semantic_search_nodes_tool` with a simple test query (e.g., the project name). If the result shows `"search_mode": "keyword"` instead of `"hybrid"`, embeddings are missing.

If embeddings are NOT available, tell the user:

**"The code map is built, but it's missing the 'smart search' feature. Smart search lets me find code by meaning instead of just exact names — it's much better at understanding what you're asking for. Want me to set it up? It takes about a minute."**

If the user says yes, run `embed_graph_tool` with the project's `repo_root`. Then say: **"Smart search is ready! I can now find code by what it does, not just what it's called."**

If the user says no, say: **"No problem — keyword search still works fine. You can always add it later."**

If embeddings ARE available (search_mode is "hybrid"), say nothing extra — move on.

## Step 5/8: Create the task

> ⛔ HARD GATE — DO NOT SKIP. You must create a GitHub issue via /board.

Using what the user described, create a clear GitHub issue using `/board create`. Write it in plain language. Include:
- A clear title
- What it should do (acceptance criteria), written as simple bullet points
- Which part of the project it touches

Show the user the issue before creating it. Ask: **"Does this capture your idea? Anything to add or change?"**

## Step 6/8: T-shirt size it

> ⛔ HARD GATE — DO NOT SKIP. ALWAYS run this step. You must t-shirt size the task and ask the user to confirm.

This step determines how the work should be built. It replaces the former Epic check with a full complexity triage — think of it like picking a t-shirt size for the work. After creating the GitHub issue in Step 5:

### 1. Classify the size

Look at the issue you just created and ask three questions:
- **How many files does it touch?** (1-3 = S, 3-5 = M, 5+ = L)
- **How many steps to build it?** (1-3 = S, 3-5 = M, 5+ = L)
- **What kind of work is it?** (bugfix/follow-up/doc edit = S; single concern with existing patterns = M; new feature with unknowns or new patterns = L; independent workstreams = XL)

| Size | What it means | Pipeline |
|---|---|---|
| **S** (Small) | 1-3 files, bugfix/follow-up/doc edit, straightforward | `/sail` (default; alternative: `/skiff`) |
| **M** (Medium) | Single concern, <5 files, existing patterns, <200 LOC | `/sail` (default; alternative: `/sloop`) |
| **L** (Large) | Multi-file, new patterns, unknowns, security-touching | `/sail --dual-lens --red-team` (default; alternative: `/ship`) |
| **XL** (Extra Large) | Independent workstreams, parallel team build (Epic Mode) | `/fleet` |

The default path is `/sail` for S, M, and L work. If the user explicitly wants the named alternative instead, use `/skiff`, `/sloop`, or `/ship`.

### 2. Present your analysis

**If it's a Small:**

> "I'd call this a **Small** — [describe what and why]. It touches [N] files and needs about [N] steps. I'll use the fast track — plan, build, one review, and it goes straight onto the main branch."

**If it's a Medium:**

> "I'd call this a **Medium** — [describe scope]. It touches a few files and uses existing patterns. I'll use the standard process — plan with a review, build, another review, and commit on a branch."

**If it's a Large:**

> "I'd call this a **Large** — [describe scope]. It touches multiple files and has some unknowns. I'll use the full process with step-by-step reviews and multiple safety checks."

**If it's an XL** (Epic Mode):

> "This is an **XL** — it has [X], [Y], and [Z] — [N] independent pieces that could be built in parallel by a team. That's a good fit for a team session."

### 3. Ask the user

For S/M/L decisions:

> "I'm calling this a [Small / Medium / Large]. Sound right, or should I size it differently?"

For XL:

- "Build as a team project or keep it simpler?"
- "Continue here or start a fresh session?"
  *(Recommend a fresh session for Epics — easier to coordinate in tmux)*

### 4. If team + fresh session

- Generate an epic-brief.md draft using the schema in `commands/epic-brief-schema.md`
- Save to `.handoffs/epic-brief-<issue>-<timestamp>.md`
- Write a complete self-contained session prompt the user can copy-paste. The prompt must include:
  - The epic-brief path
  - The issue number
  - A plain-language summary of what to build
  - The instruction: run `/fleet <issue>`

### 5. If team + continue here

- Generate epic-brief.md draft, save to `.handoffs/`
- Call `/fleet <issue>` directly

### 6. If full feature

Proceed to Step 7/8 — invoke `/sail --dual-lens --red-team <issue>`.
Fallback pipeline if the user wants the named alternative: `/ship <issue>`.

### 7. If standard build

Proceed to Step 7/8 — invoke `/sail <issue>`.
Fallback pipeline if the user wants the named alternative: `/sloop <issue>`.

### 8. If small fix

Proceed to Step 7/8 — invoke `/sail <issue>`.
Fallback pipeline if the user wants the named alternative: `/skiff <issue>`.

## Step 7/8: Build it

> ⛔ HARD GATE — DO NOT SKIP. You must invoke /sail, /skiff, /sloop, /ship, or /fleet. NEVER code directly.

### If /sail (default build)

Tell the user:

**"Great — I'm using the default build pipeline. Here's how it works:**
- **I'll make a plan first and show it to you for approval**
- **Then I'll write tests and code in small steps**
- **The automatic checks run as we go**
- **A reviewer checks for serious problems and can stop the run if needed**
- **I'll keep looping through fixes and checks until the change is clean**

**You just need to say 'looks good' or tell me what to change. Ready?"**

Then invoke `/sail` with the flags and issue number from the sub-branch you followed in Step 6/8 — bare `/sail <issue>` for S and M, `/sail --dual-lens --red-team <issue>` for L. Do not drop the L-tier flags.

#### At checkpoints during /sail

- Instead of "plan mode" -> **"I've mapped out the change. Take a look and tell me if it covers what you want."**
- Instead of "automated gates" -> **"The automatic checks are running now to catch any breakage."**
- Instead of "blocking LLM review" -> **"A reviewer is checking the work and can stop us if it finds a serious problem."**
- Instead of "convergence loop" -> **"I'm repeating the fix-and-check cycle until the reviewer sees no serious issues."**

### If /skiff (small fix)

Tell the user:

**"Great — this is a focused fix, so I'm using the fast track. Here's how it works:**
- **I'll make a short plan and show it to you for approval**
- **Then I'll write tests and code**
- **A reviewer checks the work automatically**
- **When it's done, the fix goes straight onto the main branch**

**You just need to say 'looks good' or tell me what to change. Ready?"**

Then invoke `/skiff` with the issue number.

#### At checkpoints during /skiff

- Instead of "plan mode" → **"I've written up what I'm going to change. Take a look and let me know if it covers what you want."**
- Instead of "red-team convergence" → **"The reviewer is checking the code for problems — like a second pair of eyes."**
- Instead of "CRITICAL finding" → **"The reviewer found something important that needs fixing — here's what it is: [explain]"**

### If /sloop (standard build)

Tell the user:

**"Great — I'm using the standard build process. Here's how it works:**
- **I'll make a plan, and a reviewer checks it before we start**
- **Then I'll write tests and code**
- **Another reviewer checks the finished work**
- **Everything goes on a separate branch so it can be reviewed before going live**

**You just need to say 'looks good' or tell me what to change. Ready?"**

Then invoke `/sloop` with the issue number.

#### At checkpoints during /sloop

- Instead of "plan-level red-team" → **"A reviewer is checking whether the plan is solid before we start building."**
- Instead of "red-team full-branch review" → **"The reviewer is checking all the code changes for problems."**
- Instead of "CRITICAL finding" → **"The reviewer found something important — here's what it is: [explain]"**
- Instead of "escalate to /ship" → **"The reviewer found something big enough that we should use the full process instead. Want to switch?"**

### If /ship (full feature)

Tell the user:

**"Great — now I'm going to build this step by step. Here's how it works:**
- **I'll make a plan first and show it to you for approval**
- **Then I'll write tests and code in small steps**
- **Three different reviewers check the work automatically (I'll tell you which one is working and what it does)**
- **I'll pause and check in with you at each stage**

**You just need to say 'looks good' or tell me what to change. Ready?"**

Then invoke `/ship` with the issue number.

#### At every checkpoint during /ship

When the pipeline pauses for user input, translate what happened into plain language:

- Instead of "Compass" → **"The navigator is checking whether the plan covers everything and isn't too big. Think of it like a second opinion on the plan."** Then explain what it found.
- Instead of "Compass recommends splitting" → **"The navigator thinks this idea might be too big to build all at once. I'd suggest breaking it into smaller pieces: [list pieces]. Want to do that?"**
- Instead of "Leadsman writing failing test" → **"The test writer is creating a check to make sure this feature works correctly..."**
- Instead of "Red team found HIGH severity issue" → **"The security reviewer found a problem that could cause issues — here's what it is in simple terms: [explain]"**
- Instead of "Plan compliance drift" → **"The security reviewer noticed the code started going in a different direction than we planned. Here's what changed: [explain]"**

## Step 8/8: Wrap up

> ⛔ HARD GATE — DO NOT SKIP. You must present the summary and next steps to the user.

### If /skiff was used

When `/skiff` finishes, tell the user:

**"All done! Here's what was fixed: [plain summary]. The change is already on the main branch — it's live.**

**The issue has been closed automatically. Nothing else to do on this one."**

### If /sail was used

When `/sail` finishes, tell the user:

**"Here's what happened: [plain summary].**

**If the build finished cleanly, the code has been merged to the main branch and the issue closed automatically — nothing else to do.**

**If I had to pause the build for a human to look at (a "park"), I'll have told you why and what's needed next — it is NOT merged in that case. Either way, if anything looks off, just let me know."**

### If /sloop or /ship was used

When the build finishes, tell the user:

**"All done! Here's what was built: [plain summary]. The code has been merged to the main branch.**

**The issue has been closed automatically. If anything looks off, just let me know."**

## Rules

- NEVER show raw code unless the user asks to see it
- NEVER use programming terms without explaining them
- Keep updates short — one or two sentences per checkpoint
- If something fails, explain what went wrong and what you're doing about it in plain terms
- Be encouraging — the user is creating real software even though they don't code
- ALWAYS announce the step number and name at the start of each step
- MANDATORY: Execute every step (1–8) in order. Never skip a step for any reason.
- MANDATORY: ALWAYS run the t-shirt sizing (Step 6/8) after creating the issue — evaluate for S/M/L/XL and ask the user.
- MANDATORY: ALWAYS invoke /sail <issue>, /skiff <issue>, /sloop <issue>, /ship <issue>, or /fleet <issue> to build. NEVER start coding directly — no exceptions.
- MANDATORY: Announce the step number and name at the start of each step before doing any work.
