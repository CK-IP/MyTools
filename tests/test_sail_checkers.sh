#!/usr/bin/env bash
# test_sail_checkers.sh
# Verifies the sail.checkers registry contract for the availability-gated adapters.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_FILE="$(mktemp)"

cleanup() {
  rm -f "$LOG_FILE"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  if [ -s "$LOG_FILE" ]; then
    echo "---- python output ----" >&2
    sed 's/^/  /' "$LOG_FILE" >&2 || true
    echo "-----------------------" >&2
  fi
  exit 1
}

cd "$REPO_ROOT"

if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
import shutil
import sail.checkers as checkers

expected_names = ["ruff", "mypy", "pytest", "bandit", "semgrep", "pip-audit"]
expected_artifacts = {
    "ruff": "ruff.sarif",
    "mypy": "mypy.junit.xml",
    "pytest": "junit.xml",
    "bandit": "bandit.sarif",
    "semgrep": "semgrep.sarif",
    "pip-audit": "pip-audit.json",
}

registry = checkers.build_registry()
names = [checker.name for checker in registry]
if names != expected_names:
    raise SystemExit(f"FAIL: expected registry order {expected_names!r}, got {names!r}")

for checker in registry:
    if checker.artifact != expected_artifacts[checker.name]:
        raise SystemExit(
            "FAIL: "
            f"{checker.name} artifact {checker.artifact!r} != {expected_artifacts[checker.name]!r}"
        )
    expected_available = shutil.which(checker.tool) is not None
    if checker.available() != expected_available:
        raise SystemExit(
            "FAIL: "
            f"expected {checker.name}.available() to equal {expected_available!r}, "
            f"got {checker.available()!r}"
        )
    if checker.classify(0) != "passed":
        raise SystemExit(f"FAIL: expected {checker.name}.classify(0) to return 'passed'")
    if checker.classify(1) != "failed":
        raise SystemExit(f"FAIL: expected {checker.name}.classify(1) to return 'failed'")

print("PASS: sail.checkers registry contract verified")
PY
then
  fail "sail.checkers registry contract failed (expected until sail/checkers.py exists)"
fi

echo "PASS: sail.checkers registry contract verified"

# --- Issue #33: pytest gate scope-correctness + rc classification + reason ---
# Pins the scope/config-honoring behavior: pytest must be scoped to the project's
# configured testpaths (else tests/, else target), and rc=2 (collection/config error)
# and rc=5 (no tests collected) must NOT be treated as blocking failures, with a
# distinguishing reason recorded for the decision log.
if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
import os
import tempfile
import sail.checkers as checkers

registry = {c.name: c for c in checkers.build_registry()}
pytest_chk = registry["pytest"]
ruff_chk = registry["ruff"]

# (1) rc classification — pytest-specific, non-blocking for rc in {2,5}.
cases = {0: "passed", 1: "failed", 2: "skipped", 5: "skipped", 3: "failed", 4: "failed"}
for rc, want in cases.items():
    got = pytest_chk.classify(rc)
    if got != want:
        raise SystemExit(f"FAIL: pytest.classify({rc}) == {got!r}, expected {want!r}")

# Generic checkers stay passed/failed (existing invariant preserved).
if ruff_chk.classify(2) != "failed":
    raise SystemExit("FAIL: non-pytest classify(2) must stay 'failed' (generic invariant)")
if ruff_chk.classify(0) != "passed" or ruff_chk.classify(1) != "failed":
    raise SystemExit("FAIL: non-pytest classify(0/1) invariant broken")

# (2) reason(rc) — distinguishes rc=1 vs rc=2 vs rc=5 for the decision log.
r1 = pytest_chk.reason(1) or ""
r2 = pytest_chk.reason(2) or ""
r5 = pytest_chk.reason(5) or ""
if "test failures" not in r1.lower():
    raise SystemExit(f"FAIL: pytest.reason(1) should mention test failures, got {r1!r}")
if "collection" not in r2.lower() and "config" not in r2.lower():
    raise SystemExit(f"FAIL: pytest.reason(2) should mention collection/config error, got {r2!r}")
if "no test" not in r5.lower():
    raise SystemExit(f"FAIL: pytest.reason(5) should mention no tests collected, got {r5!r}")
if pytest_chk.reason(0) is not None:
    raise SystemExit("FAIL: pytest.reason(0) should be None")
if ruff_chk.reason(2) is not None:
    raise SystemExit("FAIL: non-pytest reason(rc) should be None")

# (2b) cwd(target) — the pytest gate must run from the project root so the project's
#      own test execution model (relative fixture paths, conftest discovery) holds;
#      other checkers receive the target as an argument and run from the default cwd.
with tempfile.TemporaryDirectory() as _t:
    if pytest_chk.cwd(_t) != _t:
        raise SystemExit(f"FAIL: pytest.cwd(target) must be the target, got {pytest_chk.cwd(_t)!r}")
    if ruff_chk.cwd(_t) is not None:
        raise SystemExit(f"FAIL: non-pytest cwd(target) must be None, got {ruff_chk.cwd(_t)!r}")

# (3) build_command scoping — honor configured testpaths; the positional test
#     paths must be the resolved scope (never the whole tree when a config / tests
#     dir exists); pin the target's config via -c + --rootdir.
def build(target):
    return pytest_chk.build_command(target, os.path.join(target, "junit.xml"))

def positionals(cmd):
    out = []
    for tok in cmd[1:]:
        if tok.startswith("-"):
            break
        out.append(tok)
    return out

with tempfile.TemporaryDirectory() as td:
    # Target A: pyproject testpaths=["tests"], plus an out-of-scope engine/ tree.
    a = os.path.join(td, "a")
    os.makedirs(os.path.join(a, "tests"))
    os.makedirs(os.path.join(a, "engine"))
    with open(os.path.join(a, "pyproject.toml"), "w") as fh:
        fh.write('[tool.pytest.ini_options]\ntestpaths = ["tests"]\n')
    cmd = build(a)
    if cmd[0] != "pytest":
        raise SystemExit(f"FAIL: build_command[0] != 'pytest': {cmd!r}")
    if positionals(cmd) != [os.path.join(a, "tests")]:
        raise SystemExit(f"FAIL: positional test paths must be exactly the configured tests/ scope: {cmd!r}")
    if os.path.join(a, "engine") in cmd:
        raise SystemExit(f"FAIL: must NOT include the out-of-scope engine/ tree anywhere: {cmd!r}")
    if "-c" not in cmd or os.path.join(a, "pyproject.toml") not in cmd:
        raise SystemExit(f"FAIL: must pin target config via -c <pyproject.toml>: {cmd!r}")
    if "--rootdir" not in cmd or a not in cmd:
        raise SystemExit(f"FAIL: must pass --rootdir <target>: {cmd!r}")

    # Target B: no config, but a tests/ dir → default to tests/ (positional).
    b = os.path.join(td, "b")
    os.makedirs(os.path.join(b, "tests"))
    cmd_b = build(b)
    if positionals(cmd_b) != [os.path.join(b, "tests")]:
        raise SystemExit(f"FAIL: no-config target with tests/ must scope positionals to tests/: {cmd_b!r}")

    # Target C: no config, no tests/ → fall back to the target itself (positional).
    c = os.path.join(td, "c")
    os.makedirs(c)
    cmd_c = build(c)
    if positionals(cmd_c) != [c]:
        raise SystemExit(f"FAIL: bare target (no config/tests) must fall back to [target] positional: {cmd_c!r}")

    # Target D: pyproject.toml WITHOUT a [tool.pytest.ini_options] section must NOT
    # shadow a later tox.ini that DOES configure pytest (discovery precedence skip).
    d = os.path.join(td, "d")
    os.makedirs(os.path.join(d, "engine_tests"))
    with open(os.path.join(d, "pyproject.toml"), "w") as fh:
        fh.write("[build-system]\nrequires = [\"setuptools\"]\n")
    with open(os.path.join(d, "tox.ini"), "w") as fh:
        fh.write("[pytest]\ntestpaths = engine_tests\n")
    cmd_d = build(d)
    if positionals(cmd_d) != [os.path.join(d, "engine_tests")]:
        raise SystemExit(f"FAIL: a pyproject without [tool.pytest.ini_options] must not shadow tox.ini [pytest]: {cmd_d!r}")
    if "-c" not in cmd_d or os.path.join(d, "tox.ini") not in cmd_d:
        raise SystemExit(f"FAIL: must pin the tox.ini that actually configures pytest: {cmd_d!r}")

    # Target E: multi-line testpaths array in pyproject (the standard pytest-doc form).
    e = os.path.join(td, "e")
    os.makedirs(os.path.join(e, "suite_a"))
    os.makedirs(os.path.join(e, "suite_b"))
    with open(os.path.join(e, "pyproject.toml"), "w") as fh:
        fh.write('[tool.pytest.ini_options]\ntestpaths = [\n    "suite_a",\n    "suite_b",\n]\n')
    cmd_e = build(e)
    if positionals(cmd_e) != [os.path.join(e, "suite_a"), os.path.join(e, "suite_b")]:
        raise SystemExit(f"FAIL: multi-line testpaths array must be honored: {cmd_e!r}")

    # Target F: an EXPLICITLY-configured testpath that does not exist must be passed
    # verbatim (so pytest surfaces the misconfiguration), NOT silently widened to
    # tests/ or the whole target.
    g = os.path.join(td, "f")
    os.makedirs(g)
    with open(os.path.join(g, "pytest.ini"), "w") as fh:
        fh.write("[pytest]\ntestpaths = renamed_suite\n")
    cmd_f = build(g)
    if positionals(cmd_f) != [os.path.join(g, "renamed_suite")]:
        raise SystemExit(f"FAIL: explicitly-configured (even if missing) testpath must be honored verbatim, not widened: {cmd_f!r}")

    # Target G: EXPLICIT empty testpaths in pyproject (testpaths = []) must be HONORED —
    # NO path positionals (let pytest collect per its own config) — NOT widened back to
    # tests/ even though a tests/ dir exists (#35).
    te = os.path.join(td, "te")
    os.makedirs(os.path.join(te, "tests"))
    with open(os.path.join(te, "pyproject.toml"), "w") as fh:
        fh.write('[tool.pytest.ini_options]\ntestpaths = []\n')
    cmd_te = build(te)
    if positionals(cmd_te) != []:
        raise SystemExit(f"FAIL: explicit testpaths=[] must yield NO path positionals, not a tests/ fallback: {cmd_te!r}")
    if os.path.join(te, "tests") in cmd_te:
        raise SystemExit(f"FAIL: explicit empty testpaths must not fall back to tests/: {cmd_te!r}")

    # Target H: EXPLICIT empty testpaths in pytest.ini (key present, empty value) → no
    # positionals (#35).
    ti = os.path.join(td, "ti")
    os.makedirs(os.path.join(ti, "tests"))
    with open(os.path.join(ti, "pytest.ini"), "w") as fh:
        fh.write("[pytest]\ntestpaths =\n")
    cmd_ti = build(ti)
    if positionals(cmd_ti) != []:
        raise SystemExit(f"FAIL: pytest.ini with an empty testpaths value must yield NO path positionals: {cmd_ti!r}")

    # Target I: pytest section present but NO testpaths KEY → fall back to tests/ (the
    # absent-key case must stay distinct from explicit-empty) (#35).
    ta = os.path.join(td, "ta")
    os.makedirs(os.path.join(ta, "tests"))
    with open(os.path.join(ta, "pyproject.toml"), "w") as fh:
        fh.write('[tool.pytest.ini_options]\naddopts = "-q"\n')
    cmd_ta = build(ta)
    if positionals(cmd_ta) != [os.path.join(ta, "tests")]:
        raise SystemExit(f"FAIL: section present but no testpaths key must fall back to tests/: {cmd_ta!r}")

# (4) bandit gate must exclude nested worktree / sail-internal dirs (#44). bandit -r does
#     NOT honor .gitignore, so without -x it scans .claude/worktrees and the .sail diff
#     baseline checkout → spurious "new" findings vs the clean baseline → false block.
bandit_chk = registry["bandit"]
with tempfile.TemporaryDirectory() as _bt:
    bcmd = bandit_chk.build_command(_bt, os.path.join(_bt, "bandit.sarif"))
    if "-x" not in bcmd and "--exclude" not in bcmd:
        raise SystemExit(f"FAIL: bandit build_command must pass -x/--exclude: {bcmd!r}")
    _xval = bcmd[(bcmd.index("-x") if "-x" in bcmd else bcmd.index("--exclude")) + 1]
    if ".claude" not in _xval:
        raise SystemExit(f"FAIL: bandit --exclude must include .claude (nested worktrees), got {_xval!r}")
    # RT-1: must NOT exclude .sail — the diff baseline worktree lives under .sail/runs/.../
    # baseline-src, so excluding it would empty the baseline scan and reintroduce the false block.
    if ".sail" in _xval:
        raise SystemExit(f"FAIL: bandit --exclude must NOT include .sail (empties the diff baseline): {_xval!r}")

print("PASS: sail.checkers pytest scope/classification/reason (#33, #35) + bandit exclude (#44) verified")
PY
then
  fail "sail.checkers pytest scope-correctness (#33) failed"
fi

echo "PASS: sail.checkers pytest scope-correctness (#33) verified"

# (4e) end-to-end: bandit gate must not flag files inside nested .claude/ or .sail/ checkouts
#      (#44). Guarded on bandit availability — hermetic skip where the tool is absent.
if command -v bandit >/dev/null 2>&1; then
  if ! python3 - << 'PY'
import json, os, subprocess, tempfile
import sail.checkers as checkers
bandit_chk = {c.name: c for c in checkers.build_registry()}["bandit"]
FLAG = "import subprocess\nsubprocess.Popen('id', shell=True)\n"  # B602: shell=True
def scan(target):
    out = os.path.join(target, "bandit.sarif")
    subprocess.run(bandit_chk.build_command(target, out), capture_output=True, text=True)
    results = json.load(open(out)).get("runs", [{}])[0].get("results", [])
    return [r.get("locations", [{}])[0].get("physicalLocation", {}).get("artifactLocation", {}).get("uri", "") for r in results]

# (a) nested .claude/worktrees is excluded; real-tree is still scanned.
with tempfile.TemporaryDirectory() as td:
    open(os.path.join(td, "bad.py"), "w").write(FLAG)                       # real-tree (must flag)
    os.makedirs(os.path.join(td, ".claude/worktrees/wt"))                   # nested worktree (must NOT flag)
    open(os.path.join(td, ".claude/worktrees/wt/bad.py"), "w").write(FLAG)
    uris = scan(td)
    if not [u for u in uris if "/.claude/" not in u]:
        raise SystemExit(f"FAIL: bandit must still flag the real-tree bad.py; uris={uris}")
    if [u for u in uris if "/.claude/" in u]:
        raise SystemExit(f"FAIL: bandit must NOT flag files under nested .claude/: {uris}")

# (b) RT-1 regression: the diff baseline worktree lives at <run_dir>/baseline-src under .sail/,
# so a scan ROOTED inside a .sail/ path must STILL find its files (excluding .sail would empty
# the baseline scan → all current findings look new → false block).
with tempfile.TemporaryDirectory() as td:
    bsrc = os.path.join(td, ".sail", "runs", "r", "baseline-src")
    os.makedirs(bsrc)
    open(os.path.join(bsrc, "bad.py"), "w").write(FLAG)
    if not scan(bsrc):
        raise SystemExit("FAIL: bandit must still scan a baseline tree rooted under .sail/ (RT-1)")
print("PASS: bandit excludes nested .claude/ but still scans baseline trees under .sail/ (#44, RT-1)")
PY
  then
    fail "sail.checkers bandit nested-exclusion (#44) failed"
  fi
else
  echo "SKIP: bandit not installed — #44 end-to-end exclusion check skipped"
fi
