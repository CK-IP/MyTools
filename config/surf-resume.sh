#!/usr/bin/env bash
# surf-resume.sh — external scheduler wrapper for /surf reactive usage-cap auto-resume.
#
# Fired on an interval by the com.surf.resume LaunchAgent. The gate is PURE BASH:
# it spends zero Claude tokens on an idle tick and only launches
# `claude --dangerously-bypass-permissions -p "/surf resume"` when there is real
# unfinished board work, the usage-cap reset time has passed, and no other resume
# is already running. When the relaunched run hits the cap again, it captures the
# reset time (conservative floor) so the next tick waits rather than hot-looping.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- Tunables (overridable by env, e.g. for the functional test) ---
MIN_BACKOFF="${SURF_RESUME_MIN_BACKOFF:-300}"        # never resume sooner than 5 min after a cap
DEFAULT_BACKOFF="${SURF_RESUME_DEFAULT_BACKOFF:-18000}"  # parse-miss → 5h long default
MAX_RUN_AGE="${SURF_RESUME_MAX_RUN_AGE:-7200}"       # a lockdir older than 2h is stale → reclaim
LOG="${SURF_RESUME_LOG:-/tmp/surf-resume.log}"

SURF_DIR="$REPO_ROOT/.surf"
RESUME_AFTER="$SURF_DIR/resume-after"
LOCKDIR="$SURF_DIR/resume.lock"
ACTIVE="$SURF_DIR/active"

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

  [ -n "$latest_charter" ] || { log "no charter — nothing to resume"; return 1; }

  # Done-marker for the latest charter → run finished, gate goes quiet.
  if [ -e "${latest_charter}-done" ]; then
    log "done-marker present for $(basename "$latest_charter") — nothing to resume"
    return 1
  fi

  # A `done:` line in any journal also marks the board exhausted.
  if grep -rqsiE '^- done:|done: board exhausted' "$SURF_DIR"/journal-*.md 2>/dev/null; then
    log "journal done: line present — nothing to resume"
    return 1
  fi

  # Charter present and not done → real unfinished work.
  return 0
}

# Is a /surf session already running? A live `.surf/active` marker holds a PID; if that
# PID is still alive we must not launch on top of it. A stale marker (dead PID, or
# unreadable) is ignored and cleaned, so a crash that skipped the EXIT trap self-heals.
active_session() {
  [ -f "$ACTIVE" ] || return 1
  local pid
  pid="$(cat "$ACTIVE" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    log "live .surf/active (pid $pid) — a /surf is already running"
    return 0
  fi
  log "stale .surf/active marker — cleaning"
  rm -f "$ACTIVE" 2>/dev/null || true
  return 1
}

# Pure-bash gate. No Claude call. Returns 0 only when a relaunch should happen.
# Reclaims a stale lockdir (older than MAX_RUN_AGE) as a side effect.
should_launch() {
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
        log "live lockdir (age ${age}s) — another resume is running"
        return 1
      fi
    else
      # Can't stat it — treat as live to be safe.
      log "lockdir present, mtime unknown — treating as live"
      return 1
    fi
  fi

  # (b) no live interactive/resumed /surf session already running.
  if active_session; then
    return 1
  fi

  # (c) resume-after absent, or now ≥ it.
  if [ -f "$RESUME_AFTER" ]; then
    local ra_ts ra_epoch
    ra_ts="$(cat "$RESUME_AFTER" 2>/dev/null || true)"
    ra_epoch="$(epoch_of_rfc3339 "$ra_ts")"
    if [ -n "$ra_epoch" ] && [ "$(now_epoch)" -lt "$ra_epoch" ]; then
      log "resume-after $ra_ts not yet reached — waiting"
      return 1
    fi
  fi

  # (d) real unfinished work.
  work_remains || return 1

  return 0
}

# Best-effort parse of a cap reset time (RFC3339 Z) from the run output. Empty if none.
# Anchored: only consider RFC3339 timestamps on lines that actually mention the cap/reset
# (the same wording hit_cap uses), so an earlier unrelated timestamp — e.g. an echoed
# `↺ resume <ISO>` or a merge line — can't be mistaken for the reset time.
parse_reset_time() {
  local out="$1"
  grep -iE 'usage limit|usage cap|rate limit|try again later|limit will reset|resets at' "$out" 2>/dev/null \
    | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' 2>/dev/null \
    | head -1 || true
}

# Did the run hit the usage cap?
hit_cap() {
  local out="$1"
  grep -qiE 'usage limit|usage cap|rate limit|try again later|limit will reset|resets at' "$out" 2>/dev/null
}

main() {
  mkdir -p "$SURF_DIR"

  should_launch || { log "gate closed — exiting"; exit 0; }

  # Atomic acquire: mkdir fails if another tick already holds it.
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    log "lost lock race — exiting"
    exit 0
  fi
  trap 'rm -rf "$LOCKDIR"' EXIT

  log "launching: claude --dangerously-bypass-permissions -p \"/surf resume\""
  local out
  out="$(mktemp)"
  trap 'rm -rf "$LOCKDIR"; rm -f "$out"' EXIT

  claude --dangerously-bypass-permissions -p "/surf resume" >"$out" 2>&1 || true
  cat "$out" >>"$LOG" 2>/dev/null || true

  if hit_cap "$out"; then
    local parsed parsed_epoch floor_epoch chosen_epoch
    parsed="$(parse_reset_time "$out")"
    floor_epoch=$(( $(now_epoch) + MIN_BACKOFF ))
    if [ -n "$parsed" ]; then
      parsed_epoch="$(epoch_of_rfc3339 "$parsed")"
    else
      parsed_epoch=""
    fi
    if [ -n "$parsed_epoch" ]; then
      # max(parsed, now + MIN_BACKOFF)
      if [ "$parsed_epoch" -gt "$floor_epoch" ]; then
        chosen_epoch="$parsed_epoch"
      else
        chosen_epoch="$floor_epoch"
      fi
      log "cap hit; parsed reset $parsed → resume-after $(rfc3339_of_epoch "$chosen_epoch")"
    else
      # Unparseable → long default, never a near-term hot-loop.
      chosen_epoch=$(( $(now_epoch) + DEFAULT_BACKOFF ))
      log "cap hit; reset unparseable → long default resume-after $(rfc3339_of_epoch "$chosen_epoch")"
    fi
    rfc3339_of_epoch "$chosen_epoch" >"$RESUME_AFTER"
  else
    log "run finished without hitting the cap"
  fi
  # lockdir + tmp removed by the EXIT trap.
}

main "$@"
