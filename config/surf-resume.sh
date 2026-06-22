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

SURF_DIR="$REPO_ROOT/.surf"
RESUME_AFTER="$SURF_DIR/resume-after"
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

# Is there real unfinished board work? The done-marker is the authoritative "quiet"
# signal: a charter exists (newest by mtime) AND there is no done-marker → work remains.
# A finished or abandoned run is silenced by writing the done-marker at Wrap-up (or by a
# self-healing resume that finds the board already exhausted); see surf.md Steps 14–16.
work_remains() {
  local charter latest_charter="" newest=0 mt
  shopt -s nullglob
  for charter in "$SURF_DIR"/charter-*.md; do
    mt="$(mtime_of "$charter")"
    [ -n "$mt" ] || mt=0
    if [ "$mt" -ge "$newest" ]; then
      newest="$mt"
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

  # A `done:` line in any journal also marks the board exhausted.
  if grep -rqsiE '^- done:|done: board exhausted' "$SURF_DIR"/journal-*.md 2>/dev/null; then
    log "journal done: line present — nothing to revive"
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
  grep -iE 'usage limit|usage cap|rate limit|try again later|limit will reset|resets at' "$out" 2>/dev/null \
    | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' 2>/dev/null \
    | head -1 || true
}

# Does the captured pane show the session is currently capped? We capture only the CURRENT,
# VISIBLE screen (no deep `-S` scrollback) so a cap message that already scrolled away cannot
# falsely read as "currently capped" — the cap notice on a stalled Claude session is its active
# tail. This is the authoritative current-state read, not a grep over historical output.
hit_cap() {
  local out="$1"
  grep -qiE 'usage limit|usage cap|rate limit|try again later|limit will reset|resets at' "$out" 2>/dev/null
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
  trap 'rm -rf "$LOCKDIR"; rm -f "$out" "$full"' EXIT
  target="$(orch_target)"

  # Read the CURRENT visible screen of the orchestrator pane (no Claude tokens spent), then keep
  # only the ACTIVE TAIL (last few non-empty lines). A capped Claude session shows its cap notice
  # as the live tail; restricting to the tail keeps an older cap line that is merely still on
  # screen from re-arming. NOTE (documented limitation): pane text is the ONLY out-of-band cap
  # signal available — a capped session is blocked on the API and cannot write a marker itself, so
  # there is no machine-readable alternative to read. The conservative MIN_BACKOFF floor and the
  # single-shot, idempotent nudge bound the blast radius of any misread; validate against a real
  # capped Claude Code pane before trusting the patterns in production.
  tmux capture-pane -t "$target" -p >"$full" 2>/dev/null || true
  grep -v '^[[:space:]]*$' "$full" 2>/dev/null | tail -n 12 >"$out" || true

  # Read both signals up front: the reset time shown in the tail (if any) and the armed floor.
  local parsed_raw parsed_epoch="" armed_raw armed_epoch="" nowe
  parsed_raw="$(parse_reset_time "$out")"
  [ -n "$parsed_raw" ] && parsed_epoch="$(epoch_of_rfc3339 "$parsed_raw")"
  if [ -f "$RESUME_AFTER" ]; then
    armed_raw="$(cat "$RESUME_AFTER" 2>/dev/null || true)"
    armed_epoch="$(epoch_of_rfc3339 "$armed_raw")"
  fi
  nowe="$(now_epoch)"

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
  if hit_cap "$out"; then
    if { [ -n "$parsed_epoch" ] && [ "$parsed_epoch" -gt "$nowe" ]; } \
       || { [ -z "$parsed_epoch" ] && [ -z "$armed_epoch" ]; }; then
      arm_resume_after "$out"                                # (1) cap still in effect
      exit 0
    fi
    # else: lingering notice (reset already passed) or capped-unparseable-but-already-armed →
    # do not re-arm; fall through to the armed-floor decision below.
  fi

  if [ -n "$armed_epoch" ]; then
    if [ "$nowe" -lt "$armed_epoch" ]; then
      log "armed resume-after $armed_raw not yet reached — waiting"   # (3)
      exit 0
    fi
    # (2) armed and the floor has been crossed → the session stalled at a cap that has now reset.
    # Revive it IN PLACE with a keystroke to the orchestrator pane — no headless relaunch, no
    # process restart, so the still-alive teammate panes survive.
    log "reviving '$target' via tmux send-keys (armed floor crossed)"
    tmux send-keys -t "$target" "Cap window has reset — continue the /surf board run; do not idle." Enter 2>/dev/null || \
      log "send-keys failed (session gone?) — manual /surf resume needed"
    rm -f "$RESUME_AFTER" 2>/dev/null || true               # disarm so we nudge exactly once
    exit 0
  fi

  # (4) not capped and never armed → nothing to revive.
  log "live session, not capped, no armed floor — nothing to do"
  # lockdir + tmp removed by the EXIT trap.
}

main "$@"
