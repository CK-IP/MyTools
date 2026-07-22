#!/usr/bin/env bash
# test_sail_150_docs_currency.sh — issue #150: docs-currency gate.
# A new SAIL_*/SURF_* env-var read, external CLI dependency, or commands/*.md driver flag
# introduced without a docs mention (INSTALL.md/README/another commands/*.md file) becomes a
# blocking finding. Conservative by design: ambiguous CLI-dep mentions never block. Diff-scoped
# via affected_by. Hermetic: throwaway git repos, no network, no external tools required.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$REPO_ROOT"
unset "${!SAIL_@}"

fail() { echo "FAIL: $*" >&2; exit 1; }

mkrepo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name test
}

# ---------------------------------------------------------------------------
# T1: affected_by — diff-scoped, fires only on sail/*.py or commands/*.md.
# ---------------------------------------------------------------------------
python3 - <<'PY' || fail "T1: affected_by scoping"
from sail.checkers import build_registry
reg = {c.name: c for c in build_registry()}
c = reg["docs-currency"]
assert c.affected_by(["sail/checkers.py"]) is True
assert c.affected_by(["commands/sail.md"]) is True
assert c.affected_by(["README.md"]) is False
assert c.affected_by(["tests/test_foo.sh"]) is False
assert c.affected_by([]) is True  # empty/unknown -> conservative re-run
PY

# ---------------------------------------------------------------------------
# T2: undocumented new SAIL_* env-var read -> blocking finding.
# ---------------------------------------------------------------------------
R2="$WORK/t2"; mkrepo "$R2"
cat >"$R2/mod.py" <<'PY'
import os

def f():
    return None
PY
git -C "$R2" add -A && git -C "$R2" commit -q -m base
BASE2="$(git -C "$R2" rev-parse HEAD)"
cat >"$R2/mod.py" <<'PY'
import os

def f():
    return os.environ["SAIL_NEWKNOB"]
PY
git -C "$R2" add -A && git -C "$R2" commit -q -m change

python3 - "$R2" "$BASE2" <<'PY' || fail "T2: undocumented env-var must block"
import sys
sys.path.insert(0, ".")
from sail.docs_currency import find_docs_currency_findings
repo, base = sys.argv[1], sys.argv[2]
found = find_docs_currency_findings(repo, base)
assert any(f["kind"] == "env-var" and f["token"] == "SAIL_NEWKNOB" for f in found), found
PY

# ---------------------------------------------------------------------------
# T3: same env-var introduction, but the diff ALSO touches INSTALL.md -> no block.
# ---------------------------------------------------------------------------
R3="$WORK/t3"; mkrepo "$R3"
cat >"$R3/mod.py" <<'PY'
import os

def f():
    return None
PY
cat >"$R3/INSTALL.md" <<'MD'
# install
MD
git -C "$R3" add -A && git -C "$R3" commit -q -m base
BASE3="$(git -C "$R3" rev-parse HEAD)"
cat >"$R3/mod.py" <<'PY'
import os

def f():
    return os.environ["SAIL_NEWKNOB"]
PY
cat >>"$R3/INSTALL.md" <<'MD'
Set SAIL_NEWKNOB to configure the new knob.
MD
git -C "$R3" add -A && git -C "$R3" commit -q -m change

python3 - "$R3" "$BASE3" <<'PY' || fail "T3: documented introduction must not block"
import sys
sys.path.insert(0, ".")
from sail.docs_currency import find_docs_currency_findings
repo, base = sys.argv[1], sys.argv[2]
found = find_docs_currency_findings(repo, base)
assert not any(f["kind"] == "env-var" and f["token"] == "SAIL_NEWKNOB" for f in found), found
PY

# ---------------------------------------------------------------------------
# T4: unrelated diff (no sail/*.py, no commands/*.md) -> no findings at all.
# ---------------------------------------------------------------------------
R4="$WORK/t4"; mkrepo "$R4"
mkdir -p "$R4/docs"
cat >"$R4/docs/notes.md" <<'MD'
notes
MD
git -C "$R4" add -A && git -C "$R4" commit -q -m base
BASE4="$(git -C "$R4" rev-parse HEAD)"
cat >>"$R4/docs/notes.md" <<'MD'
more notes referencing SAIL_UNRELATED just as prose
MD
git -C "$R4" add -A && git -C "$R4" commit -q -m change

python3 - "$R4" "$BASE4" <<'PY' || fail "T4: unrelated diff must yield no findings"
import sys
sys.path.insert(0, ".")
from sail.docs_currency import find_docs_currency_findings
repo, base = sys.argv[1], sys.argv[2]
found = find_docs_currency_findings(repo, base)
assert found == [], found
PY

# ---------------------------------------------------------------------------
# T5: new command flag added to commands/sail.md with no other doc surface touched -> block.
# ---------------------------------------------------------------------------
R5="$WORK/t5"; mkrepo "$R5"
mkdir -p "$R5/commands"
cat >"$R5/commands/sail.md" <<'MD'
Usage: /sail <issue>
MD
git -C "$R5" add -A && git -C "$R5" commit -q -m base
BASE5="$(git -C "$R5" rev-parse HEAD)"
cat >"$R5/commands/sail.md" <<'MD'
Usage: /sail <issue> --newflag
MD
git -C "$R5" add -A && git -C "$R5" commit -q -m change

python3 - "$R5" "$BASE5" <<'PY' || fail "T5: undocumented new flag must block"
import sys
sys.path.insert(0, ".")
from sail.docs_currency import find_docs_currency_findings
repo, base = sys.argv[1], sys.argv[2]
found = find_docs_currency_findings(repo, base)
assert any(f["kind"] == "flag" and f["token"] == "--newflag" for f in found), found
PY

# ---------------------------------------------------------------------------
# T6: ambiguous CLI reference (non-literal / already-common tool) -> advisory only, no block.
# ---------------------------------------------------------------------------
R6="$WORK/t6"; mkrepo "$R6"
cat >"$R6/mod.py" <<'PY'
import subprocess

def f(interpreter):
    return subprocess.run([interpreter, "-c", "print(1)"])
PY
git -C "$R6" add -A && git -C "$R6" commit -q -m base
BASE6="$(git -C "$R6" rev-parse HEAD)"
cat >"$R6/mod.py" <<'PY'
import subprocess

def f(interpreter):
    subprocess.run(["git", "status"])
    return subprocess.run([interpreter, "-c", "print(1)"])
PY
git -C "$R6" add -A && git -C "$R6" commit -q -m change

python3 - "$R6" "$BASE6" <<'PY' || fail "T6: ambiguous/variable CLI ref must not block"
import sys
sys.path.insert(0, ".")
from sail.docs_currency import find_docs_currency_findings
repo, base = sys.argv[1], sys.argv[2]
found = find_docs_currency_findings(repo, base)
assert any(f["kind"] == "cli" and not f["blocking"] for f in found), found
assert not any(f["kind"] == "cli" and f["blocking"] for f in found), found
PY

# ---------------------------------------------------------------------------
# T7: relocation — a SAIL_* read moved (removed on one line, added on another) is not new.
# ---------------------------------------------------------------------------
R7="$WORK/t7"; mkrepo "$R7"
cat >"$R7/mod.py" <<'PY'
import os


def f():
    return os.environ["SAIL_EXISTING"]
PY
git -C "$R7" add -A && git -C "$R7" commit -q -m base
BASE7="$(git -C "$R7" rev-parse HEAD)"
cat >"$R7/mod.py" <<'PY'
import os


def f():
    value = os.environ["SAIL_EXISTING"]
    return value
PY
git -C "$R7" add -A && git -C "$R7" commit -q -m change

python3 - "$R7" "$BASE7" <<'PY' || fail "T7: relocated env-var read must not be new"
import sys
sys.path.insert(0, ".")
from sail.docs_currency import find_docs_currency_findings
repo, base = sys.argv[1], sys.argv[2]
found = find_docs_currency_findings(repo, base)
assert not any(f["kind"] == "env-var" and f["token"] == "SAIL_EXISTING" for f in found), found
PY

# ---------------------------------------------------------------------------
# T8: runner integration — undocumented env-var read blocks in diff mode.
# ---------------------------------------------------------------------------
RD8="$WORK/t8-run"; mkdir -p "$RD8"
SAIL_CHECKERS=docs-currency python3 -m sail run --target "$R2" --diff "$BASE2" --run-dir "$RD8" --no-review >/dev/null 2>&1 || true
python3 - "$RD8/run-state.json" <<'PY' || fail "T8: runner did not block the undocumented env-var introduction"
import json
import sys
with open(sys.argv[1], encoding="utf-8") as fh:
    state = json.load(fh)
gate = next(g for g in state["gates"] if g["name"] == "docs-currency")
assert gate["status"] == "failed", gate
assert gate["reason"] == "mode=diff new=1", gate
PY

# ---------------------------------------------------------------------------
# T9: a multi-line os.environ.get(...) call (this repo's prevailing formatting style) is still
# detected as a new env-var read, not invisible to a single-line-only regex.
# ---------------------------------------------------------------------------
R9="$WORK/t9"; mkrepo "$R9"
cat >"$R9/mod.py" <<'PY'
import os

def f():
    return None
PY
git -C "$R9" add -A && git -C "$R9" commit -q -m base
BASE9="$(git -C "$R9" rev-parse HEAD)"
cat >"$R9/mod.py" <<'PY'
import os

def f():
    return os.environ.get(
        "SAIL_MULTILINE",
        None,
    )
PY
git -C "$R9" add -A && git -C "$R9" commit -q -m change

python3 - "$R9" "$BASE9" <<'PY' || fail "T9: multi-line env-var read must still block"
import sys
sys.path.insert(0, ".")
from sail.docs_currency import find_docs_currency_findings
repo, base = sys.argv[1], sys.argv[2]
found = find_docs_currency_findings(repo, base)
assert any(f["kind"] == "env-var" and f["token"] == "SAIL_MULTILINE" for f in found), found
PY

# ---------------------------------------------------------------------------
# T10: a flag documented via a markdown bullet / inline-code line (the dominant documentation
# style in commands/*.md) must be recognized as a genuine mention, not rejected outright.
# ---------------------------------------------------------------------------
R10="$WORK/t10"; mkrepo "$R10"
mkdir -p "$R10/commands"
cat >"$R10/commands/sail.md" <<'MD'
Usage: /sail <issue>
MD
git -C "$R10" add -A && git -C "$R10" commit -q -m base
BASE10="$(git -C "$R10" rev-parse HEAD)"
cat >"$R10/commands/sail.md" <<'MD'
Usage: /sail <issue> --newflag

## Flags

- `--newflag` — enables the new documented behavior you can use
MD
git -C "$R10" add -A && git -C "$R10" commit -q -m change

python3 - "$R10" "$BASE10" <<'PY' || fail "T10: bullet-documented flag must not block"
import sys
sys.path.insert(0, ".")
from sail.docs_currency import find_docs_currency_findings
repo, base = sys.argv[1], sys.argv[2]
found = find_docs_currency_findings(repo, base)
assert not any(f["kind"] == "flag" and f["token"] == "--newflag" for f in found), found
PY

# ---------------------------------------------------------------------------
# T11: baseline-awareness — a token already present ANYWHERE in the pre-diff tree (already
# documented, or already read from a sibling file) must not block just because THIS diff's own
# added/removed lines don't happen to show it as pre-existing.
# ---------------------------------------------------------------------------
R11="$WORK/t11"; mkrepo "$R11"
mkdir -p "$R11/sail"
cat >"$R11/sail/existing.py" <<'PY'
import os

def existing_reader():
    return os.environ["SAIL_ALREADY_KNOWN"]
PY
git -C "$R11" add -A && git -C "$R11" commit -q -m base
BASE11="$(git -C "$R11" rev-parse HEAD)"
cat >"$R11/sail/new_caller.py" <<'PY'
import os

def new_caller():
    return os.environ["SAIL_ALREADY_KNOWN"]
PY
git -C "$R11" add -A && git -C "$R11" commit -q -m change

python3 - "$R11" "$BASE11" <<'PY' || fail "T11: baseline-known token in a new call site must not block"
import sys
sys.path.insert(0, ".")
from sail.docs_currency import find_docs_currency_findings
repo, base = sys.argv[1], sys.argv[2]
found = find_docs_currency_findings(repo, base)
assert not any(f["kind"] == "env-var" and f["token"] == "SAIL_ALREADY_KNOWN" for f in found), found
PY

# ---------------------------------------------------------------------------
# T12: a *.sh test script whose heredoc embeds Python fixture source (this repo's own test
# style) must NOT be scanned for env-var reads — only real *.py source is a production read.
# ---------------------------------------------------------------------------
R12="$WORK/t12"; mkrepo "$R12"
cat >"$R12/test_fixture.sh" <<'SH'
#!/usr/bin/env bash
echo hi
SH
git -C "$R12" add -A && git -C "$R12" commit -q -m base
BASE12="$(git -C "$R12" rev-parse HEAD)"
cat >"$R12/test_fixture.sh" <<'SH'
#!/usr/bin/env bash
python3 - <<'PY'
import os
os.environ["SAIL_FIXTURE_ONLY"]
PY
SH
git -C "$R12" add -A && git -C "$R12" commit -q -m change

python3 - "$R12" "$BASE12" <<'PY' || fail "T12: a Python-lookalike heredoc inside a *.sh fixture must not be scanned"
import sys
sys.path.insert(0, ".")
from sail.docs_currency import find_docs_currency_findings
repo, base = sys.argv[1], sys.argv[2]
found = find_docs_currency_findings(repo, base)
assert not any(f["kind"] == "env-var" and f["token"] == "SAIL_FIXTURE_ONLY" for f in found), found
PY

echo "ALL PASS: test_sail_150_docs_currency"
