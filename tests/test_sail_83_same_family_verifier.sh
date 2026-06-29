#!/usr/bin/env bash
# test_sail_83_same_family_verifier.sh — issue #83 (NARROWED residual): warn when the Gear-2
# tidiness verifier resolves to the SAME family as the Gear-1 tidiness lens. The verifier is meant
# to be an INDEPENDENT cross-family confirmation before a block-tier candidate gets teeth; a
# same-family verifier degenerates into self-rubber-stamping (an integrity gap → ALERT-class).
# v1 is a WARNING + docs, NOT hard family-enforcement: review_tidiness records a `same_family_warning`
# in review.json's tidiness block (and run_review emits an ⚠ decision-log line).
# Asserts: same-family verifier → warning emitted; genuinely cross-family verifier → NO warning.
# Hermetic per #64/#102: mocks every backend, clears inherited SAIL_* knobs, throwaway git targets.
# shellcheck disable=SC2016  # ${RC:-0}/${$2:-} are written LITERALLY into the generated mock scripts
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
# Hermetic: a real shell exports SAIL_* codex knobs (settings.json); clear them so each subtest
# controls its own backend (subtests set theirs via command prefix).
unset "${!SAIL_@}"
export SAIL_CHECKERS=ruff,pytest
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"

fail() { echo "FAIL: $*"; exit 1; }

# Mock LLM emitting a fixed string, placed at a path whose BASENAME is the backend "family"
# (_backend_family keys off os.path.basename(argv[0])) so same/cross-family is genuinely exercised.
mk_family_mock() { # $1=family-name $2=outvar-env-name -> echoes the created executable path
  local dir="$WORK/$1.$2"; mkdir -p "$dir"
  local path="$dir/$1"
  printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' "printf '%s' \"\${$2:-}\"" 'exit ${RC:-0}' > "$path"
  chmod +x "$path"
  echo "$path"
}

# Cross-family verifier mock at a family-named path: confirms every candidate id it sees so the
# Gear-2 path runs to completion (the warning itself is recorded regardless of the verdict).
mk_verify_mock() { # $1=family-name -> echoes the created executable path
  local dir="$WORK/$1.verify"; mkdir -p "$dir"
  local path="$dir/$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
in="$(cat)"
IN="$in" python3 - <<'PY'
import os, re, json
ids = re.findall(r'"id":\s*"([^"]+)"', os.environ["IN"])
print(json.dumps({"verdicts": [{"id": i, "confirmed": True, "reason": "mock"} for i in ids]}))
PY
EOF
  chmod +x "$path"
  echo "$path"
}

REVIEW_CLAUDE="$(mk_family_mock claude REVIEW_OUT)"   # correctness lens (family irrelevant here)
TIDY_CODEX="$(mk_family_mock codex TIDY_OUT)"         # Gear-1 tidiness lens, family "codex"
TIDY_CLAUDE="$(mk_family_mock claude TIDY_OUT)"       # Gear-1 tidiness lens, family "claude"
VERIFY_CODEX="$(mk_verify_mock codex)"                # Gear-2 verifier, family "codex"
TIDY_MYLLM="$(mk_family_mock myllm TIDY_OUT)"         # Gear-1 lens, UNKNOWN family "myllm"
VERIFY_OTHERLLM="$(mk_verify_mock otherllm)"          # Gear-2 verifier, UNKNOWN family "otherllm"

CLEAN='{"findings":[],"summary":"no issues"}'
# Block-tier EASY WIN (dead code) — a would-block candidate, so Gear-2 verification fires.
BLOCK_DEADCODE='{"findings":[{"severity":"LOW","tier":"block","category":"simplification","file":"mod.py","line":2,"issue":"dead local x/y never used after inline","recommendation":"return 1+2"}],"summary":"1"}'

new_target() { # $1=dir : clean git target with a multi-line working-tree change
  mkdir -p "$1"
  printf 'def f():\n    return 1\n' > "$1/mod.py"
  git -C "$1" init -q
  git -C "$1" add -A
  git -C "$1" -c user.email=t@t -c user.name=t commit -qm base
  printf 'def f():\n    x = 1\n    y = 2\n    return x + y  # changed\n' > "$1/mod.py"
}

run_sail() { # $1=target $2=run-dir : runs the tidiness review (exit code irrelevant — we assert on review.json)
  python3 -m sail run --target "$1" --diff HEAD --run-dir "$2" --tidiness >/dev/null 2>&1 || true
}

warn_present() { # $1=review.json -> exits 0 if same_family_warning present (else 1)
  python3 - "$1" <<'PY'
import json, sys
t = json.load(open(sys.argv[1])).get("tidiness") or {}
sys.exit(0 if t.get("same_family_warning") else 1)
PY
}

# --- T1: SAME-family verifier (Gear-1 codex, verifier codex) → warning emitted. ---
TGT="$WORK/t1"; new_target "$TGT"; RD="$WORK/rd1"
SAIL_REVIEW_CMD="$REVIEW_CLAUDE" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="$TIDY_CODEX" TIDY_OUT="$BLOCK_DEADCODE" \
SAIL_TIDINESS_VERIFY_CMD="$VERIFY_CODEX" \
  run_sail "$TGT" "$RD"
[ -f "$RD/review.json" ] || fail "T1: review.json not written — tidiness path did not run"
warn_present "$RD/review.json" || fail "T1: same-family verifier did not emit same_family_warning"
grep -q "rubber-stamping" "$RD/decision-log.md" || fail "T1: decision log missing the ⚠ code-health warning line"
echo "PASS T1: same-family Gear-2 verifier emits the rubber-stamp warning (review.json + decision log)"

# --- T2: genuinely CROSS-family verifier (Gear-1 claude, verifier codex) → NO warning. ---
TGT="$WORK/t2"; new_target "$TGT"; RD="$WORK/rd2"
SAIL_REVIEW_CMD="$REVIEW_CLAUDE" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="$TIDY_CLAUDE" TIDY_OUT="$BLOCK_DEADCODE" \
SAIL_TIDINESS_VERIFY_CMD="$VERIFY_CODEX" \
  run_sail "$TGT" "$RD"
# Positive proof the cross-family Gear-2 path ACTUALLY ran (else "no warning" would pass vacuously
# even if the verifier never fired): the verifier confirmed the block candidate, so the tidiness
# block must show a completed verification with a blocking finding.
python3 - "$RD/review.json" <<'PY' || fail "T2: cross-family Gear-2 path did not run — negative test would pass vacuously"
import json, os, sys
assert os.path.exists(sys.argv[1]), f"review.json not written: {sys.argv[1]}"
t = json.load(open(sys.argv[1])).get("tidiness") or {}
assert t.get("status") == "completed", f"tidiness lens did not complete: {t.get('status')}"
assert (t.get("verification") or {}).get("status") == "completed", "Gear-2 verification did not run"
assert t.get("blocking"), "cross-family verifier did not confirm — verification path not exercised"
PY
if warn_present "$RD/review.json"; then fail "T2: cross-family verifier wrongly emitted same_family_warning"; fi
if grep -q "rubber-stamping" "$RD/decision-log.md"; then fail "T2: decision log wrongly emitted the rubber-stamp warning"; fi
echo "PASS T2: a genuinely cross-family verifier (Gear-2 confirmed) emits NO warning (no false positive)"

# --- T4: env-WRAPPED SAME-family (#118). Gear-1 plain codex; verifier '/usr/bin/env <codex>'. ---
# Pins the MISSED-real-same-family half of the bug: before the basename fix _backend_family keys off
# the un-basenamed argv[0], so '/usr/bin/env …' resolves to 'env' (not 'codex') and a genuinely
# same-family verifier slips past with NO warning. After the fix both read 'codex' → warning fires.
TGT="$WORK/t4"; new_target "$TGT"; RD="$WORK/rd4"
SAIL_REVIEW_CMD="$REVIEW_CLAUDE" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="$TIDY_CODEX" TIDY_OUT="$BLOCK_DEADCODE" \
SAIL_TIDINESS_VERIFY_CMD="/usr/bin/env $VERIFY_CODEX" \
  run_sail "$TGT" "$RD"
[ -f "$RD/review.json" ] || fail "T4: review.json not written — tidiness path did not run"
warn_present "$RD/review.json" || fail "T4: env-wrapped same-family verifier did not emit same_family_warning (basename normalization missing)"
echo "PASS T4: '/usr/bin/env' wrapper normalizes to the inner family → same-family warning still fires"

# --- T5: env-WRAPPED CROSS-family (#118). Gear-1 '/usr/bin/env <claude>'; verifier '/usr/bin/env <codex>'. ---
# Pins the FALSE-ALARM half: before the fix BOTH wrapper forms collapse to 'env' → 'env'=='env' →
# wrong warning. After the fix they read 'claude' vs 'codex' → NO warning, and the Gear-2 path still
# runs to completion (positive proof the negative isn't vacuous).
TGT="$WORK/t5"; new_target "$TGT"; RD="$WORK/rd5"
SAIL_REVIEW_CMD="$REVIEW_CLAUDE" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="/usr/bin/env $TIDY_CLAUDE" TIDY_OUT="$BLOCK_DEADCODE" \
SAIL_TIDINESS_VERIFY_CMD="/usr/bin/env $VERIFY_CODEX" \
  run_sail "$TGT" "$RD"
python3 - "$RD/review.json" <<'PY' || fail "T5: env-wrapped cross-family Gear-2 path did not run — negative test would pass vacuously"
import json, os, sys
assert os.path.exists(sys.argv[1]), f"review.json not written: {sys.argv[1]}"
t = json.load(open(sys.argv[1])).get("tidiness") or {}
assert t.get("status") == "completed", f"tidiness lens did not complete: {t.get('status')}"
assert (t.get("verification") or {}).get("status") == "completed", "Gear-2 verification did not run"
assert t.get("blocking"), "cross-family verifier did not confirm — verification path not exercised"
PY
if warn_present "$RD/review.json"; then fail "T5: two '/usr/bin/env'-wrapped backends wrongly collapsed to 'env' → false same_family_warning"; fi
echo "PASS T5: two env-wrapped backends do NOT collapse to 'env' (claude vs codex) → no false warning"

# --- T3: UNKNOWN distinct families (#118 LOW). Gear-1 'myllm'; verifier 'otherllm' → NO warning. ---
# Reframed from the LOW finding's literal premise ("a mock whose basename _backend_family returns ''"):
# _backend_family returns the basename, never '' for a resolvable command, so two IDENTICAL unknown
# names ('myllm'/'myllm') are genuinely same-family and SHOULD warn (not a false positive). The
# protective intent — "unknown-family pairs must not false-alarm" — is pinned by asserting two
# DISTINCT unknown basenames raise no warning, with the Gear-2 path still completing.
TGT="$WORK/t3"; new_target "$TGT"; RD="$WORK/rd3"
SAIL_REVIEW_CMD="$REVIEW_CLAUDE" REVIEW_OUT="$CLEAN" \
SAIL_TIDINESS_CMD="$TIDY_MYLLM" TIDY_OUT="$BLOCK_DEADCODE" \
SAIL_TIDINESS_VERIFY_CMD="$VERIFY_OTHERLLM" \
  run_sail "$TGT" "$RD"
python3 - "$RD/review.json" <<'PY' || fail "T3: unknown-family Gear-2 path did not run — negative test would pass vacuously"
import json, os, sys
assert os.path.exists(sys.argv[1]), f"review.json not written: {sys.argv[1]}"
t = json.load(open(sys.argv[1])).get("tidiness") or {}
assert t.get("status") == "completed", f"tidiness lens did not complete: {t.get('status')}"
assert (t.get("verification") or {}).get("status") == "completed", "Gear-2 verification did not run"
assert t.get("blocking"), "unknown-family verifier did not confirm — verification path not exercised"
PY
if warn_present "$RD/review.json"; then fail "T3: distinct unknown families (myllm vs otherllm) wrongly emitted same_family_warning"; fi
echo "PASS T3: distinct unknown families do NOT false-alarm (myllm vs otherllm → no warning)"

echo "ALL PASS: test_sail_83_same_family_verifier.sh"
