#!/bin/bash
# Ship-lite Stop hook — enforces /ship-lite Stage 2→3 auto-transition.
# Blocks the model from stopping (exit 2) when /implement has returned
# but the @red-team dispatch has not been run.
# Exit 0 = allow stop, Exit 2 = block stop.
#
# Modeled after ship-skiff-stop-gate.sh (issue #201).
#
# Input (stdin JSON): {stop_hook_active, transcript_path, session_id, cwd, agent_id?}
# Output: exit code only.
#
# Fast-exit ladder:
# 1. jq not installed → exit 0
# 2. stop_hook_active: true → exit 0 (infinite-loop breaker)
# 3. agent_id present → exit 0 (subagent turn)
# 4. sentinel absent → exit 0 (not a ship-lite run)
# 5. transcript_path absent/empty → exit 0
# 6. transcript file missing → exit 0
# 7. transcript not parseable → exit 0
# 8. empty transcript → exit 0


command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
stop_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)
[ "$stop_active" = "true" ] && exit 0

agent_id=$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null)
[ -n "$agent_id" ] && exit 0

[ -f "$HOME/.ship/ship-lite-active-$PPID" ] || exit 0

transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -z "$transcript_path" ] && exit 0
[ ! -f "$transcript_path" ] && exit 0

transcript_snapshot=$(< "$transcript_path") || exit 0
printf '%s' "$transcript_snapshot" | jq -se . >/dev/null 2>&1 || exit 0

obj_count=$(printf '%s' "$transcript_snapshot" | jq -sc '[.[] | select(type == "object")] | length' 2>/dev/null)
[ "${obj_count:-0}" = "0" ] && exit 0

lines=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lines+=("$line")
done < <(printf '%s' "$transcript_snapshot" | jq -sc '.[] | select(type == "object")' 2>/dev/null)

[ ${#lines[@]} -eq 0 ] && exit 0

# Reverse scan: find last Skill(implement) invocation
skill_idx=-1
skill_content_idx=-1
for ((i=${#lines[@]}-1; i>=0; i--)); do
  cidx=$(printf '%s' "${lines[$i]}" | jq '
    .message.content
    | to_entries
    | map(select(.value.type == "tool_use" and .value.name == "Skill" and .value.input.skill == "implement"))
    | last
    | .key // -1
  ' 2>/dev/null)
  if [ -n "$cidx" ] && [ "$cidx" -ge 0 ] 2>/dev/null; then
    skill_idx=$i
    skill_content_idx=$cidx
    break
  fi
done

[ "$skill_idx" -lt 0 ] && exit 0

# Forward scan: check for @red-team Agent dispatch or anomalous AUQ
# Phase A: same-line continuation
agent_match=$(printf '%s' "${lines[$skill_idx]}" | jq -e --argjson sidx "$skill_content_idx" '
  .message.content[$sidx+1:][]?
  | select(.type == "tool_use")
  | select(.name == "Agent")
  | select(.input.prompt | test("red-team|red_team"; "i"))
' 2>/dev/null)
[ -n "$agent_match" ] && exit 0

auq_match=$(printf '%s' "${lines[$skill_idx]}" | jq -e --argjson sidx "$skill_content_idx" '
  .message.content[$sidx+1:][]?
  | select(.type == "tool_use")
  | select(.name == "AskUserQuestion")
  | select(.input.questions[0].header == "Anomalous /implement return")
' 2>/dev/null)
[ -n "$auq_match" ] && exit 0

# Phase B: subsequent lines
for ((i=skill_idx+1; i<${#lines[@]}; i++)); do
  agent_match=$(printf '%s' "${lines[$i]}" | jq -e '
    .message.content[]?
    | select(.type == "tool_use")
    | select(.name == "Agent")
    | select(.input.prompt | test("red-team|red_team"; "i"))
  ' 2>/dev/null)
  [ -n "$agent_match" ] && exit 0

  auq_match=$(printf '%s' "${lines[$i]}" | jq -e '
    .message.content[]?
    | select(.type == "tool_use")
    | select(.name == "AskUserQuestion")
    | select(.input.questions[0].header == "Anomalous /implement return")
  ' 2>/dev/null)
  [ -n "$auq_match" ] && exit 0
done

msg="/ship-lite Stage 2 has returned. You must dispatch @red-team (Stage 3) before ending your turn — or present the anomalous /implement return AskUserQuestion. See ship-lite.md Stage 2 auto-transition rule."
printf '%s\n' "$msg" >&2
exit 2
