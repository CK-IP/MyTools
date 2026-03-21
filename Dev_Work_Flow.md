# Development Workflow Guide

A step-by-step workflow for professional feature development using GitHub, designed for small teams collaborating on a shared codebase with Claude Code as a development assistant.

---

## Overview

Every new idea follows this lifecycle:

```
Define → Branch → Plan → Implement → Commit → Push → PR → Merge → Close
```

Each phase has a specific purpose. Skipping phases leads to rework, lost context, or merge conflicts.

---

## Phase 1: Define the Work

**Purpose:** Create a trackable record of *what* you're building and *why*, before writing any code. This prevents duplicate work and gives you acceptance criteria to code against.

**Prompt:**
```
/board create "Short title of your idea"
```

This creates a GitHub issue with acceptance criteria and adds it to the project board. Discuss the idea in issue comments with colleagues before starting.

**Guidelines:**
- Small idea (< 1 hour): single issue
- Large idea (multi-day): create an epic issue, then break into smaller child issues — one per PR

---

## Phase 2: Create Your Workspace

**Purpose:** Feature branches isolate your work from `main` so colleagues aren't affected by incomplete changes, and you aren't affected by theirs.

**Prompt:**
```
Create a feature branch for issue #X
```

This checks out `main`, pulls latest, and creates a new branch.

### Branch Naming Options

| Style | Example | Best for |
|-------|---------|----------|
| `ship/<issue#>` | `ship/42` | Fast, ties directly to issue |
| `feature/<description>` | `feature/chart-zoom` | Readable at a glance |
| `<name>/<issue#>-<desc>` | `chris/42-chart-zoom` | Teams where multiple people branch often |

Pick one convention and use it consistently.

---

## Phase 3: Plan Before Coding

**Purpose:** Planning surfaces problems before you've invested hours coding the wrong approach. For non-trivial changes, always plan first.

**Prompt:**
```
Enter plan mode. I want to implement <describe the feature>. Here's the issue: #X
```

In plan mode, Claude reads relevant code, loads domain context, and produces a step-by-step implementation plan. Review and adjust before any code is written. Each step becomes an `/implement` call.

**When to skip:** Trivial changes (one-line fixes, typo corrections, config-only edits) don't need a formal plan.

---

## Phase 4: Implement

**Purpose:** `/implement` follows TDD — write a failing test, write code to pass it, run the full suite, then red-team review. This catches bugs before they reach colleagues.

**Prompt (repeat for each step from the plan):**
```
/implement <description of this step>
```

Each `/implement` cycle:
1. Writes a failing test
2. Writes the code to make it pass
3. Runs the full test suite
4. Performs a red-team review

---

## Phase 5: Commit (Save Your Progress)

**Purpose:** Commits are save points. Frequent commits mean you can always get back to a working state if something goes wrong.

**Prompt:**
```
Commit these changes
```

Claude runs the test suite, reviews the diff, and creates a commit with a clear message.

### When to Commit
- After each `/implement` step passes tests
- Before switching context (lunch, meeting, different task)
- Before any risky refactor

### Commit Frequency Options

| Style | When | Trade-off |
|-------|------|-----------|
| **Atomic** | One commit per logical change | Clean history, easy to revert, slightly more overhead |
| **Checkpoint** | Whenever tests pass | Faster flow, squash when merging |
| **Batched** | Once per session | Risky — lose work if something breaks |

**Recommendation:** Atomic commits during development, squash-merge your PRs. You get safe save points and a tidy `main` history.

---

## Phase 6: Push to Remote (Backup)

**Purpose:** Local commits only exist on your machine. Pushing backs up your work and lets colleagues see progress.

**Prompt:**
```
Push my changes
```

### When to Push
- End of every work session (minimum)
- Before any meeting where someone might look at your branch
- After completing a logical chunk of work

Pushing incomplete work to a feature branch is perfectly professional — that's what branches are for.

---

## Phase 7: Open the PR

**Purpose:** Pull requests are where colleagues review, discuss, and approve changes before they reach `main`.

**Prompt:**
```
Create a PR for issue #X
```

Claude summarizes all commits on the branch, writes a description with a test plan, and links the issue.

### PR Size Options

| Style | Scope | Trade-off |
|-------|-------|-----------|
| **Small & focused** | One concern per PR | Easy to review, fast to merge |
| **Feature bundle** | All changes for one issue | Full context in one place, harder to review |

**Recommendation:** Small and focused. A PR that takes 10 minutes to review gets merged today. A PR that takes an hour gets merged "later."

---

## Phase 8: After Merge

**Purpose:** Close the loop — verify the work meets acceptance criteria and update the project board.

**Prompt:**
```
Post acceptance review on issue #X and move it to done on the board
```

This posts a PASS/FAIL review comment with test evidence on the issue, then updates the project board status.

---

## Quick Reference

```
/board create "My idea"              # 1. Track the work
Create a branch for issue #X         # 2. Isolate your workspace
Enter plan mode for #X               # 3. Plan the approach
/implement <step>                    # 4. Code with TDD (repeat)
Commit these changes                 # 5. Save progress (repeat)
Push my changes                      # 6. Backup to remote
Create a PR for issue #X             # 7. Request review
Post acceptance review on #X         # 8. Close the loop
/board move #X done                  # 9. Update the board
```

---

## Tips

- **Don't fear small PRs.** Three small PRs are better than one large one.
- **Commit before you experiment.** If the experiment fails, you can revert cleanly.
- **Push before you stop.** Your laptop is not a backup strategy.
- **Plan non-trivial work.** Five minutes of planning saves an hour of rework.
- **One branch per issue.** Mixing concerns in a branch leads to painful reviews and partial reverts.
