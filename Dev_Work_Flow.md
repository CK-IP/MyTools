# Development Workflow Guide

A step-by-step workflow for professional feature development using GitHub, designed for small teams collaborating on a shared codebase with Claude Code as a development assistant.

---

## Overview

Every new idea follows this lifecycle:

```
Idea → Issue → T-shirt size → Pipeline → Review → Merge → Close
```

The `/idea` command handles the first three steps automatically, then routes to the right pipeline based on complexity.

---

## The Fast Path: `/idea`

For most work, start here:

```
/idea
```

`/idea` walks you through 8 steps:
1. Pick the project
2. Pull latest code
3. Describe your idea
4. Load project knowledge
5. Create a GitHub issue
6. T-shirt size it (S/M/L/XL)
7. Build it (routes to the right pipeline automatically)
8. Wrap up

You just describe what you want — `/idea` handles the rest.

### How t-shirt sizing works

| Size | What it means | Pipeline | How it works |
|------|---------------|----------|--------------|
| **S** (Small) | 1-3 files, bugfix/follow-up/doc edit | `/skiff` | Plan → build → review → commit direct to main |
| **M** (Medium) | Single concern, <5 files, existing patterns | `/sloop` | Plan (1 review round) → build → review → commit on branch → merge |
| **L** (Large) | Multi-file, new patterns, unknowns | `/ship` | Full ceremony: orientation → plan (5 review rounds) → per-step gates → full review → simplify → commit |
| **XL** (Extra Large) | Independent workstreams, parallel team build | `/fleet` | Spawns worker agents + rolling QA, coordinates via contracts |

---

## Running pipelines directly

If you already have a GitHub issue and know the size, you can skip `/idea` and call the pipeline directly:

```
/skiff 42        # Small fix — direct to main
/sloop 42        # Standard build — branch + merge
/ship 42         # Full feature — all gates
/fleet 42        # Epic — parallel team build
```

---

## The manual path

For work that doesn't fit a pipeline (exploratory research, one-off scripts, configuration changes), you can still work step by step:

### Phase 1: Define the Work

```
/board create "Short title of your idea"
```

Creates a GitHub issue with acceptance criteria and adds it to the project board.

### Phase 2: Create Your Workspace

```
Create a feature branch for issue #X
```

Checks out `main`, pulls latest, and creates a new branch.

#### Branch Naming

| Style | Example | Best for |
|-------|---------|----------|
| `ship/<issue#>` | `ship/42` | Pipeline work (created automatically) |
| `feature/<description>` | `feature/chart-zoom` | Manual feature branches |
| `fix/<description>` | `fix/data-import` | Manual bugfix branches |

### Phase 3: Plan Before Coding

```
Enter plan mode. I want to implement <describe the feature>. Here's the issue: #X
```

In plan mode, Claude reads relevant code, loads domain context, and produces a step-by-step implementation plan.

### Phase 4: Implement

```
/implement <description of this step>
```

Each `/implement` cycle: writes a failing test → writes code to pass it → runs the full suite → red-team review.

### Phase 5: Commit

```
Commit these changes
```

**When to commit:**
- After each `/implement` step passes tests
- Before switching context (lunch, meeting, different task)
- Before any risky refactor

### Phase 6: Push to Remote

```
Push my changes
```

Push at least at the end of every work session. Pushing incomplete work to a feature branch is fine — that's what branches are for.

### Phase 7: Open the PR

```
Create a PR for issue #X
```

### Phase 8: After Merge

```
Post acceptance review on issue #X and move it to done on the board
```

---

## Quick Reference

```
/idea                            # Best starting point for most work
/skiff 42                        # Small fix (S)
/sloop 42                        # Standard build (M)
/ship 42                         # Full feature (L)
/fleet 42                        # Epic team build (XL)
/board create "My idea"          # Create an issue manually
/implement <step>                # TDD cycle (used within pipelines)
/fortify                         # Security + coverage scan
/memory-audit                    # Check memory for staleness
```

---

## Tips

- **Start with `/idea`.** It picks the right pipeline for you.
- **Don't fear small PRs.** Three small PRs are better than one large one.
- **Commit before you experiment.** If the experiment fails, you can revert cleanly.
- **Push before you stop.** Your laptop is not a backup strategy.
- **One branch per issue.** Mixing concerns in a branch leads to painful reviews and partial reverts.
