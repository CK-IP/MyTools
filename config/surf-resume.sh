#!/usr/bin/env bash
# surf-resume.sh — durable-file headless-relaunch watcher for /surf's usage-cap auto-resume
# (surf.md Step 16).
#
# #124: this is the DEFAULT cap-recovery — a headless relaunch of `/surf resume`, the proven #53
# LaunchAgent model. /surf delegates each issue to a headless `claude -p` worker, and a headless
# `claude -p` process CAN host /sail's crew (depth-0 subagents) — so there is no session that must
# stay alive across the cap, and no need for an in-place tmux send-keys revive. Nothing needs to
# persist: the durable `.surf/` files + git are the entire state, and the relaunched headless run
# (`claude --dangerously-skip-permissions -p "/surf resume"`) rebuilds board position from them.
#
# This SUPERSEDES the #73 persistent-tmux send-keys revive, which existed only because the old
# teammate-pane build body could not run headless — a premise now verified FALSE. The optional
# supervised (panes) lens (surf.md Step 3b) is a pure visibility layer with no cap-recovery of its
# own; a capped run — watched or not — recovers via this same durable-file headless relaunch.
#
# Fired on an interval by the com.surf.resume LaunchAgent. The gate is PURE BASH: it spends zero
# Claude tokens on an idle tick and only relaunches when there is real unfinished board work, no
# /surf already running, and the usage-cap reset time has passed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- Tunables (overridable by env, e.g. for the functional test) ---
MAX_RUN_AGE="${SURF_RESUME_MAX_RUN_AGE:-7200}"       # a lockdir older than 2h is stale → reclaim
HEARTBEAT_STALE_SECS="${SURF_HEARTBEAT_STALE_SECS:-2700}"  # live active pid older than 45 min heartbeat → stalled
LOG="${SURF_RESUME_LOG:-/tmp/surf-resume.log}"
# #163: cap classification, reset parsing AND floor arming are single-sourced in the tested Python
# module (sail cap-recovery), not a bash regex / bash math — so the supervisor and this watcher can
# never drift. The backoff tunables (SURF_RESUME_MIN_BACKOFF / SURF_RESUME_DEFAULT_BACKOFF and the
# SAIL_CAP_RECOVERY_* knobs) are read by that module directly from the environment.

SURF_DIR="${SURF_RESUME_DIR:-$REPO_ROOT/.surf}"   # overridable so the functional test can point at a fixture dir
RESUME_AFTER="$SURF_DIR/resume-after"
LOCKDIR="$SURF_DIR/resume.lock"
ACTIVE="$SURF_DIR/active"
HEARTBEAT="$SURF_DIR/heartbeat"
CAPPED="$SURF_DIR/capped"

cap_recovery() {
  # launchd sets no WorkingDirectory, so main() runs from `/` (or $HOME) where the `sail` package is
  # not importable. Run the module from REPO_ROOT so `python3 -m sail` resolves (#127/#128 runtime
  # escape). All paths passed in (--text-file, --surf-dir) are absolute, so the cd is safe.
  ( cd "$REPO_ROOT" && python3 -m sail cap-recovery "$@" )
}

log() { printf '%s surf-resume: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG" 2>/dev/null || true; }

now_epoch() { date +%s; }

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

heartbeat_is_stale() {
  [ -f "$HEARTBEAT" ] || return 0
  local hb_mtime age
  hb_mtime="$(mtime_of "$HEARTBEAT")"
  [ -n "$hb_mtime" ] || return 0
  age=$(( $(now_epoch) - hb_mtime ))
  [ "$age" -ge "$HEARTBEAT_STALE_SECS" ]
}

resolve_claude() {
  local found
  found="$(command -v claude 2>/dev/null || true)"
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    return 0
  fi
  if [ -x "$HOME/.local/bin/claude" ]; then
    printf '%s\n' "$HOME/.local/bin/claude"
    return 0
  fi
  return 1
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
    # Scenario 5: a live supervisor that cap-relinquished (wrote .surf/capped) must be taken over,
    # even with a FRESH heartbeat — so the capped marker overrides the heartbeat check below by
    # design. Guard against a STALE lone marker double-driving a healthy session: only honor it when
    # an armed resume-after floor is ALSO present (relinquish writes the pair; clear removes the
    # pair). should_launch then still waits until that floor passes before relaunching.
    if [ -f "$CAPPED" ] && [ -f "$RESUME_AFTER" ]; then
      log "live .surf/active (pid $pid) + capped marker + armed floor — supervisor self-relinquished, treating as recoverable"
      return 1
    fi
    if heartbeat_is_stale; then
      log "live .surf/active (pid $pid) but stale heartbeat — treating as stalled"
      return 1
    fi
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

# Did the relaunched run hit the usage cap? #163: classification is single-sourced in the tested
# Python module (sail cap-recovery classify), which reads only the TERMINAL tail of the output — the
# only window where a genuine cap notice (the terminal state of a capped run) can legitimately appear
# — so ordinary board content mentioning "rate limit"/"resets at" earlier in the output cannot
# trigger a spurious multi-hour backoff. Cap text is passed via the output FILE (never interpolated
# on the command line), keeping the shell↔Python interface injection-safe.
hit_cap() {
  local out="$1"
  [ -n "$out" ] || return 1
  cap_recovery classify --text-file "$out" >/dev/null 2>&1
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
  # This tick has committed to taking over, so the self-relinquish `capped` marker has done its job —
  # remove it NOW (#163 review): its meaning is "a live supervisor is cap-blocked, take over," which
  # this takeover fulfills. Leaving it until the relaunch's exit would let it outlive its purpose. The
  # LOCKDIR (not the marker) is what serializes ticks during the relaunch, so clearing it here is safe;
  # the resume-after floor still gates the relaunch. If the relaunched run re-caps, it arms a fresh
  # marker/floor of its own.
  rm -f "$CAPPED" 2>/dev/null || true
  local out
  out="$(mktemp)"
  trap 'rm -rf "$LOCKDIR"; rm -f "${out:-}"' EXIT

  # NOTE (deferred → §5c): no crash-loop escalating backoff here — bounded retry-on-transient is the
  # §5c backlog item, out of scope for this swap-only land. A persistent cap is bounded by the
  # resume-after floor below; a persistent non-cap failure simply re-relaunches each tick.
  local claude_bin
  claude_bin="$(resolve_claude || true)"
  if [ -z "$claude_bin" ]; then
    log "claude not found (PATH=${PATH:-}) — cannot relaunch /surf resume"
    exit 1
  fi
  log "relaunching: (cd $REPO_ROOT) $claude_bin --dangerously-skip-permissions -p \"/surf resume\""
  # launchd sets no WorkingDirectory, so this script can run from `/` or `$HOME`. cd to the repo
  # root before relaunch so /surf resume — and /sail's cwd-relative run-dir discovery — resolve
  # against the right repo, not launchd's inherited cwd (#136 review).
  ( cd "$REPO_ROOT" && "$claude_bin" --dangerously-skip-permissions -p "/surf resume" ) >"$out" 2>&1 &
  claude_pid=$!
  printf '%s\n' "$claude_pid" >"$ACTIVE" 2>/dev/null || true
  wait "$claude_pid" || true
  cat "$out" >>"$LOG" 2>/dev/null || true

  # If the relaunched run hit the cap again, arm the shared resume-after floor so the next tick waits
  # rather than hot-looping. #163: ALL the floor logic — forward-only merge, wall-clock ceiling,
  # post-reset margin, the never-hot-loop MIN_BACKOFF floor, dual-horizon reset parse, and the
  # default-backoff on a parse-miss — lives in the single-source `sail cap-recovery arm` (no bash
  # floor math here). The watcher is issue-agnostic (whole-board resume), so it arms the GLOBAL
  # cap-state (no --issue). `arm` writes `$RESUME_AFTER` itself.
  if hit_cap "$out"; then
    local armed
    armed="$(cap_recovery arm --surf-dir "$SURF_DIR" --now "$(now_epoch)" --text-file "$out" || true)"
    log "cap hit; armed resume-after ${armed:-<arm returned nothing>}"
  else
    # Clean relaunch (no cap on the rerun): clear the shared floor + cap-state AND any self-relinquish
    # `capped` marker, so the next tick is not gated by stale state and a later healthy live session
    # is never mis-read as recoverable (#163 redteam). Safe because should_launch already passed.
    cap_recovery clear --surf-dir "$SURF_DIR" >/dev/null 2>&1 || true
    log "run finished without hitting the cap — cleared resume-after / cap-state / capped marker"
  fi

  # Takeover/cleanup: only remove the marker if it still names this relaunch's launch pid.
  # If the resumed /surf wrote its own pid into `.surf/active`, leave that ownership intact.
  if [ -n "${claude_pid:-}" ] && [ -f "$ACTIVE" ] && [ "$(cat "$ACTIVE" 2>/dev/null || true)" = "$claude_pid" ]; then
    rm -f "$ACTIVE" 2>/dev/null || true
  fi
  # lockdir + tmp removed by the EXIT trap.
}

# Run main only when executed directly — sourcing (e.g. the functional test) gets the functions
# without firing the watcher.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
