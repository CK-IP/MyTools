#!/usr/bin/env bash
# surf-resume.sh — session-bound revive watcher for /surf's persistent-tmux + revive
# auto-resume (surf.md Step 16).
#
# REFRAMED (issue #73): this is NO LONGER a headless relauncher. /surf delegates every issue
# to an agent-team teammate, and agent teams CANNOT run in headless `claude -p` mode — so the
# old `claude -p "/surf resume"` relaunch could never host the per-issue teammates. Instead /surf
# now runs in a long-lived NAMED tmux session ("surf") that stays alive across a usage-cap window,
# and this watcher REVIVES that still-alive session IN PLACE with `tmux send-keys` once the cap
# resets — so the teammates survive the cap.
#
# Fired on an interval by the com.surf.resume LaunchAgent. The gate is PURE BASH: it spends zero
# Claude tokens on an idle tick and only sends a revive keystroke when there is real unfinished
# board work, a LIVE named session to revive, and the usage-cap reset time has passed.
#
# REBOOT TRADE-OFF: this survives a usage-cap window, NOT a machine reboot. A reboot destroys the
# tmux session, so there is no live session to revive (the gate stays closed); recovery is then a
# MANUAL `tmux new -s surf` → `claude --dangerously-bypass-permissions` → `/surf resume`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- Tunables (overridable by env, e.g. for the functional test) ---
MIN_BACKOFF="${SURF_RESUME_MIN_BACKOFF:-300}"        # never revive sooner than 5 min after a cap
DEFAULT_BACKOFF="${SURF_RESUME_DEFAULT_BACKOFF:-18000}"  # parse-miss → 5h long default
MAX_RUN_AGE="${SURF_RESUME_MAX_RUN_AGE:-7200}"       # a lockdir older than 2h is stale → reclaim
SESSION="${SURF_RESUME_SESSION:-surf}"               # the canonical named tmux session
LOG="${SURF_RESUME_LOG:-/tmp/surf-resume.log}"
CAP_NOTICE_RE='weekly limit|hit your .*limit|usage limit|usage cap|rate limit|try again later|limit will reset|limit reached|resets at|/usage-credits'

SURF_DIR="${SURF_RESUME_DIR:-$REPO_ROOT/.surf}"   # overridable so the functional test can point at a fixture dir
RESUME_AFTER="$SURF_DIR/resume-after"
RESUME_PANES="$SURF_DIR/resume-panes"
LOCKDIR="$SURF_DIR/resume.lock"
ACTIVE="$SURF_DIR/active"
ORCH_PANE_FILE="$SURF_DIR/orchestrator-pane"   # tmux pane id the orchestrator records at Step 7

log() { printf '%s surf-resume: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG" 2>/dev/null || true; }

now_epoch() { date +%s; }

# RFC3339 (UTC, Z) string for an epoch.
rfc3339_of_epoch() {
  local e="$1"
  if date -u -r "$e" "+%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
    date -u -r "$e" "+%Y-%m-%dT%H:%M:%SZ"
  else
    date -u -d "@$e" "+%Y-%m-%dT%H:%M:%SZ"
  fi
}

# Epoch for an RFC3339 (UTC, Z) string. Empty on failure.
epoch_of_rfc3339() {
  local ts="$1"
  if date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" "+%s" 2>/dev/null; then
    return 0
  fi
  date -u -d "$ts" "+%s" 2>/dev/null || true
}

# mtime (epoch) of a path. Empty on failure.
mtime_of() {
  local p="$1"
  if stat -f %m "$p" 2>/dev/null; then
    return 0
  fi
  stat -c %Y "$p" 2>/dev/null || true
}

# Live pane ids for the named tmux session, one per line.
live_panes() {
  tmux list-panes -s -t "$SESSION" -F '#{pane_id}' 2>/dev/null || true
}

# Is there real unfinished board work? The done-marker is the authoritative "quiet"
# signal: a charter exists (latest by its sortable `<timestamp>` suffix) AND there is no
# done-marker → work remains. A finished or abandoned run is silenced by writing the done-marker at
# Wrap-up (or by a self-healing resume that finds the board already exhausted); see surf.md Steps 14–16.
work_remains() {
  # Pick the latest charter by the SORTABLE `charter-<timestamp>.md` suffix, not mtime: timestamps
  # are ISO-like (lexical order == chronological), and a `touch` on an OLD charter must not make it
  # look newest and silence a genuinely-newer unfinished run (#86). The paired journal/done-marker
  # are then derived from this charter's own suffix below.
  local charter latest_charter=""
  shopt -s nullglob
  for charter in "$SURF_DIR"/charter-*.md; do
    if [ -z "$latest_charter" ] || [ "$charter" \> "$latest_charter" ]; then
      latest_charter="$charter"
    fi
  done
  shopt -u nullglob

  [ -n "$latest_charter" ] || { log "no charter — nothing to revive"; return 1; }

  # Done-marker for the latest charter → run finished, gate goes quiet.
  if [ -e "${latest_charter}-done" ]; then
    log "done-marker present for $(basename "$latest_charter") — nothing to revive"
    return 1
  fi

  # A `done:` line in the LATEST charter's OWN journal also marks the board exhausted.
  # Scope this to the journal paired with the latest charter (same `<timestamp>` suffix:
  # `charter-<timestamp>.md` ↔ `journal-<timestamp>.md`); a GLOBAL grep across all journals
  # would let an OLD completed run's journal silence a NEWER unfinished charter (#86).
  local charter_ts latest_journal
  charter_ts="$(basename "$latest_charter" .md)"; charter_ts="${charter_ts#charter-}"
  latest_journal="$SURF_DIR/journal-${charter_ts}.md"
  if [ -f "$latest_journal" ] && grep -qsiE '^- done:|done: board exhausted' "$latest_journal" 2>/dev/null; then
    log "journal done: line present for $(basename "$latest_journal") — nothing to revive"
    return 1
  fi

  # Charter present and not done → real unfinished work.
  return 0
}

# Is there a LIVE /surf session to revive? Requires BOTH a live `.surf/active` PID marker AND a
# live named tmux session to send keys to. In the reframed model a live session is REQUIRED (we
# revive it in place); a stale marker or a missing session means there is nothing to nudge — the
# reboot/last-resort path is a manual `/surf resume`, never an automatic headless relaunch.
live_session() {
  if [ ! -f "$ACTIVE" ]; then
    log "no .surf/active marker — no live session to revive"
    return 1
  fi
  local pid
  pid="$(cat "$ACTIVE" 2>/dev/null || true)"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    log "stale .surf/active marker (dead pid '$pid') — cleaning; no live session to revive"
    rm -f "$ACTIVE" 2>/dev/null || true
    return 1
  fi
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    log "live pid $pid but no tmux session '$SESSION' — session gone (reboot?); manual /surf resume needed"
    return 1
  fi
  return 0
}

# Pure-bash gate. No Claude call. Returns 0 only when a revive should happen.
# Reclaims a stale lockdir (older than MAX_RUN_AGE) as a side effect.
should_revive() {
  # (a) lock not held — or held but stale (covers a SIGKILL that never fired the trap).
  if [ -d "$LOCKDIR" ]; then
    local lmt age
    lmt="$(mtime_of "$LOCKDIR")"
    if [ -n "$lmt" ]; then
      age=$(( $(now_epoch) - lmt ))
      if [ "$age" -ge "$MAX_RUN_AGE" ]; then
        log "stale lockdir (age ${age}s ≥ ${MAX_RUN_AGE}s) — reclaiming"
        rm -rf "$LOCKDIR"
      else
        log "live lockdir (age ${age}s) — another revive is running"
        return 1
      fi
    else
      # Can't stat it — treat as live to be safe.
      log "lockdir present, mtime unknown — treating as live"
      return 1
    fi
  fi

  # (b) a LIVE interactive/resumed /surf session must exist to revive.
  if ! live_session; then
    return 1
  fi

  # (c) real unfinished work.
  work_remains || return 1

  return 0
}

# Best-effort parse of a cap reset time (RFC3339 Z) from the captured pane. Empty if none.
# Anchored: only consider RFC3339 timestamps on lines that actually mention the cap/reset
# (the same wording hit_cap uses), so an earlier unrelated timestamp — e.g. an echoed
# `↺ resume <ISO>` or a merge line — can't be mistaken for the reset time.
parse_reset_time() {
  local out="$1"
  local line ts time tz
  line="$(
    grep -iE "$CAP_NOTICE_RE" \
      "$out" 2>/dev/null | head -1 || true
  )"
  [ -n "$line" ] || return 0

  ts="$(printf '%s\n' "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' 2>/dev/null | head -1 || true)"
  if [ -n "$ts" ]; then
    printf '%s\n' "$ts"
    return 0
  fi

  time="$(
    printf '%s\n' "$line" | sed -nE 's/.*([0-9]{1,2}(:[0-9]{2})?[[:space:]]*[AaPp][Mm]).*/\1/p' | head -1 || true
  )"
  tz="$(
    printf '%s\n' "$line" | sed -nE 's/.*\(([A-Za-z_]+\/[A-Za-z_]+)\).*/\1/p' | head -1 || true
  )"
  if [ -z "$time" ] || [ -z "$tz" ] || ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi

  python3 - "$time" "$tz" <<'PY' 2>/dev/null || true
import re
import sys
from datetime import datetime, timedelta, timezone

try:
    from zoneinfo import ZoneInfo
except Exception:
    raise SystemExit(0)

token = sys.argv[1].strip().lower().replace(" ", "")
match = re.fullmatch(r"(?P<h>\d{1,2})(?::(?P<m>\d{2}))?(?P<ampm>am|pm)", token)
if not match:
    raise SystemExit(0)

hour = int(match.group("h")) % 12
if match.group("ampm") == "pm":
    hour += 12
minute = int(match.group("m") or 0)

zone = ZoneInfo(sys.argv[2])
now = datetime.now(zone)
candidate = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
if candidate <= now:
    candidate += timedelta(days=1)

print(candidate.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

# Does the captured pane show the session is currently capped? We capture only the CURRENT,
# VISIBLE screen (no deep `-S` scrollback) so a cap message that already scrolled away cannot
# falsely read as "currently capped" — the cap notice on a stalled Claude session is its active
# tail. This is the authoritative current-state read, not a grep over historical output.
hit_cap() {
  local out="$1"
  grep -qiE "$CAP_NOTICE_RE" "$out" 2>/dev/null
}

# The tmux target for capture/send — the recorded orchestrator pane id if /surf wrote one
# (Step 7), else the named session's active pane. Sending to a precise pane keeps the revive
# keystroke out of a teammate's pane.
orch_target() {
  if [ -f "$ORCH_PANE_FILE" ]; then
    local p
    p="$(cat "$ORCH_PANE_FILE" 2>/dev/null || true)"
    if [ -n "$p" ]; then printf '%s' "$p"; return 0; fi
  fi
  printf '%s' "$SESSION"
}

# Arm the resume-after floor from an observed cap: max(parsed_reset, now + MIN_BACKOFF), or a
# long default when the reset time is unparseable (never a near-term hot-loop).
arm_resume_after() {
  local out="$1" parsed parsed_epoch floor_epoch chosen_epoch
  parsed="$(parse_reset_time "$out")"
  floor_epoch=$(( $(now_epoch) + MIN_BACKOFF ))
  if [ -n "$parsed" ]; then parsed_epoch="$(epoch_of_rfc3339 "$parsed")"; else parsed_epoch=""; fi
  if [ -n "$parsed_epoch" ]; then
    if [ "$parsed_epoch" -gt "$floor_epoch" ]; then chosen_epoch="$parsed_epoch"; else chosen_epoch="$floor_epoch"; fi
    log "session capped; parsed reset $parsed → armed resume-after $(rfc3339_of_epoch "$chosen_epoch")"
  else
    chosen_epoch=$(( $(now_epoch) + DEFAULT_BACKOFF ))
    log "session capped; reset unparseable → long default armed resume-after $(rfc3339_of_epoch "$chosen_epoch")"
  fi
  rfc3339_of_epoch "$chosen_epoch" >"$RESUME_AFTER"
}

main() {
  mkdir -p "$SURF_DIR"

  should_revive || { log "gate closed — exiting"; exit 0; }

  # Atomic acquire: mkdir fails if another tick already holds it.
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    log "lost lock race — exiting"
    exit 0
  fi
  local out target full
  out="$(mktemp)"
  full="$(mktemp)"
  local best
  best="$(mktemp)"
  trap 'rm -rf "$LOCKDIR"; rm -f "${out:-}" "${full:-}" "${best:-}"' EXIT
  target="$(orch_target)"
  local parsed_raw parsed_epoch armed_raw armed_epoch nowe floor_epoch
  local active_cap=0 best_epoch="" best_out="" capped_panes="" pane_list pane candidate_epoch
  local revive_targets

  armed_raw=""
  armed_epoch=""
  if [ -f "$RESUME_AFTER" ]; then
    armed_raw="$(cat "$RESUME_AFTER" 2>/dev/null || true)"
    armed_epoch="$(epoch_of_rfc3339 "$armed_raw")"
  fi
  nowe="$(now_epoch)"
  floor_epoch=$((nowe + MIN_BACKOFF))

  pane_list="$(live_panes)"
  [ -n "$pane_list" ] || pane_list="$target"
  while IFS= read -r pane; do
    [ -n "$pane" ] || continue
    tmux capture-pane -t "$pane" -p >"$full" 2>/dev/null || true
    grep -v '^[[:space:]]*$' "$full" 2>/dev/null | tail -n 12 >"$out" || true
    if hit_cap "$out"; then
      active_cap=1
      capped_panes="${capped_panes}${pane}"$'\n'
      parsed_raw="$(parse_reset_time "$out")"
      if [ -n "$parsed_raw" ]; then
        parsed_epoch="$(epoch_of_rfc3339 "$parsed_raw")"
        if [ -n "$parsed_epoch" ] && [ "$parsed_epoch" -gt "$nowe" ]; then
          candidate_epoch=$(( parsed_epoch > floor_epoch ? parsed_epoch : floor_epoch ))
          if [ -z "$best_epoch" ] || [ "$candidate_epoch" -gt "$best_epoch" ]; then
            best_epoch="$candidate_epoch"
            cp "$out" "$best"
            best_out="$best"
          fi
        elif [ -z "$armed_epoch" ] && [ -z "$best_out" ]; then
          cp "$out" "$best"
          best_out="$best"
        fi
      elif [ -z "$armed_epoch" ] && [ -z "$best_out" ]; then
        cp "$out" "$best"
        best_out="$best"
      fi
    fi
  done <<<"$pane_list"

  # Read both signals up front: the reset time shown in the tail (if any) and the armed floor.
  # A cap notice is only "still in effect" when its reset time is in the future, or it is the
  # first sight of a cap and there is no armed floor yet. A lingering notice whose reset has
  # already passed must NOT re-arm, or the revive would livelock.
  if [ "$active_cap" -eq 1 ]; then
    printf '%s\n' "$capped_panes" | awk 'NF && !seen[$0]++' >"$RESUME_PANES"
    # Relative reset strings (e.g. "resets 8pm") always parse to a future epoch, so once an
    # armed floor has already been crossed we must not treat the lingering notice as a fresh cap.
    if [ -n "$best_out" ] && { [ -z "$armed_epoch" ] || [ "$nowe" -lt "$armed_epoch" ]; }; then
      arm_resume_after "$best_out"
      exit 0
    fi
  fi

  # State machine — positive stall evidence is REQUIRED before any nudge:
  #   (1) cap STILL IN EFFECT → arm/refresh resume-after, never nudge.
  #   (2) armed AND reset passed → the session WAS observed capped and the window has reset
  #                               → revive once, then disarm.
  #   (3) armed AND reset pending → wait.
  #   (4) not capped, not armed   → healthy/working session → DO NOTHING.
  #
  # A cap notice is only "still in effect" when its parsed reset time is in the FUTURE, OR it is
  # the first sight of a cap (unparseable reset, no floor yet). A LINGERING cap notice whose reset
  # has already passed must NOT re-arm — the notice stays on the tail until we nudge, so re-arming
  # it would push the floor forward every tick and the revive (state 2) would never fire (livelock).
  # In that case we fall through to the armed-floor check and revive.
  if [ -n "$armed_epoch" ]; then
    if [ "$nowe" -lt "$armed_epoch" ]; then
      log "armed resume-after $armed_raw not yet reached — waiting"   # (3)
      exit 0
    fi
    # (2) armed and the floor has been crossed → the session stalled at a cap that has now reset.
    # Revive it IN PLACE with a keystroke to the pane(s) that actually stalled — no headless
    # relaunch, no process restart, so the still-alive teammate panes survive.
    if [ -s "$RESUME_PANES" ]; then
      revive_targets="$(cat "$RESUME_PANES" 2>/dev/null || true)"
    else
      revive_targets="$(orch_target)"
    fi
    while IFS= read -r pane; do
      [ -n "$pane" ] || continue
      log "reviving '$pane' via tmux send-keys (armed floor crossed)"
      tmux send-keys -t "$pane" "Cap window has reset — continue the /surf board run; do not idle." Enter 2>/dev/null || \
        log "send-keys failed for '$pane' (session gone?) — manual /surf resume needed"
    done <<<"$revive_targets"
    rm -f "$RESUME_AFTER" "$RESUME_PANES" 2>/dev/null || true   # disarm so we nudge exactly once
    exit 0
  fi

  # (4) not capped and never armed → nothing to revive.
  log "live session, not capped, no armed floor — nothing to do"
  # lockdir + tmp removed by the EXIT trap.
}

# Run main only when executed directly — sourcing (e.g. the functional test) gets the functions
# without firing the watcher.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
