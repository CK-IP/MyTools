#!/usr/bin/env bash
# test_sail_113_disposition.sh — #113: minor-finding disposition (blast-radius split).
#   Fix TRIVIAL in-blast-radius issues inline (logged, no silent diff creep); CAPTURE everything
#   out-of-scope as a deferred finding (+ optional auto-filed one-line issue). The hard CEILING for
#   an inline fix is testable: a fix touching a 2nd file / a public interface / a new dependency is
#   NOT eligible (the un-mechanizable "trivial / zero-behavior" judgment stays with the LLM lens).
#
# Repo is SHELL-TEST-ONLY (no pytest suite), so the deterministic Python predicate + the DecisionLog
# marker + the CLI + the land rendering are unit-tested INLINE via python3 (the established
# test_sail_95/131 pattern); the prose + review-prompt directives are asserted structurally from
# their CANONICAL prescribed marker phrases AND as contiguous meaning-bearing clauses (#53: drive
# the assertion from the real prescribed wording, and pin the actual positive/negative rule so a
# negated directive carrying the same keywords cannot pass).
#
# shellcheck disable=SC1091
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
unset "${!SAIL_@}" || true   # hermetic: a real shell exports SAIL_* codex knobs — clear them
cd "$REPO_ROOT"
fail() { echo "FAIL: $*"; exit 1; }

# ============================================================================
# Part A — the hard CEILING as a deterministic, unit-tested predicate (AC#3/#4)
#   Only the MECHANIZABLE boundary lives here; "trivial / zero-behavior-change" stays LLM judgment.
# ============================================================================
python3 - <<'PY' || fail "A: inline_fix_eligible ceiling predicate contract"
from sail.disposition import inline_fix_eligible as ok

# Eligible: a single-file, few-line, no-interface/dep/behavior change is the in-blast-radius case.
assert ok(["sail/runner.py"]) is True
assert ok(1) is True                                  # accepts a count too
assert ok(["a.py"], changed_lines=3, max_lines=10) is True

# A BARE STRING path is ONE file, not len(path) characters (redteam round-1 bug fix):
assert ok("sail/runner.py") is True, "bare str path must count as 1 file, not 14 chars"
assert ok("x") is True                                # a 1-char path is still 1 file, still eligible

# CEILING — any one trips it -> NOT eligible (must be a deferred finding / follow-up issue):
assert ok(["a.py", "b.py"]) is False                  # >=2 files (the issue's own AC#4 example)
assert ok(2) is False                                 # >=2 files by count
assert ok(["a.py"], touches_public_interface=True) is False   # public-interface change
assert ok(["a.py"], adds_dependency=True) is False    # new dependency
assert ok(["a.py"], adds_behavior=True) is False      # new behavior surface
assert ok(["a.py"], changed_lines=40, max_lines=10) is False  # exceeds the "few lines" budget

# Hardening: empty / zero candidate is not "eligible to grow the diff"
assert ok([]) is False
assert ok(0) is False
assert ok("") is False                                # empty path string is not a fixable candidate
PY

# ============================================================================
# Part B — the inline-fix VISIBILITY log is a DURABLE narrative marker (AC#2/#5),
#   NOT a finding disposition: it round-trips via read_inline_fixes AND is INVISIBLE to
#   read_resolutions (so it can never collide with the convergence buckets — materiality floor
#   keys on "deferred", oscillation on rejected/deferred — risk 8 grounded).
# ============================================================================
python3 - "$WORK" <<'PY' || fail "B: inline_fix_marker durable + not-a-disposition"
import sys, os
from sail.decisionlog import DecisionLog
rd = os.path.join(sys.argv[1], "rd_b"); os.makedirs(rd, exist_ok=True)
log = DecisionLog(rd)
log.inline_fix_marker("sail/runner.py", "also corrected a stale comment while editing the marker path")
text = open(os.path.join(rd, "decision-log.md"), encoding="utf-8").read()
assert "inline-fix:" in text, "marker not durably written to decision-log.md"
assert "sail/runner.py" in text and "also corrected" in text, "marker lost its file/summary"
# Round-trips via the dedicated reader...
fixes = DecisionLog(rd).read_inline_fixes()
assert len(fixes) == 1 and fixes[0]["file"] == "sail/runner.py", "read_inline_fixes did not round-trip"
assert "also corrected" in fixes[0]["summary"], "read_inline_fixes lost the summary"
# ...but is NOT a finding resolution -> read_resolutions must not see it.
assert DecisionLog(rd).read_resolutions() == {}, "inline-fix marker leaked into read_resolutions (convergence-bucket collision risk)"
PY

# ============================================================================
# Part C — the REVIEW prompt teaches the blast-radius disposition (AC#2/#7)
#   Asserted from canonical phrases AND contiguous positive/negative rule clauses (a negated
#   directive carrying the same keywords must NOT pass). Gated on ACs being in scope (#355 LOW).
# ============================================================================
python3 - <<'PY' || fail "C: review prompt carries the blast-radius disposition directive"
from sail import review
# The directive is only coherent when AC traceability is in scope -> appended only with ACs.
no_ac = review.build_prompt("--- a/x\n+++ b/x\n+pass\n")
assert "blast-radius" not in no_ac.lower() and "blast radius" not in no_ac.lower(), \
    "directive must NOT append on the no-ACs path (it would treat the whole diff as opportunistic)"

prompt = review.build_prompt("--- a/x\n+++ b/x\n+pass\n", acs=["does the thing"])
low = prompt.lower()
assert "blast-radius" in low or "blast radius" in low, "no blast-radius disposition directive in review prompt"
assert "in-blast-radius opportunistic fix" in low, "missing the recognition directive (logged in-radius fix = explained)"
assert "also corrected x while editing y" in low, "missing the canonical inline-fix log form"
# Contiguous meaning-bearing clauses (defeat the same-keywords-but-negated mutation):
assert "is explained. do not flag it" in low, "positive rule must be the contiguous 'is EXPLAINED. Do NOT flag it'"
assert 'is a finding (category "scope")' in low, "negative rule must mark out-of-scope/unlogged as a scope finding"
PY

# ============================================================================
# Part D — the disposition POLICY is documented in BOTH specs (AC#1/#2/#8/#9)
# ============================================================================
SAIL_MD="commands/sail.md"; SURF_MD="commands/surf.md"
grep -qi "Minor-finding disposition" "$SAIL_MD" || fail "D1: sail.md lacks the 'Minor-finding disposition' section"
grep -qi "blast radius\|blast-radius" "$SAIL_MD" || fail "D2: sail.md lacks the blast-radius framing"
# the hard ceiling — all four clauses must be present
grep -qi "single file" "$SAIL_MD" || fail "D3: sail.md ceiling missing 'single file'"
grep -qi "public.interface" "$SAIL_MD" || fail "D4: sail.md ceiling missing 'public interface'"
grep -qi "no new dependency" "$SAIL_MD" || fail "D5: sail.md ceiling missing 'no new dependency'"
grep -qi "no new behavior" "$SAIL_MD" || fail "D6: sail.md ceiling missing 'no new behavior'"
# inline visibility log form
grep -qi "also corrected X while editing Y" "$SAIL_MD" || fail "D7: sail.md missing the inline-fix log form"
# out-of-scope capture: deferred finding (always) + OPTIONAL auto-file, INFO-tier per #112
grep -qi "deferred finding" "$SAIL_MD" || fail "D8: sail.md missing 'deferred finding' (the guaranteed capture floor)"
grep -qi "optional" "$SAIL_MD" || fail "D9: sail.md must mark auto-filing OPTIONAL (deferred-finding is the floor)"
grep -qi "filed #N\|→ filed\|noted → filed" "$SAIL_MD" || fail "D10: sail.md missing the INFO-tier 'filed #N' report form"
grep -qi "#112" "$SAIL_MD" || fail "D11: sail.md must reference the #112 tone convention"
# AC#9 safe auto-file pattern (the #108 reuse)
grep -qi -- "--body-file" "$SAIL_MD" || fail "D15: sail.md auto-file must specify the #108 --body-file safe pattern"
# AC: the driver can actually invoke the predicate/marker (no dormant feature)
grep -qi "sail disposition" "$SAIL_MD" || fail "D16: sail.md must show the 'python3 -m sail disposition' invocation (driver reachability)"

# surf.md carries (or references) the same policy: blast-radius split + the ceiling
grep -qi "Minor-finding disposition\|blast radius\|blast-radius" "$SURF_MD" || fail "D12: surf.md lacks the disposition policy"
grep -qi "single file" "$SURF_MD" || fail "D13: surf.md lacks the inline ceiling"
grep -qi "deferred finding" "$SURF_MD" || fail "D14: surf.md lacks out-of-scope capture (deferred finding)"

# ============================================================================
# Part E — the CLI subcommand makes the ceiling/ marker REACHABLE by the markdown driver (redteam)
# ============================================================================
# eligible single-file candidate -> rc 0, prints "eligible"
out="$(python3 -m sail disposition --files 1)" || fail "E1: ceiling check rc!=0 for an eligible candidate"
[ "$out" = "eligible" ] || fail "E2: expected 'eligible', got '$out'"
# >=2 files -> rc 1 (not eligible), prints "exceeds-ceiling"
if out="$(python3 -m sail disposition --files 2)"; then fail "E3: ceiling check must rc!=0 when it exceeds"; fi
[ "$out" = "exceeds-ceiling" ] || fail "E4: expected 'exceeds-ceiling', got '$out'"
# public-interface single-file -> exceeds
python3 -m sail disposition --files 1 --public-interface && fail "E5: public-interface must exceed the ceiling" || true
# record-inline-fix writes the durable marker into the run-dir
RDE="$WORK/rd_e"; mkdir -p "$RDE"
python3 -m sail disposition --record-inline-fix --run-dir "$RDE" --file "sail/x.py" --summary "also corrected a typo while editing x" \
  || fail "E6: record-inline-fix rc!=0"
grep -q "inline-fix:" "$RDE/decision-log.md" || fail "E7: record-inline-fix did not write the marker"
# An EMPTY/whitespace summary defeats the visibility guard -> rejected (rc!=0), no marker written.
RDE2="$WORK/rd_e2"; mkdir -p "$RDE2"
python3 -m sail disposition --record-inline-fix --run-dir "$RDE2" --file "sail/x.py" --summary "   " \
  && fail "E8: empty/whitespace --summary must be rejected" || true
[ -f "$RDE2/decision-log.md" ] && grep -q "inline-fix:" "$RDE2/decision-log.md" && fail "E9: rejected empty summary must NOT write a marker" || true

# ============================================================================
# Part F — inline-fix markers are SURFACED on the land/delivery comment (AC#6, narrative design)
# ============================================================================
python3 - "$WORK" <<'PY' || fail "F: land_comment surfaces inline-fix markers"
import sys, os
from sail.lifecycle import land_comment
from sail.decisionlog import DecisionLog
rd = os.path.join(sys.argv[1], "rd_f"); os.makedirs(rd, exist_ok=True)
log = DecisionLog(rd)
log.inline_fix_marker("sail/runner.py", "also corrected a stale comment while editing Y")
fixes = DecisionLog(rd).read_inline_fixes()
comment = land_comment(113, {"findings": [], "counts": {}}, {}, inline_fixes=fixes)
assert "Inline opportunistic fixes" in comment, "land comment missing the inline-fixes narrative section"
assert "sail/runner.py" in comment and "also corrected a stale comment" in comment, "land comment dropped the marker detail"
# Back-compat: omitting inline_fixes must not break the renderer or emit an empty section.
plain = land_comment(113, {"findings": [], "counts": {}}, {})
assert "Inline opportunistic fixes" not in plain, "empty inline-fixes must NOT render a section"
PY

echo "PASS: test_sail_113_disposition"
