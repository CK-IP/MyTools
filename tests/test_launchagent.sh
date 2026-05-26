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

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
