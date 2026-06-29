#!/usr/bin/env bash
# surf-resume.sh — durable-file headless-relaunch watcher for /surf's usage-cap auto-resume
# (surf.md Step 16).
#
# #124: this is the DEFAULT cap-recovery — a headless relaunch of `/surf resume`, the proven #53
# LaunchAgent model. /surf delegates each issue to a headless `claude -p` worker, and a headless
# `claude -p` process CAN host /sail's crew (depth-0 subagents) — so there is no session that must
# stay alive across the cap, and no need for an in-place tmux send-keys revive. Nothing needs to
# persist: the durable `.surf/` files + git are the entire state, and the relaunched headless run
# (`claude --dangerously-bypass-permissions -p "/surf resume"`) rebuilds board position from them.
#
# This SUPERSEDES the #73 persistent-tmux send-keys revive, which existed only because the old
# teammate-pane build body could not run headless — a premise now verified FALSE. The optional
# supervised (panes) lens (surf.md Step 3b) may still revive a long-lived session in place; that is
# a visibility convenience of the optional lens, not this default watcher.
#
# Fired on an interval by the com.surf.resume LaunchAgent. The gate is PURE BASH: it spends zero
# Claude tokens on an idle tick and only relaunches when there is real unfinished board work, no
# /surf already running, and the usage-cap reset time has passed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- Tunables (overridable by env, e.g. for the functional test) ---
MIN_BACKOFF="${SURF_RESUME_MIN_BACKOFF:-300}"        # never relaunch sooner than 5 min after a cap
DEFAULT_BACKOFF="${SURF_RESUME_DEFAULT_BACKOFF:-18000}"  # parse-miss → 5h long default
MAX_RUN_AGE="${SURF_RESUME_MAX_RUN_AGE:-7200}"       # a lockdir older than 2h is stale → reclaim
LOG="${SURF_RESUME_LOG:-/tmp/surf-resume.log}"
CAP_NOTICE_RE='weekly limit|hit your .*limit|usage limit|usage cap|rate limit|try again later|limit will reset|limit reached|resets at|/usage-credits'

SURF_DIR="${SURF_RESUME_DIR:-$REPO_ROOT/.surf}"   # overridable so the functional test can point at a fixture dir
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

  [ -n "$latest_charter" ] || { log "no charter — nothing to resume"; return 1; }

  # Done-marker for the latest charter → run finished, gate goes quiet.
  if [ -e "${latest_charter}-done" ]; then
    log "done-marker present for $(basename "$latest_charter") — nothing to resume"
    return 1
  fi

  # User-stop sentinel → a DELIBERATE pause, not a cap (#124 R5-5). The watcher must NOT auto-relaunch
  # a run the operator stopped on purpose. `/surf resume` clears `.surf/<charter>-paused` on re-entry,
  # so a manual resume restarts auto-recovery; a cap-stop never writes this sentinel, so it relaunches.
  if [ -e "${latest_charter}-paused" ]; then
    log "user-stop sentinel present for $(basename "$latest_charter") — deliberately paused, not resuming"
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
    log "journal done: line present for $(basename "$latest_journal") — nothing to resume"
    return 1
  fi

  # Charter present and not done → real unfinished work.
  return 0
}

# Is a /surf session already running? A live `.surf/active` marker holds a PID; if that PID is
# still alive we must NOT relaunch on top of it. A stale marker (dead PID, or unreadable) is
# ignored and cleaned, so a crash that skipped the EXIT trap self-heals.
active_session() {
  [ -f "$ACTIVE" ] || return 1
  local pid
  pid="$(cat "$ACTIVE" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    log "live .surf/active (pid $pid) — a /surf is already running"
    return 0
  fi
  log "stale .surf/active marker (dead pid '$pid') — cleaning"
  rm -f "$ACTIVE" 2>/dev/null || true
  return 1
}

# Pure-bash gate. No Claude call. Returns 0 only when a headless relaunch should happen.
# Reclaims a lockdir only when its recorded relaunch PID is dead AND it has aged out.
should_launch() {
  # (a) lock held? A relaunch can legitimately run for HOURS (a full board pass), far longer than
  #     MAX_RUN_AGE — so age ALONE must NOT make the lock look stale (#124 R5-4: that race let a
  #     second tick relaunch concurrently). The authoritative liveness signal is the relaunch PID
  #     recorded in the lockdir: a LIVE pid → lock is live regardless of age; only a DEAD-or-absent
  #     pid that ALSO aged past MAX_RUN_AGE is reclaimed (covers a SIGKILL that never fired the trap).
  if [ -d "$LOCKDIR" ]; then
    local lpid lmt age
    lpid="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
    if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then
      log "live lockdir (relaunch pid $lpid alive) — another resume is running"
      return 1
    fi
    lmt="$(mtime_of "$LOCKDIR")"
    if [ -n "$lmt" ]; then
      age=$(( $(now_epoch) - lmt ))
      if [ "$age" -ge "$MAX_RUN_AGE" ]; then
        log "stale lockdir (pid '${lpid:-none}' dead, age ${age}s ≥ ${MAX_RUN_AGE}s) — reclaiming"
        rm -rf "$LOCKDIR"
      else
        log "lockdir pid dead but young (age ${age}s) — holding to avoid a kill/restart race"
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

# Best-effort parse of a cap reset time (RFC3339 Z) from the relaunched run's OWN output. Empty if
# none. Anchored: only consider RFC3339 timestamps on lines that actually mention the cap/reset
# (the same wording hit_cap uses), so an unrelated timestamp can't be mistaken for the reset time.
parse_reset_time() {
  local out="$1"
  local line ts time tz
  # Anchor to the SAME tail buffer hit_cap matched (#124 r3): only consider a cap-wording line within
  # the last N non-empty lines, so a reset time is never parsed from unrelated board content earlier
  # in the output (the timestamp that hit_cap's tail anchor already refused to treat as a cap notice).
  line="$(cap_tail "$out" | grep -iE "$CAP_NOTICE_RE" 2>/dev/null | head -1 || true)"
  [ -n "$line" ] || return 0

  # Preferred: an explicit RFC3339 Z timestamp on the cap line.
  ts="$(printf '%s\n' "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' 2>/dev/null | head -1 || true)"
  if [ -n "$ts" ]; then
    printf '%s\n' "$ts"
    return 0
  fi

  # Fallback (#119 weekly cap): a relative am/pm clock time + an IANA TZ, e.g.
  # "resets 8pm (America/New_York)". Roll it FORWARD to the next future epoch and emit RFC3339 Z.
  time="$(printf '%s\n' "$line" | sed -nE 's/.*([0-9]{1,2}(:[0-9]{2})?[[:space:]]*[AaPp][Mm]).*/\1/p' | head -1 || true)"
  tz="$(printf '%s\n' "$line" | sed -nE 's/.*\(([A-Za-z_]+\/[A-Za-z_]+)\).*/\1/p' | head -1 || true)"
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

# Did the relaunched run hit the usage cap? ANCHORED TO THE TAIL (#124 R2-6): read only the last N
# non-empty lines, because a genuine cap notice is the TERMINAL state of a capped run (the run stops
# at it), never buried mid-output. This stops ordinary board content mentioning "rate limit"/"resets
# at" earlier in the output from triggering a spurious multi-hour backoff. A cap notice WITHOUT a
# parseable reset time is still detected here (it then arms the conservative DEFAULT_BACKOFF floor),
# so the never-hot-loop guarantee holds whether or not a reset token co-occurs.
# The last N non-empty lines of the relaunch output — the only window where a genuine cap notice
# (the TERMINAL state of a capped run) can legitimately appear. Shared by hit_cap and
# parse_reset_time so the two can never drift (#124 r3). N is env-overridable.
cap_tail() {
  local out="$1" tail_n="${SURF_RESUME_CAP_TAIL:-3}"
  grep -v '^[[:space:]]*$' "$out" 2>/dev/null | tail -n "$tail_n" || true
}

hit_cap() {
  local out="$1" tail_buf
  tail_buf="$(cap_tail "$out")"
  [ -n "$tail_buf" ] || return 1
  printf '%s\n' "$tail_buf" | grep -qiE "$CAP_NOTICE_RE" 2>/dev/null
}

main() {
  mkdir -p "$SURF_DIR"

  should_launch || { log "gate closed — exiting"; exit 0; }

  # Atomic acquire: mkdir fails if another tick already holds it.
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    log "lost lock race — exiting"
    exit 0
  fi
  # Record THIS process's pid in the lock so a concurrent tick can tell a live multi-hour relaunch
  # from a genuinely-dead one by liveness, not by age alone (#124 R5-4). This tick holds the lock
  # for the relaunch's whole lifetime; should_launch keeps the lock live while this pid is alive.
  printf '%s\n' "$$" >"$LOCKDIR/pid" 2>/dev/null || true
  local out
  out="$(mktemp)"
  trap 'rm -rf "$LOCKDIR"; rm -f "${out:-}"' EXIT

  # NOTE (deferred → §5c): no crash-loop escalating backoff here — bounded retry-on-transient is the
  # §5c backlog item, out of scope for this swap-only land. A persistent cap is bounded by the
  # resume-after floor below; a persistent non-cap failure simply re-relaunches each tick.
  log "relaunching: claude --dangerously-bypass-permissions -p \"/surf resume\""
  claude --dangerously-bypass-permissions -p "/surf resume" >"$out" 2>&1 || true
  cat "$out" >>"$LOG" 2>/dev/null || true

  # If the relaunched run hit the cap again, arm a conservative resume-after floor so the next tick
  # waits rather than hot-looping.
  if hit_cap "$out"; then
    local parsed parsed_epoch floor_epoch chosen_epoch
    parsed="$(parse_reset_time "$out")"
    floor_epoch=$(( $(now_epoch) + MIN_BACKOFF ))
    if [ -n "$parsed" ]; then parsed_epoch="$(epoch_of_rfc3339 "$parsed")"; else parsed_epoch=""; fi
    if [ -n "$parsed_epoch" ]; then
      if [ "$parsed_epoch" -gt "$floor_epoch" ]; then chosen_epoch="$parsed_epoch"; else chosen_epoch="$floor_epoch"; fi
      log "cap hit; parsed reset $parsed → resume-after $(rfc3339_of_epoch "$chosen_epoch")"
    else
      chosen_epoch=$(( $(now_epoch) + DEFAULT_BACKOFF ))
      log "cap hit; reset unparseable → long default resume-after $(rfc3339_of_epoch "$chosen_epoch")"
    fi
    rfc3339_of_epoch "$chosen_epoch" >"$RESUME_AFTER"
  else
    # Clean relaunch (no cap on the rerun): clear any crossed floor so the next tick is not gated by
    # a stale resume-after. (We only reach the relaunch when should_launch already passed — i.e. the
    # floor was absent or crossed — so removing it here is safe and restores the floor-cleared
    # behavior the pre-#124 revive model had. #124 R2-3.)
    rm -f "$RESUME_AFTER" 2>/dev/null || true
    log "run finished without hitting the cap — cleared any crossed resume-after floor"
  fi
  # lockdir + tmp removed by the EXIT trap.
}

# Run main only when executed directly — sourcing (e.g. the functional test) gets the functions
# without firing the watcher.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
