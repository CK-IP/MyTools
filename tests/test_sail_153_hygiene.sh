#!/usr/bin/env bash
# test_sail_153_hygiene.sh — #153: /sail + /surf operator-safety hygiene batch.
#   Three Tier-3 items from the 2026-07-06 evaluation, batched:
#     1. Lens preflight WARNING (not failure) — `--dual-lens` w/o SAIL_REVIEW_CMD2, or
#        `--red-team` w/o SAIL_REDTEAM_CMD: keep the clean degrade, add a loud launch note.
#     2. `.ship/domain.md` injection capped (~10KB) with a logged truncation note — a
#        bloat/poisoning guard on the untrusted context (OWASP LLM01), bounds its cost too.
#     3. `/surf resume` surfaces issues parked >7 days with no activity (orphaned-park guard),
#        report-only, no auto-action.
#
# Repo is SHELL-TEST-ONLY (no pytest suite), so the deterministic Python predicates (the cap +
# the aging predicate, AC#4) + their CLI are unit-tested INLINE via python3 (the established
# test_sail_95/113/131 pattern); the prose preflight (sail.md) + the resume report (surf.md) are
# asserted STRUCTURALLY from their canonical prescribed marker phrases AND as positive-meaning
# clauses (#53: pin the real wording so a negated directive carrying the same keywords can't pass).
#
# shellcheck disable=SC1091
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
unset "${!SAIL_@}" || true   # hermetic: a real shell exports SAIL_* codex knobs — clear them
cd "$REPO_ROOT"
fail() { echo "FAIL: $*"; exit 1; }

# ============================================================================
# Part A — domain.md injection cap: deterministic, unit-tested predicate (AC#2/#4)
# ============================================================================
python3 - <<'PY' || fail "A: cap_domain_memory predicate contract"
from sail.checkers import cap_domain_memory, DOMAIN_MEMORY_CAP_BYTES

# ~10KB default cap.
assert DOMAIN_MEMORY_CAP_BYTES == 10 * 1024, DOMAIN_MEMORY_CAP_BYTES

# None / empty pass through as ("", 0, False) — a clean no-op, never an error.
assert cap_domain_memory(None) == ("", 0, False)
assert cap_domain_memory("") == ("", 0, False)

# Under the cap -> passthrough, not truncated, original byte count reported.
assert cap_domain_memory("hello") == ("hello", 5, False)

# EXACTLY at the cap -> not truncated (boundary is inclusive).
at = "a" * DOMAIN_MEMORY_CAP_BYTES
assert cap_domain_memory(at) == (at, DOMAIN_MEMORY_CAP_BYTES, False)

# OVER the cap -> truncated, flagged, original byte count reported, capped payload (content +
# embedded marker) stays <= cap bytes, and a VISIBLE truncation marker is appended to the CONTENT
# itself (not only the stderr note) so the LLM consumer knows the memory was cut.
over = "a" * (DOMAIN_MEMORY_CAP_BYTES + 100)
capped, n, trunc = cap_domain_memory(over)
assert trunc is True
assert n == DOMAIN_MEMORY_CAP_BYTES + 100
assert len(capped.encode("utf-8")) <= DOMAIN_MEMORY_CAP_BYTES
assert "truncated" in capped and "#153" in capped, "capped content must carry a visible marker"
assert capped.startswith("a"), "leading content is preserved before the marker"
# The content portion (everything before the marker) is all original bytes.
content = capped.split("\n\n[")[0]
assert set(content) == {"a"}, "content before the marker is untouched original bytes"

# MULTIBYTE safety: a cap that lands mid-character must not crash and must not emit a partial/mojibake
# char. Each '€' is 3 UTF-8 bytes; the content budget need not be a multiple of 3, so the byte-slice
# can split one — errors="ignore" must drop it cleanly.
mb = "€" * DOMAIN_MEMORY_CAP_BYTES
capped_mb, n_mb, trunc_mb = cap_domain_memory(mb)
assert trunc_mb is True
capped_mb.encode("utf-8")                      # round-trips without error
assert len(capped_mb.encode("utf-8")) <= DOMAIN_MEMORY_CAP_BYTES
mb_content = capped_mb.split("\n\n[")[0]
assert set(mb_content) == {"€"}, "no partial/garbage char at the cap boundary"
print("A ok")
PY
echo "PASS A: cap_domain_memory predicate"

# ============================================================================
# Part B — freshness consistency: injected payload AND freshness hash both use the CAPPED content,
#   so a >cap domain.md is not perpetually "stale" (which would force a re-review every round).
# ============================================================================
python3 - <<'PY' || fail "B: domain fingerprint uses the capped content"
import os, tempfile
from sail.checkers import DOMAIN_MEMORY_CAP_BYTES
from sail.review import domain_fingerprint, domain_hash_stale

d = tempfile.mkdtemp()
os.makedirs(os.path.join(d, ".ship"))
p = os.path.join(d, ".ship", "domain.md")
with open(p, "w", encoding="utf-8") as f:
    f.write("R" * (DOMAIN_MEMORY_CAP_BYTES + 500))   # bigger than the cap

h1 = domain_fingerprint(d)
# The stored fingerprint equals the current one -> NOT stale (no spurious re-review loop).
assert domain_hash_stale(d, h1) is False

# A change ONLY in the truncated tail (beyond the cap) is invisible to the reviewer, so the
# fingerprint must be UNCHANGED — the injected content is identical.
with open(p, "a", encoding="utf-8") as f:
    f.write("Z" * 100)
assert domain_fingerprint(d) == h1, "tail-only change beyond the cap must not change the fingerprint"

# A change WITHIN the injected window DOES change the fingerprint -> re-review triggered.
with open(p, "w", encoding="utf-8") as f:
    f.write("Q" + "R" * (DOMAIN_MEMORY_CAP_BYTES + 500))
assert domain_fingerprint(d) != h1, "an in-window change must change the fingerprint"

# Empty-sentinel path unchanged: absent domain.md hashes to the empty sentinel.
empty = tempfile.mkdtemp()
assert domain_hash_stale(empty, None) is False
print("B ok")
PY
echo "PASS B: freshness fingerprint capped-consistent"

# ============================================================================
# Part C — parked-issue aging: deterministic, unit-tested predicate + scanner (AC#3/#4)
# ============================================================================
python3 - <<'PY' || fail "C: aging predicate + find_stale_parks contract"
import os, tempfile
from sail.parked_aging import is_stale_park, find_stale_parks, STALE_PARK_THRESHOLD_DAYS

DAY = 86400
now = 1_000_000_000
assert STALE_PARK_THRESHOLD_DAYS == 7

# Fresh -> not stale.
assert is_stale_park(now - 1 * DAY, now) is False
# EXACTLY 7 days -> not stale (guard is strictly ">7 days").
assert is_stale_park(now - 7 * DAY, now) is False
# Just past 7 days -> stale.
assert is_stale_park(now - 7 * DAY - 1, now) is True
assert is_stale_park(now - 8 * DAY, now) is True
# Custom threshold honored.
assert is_stale_park(now - 4 * DAY, now, threshold_days=3) is True
assert is_stale_park(now - 2 * DAY, now, threshold_days=3) is False

# FAIL-SAFE on bad/missing data — a report-only guard must never manufacture a false orphan:
assert is_stale_park(None, now) is False
assert is_stale_park(0, now) is False
assert is_stale_park(now + DAY, now) is False       # future mtime -> not stale

# find_stale_parks: last-activity is the .surf/runs/<issue>/ dir mtime; a missing dir is skipped
# (can't age what has no activity record); the caller supplies the parked set.
runs = tempfile.mkdtemp()
now2 = 2_000_000_000
for issue, age in [("100", 30), ("101", 2), ("102", 10)]:
    dd = os.path.join(runs, issue); os.makedirs(dd)
    os.utime(dd, (now2 - age * DAY, now2 - age * DAY))
res = dict(find_stale_parks(runs, ["100", "101", "102", "103"], now2))
assert "100" in res and "102" in res, res
assert "101" not in res, "2-day park is not orphaned"
assert "103" not in res, "no run-dir -> skipped, not a false orphan"
assert res["100"] >= 30 and res["102"] >= 10, res    # age reported in whole days

# ACTIVITY signal is the NEWEST mtime across the dir AND its contents — a dir whose OWN mtime is old
# but that holds a freshly-written file (a journal/stream append) is STILL ACTIVE, not orphaned
# (#153 review MEDIUM: a directory mtime does not advance on an append to an existing file).
active = os.path.join(runs, "104")
os.makedirs(active)
os.utime(active, (now2 - 30 * DAY, now2 - 30 * DAY))       # dir mtime is 30d old
stream = os.path.join(active, "worker-stream.jsonl")
with open(stream, "w") as fh:
    fh.write("{}\n")
os.utime(stream, (now2 - 1 * DAY, now2 - 1 * DAY))         # but a file was written 1d ago
res2 = dict(find_stale_parks(runs, ["104"], now2))
assert "104" not in res2, "a recently-written file inside the run-dir counts as activity"
print("C ok")
PY
echo "PASS C: parked-issue aging predicate + scanner"

# ============================================================================
# Part D — the `sail parked-aging` CLI (thin glue over the predicate; report-only, rc 0)
# ============================================================================
RUNS="$WORK/runs"; mkdir -p "$RUNS/200" "$RUNS/201" "$RUNS/202"
NOW=2000000000
# 200 = 30d old, 201 = 1d old, 202 = 9d old
python3 - "$RUNS" "$NOW" <<'PY'
import os, sys
runs, now = sys.argv[1], int(sys.argv[2])
DAY = 86400
for issue, age in [("200", 30), ("201", 1), ("202", 9)]:
    dd = os.path.join(runs, issue)
    os.utime(dd, (now - age * DAY, now - age * DAY))
PY
OUT="$(python3 -m sail parked-aging --runs-dir "$RUNS" --issues 200,201,202 --now "$NOW")"
RC=$?
[ "$RC" -eq 0 ] || fail "D: parked-aging CLI must exit 0 (report-only), got $RC"
echo "$OUT" | grep -q "#200" || fail "D: 30d park #200 must be reported orphaned"
echo "$OUT" | grep -q "#202" || fail "D: 9d park #202 must be reported orphaned"
echo "$OUT" | grep -q "#201" && fail "D: 1d fresh park #201 must NOT be reported"
# No stale parks -> still rc 0, and a clean 'none' note.
OUT2="$(python3 -m sail parked-aging --runs-dir "$RUNS" --issues 201 --now "$NOW")"
echo "$OUT2" | grep -qi "no orphaned parks" || fail "D: empty case must print a clean 'none' note"
echo "PASS D: parked-aging CLI"

# ============================================================================
# Part E — lens preflight WARNING prose in commands/sail.md (AC#1, structural)
# ============================================================================
SAIL_MD="commands/sail.md"
grep -q "SAIL-LENS-PREFLIGHT" "$SAIL_MD" || fail "E: sail.md missing the lens-preflight block marker"
# It must name BOTH degrade pairs.
grep -q "SAIL_REVIEW_CMD2" "$SAIL_MD" || fail "E: preflight must check SAIL_REVIEW_CMD2 for --dual-lens"
grep -q "SAIL_REDTEAM_CMD" "$SAIL_MD" || fail "E: preflight must check SAIL_REDTEAM_CMD for --red-team"
# It is a WARNING, not a failure — the clean degrade is KEPT. Assert the positive rule.
python3 - <<'PY' || fail "E: preflight must be a non-failing warning that keeps the degrade"
import re
t = open("commands/sail.md", encoding="utf-8").read()
i = t.find("SAIL-LENS-PREFLIGHT")
assert i != -1
block = t[i:i + 2500]
low = block.lower()
assert "warn" in low or "heads up" in low or "⚠" in block, "preflight must be phrased as a warning"
assert "degrade" in low or "single-lens" in low or "clean" in low, "must state the degrade is kept"
# Must NOT abort the run: no `exit 1` inside the preflight block.
assert "exit 1" not in block, "preflight is a WARNING, never a failure/exit"
PY
echo "PASS E: sail.md lens-preflight warning prose"

# ============================================================================
# Part F — /surf resume orphaned-park report prose in commands/surf.md (AC#3, structural)
# ============================================================================
SURF_MD="commands/surf.md"
grep -q "parked-aging" "$SURF_MD" || fail "F: surf.md must call the parked-aging CLI on resume"
grep -qi "orphaned-park\|orphaned park" "$SURF_MD" || fail "F: surf.md must name the orphaned-park guard"
python3 - <<'PY' || fail "F: surf resume orphaned-park guard must be report-only"
t = open("commands/surf.md", encoding="utf-8").read()
i = t.lower().find("orphaned-park")
if i == -1:
    i = t.lower().find("orphaned park")
assert i != -1
block = t[max(0, i - 400):i + 900]
low = block.lower()
assert "7" in block and "day" in low, "must state the >7-day threshold"
assert "report-only" in low or "no auto-action" in low or "no auto action" in low, \
    "guard must be explicitly report-only (no auto-action)"
PY
echo "PASS F: surf.md orphaned-park resume report prose"

echo "ALL PASS: test_sail_153_hygiene.sh"
