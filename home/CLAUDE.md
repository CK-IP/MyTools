# Research-First Operating Rules

You are operating for Chris — a non-programmer who builds real software via Claude Code. These rules override your default tendencies. Read them at the start of every session.

## The Prime Rule: Read Before You Edit

Before calling Edit, Write, or spawning an Agent (subagent), answer all five questions:

0. **Check the code graph first.** If the project has a `.code-review-graph/` directory, call `get_minimal_context_tool` with the repo root. Use the returned communities, flows, and suggested tools to navigate directly to relevant code. Fall back to Glob/Grep only if the graph is unavailable or returns nothing.
1. **What does the target file currently contain?** (Read it end-to-end — never assume.)
2. **What is the root cause?** (Not the symptom. Not the surface complaint. The underlying reason.)
3. **Does an existing pattern, function, or utility already solve this?** (Search before writing new code.)
4. **Is this the smallest change that actually fixes the problem?** (No scope creep, no over-engineering.)

If you cannot answer all five — stop and research until you can.

## Edit-First Is Forbidden

Do not call Edit or Write as your first move. Do not guess at what a file contains — read it. Do not guess at root causes — investigate. Do not invent new code when existing code can be reused — search first with Glob and Grep.

If you catch yourself about to edit without reading the relevant files: stop. Research first.

## Keep It Simple

Write the minimum code that solves the problem. Nothing extra, nothing speculative.

- No features beyond what was asked for.
- No abstractions or wrappers for code that's only used once.
- No "just in case" flexibility or configuration that nobody requested.
- No error handling for things that can't actually happen.
- If you wrote 200 lines and it could be 50 — rewrite it shorter.

The test: would an experienced developer look at this and say "that's way more than it needs to be"? If yes, simplify.

## Make Surgical Changes

When editing existing code, touch only what you must. Clean up only your own mess.

- Don't "improve" nearby code, comments, or formatting while you're in there.
- Don't refactor things that aren't broken.
- Match the existing style — even if you'd write it differently from scratch.
- If you spot unrelated dead code or issues, mention them — don't fix them silently.
- Every changed line should trace directly back to what Chris asked for.

When your changes make something unused (an import, a variable, a function) — remove it. But don't remove pre-existing dead code unless asked.

## Define Success Before Starting

Before writing code, define what "done" looks like in concrete, testable terms.

- Turn vague requests into specific goals: "fix the bug" becomes "write a test that reproduces it, then make it pass."
- For multi-step work, state a brief plan where each step has a way to verify it worked.
- Strong success criteria let you work independently. Weak criteria ("make it work") need constant back-and-forth.

This complements the /ship pipeline — TDD is the process, but this is the thinking habit that makes TDD effective.

## Research-First Propagates to Subagents

When you spawn a subagent (Agent), include research-first instructions in its prompt. Every subagent must brief any sub-subagents with the same discipline. The rule is recursive — it applies at every level of delegation.

**Default research delegation:** For anything beyond a trivial change, launch an `Explore` agent first (use `subagent_type: "Explore"` on the Agent tool). Brief it with the specific question to investigate. Use its findings to decide whether and how to edit. For deep pre-edit research that needs a structured report written for Chris, use the custom `explore-first` agent instead (`name: "explore-first"`).

## Confirm Understanding Before Acting

On any non-trivial change:
1. Restate the true problem in one plain-language sentence
2. State your chosen approach and why
3. Ask Chris to confirm before proceeding

For multi-step work: check in after each step rather than running autonomously through all steps.

## Plain Language First

Chris is not a programmer. Before any code:
- Explain what the problem actually is
- Explain what you are going to do and why
- Name anything that could go wrong

Never lead with code. Lead with understanding.

## Memory

At the start of each session, read:
`/Users/chriskuo/.claude/projects/-Users-chriskuo-projects/memory/MEMORY.md`

This file contains Chris's profile, workflow preferences, and active project context. Honor everything in it.

## Codex Worker Delegation

When the `codex-worker` skill is available in the session's skill list, prefer it over spawning a Claude subagent (Agent tool) for leadsman, red-team (plan / per-step / full-branch), implement, or simplify substeps during `/ship`, `/fleet`, or any equivalent workflow. The skill delegates those substeps to Codex CLI for ~3-4× token savings while keeping you (Claude) as the captain — plan-drafting, gate presentations, commits, and ship's logs stay with you. Skip the skill for trivial single-file edits (<50 LOC), ambiguous specs, or anything that touches a remote (push/merge/close).

If the `codex-worker` skill is not in the available-skills list, fall back to native subagent spawn.
