#!/usr/bin/env bash
# test_surf_resume.sh — functional test for config/surf-resume.sh, the /surf revive watcher.
#
# Stubs `tmux` (has-session / capture-pane / send-keys / display-message) and seeds a temp .surf/
# so we can assert the watcher's stall-evidence state machine WITHOUT a real tmux session or any
# Claude call:
#   (a) armed + reset crossed (stalled-then-reset) → exactly ONE send-keys, floor disarmed.
#   (b) currently capped, not armed                → NO send-keys, resume-after gets armed.
#   (c) healthy session, not armed                 → NO send-keys, no resume-after written.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_SRC="$SRC_DIR/config/surf-resume.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

[ -f "$SCRIPT_SRC" ] || { echo "FAIL: surf-resume.sh not found at $SCRIPT_SRC"; exit 1; }

# --- scratch repo + tmux stub -------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/config" "$WORK/.surf" "$WORK/stubbin"
cp "$SCRIPT_SRC" "$WORK/config/surf-resume.sh"
chmod +x "$WORK/config/surf-resume.sh"

SENDKEYS_REC="$WORK/sendkeys.log"
CAP_FIXTURE="$WORK/pane.txt"
: >"$SENDKEYS_REC"

# Stub tmux: capture-pane prints the fixture; send-keys is recorded; has-session/display succeed.
# Multi-pane (#119): list-panes enumerates the live set ($WORK/panes.txt, one id per line, default
# just the orchestrator '%0' so legacy single-pane cases are unchanged); capture-pane honors a
# per-pane fixture ($WORK/pane-<id>.txt) when present, else falls back to the shared $CAP_FIXTURE.
cat >"$WORK/stubbin/tmux" <<STUB
#!/usr/bin/env bash
cmd="\$1"
# Resolve a '-t <target>' anywhere in the args (per-pane capture / send-keys support).
target=""; prev=""
for a in "\$@"; do [ "\$prev" = "-t" ] && target="\$a"; prev="\$a"; done
case "\$cmd" in
  has-session)     [ -n "\${TMUX_NO_SESSION:-}" ] && exit 1 || exit 0 ;;
  display-message) echo '%0' ;;
  list-panes)      if [ -f "$WORK/panes.txt" ]; then cat "$WORK/panes.txt"; else echo '%0'; fi ;;
  capture-pane)    if [ -n "\$target" ] && [ -f "$WORK/pane-\${target}.txt" ]; then cat "$WORK/pane-\${target}.txt"; else cat "$CAP_FIXTURE" 2>/dev/null || true; fi ;;
  send-keys)       echo "send-keys \$*" >> "$SENDKEYS_REC" ;;
  *)               exit 0 ;;
esac
STUB
chmod +x "$WORK/stubbin/tmux"

run_watcher() {
  # Fresh per-scenario state: live PID marker (this test process is alive), a charter so
  # work_remains() is true, a recorded orchestrator pane, no lock.
  rm -rf "$WORK/.surf/resume.lock"
  echo "$$" >"$WORK/.surf/active"
  echo '%0'  >"$WORK/.surf/orchestrator-pane"
  printf '# charter\n- mission: test\n' >"$WORK/.surf/charter-20260101T000000.md"
  : >"$SENDKEYS_REC"
  PATH="$WORK/stubbin:$PATH" \
    SURF_RESUME_SESSION=surf \
    SURF_RESUME_LOG="$WORK/.surf/watch.log" \
    bash "$WORK/config/surf-resume.sh" >/dev/null 2>&1 || true
}

sendkeys_count() { grep -c 'send-keys' "$SENDKEYS_REC" 2>/dev/null | head -1 || true; }

# --- (a) armed + reset crossed → exactly one send-keys, floor disarmed -------
printf 'all good, working...\n' >"$CAP_FIXTURE"          # healthy current screen
echo '2020-01-01T00:00:00Z' >"$WORK/.surf/resume-after"  # armed floor in the past
run_watcher
c="$(sendkeys_count)"
if [ "$c" -eq 1 ]; then pass "(a) stalled-then-reset → exactly one send-keys"; else fail "(a) expected 1 send-keys, got $c"; fi
if [ ! -f "$WORK/.surf/resume-after" ]; then pass "(a) floor disarmed after revive"; else fail "(a) resume-after not disarmed"; fi

# --- (b) currently capped, not armed → no send-keys, floor armed -------------
printf 'Claude usage limit reached. limit will reset at 2099-01-01T00:00:00Z\n' >"$CAP_FIXTURE"
rm -f "$WORK/.surf/resume-after"
run_watcher
c="$(sendkeys_count)"
if [ "$c" -eq 0 ]; then pass "(b) still-capped → no send-keys"; else fail "(b) expected 0 send-keys, got $c"; fi
if [ -f "$WORK/.surf/resume-after" ]; then pass "(b) resume-after armed from observed cap"; else fail "(b) resume-after not armed"; fi

# --- (c) healthy, not armed → no send-keys, no floor written -----------------
printf 'all good, working...\n' >"$CAP_FIXTURE"
rm -f "$WORK/.surf/resume-after"
run_watcher
c="$(sendkeys_count)"
if [ "$c" -eq 0 ]; then pass "(c) healthy session → no send-keys"; else fail "(c) expected 0 send-keys, got $c"; fi
if [ ! -f "$WORK/.surf/resume-after" ]; then pass "(c) no spurious resume-after on healthy session"; else fail "(c) resume-after wrongly written"; fi

# --- (d) LINGERING cap notice w/ PAST reset + armed crossed → revive, no re-arm-livelock
# Regression for the round-3 finding: a cap notice stays on the tail until we nudge; if its
# reset time has already passed it must NOT re-arm (which would push the floor forward forever
# and never revive). Expect exactly one send-keys and the floor disarmed.
printf 'Claude usage limit reached. limit will reset at 2020-01-01T00:00:00Z\n' >"$CAP_FIXTURE"
echo '2020-01-01T00:00:00Z' >"$WORK/.surf/resume-after"   # armed, and crossed (past)
run_watcher
c="$(sendkeys_count)"
if [ "$c" -eq 1 ]; then pass "(d) lingering-past-cap → revive (no livelock)"; else fail "(d) expected 1 send-keys, got $c"; fi
if [ ! -f "$WORK/.surf/resume-after" ]; then pass "(d) floor disarmed after lingering-cap revive"; else fail "(d) resume-after not disarmed"; fi

# --- Gate coverage (#57 cleanup — reconciled from the retired test_surf_resume_wrapper.sh).
# should_revive must be CLOSED (no send-keys) when work_remains is false or there is no LIVE
# session. These replace the old relauncher's launch-gating cases under #73's revive model.
gate_setup() {  # fresh state: armed+crossed floor + healthy pane (so ONLY the gate can stop a revive)
  rm -rf "$WORK/.surf/resume.lock"
  echo '%0' >"$WORK/.surf/orchestrator-pane"
  printf '# charter\n- mission: test\n' >"$WORK/.surf/charter-20260101T000000.md"
  rm -f "$WORK/.surf/charter-20260101T000000.md-done"
  printf 'all good, working...\n' >"$CAP_FIXTURE"
  echo '2020-01-01T00:00:00Z' >"$WORK/.surf/resume-after"
  : >"$SENDKEYS_REC"
}
gate_run() { PATH="$WORK/stubbin:$PATH" SURF_RESUME_SESSION=surf SURF_RESUME_LOG="$WORK/.surf/watch.log" "$@" bash "$WORK/config/surf-resume.sh" >/dev/null 2>&1 || true; }

# (e) done-marker present → work_remains false → gate closed → no revive
gate_setup; echo "$$" >"$WORK/.surf/active"; touch "$WORK/.surf/charter-20260101T000000.md-done"
gate_run
c="$(sendkeys_count)"
if [ "$c" -eq 0 ]; then pass "(e) done-marker → gate closed, no revive"; else fail "(e) expected 0 send-keys, got $c"; fi

# (f) stale/dead .surf/active PID → no live session → gate closed → no revive (#73 semantics flip)
gate_setup; echo '999999' >"$WORK/.surf/active"
gate_run
c="$(sendkeys_count)"
if [ "$c" -eq 0 ]; then pass "(f) dead .surf/active pid → no live session, no revive"; else fail "(f) expected 0 send-keys, got $c"; fi

# (g) no tmux session (has-session fails) → no live session → gate closed → no revive
gate_setup; echo "$$" >"$WORK/.surf/active"
gate_run env TMUX_NO_SESSION=1
c="$(sendkeys_count)"
if [ "$c" -eq 0 ]; then pass "(g) no tmux session → no live session, no revive"; else fail "(g) expected 0 send-keys, got $c"; fi

# --- Multi-pane teammate-cap awareness (#119) --------------------------------
# The watcher must enumerate ALL live panes (orchestrator + teammates), arm from whichever pane
# is capped, persist the capped pane id(s) across the arm/revive tick gap, and nudge the pane that
# actually stalled — not a fixed orchestrator-only target.
multipane_reset() {  # clear only the multi-pane fixtures; run_watcher re-seeds active/charter/orch-pane
  rm -f "$WORK"/pane-*.txt "$WORK/panes.txt" "$WORK/.surf/resume-panes" "$WORK/.surf/resume-after"
}

# (h) teammate pane capped while orchestrator is idle → arm + record the teammate pane, NO nudge
multipane_reset
printf '%%0\n%%1\n' >"$WORK/panes.txt"
printf 'all good, working...\n' >"$WORK/pane-%0.txt"
printf 'Claude usage limit reached. limit will reset at 2099-01-01T00:00:00Z\n' >"$WORK/pane-%1.txt"
run_watcher
c="$(sendkeys_count)"
if [ "$c" -eq 0 ]; then pass "(h) teammate capped, orch idle → no send-keys (arming tick)"; else fail "(h) expected 0 send-keys, got $c"; fi
if [ -s "$WORK/.surf/resume-after" ]; then pass "(h) resume-after armed from teammate pane"; else fail "(h) resume-after not armed"; fi
if grep -q '%1' "$WORK/.surf/resume-panes" 2>/dev/null; then pass "(h) resume-panes records teammate pane %1"; else fail "(h) resume-panes missing teammate pane id"; fi

# (i) armed + floor crossed with a recorded teammate pane → exactly one nudge to THAT pane, disarm both
multipane_reset
printf '%%0\n%%1\n' >"$WORK/panes.txt"
printf 'all good, working...\n' >"$WORK/pane-%0.txt"
printf 'all good, working...\n' >"$WORK/pane-%1.txt"
echo '%1' >"$WORK/.surf/resume-panes"
echo '2020-01-01T00:00:00Z' >"$WORK/.surf/resume-after"
run_watcher
c="$(sendkeys_count)"
if [ "$c" -eq 1 ]; then pass "(i) revive → exactly one send-keys"; else fail "(i) expected 1 send-keys, got $c"; fi
if grep -q 'send-keys.*-t %1' "$SENDKEYS_REC" 2>/dev/null; then pass "(i) send-keys targets recorded teammate pane %1"; else fail "(i) send-keys not targeted at %1"; fi
if [ ! -f "$WORK/.surf/resume-after" ]; then pass "(i) resume-after disarmed"; else fail "(i) resume-after not removed"; fi
if [ ! -f "$WORK/.surf/resume-panes" ]; then pass "(i) resume-panes disarmed"; else fail "(i) resume-panes not removed"; fi

# (j) REAL weekly-cap message (secondary #3) → detected as capped, arms a FUTURE floor, no nudge
multipane_reset
printf '%%0\n' >"$WORK/panes.txt"
printf '%s\n' "You've hit your weekly limit · resets 8pm (America/New_York)" "/usage-credits to request more usage from your admin." >"$WORK/pane-%0.txt"
run_watcher
c="$(sendkeys_count)"
if [ "$c" -eq 0 ]; then pass "(j) weekly cap → no send-keys (arming tick)"; else fail "(j) expected 0 send-keys, got $c"; fi
if [ -s "$WORK/.surf/resume-after" ]; then pass "(j) weekly-cap message detected → resume-after armed"; else fail "(j) weekly cap not detected/armed"; fi
ra="$(cat "$WORK/.surf/resume-after" 2>/dev/null || true)"
rae="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ra" "+%s" 2>/dev/null || date -u -d "$ra" "+%s" 2>/dev/null || echo 0)"
if [ "${rae:-0}" -gt "$(date +%s)" ]; then pass "(j) weekly-cap floor is in the future"; else fail "(j) floor not in future ($ra)"; fi

# (k) multiple recorded capped panes → one nudge each
multipane_reset
printf '%%0\n%%1\n%%2\n' >"$WORK/panes.txt"
printf 'all good\n' >"$WORK/pane-%0.txt"; printf 'all good\n' >"$WORK/pane-%1.txt"; printf 'all good\n' >"$WORK/pane-%2.txt"
printf '%%1\n%%2\n' >"$WORK/.surf/resume-panes"
echo '2020-01-01T00:00:00Z' >"$WORK/.surf/resume-after"
run_watcher
c="$(sendkeys_count)"
if [ "$c" -eq 2 ]; then pass "(k) two recorded panes → two send-keys"; else fail "(k) expected 2 send-keys, got $c"; fi

# (l) benign text containing 'resets'/'presets' must NOT be misread as a cap (precision; #119 review)
# Guards against an over-broad hit_cap pattern matching the bare substring 'resets' (e.g. 'presets').
multipane_reset
printf '%%0\n' >"$WORK/panes.txt"
printf '%s\n' "Applied 3 presets; the counter resets the value each run." >"$WORK/pane-%0.txt"
run_watcher
c="$(sendkeys_count)"
if [ "$c" -eq 0 ]; then pass "(l) benign 'presets/resets' text → no send-keys"; else fail "(l) expected 0 send-keys, got $c"; fi
if [ ! -f "$WORK/.surf/resume-after" ]; then pass "(l) benign text → not misread as a cap (no arm)"; else fail "(l) benign text wrongly armed resume-after"; fi

# (m) LINGERING relative (am/pm) cap notice + armed-and-crossed floor → revive once, no re-arm livelock
# Regression for the #119 round-2 red-team HIGH: parse_reset_time rolls 'resets 8pm' FORWARD to a
# future epoch, so a lingering weekly-cap notice (still on the tail after the real reset) must NOT be
# re-armed as a fresh cap — else state 2 never fires and the watcher never revives after a weekly cap.
multipane_reset
printf '%%0\n' >"$WORK/panes.txt"
printf '%s\n' "You've hit your weekly limit · resets 8pm (America/New_York)" >"$WORK/pane-%0.txt"
echo '%0' >"$WORK/.surf/resume-panes"                     # capped pane recorded at the arming tick
echo '2020-01-01T00:00:00Z' >"$WORK/.surf/resume-after"   # armed, and crossed (past)
run_watcher
c="$(sendkeys_count)"
if [ "$c" -eq 1 ]; then pass "(m) lingering am/pm cap + crossed floor → revive once (no livelock)"; else fail "(m) expected 1 send-keys, got $c"; fi
if [ ! -f "$WORK/.surf/resume-after" ]; then pass "(m) floor disarmed after lingering am/pm revive"; else fail "(m) resume-after not disarmed"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
