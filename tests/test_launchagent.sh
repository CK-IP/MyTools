#!/usr/bin/env bash
# test_launchagent.sh
# Structural assertions for LaunchAgent config files.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON_PLIST="$REPO_ROOT/config/com.crg.daemon.plist"
REMINDER_PLIST="$REPO_ROOT/config/com.crg.refresh-reminder.plist"
REMINDER_SCRIPT="$REPO_ROOT/config/refresh-reminder.sh"
INSTALL="$REPO_ROOT/INSTALL.md"
README="$REPO_ROOT/README.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- 1: daemon plist exists and non-empty ---
if [ -f "$DAEMON_PLIST" ] && [ -s "$DAEMON_PLIST" ]; then
  pass "config/com.crg.daemon.plist exists and is not empty"
else
  fail "config/com.crg.daemon.plist does not exist or is empty"
fi

# --- 2: reminder plist exists and non-empty ---
if [ -f "$REMINDER_PLIST" ] && [ -s "$REMINDER_PLIST" ]; then
  pass "config/com.crg.refresh-reminder.plist exists and is not empty"
else
  fail "config/com.crg.refresh-reminder.plist does not exist or is empty"
fi

# --- 3: reminder script exists and has set -euo pipefail ---
if [ -f "$REMINDER_SCRIPT" ] && grep -q "set -euo pipefail" "$REMINDER_SCRIPT" 2>/dev/null; then
  pass "refresh-reminder.sh exists and has set -euo pipefail"
else
  fail "refresh-reminder.sh missing or lacks set -euo pipefail"
fi

# --- 4: daemon plist contains code-review-graph ---
if grep -q "code-review-graph" "$DAEMON_PLIST" 2>/dev/null; then
  pass "daemon plist contains code-review-graph"
else
  fail "daemon plist does not contain code-review-graph"
fi

# --- 5: daemon plist contains RunAtLoad ---
if grep -q "RunAtLoad" "$DAEMON_PLIST" 2>/dev/null; then
  pass "daemon plist contains RunAtLoad"
else
  fail "daemon plist does not contain RunAtLoad"
fi

# --- 6: daemon plist contains KeepAlive ---
if grep -q "KeepAlive" "$DAEMON_PLIST" 2>/dev/null; then
  pass "daemon plist contains KeepAlive"
else
  fail "daemon plist does not contain KeepAlive"
fi

# --- 7: reminder plist contains StartCalendarInterval ---
if grep -q "StartCalendarInterval" "$REMINDER_PLIST" 2>/dev/null; then
  pass "reminder plist contains StartCalendarInterval"
else
  fail "reminder plist does not contain StartCalendarInterval"
fi

# --- 8: reminder script contains osascript (notification) ---
if grep -q "osascript" "$REMINDER_SCRIPT" 2>/dev/null; then
  pass "reminder script contains osascript"
else
  fail "reminder script does not contain osascript"
fi

# --- 9: daemon plist uses __UVX_PATH__ placeholder (portable) ---
if grep -q "__UVX_PATH__" "$DAEMON_PLIST" 2>/dev/null; then
  pass "daemon plist uses __UVX_PATH__ placeholder"
else
  fail "daemon plist does not use __UVX_PATH__ placeholder (hardcoded path)"
fi

# --- 10: INSTALL.md mentions launchctl ---
if grep -q "launchctl" "$INSTALL" 2>/dev/null; then
  pass "INSTALL.md mentions launchctl"
else
  fail "INSTALL.md does not mention launchctl"
fi

# --- 11: INSTALL.md mentions com.crg.daemon ---
if grep -q "com.crg.daemon" "$INSTALL" 2>/dev/null; then
  pass "INSTALL.md mentions com.crg.daemon"
else
  fail "INSTALL.md does not mention com.crg.daemon"
fi

# --- 12: README.md mentions auto-start or LaunchAgent ---
if grep -q "auto-start\|LaunchAgent" "$README" 2>/dev/null; then
  pass "README.md mentions auto-start or LaunchAgent"
else
  fail "README.md does not mention auto-start or LaunchAgent"
fi

# ===========================================================================
# Functional cases — interactive background-automation in install.sh + the
# doctor readiness section. Drive the REAL install.sh/doctor.sh in a sandbox
# HOME with launchctl stubbed; never touch the real ~/Library/LaunchAgents.
# Mirrors test_surf_resume_wrapper.sh: mktemp sandbox, trap cleanup, stubs on
# PATH. REC is a single cumulative recorder; each case truncates it at start so
# per-case verb assertions (bootstrap/bootout/list) stay isolated.
# ===========================================================================
INSTALL_SH="$REPO_ROOT/install.sh"
DOCTOR_SH="$REPO_ROOT/doctor.sh"

TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME"; }
trap cleanup EXIT

BIN="$TMP_HOME/bin"
LA_DIR="$TMP_HOME/LaunchAgents"
REC="$TMP_HOME/launchctl.log"
mkdir -p "$BIN" "$LA_DIR"

# Stub launchctl: record argv, always succeed (so bootout/bootstrap never abort
# under set -euo pipefail), emit nothing for `list`.
cat >"$BIN/launchctl" <<EOF
#!/usr/bin/env bash
printf 'LAUNCHCTL %s\n' "\$*" >>"$REC"
exit 0
EOF
chmod +x "$BIN/launchctl"

# Stub claude so doctor's required-tool check passes in the sandbox.
cat >"$BIN/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN/claude"

# --- Case A: non-TTY install auto-skips the whole section -------------------
: > "$REC"
rm -f "$LA_DIR"/*.plist 2>/dev/null || true
if HOME="$TMP_HOME" LAUNCHAGENTS_DIR="$LA_DIR" PATH="$BIN:$PATH" \
     bash "$INSTALL_SH" --no-tools </dev/null >/dev/null 2>&1; then arc=0; else arc=$?; fi
if [ "$arc" -eq 0 ] && ! ls "$LA_DIR"/*.plist >/dev/null 2>&1 && ! grep -q 'bootstrap' "$REC" 2>/dev/null; then
  pass "caseA: non-TTY install exits 0 and auto-skips background automation (no plists, no bootstrap)"
else
  fail "caseA: non-TTY install should exit 0 and auto-skip background automation (rc=$arc)"
fi

# --- Case B: CK_BG_FORCE + all-N installs nothing ---------------------------
: > "$REC"
rm -f "$LA_DIR"/*.plist 2>/dev/null || true
if HOME="$TMP_HOME" LAUNCHAGENTS_DIR="$LA_DIR" PATH="$BIN:$PATH" CK_BG_FORCE=1 \
     bash "$INSTALL_SH" --no-tools >/dev/null 2>&1 <<<$'n\nn\nn'; then brc=0; else brc=$?; fi
if [ "$brc" -eq 0 ] && ! ls "$LA_DIR"/*.plist >/dev/null 2>&1 && ! grep -q 'bootstrap' "$REC" 2>/dev/null; then
  pass "caseB: CK_BG_FORCE + all-N exits 0 and installs nothing"
else
  fail "caseB: CK_BG_FORCE + all-N should exit 0 and install nothing (rc=$brc)"
fi

# --- Case C: CK_BG_FORCE + y/n/y -> daemon + surf, reminder skipped ---------
: > "$REC"
rm -f "$LA_DIR"/*.plist 2>/dev/null || true
if HOME="$TMP_HOME" LAUNCHAGENTS_DIR="$LA_DIR" PATH="$BIN:$PATH" CK_BG_FORCE=1 \
     bash "$INSTALL_SH" --no-tools >/dev/null 2>&1 <<<$'y\nn\ny'; then crc=0; else crc=$?; fi
if [ "$crc" -eq 0 ] && [ -f "$LA_DIR/com.crg.daemon.plist" ] && [ -f "$LA_DIR/com.surf.resume.plist" ] \
   && [ ! -f "$LA_DIR/com.crg.refresh-reminder.plist" ]; then
  pass "caseC: y/n/y exits 0, installs daemon + surf, skips reminder"
else
  fail "caseC: y/n/y did not install the expected plists"
fi
if [ -f "$LA_DIR/com.crg.daemon.plist" ] && ! grep -q '__UVX_PATH__' "$LA_DIR/com.crg.daemon.plist"; then
  pass "caseC: daemon plist __UVX_PATH__ substituted"
else
  fail "caseC: daemon plist still has __UVX_PATH__ (or missing)"
fi
if [ -f "$LA_DIR/com.surf.resume.plist" ] && ! grep -q '__REPO_ROOT__' "$LA_DIR/com.surf.resume.plist" \
   && grep -qF "$REPO_ROOT" "$LA_DIR/com.surf.resume.plist"; then
  pass "caseC: surf plist __REPO_ROOT__ substituted with real path"
else
  fail "caseC: surf plist __REPO_ROOT__ not substituted correctly"
fi
if grep 'bootstrap' "$REC" 2>/dev/null | grep -q 'com.crg.daemon.plist' \
   && grep 'bootstrap' "$REC" 2>/dev/null | grep -q 'com.surf.resume.plist'; then
  pass "caseC: launchctl bootstrap recorded for daemon + surf"
else
  fail "caseC: launchctl bootstrap not recorded for both agents"
fi

# --- Case D: idempotent re-run of Case C ------------------------------------
: > "$REC"
if HOME="$TMP_HOME" LAUNCHAGENTS_DIR="$LA_DIR" PATH="$BIN:$PATH" CK_BG_FORCE=1 \
     bash "$INSTALL_SH" --no-tools >/dev/null 2>&1 <<<$'y\nn\ny'; then
  drc=0
else
  drc=$?
fi
if [ "$drc" -eq 0 ] && [ -f "$LA_DIR/com.crg.daemon.plist" ]; then
  pass "caseD: idempotent re-run succeeds, plist still present"
else
  fail "caseD: idempotent re-run failed (rc=$drc)"
fi
if grep -q 'bootout.*com.crg.daemon' "$REC" 2>/dev/null; then
  pass "caseD: bootout issued on re-run (idempotent reload path)"
else
  fail "caseD: no bootout recorded on re-run"
fi

# --- Case E: doctor readiness section, exit 0 preserved ---------------------
# Setup run creates ~/.claude symlinks (Step [4/4] auto-skips on </dev/null);
# this also fires install.sh's embedded doctor.sh, hence output suppression.
if HOME="$TMP_HOME" LAUNCHAGENTS_DIR="$LA_DIR" PATH="$BIN:$PATH" \
     bash "$INSTALL_SH" --no-tools </dev/null >/dev/null 2>&1; then esetuprc=0; else esetuprc=$?; fi
if [ "$esetuprc" -eq 0 ]; then
  pass "caseE: setup install run exits 0"
else
  fail "caseE: setup install run failed (rc=$esetuprc)"
fi
: > "$REC"
if dout="$(HOME="$TMP_HOME" PATH="$BIN:$PATH" bash "$DOCTOR_SH" 2>&1)"; then
  erc=0
else
  erc=$?
fi
if [ "$erc" -eq 0 ]; then
  pass "caseE: doctor exits 0 with readiness section"
else
  fail "caseE: doctor exit code changed (rc=$erc)"
fi
if printf '%s' "$dout" | grep -q 'Background agents'; then
  pass "caseE: doctor prints 'Background agents + /surf readiness' section"
else
  fail "caseE: doctor missing readiness section header"
fi
if printf '%s' "$dout" | grep -q 'com.surf.resume' && printf '%s' "$dout" | grep -q '/surf engine'; then
  pass "caseE: doctor reports com.surf.resume and /surf engine"
else
  fail "caseE: doctor missing surf readiness lines"
fi
if grep -q 'list' "$REC" 2>/dev/null; then
  pass "caseE: doctor invoked launchctl list"
else
  fail "caseE: doctor did not invoke launchctl list"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
