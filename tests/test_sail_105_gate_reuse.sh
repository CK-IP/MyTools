#!/usr/bin/env bash
# test_sail_105_gate_reuse.sh — issue #105: per-gate reuse on a same-scope resume.
# Post-#79, ANY diff-content change on resume resets ALL terminal gates. #105 (Path B,
# file-relevance): when the ONLY reason to reset is a same-scope diff MOVE (both fingerprints
# present, scope unchanged), reset only the gates whose dependency file-types appear in the
# changed-file set; keep the others green (reused). The #79 fail-safe is preserved — a scope
# change or a missing/uncomputable fingerprint still resets ALL gates (uncertainty => re-run).
# Conservative throughout: any uncertainty => re-run, never skip (no stale all-clear).
# Hermetic: throwaway git targets, gate-only runs (--no-review), real ruff/shellcheck.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"
# Hermetic (.ship/domain.md #102): clear inherited SAIL_* codex knobs; each subtest sets its own.
unset "${!SAIL_@}"

fail() { echo "FAIL: $*"; exit 1; }
gate_field() { # $1=state.json $2=gate-name $3=field
  python3 -c "import json,sys
d=json.load(open(sys.argv[1]))
g=next((x for x in d['gates'] if x['name']==sys.argv[2]), None)
print(g.get(sys.argv[3]) if g else 'MISSING')" "$1" "$2" "$3"
}

# ---------------------------------------------------------------------------
# T1: affected_by per-gate dependency rule (the deterministic, tested heart).
# ---------------------------------------------------------------------------
python3 - <<'PY' || fail "T1: affected_by per-gate rule"
from sail.checkers import build_registry
reg = {c.name: c for c in build_registry()}
def chk(name, files, expect):
    got = reg[name].affected_by(files)
    assert got is expect, f"{name}.affected_by({files}) = {got}, expected {expect}"
# python lint/type gates -> .py + .pyi stubs (ruff also .ipynb notebooks)
chk("ruff", ["a.py"], True);            chk("ruff", ["README.md"], False)
chk("ruff", ["stubs/a.pyi"], True);     chk("ruff", ["nb.ipynb"], True)
chk("mypy", ["pkg/b.py"], True);        chk("mypy", ["docs/x.rst"], False)
chk("mypy", ["stubs/a.pyi"], True)
# ruff respects ignore files: a .gitignore/.ruffignore edit can change its scanned set + verdict.
chk("ruff", [".gitignore"], True);      chk("ruff", [".ruffignore"], True)
# shell gate -> only .sh
chk("shellcheck", ["x.sh"], True);      chk("shellcheck", ["a.py"], False)
# narrow gates also re-run on their own TOOL CONFIG (a config edit can flip a prior green).
chk("ruff", ["pyproject.toml"], True);  chk("ruff", ["ruff.toml"], True);  chk("ruff", [".ruff.toml"], True)
chk("mypy", ["mypy.ini"], True);        chk("mypy", ["setup.cfg"], True);  chk("mypy", ["pyproject.toml"], True)
chk("shellcheck", [".shellcheckrc"], True)
# python dep manifests (incl. the pip-tools requirements/ dir layout)
chk("pip-audit", ["pyproject.toml"], True)
chk("pip-audit", ["requirements-dev.txt"], True)
chk("pip-audit", ["requirements/dev.txt"], True)   # pip-tools layout
chk("pip-audit", ["a.py"], False)
# node dep manifests
chk("npm-audit", ["package.json"], True)
chk("npm-audit", ["yarn.lock"], True)
chk("npm-audit", ["a.py"], False)
# PURE code scanners (bandit/semgrep) only analyze .py — re-run on any code file, skip only when
# EVERY changed file is clearly prose (.md/.rst). .txt is NOT inert (often a fixture/golden file).
for g in ("bandit", "semgrep"):
    chk(g, ["a.py"], True)
    chk(g, ["a.py", "README.md"], True)   # mixed: any non-doc file => re-run
    chk(g, ["README.md"], False)          # markdown-only => skip
    chk(g, ["docs/a.md", "docs/b.rst"], False)
    chk(g, ["fixture.txt"], True)         # .txt may be a fixture => re-run (not inert)
# Gates that read/execute ARBITRARY files cannot be scoped by suffix — always re-run when the
# diff moved: gitleaks (secrets can hide in any file incl. docs), pytest (doctests/fixtures can
# live in .md/.rst/.txt via --doctest-glob), diff-coverage (diff-derived).
for g in ("gitleaks", "pytest", "diff-coverage"):
    chk(g, ["a.py"], True)
    chk(g, ["README.md"], True)
    chk(g, ["doc.rst"], True)
    chk(g, ["notes.txt"], True)
# empty list (uncertainty) => re-run everything (fail-safe)
for g in reg:
    assert reg[g].affected_by([]) is True, f"{g}.affected_by([]) must be True (uncertainty)"
print("PASS T1: affected_by per-gate rule")
PY
echo "PASS T1: affected_by per-gate dependency rule"

# ---------------------------------------------------------------------------
# Shared target builder: a git repo whose base has a clean .py and .sh, plus a
# .gitignore for gate side-artifacts (so .coverage/__pycache__ never pollute the
# diff fingerprint — exactly what a real repo does).
# ---------------------------------------------------------------------------
mk_target() { # $1=dir  (optional $2=include script.sh in base: yes|no, default yes)
  local d="$1" with_sh="${2:-yes}"
  mkdir -p "$d"
  printf 'def f(x):\n    return x + 1\n' > "$d/mod.py"
  printf '.coverage\n__pycache__/\n.sail/\n' > "$d/.gitignore"
  [ "$with_sh" = "yes" ] && printf '#!/bin/sh\necho hello\n' > "$d/ok.sh"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  git -C "$d" add -A
  git -C "$d" commit -qm base
}

# ---------------------------------------------------------------------------
# T2: an irrelevant gate is REUSED on a same-scope diff move.
#   round1: edit mod.py only -> ruff+shellcheck both green.
#   round2: edit mod.py again (diff moves, SAME scope/ref) -> ruff re-run,
#           the shellcheck gate REUSED (its .sh inputs are absent from the diff).
# ---------------------------------------------------------------------------
TGT="$WORK/t2"; mk_target "$TGT"
BASE="$(git -C "$TGT" rev-parse HEAD)"
RD="$WORK/rd2"; STATE="$RD/run-state.json"; DLOG="$RD/decision-log.md"
export SAIL_CHECKERS=ruff,shellcheck

printf 'def f(x):\n    return x + 2\n' > "$TGT/mod.py"   # round1 change (.py only)
python3 -m sail run --target "$TGT" --diff "$BASE" --run-dir "$RD" --no-review >/dev/null 2>&1 || true
[ -f "$STATE" ] || fail "T2: no run-state after round1"
[ "$(gate_field "$STATE" ruff status)" = "passed" ] || fail "T2: ruff not green in round1 ($(gate_field "$STATE" ruff status))"
[ "$(gate_field "$STATE" shellcheck status)" = "passed" ] || fail "T2: shellcheck not green in round1 ($(gate_field "$STATE" shellcheck status))"
SC_SEQ1="$(gate_field "$STATE" shellcheck seq)"
RUFF_SEQ1="$(gate_field "$STATE" ruff seq)"

printf 'def f(x):\n    return x + 3\n' > "$TGT/mod.py"   # round2: diff MOVES, same scope/ref
python3 -m sail run --target "$TGT" --diff "$BASE" --run-dir "$RD" --no-review >/dev/null 2>&1 || true
SC_SEQ2="$(gate_field "$STATE" shellcheck seq)"
RUFF_SEQ2="$(gate_field "$STATE" ruff seq)"

[ "$SC_SEQ2" = "$SC_SEQ1" ] || fail "T2: shellcheck was re-run (seq $SC_SEQ1 -> $SC_SEQ2); a .py-only diff move must REUSE it"
[ "$RUFF_SEQ2" != "$RUFF_SEQ1" ] || fail "T2: ruff was NOT re-run (seq stayed $RUFF_SEQ1); a .py change must reset it"
grep -qi "gate-reuse" "$DLOG" || fail "T2: missing gate-reuse marker for the skipped (reused) gate"
echo "PASS T2: irrelevant gate reused on a same-scope diff move; relevant gate re-run"

# ---------------------------------------------------------------------------
# T3: a gate-relevant change still INVALIDATES that gate (no stale all-clear).
#   round1: .py-only diff -> shellcheck green (no .sh anywhere).
#   round2: ADD a .sh with a shellcheck violation -> shellcheck MUST be reset+re-run.
# ---------------------------------------------------------------------------
TGT="$WORK/t3"; mk_target "$TGT" no          # base has NO .sh
BASE="$(git -C "$TGT" rev-parse HEAD)"
RD="$WORK/rd3"; STATE="$RD/run-state.json"; DLOG="$RD/decision-log.md"

printf 'def f(x):\n    return x + 2\n' > "$TGT/mod.py"   # round1 change (.py only)
python3 -m sail run --target "$TGT" --diff "$BASE" --run-dir "$RD" --no-review >/dev/null 2>&1 || true
[ "$(gate_field "$STATE" shellcheck status)" = "passed" ] || [ "$(gate_field "$STATE" shellcheck status)" = "skipped" ] \
  || fail "T3: shellcheck unexpectedly $(gate_field "$STATE" shellcheck status) in round1 (expected green/skipped, no .sh present)"
SC_SEQ1="$(gate_field "$STATE" shellcheck seq)"

# round2: introduce a .sh with an unmistakable shellcheck finding (unquoted var -> SC2086).
# The single quotes are intentional — we WANT the literal `$UNQUOTED` written into bad.sh — so
# suppress SC2016 (which would otherwise fail this test file under the project's own shellcheck gate).
# shellcheck disable=SC2016
printf '#!/bin/sh\nrm $UNQUOTED\n' > "$TGT/bad.sh"
python3 -m sail run --target "$TGT" --diff "$BASE" --run-dir "$RD" --no-review >/dev/null 2>&1 || true
SC_SEQ2="$(gate_field "$STATE" shellcheck seq)"
[ "$SC_SEQ2" != "$SC_SEQ1" ] || fail "T3: shellcheck was REUSED ($SC_SEQ1) after a .sh was added — stale all-clear! must reset+re-run"
echo "PASS T3: a newly-relevant .sh resets+re-runs shellcheck (no stale all-clear)"

# ---------------------------------------------------------------------------
# T4: fail-safe — a CHANGED --diff ref (scope change) still resets ALL gates.
# ---------------------------------------------------------------------------
TGT="$WORK/t4"; mk_target "$TGT"
git -C "$TGT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m second >/dev/null 2>&1
BASE1="$(git -C "$TGT" rev-parse HEAD~1)"
BASE2="$(git -C "$TGT" rev-parse HEAD)"
RD="$WORK/rd4"; STATE="$RD/run-state.json"; DLOG="$RD/decision-log.md"
export SAIL_CHECKERS=ruff,shellcheck

printf 'def f(x):\n    return x + 2\n' > "$TGT/mod.py"
python3 -m sail run --target "$TGT" --diff "$BASE1" --run-dir "$RD" --no-review >/dev/null 2>&1 || true
SC_SEQ1="$(gate_field "$STATE" shellcheck seq)"
# resume with a DIFFERENT --diff ref => scope changed => fail-safe resets ALL terminal gates.
python3 -m sail run --target "$TGT" --diff "$BASE2" --run-dir "$RD" --no-review >/dev/null 2>&1 || true
SC_SEQ2="$(gate_field "$STATE" shellcheck seq)"
[ "$SC_SEQ2" != "$SC_SEQ1" ] || fail "T4: scope change must reset shellcheck too (fail-safe), but seq stayed $SC_SEQ1"
echo "PASS T4: scope change resets ALL gates (fail-safe preserved)"

# ---------------------------------------------------------------------------
# T5: only ALREADY-GREEN (passed) gates are reusable. A non-green terminal gate
#   (failed/skipped) whose inputs are unaffected must STILL reset+re-run on a
#   same-scope resume — never preserve a stale failed/skipped verdict.
# ---------------------------------------------------------------------------
TGT="$WORK/t5"; mk_target "$TGT" no          # base has NO .sh
BASE="$(git -C "$TGT" rev-parse HEAD)"
RD="$WORK/rd5"; STATE="$RD/run-state.json"
export SAIL_CHECKERS=ruff,shellcheck

printf 'def f(x):\n    return x + 2\n' > "$TGT/mod.py"   # round1: .py-only diff (no .sh anywhere)
python3 -m sail run --target "$TGT" --diff "$BASE" --run-dir "$RD" --no-review >/dev/null 2>&1 || true
# Force a STALE non-green verdict on the shellcheck gate (mirrors test_sail_79's run-state poke):
# pretend a prior round left it failed with a stale artifact, though its .sh inputs are unaffected.
python3 - "$STATE" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
g=[x for x in d["gates"] if x["name"]=="shellcheck"][0]
g["status"]="failed"; g["artifact"]="STALE.txt"; g["rc"]=1
json.dump(d,open(p,"w"),indent=2,sort_keys=True)
PY
printf 'def f(x):\n    return x + 3\n' > "$TGT/mod.py"   # round2: .py-only move (shellcheck still unaffected)
python3 -m sail run --target "$TGT" --diff "$BASE" --run-dir "$RD" --no-review >/dev/null 2>&1 || true
ART="$(gate_field "$STATE" shellcheck artifact)"
[ "$ART" != "STALE.txt" ] || fail "T5: a FAILED gate with unaffected inputs was REUSED (stale 'STALE.txt' preserved); only passed gates may be reused"
echo "PASS T5: a non-green (failed) gate is always reset+re-run, never reused"

# ---------------------------------------------------------------------------
# T6: changed_files is rename-blind. Under diff.renames=true, `git diff --name-only`
#   reports only a rename's DESTINATION, so a `.py -> .md` rename would hide the lost
#   Python source and let mypy/pytest reuse a stale green. changed_files must surface
#   BOTH sides (the old .py path must appear), so the relevant gate still resets.
# ---------------------------------------------------------------------------
TGT="$WORK/t6"; mk_target "$TGT" no
git -C "$TGT" config diff.renames true
BASE="$(git -C "$TGT" rev-parse HEAD)"
git -C "$TGT" mv mod.py renamed.md          # rename a .py to a doc suffix
git -C "$TGT" -c user.email=t@t -c user.name=t commit -qm rename
unset SAIL_CHECKERS                          # need the full registry (mypy/pytest) for this check
python3 - "$TGT" "$BASE" <<'PY' || fail "T6: changed_files hid a rename's source path (.py lost)"
import sys
from sail.review import changed_files
from sail.checkers import build_registry
files = changed_files(sys.argv[1], sys.argv[2])
assert "mod.py" in files, f"changed_files must surface the renamed-away .py source; got {files}"
reg = {c.name: c for c in build_registry()}
assert reg["mypy"].affected_by(files) is True, "mypy must reset when a .py was renamed away"
assert reg["pytest"].affected_by(files) is True, "pytest must reset when a .py was renamed away"
print("PASS T6 inner")
PY
echo "PASS T6: changed_files surfaces both sides of a rename (no hidden stale-green)"

echo "ALL PASS: test_sail_105_gate_reuse"
