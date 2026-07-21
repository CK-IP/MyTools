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
# #163: the watcher's REPO_ROOT is $WORK (script lives at $WORK/config), and it now cd's to
# REPO_ROOT before `python3 -m sail cap-recovery` (launchd sets no WorkingDirectory). Symlink the
# real sail package under $WORK so the classifier/parser resolve exactly as they do in production.
ln -s "$SRC_DIR/sail" "$WORK/sail"
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
# Optional: simulate the resumed /surf run's Step-7 own-pid write into .surf/active (n2b).
[ -n "\${CLAUDE_WRITE_ACTIVE:-}" ] && printf '%s\n' "\${CLAUDE_WRITE_ACTIVE}" >"$WORK/.surf/active" || true
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
# #126 heartbeat contract: a live pid alone no longer closes the gate — a live-but-CAP-FROZEN
# supervisor must be taken over (see (n)). "Already running" now means live pid + FRESH
# `.surf/heartbeat`; a missing heartbeat counts as stale (backward-compat takeover). So this
# test seeds a fresh heartbeat to keep pinning the live-and-working → no-relaunch behavior.
seed_charter
rm -f "$WORK/.surf/resume-after"
echo "$$" >"$WORK/.surf/active"   # this test process is alive
touch "$WORK/.surf/heartbeat"     # fresh heartbeat: live AND working
run_watcher
c="$(invoke_count)"
if [ "$c" -eq 0 ]; then pass "(d) live .surf/active + fresh heartbeat → already running, no relaunch"; else fail "(d) expected 0 relaunches, got $c"; fi
rm -f "$WORK/.surf/active" "$WORK/.surf/heartbeat"

# --- (d-cap) #163 scenario 5: a live pid + FRESH heartbeat + `.surf/capped` relinquish marker +
# an armed-but-PASSED resume-after → the supervisor self-relinquished while cap-blocked, so the
# watcher must TAKE OVER (relaunch) despite the fresh heartbeat. This pins AC "watcher takeover
# despite a live pid + capped marker" end-to-end through active_session()/main().
seed_charter
echo "$$" >"$WORK/.surf/active"          # supervisor pid still alive
touch "$WORK/.surf/heartbeat"            # fresh heartbeat — would normally block; capped must override
touch "$WORK/.surf/capped"               # relinquish marker
rfc3339_at -60 >"$WORK/.surf/resume-after"   # armed floor already passed → relaunch may fire
run_watcher
c="$(invoke_count)"
if [ "$c" -eq 1 ]; then pass "(d-cap) live pid + fresh heartbeat + capped + passed floor → watcher takes over"; else fail "(d-cap) expected 1 takeover relaunch, got $c"; fi
rm -f "$WORK/.surf/active" "$WORK/.surf/heartbeat" "$WORK/.surf/capped" "$WORK/.surf/resume-after"

# --- (d-cap2) #163 b321 guard: a LONE stale `.surf/capped` marker with NO armed resume-after must
# NOT make a healthy live session look recoverable (no double-drive). relinquish/clear write and
# remove the marker+floor as a pair, so a marker without a floor is stale and is ignored.
seed_charter
echo "$$" >"$WORK/.surf/active"
touch "$WORK/.surf/heartbeat"
touch "$WORK/.surf/capped"               # marker present but NO resume-after floor
rm -f "$WORK/.surf/resume-after"
run_watcher
c="$(invoke_count)"
if [ "$c" -eq 0 ]; then pass "(d-cap2) lone stale capped marker (no armed floor) → healthy session not double-driven"; else fail "(d-cap2) expected 0 relaunches, got $c"; fi
rm -f "$WORK/.surf/active" "$WORK/.surf/heartbeat" "$WORK/.surf/capped"

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
# (now + N hours) never lands within a few minutes of 20:00 ET, so hour==20 & minute<5 uniquely
# proves the parser fired. #163: `arm` adds a small post-reset margin (default 120s) so the floor
# lands at ~20:02, not exactly 20:00 — hence the minute-window rather than an exact match.
parsed_hhmm="$(TZ=America/New_York date -r "${rae:-0}" "+%H:%M" 2>/dev/null || TZ=America/New_York date -d "@${rae:-0}" "+%H:%M" 2>/dev/null || echo "")"
parsed_hh="${parsed_hhmm%%:*}"; parsed_mm="${parsed_hhmm##*:}"
if [ "$parsed_hh" = "20" ] && [ -n "$parsed_mm" ] && [ "$((10#$parsed_mm))" -lt 5 ]; then pass "(i) floor came from the am/pm parser (lands ~20:00 ET + margin)"; else fail "(i) floor not on parsed 20:00 ET wall-clock (got '$parsed_hhmm') — parser did not fire"; fi

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

# --- (m) #126 §121 / #163: a BENIGN non-cap line that merely contains "limit reached" (e.g. a CLI's
# "max retries limit reached" / "concurrency limit reached") must NOT be detected as a usage cap, so
# no spurious multi-hour resume-after backoff is armed on a non-cap stop. The GENUINE Anthropic
# notice "Claude usage limit reached" must STILL be detected (via the `usage limit` token). #163
# lifted classification into the single-source Python classifier (sail cap-recovery classify), so
# these cases now pin THAT classifier directly instead of the retired bash CAP_NOTICE_RE regex.
if ( cd "$SRC_DIR" && printf '%s\n' "max retries limit reached" | python3 -m sail cap-recovery classify >/dev/null 2>&1 ); then
  fail "(m) classifier still matches benign 'max retries limit reached'"
else
  pass "(m) classifier no longer matches benign 'max retries limit reached'"
fi
if ( cd "$SRC_DIR" && printf '%s\n' "Claude usage limit reached" | python3 -m sail cap-recovery classify >/dev/null 2>&1 ); then
  pass "(m) classifier still matches genuine 'Claude usage limit reached'"
else
  fail "(m) classifier lost genuine 'Claude usage limit reached' coverage"
fi
seed_charter
rm -f "$WORK/.surf/active" "$WORK/.surf/resume-after"
CLAUDE_OUT="max retries limit reached" run_watcher
if [ ! -f "$WORK/.surf/resume-after" ]; then pass "(m) benign 'max retries limit reached' → NOT a cap, no backoff armed"; else fail "(m) benign 'limit reached' wrongly detected as a cap (spurious backoff armed)"; fi

seed_charter
rm -f "$WORK/.surf/active" "$WORK/.surf/resume-after"
CLAUDE_OUT="Claude usage limit reached" run_watcher
if [ -s "$WORK/.surf/resume-after" ]; then pass "(m) genuine 'Claude usage limit reached' → still detected as a cap (coverage preserved)"; else fail "(m) genuine usage-limit notice NOT detected — cap coverage lost"; fi

# --- (n) #126 cap-stall auto-resume: heartbeat stale-live detection + takeover -------------------
# A live `.surf/active` pid can belong to a CAP-FROZEN interactive supervisor (live-but-stalled —
# fired twice live, board runs 2026-07-06/07: the frozen session held the pid and the gate stayed
# closed forever). The watcher must treat a live pid as STALLED when `.surf/heartbeat` is older
# than SURF_HEARTBEAT_STALE_SECS (default ~2700s); a MISSING heartbeat counts as stale (backward
# compatible with pre-heartbeat charters). Stale-live bypasses ONLY the liveness gate — the
# done-marker and resume-after floor still apply on the takeover path.

# (n1) fresh heartbeat + live pid → gate stays closed (current behavior pinned).
seed_charter
rm -f "$WORK/.surf/resume-after"
echo "$$" >"$WORK/.surf/active"
touch "$WORK/.surf/heartbeat"
run_watcher
c="$(invoke_count)"
if [ "$c" -eq 0 ]; then pass "(n1) fresh heartbeat + live pid → gate closed, no takeover"; else fail "(n1) expected 0 relaunches on fresh heartbeat, got $c"; fi
if [ ! -f "$WORK/.surf/resume-after" ]; then pass "(n1) fresh heartbeat → no backoff armed"; else fail "(n1) spurious resume-after armed on fresh heartbeat"; fi

# (n2) STALE heartbeat + live pid → the live pid is a cap-frozen supervisor → takeover relaunch
# fires. The watcher overwrites `.surf/active` with the relaunch pid BEFORE the run (so the frozen
# session's re-anchor check fails and it stands down), and after the run it must NOT leave a dead
# marker behind: the stub never writes `.surf/active` itself, so once the relaunch exits the marker
# must be gone (a dead-pid marker would make `.surf/active` an unreliable liveness signal until the
# next tick happens to clean it).
seed_charter
rm -f "$WORK/.surf/resume-after"
echo "$$" >"$WORK/.surf/active"
touch -t 202001010000 "$WORK/.surf/heartbeat"   # heartbeat mtime far past any sane threshold
run_watcher
c="$(invoke_count)"
if [ "$c" -eq 1 ]; then pass "(n2) stale heartbeat + live pid → takeover relaunch fires"; else fail "(n2) expected 1 takeover relaunch on stale heartbeat, got $c"; fi
if ! grep -qxF "$$" "$WORK/.surf/active" 2>/dev/null; then pass "(n2) stalled pid no longer owns .surf/active after takeover"; else fail "(n2) .surf/active still holds the stalled pid after takeover"; fi
if [ ! -f "$WORK/.surf/active" ]; then pass "(n2) no dead-pid marker left in .surf/active after the relaunch exits"; else fail "(n2) dead-pid marker left in .surf/active after relaunch (holds: $(cat "$WORK/.surf/active" 2>/dev/null))"; fi
rm -f "$WORK/.surf/active" "$WORK/.surf/heartbeat"

# (n2b) The resumed run OWNS the marker: when the relaunched /surf writes its own pid into
# `.surf/active` (the Step-7 write, simulated by the stub via CLAUDE_WRITE_ACTIVE), the watcher's
# post-run cleanup must NOT clobber it — only a marker still holding the watcher's own launch pid
# is cleaned.
seed_charter
rm -f "$WORK/.surf/resume-after"
echo "$$" >"$WORK/.surf/active"
touch -t 202001010000 "$WORK/.surf/heartbeat"
CLAUDE_WRITE_ACTIVE=4242 run_watcher
if [ "$(cat "$WORK/.surf/active" 2>/dev/null)" = "4242" ]; then pass "(n2b) resumed run's own .surf/active write preserved (watcher cleanup is conditional)"; else fail "(n2b) watcher clobbered the resumed run's .surf/active (holds: $(cat "$WORK/.surf/active" 2>/dev/null || echo '<absent>'))"; fi
rm -f "$WORK/.surf/active" "$WORK/.surf/heartbeat"

# (n3) MISSING heartbeat + live pid (pre-heartbeat charter) → counts as stale → takeover fires.
seed_charter
rm -f "$WORK/.surf/resume-after" "$WORK/.surf/heartbeat"
echo "$$" >"$WORK/.surf/active"
run_watcher
c="$(invoke_count)"
if [ "$c" -eq 1 ]; then pass "(n3) missing heartbeat + live pid → stale (backward compat), takeover fires"; else fail "(n3) expected 1 relaunch on missing heartbeat, got $c"; fi
rm -f "$WORK/.surf/active"

# (n4) stale heartbeat + live pid + FUTURE resume-after floor → takeover still honors the floor.
seed_charter
echo "$$" >"$WORK/.surf/active"
touch -t 202001010000 "$WORK/.surf/heartbeat"
rfc3339_at 36000 >"$WORK/.surf/resume-after"   # 10h out
run_watcher
c="$(invoke_count)"
if [ "$c" -eq 0 ]; then pass "(n4) stale heartbeat but future floor → takeover waits (floor honored)"; else fail "(n4) takeover ignored the resume-after floor ($c relaunches)"; fi
rm -f "$WORK/.surf/active" "$WORK/.surf/heartbeat" "$WORK/.surf/resume-after"

# (n5) stale heartbeat + live pid + done-marker → no work remains → no takeover.
seed_charter
echo "$$" >"$WORK/.surf/active"
touch -t 202001010000 "$WORK/.surf/heartbeat"
touch "$WORK/.surf/charter-20260101T000000.md-done"
run_watcher
c="$(invoke_count)"
if [ "$c" -eq 0 ]; then pass "(n5) stale heartbeat but done-marker → gate closed (work_remains honored)"; else fail "(n5) takeover fired despite done-marker ($c relaunches)"; fi
rm -f "$WORK/.surf/active" "$WORK/.surf/heartbeat" "$WORK/.surf/charter-20260101T000000.md-done"

# --- (o) #126 latent PATH bug: relaunch must resolve `claude` under launchd's minimal PATH -------
# launchd runs the watcher with PATH=/usr/bin:/bin:/usr/sbin:/sbin — a bare `claude` never resolves
# (~/.local/bin is not on that PATH) and the `|| true` swallowed the failure silently. The script
# must resolve claude via an explicit PATH export / absolute-path fallback (e.g. $HOME/.local/bin).
seed_charter
rm -f "$WORK/.surf/active" "$WORK/.surf/resume-after"
rm -rf "$WORK/.surf/resume.lock"
mkdir -p "$WORK/.local/bin"
cp "$WORK/bin/claude" "$WORK/.local/bin/claude"
: >"$CLAUDE_REC"
env -i HOME="$WORK" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  SURF_RESUME_LOG="$WORK/.surf/watch.log" CLAUDE_OUT="run finished cleanly" \
  SURF_RESUME_MIN_BACKOFF=60 SURF_RESUME_DEFAULT_BACKOFF=36000 SURF_RESUME_MAX_RUN_AGE=7200 \
  bash "$WORK/config/surf-resume.sh" >/dev/null 2>&1 || true
c="$(invoke_count)"
if [ "$c" -eq 1 ]; then pass "(o) launchd minimal PATH → claude resolved via \$HOME/.local/bin (PATH fix)"; else fail "(o) bare \`claude\` did not resolve under launchd's minimal PATH ($c relaunches)"; fi

# (o2) claude resolvable NOWHERE → the watcher must fail LOUDLY (a 'claude not found' log line),
# not die silently. Under `set -euo pipefail` a bare `claude_bin="$(resolve_claude)"` assignment
# aborts the script before any diagnostic can run — the exact silent-failure mode the PATH fix
# set out to eliminate — so the not-found path needs its own pin.
seed_charter
rm -f "$WORK/.surf/active" "$WORK/.surf/resume-after"
rm -rf "$WORK/.surf/resume.lock"
rm -f "$WORK/.local/bin/claude"
: >"$CLAUDE_REC"
: >"$WORK/.surf/watch.log"
env -i HOME="$WORK" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  SURF_RESUME_LOG="$WORK/.surf/watch.log" \
  SURF_RESUME_MIN_BACKOFF=60 SURF_RESUME_DEFAULT_BACKOFF=36000 SURF_RESUME_MAX_RUN_AGE=7200 \
  bash "$WORK/config/surf-resume.sh" >/dev/null 2>&1 || true
c="$(invoke_count)"
if [ "$c" -eq 0 ] && grep -qi 'claude not found' "$WORK/.surf/watch.log" 2>/dev/null; then
  pass "(o2) claude unresolvable → loud 'claude not found' log, no silent death"
else
  fail "(o2) unresolvable claude died silently (invokes=$c, log: $(grep -ci 'claude not found' "$WORK/.surf/watch.log" 2>/dev/null || echo 0) matches)"
fi
mkdir -p "$WORK/.local/bin"; cp "$WORK/bin/claude" "$WORK/.local/bin/claude"   # restore for any later test

# --- (q) surf.md spec pins for the heartbeat/takeover contract (mirrors test (g)'s style) --------
if grep -qiE '\.surf/heartbeat' "$SURF_MD" 2>/dev/null && grep -qiE 'heartbeat.*(poll tick|worker launch)|(poll tick|worker launch).*heartbeat' "$SURF_MD" 2>/dev/null; then
  pass "(q) surf.md: supervisor touches .surf/heartbeat at checkpoints (worker launch / poll tick)"
else
  fail "(q) surf.md heartbeat-touch rule missing"
fi
if grep -qiE 'stand(s|[- ])?down' "$SURF_MD" 2>/dev/null && grep -qiE '\.surf/active.*no longer|no longer.*\.surf/active' "$SURF_MD" 2>/dev/null; then
  pass "(q) surf.md: re-anchor rule — session stands down when .surf/active no longer holds its pid"
else
  fail "(q) surf.md re-anchor/stand-down rule missing"
fi
if grep -qiE 'overwrit[a-z]*[^.]*\.surf/active|\.surf/active[^.]*overwrit' "$SURF_MD" 2>/dev/null; then
  pass "(q) surf.md: takeover supervisor overwrites .surf/active with its own pid"
else
  fail "(q) surf.md takeover-overwrite rule missing"
fi
# (q4) The re-anchor/stand-down check must run at EVERY heartbeat checkpoint, BEFORE the
# checkpoint's action — a cap-frozen supervisor wakes MID-issue, so a per-issue-boundary-only
# re-anchor leaves a window where two supervisors double-drive one worktree (round-1 HIGH).
if grep -qiE '(re-anchor|ownership|stand[- ]?down)[^.]*(every|each)[^.]*checkpoint|(every|each)[^.]*checkpoint[^.]*(re-anchor|stand[- ]?down)' "$SURF_MD" 2>/dev/null \
   && grep -qiE 'before[^.]*(checkpoint.{0,40}action|acting|performing)' "$SURF_MD" 2>/dev/null; then
  pass "(q4) surf.md: re-anchor check at every heartbeat checkpoint, before the action"
else
  fail "(q4) surf.md per-checkpoint re-anchor-before-action rule missing"
fi
# (q5) The heartbeat threshold only works if the poll cadence is pinned well under it: surf.md
# must state a concrete polling interval bound while a worker is in flight (round-1 MEDIUM —
# an unpinned cadence lets a slow-but-healthy run be misjudged stale).
if grep -qiE 'at least every [0-9]+ ?(minutes|min)' "$SURF_MD" 2>/dev/null; then
  pass "(q5) surf.md: poll cadence pinned to a concrete bound (heartbeat margin holds)"
else
  fail "(q5) surf.md poll-cadence bound missing — heartbeat staleness margin unpinned"
fi

# --- (r) INSTALL.md documents the watcher-agent operational gotchas ------------------------------
INSTALL_MD="$SRC_DIR/INSTALL.md"
if grep -qF 'launchctl kickstart' "$INSTALL_MD" 2>/dev/null; then
  pass "(r) INSTALL.md documents launchctl kickstart after load"
else
  fail "(r) INSTALL.md missing launchctl kickstart step"
fi
if grep -qiE 'Background Task Management|BTM' "$INSTALL_MD" 2>/dev/null && grep -qiE 'sleep' "$INSTALL_MD" 2>/dev/null; then
  pass "(r) INSTALL.md notes the BTM approval + sleep limitation"
else
  fail "(r) INSTALL.md missing BTM/sleep limitation note"
fi
# New config knob (docs-impact, #56): the heartbeat staleness threshold env var must be documented.
if grep -qF 'SURF_HEARTBEAT_STALE_SECS' "$INSTALL_MD" 2>/dev/null; then
  pass "(r) INSTALL.md documents the SURF_HEARTBEAT_STALE_SECS knob"
else
  fail "(r) INSTALL.md missing SURF_HEARTBEAT_STALE_SECS documentation"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
