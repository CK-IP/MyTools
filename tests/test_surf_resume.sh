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
cat >"$WORK/stubbin/tmux" <<STUB
#!/usr/bin/env bash
cmd="\$1"
case "\$cmd" in
  has-session)   exit 0 ;;
  display-message) echo '%0' ;;
  capture-pane)  cat "$CAP_FIXTURE" 2>/dev/null || true ;;
  send-keys)     echo "send-keys \$*" >> "$SENDKEYS_REC" ;;
  *)             exit 0 ;;
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
[ "$c" -eq 1 ] && pass "(a) stalled-then-reset → exactly one send-keys" || fail "(a) expected 1 send-keys, got $c"
[ ! -f "$WORK/.surf/resume-after" ] && pass "(a) floor disarmed after revive" || fail "(a) resume-after not disarmed"

# --- (b) currently capped, not armed → no send-keys, floor armed -------------
printf 'Claude usage limit reached. limit will reset at 2099-01-01T00:00:00Z\n' >"$CAP_FIXTURE"
rm -f "$WORK/.surf/resume-after"
run_watcher
c="$(sendkeys_count)"
[ "$c" -eq 0 ] && pass "(b) still-capped → no send-keys" || fail "(b) expected 0 send-keys, got $c"
[ -f "$WORK/.surf/resume-after" ] && pass "(b) resume-after armed from observed cap" || fail "(b) resume-after not armed"

# --- (c) healthy, not armed → no send-keys, no floor written -----------------
printf 'all good, working...\n' >"$CAP_FIXTURE"
rm -f "$WORK/.surf/resume-after"
run_watcher
c="$(sendkeys_count)"
[ "$c" -eq 0 ] && pass "(c) healthy session → no send-keys" || fail "(c) expected 0 send-keys, got $c"
[ ! -f "$WORK/.surf/resume-after" ] && pass "(c) no spurious resume-after on healthy session" || fail "(c) resume-after wrongly written"

# --- (d) LINGERING cap notice w/ PAST reset + armed crossed → revive, no re-arm-livelock
# Regression for the round-3 finding: a cap notice stays on the tail until we nudge; if its
# reset time has already passed it must NOT re-arm (which would push the floor forward forever
# and never revive). Expect exactly one send-keys and the floor disarmed.
printf 'Claude usage limit reached. limit will reset at 2020-01-01T00:00:00Z\n' >"$CAP_FIXTURE"
echo '2020-01-01T00:00:00Z' >"$WORK/.surf/resume-after"   # armed, and crossed (past)
run_watcher
c="$(sendkeys_count)"
[ "$c" -eq 1 ] && pass "(d) lingering-past-cap → revive (no livelock)" || fail "(d) expected 1 send-keys, got $c"
[ ! -f "$WORK/.surf/resume-after" ] && pass "(d) floor disarmed after lingering-cap revive" || fail "(d) resume-after not disarmed"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
