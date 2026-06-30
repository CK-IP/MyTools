#!/usr/bin/env bash
# test_sail_125_domain_pickup.sh — issue #125: re-read domain memory per stage for mid-build
# pickup (no re-launch). Before #125 the plan/review stages never read `.ship/domain.md` (only
# checkers.py did, and only for diff-coverage-threshold), so a domain fact added between
# checkpoints on a same-run-dir resume was invisible. #125 wires a shared failure-safe
# `read_domain_memory(target)` reader into both prompt builders and adds a `domain_hash` to the
# review freshness/reuse key so a domain-only change forces a fresh review.
#
# Hermetic: throwaway tmp dirs + tmp git repos; no LLM backend invoked.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
cd "$REPO_ROOT"
# Hermetic: clear inherited SAIL_* knobs so no backend is reached.
unset "${!SAIL_@}" 2>/dev/null || true

fail() { echo "FAIL: $*"; exit 1; }

# ---------------------------------------------------------------------------
# T1: read_domain_memory(target) — shared, failure-safe reader (AC#1).
#     Mirrors checkers.diff_coverage_threshold's path-build + try/except + None-on-absent.
# ---------------------------------------------------------------------------
python3 - <<'PY' || fail "T1: read_domain_memory reader"
import os, tempfile
from sail.checkers import read_domain_memory
with tempfile.TemporaryDirectory() as d:
    # absent -> None
    assert read_domain_memory(d) is None, "absent .ship/domain.md must return None"
    os.makedirs(os.path.join(d, ".ship"))
    p = os.path.join(d, ".ship", "domain.md")
    with open(p, "w", encoding="utf-8") as fh:
        fh.write("# Domain\nDAIRY_FACT: UF retentate ratio is 3:1\n")
    txt = read_domain_memory(d)
    assert txt is not None and "UF retentate ratio is 3:1" in txt, "present file must return its text"
    # unreadable (dir where a file is expected) -> None, never raises
    import shutil; os.remove(p); os.makedirs(p)
    assert read_domain_memory(d) is None, "unreadable .ship/domain.md must return None, not raise"
print("T1 ok")
PY
echo "PASS T1"

# ---------------------------------------------------------------------------
# T2: plan.build_prompt injects a DOMAIN MEMORY block when given; byte-identical
#     baseline when absent/empty (the zero-cost no-op, AC#7); per-invocation re-read.
# ---------------------------------------------------------------------------
python3 - <<'PY' || fail "T2: plan.build_prompt domain injection + no-op + per-invocation"
import os, tempfile
from sail import plan
from sail.checkers import read_domain_memory
spec = "Add a widget that frobs the gizmo. Run the tests."

# zero-cost no-op: None and "" produce byte-identical output to today's (no-arg) prompt.
base = plan.build_prompt(spec)
assert plan.build_prompt(spec, domain_memory=None) == base, "domain_memory=None must be byte-identical baseline"
assert plan.build_prompt(spec, domain_memory="") == base, "domain_memory='' must be byte-identical baseline"
assert plan.build_prompt(spec, domain_memory="   \n  ") == base, "whitespace-only must be byte-identical baseline"

# injected fact appears in the prompt
fact = "ZZTOP_RULE: never frob before noon"
withdom = plan.build_prompt(spec, domain_memory="# Domain\n" + fact + "\n")
assert fact in withdom, "domain fact must appear in the plan prompt"
assert len(withdom) > len(base), "domain block must add content when present"
# domain memory is working-tree state a change-under-review can modify -> it MUST be framed as
# untrusted reference data, never as instructions (OWASP LLM01), mirroring the SPEC/DIFF/TRIAGE blocks.
assert "untrusted" in withdom.lower() and "not as instructions" in withdom.lower(), \
    "plan DOMAIN MEMORY block must carry the untrusted-data / not-instructions framing"

# per-invocation re-read: read .ship/domain.md, build; append a fact; read again, build -> picked up
with tempfile.TemporaryDirectory() as d:
    os.makedirs(os.path.join(d, ".ship"))
    p = os.path.join(d, ".ship", "domain.md")
    with open(p, "w", encoding="utf-8") as fh:
        fh.write("FACT_A: alpha\n")
    pr1 = plan.build_prompt(spec, domain_memory=read_domain_memory(d))
    assert "FACT_A: alpha" in pr1 and "FACT_B: bravo" not in pr1
    with open(p, "a", encoding="utf-8") as fh:
        fh.write("FACT_B: bravo\n")
    pr2 = plan.build_prompt(spec, domain_memory=read_domain_memory(d))
    assert "FACT_B: bravo" in pr2, "a fact added between checkpoints must be picked up on the next read"
print("T2 ok")
PY
echo "PASS T2"

# ---------------------------------------------------------------------------
# T3: review.build_prompt injects the same DOMAIN MEMORY block; byte-identical baseline.
# ---------------------------------------------------------------------------
python3 - <<'PY' || fail "T3: review.build_prompt domain injection + no-op"
from sail import review
diff = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n"
base = review.build_prompt(diff)
assert review.build_prompt(diff, domain_memory=None) == base, "domain_memory=None must be byte-identical baseline"
assert review.build_prompt(diff, domain_memory="") == base, "domain_memory='' must be byte-identical baseline"
fact = "REVIEW_DOMAIN_FACT: counts must be 8 not 9"
withdom = review.build_prompt(diff, domain_memory="# Domain\n" + fact + "\n")
assert fact in withdom, "domain fact must appear in the review prompt"
assert "untrusted" in withdom.lower() and "not as instructions" in withdom.lower(), \
    "review DOMAIN MEMORY block must carry the untrusted-data / not-instructions framing"
# composes with acs without losing either
wd2 = review.build_prompt(diff, acs=["AC one"], domain_memory=fact)
assert fact in wd2 and "AC one" in wd2, "domain block must coexist with the AC block"
print("T3 ok")
PY
echo "PASS T3"

# ---------------------------------------------------------------------------
# T4: review.domain_fingerprint(target) reflects .ship/domain.md; sha256("") sentinel when absent.
# ---------------------------------------------------------------------------
python3 - <<'PY' || fail "T4: domain_fingerprint"
import os, hashlib, tempfile
from sail import review
empty_sentinel = hashlib.sha256(b"").hexdigest()
with tempfile.TemporaryDirectory() as d:
    assert review.domain_fingerprint(d) == empty_sentinel, "absent domain.md -> sha256('') sentinel"
    os.makedirs(os.path.join(d, ".ship"))
    p = os.path.join(d, ".ship", "domain.md")
    with open(p, "w", encoding="utf-8") as fh:
        fh.write("FACT: one\n")
    h1 = review.domain_fingerprint(d)
    assert h1 != empty_sentinel, "present domain.md -> non-sentinel hash"
    with open(p, "a", encoding="utf-8") as fh:
        fh.write("FACT: two\n")
    h2 = review.domain_fingerprint(d)
    assert h2 != h1, "a domain.md content change must change the fingerprint"
print("T4 ok")
PY
echo "PASS T4"

# ---------------------------------------------------------------------------
# T5: the review freshness/reuse gate (convergence.review_current_and_clean) is invalidated
#     when ONLY .ship/domain.md changed (AC#4/#6) — diff + plan unchanged. Backward-compat:
#     an old review.json with no domain_hash, on a repo with no domain.md, stays reusable.
# ---------------------------------------------------------------------------
python3 - <<'PY' || fail "T5: reuse invalidated by domain-only change + backward-compat"
import os, json, subprocess, tempfile
from sail import review, convergence

def git(d, *args):
    subprocess.run(["git", "-C", d, *args], check=True, capture_output=True)

with tempfile.TemporaryDirectory() as d:
    git(d, "init", "-q")
    git(d, "config", "user.email", "t@t"); git(d, "config", "user.name", "t")
    with open(os.path.join(d, "f.py"), "w") as fh: fh.write("x = 1\n")
    git(d, "add", "."); git(d, "commit", "-qm", "base")
    # produce a working-tree diff vs HEAD so diff_fingerprint is non-empty + stable
    with open(os.path.join(d, "f.py"), "w") as fh: fh.write("x = 2\n")
    diff_ref = "HEAD"
    rd = os.path.join(d, ".sail", "runs", "r1"); os.makedirs(rd)

    # write a review.json that matches the current target/diff/plan AND the current (absent) domain
    review_json = {
        "status": "completed", "round": 1,
        "target": os.path.abspath(d), "diff_ref": diff_ref,
        "diff_hash": review.diff_fingerprint(os.path.abspath(d), diff_ref),
        "plan_hash": review.plan_fingerprint(rd),
        "domain_hash": review.domain_fingerprint(os.path.abspath(d)),
        "findings": [], "counts": {"CRITICAL": 0, "HIGH": 0},
    }
    p = os.path.join(rd, "review.json")
    json.dump(review_json, open(p, "w"))
    assert convergence.review_current_and_clean(rd, d, 1) is True, "matching hashes -> fresh"

    # add a domain fact (diff + plan unchanged) -> stale, force a fresh review
    os.makedirs(os.path.join(d, ".ship"))
    with open(os.path.join(d, ".ship", "domain.md"), "w") as fh:
        fh.write("NEW_FACT: this changes the resumed run's behavior\n")
    assert convergence.review_current_and_clean(rd, d, 1) is False, \
        "a domain-only change must invalidate review reuse (mid-build pickup)"

    # restore matching domain_hash -> fresh again
    review_json["domain_hash"] = review.domain_fingerprint(os.path.abspath(d))
    json.dump(review_json, open(p, "w"))
    assert convergence.review_current_and_clean(rd, d, 1) is True, "updated domain_hash -> fresh again"

# Backward-compat: an OLD review.json without a domain_hash key, on a repo with NO domain.md,
# must still be considered fresh (missing key defaults to the empty-domain sentinel) so #125
# never regresses existing reuse on domain-free repos.
with tempfile.TemporaryDirectory() as d:
    git(d, "init", "-q")
    git(d, "config", "user.email", "t@t"); git(d, "config", "user.name", "t")
    with open(os.path.join(d, "f.py"), "w") as fh: fh.write("x = 1\n")
    git(d, "add", "."); git(d, "commit", "-qm", "base")
    with open(os.path.join(d, "f.py"), "w") as fh: fh.write("x = 2\n")
    rd = os.path.join(d, ".sail", "runs", "r1"); os.makedirs(rd)
    legacy = {
        "status": "completed", "round": 1,
        "target": os.path.abspath(d), "diff_ref": "HEAD",
        "diff_hash": review.diff_fingerprint(os.path.abspath(d), "HEAD"),
        "plan_hash": review.plan_fingerprint(rd),
        # NOTE: no "domain_hash" key (pre-#125 artifact)
        "findings": [], "counts": {"CRITICAL": 0, "HIGH": 0},
    }
    json.dump(legacy, open(os.path.join(rd, "review.json"), "w"))
    assert convergence.review_current_and_clean(rd, d, 1) is True, \
        "legacy review.json (no domain_hash) on a domain-free repo must stay reusable"

    # ...but the SAME legacy review.json, once the repo gains a domain.md, must be STALE: the
    # missing key defaults to the empty sentinel, which no longer matches current_domain_hash.
    # (Pins the `stored is None and current != sentinel -> stale` branch the round-1 reviewer
    # flagged as untested — the subtlest half of the backward-compat default.)
    os.makedirs(os.path.join(d, ".ship"))
    with open(os.path.join(d, ".ship", "domain.md"), "w") as fh:
        fh.write("LATE_FACT: domain memory appeared after the legacy review\n")
    assert convergence.review_current_and_clean(rd, d, 1) is False, \
        "legacy review.json (no domain_hash) on a repo that NOW has domain.md must be stale"
print("T5 ok")
PY
echo "PASS T5"

# ---------------------------------------------------------------------------
# T6: review() stamps domain_hash into its result (so run_review persists it into review.json),
#     and it equals domain_fingerprint(target). Uses the empty-diff path (no backend needed).
# ---------------------------------------------------------------------------
python3 - <<'PY' || fail "T6: review() result carries domain_hash"
import os, subprocess, tempfile
from sail import review

def git(d, *args):
    subprocess.run(["git", "-C", d, *args], check=True, capture_output=True)

with tempfile.TemporaryDirectory() as d:
    git(d, "init", "-q")
    git(d, "config", "user.email", "t@t"); git(d, "config", "user.name", "t")
    with open(os.path.join(d, "f.py"), "w") as fh: fh.write("x = 1\n")
    git(d, "add", "."); git(d, "commit", "-qm", "base")
    os.makedirs(os.path.join(d, ".ship"))
    with open(os.path.join(d, ".ship", "domain.md"), "w") as fh:
        fh.write("FACT: live\n")
    # empty diff (HEAD vs working tree, no change) -> early return, no backend invoked
    res = review.review(os.path.abspath(d), "HEAD", advisory=True)
    assert "domain_hash" in res, "review() result must include domain_hash"
    assert res["domain_hash"] == review.domain_fingerprint(os.path.abspath(d)), \
        "review() domain_hash must equal domain_fingerprint(target)"
print("T6 ok")
PY
echo "PASS T6"

echo "ALL PASS: test_sail_125_domain_pickup"
