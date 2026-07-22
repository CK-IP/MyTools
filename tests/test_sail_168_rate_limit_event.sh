#!/usr/bin/env bash
# test_sail_168_rate_limit_event.sh — #168: adopt the worker's stream-json `rate_limit_event` as the
# AUTHORITATIVE cap/reset signal, superseding the #126 cap-text regex on the /surf WORKER path.
#
# The parser is a convoy `ship-tide.py` port (`_parse_resets_at` / `_find_last_event_by_type` /
# `_usage_limit_decision`) living in the single-source tested module `sail/cap_recovery.py`. It reads
# stream-json LINES from a FILE (never shell-interpolated — OWASP LLM01) and returns the RAW reset
# epoch (arm adds the post-reset margin + floor + ceiling, single-sourced). Hold-worthiness keys off
# status/utilization exactly like convoy; five_hour and seven_day are evaluated INDEPENDENTLY and the
# LONGEST-wait window dominates. An absent/malformed/elapsed/non-cap event yields NO reset (rc 1) so
# the /surf fallback chain (#166 statusline → #163 reactive floor) engages — the event never fabricates
# a bogus wake target.
#
# Hermetic: cd into the repo, scrub SAIL_*/SURF_* so env knobs cannot leak into the floor math, inject
# a frozen --now everywhere, no live git/statusline/backend dependence, cap text/JSON always file-fed.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SRC_DIR"
for v in $(env | sed -nE 's/^((SAIL|SURF)_[A-Za-z0-9_]+)=.*/\1/p'); do unset "$v"; done

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1  (${2:-})"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

CR() { python3 -m sail cap-recovery "$@"; }

# A fixed reference "now": 2026-07-21T18:00:00Z. Windows reset in the future by default.
NOW=1784656800
FIVE_RESET=$((NOW + 3600))       # 5h window resets in 1h
SEVEN_RESET=$((NOW + 3 * 86400)) # 7d window resets in 3 days
MARGIN=120                       # DEFAULT_POST_RESET_MARGIN_SECS

# ---- fixture builders (each writes a stream-json .jsonl file) ----------------------------------
# A rate_limit_event line. $1=window $2=status $3=utilization ("-" to omit) $4=resetsAt(raw int/str)
rle() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
window, status, util, resets = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
info = {"status": status, "rateLimitType": window,
        "resetsAt": (int(resets) if resets.lstrip("-").isdigit() else resets)}
if util != "-":
    info["utilization"] = float(util)
print(json.dumps({"type": "rate_limit_event", "rate_limit_info": info}))
PY
}

epoch_field() { printf '%s' "$1" | cut -f"$2"; }

# ================================================================================================
# Part A — rate-limit-event CLI: extract the authoritative RAW reset epoch from a stream-json file.
#   Prints "<raw_epoch>\t<limit_type>" and rc 0 when a hold-worthy event is present; rc 1 (no output)
#   when absent/malformed/elapsed/non-cap. (AC0, AC1, AC3, AC6)
# ================================================================================================

LOG="$WORK/stream.jsonl"

# A1 — a rejected five_hour event → authoritative raw resetsAt (epoch-seconds), limit_type=five_hour.
{ echo '{"type":"system","subtype":"init"}'; rle five_hour rejected - "$FIVE_RESET"; } > "$LOG"
if OUT="$(CR rate-limit-event --log-file "$LOG" --now "$NOW")"; then
  if [ "$(epoch_field "$OUT" 1)" = "$FIVE_RESET" ]; then pass "A1: rejected five_hour → raw resetsAt epoch"; else fail "A1 epoch" "$OUT"; fi
  if [ "$(epoch_field "$OUT" 2)" = "five_hour" ]; then pass "A1b: limit_type=five_hour"; else fail "A1b type" "$OUT"; fi
else
  fail "A1: hold-worthy event must rc 0" "rc=$?"
fi

# A2 — epoch-MILLISECONDS resetsAt (convoy: > 1e12 → /1000).
rle five_hour rejected - "$(( FIVE_RESET * 1000 ))" > "$LOG"
OUT="$(CR rate-limit-event --log-file "$LOG" --now "$NOW" || true)"
if [ "$(epoch_field "$OUT" 1)" = "$FIVE_RESET" ]; then pass "A2: epoch-ms resetsAt normalized to seconds"; else fail "A2" "$OUT"; fi

# A3 — ISO-8601 string resetsAt with trailing Z.
ISO="$(python3 - "$FIVE_RESET" <<'PY'
import sys, datetime
print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"
rle five_hour rejected - "$ISO" > "$LOG"
OUT="$(CR rate-limit-event --log-file "$LOG" --now "$NOW" || true)"
if [ "$(epoch_field "$OUT" 1)" = "$FIVE_RESET" ]; then pass "A3: ISO-8601 resetsAt parsed to epoch"; else fail "A3" "$OUT"; fi

# A4 — status "allowed" → NOT a cap → rc 1, no output (fail to absence).
rle five_hour allowed 0.99 "$FIVE_RESET" > "$LOG"
if CR rate-limit-event --log-file "$LOG" --now "$NOW" >/dev/null 2>&1; then fail "A4: 'allowed' must not be a cap" "rc0"; else pass "A4: 'allowed' status → no reset (rc 1)"; fi

# A5 — allowed_warning + utilization ABOVE the five_hour threshold (0.90) → hold.
rle five_hour allowed_warning 0.94 "$FIVE_RESET" > "$LOG"
if OUT="$(CR rate-limit-event --log-file "$LOG" --now "$NOW")" && [ "$(epoch_field "$OUT" 1)" = "$FIVE_RESET" ]; then
  pass "A5: allowed_warning util>=0.90 (five_hour) → hold"
else
  fail "A5" "$OUT"
fi

# A6 — allowed_warning + utilization BELOW the five_hour threshold → no hold (rc 1).
rle five_hour allowed_warning 0.80 "$FIVE_RESET" > "$LOG"
if CR rate-limit-event --log-file "$LOG" --now "$NOW" >/dev/null 2>&1; then fail "A6: warning under threshold must not hold" "rc0"; else pass "A6: allowed_warning util<0.90 → no reset"; fi

# A7 — seven_day threshold is STRICTER (0.98): util 0.94 does NOT hold on seven_day (would on five_hour).
rle seven_day allowed_warning 0.94 "$SEVEN_RESET" > "$LOG"
if CR rate-limit-event --log-file "$LOG" --now "$NOW" >/dev/null 2>&1; then fail "A7: 0.94 must not hold on seven_day (thr 0.98)" "rc0"; else pass "A7: seven_day threshold 0.98 (0.94 does not hold)"; fi
rle seven_day allowed_warning 0.99 "$SEVEN_RESET" > "$LOG"
OUT="$(CR rate-limit-event --log-file "$LOG" --now "$NOW" || true)"
if [ "$(epoch_field "$OUT" 2)" = "seven_day" ]; then pass "A7b: seven_day util>=0.98 → hold"; else fail "A7b" "$OUT"; fi

# A8 — ELAPSED window: resetsAt already in the PAST of now → not an active cap → rc 1.
rle five_hour rejected - "$((NOW - 10))" > "$LOG"
if CR rate-limit-event --log-file "$LOG" --now "$NOW" >/dev/null 2>&1; then fail "A8: elapsed reset must not hold" "rc0"; else pass "A8: elapsed (past) resetsAt → no reset"; fi

# ================================================================================================
# Part B — per-window independence + longest-wait dominance (convoy #469). (AC2 shape)
# ================================================================================================

# B1 — five_hour (rejected, near) AND seven_day (rejected, far) both present → the LONGER wait
# (seven_day) dominates the single wake target.
{ rle five_hour rejected - "$FIVE_RESET"; rle seven_day rejected - "$SEVEN_RESET"; } > "$LOG"
OUT="$(CR rate-limit-event --log-file "$LOG" --now "$NOW" || true)"
if [ "$(epoch_field "$OUT" 1)" = "$SEVEN_RESET" ] && [ "$(epoch_field "$OUT" 2)" = "seven_day" ]; then
  pass "B1: longest-wait window dominates (seven_day)"
else
  fail "B1" "$OUT"
fi

# B2 — a window's LAST event wins (a later 'allowed' clears an earlier 'rejected' for that window).
{ rle five_hour rejected - "$FIVE_RESET"; rle five_hour allowed - "$FIVE_RESET"; } > "$LOG"
if CR rate-limit-event --log-file "$LOG" --now "$NOW" >/dev/null 2>&1; then fail "B2: later 'allowed' must clear earlier 'rejected'" "rc0"; else pass "B2: last event per window wins"; fi

# ================================================================================================
# Part C — malformed / injection-safety: never crash, never leak, fail to absence. (AC6, AC7-safety)
# ================================================================================================

# C1 — garbage + partial-JSON lines interleaved with one valid event → the valid event still parses.
{ echo 'not json at all'; echo '{"type":"rate_limit_event"'; echo '{}'; echo '[]'; rle five_hour rejected - "$FIVE_RESET"; } > "$LOG"
OUT="$(CR rate-limit-event --log-file "$LOG" --now "$NOW" || true)"
if [ "$(epoch_field "$OUT" 1)" = "$FIVE_RESET" ]; then pass "C1: malformed lines skipped, valid event parsed"; else fail "C1" "$OUT"; fi

# C2 — empty file → rc 1, no output, no traceback on stdout.
: > "$LOG"
if CR rate-limit-event --log-file "$LOG" --now "$NOW" >/dev/null 2>&1; then fail "C2: empty stream must rc 1" "rc0"; else pass "C2: empty stream → no reset (rc 1)"; fi

# C2b — MISSING/unreadable stream file (a worker that never wrote a stream) → fail OPEN: rc 1, NO
# output, NO traceback (convoy _read_lines parity). Assert the stderr is clean (no Traceback spew).
if ERR="$(CR rate-limit-event --log-file "$WORK/does-not-exist.jsonl" --now "$NOW" 2>&1 1>/dev/null)"; then
  fail "C2b: missing stream file must rc 1" "rc0"
elif printf '%s' "$ERR" | grep -q "Traceback"; then
  fail "C2b: missing stream file spewed a traceback" "$ERR"
else
  pass "C2b: missing stream file → rc 1, no traceback (fail-open)"
fi

# C2c — NON-UTF-8 bytes in the stream → fail OPEN (rc 1, no traceback). UnicodeDecodeError is a
# ValueError (NOT an OSError), so the read guard must catch both (convoy _read_lines parity).
printf '\x80\xff not utf8\n' > "$WORK/badenc.jsonl"
if ERR="$(CR rate-limit-event --log-file "$WORK/badenc.jsonl" --now "$NOW" 2>&1 1>/dev/null)"; then
  fail "C2c: non-UTF-8 stream must rc 1" "rc0"
elif printf '%s' "$ERR" | grep -q "Traceback"; then
  fail "C2c: non-UTF-8 stream spewed a traceback" "$ERR"
else
  pass "C2c: non-UTF-8 stream → rc 1, no traceback (fail-open)"
fi
# And arm on the same bad stream must not crash — INCLUDING the watcher shape where the SAME non-UTF-8
# file is passed as BOTH --log-file AND --text-file (the event read fails open, then the cap-text read
# must ALSO fail open, not crash). Capture output first (no pipe) so the assertion isn't vacuous under
# pipefail — the earlier bug was the --text-file read being unguarded.
ARMERR="$(CR arm --surf-dir "$WORK/surfbad" --issue 168 --now "$NOW" --log-file "$WORK/badenc.jsonl" --text-file "$WORK/badenc.jsonl" 2>&1 || true)"
if printf '%s' "$ARMERR" | grep -q "Traceback"; then
  fail "C2d: arm --log-file+--text-file crashed on non-UTF-8 stream" "$ARMERR"
elif [ -f "$WORK/surfbad/runs/168/cap-state.json" ]; then
  fail "C2d: non-UTF-8 stream must NOT arm" "armed"
else
  pass "C2d: arm --log-file+--text-file on non-UTF-8 stream → no crash, not-cap (fail-open)"
fi

# C3 — a rate_limit_event whose resetsAt is UNPARSEABLE → fail to absence (rc 1), never a bogus epoch.
rle five_hour rejected - "totally-not-a-date" > "$LOG"
if CR rate-limit-event --log-file "$LOG" --now "$NOW" >/dev/null 2>&1; then fail "C3: unparseable resetsAt must not hold" "rc0"; else pass "C3: unparseable resetsAt → no reset"; fi

# C4 — INJECTION-SAFE: fields carry shell-active text, embedded quotes, $(...) and terminal escapes.
# Parsed purely as JSON DATA from the file; must not execute, leak, or corrupt the epoch. The side
# effect (a marker file) is never created.
python3 - "$LOG" "$FIVE_RESET" <<'PY'
import json, sys
resets = int(sys.argv[2])
evil = "$(touch /tmp/sail168_pwned); `id`; \"quote\n\x1b[31mred\x1b[0m"
line = {"type": "rate_limit_event",
        "rate_limit_info": {"status": "rejected", "rateLimitType": "five_hour",
                            "resetsAt": resets, "note": evil, evil: "x"}}
open(sys.argv[1], "w").write(json.dumps(line) + "\n")
PY
rm -f /tmp/sail168_pwned
OUT="$(CR rate-limit-event --log-file "$LOG" --now "$NOW" || true)"
if [ "$(epoch_field "$OUT" 1)" = "$FIVE_RESET" ]; then pass "C4: injection payload parsed as data, epoch intact"; else fail "C4 epoch" "$OUT"; fi
if [ -e /tmp/sail168_pwned ]; then fail "C4b: injection payload EXECUTED (marker created!)" "pwned"; else pass "C4b: no shell execution of event fields"; fi

# ================================================================================================
# Part D — arm --reset-epoch: the AUTHORITATIVE event feeds the SAME single arming path (#163/#167).
#   arm applies margin + floor + ceiling + forward-only merge; writes .surf/resume-after AND
#   cap-state.json integer reset-after (the shape the #167 hop/wall-policy chain consumes). (AC3, AC4)
# ================================================================================================

SURF="$WORK/surf"; mkdir -p "$SURF"
STATE="$SURF/runs/168/cap-state.json"
state_reset() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["reset-after"])' "$STATE"; }

# D1 — arm from the event's raw epoch: cap-state.json integer reset-after == raw + margin (matching
# reset_wakeup_epoch(raw, now, margin)); resume-after RFC3339 mirrors it.
CR arm --surf-dir "$SURF" --issue 168 --now "$NOW" --reset-epoch "$FIVE_RESET" --limit-type five_hour >/dev/null
if [ ! -f "$STATE" ]; then fail "D1: cap-state.json not written by arm --reset-epoch" "missing"; else
  GOT="$(state_reset)"; EXP=$(( FIVE_RESET + MARGIN ))
  if [ "$GOT" = "$EXP" ]; then pass "D1: arm --reset-epoch → cap-state reset-after = raw + margin"; else fail "D1" "got=$GOT exp=$EXP"; fi
  # AC3: the persisted integer epoch equals usage_cap.reset_wakeup_epoch(raw, now, margin) — the exact
  # value the #167 reset_wakeup_epoch/next_hop chain consumes as --wake.
  RWE="$(python3 -c 'from sail.usage_cap import reset_wakeup_epoch; print(reset_wakeup_epoch('"$FIVE_RESET"','"$NOW"','"$MARGIN"'))')"
  if [ "$GOT" = "$RWE" ]; then pass "D1b: persisted epoch == usage_cap.reset_wakeup_epoch handoff (AC3)"; else fail "D1b" "got=$GOT rwe=$RWE"; fi
  if [ -f "$SURF/resume-after" ]; then pass "D1c: .surf/resume-after written from event"; else fail "D1c" "no resume-after"; fi
fi

# D2 — arm --reset-epoch bypasses the cap-TEXT classify: no --text-file needed, and cap text is never
# consulted (the event IS the authoritative cap signal; #126 regex retired on this path).
SURF2="$WORK/surf2"; mkdir -p "$SURF2"
CR arm --surf-dir "$SURF2" --issue 168 --now "$NOW" --reset-epoch "$SEVEN_RESET" --limit-type seven_day >/dev/null
if [ -f "$SURF2/runs/168/cap-state.json" ]; then pass "D2: arm from event needs no cap-text (regex bypassed)"; else fail "D2" "no state"; fi

# D3 — FORWARD-ONLY idempotency (risk 11): re-arming with an OLDER event epoch does NOT move the
# floor backward — a replayed/duplicate/older event can't shorten the wait.
BEFORE="$(state_reset)"
CR arm --surf-dir "$SURF" --issue 168 --now "$NOW" --reset-epoch "$((FIVE_RESET - 1000))" --limit-type five_hour >/dev/null
AFTER="$(state_reset)"
if [ "$AFTER" = "$BEFORE" ]; then pass "D3: older re-arm does not move the floor backward (forward-only)"; else fail "D3" "before=$BEFORE after=$AFTER"; fi

# ================================================================================================
# Part F — SOURCE PRECEDENCE, single-sourced in `arm` (AC2, AC7). event > cap-text > not-cap, so the
#   FP-prone #126 regex can never override a fresh structured event.
# ================================================================================================

SURF3="$WORK/surf3"; mkdir -p "$SURF3"
S3="$SURF3/runs/168/cap-state.json"
# A misleading cap-TEXT fixture whose parseable reset (FIVE_RESET) DIFFERS from the event (SEVEN).
CAPTXT="$WORK/captext.txt"
ISO_FIVE="$(python3 - "$FIVE_RESET" <<'PY'
import sys, datetime
print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"
printf 'building...\nusage limit reached; limit will reset %s\n' "$ISO_FIVE" > "$CAPTXT"

# F1 — event (seven_day, far) PRESENT alongside misleading cap TEXT (five_hour, near): the EVENT wins.
rle seven_day rejected - "$SEVEN_RESET" > "$LOG"
CR arm --surf-dir "$SURF3" --issue 168 --now "$NOW" --log-file "$LOG" --text-file "$CAPTXT" >/dev/null
GOT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["reset-after"])' "$S3")"
if [ "$GOT" = "$(( SEVEN_RESET + MARGIN ))" ]; then pass "F1: event outranks cap-text (event resetsAt wins)"; else fail "F1" "got=$GOT exp=$(( SEVEN_RESET + MARGIN ))"; fi
TYPE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["limit-type"])' "$S3")"
if [ "$TYPE" = "seven_day" ]; then pass "F1b: limit-type from event window (seven_day)"; else fail "F1b" "$TYPE"; fi

# F2 — event ABSENT (no rate_limit_event in the stream) + cap TEXT present → fall back to cap-text.
SURF4="$WORK/surf4"; mkdir -p "$SURF4"; S4="$SURF4/runs/168/cap-state.json"
echo '{"type":"assistant","message":"nothing to see"}' > "$LOG"   # a stream with NO rate_limit_event
CR arm --surf-dir "$SURF4" --issue 168 --now "$NOW" --log-file "$LOG" --text-file "$CAPTXT" >/dev/null
if [ -f "$S4" ]; then
  GOT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["reset-after"])' "$S4")"
  if [ "$GOT" = "$(( FIVE_RESET + MARGIN ))" ]; then pass "F2: event absent → cap-text fallback arms"; else fail "F2" "got=$GOT exp=$(( FIVE_RESET + MARGIN ))"; fi
else
  fail "F2: cap-text fallback did not arm" "no cap-state"
fi

# F3 — neither event NOR cap-text (event-only worker path, no --text-file) → NOT a cap, nothing armed.
SURF5="$WORK/surf5"; mkdir -p "$SURF5"
echo '{"type":"assistant","message":"clean build, committed"}' > "$LOG"
OUT="$(CR arm --surf-dir "$SURF5" --issue 168 --now "$NOW" --log-file "$LOG" || true)"
if [ -z "$OUT" ] && [ ! -f "$SURF5/runs/168/cap-state.json" ]; then pass "F3: no event + no cap-text → not-cap (build park)"; else fail "F3" "out=$OUT"; fi

# F4 — AC7 authoritative negative: a structured event that says NOT-capped (status: allowed) ALONGSIDE
# misleading cap TEXT → the event WINS and SUPPRESSES cap-text → NOT armed. This is the #126 FP class
# #168 retires: a stale cap-text tail can never arm once a structured event has spoken.
SURF7="$WORK/surf7"; mkdir -p "$SURF7"
rle five_hour allowed 0.10 "$FIVE_RESET" > "$LOG"     # event present, explicitly NOT a cap
CR arm --surf-dir "$SURF7" --issue 168 --now "$NOW" --log-file "$LOG" --text-file "$CAPTXT" >/dev/null
if [ ! -f "$SURF7/runs/168/cap-state.json" ]; then pass "F4: non-cap event suppresses cap-text fallback (AC7)"; else fail "F4: cap-text armed despite an 'allowed' event" "armed"; fi
# saw_rate_limit_event unit check (event-seen tri-state).
python3 - <<'PY' || exit 1
from sail.cap_recovery import saw_rate_limit_event
assert saw_rate_limit_event('{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour"}}') is True
assert saw_rate_limit_event('{"type":"assistant","message":"hi"}') is False
assert saw_rate_limit_event('') is False
PY
pass "F4b: saw_rate_limit_event tri-state (event present vs absent)"

# ================================================================================================
# Part G — arm --reset-epoch without --limit-type records "unknown", never the "weekly" placeholder
#   (lens1 review LOW: an event-sourced window must not be mislabeled a weekly text reset). (AC0)
# ================================================================================================
SURF6="$WORK/surf6"; mkdir -p "$SURF6"
CR arm --surf-dir "$SURF6" --issue 168 --now "$NOW" --reset-epoch "$FIVE_RESET" >/dev/null
TYPE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["limit-type"])' "$SURF6/runs/168/cap-state.json")"
if [ "$TYPE" = "unknown" ]; then pass "G1: arm --reset-epoch without --limit-type → limit-type=unknown"; else fail "G1" "got=$TYPE (expected unknown, not weekly)"; fi

# ================================================================================================
# Part E — surf-worker.sh: the worker is LAUNCHED with stream-json so a rate_limit_event exists to
#   parse (grounded risk 12: without this the parser is dead code). (AC4, AC5-shape)
# ================================================================================================

WORKER_SRC="$SRC_DIR/config/surf-worker.sh"
# shellcheck disable=SC1090
. "$WORKER_SRC"
CMD="$(surf_worker_command 42 2>/dev/null || true)"
case "$CMD" in
  *"--output-format stream-json"*"--verbose"*|*"--verbose"*"--output-format stream-json"*)
    pass "E1: surf_worker_command emits stream-json + verbose launch" ;;
  *) fail "E1: worker launch missing stream-json/verbose" "$CMD" ;;
esac
# The stream-json flags must not disturb the injection-safe prefix or the /sail --unattended prompt.
case "$CMD" in
  'claude --dangerously-skip-permissions'*' -p "/sail 42 --unattended '*)
    pass "E2: skip-permissions + /sail 42 --unattended prompt preserved" ;;
  *) fail "E2: worker command shape regressed" "$CMD" ;;
esac
if grep -q -- '--output-format stream-json' "$WORKER_SRC"; then pass "E3: surf-worker.sh source carries stream-json flag"; else fail "E3" "no stream-json in source"; fi

# ================================================================================================
echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
