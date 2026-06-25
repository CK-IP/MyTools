#!/usr/bin/env bash
# test_sail_diff.sh — issue #34: diff/baseline scoping mode (runner + CLI integration).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"
# Hermetic (.ship/domain.md #102): a real shell exports SAIL_* codex knobs (settings.json);
# clear them so each subtest controls its own backend (subtests set theirs via command prefix).
unset "${!SAIL_@}"

# Tiny git target with a deliberate ruff finding so the whole-repo run is non-clean.
TGT="$WORK/target"; mkdir -p "$TGT"
printf 'import os\nx=1\n' > "$TGT/mod.py"   # F401 unused import → ruff flags it
git -C "$TGT" init -q   # git repo (no commits needed; T4 uses an invalid ref)

gate_field() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));g=[x for x in d['gates'] if x['name']==sys.argv[2]][0];print(g.get(sys.argv[3]))" "$1" "$2" "$3"; }

# --- T1: baseline mode on identical code → zero new findings (suppression) ---
RD1="$WORK/rd1"; RD2="$WORK/rd2"
python3 -m sail run --target "$TGT" --run-dir "$RD1" >/dev/null 2>&1 || true
python3 -m sail run --target "$TGT" --baseline "$RD1" --run-dir "$RD2" >/dev/null 2>&1 || true
[ -f "$RD2/run-state.json" ] || { echo "FAIL T1: no run-state for baseline run"; exit 1; }
for g in ruff bandit; do
  mode=$(gate_field "$RD2/run-state.json" "$g" mode)
  nf=$(gate_field "$RD2/run-state.json" "$g" new_findings_count)
  [ "$mode" = "baseline" ] || { echo "FAIL T1: $g mode=$mode, expected baseline"; exit 1; }
  [ "$nf" = "0" ] || { echo "FAIL T1: $g new_findings_count=$nf, expected 0 (same code)"; exit 1; }
done
r1=$(gate_field "$RD1/run-state.json" ruff status)
r2=$(gate_field "$RD2/run-state.json" ruff status)
[ "$r2" = "passed" ] || { echo "FAIL T1: ruff baseline status=$r2, expected passed (0 new); whole-repo was $r1"; exit 1; }
grep -qi "mode" "$RD2/decision-log.md" || { echo "FAIL T1: decision log missing mode marker"; exit 1; }
echo "PASS T1: baseline mode suppresses pre-existing (ruff whole-repo=$r1 -> baseline=passed, 0 new)"

# --- T2: whole-repo mode unchanged (no flags) ---
RD3="$WORK/rd3"
python3 -m sail run --target "$TGT" --run-dir "$RD3" >/dev/null 2>&1 || true
m=$(gate_field "$RD3/run-state.json" ruff mode)
case "$m" in whole-repo|None) : ;; *) echo "FAIL T2: whole-repo mode=$m"; exit 1 ;; esac
echo "PASS T2: whole-repo mode preserved (ruff mode=$m)"

# --- T3: --diff and --baseline mutually exclusive ---
if python3 -m sail run --target "$TGT" --diff HEAD --baseline "$RD1" --run-dir "$WORK/rd4" >/dev/null 2>&1; then
  echo "FAIL T3: --diff + --baseline should be mutually exclusive"; exit 1
fi
echo "PASS T3: --diff/--baseline mutually exclusive"

# --- T4: invalid --diff ref fails loudly (non-zero), not silent whole-repo ---
if python3 -m sail run --target "$TGT" --diff no-such-ref-xyz --run-dir "$WORK/rd5" >/dev/null 2>&1; then
  echo "FAIL T4: invalid --diff ref should fail loudly"; exit 1
fi
echo "PASS T4: invalid --diff ref fails loudly"

# --- T5: --baseline overlapping --run-dir is rejected (else current overwrites baseline) ---
if python3 -m sail run --target "$TGT" --baseline "$RD1" --run-dir "$RD1" >/dev/null 2>&1; then
  echo "FAIL T5: --baseline == --run-dir must be rejected"; exit 1
fi
echo "PASS T5: overlapping --baseline/--run-dir rejected"

echo "PASS: sail diff/baseline scoping (#34) verified"
