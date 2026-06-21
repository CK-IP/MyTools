#!/usr/bin/env bash
# test_surf_resume_wrapper.sh
# Functional test of config/surf-resume.sh's pure-shell gate + reset capture.
# Mirrors test_sail_runner.sh: mktemp REPO_ROOT, trap cleanup, PASS/FAIL counters,
# claude stubbed on PATH via a recorder, backoff/age constants env-overridden.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$REPO_ROOT/config/surf-resume.sh"

PASS=0
FAIL=0

pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
}

# Each case gets a fresh fake repo root, a fresh stubbed `claude`, and a fresh
# PATH so the wrapper sees our recorder rather than a real CLI.
TMP_ROOT="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# Small backoff/age constants so the test runs fast but the floor logic is exercised.
# DEFAULT_BACKOFF is deliberately large (the "long default" on a parse-miss).
export SURF_RESUME_MIN_BACKOFF=60          # 1 min floor
export SURF_RESUME_DEFAULT_BACKOFF=36000   # 10h long default
export SURF_RESUME_MAX_RUN_AGE=2           # 2s -> easy to make a lock "stale"

# now-epoch + RFC3339 helpers (BSD/GNU date compatible enough for our use)
now_epoch() { date +%s; }
rfc3339_at() {
  # $1 = epoch offset (may be negative)
  local target=$(( $(now_epoch) + $1 ))
  if date -u -r "$target" "+%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
    date -u -r "$target" "+%Y-%m-%dT%H:%M:%SZ"
  else
    date -u -d "@$target" "+%Y-%m-%dT%H:%M:%SZ"
  fi
}
epoch_of_rfc3339() {
  # $1 = RFC3339 Z timestamp -> epoch
  if date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" "+%s" >/dev/null 2>&1; then
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" "+%s"
  else
    date -u -d "$1" "+%s"
  fi
}

# Build a fresh fake repo + stubbed claude. Echoes the case dir.
# $1 = case name, $2 = stub-output mode (none|cap-unparseable|cap-parseable|ok)
setup_case() {
  local name="$1" stub_mode="$2"
  local dir="$TMP_ROOT/$name"
  mkdir -p "$dir/config" "$dir/.surf" "$dir/bin"

  # Copy the real wrapper into the fake repo so REPO_ROOT resolves to $dir.
  cp "$WRAPPER" "$dir/config/surf-resume.sh"
  chmod +x "$dir/config/surf-resume.sh"

  # A charter with a journal in the REAL prescribed format: append-only merge-outcome
  # lines and NO done-marker. Per surf.md Step 16, charter-present + no-done-marker IS
  # "real unfinished work" — that's what the gate requires (and HIGH-1's regression guard).
  cat >"$dir/.surf/charter-20260101-000000.md" <<'EOF'
# Charter
Mission: clear the sandbox board.
Run mode: Autonomous
EOF
  cat >"$dir/.surf/journal-20260101-000000.md" <<'EOF'
# Journal
- merged #10 abc1230
- merged #11 abc1231
EOF

  # Stub `claude` on PATH: APPENDS one delimited marker line per invocation (so a
  # double-launch regression is detectable by count), then emits the requested output.
  local rec="$dir/claude-argv.log"
  case "$stub_mode" in
    cap-unparseable)
      cat >"$dir/bin/claude" <<EOF
#!/usr/bin/env bash
printf 'INVOKE %s\n' "\$*" >>"$rec"
echo "You've hit your usage limit. Try again later."
EOF
      ;;
    cap-parseable)
      # Reset 30 min from now, embedded in a recognizable phrase.
      local reset_ts
      reset_ts="$(rfc3339_at 1800)"
      cat >"$dir/bin/claude" <<EOF
#!/usr/bin/env bash
printf 'INVOKE %s\n' "\$*" >>"$rec"
echo "Usage limit reached. Your limit will reset at $reset_ts."
EOF
      ;;
    cap-anchored)
      # Output contains an EARLIER unrelated RFC3339 (an echoed resume marker) BEFORE
      # the cap line, whose reset timestamp is LATER. The anchored parser must pick the
      # cap-line timestamp, not the earlier resume-marker one.
      local early_ts late_ts
      early_ts="$(rfc3339_at 120)"     # ~2 min out, unrelated
      late_ts="$(rfc3339_at 1800)"     # ~30 min out, the real reset
      cat >"$dir/bin/claude" <<EOF
#!/usr/bin/env bash
printf 'INVOKE %s\n' "\$*" >>"$rec"
echo "- ↺ resume $early_ts"
echo "Usage limit reached. Your limit will reset at $late_ts."
EOF
      ;;
    *)
      cat >"$dir/bin/claude" <<EOF
#!/usr/bin/env bash
printf 'INVOKE %s\n' "\$*" >>"$rec"
echo "resume complete, board worked"
EOF
      ;;
  esac
  chmod +x "$dir/bin/claude"
  echo "$dir"
}

run_wrapper() {
  # $1 = case dir. Runs the wrapper with stub on PATH; never aborts the test.
  local dir="$1"
  ( PATH="$dir/bin:$PATH" SURF_RESUME_LOG="$dir/surf-resume.log" \
      bash "$dir/config/surf-resume.sh" ) >/dev/null 2>&1 || true
}

stub_invoked() {
  # $1 = case dir -> 0 if the claude stub recorded an argv
  [ -s "$1/claude-argv.log" ]
}

# ---------------------------------------------------------------------------
# Case 1: future resume-after -> no launch
# ---------------------------------------------------------------------------
d="$(setup_case future_resume_after ok)"
rfc3339_at 3600 >"$d/.surf/resume-after"
run_wrapper "$d"
stub_invoked "$d" && fail "case1: future resume-after should NOT launch" \
  || pass "case1: future resume-after -> no launch"

# ---------------------------------------------------------------------------
# Case 2: fresh lockdir -> no launch
# ---------------------------------------------------------------------------
d="$(setup_case fresh_lock ok)"
mkdir "$d/.surf/resume.lock"   # held now, well within MAX_RUN_AGE
run_wrapper "$d"
stub_invoked "$d" && fail "case2: fresh lock should NOT launch" \
  || pass "case2: fresh lockdir -> no launch"

# ---------------------------------------------------------------------------
# Case 3: stale lockdir (older than MAX_RUN_AGE) -> reclaimed + launches
# ---------------------------------------------------------------------------
d="$(setup_case stale_lock ok)"
mkdir "$d/.surf/resume.lock"
# Age the lockdir beyond MAX_RUN_AGE (2s).
sleep 3
run_wrapper "$d"
stub_invoked "$d" && pass "case3: stale lockdir reclaimed -> launches" \
  || fail "case3: stale lockdir should be reclaimed and launch"

# ---------------------------------------------------------------------------
# Case 4: past/absent resume-after + no lock + unfinished work -> launch once,
#         argv carries --dangerously-bypass-permissions and /surf resume.
# ---------------------------------------------------------------------------
d="$(setup_case happy_launch ok)"
# No resume-after file at all (absent) and no lock.
run_wrapper "$d"
if stub_invoked "$d"; then
  pass "case4: launches when work remains + no lock + no resume-after"
  if grep -qF -- '--dangerously-bypass-permissions' "$d/claude-argv.log"; then
    pass "case4: argv carries --dangerously-bypass-permissions"
  else
    fail "case4: argv missing --dangerously-bypass-permissions"
  fi
  if grep -qF -- '/surf resume' "$d/claude-argv.log"; then
    pass "case4: argv carries /surf resume"
  else
    fail "case4: argv missing /surf resume"
  fi
  # invoked exactly once: recorder APPENDS one INVOKE marker per call, so the count
  # is a real assertion — a double-launch regression would push it above 1.
  if [ "$(grep -c '^INVOKE ' "$d/claude-argv.log")" -eq 1 ]; then
    pass "case4: stub invoked exactly once"
  else
    fail "case4: stub invoked more than once"
  fi
else
  fail "case4: should launch but stub not invoked"
  fail "case4: argv missing --dangerously-bypass-permissions"
  fail "case4: argv missing /surf resume"
  fail "case4: stub invoked exactly once"
fi

# ---------------------------------------------------------------------------
# Case 5: board done-marker present -> no launch even past resume-after
# ---------------------------------------------------------------------------
d="$(setup_case done_marker ok)"
rfc3339_at -3600 >"$d/.surf/resume-after"   # in the past
# Mark the run done so the work-remaining gate goes quiet.
echo "- done: board exhausted $(rfc3339_at 0)" >>"$d/.surf/journal-20260101-000000.md"
touch "$d/.surf/charter-20260101-000000.md-done"
run_wrapper "$d"
stub_invoked "$d" && fail "case5: done-marker should suppress launch" \
  || pass "case5: done-marker -> no launch even past resume-after"

# ---------------------------------------------------------------------------
# Case 6: unparseable cap output -> resume-after = long DEFAULT_BACKOFF, lock cleared
# ---------------------------------------------------------------------------
d="$(setup_case cap_unparseable cap-unparseable)"
run_wrapper "$d"
if stub_invoked "$d" && [ -f "$d/.surf/resume-after" ]; then
  ra_epoch="$(epoch_of_rfc3339 "$(cat "$d/.surf/resume-after")")"
  # Expect it far out: at least MIN_BACKOFF beyond now, and near DEFAULT_BACKOFF
  # (not a near-term hot loop). Assert > 1h out (DEFAULT_BACKOFF is 10h).
  if [ "$ra_epoch" -gt "$(( $(now_epoch) + 3600 ))" ]; then
    pass "case6: unparseable cap -> long DEFAULT_BACKOFF resume-after"
  else
    fail "case6: unparseable cap -> resume-after too near (hot-loop risk)"
  fi
else
  fail "case6: unparseable cap -> resume-after not written"
fi
if [ ! -d "$d/.surf/resume.lock" ]; then
  pass "case6: lockdir cleared after run"
else
  fail "case6: lockdir not cleared after run"
fi

# ---------------------------------------------------------------------------
# Case 7: parseable reset time -> resume-after = max(parsed, now+MIN_BACKOFF)
# ---------------------------------------------------------------------------
d="$(setup_case cap_parseable cap-parseable)"
run_wrapper "$d"
if stub_invoked "$d" && [ -f "$d/.surf/resume-after" ]; then
  ra_epoch="$(epoch_of_rfc3339 "$(cat "$d/.surf/resume-after")")"
  floor_epoch="$(( $(now_epoch) + SURF_RESUME_MIN_BACKOFF ))"
  # Parsed reset was ~30 min (1800s) out, well above the 60s floor -> parsed wins.
  if [ "$ra_epoch" -ge "$floor_epoch" ] && [ "$ra_epoch" -gt "$(( $(now_epoch) + 600 ))" ]; then
    pass "case7: parseable reset -> resume-after honors parsed time above floor"
  else
    fail "case7: parseable reset -> resume-after not at max(parsed, floor)"
  fi
else
  fail "case7: parseable reset -> resume-after not written"
fi

# ---------------------------------------------------------------------------
# Case 8: charter + journal with ONLY merge-outcome lines + NO done-marker
#         -> LAUNCHES. This is HIGH-1's regression guard: the simplified
#         work_remains must treat charter-present + no-done-marker as work.
# ---------------------------------------------------------------------------
d="$(setup_case merge_only_no_done ok)"
# Fixture is already merge-only + no done-marker; no resume-after, no lock.
run_wrapper "$d"
stub_invoked "$d" && pass "case8: merge-only journal + no done-marker -> launches (HIGH-1 guard)" \
  || fail "case8: merge-only journal + no done-marker should launch"

# ---------------------------------------------------------------------------
# Case 9: live .surf/active (PID of a real running process) -> NO launch,
#         even with work remaining and no resume-after/lock.
# ---------------------------------------------------------------------------
d="$(setup_case live_active ok)"
sleep 30 &
live_pid=$!
echo "$live_pid" >"$d/.surf/active"
run_wrapper "$d"
if stub_invoked "$d"; then
  fail "case9: live .surf/active should suppress launch"
else
  pass "case9: live .surf/active -> no launch"
fi
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Case 10: stale .surf/active (dead PID) -> NOT blocked by it; launches.
# ---------------------------------------------------------------------------
d="$(setup_case stale_active ok)"
echo "999999" >"$d/.surf/active"   # almost certainly not a live PID
run_wrapper "$d"
if stub_invoked "$d"; then
  pass "case10: stale .surf/active -> not blocked, launches"
else
  fail "case10: stale .surf/active should not block launch"
fi
if [ ! -f "$d/.surf/active" ]; then
  pass "case10: stale .surf/active cleaned"
else
  fail "case10: stale .surf/active not cleaned"
fi

# ---------------------------------------------------------------------------
# Case 11: anchored reset parse -> an EARLIER unrelated RFC3339 (echoed resume
#          marker) precedes the cap line whose timestamp is LATER. resume-after
#          must lock onto the cap-line timestamp, not the earlier one.
# ---------------------------------------------------------------------------
d="$(setup_case cap_anchored cap-anchored)"
run_wrapper "$d"
if stub_invoked "$d" && [ -f "$d/.surf/resume-after" ]; then
  ra_epoch="$(epoch_of_rfc3339 "$(cat "$d/.surf/resume-after")")"
  # The earlier (wrong) marker was ~120s out; the real cap reset ~1800s out.
  # Anchored parse + max(parsed, now+60 floor) must land well past the 120s decoy.
  if [ "$ra_epoch" -gt "$(( $(now_epoch) + 600 ))" ]; then
    pass "case11: anchored parse picks cap-line timestamp, not earlier decoy"
  else
    fail "case11: anchored parse locked onto the earlier decoy timestamp"
  fi
else
  fail "case11: anchored cap -> resume-after not written"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
