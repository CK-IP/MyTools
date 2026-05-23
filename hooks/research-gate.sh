#!/bin/bash
# Research-first soft gate (PreToolUse on Edit|Write|Task)
# Always exits 0 — never blocks. Injects a research checklist into Claude's
# context immediately before the action so Claude can self-check before proceeding.

input=$(cat)  # consume stdin (tool call JSON; not used in soft-gate mode)

cat <<'CHECKLIST'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
RESEARCH-FIRST GATE — confirm before this action:
  1. Read   — Have you read the target file(s) end-to-end?
  2. Root   — Do you understand the root cause, not just the symptom?
  3. Reuse  — Have you searched for existing patterns/utilities to reuse?
  4. Small  — Is this the smallest change that solves the actual problem?
  + Agents  — If spawning a subagent, have you briefed it research-first?
  + Graph  — Did you check the code graph (get_minimal_context) before scanning?

If ANY answer is NO: stop and research first.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CHECKLIST

exit 0
