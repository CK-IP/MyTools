#!/usr/bin/env bash
# test_sail_learn.sh — #147: /sail learning loop (post-land root-cause grouping into
#   PROPOSED .ship/domain.md rules; human-approved, NEVER auto-applied).
#
# Split by the infrastructure-placement rule (judgment→LLM, decisions→tested Python):
#   - the JUDGMENT (grouping findings into root-cause classes + drafting rule text) is a cheap
#     LLM pass — exercised hermetically here via a STUB backend that echoes canned JSON;
#   - the DETERMINISTIC parts (collect/parse/dedupe/render/assembly/apply + fail-open) are unit-
#     tested directly, the established test_sail_95/113/131 inline-python pattern.
#
# Hermetic: unset SAIL_* (a real shell exports codex knobs), throwaway target, no live git-diff.
# shellcheck disable=SC1091,SC2016
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
unset "${!SAIL_@}" || true
export SAIL_STATE_DIR="$WORK/sail-state"   # isolate the #107 codex-down latch
cd "$REPO_ROOT"
fail() { echo "FAIL: $*"; exit 1; }

# --- Fixtures: a finished run-dir with a review.json (blocking + non-blocking findings) and a
#     decision-log carrying per-finding dispositions. -------------------------------------------
RD="$WORK/rd"; mkdir -p "$RD"
cat > "$RD/review.json" <<'JSON'
{
  "status": "completed",
  "counts": {"CRITICAL": 0, "HIGH": 2, "MEDIUM": 1, "LOW": 0},
  "findings": [
    {"id": "F1", "severity": "HIGH", "category": "portability", "file": "doctor.sh", "line": 31,
     "issue": "bash-only path augmentation breaks under the zsh runtime", "lens": "lens1"},
    {"id": "F2", "severity": "HIGH", "category": "portability", "file": "install.sh", "line": 9,
     "issue": "setsid is unavailable on macOS", "lens": "redteam"},
    {"id": "F3", "severity": "MEDIUM", "category": "style", "file": "x.py", "line": 4,
     "issue": "a non-blocking nit", "lens": "lens1"}
  ]
}
JSON
# decision-log dispositions (the DecisionLog format is authoritative)
python3 - "$RD" <<'PY'
import sys
from sail.decisionlog import DecisionLog
log = DecisionLog(sys.argv[1])
log.finding_resolution("F1", "addressed", "added a zsh runtime seam", round=2)
log.finding_resolution("F2", "addressed", "guarded setsid behind an availability check", round=2)
PY

# ============================================================================
# T1 — collect_history: hydrates ONLY blocking (CRITICAL/HIGH) findings with disposition+round
# ============================================================================
python3 - "$RD" <<'PY' || fail "T1: collect_history contract"
import sys
from sail.learn import collect_history
recs = collect_history(sys.argv[1])
ids = sorted(r["id"] for r in recs)
assert ids == ["F1", "F2"], f"only blocking findings hydrated, got {ids}"
by = {r["id"]: r for r in recs}
assert by["F1"]["severity"] == "HIGH"
assert by["F1"]["issue"].startswith("bash-only")
assert by["F1"]["disposition"] == "addressed"
assert by["F1"]["rationale"] == "added a zsh runtime seam"
assert by["F1"]["round"] == 2
assert by["F1"]["category"] == "portability"
print("ok")
PY
echo "PASS T1: collect_history hydrates blocking findings + dispositions"

# ============================================================================
# T2 — collect_history is FAIL-OPEN: missing/malformed review.json -> [] (never raises)
# ============================================================================
python3 - "$WORK" <<'PY' || fail "T2: collect_history fail-open"
import os, sys
from sail.learn import collect_history
assert collect_history(os.path.join(sys.argv[1], "nope")) == []      # missing dir
bad = os.path.join(sys.argv[1], "bad"); os.makedirs(bad, exist_ok=True)
open(os.path.join(bad, "review.json"), "w").write("{ not json")
assert collect_history(bad) == []                                     # malformed
print("ok")
PY
echo "PASS T2: collect_history fail-open on missing/malformed"

# ============================================================================
# T3 — parse_learn: one object WITH the "groups" key (mirrors parse_plan fail-closed idiom)
# ============================================================================
python3 - <<'PY' || fail "T3: parse_learn contract"
from sail.learn import parse_learn
good = '''prose... {"groups": [{"root_cause_class": "domain_gap", "finding_ids": ["F1"],
  "summary": "s", "proposed_rule": {"title": "T", "body": "B", "source": "#147"}}]} trailing'''
p = parse_learn(good)
assert p is not None and len(p["groups"]) == 1
assert parse_learn("no json here") is None
# two objects WITH the key -> fail closed (None)
assert parse_learn('{"groups": []} {"groups": []}') is None
print("ok")
PY
echo "PASS T3: parse_learn extracts groups, fails closed"

# ============================================================================
# T4 — domain_gap_rules: only domain_gap groups yield proposed rule text
# ============================================================================
python3 - <<'PY' || fail "T4: domain_gap_rules"
from sail.learn import domain_gap_rules
parsed = {"groups": [
  {"root_cause_class": "domain_gap", "finding_ids": ["F1"], "summary": "s",
   "proposed_rule": {"title": "Zsh runtime seam", "body": "B1", "source": "#147"}},
  {"root_cause_class": "plan_gap", "finding_ids": ["F2"], "summary": "s"},
  {"root_cause_class": "emergent", "finding_ids": ["F3"], "summary": "s"},
]}
rules = domain_gap_rules(parsed)
assert len(rules) == 1, f"only domain_gap yields a rule, got {len(rules)}"
assert rules[0]["title"] == "Zsh runtime seam"
print("ok")
PY
echo "PASS T4: domain_gap_rules filters to domain_gap only"

# ============================================================================
# T5 — dedupe_rules: drop a rule whose title matches an existing domain.md heading; keep novel
# ============================================================================
python3 - <<'PY' || fail "T5: dedupe_rules"
from sail.learn import dedupe_rules
domain = "# D\n\n## Rules\n\n### Shell scripts use set -euo pipefail\nBody.\n\n*Source: x.*\n"
rules = [
  {"title": "Shell scripts use set -euo pipefail", "body": "dup", "source": "#147"},   # dup title
  {"title": "Zsh runtime seam for PATH augmentation", "body": "novel", "source": "#147"},
]
kept, dropped = dedupe_rules(rules, domain)
assert [r["title"] for r in kept] == ["Zsh runtime seam for PATH augmentation"], kept
assert len(dropped) == 1 and dropped[0]["title"].startswith("Shell scripts"), dropped
# no existing domain text -> everything kept
kept2, dropped2 = dedupe_rules(rules, "")
assert len(kept2) == 2 and dropped2 == []
print("ok")
PY
echo "PASS T5: dedupe_rules drops title-duplicates, keeps novel"

# ============================================================================
# T6 — render_rule_markdown: exact domain.md rule format (### title / body / *Source:*)
# ============================================================================
python3 - <<'PY' || fail "T6: render_rule_markdown"
from sail.learn import render_rule_markdown
md = render_rule_markdown({"title": "T", "body": "The body.", "source": "#147"})
assert md.startswith("### T\n"), md
assert "The body." in md
assert "*Source: #147*" in md
print("ok")
PY
echo "PASS T6: render_rule_markdown matches domain.md format"

# ============================================================================
# T7 — run_learn FAIL-OPEN with NO backend (SAIL_LEARN_CMD + SAIL_REVIEW_CMD unset):
#      exit 0, learn.json status=skipped, proposals md written, domain.md NEVER touched, no crash
# ============================================================================
TGT="$WORK/tgt7"; mkdir -p "$TGT/.ship"
printf 'ORIG DOMAIN\n' > "$TGT/.ship/domain.md"
BEFORE="$(md5 -q "$TGT/.ship/domain.md" 2>/dev/null || md5sum "$TGT/.ship/domain.md" | cut -d' ' -f1)"
set +e
( unset SAIL_LEARN_CMD SAIL_REVIEW_CMD
  python3 -m sail learn --run-dir "$RD" --target "$TGT" --unattended 1 ) >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 0 ] || fail "T7: run_learn must exit 0 with no backend (fail-open), got $rc"
[ -f "$RD/learn.json" ] || fail "T7: learn.json must be written"
st="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("status"))' "$RD/learn.json")"
[ "$st" = skipped ] || fail "T7: status should be skipped with no backend, got $st"
[ -f "$RD/learn-proposals.md" ] || fail "T7: learn-proposals.md must be written"
AFTER="$(md5 -q "$TGT/.ship/domain.md" 2>/dev/null || md5sum "$TGT/.ship/domain.md" | cut -d' ' -f1)"
[ "$BEFORE" = "$AFTER" ] || fail "T7: run_learn must NEVER modify domain.md"
echo "PASS T7: run_learn fail-open (no backend) never touches domain.md"

# ============================================================================
# T8 — run_learn END-TO-END with a STUB backend echoing canned classification JSON:
#      proposals assembled into learn-proposals.md; domain.md still byte-identical (unattended);
#      a domain_gap rule already present in domain.md is DEDUPED out of the proposals.
# ============================================================================
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/learnstub" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
cat <<'JSON'
{"groups": [
  {"root_cause_class": "domain_gap", "finding_ids": ["F1"], "summary": "runtime shell mismatch",
   "proposed_rule": {"title": "Verify sourced libs under the real runtime shell",
     "body": "A bash-only lib sourced under zsh can break; probe it under the runtime shell.",
     "source": "#147 — F1/F2 recurred as portability findings."}},
  {"root_cause_class": "domain_gap", "finding_ids": ["F2"], "summary": "existing rule",
   "proposed_rule": {"title": "Shell scripts use set -euo pipefail",
     "body": "dup of an existing rule", "source": "#147"}},
  {"root_cause_class": "implementation_drift", "finding_ids": ["F3"], "summary": "drift only"}
]}
JSON
STUB
chmod +x "$BIN/learnstub"

TGT8="$WORK/tgt8"; mkdir -p "$TGT8/.ship"
cat > "$TGT8/.ship/domain.md" <<'DOM'
# D

## Rules

### Shell scripts use set -euo pipefail
Body.

*Source: x.*
DOM
BEFORE8="$(md5 -q "$TGT8/.ship/domain.md" 2>/dev/null || md5sum "$TGT8/.ship/domain.md" | cut -d' ' -f1)"
RD8="$WORK/rd8"; cp -R "$RD/." "$RD8/"
set +e
( unset SAIL_REVIEW_CMD
  SAIL_LEARN_CMD="$BIN/learnstub" PATH="$BIN:$PATH" \
    python3 -m sail learn --run-dir "$RD8" --target "$TGT8" --unattended 1 ) >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 0 ] || fail "T8: run_learn end-to-end must exit 0, got $rc"
st8="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("status"))' "$RD8/learn.json")"
[ "$st8" = completed ] || fail "T8: status should be completed with a backend, got $st8"
grep -q "Verify sourced libs under the real runtime shell" "$RD8/learn-proposals.md" \
  || fail "T8: novel domain_gap rule must appear in proposals"
# the existing-rule proposal must be DEDUPED out of the proposed set
n_prop="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("proposed_rules",[])))' "$RD8/learn.json")"
[ "$n_prop" = 1 ] || fail "T8: exactly 1 rule should survive dedupe, got $n_prop"
AFTER8="$(md5 -q "$TGT8/.ship/domain.md" 2>/dev/null || md5sum "$TGT8/.ship/domain.md" | cut -d' ' -f1)"
[ "$BEFORE8" = "$AFTER8" ] || fail "T8: unattended run_learn must NEVER modify domain.md"
echo "PASS T8: run_learn end-to-end assembles+dedupes proposals; domain.md untouched (unattended)"

# ============================================================================
# T9 — supervised apply: appends a selected proposal to domain.md; idempotent (no duplicate)
# ============================================================================
set +e
SAIL_LEARN_CMD="$BIN/learnstub" PATH="$BIN:$PATH" \
  python3 -m sail learn --apply --indices 0 --run-dir "$RD8" --target "$TGT8" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" = 0 ] || fail "T9: apply must exit 0, got $rc"
grep -q "### Verify sourced libs under the real runtime shell" "$TGT8/.ship/domain.md" \
  || fail "T9: accepted rule must be appended to domain.md"
# re-apply the same index -> idempotent (still exactly one occurrence)
SAIL_LEARN_CMD="$BIN/learnstub" PATH="$BIN:$PATH" \
  python3 -m sail learn --apply --indices 0 --run-dir "$RD8" --target "$TGT8" >/dev/null 2>&1 || true
n_head="$(grep -c "### Verify sourced libs under the real runtime shell" "$TGT8/.ship/domain.md")"
[ "$n_head" = 1 ] || fail "T9: apply must be idempotent, got $n_head occurrences"
echo "PASS T9: supervised apply appends accepted rule (idempotent)"

# ============================================================================
# T10 — proposals md carries ALL root-cause classes (not just domain_gap) for the human report
# ============================================================================
grep -q "implementation_drift" "$RD8/learn-proposals.md" \
  || fail "T10: proposals md must surface every root-cause class for the reviewer"
grep -qi "domain_gap" "$RD8/learn-proposals.md" \
  || fail "T10: proposals md must name the domain_gap class"
echo "PASS T10: proposals md reports every root-cause class"

# ============================================================================
# T11 — redteam finding (idempotency): a multi-line LLM title must NOT defeat dedup.
#   render must emit a SINGLE-LINE `###` heading (no title text leaking into the body), and a
#   re-apply of the same multi-line-titled rule must NOT append a second copy.
# ============================================================================
python3 - "$WORK" <<'PY' || fail "T11: multi-line-title idempotency"
import os, sys
from sail.learn import append_rules_to_domain
tgt = os.path.join(sys.argv[1], "tgt11"); os.makedirs(os.path.join(tgt, ".ship"), exist_ok=True)
rule = {"title": "Line one\nLine two", "body": "The rule body.", "source": "#147"}
assert append_rules_to_domain(tgt, [rule]) == 1                 # first write appends 1
assert append_rules_to_domain(tgt, [rule]) == 0                 # re-apply is a no-op (idempotent)
dom = open(os.path.join(tgt, ".ship", "domain.md")).read()
heads = [ln for ln in dom.splitlines() if ln.startswith("### ")]
assert len(heads) == 1, f"exactly one heading, got {heads}"
assert heads[0] == "### Line one Line two", f"heading must be single-line, got {heads[0]!r}"
assert "Line two\n" not in dom.replace("### Line one Line two", ""), "no title text may leak into the body"
print("ok")
PY
echo "PASS T11: multi-line title renders single-line + re-apply is idempotent"

# ============================================================================
# T12 — lens2 / AC3: dedupe drops a rule whose normalized BODY text already appears in domain.md,
#   even when the title/heading differs (dedup on normalized text, not only `###` headings).
# ============================================================================
python3 - <<'PY' || fail "T12: body-text dedupe (AC3)"
from sail.learn import dedupe_rules
domain = "# D\n\n### Some Existing Heading\nProbe sourced libs under the runtime shell.\n\n*Source: x.*\n"
rules = [
  {"title": "A Different Title", "body": "Probe sourced libs under the runtime shell.", "source": "#147"},
  {"title": "Genuinely Novel", "body": "A brand new rule about caching.", "source": "#147"},
]
kept, dropped = dedupe_rules(rules, domain)
assert [r["title"] for r in kept] == ["Genuinely Novel"], kept
assert [r["title"] for r in dropped] == ["A Different Title"], dropped
print("ok")
PY
echo "PASS T12: dedupe drops rules whose normalized body already exists (AC3)"

# ============================================================================
# T13 — lens1: a repeated index (`--indices 0,0`) must append the rule only ONCE (intra-batch dedup).
# ============================================================================
python3 - "$WORK" <<'PY' || fail "T13: intra-batch dedup"
import os, sys
from sail.learn import append_rules_to_domain
tgt = os.path.join(sys.argv[1], "tgt13"); os.makedirs(os.path.join(tgt, ".ship"), exist_ok=True)
r = {"title": "Only Once", "body": "b", "source": "#147"}
assert append_rules_to_domain(tgt, [r, r]) == 1, "a repeated rule in one batch must append once"
dom = open(os.path.join(tgt, ".ship", "domain.md")).read()
assert dom.count("### Only Once") == 1, dom
print("ok")
PY
echo "PASS T13: intra-batch repeated rule appends only once"

# ============================================================================
# T14 — AC1: collect_history reads review.json THROUGH sail/review.py's audited parser
#   (parse_findings), so its severity fail-closed normalization applies — an unknown-severity
#   finding is escalated to HIGH and therefore hydrated as blocking.
# ============================================================================
python3 - "$WORK" <<'PY' || fail "T14: collector reuses review.parse_findings"
import os, sys, json
from sail.learn import collect_history
rd = os.path.join(sys.argv[1], "rd14"); os.makedirs(rd, exist_ok=True)
json.dump({"status": "completed", "findings": [
  {"id": "U1", "severity": "WEIRD", "issue": "unknown severity", "lens": "lens1"},
  {"id": "L1", "severity": "LOW", "issue": "genuinely low", "lens": "lens1"},
]}, open(os.path.join(rd, "review.json"), "w"))
recs = collect_history(rd)
ids = sorted(r["id"] for r in recs)
assert ids == ["U1"], f"parse_findings escalates unknown severity to HIGH -> hydrated; LOW excluded; got {ids}"
print("ok")
PY
echo "PASS T14: collect_history reads via review.parse_findings (severity fail-closed)"

# ============================================================================
# T15 — dedupe body-check truthy guard is load-bearing: a rule with an EMPTY body must be KEPT
#   against a non-empty domain (else `"" in normalized_domain` == True would drop every
#   blank-body rule as a spurious duplicate). Pins the guard the round-2 review flagged.
# ============================================================================
python3 - <<'PY' || fail "T15: empty-body dedupe guard"
from sail.learn import dedupe_rules
domain = "# D\n\n### Existing\nSome existing body text here.\n\n*Source: x.*\n"
kept, dropped = dedupe_rules([{"title": "Novel Blank-Body Rule", "body": "", "source": "#147"}], domain)
assert [r["title"] for r in kept] == ["Novel Blank-Body Rule"], (kept, dropped)
assert dropped == [], dropped
print("ok")
PY
echo "PASS T15: empty-body rule is kept (dedupe truthy guard load-bearing)"

# ============================================================================
# T16 — run_learn actually SENDS the hydrated blocking records to the classifier (kills the
#   build_prompt(records, ...) -> build_prompt([], ...) mutation the round-2 review flagged: T8's
#   `cat >/dev/null` stub could not have caught it). A stub captures stdin; assert a finding id is in it.
# ============================================================================
STDIN_CAP="$WORK/stdin16.txt"
cat > "$BIN/capstub" <<STUB
#!/usr/bin/env bash
cat > "$STDIN_CAP"
echo '{"groups": []}'
STUB
chmod +x "$BIN/capstub"
RD16="$WORK/rd16"; cp -R "$RD/." "$RD16/"
set +e
( unset SAIL_REVIEW_CMD
  SAIL_LEARN_CMD="$BIN/capstub" PATH="$BIN:$PATH" \
    python3 -m sail learn --run-dir "$RD16" --target "$WORK/tgt16" --unattended 1 ) >/dev/null 2>&1
set -e
grep -q '"id": "F1"' "$STDIN_CAP" || fail "T16: hydrated records (F1) must be sent to the classifier"
echo "PASS T16: run_learn sends hydrated records to the classifier backend"

# ============================================================================
# T17 — a HUNG backend must not block the terminus: SAIL_LEARN_TIMEOUT bounds the call, run_learn
#   fails OPEN (exit 0, status skipped) instead of hanging — the fail-open guarantee covers a hang.
# ============================================================================
cat > "$BIN/hangstub" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
sleep 30
STUB
chmod +x "$BIN/hangstub"
RD17="$WORK/rd17"; cp -R "$RD/." "$RD17/"
set +e
SECONDS=0
( unset SAIL_REVIEW_CMD
  SAIL_LEARN_CMD="$BIN/hangstub" SAIL_LEARN_TIMEOUT=1 PATH="$BIN:$PATH" \
    python3 -m sail learn --run-dir "$RD17" --target "$WORK/tgt17" --unattended 1 ) >/dev/null 2>&1
rc=$?; elapsed=$SECONDS
set -e
[ "$rc" = 0 ] || fail "T17: run_learn must fail open (exit 0) on a hung backend, got $rc"
[ "$elapsed" -lt 20 ] || fail "T17: run_learn must not wait for the hung backend (took ${elapsed}s)"
st17="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("status"))' "$RD17/learn.json")"
[ "$st17" = skipped ] || fail "T17: status should be skipped on timeout, got $st17"
echo "PASS T17: run_learn fails open on a hung backend (timeout-bounded)"

# ============================================================================
# T18 — body-dedup precision (redteam): a novel rule whose body coincidentally appears in unrelated
#   PROSE (not an existing rule body) must be KEPT; a body matching an existing RULE body is dropped.
# ============================================================================
python3 - <<'PY' || fail "T18: body-dedup matches rule bodies, not arbitrary prose"
from sail.learn import dedupe_rules
# The phrase lives in unrelated PREAMBLE prose, not under any ### rule heading.
domain = ("# Domain\n\nProbe sourced libs under the runtime shell before shipping.\n\n"
          "## Rules\n\n### An Unrelated Rule\nSomething entirely different.\n\n*Source: x.*\n")
novel = {"title": "New Runtime Rule", "body": "Probe sourced libs under the runtime shell before shipping.", "source": "#147"}
kept, dropped = dedupe_rules([novel], domain)
assert [r["title"] for r in kept] == ["New Runtime Rule"], (kept, dropped)  # prose match must NOT drop it
# but a body matching an existing RULE body IS dropped
dup = {"title": "Different Heading", "body": "Something entirely different.", "source": "#147"}
kept2, dropped2 = dedupe_rules([dup], domain)
assert [r["title"] for r in dropped2] == ["Different Heading"], (kept2, dropped2)
print("ok")
PY
echo "PASS T18: body-dedup compares rule bodies, not arbitrary file prose"

echo "ALL PASS: test_sail_learn.sh"
