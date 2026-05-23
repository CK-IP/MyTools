#!/bin/bash
# Codex redirect hook (PreToolUse on Agent)
# Redirects /ship worker substeps to codex exec instead of Claude Agent.
# Exit 0 = allow, JSON with permissionDecision:deny = block and redirect.
#
# Signal file ~/.ship/codex-fallback allows graceful fallback to Agent
# when codex is unavailable (out of tokens, auth, network, etc.).
#
# TEMPORARY: Remove this hook once /ship has native codex worker integration.

input=$(cat)

# Fast exit: no active /ship run
ls "$HOME/.ship"/ship-substeps-*.json >/dev/null 2>&1 || exit 0

# Fast exit: codex binary not installed
command -v codex >/dev/null 2>&1 || exit 0

# Fast exit: jq required for JSON parsing
command -v jq >/dev/null 2>&1 || exit 0

# Check fallback signal: only honor if newer than the current /ship run
if [ -f "$HOME/.ship/codex-fallback" ]; then
  newest_substeps=$(ls -t "$HOME/.ship"/ship-substeps-*.json 2>/dev/null | head -1)
  if [ -n "$newest_substeps" ] && [ "$HOME/.ship/codex-fallback" -nt "$newest_substeps" ]; then
    exit 0  # Fallback from current run — codex failed, allow Agent through
  else
    rm -f "$HOME/.ship/codex-fallback"  # Stale signal from previous run, clean up
  fi
fi

# Extract the Agent prompt
prompt=$(echo "$input" | jq -r '.tool_input.prompt // empty' 2>/dev/null)
[ -z "$prompt" ] && exit 0

# Match codex-eligible substep keywords in the prompt
if echo "$prompt" | grep -qiE '(leadsman|write.*(failing|test)|implement.*minimum|red.?team|simplif|adversarial.?review|qa.?review)'; then
  cat <<'REDIRECT'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Codex worker redirect: this substep should use codex exec, not a Claude Agent.",
    "additionalContext": "CODEX WORKER REDIRECT: Do NOT spawn a Claude Agent for this substep. Instead, delegate it to Codex CLI via Bash using the codex-worker skill (read ~/.claude/skills/codex-worker/SKILL.md if you haven't already). Use the per-role recipe matching this substep (leadsman, implement, red-team, or simplify). Run codex exec with -m gpt-5.4-mini -c model_reasoning_effort=high per the universal invocation contract. If codex exec fails for ANY reason (binary missing, auth expired, out of tokens, network error), do these two things in order: (1) touch ~/.ship/codex-fallback (2) retry this same substep using the Agent tool as normal — the hook will allow it through."
  }
}
REDIRECT
  exit 0
fi

# Non-eligible Agent call — allow through
exit 0
