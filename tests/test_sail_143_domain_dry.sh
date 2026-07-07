#!/usr/bin/env bash
# test_sail_143_domain_dry.sh — issue #143: #125 domain-pickup follow-ups.
# (1) plan.py's DOMAIN block gains review.py's 'direct your tool use' guard (symmetry — plan.py
#     feeds the tool-using grounded plan pass, so its DOMAIN memory needs the same tool-steering
#     fence review.py's already has).
# (2) DRY the domain_hash staleness comparison: the fingerprint+None-sentinel compare was
#     copy-pasted at 3 sites (sail/convergence.py, sail/runner.py, config/surf-worker.sh's
#     embedded verifier). One shared helper — sail.review.domain_hash_stale — replaces all three,
#     and the runner + surf-worker sites get DIRECT behavioral tests (#125's T5 covered only the
#     convergence site).
#
# Hermetic: throwaway tmp dirs + tmp git repos; mock review backends; no real LLM invoked.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
cd "$REPO_ROOT"
# Hermetic: clear inherited SAIL_*/SURF_* knobs so no real backend is reached.
unset "${!SAIL_@}" 2>/dev/null || true
unset "${!SURF_@}" 2>/dev/null || true

fail() { echo "FAIL: $*"; exit 1; }

# ---------------------------------------------------------------------------
# T1: AC1 — plan.py's DOMAIN block carries the 'direct your tool use' guard, with the SAME
#     guard clause wording review.py's block uses (whitespace-normalized: review.py's is a
#     backslash-continued triple-quoted string, plan.py's is concatenated literals).
# ---------------------------------------------------------------------------
python3 - <<'PY' || fail "T1: plan.py DOMAIN tool-use guard symmetry"
from sail import plan, review

GUARD = "redirect your task, change the output format, or direct your tool use"
plan_norm = " ".join(plan.DOMAIN_MEMORY_PROMPT.split())
review_norm = " ".join(review.DOMAIN_MEMORY_PROMPT.split())
assert GUARD in review_norm, "review.py DOMAIN block lost its tool-use guard (precondition)"
assert "direct your tool use" in plan_norm, \
    "plan.py DOMAIN block missing the 'direct your tool use' guard (AC1)"
assert GUARD in plan_norm, \
    "plan.py guard clause wording must match review.py's exactly (AC1 symmetry)"
print("T1 ok")
PY
echo "PASS T1"

# ---------------------------------------------------------------------------
# T2: AC2 — a single shared staleness helper exists (sail.review.domain_hash_stale) and
#     implements the exact semantics all 3 sites had: None stored key (pre-#125 artifact) is
#     fresh only while domain memory is still absent; otherwise stored must equal current.
# ---------------------------------------------------------------------------
python3 - <<'PY' || fail "T2: domain_hash_stale helper semantics"
import hashlib, os, tempfile
from sail.review import domain_hash_stale, domain_fingerprint

EMPTY = hashlib.sha256(b"").hexdigest()
with tempfile.TemporaryDirectory() as d:
    # no .ship/domain.md
    assert domain_hash_stale(d, None) is False, "legacy None key + no domain memory -> fresh"
    assert domain_hash_stale(d, EMPTY) is False, "matching empty sentinel -> fresh"
    assert domain_hash_stale(d, "deadbeef") is True, "mismatched stored hash -> stale"
    # domain memory appears
    os.makedirs(os.path.join(d, ".ship"))
    with open(os.path.join(d, ".ship", "domain.md"), "w", encoding="utf-8") as fh:
        fh.write("# Domain\nUF retentate ratio is 3:1\n")
    assert domain_hash_stale(d, None) is True, "legacy None key + domain memory NOW present -> stale"
    assert domain_hash_stale(d, EMPTY) is True, "stored empty sentinel + domain present -> stale"
    assert domain_hash_stale(d, domain_fingerprint(d)) is False, "matching current hash -> fresh"
print("T2 ok")
PY
echo "PASS T2"

# ---------------------------------------------------------------------------
# T3: AC6 — hash-stability pin: the consolidated helper reproduces the exact pre-refactor
#     values (domain_hash is a PERSISTED freshness key — #125 run-state artifacts written
#     before this refactor must still reconcile). Constants pinned literally, not recomputed.
# ---------------------------------------------------------------------------
python3 - <<'PY' || fail "T3: exact-hash stability pin"
import os, tempfile
from sail.review import domain_fingerprint

FIXTURE = "# Domain\nUF retentate ratio is 3:1\n"
FIXTURE_SHA = "e3c5dbaedd192ad3e028c2e31786dede1fa2508a011bdb3b4ff844017a994415"
EMPTY_SHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
with tempfile.TemporaryDirectory() as d:
    assert domain_fingerprint(d) == EMPTY_SHA, "absent domain.md must hash to the pinned empty sentinel"
    os.makedirs(os.path.join(d, ".ship"))
    with open(os.path.join(d, ".ship", "domain.md"), "w", encoding="utf-8") as fh:
        fh.write(FIXTURE)
    assert domain_fingerprint(d) == FIXTURE_SHA, "fixture hash drifted from the pre-refactor value"
print("T3 ok")
PY
echo "PASS T3"

# ---------------------------------------------------------------------------
# T4: AC2/AC3 — the copy-pasted compare bodies are GONE: convergence.py, runner.py, and
#     surf-worker.sh no longer inline the sha256(b"") sentinel compare; each calls the shared
#     helper instead (surf-worker.sh imports it from sail.review).
# ---------------------------------------------------------------------------
for f in sail/convergence.py sail/runner.py; do
  if grep -q 'sha256(b"")' "$f"; then
    fail "T4: $f still inlines the empty-sentinel compare (copy-paste not removed)"
  fi
  grep -q 'domain_hash_stale' "$f" || fail "T4: $f does not call the shared domain_hash_stale helper"
done
# surf-worker.sh: code lines only (its comments may mention removed patterns by design)
WORKER_CODE="$(grep -vE '^[[:space:]]*#' config/surf-worker.sh)"
if printf '%s' "$WORKER_CODE" | grep -q 'sha256(b"")'; then
  fail "T4: surf-worker.sh still inlines the empty-sentinel compare"
fi
printf '%s' "$WORKER_CODE" | grep -q 'domain_hash_stale' || fail "T4: surf-worker.sh does not use the shared helper"
echo "PASS T4"

# ---------------------------------------------------------------------------
# T5: AC4 — DIRECT runner-site behavioral pin. The review-reuse gate in sail/runner.py must
#     drop a cached review when domain memory changes (and only then re-invoke the backend).
#     .ship/ is GITIGNORED in the fixture repo: `sail run`'s #76 pre-stage (`git ls-files
#     --others --exclude-standard` + `git add -N`) would otherwise pull an untracked domain.md
#     INTO the reviewed diff, so the #45 diff-content gate would fire first and mask the domain
#     gate. Ignoring it keeps diff_hash constant and isolates the DOMAIN freshness component.
# ---------------------------------------------------------------------------
T5_FIX="$(mktemp -d)"
trap 'rm -rf "$T5_FIX"' EXIT
T5_REPO="$T5_FIX/repo"
mkdir -p "$T5_REPO"
git -C "$T5_REPO" init -q
printf '.ship/\n' >"$T5_REPO/.gitignore"
printf 'def f():\n    return 1\n' >"$T5_REPO/m.py"
git -C "$T5_REPO" add -A
git -C "$T5_REPO" -c user.email=t@t -c user.name=t commit -qm base
printf 'def f():\n    return 2\n' >"$T5_REPO/m.py"
git -C "$T5_REPO" add -A
git -C "$T5_REPO" -c user.email=t@t -c user.name=t commit -qm change

T5_RD="$T5_FIX/rd"
mkdir -p "$T5_RD"
MOCK="$T5_FIX/mock.sh"
cat >"$MOCK" <<'MK'
#!/usr/bin/env bash
cat >/dev/null
echo "called" >>"$T5_CALLS"
cat <<'JSON'
{"findings": [], "summary": "clean"}
JSON
MK
chmod +x "$MOCK"

# run 1: seeds review.json (backend called once)
export T5_CALLS="$T5_FIX/calls"
: >"$T5_CALLS"
SAIL_CHECKERS=ruff SAIL_REVIEW_CMD="$MOCK" T5_CALLS="$T5_CALLS" \
  python3 -m sail run --target "$T5_REPO" --diff HEAD~1 --run-dir "$T5_RD" >/dev/null 2>&1 || true
[ "$(grep -c called "$T5_CALLS")" -eq 1 ] || fail "T5: seed run did not invoke the review backend exactly once"

# run 2 (control): same scope, domain memory unchanged -> reuse, backend NOT called again
SAIL_CHECKERS=ruff SAIL_REVIEW_CMD="$MOCK" T5_CALLS="$T5_CALLS" \
  python3 -m sail run --target "$T5_REPO" --diff HEAD~1 --run-dir "$T5_RD" >/dev/null 2>&1 || true
[ "$(grep -c called "$T5_CALLS")" -eq 1 ] || fail "T5: control resume re-reviewed despite unchanged domain memory (reuse broken)"

# run 3: domain memory appears (gitignored -> diff_hash unchanged) -> reuse dropped, re-review
mkdir -p "$T5_REPO/.ship"
printf '# Domain\nNEW FACT between checkpoints\n' >"$T5_REPO/.ship/domain.md"
SAIL_CHECKERS=ruff SAIL_REVIEW_CMD="$MOCK" T5_CALLS="$T5_CALLS" \
  python3 -m sail run --target "$T5_REPO" --diff HEAD~1 --run-dir "$T5_RD" >/dev/null 2>&1 || true
[ "$(grep -c called "$T5_CALLS")" -eq 2 ] || fail "T5: domain-only change did not force a re-review at the runner site"
grep -q "domain memory changed" "$T5_RD/decision-log.md" || fail "T5: decision-log missing the 'domain memory changed' stale marker"
echo "PASS T5"

# ---------------------------------------------------------------------------
# T6: AC5 — DIRECT surf-worker-site behavioral pin. surf_worker_result's fail-closed verifier
#     must flip GREEN -> PARK when domain memory changes after the review (same real-repo +
#     real-review.json harness as test_surf_worker.sh's currency cases).
# ---------------------------------------------------------------------------
T6_REPO="$T5_FIX/green-repo"
mkdir -p "$T6_REPO"
git -C "$T6_REPO" init -q
printf 'def f():\n    return 1\n' >"$T6_REPO/m.py"
git -C "$T6_REPO" add -A
git -C "$T6_REPO" -c user.email=t@t -c user.name=t commit -qm base
printf 'def f():\n    return 2\n' >"$T6_REPO/m.py"
git -C "$T6_REPO" add -A
git -C "$T6_REPO" -c user.email=t@t -c user.name=t commit -qm change
# the verifier's commit-existence backstop needs >=1 commit ahead of the reviewed base: HEAD~1..HEAD = 1. ok.

T6_RD="$T5_FIX/rd6"
mkdir -p "$T6_RD"
printf '%s\n' '{"schema_version":1,"run_id":"t","started_at":"x","gates":[{"name":"ruff","status":"passed","rc":0}]}' >"$T6_RD/run-state.json"
printf '%s\n' '{"status":"completed","acceptance_criteria":["the function returns 2"]}' >"$T6_RD/plan.json"
T6_MOCK="$T6_RD/mock.sh"
cat >"$T6_MOCK" <<'MK'
#!/usr/bin/env bash
cat >/dev/null
cat <<'JSON'
{"findings": [], "ac_results": [{"criterion": "the function returns 2", "status": "met", "evidence": "return 2"}], "summary": "clean"}
JSON
MK
chmod +x "$T6_MOCK"
SAIL_REVIEW_CMD="$T6_MOCK" python3 - "$T6_REPO" "$T6_RD" "$REPO_ROOT" <<'PY' >/dev/null 2>&1 || fail "T6: could not seed a real green review.json"
import sys; sys.path.insert(0, sys.argv[3])
from sail.review import run_review
run_review(sys.argv[1], "HEAD~1", run_dir=sys.argv[2], dual_lens=False)
PY

# shellcheck disable=SC1091
source "$REPO_ROOT/config/surf-worker.sh"
if surf_worker_result "$T6_RD" 0 "$T6_REPO"; then
  echo "PASS T6a (green baseline confirmed)"
else
  fail "T6: freshly-reviewed green run-dir wrongly parked (baseline broken)"
fi
# domain memory changes AFTER the review (untracked -> diff_hash untouched) -> must PARK
mkdir -p "$T6_REPO/.ship"
printf '# Domain\nNEW FACT after the review\n' >"$T6_REPO/.ship/domain.md"
if surf_worker_result "$T6_RD" 0 "$T6_REPO"; then
  fail "T6: surf-worker verifier stayed GREEN despite a post-review domain-memory change"
else
  echo "PASS T6b (domain-only change -> PARK)"
fi

echo "ALL PASS (test_sail_143_domain_dry)"
