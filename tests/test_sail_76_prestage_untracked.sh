#!/usr/bin/env bash
# test_sail_76_prestage_untracked.sh — issue #76: `run --diff` must pre-stage untracked,
# non-ignored files (`git add -N`) so diff-scoped gates and the T6 scope-guard see brand-new
# files that the build just created, without anyone remembering to stage them manually.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"
# Hermetic (.ship/domain.md #102): a real shell exports SAIL_* codex knobs (settings.json);
# clear them so each subtest controls its own backend (subtests set theirs via command prefix).
unset "${!SAIL_@}"

# A target repo with a committed baseline so there is a ref to diff against.
TGT="$WORK/target"; mkdir -p "$TGT"
git -C "$TGT" init -q
git -C "$TGT" config user.email t@t; git -C "$TGT" config user.name t
printf 'committed = 1\n' > "$TGT/base.py"
git -C "$TGT" add base.py
git -C "$TGT" commit -qm base
BASE="$(git -C "$TGT" rev-parse HEAD)"

prestage() { python3 -c "import sys; from sail.runner import _prestage_untracked; _prestage_untracked(sys.argv[1])" "$1"; }
gate_field() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));g=[x for x in d['gates'] if x['name']==sys.argv[2]][0];print(g.get(sys.argv[3]))" "$1" "$2" "$3"; }

# --- T1: a brand-new untracked .py file becomes visible to the diff against BASE ---
printf 'new = 2\n' > "$TGT/brand_new.py"
# Before pre-stage: untracked file is invisible to `git diff <ref>` (the foot-gun).
if git -C "$TGT" diff --name-only "$BASE" | grep -qx brand_new.py; then
  echo "FAIL T1 precondition: untracked file already in diff (test invalid)"; exit 1
fi
prestage "$TGT"
git -C "$TGT" diff --name-only "$BASE" | grep -qx brand_new.py \
  || { echo "FAIL T1: new untracked file not visible to diff after pre-stage"; exit 1; }
# Pin intent-to-add SPECIFICALLY (AC#6): `git status --short` must show ` A` (intent-to-add,
# content NOT staged) — never `A ` (fully staged). This fails under an `add -N` → `add` mutation.
st="$(git -C "$TGT" status --short brand_new.py)"
[ "${st:0:2}" = " A" ] \
  || { echo "FAIL T1: expected intent-to-add ' A', got '${st:0:2}' (add -N mutated to add?)"; exit 1; }
git -C "$TGT" diff --cached --name-only | grep -qx brand_new.py \
  && { echo "FAIL T1: brand_new.py has staged content (not intent-to-add)"; exit 1; }
echo "PASS T1: untracked new file is intent-to-add staged (content unstaged) → visible to diff-scoped gates"

# --- T2: .gitignore'd untracked files are NOT staged ---
printf 'ignored.py\n' > "$TGT/.gitignore"
printf 'secret = 3\n' > "$TGT/ignored.py"
prestage "$TGT"
if git -C "$TGT" ls-files --error-unmatch ignored.py >/dev/null 2>&1; then
  echo "FAIL T2: ignored file was staged (exclude-standard not honored)"; exit 1
fi
echo "PASS T2: .gitignore'd file is not staged"

# --- T3: NUL-safe — pathnames containing a space AND a newline are staged (AC#4) ---
# A literal newline in the name is the assertion a line-splitting (dropped `-z`) mutation fails.
printf 'spaced = 4\n' > "$TGT/with space.py"
nlfile="$(printf 'two\nlines.py')"; printf 'nl = 5\n' > "$TGT/$nlfile"
prestage "$TGT"
git -C "$TGT" ls-files --error-unmatch "with space.py" >/dev/null 2>&1 \
  || { echo "FAIL T3: file with space not staged (NUL-safety broken)"; exit 1; }
git -C "$TGT" ls-files --error-unmatch "$nlfile" >/dev/null 2>&1 \
  || { echo "FAIL T3: file with newline not staged (line-split, not NUL-safe)"; exit 1; }
echo "PASS T3: pathnames with a space AND a newline staged (NUL-safe, AC#4)"

# --- T4: idempotent — re-running pre-stage leaves the index intent-to-add (no content staged) ---
prestage "$TGT"
prestage "$TGT"
st4="$(git -C "$TGT" status --short brand_new.py)"
[ "${st4:0:2}" = " A" ] \
  || { echo "FAIL T4: after a second pre-stage, brand_new.py status='${st4:0:2}', expected ' A' (re-run promoted i-t-a to a full stage)"; exit 1; }
git -C "$TGT" diff --cached --name-only | grep -qx brand_new.py \
  && { echo "FAIL T4: re-run staged content for brand_new.py (idempotency broken)"; exit 1; }
echo "PASS T4: re-run is idempotent — index stays intent-to-add, no content staged"

# --- T5: end-to-end — `sail run --diff` itself pre-stages (catches deletion of the run() wiring) ---
# A fresh target so the assertion is clean. After a real `sail run --target T --diff BASE`, the
# brand-new untracked file must be intent-to-add in T's index — proving run() invoked the
# pre-stage before computing the diff. Deleting `_prestage_untracked(target_root)` from run()
# leaves the file `??` and fails this, which the direct-call tests above could not catch.
T2="$WORK/t2"; mkdir -p "$T2"
git -C "$T2" init -q
git -C "$T2" config user.email t@t; git -C "$T2" config user.name t
printf '.sail/\n' > "$T2/.gitignore"           # sail's own artifacts must not enter scope
printf 'committed = 1\n' > "$T2/base.py"
git -C "$T2" add base.py .gitignore
git -C "$T2" commit -qm base
B2="$(git -C "$T2" rev-parse HEAD)"
# The new file carries a ruff F401 (unused import). Ordering proof: the diff-scoped ruff gate
# can only flag it if pre-staging ran BEFORE gate execution — a mutation moving the pre-stage to
# after the gates would leave fresh_file.py untracked and unscanned (new_findings_count 0), so
# this catches the ordering bug that the final-index ` A` check alone cannot.
printf 'import os\nfresh = 9\n' > "$T2/fresh_file.py"      # brand-new, untracked, F401
python3 -m sail run --target "$T2" --diff "$B2" --run-dir "$WORK/rd_t5" --no-review >/dev/null 2>&1 || true
st5="$(git -C "$T2" status --short fresh_file.py)"
[ "${st5:0:2}" = " A" ] \
  || { echo "FAIL T5: after 'sail run --diff', fresh_file.py status='${st5:0:2}', expected ' A' (run() did not pre-stage)"; exit 1; }
# Stronger ordering proof when ruff is installed: the diff-scoped ruff gate can only flag the
# F401 if pre-staging ran BEFORE gate execution. Guard on ruff's presence so the suite does not
# fail spuriously where the static-analysis tool set is absent (#104) — the ` A` check above
# remains the ordering proxy in that case.
if command -v ruff >/dev/null 2>&1; then
  ruff_nf="$(gate_field "$WORK/rd_t5/run-state.json" ruff new_findings_count 2>/dev/null || echo 0)"
  case "$ruff_nf" in ''|0|None) echo "FAIL T5: ruff did not scan the pre-staged new file (new_findings_count=$ruff_nf) — pre-stage ran after gates?"; exit 1 ;; esac
  echo "PASS T5: 'sail run --diff' pre-stages BEFORE gates — ruff scanned the new file (new_findings=$ruff_nf)"
else
  echo "PASS T5 (ruff absent): pre-stage ran end-to-end (index ' A'); ruff-ordering assertion skipped (#104)"
fi

# --- T6: Sail's own run artifacts never enter the diff, even if the target does NOT ignore them ---
# Regression for the #76 round-3 leak: run_dir lives under the target and the target has NO
# `.sail/`/run-dir gitignore entry. The user-created file must appear in the diff; sail's own
# run-state.json (under run_dir) must NOT.
T3="$WORK/t3"; mkdir -p "$T3"
git -C "$T3" init -q
git -C "$T3" config user.email t@t; git -C "$T3" config user.name t
printf 'committed = 1\n' > "$T3/base.py"
git -C "$T3" add base.py
git -C "$T3" commit -qm base      # NOTE: no .gitignore — `.sailrun/` is NOT excluded
B3="$(git -C "$T3" rev-parse HEAD)"
printf 'user = 7\n' > "$T3/user_new.py"
RD6="$T3/.sailrun"                 # run-dir INSIDE the target, NOT gitignored
python3 -m sail run --target "$T3" --diff "$B3" --run-dir "$RD6" --no-review >/dev/null 2>&1 || true
diffnames="$(git -C "$T3" diff --name-only "$B3")"
echo "$diffnames" | grep -qx user_new.py \
  || { echo "FAIL T6: user file not in diff (pre-stage skipped it)"; exit 1; }
if echo "$diffnames" | grep -q '\.sailrun/'; then
  echo "FAIL T6: Sail's own run artifacts leaked into the reviewed diff:"; echo "$diffnames" | grep '\.sailrun/'; exit 1
fi
echo "PASS T6: run-dir artifacts excluded from the diff even when the target does not ignore them"

# --- T7: run_dir == target root must NOT disable pre-staging (degenerate-exclusion guard) ---
# A misconfigured run_dir equal to the target would, without the guard, filter out every user
# file (all are "under" run_dir) and silently no-op the whole feature.
T4D="$WORK/t4d"; mkdir -p "$T4D"
git -C "$T4D" init -q
git -C "$T4D" config user.email t@t; git -C "$T4D" config user.name t
printf 'committed = 1\n' > "$T4D/base.py"; git -C "$T4D" add base.py; git -C "$T4D" commit -qm base
printf 'user = 8\n' > "$T4D/new_when_rd_is_root.py"
python3 -c "import sys; from sail.runner import _prestage_untracked; _prestage_untracked(sys.argv[1], sys.argv[1])" "$T4D"
git -C "$T4D" ls-files --error-unmatch new_when_rd_is_root.py >/dev/null 2>&1 \
  || { echo "FAIL T7: run_dir==target filtered out the user file (pre-stage silently disabled)"; exit 1; }
echo "PASS T7: run_dir==target root does not disable pre-staging"

echo "PASS: sail #76 pre-stage untracked files verified"
