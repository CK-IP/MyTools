#!/usr/bin/env bash
# test_surf_resume.sh — functional test for config/surf-resume.sh, the /surf cap-recovery watcher.
#
# #124 INVERSION: the default cap-recovery is now the durable-file HEADLESS RELAUNCH of
# `/surf resume` (the proven #53 LaunchAgent model), NOT a persistent-tmux `send-keys` revive.
# A headless `claude -p` process can host /sail's crew (depth-0 subagents), so the headless
# relaunch is viable again. This test stubs `claude` on PATH and seeds a temp .surf/ to assert
# the watcher's pure-bash gate + reset-capture WITHOUT any real Claude call:
#   (a) gate open (charter, no done-marker, no live session, floor passed) → exactly ONE relaunch.
#   (b) currently capped on relaunch → resume-after armed to a FUTURE floor, no hot-loop.
#   (c) done-marker present → gate closed → NO relaunch.
#   (d) live .surf/active PID → a /surf already running → NO relaunch.
#   (e) armed resume-after still in the future → NO relaunch (waiting).
# The #86 charter-scoping of work_remains() (sortable suffix, scoped journal) is exercised by
# tests/test_surf.sh S16b/S16c, which source this script's functions directly.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_SRC="$SRC_DIR/config/surf-resume.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

[ -f "$SCRIPT_SRC" ] || { echo "FAIL: surf-resume.sh not found at $SCRIPT_SRC"; exit 1; }

# Small constants so the floor logic runs fast.
export SURF_RESUME_MIN_BACKOFF=60          # 1 min floor
export SURF_RESUME_DEFAULT_BACKOFF=36000   # 10h long default
export SURF_RESUME_MAX_RUN_AGE=2           # 2s -> easy to make a lock stale

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/config" "$WORK/.surf" "$WORK/bin"
cp "$SCRIPT_SRC" "$WORK/config/surf-resume.sh"
chmod +x "$WORK/config/surf-resume.sh"

CLAUDE_REC="$WORK/claude-argv.log"
: >"$CLAUDE_REC"

now_epoch() { date +%s; }
rfc3339_at() {
  local target=$(( $(now_epoch) + $1 ))
  date -u -r "$target" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "@$target" "+%Y-%m-%dT%H:%M:%SZ"
}

# Stub `claude` on PATH: records one INVOKE line per call (so a double-relaunch is countable),
# then emits the requested output ($CLAUDE_OUT) so the cap-capture path can be exercised.
cat >"$WORK/bin/claude" <<STUB
#!/usr/bin/env bash
printf 'INVOKE %s\n' "\$*" >>"$CLAUDE_REC"
printf 'CWD %s\n' "\$(pwd -P)" >>"$CLAUDE_REC"
printf '%s\n' "\${CLAUDE_OUT:-run finished cleanly}"
STUB
chmod +x "$WORK/bin/claude"

seed_charter() {
  printf '# charter\n- mission: test\n' >"$WORK/.surf/charter-20260101T000000.md"
  printf '# journal\n- merged #10 abc1230\n' >"$WORK/.surf/journal-20260101T000000.md"
}

run_watcher() {
  rm -rf "$WORK/.surf/resume.lock"
  run_watcher_keeplock
}

# Same as run_watcher but does NOT clear a pre-seeded lockdir (for the R5-4 stale-lock cases).
run_watcher_keeplock() {
  : >"$CLAUDE_REC"
  PATH="$WORK/bin:$PATH" \
    SURF_RESUME_LOG="$WORK/.surf/watch.log" \
    SURF_RESUME_MAX_RUN_AGE="${SURF_RESUME_MAX_RUN_AGE:-7200}" \
    CLAUDE_OUT="${CLAUDE_OUT:-run finished cleanly}" \
    bash "$WORK/config/surf-resume.sh" >/dev/null 2>&1 || true
}

invoke_count() { grep -c 'INVOKE' "$CLAUDE_REC" 2>/dev/null | head -1 || true; }

# --- (a) gate open → exactly ONE headless relaunch of `/surf resume` -----------
seed_charter
rm -f "$WORK/.surf/active" "$WORK/.surf/resume-after"
run_watcher
c="$(invoke_count)"
if [ "$c" -eq 1 ]; then pass "(a) gate open → exactly one claude relaunch"; else fail "(a) expected 1 relaunch, got $c"; fi
if grep -q -- '-p .*/surf resume' "$CLAUDE_REC" 2>/dev/null; then pass "(a) relaunch invokes \"/surf resume\""; else fail "(a) relaunch did not invoke /surf resume"; fi
if grep -q -- '--dangerously-skip-permissions' "$CLAUDE_REC" 2>/dev/null; then pass "(a) relaunch carries --dangerously-skip-permissions"; else fail "(a) skip-permissions flag not carried on relaunch"; fi
# #136 review: the relaunch must `cd "$REPO_ROOT"` (launchd sets no WorkingDirectory). The script's
# REPO_ROOT resolves to $WORK (it lives at $WORK/config/surf-resume.sh), so the stub must have run
# from there. A mutation reverting the cd would record a different cwd and fail this.
EXPECT_CWD="$(cd "$WORK" && pwd -P)"
if grep -qF "CWD $EXPECT_CWD" "$CLAUDE_REC" 2>/dev/null; then pass "(a) relaunch runs from REPO_ROOT (cd \$REPO_ROOT honored)"; else fail "(a) relaunch did not cd to REPO_ROOT (recorded: $(grep '^CWD' "$CLAUDE_REC" | tail -1))"; fi

# --- (b) capped on relaunch → resume-after armed to a FUTURE floor, no hot-loop -
seed_charter
rm -f "$WORK/.surf/active" "$WORK/.surf/resume-after"
CLAUDE_OUT="You've hit your usage limit. Try again later." run_watcher
if [ -s "$WORK/.surf/resume-after" ]; then pass "(b) cap on relaunch → resume-after armed"; else fail "(b) resume-after not armed after cap"; fi
ra="$(cat "$WORK/.surf/resume-after" 2>/dev/null || true)"
rae="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ra" "+%s" 2>/dev/null || date -u -d "$ra" "+%s" 2>/dev/null || echo 0)"
if [ "${rae:-0}" -gt "$(now_epoch)" ]; then pass "(b) armed floor is in the future (no hot-loop)"; else fail "(b) floor not in future ($ra)"; fi

# --- (c) done-marker present → gate closed → NO relaunch ----------------------
seed_charter
rm -f "$WORK/.surf/active" "$WORK/.surf/resume-after"
touch "$WORK/.surf/charter-20260101T000000.md-done"
run_watcher
c="$(invoke_count)"
if [ "$c" -eq 0 ]; then pass "(c) done-marker → gate closed, no relaunch"; else fail "(c) expected 0 relaunches, got $c"; fi
rm -f "$WORK/.surf/charter-20260101T000000.md-done"

# --- (d) live .surf/active PID → a /surf already running → NO relaunch --------
seed_charter
rm -f "$WORK/.surf/resume-after"
echo "$$" >"$WORK/.surf/active"   # this test process is alive
run_watcher
c="$(invoke_count)"
if [ "$c" -eq 0 ]; then pass "(d) live .surf/active → already running, no relaunch"; else fail "(d) expected 0 relaunches, got $c"; fi
rm -f "$WORK/.surf/active"

# --- (e) armed resume-after still in the future → NO relaunch (waiting) -------
seed_charter
rm -f "$WORK/.surf/active"
rfc3339_at 36000 >"$WORK/.surf/resume-after"   # 10h out
run_watcher
c="$(invoke_count)"
if [ "$c" -eq 0 ]; then pass "(e) future resume-after → waiting, no relaunch"; else fail "(e) expected 0 relaunches, got $c"; fi

# --- (f) stale/dead .surf/active PID → self-heals → relaunch proceeds ---------
seed_charter
rm -f "$WORK/.surf/resume-after"
echo '999999' >"$WORK/.surf/active"   # dead PID
run_watcher
c="$(invoke_count)"
if [ "$c" -eq 1 ]; then pass "(f) stale .surf/active → self-heals, relaunch proceeds"; else fail "(f) expected 1 relaunch, got $c"; fi

# --- (h) #124 R2-3: armed floor in the PAST → relaunch fires AND the floor is cleared afterwards.
# (Restores the floor-cleared coverage the old send-keys tests (a)/(d) had.)
seed_charter
rm -f "$WORK/.surf/active"
rfc3339_at -3600 >"$WORK/.surf/resume-after"   # armed, 1h in the PAST → crossed
run_watcher
c="$(invoke_count)"
if [ "$c" -eq 1 ]; then pass "(h) past floor crossed → exactly one relaunch"; else fail "(h) expected 1 relaunch, got $c"; fi
if [ ! -f "$WORK/.surf/resume-after" ]; then pass "(h) floor cleared after a clean relaunch (no cap on rerun)"; else fail "(h) resume-after not cleared after clean relaunch"; fi

# --- (i) #124 R2-5: a WEEKLY-cap message with an am/pm + TZ reset time (the #119 parser) arms a
# FUTURE floor from the parsed reset time, not just a fixed default backoff.
seed_charter
rm -f "$WORK/.surf/active" "$WORK/.surf/resume-after"
CLAUDE_OUT="You've hit your weekly limit · resets 8pm (America/New_York)" run_watcher
if [ -s "$WORK/.surf/resume-after" ]; then pass "(i) weekly am/pm cap → resume-after armed"; else fail "(i) weekly-cap floor not armed"; fi
ra="$(cat "$WORK/.surf/resume-after" 2>/dev/null || true)"
rae="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ra" "+%s" 2>/dev/null || date -u -d "$ra" "+%s" 2>/dev/null || echo 0)"
if [ "${rae:-0}" -gt "$(now_epoch)" ]; then pass "(i) weekly-cap floor parsed into the future"; else fail "(i) weekly-cap floor not in future ($ra)"; fi
# Deterministic "the am/pm parser fired" check: the floor must land on the parsed 8pm wall-clock in
# America/New_York. The old check (floor < fixed-default magnitude) was CLOCK-DEPENDENT — after 8pm
# local the next 8pm legitimately rolls to tomorrow and is farther out than the default backoff, so
# it false-failed late in the day. Assert the WALL-CLOCK, not the gap: the default fallback
# (now + N hours) never lands exactly on 20:00:00 ET, so 20:00 uniquely proves the parser fired.
parsed_hhmm="$(TZ=America/New_York date -r "${rae:-0}" "+%H:%M" 2>/dev/null || TZ=America/New_York date -d "@${rae:-0}" "+%H:%M" 2>/dev/null || echo "")"
if [ "$parsed_hhmm" = "20:00" ]; then pass "(i) floor came from the am/pm parser (lands on 20:00 ET)"; else fail "(i) floor not on parsed 20:00 ET wall-clock (got '$parsed_hhmm') — parser did not fire"; fi

# --- (j) #124 R2-6: a relaunch whose BODY mentions cap phrases but whose TAIL is a normal
# completion must NOT arm a backoff (cap detection is tail-anchored).
seed_charter
rm -f "$WORK/.surf/active" "$WORK/.surf/resume-after"
CLAUDE_OUT="$(printf '%s\n' \
  'Working issue #5: the code references a rate limit and resets at midnight.' \
  'merged #5 abc1234' \
  'merged #6 def5678' \
  'Board exhausted — run complete.')" run_watcher
if [ ! -f "$WORK/.surf/resume-after" ]; then pass "(j) body mentions cap, tail is normal → NO backoff armed (tail-anchored)"; else fail "(j) spurious backoff armed from body cap mention"; fi

# --- (k) #124 R5-4: a lockdir whose recorded relaunch PID is ALIVE is NOT treated as stale, even
# when its mtime is far older than MAX_RUN_AGE (a routine multi-hour board pass). No concurrent
# relaunch must fire while a live relaunch holds the lock.
seed_charter
rm -f "$WORK/.surf/active" "$WORK/.surf/resume-after"
mkdir -p "$WORK/.surf/resume.lock"
echo "$$" >"$WORK/.surf/resume.lock/pid"            # live pid (this test process)
touch -t 202001010000 "$WORK/.surf/resume.lock"     # mtime way older than MAX_RUN_AGE
SURF_RESUME_MAX_RUN_AGE=1 run_watcher_keeplock       # tiny MAX_RUN_AGE: age alone would look stale
c="$(invoke_count)"
if [ "$c" -eq 0 ]; then pass "(k) live-pid lock (old mtime) → NOT stale, no concurrent relaunch"; else fail "(k) live lock wrongly reclaimed → concurrent relaunch ($c)"; fi
if [ -d "$WORK/.surf/resume.lock" ]; then pass "(k) live lock left intact"; else fail "(k) live lock was reclaimed"; fi
rm -rf "$WORK/.surf/resume.lock"

# --- (k2) #124 R5-4: a lockdir whose recorded PID is DEAD and which has aged out IS reclaimed
# (a SIGKILL that skipped the trap must not wedge the watcher forever).
seed_charter
rm -f "$WORK/.surf/active" "$WORK/.surf/resume-after"
mkdir -p "$WORK/.surf/resume.lock"
echo '999999' >"$WORK/.surf/resume.lock/pid"        # dead pid
touch -t 202001010000 "$WORK/.surf/resume.lock"     # old mtime
SURF_RESUME_MAX_RUN_AGE=1 run_watcher_keeplock
c="$(invoke_count)"
if [ "$c" -eq 1 ]; then pass "(k2) dead-pid aged-out lock → reclaimed, relaunch proceeds"; else fail "(k2) dead aged-out lock not reclaimed ($c)"; fi
rm -rf "$WORK/.surf/resume.lock"

# --- (l) #124 R5-5: a user-stop paused sentinel closes the gate (no relaunch); absent → normal.
seed_charter
rm -f "$WORK/.surf/active" "$WORK/.surf/resume-after"
touch "$WORK/.surf/charter-20260101T000000.md-paused"
run_watcher
c="$(invoke_count)"
if [ "$c" -eq 0 ]; then pass "(l) paused sentinel → gate closed, no relaunch (deliberate user-stop)"; else fail "(l) paused sentinel ignored → wrongly relaunched ($c)"; fi
rm -f "$WORK/.surf/charter-20260101T000000.md-paused"
# absent sentinel → normal relaunch (proves the sentinel, not some other gate, closed it above).
seed_charter
rm -f "$WORK/.surf/active" "$WORK/.surf/resume-after"
run_watcher
c="$(invoke_count)"
if [ "$c" -eq 1 ]; then pass "(l) no paused sentinel → normal relaunch"; else fail "(l) expected 1 relaunch without sentinel, got $c"; fi

# --- (g) surf.md resume reconciliation (#136 AC4): an in-flight issue (an unmerged `sail/<issue>`
# branch) WITHOUT a `.surf/runs/<issue>/.done` completion sentinel is ORPHANED and re-launched with a
# FRESH /sail worker (a new .sail/runs/sail-<issue>-<ts>/), never treated as done. The pre-#136
# "same --run-dir" re-invocation is gone — /sail names a fresh timestamped run-dir each launch.
SURF_MD="$SRC_DIR/commands/surf.md"
if grep -qiE 'no .*sentinel.*orphan|orphan.*(no|missing) .*sentinel|in-flight.*orphan|unmerged.*no .*\.done' "$SURF_MD" 2>/dev/null; then
  pass "(g) surf.md: an in-flight issue without a .done sentinel is treated as orphaned"
else
  fail "(g) surf.md orphaned-issue reconciliation rule missing"
fi
if grep -qiE 'fresh .*/sail worker|re-launch.*fresh.*worker|fresh.*worker.*new .*\.sail/runs' "$SURF_MD" 2>/dev/null; then
  pass "(g) surf.md: orphan re-launches a FRESH /sail worker (new run-dir)"
else
  fail "(g) surf.md fresh-worker re-launch rule missing"
fi
# The old SAME-run-dir re-invocation must be gone (it described a model /sail no longer supports).
if grep -qiE 'same .*--run-dir|--run-dir \.surf/runs' "$SURF_MD" 2>/dev/null; then
  fail "(g) stale 'same --run-dir' resume language still present"
else
  pass "(g) stale 'same --run-dir' resume language removed"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
