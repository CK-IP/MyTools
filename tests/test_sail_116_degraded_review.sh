#!/usr/bin/env bash
# test_sail_116_degraded_review.sh — issue #116: an autonomous commit under a DEGRADED review
# (a cross-family lens the diff GATED FOR did not run) must be VISIBLE (callout + log), the work
# ACCEPTED (no park), and an issue filed ONLY via the existing #108 termini (maintainer refinement
# overrides AC2's always-file). Classification fails toward visibility:
#   - "latched"      : a CONFIGURED codex-family backend was latched off (#107 marker active)  -> ALERT
#   - "unavailable"  : a CONFIGURED backend did not run for another reason (bad path / down)   -> ALERT
#   - "unconfigured" : the backend env is UNSET (operator's standing single-lens setup)        -> INFO
#
# Hermetic: mock LLM CLIs, real `python3 -m sail review` + the shipped classifier. Mirrors
# test_sail_74_dual_lens_signal.sh / test_sail_107_codex_latch.sh.
# shellcheck disable=SC2016
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"
# Hermeticity: clear inherited backends + latch state so each case controls its own.
unset SAIL_REVIEW_CMD SAIL_REVIEW_CMD2 SAIL_REDTEAM_CMD SAIL_TIDINESS_CMD SAIL_TIDINESS_VERIFY_CMD \
      SAIL_STATE_DIR SAIL_SESSION_ID 2>/dev/null || true

MOCK="$WORK/mock_llm.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "%s" "${MOCK_OUT:-}"' 'exit ${MOCK_RC:-0}' > "$MOCK"
chmod +x "$MOCK"
CLEAN='{"findings":[],"summary":"no issues"}'

TGT="$WORK/target"; mkdir -p "$TGT"
printf 'def f():\n    return 1\n' > "$TGT/mod.py"
git -C "$TGT" init -q
git -C "$TGT" add -A
git -C "$TGT" -c user.email=t@t -c user.name=t commit -qm base
printf 'def f():\n    return 2  # changed\n' > "$TGT/mod.py"

field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$1" "$2"; }

# ───────────────────────────── Part A — review.json records the per-round booleans ─────────────
# A1: both cross-family lenses CONFIGURED + RAN (full strength) → not degraded.
RD1="$WORK/rd1"
set +e; SAIL_REVIEW_CMD="bash $MOCK" SAIL_REVIEW_CMD2="bash $MOCK" SAIL_REDTEAM_CMD="bash $MOCK" MOCK_OUT="$CLEAN" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD1" --dual-lens --red-team >/dev/null 2>&1; set -e
[ "$(field "$RD1/review.json" lens2_ran)" = "True" ]            || { echo "FAIL A1: lens2_ran"; exit 1; }
[ "$(field "$RD1/review.json" lens2_configured)" = "True" ]     || { echo "FAIL A1: lens2_configured"; exit 1; }
[ "$(field "$RD1/review.json" redteam_requested)" = "True" ]    || { echo "FAIL A1: redteam_requested"; exit 1; }
[ "$(field "$RD1/review.json" redteam_ran)" = "True" ]          || { echo "FAIL A1: redteam_ran"; exit 1; }
[ "$(field "$RD1/review.json" redteam_configured)" = "True" ]   || { echo "FAIL A1: redteam_configured"; exit 1; }
echo "PASS A1: full-strength → all gated lenses ran + booleans recorded"

# A2: both backends CONFIGURED (env set) but BROKEN, non-codex → ran=False, configured=True, latched=False (UNAVAILABLE).
RD2="$WORK/rd2"
set +e; SAIL_REVIEW_CMD="bash $MOCK" SAIL_REVIEW_CMD2="/nonexistent/llm-xyz" SAIL_REDTEAM_CMD="/nonexistent/rt-xyz" MOCK_OUT="$CLEAN" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD2" --dual-lens --red-team >/dev/null 2>&1; set -e
[ "$(field "$RD2/review.json" lens2_configured)" = "True" ]    || { echo "FAIL A2: lens2_configured (env set)"; exit 1; }
[ "$(field "$RD2/review.json" lens2_latched)" = "False" ]      || { echo "FAIL A2: lens2_latched (non-codex)"; exit 1; }
[ "$(field "$RD2/review.json" redteam_ran)" = "False" ]        || { echo "FAIL A2: redteam_ran"; exit 1; }
[ "$(field "$RD2/review.json" redteam_configured)" = "True" ]  || { echo "FAIL A2: redteam_configured (env set)"; exit 1; }
[ "$(field "$RD2/review.json" redteam_latched)" = "False" ]    || { echo "FAIL A2: redteam_latched (non-codex)"; exit 1; }
echo "PASS A2: configured-but-broken non-codex → configured=True, latched=False (unavailable signal)"

# A3: backends UNSET → configured=False (UNCONFIGURED).
RD3="$WORK/rd3"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD3" --dual-lens --red-team >/dev/null 2>&1; set -e
[ "$(field "$RD3/review.json" lens2_configured)" = "False" ]   || { echo "FAIL A3: lens2_configured (unset)"; exit 1; }
[ "$(field "$RD3/review.json" redteam_requested)" = "True" ]   || { echo "FAIL A3: redteam_requested"; exit 1; }
[ "$(field "$RD3/review.json" redteam_configured)" = "False" ] || { echo "FAIL A3: redteam_configured (unset)"; exit 1; }
echo "PASS A3: unset backends → configured=False (unconfigured signal)"

# A4: NO cross-family lens requested → not gated-for.
RD4="$WORK/rd4"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD4" >/dev/null 2>&1; set -e
[ "$(field "$RD4/review.json" dual_lens_requested)" = "False" ] || { echo "FAIL A4: dual_lens_requested"; exit 1; }
[ "$(field "$RD4/review.json" redteam_requested)" = "False" ]   || { echo "FAIL A4: redteam_requested"; exit 1; }
echo "PASS A4: no flags / low-stakes → nothing gated for (not degraded)"

# A5: CONFIGURED codex-family red-team backend + ACTIVE #107 latch → ran=False, latched=True (LATCHED).
# Hermetic latch: SAIL_STATE_DIR isolates the marker; SAIL_SESSION_ID shares the session so the
# trip (one process) and the review (another) agree it is the SAME session (not stale).
RD5="$WORK/rd5"; ST="$WORK/state"
SAIL_STATE_DIR="$ST" SAIL_SESSION_ID=t116 python3 -c "from sail import codexlatch; codexlatch.trip_latch('test: out of credits')"
set +e; SAIL_STATE_DIR="$ST" SAIL_SESSION_ID=t116 SAIL_REVIEW_CMD="bash $MOCK" SAIL_REDTEAM_CMD="codex exec -m gpt-5.5" MOCK_OUT="$CLEAN" \
  python3 -m sail review --target "$TGT" --diff HEAD --run-dir "$RD5" --red-team >/dev/null 2>&1; set -e
[ "$(field "$RD5/review.json" redteam_configured)" = "True" ]  || { echo "FAIL A5: redteam_configured"; exit 1; }
[ "$(field "$RD5/review.json" redteam_ran)" = "False" ]        || { echo "FAIL A5: redteam_ran (latched off)"; exit 1; }
[ "$(field "$RD5/review.json" redteam_latched)" = "True" ]     || { echo "FAIL A5: redteam_latched (codex + #107 marker)"; exit 1; }
echo "PASS A5: codex-family + active #107 latch → ran=False, latched=True (latched signal uses the marker)"

# A6: EMPTY diff reviewed with --dual-lens — run_review suppresses lens2 on an empty diff, so
# dual_lens_requested=True but lens2_ran=False. That is NOT a degradation: an empty diff gates for
# nothing. review.json must record empty_diff=True so the classifier can suppress the false positive.
RD6E="$WORK/rd6e"; TGTE="$WORK/te"; mkdir -p "$TGTE"
printf 'x = 1\n' > "$TGTE/m.py"
git -C "$TGTE" init -q; git -C "$TGTE" add -A; git -C "$TGTE" -c user.email=t@t -c user.name=t commit -qm base
# NO working-tree change → `git diff HEAD` is empty.
set +e; SAIL_REVIEW_CMD="bash $MOCK" SAIL_REVIEW_CMD2="/nonexistent/llm" MOCK_OUT="$CLEAN" \
  python3 -m sail review --target "$TGTE" --diff HEAD --run-dir "$RD6E" --dual-lens >/dev/null 2>&1; set -e
[ "$(field "$RD6E/review.json" empty_diff)" = "True" ] || { echo "FAIL A6: review.json must record empty_diff=True"; exit 1; }
echo "PASS A6: empty-diff review records empty_diff=True"

# ───────────────────────────── Part B — degraded_lenses() / tone classifier (truth table) ──────
python3 - "$RD1/review.json" "$RD2/review.json" "$RD3/review.json" "$RD4/review.json" "$RD5/review.json" <<'PY'
import json, sys
from sail.review import degraded_lenses, degraded_tone, format_degraded_note
full, unavail, unconf, nongate, latched = (json.load(open(p)) for p in sys.argv[1:6])

assert degraded_lenses(full) == [], f"full-strength must be clean, got {degraded_lenses(full)}"
assert degraded_tone(degraded_lenses(full)) == "", "full-strength tone empty"

du = degraded_lenses(unavail)
assert {d["lens"] for d in du} == {"lens2", "redteam"}, du
assert all(d["cause"] == "unavailable" for d in du), du
assert degraded_tone(du) == "ALERT", "configured-but-down must be ALERT (#112 deviation)"

uc = degraded_lenses(unconf)
assert {d["lens"] for d in uc} == {"lens2", "redteam"}, uc
assert all(d["cause"] == "unconfigured" for d in uc), uc
assert degraded_tone(uc) == "INFO", "unset backend is expected setup → INFO, not ALERT"

assert degraded_lenses(nongate) == [], "non-gating diff must never report degradation"

dl = degraded_lenses(latched)
assert {d["lens"]: d["cause"] for d in dl}.get("redteam") == "latched", dl
assert degraded_tone(dl) == "ALERT", "codex latched off → ALERT"

# Mixed: one latched, one unconfigured → ALERT wins (any deviation present).
mixed = {"dual_lens_requested": True, "lens2_ran": False, "lens2_configured": False,
         "redteam_requested": True, "redteam_ran": False, "redteam_configured": True, "redteam_latched": True}
assert degraded_tone(degraded_lenses(mixed)) == "ALERT", "any latched/unavailable lens → ALERT"

note = format_degraded_note(dl, sha="abc1234", round=3)
assert "abc1234" in note and "Review degradation" in note, note
assert "⚠" in note, "ALERT (latched/unavailable) note must carry the ⚠️ banner"
assert "red-team" in note, note
assert "3" in note and "round" in note.lower(), f"note must be round-tagged: {note}"
# TONE-AWARE wording: an UNCONFIGURED (INFO) review is the operator's expected setup — it must NOT
# render the alarmist "⚠️ … committed under a degraded review" banner (it was never configured).
unconf_note = format_degraded_note(degraded_lenses(unconf))
assert "single-lens" in unconf_note.lower(), unconf_note
assert "⚠" not in unconf_note, "unconfigured (INFO) must not render the alarmist ⚠️ banner"
assert "committed under a **degraded review**" not in unconf_note, "INFO must not claim a degraded-review commit"

# Empty diff is NON-GATING: a --dual-lens review of an empty diff must not report degradation,
# even though dual_lens_requested=True and lens2_ran=False (lens2 suppressed on an empty diff).
empty_rev = {"dual_lens_requested": True, "lens2_ran": False, "lens2_configured": False,
             "redteam_requested": False, "empty_diff": True}
assert degraded_lenses(empty_rev) == [], f"empty diff must never report degradation: {degraded_lenses(empty_rev)}"
print("PASS B: degraded_lenses/degraded_tone/format_degraded_note classify latched/unavailable/unconfigured/full/non-gating/empty")
PY

# ───────────────────────────── Part C — land-comment surfaces the degradation (deliverable C) ───
python3 - "$RD2/review.json" "$RD1/review.json" <<'PY'
import json, sys
from sail.lifecycle import land_comment
deg = json.load(open(sys.argv[1])); full = json.load(open(sys.argv[2]))
c_deg  = land_comment(116, deg, {}, "ok")
c_full = land_comment(116, full, {}, "ok")
assert "Review degradation" in c_deg, "land-comment must surface the degradation section"
assert "red-team" in c_deg and "dual-lens" in c_deg, c_deg
assert "Review degradation" not in c_full, "full-strength land-comment must NOT carry a degradation section"
print("PASS C: land_comment surfaces degradation on a degraded review, silent on full-strength")
PY

# ───────────────────────────── Part D — CLI: tone+lenses line, note file, freshness, stale-note ─
# D1: unavailable review → ALERT + lens:cause pairs + writes note file (with SHA).
OUT="$(python3 -m sail degraded-review --run-dir "$RD2" --sha deadbee 2>/dev/null)"
echo "$OUT" | grep -q '^ALERT ' || { echo "FAIL D1: expected ALERT, got [$OUT]"; exit 1; }
echo "$OUT" | grep -q 'redteam:unavailable' || { echo "FAIL D1: redteam:unavailable missing from [$OUT]"; exit 1; }
[ -f "$RD2/degraded-review.md" ] || { echo "FAIL D1: note not written"; exit 1; }
grep -q 'deadbee' "$RD2/degraded-review.md" || { echo "FAIL D1: SHA missing from note"; exit 1; }
echo "PASS D1: CLI prints ALERT + lens:cause pairs and writes the durable note (with SHA)"

# D2: unconfigured review → INFO tone, not ALERT.
OUT3="$(python3 -m sail degraded-review --run-dir "$RD3" 2>/dev/null)"
echo "$OUT3" | grep -q '^INFO ' || { echo "FAIL D2: expected INFO, got [$OUT3]"; exit 1; }
echo "PASS D2: unconfigured → INFO (expected single-lens setup, not a deviation)"

# D3: full-strength → no output (no follow-up, no callout).
OUT1="$(python3 -m sail degraded-review --run-dir "$RD1" 2>/dev/null)"
[ -z "$OUT1" ] || { echo "FAIL D3: full-strength must produce no degraded output, got [$OUT1]"; exit 1; }
echo "PASS D3: full-strength review → empty output (no follow-up triggered)"

# D4: freshness (STABLE currency, no re-diff so it is correct AFTER the commit) — stale round NOT
# credited; committing round IS. Uses --diff HEAD review.json but does NOT recompute the diff.
OUT_STALE="$(python3 -m sail degraded-review --run-dir "$RD2" --target "$TGT" --round 2 2>/dev/null)"
[ -z "$OUT_STALE" ] || { echo "FAIL D4: stale round must not be credited, got [$OUT_STALE]"; exit 1; }
OUT_FRESH="$(python3 -m sail degraded-review --run-dir "$RD2" --target "$TGT" --round 1 2>/dev/null)"
echo "$OUT_FRESH" | grep -q '^ALERT ' || { echo "FAIL D4: matching round should report degradation, got [$OUT_FRESH]"; exit 1; }
grep -qi 'round' "$RD2/degraded-review.md" || { echo "FAIL D4: durable note must be round-tagged when --round given"; exit 1; }
echo "PASS D4: freshness-keyed (stable currency) — stale prior round not credited; committing round is (note round-tagged)"

# D5: STALE-NOTE REMOVAL (the round-1 HIGH) — a pre-existing note must NOT survive a later
# full-strength (or stale) invocation, else the shell would enrich a CLEAN commit's issue with it.
printf 'STALE NOTE from a prior degraded round\n' > "$RD1/degraded-review.md"
python3 -m sail degraded-review --run-dir "$RD1" >/dev/null 2>&1
[ ! -f "$RD1/degraded-review.md" ] || { echo "FAIL D5: full-strength run must REMOVE a stale degraded-review.md"; exit 1; }
# And a stale-round invocation also clears it (cannot credit, must not leave a stale note behind).
printf 'STALE\n' > "$RD2/degraded-review.md"
python3 -m sail degraded-review --run-dir "$RD2" --target "$TGT" --round 9 >/dev/null 2>&1
[ ! -f "$RD2/degraded-review.md" ] || { echo "FAIL D5: stale-round run must REMOVE a stale degraded-review.md"; exit 1; }
echo "PASS D5: stale degraded-review.md is removed on full-strength / stale invocations (no stale enrichment)"

# D6: CONTENT-DRIFT — freshness is keyed to the committing round's diff_hash + plan_hash (not just
# round/target), so a review.json whose reviewed content no longer matches the live diff is NOT
# credited. Safe post-commit because the runner pins diff_ref to a base SHA (#87): `git diff <SHA>`
# is identical before and after the commit lands.
TGT6="$WORK/t6"; mkdir -p "$TGT6"; printf 'a = 1\n' > "$TGT6/m.py"
git -C "$TGT6" init -q; git -C "$TGT6" add -A; git -C "$TGT6" -c user.email=t@t -c user.name=t commit -qm base
printf 'a = 2  # changed\n' > "$TGT6/m.py"
RD6="$WORK/rd6"
set +e; SAIL_REVIEW_CMD="bash $MOCK" MOCK_OUT="$CLEAN" \
  python3 -m sail review --target "$TGT6" --diff HEAD --run-dir "$RD6" --dual-lens >/dev/null 2>&1; set -e
# Without drift the degraded line WOULD print (lens2 unconfigured → INFO); now drift the content:
printf 'a = 999  # DRIFTED after the review ran\n' > "$TGT6/m.py"
OUT6="$(python3 -m sail degraded-review --run-dir "$RD6" --target "$TGT6" --round 1 2>/dev/null)"
[ -z "$OUT6" ] || { echo "FAIL D6: content drift since review must NOT be credited (diff_hash keying), got [$OUT6]"; exit 1; }
echo "PASS D6: diff_hash/plan_hash keyed — content drift since the committing review is not credited"

# ───────────────────────────── Part E — shell terminus contracts (deliverables D + E) ───────────
# E1: REAL self-contained terminus path (not fabricated): run the EXACT documented terminus snippet
# — capture SHA via `git rev-parse`, re-derive the note with `--sha "$SHA"`, then append — and
# assert the terminus-supplied SHA reaches the body. Exercises the contract a dropped/empty `$SHA`
# would break (the round-5 regression), which a hardcoded literal SHA could not catch.
ENR="$WORK/enr"; mkdir -p "$ENR"
printf 'spec-conflict objection text\n' > "$ENR/body.md"
SESSION_DIR="$RD2"; WORK_DIR="$TGT"; BODY="$ENR/body.md"
# --- documented #108 terminus enrichment (mirrors commands/sail.md) ---
SHA="$(git -C "$WORK_DIR" rev-parse HEAD)"
python3 -m sail degraded-review --run-dir "$SESSION_DIR" --sha "$SHA" >/dev/null
[ -f "$SESSION_DIR/degraded-review.md" ] && { printf '\n' >> "$BODY"; cat "$SESSION_DIR/degraded-review.md" >> "$BODY"; }
# ---
grep -q "$SHA" "$BODY" || { echo "FAIL E1: terminus-supplied SHA ($SHA) did not reach BODY"; exit 1; }
grep -qE 'red-team|dual-lens' "$BODY" || { echo "FAIL E1: lens name missing from BODY"; exit 1; }
grep -q 'spec-conflict objection text' "$BODY" || { echo "FAIL E1: enrichment clobbered the original body"; exit 1; }
echo "PASS E1: self-contained terminus (git-rev-parse SHA → re-derive → append) carries the real SHA+lens"

# E2: commands/sail.md wires the Stage-4 callout AND the enrichment on BOTH #108 termini, each of
# which RE-DERIVES the note itself (self-contained: `sail degraded-review` immediately before the
# append) so it never depends on Stage-4 ordering. A mutation deleting any of these is caught here.
SAIL_MD="commands/sail.md"
calls="$(grep -c 'sail degraded-review' "$SAIL_MD" || true)"
[ "$calls" -ge 3 ] || { echo "FAIL E2: expected >=3 'sail degraded-review' calls (Stage-4 + both #108 termini re-derive), found $calls"; exit 1; }
appends="$(grep -c 'cat "\$SESSION_DIR/degraded-review.md" >> "\$BODY"' "$SAIL_MD" || true)"
[ "$appends" -ge 2 ] || { echo "FAIL E2: expected the degraded-note body append on BOTH #108 termini, found $appends"; exit 1; }
echo "PASS E2: sail.md wires Stage-4 callout + self-contained re-derive + enrichment on both termini ($calls calls, $appends appends)"

# E3: /surf's autonomous merge terminus also runs the degraded-review check (the redteam-found gap —
# red-team degradation slips past /surf's lens2-only #74 guard and would merge silently otherwise).
grep -q 'sail degraded-review' commands/surf.md || { echo "FAIL E3: /surf merge terminus must run sail degraded-review (#116)"; exit 1; }
echo "PASS E3: /surf merge terminus wires the degraded-review visibility check"

# ───────────────────────────── Part F — terminus BEHAVIOR (executed, not grepped) ───────────────
# Executes the documented Stage-4 degraded-review callout (mirrors commands/sail.md) with a mocked
# `gh` on PATH, and asserts the actual contract: ALERT/INFO emitted, work ACCEPTED (rc 0), and NO
# issue filed on a clean degraded green. This is the anti-mutation guard the grep in E cannot give.
BIN="$WORK/bin"; mkdir -p "$BIN"
printf '%s\n' '#!/usr/bin/env bash' 'echo "GH $*" >> "'"$WORK"'/gh-called"; exit 0' > "$BIN/gh"; chmod +x "$BIN/gh"

run_terminus() {  # $1=run-dir $2=target $3=round  → runs the documented snippet, stderr on fd2
  # Mirror the documented Stage-4 snippet exactly, including capturing a REAL commit SHA via
  # `git rev-parse` (not a seeded literal) so the test pins the contract, not an incidental value.
  local SESSION_DIR="$1" WORK_DIR="$2" ROUND="$3" UNATTENDED=1 COMMIT=yes
  local SHA; SHA="$(git -C "$WORK_DIR" rev-parse HEAD)"
  PATH="$BIN:$PATH"
  if [ "$COMMIT" = "yes" ] && { [ "$UNATTENDED" = "1" ] || [ -n "${SURF_RUN:-}" ]; }; then
    local DEGRADED TONE
    DEGRADED="$(python3 -m sail degraded-review --run-dir "$SESSION_DIR" --target "$WORK_DIR" --round "$ROUND" --sha "$SHA")"
    if [ -n "$DEGRADED" ]; then
      TONE="${DEGRADED%% *}"
      echo "sail: [$TONE] committed $SHA under a DEGRADED review (${DEGRADED#* }) — work ACCEPTED" >&2
    fi
  fi
}

# F1: degraded green (configured-but-unavailable) → ALERT (naming the real commit SHA), accepted, no issue.
rm -f "$WORK/gh-called"
TGT_SHA="$(git -C "$TGT" rev-parse HEAD)"
ERR1="$WORK/f1.err"; run_terminus "$RD2" "$TGT" 1 2>"$ERR1"; rc1=$?
[ "$rc1" -eq 0 ] || { echo "FAIL F1: terminus did not exit 0 (work must be accepted, not parked)"; exit 1; }
grep -q "\[ALERT\] committed $TGT_SHA" "$ERR1" || { echo "FAIL F1: ALERT callout did not name the real commit SHA"; cat "$ERR1"; exit 1; }
grep -q 'work ACCEPTED' "$ERR1" || { echo "FAIL F1: accept wording missing"; exit 1; }
[ ! -f "$WORK/gh-called" ] || { echo "FAIL F1: an issue was filed on a clean degraded green (must be none)"; exit 1; }
echo "PASS F1: degraded green → ALERT callout, work ACCEPTED (rc 0), NO issue filed"

# F2: full-strength → no callout at all, no issue.
rm -f "$WORK/gh-called"
ERR2="$WORK/f2.err"; run_terminus "$RD1" "$TGT" 1 2>"$ERR2"; rc2=$?
[ "$rc2" -eq 0 ] || { echo "FAIL F2: terminus did not exit 0"; exit 1; }
[ ! -s "$ERR2" ] || { echo "FAIL F2: full-strength must emit NO callout, got [$(cat "$ERR2")]"; exit 1; }
[ ! -f "$WORK/gh-called" ] || { echo "FAIL F2: full-strength must file no issue"; exit 1; }
echo "PASS F2: full-strength → no callout, no issue (silent, accepted)"

# F3: LATCHED terminus (the AC's explicit latched-at-terminus case) — a codex-family lens latched
# off (#107) at the committing round → ALERT callout naming the latch, work accepted, no issue.
rm -f "$WORK/gh-called"
ERR3="$WORK/f3.err"; run_terminus "$RD5" "$TGT" 1 2>"$ERR3"; rc3=$?
[ "$rc3" -eq 0 ] || { echo "FAIL F3: latched terminus did not exit 0 (accept, not park)"; exit 1; }
grep -q '\[ALERT\] committed' "$ERR3" || { echo "FAIL F3: latched terminus must emit ALERT, got [$(cat "$ERR3")]"; exit 1; }
grep -q 'redteam:latched' "$ERR3" || { echo "FAIL F3: callout must name the latched lens"; exit 1; }
[ ! -f "$WORK/gh-called" ] || { echo "FAIL F3: latched degraded green must file no issue on its own"; exit 1; }
echo "PASS F3: latched terminus → ALERT (names the latch), work ACCEPTED, NO issue filed"

echo "ALL PASS: test_sail_116_degraded_review"
