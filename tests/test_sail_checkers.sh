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
# Hermetic (.ship/domain.md #102): a real shell exports SAIL_* codex knobs (settings.json);
# clear them so each subtest controls its own backend (subtests set theirs via command prefix).
unset "${!SAIL_@}"

if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
import shutil
import sail.checkers as checkers

expected_names = ["ruff", "mypy", "pytest", "bandit", "semgrep", "pip-audit", "shellcheck", "gitleaks", "npm-audit", "diff-coverage"]
expected_artifacts = {
    "ruff": "ruff.sarif",
    "mypy": "mypy.junit.xml",
    "pytest": "junit.xml",
    "bandit": "bandit.sarif",
    "semgrep": "semgrep.sarif",
    "pip-audit": "pip-audit.json",
    "shellcheck": "shellcheck.json",
    "gitleaks": "gitleaks.sarif",
    "npm-audit": "npm-audit.json",
    "diff-coverage": "diff-coverage.json",
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
    # #48 Step 1: stdout_artifact field defaults False for every file-based-output checker.
    # shellcheck (#48 Step 2) emits findings to stdout and opts in explicitly (asserted below);
    # gitleaks (#48 Step 3) writes SARIF to a file, so it stays False (asserted below).
    # shellcheck (#48) and npm-audit (#52) capture stdout (tools with no file flag / the
    # no-Node sentinel); every other checker writes its own artifact file (default False).
    if checker.name not in ("shellcheck", "npm-audit") and checker.stdout_artifact is not False:
        raise SystemExit(
            f"FAIL: {checker.name}.stdout_artifact must default False, got {checker.stdout_artifact!r}"
        )

# #48 Step 2: shellcheck registry contract — present, blocking, stdout-captured artifact.
shellcheck_chk = {c.name: c for c in registry}.get("shellcheck")
if shellcheck_chk is None:
    raise SystemExit("FAIL: shellcheck checker must be registered (#48 Step 2)")
if shellcheck_chk.tool != "shellcheck":
    raise SystemExit(f"FAIL: shellcheck.tool must be 'shellcheck', got {shellcheck_chk.tool!r}")
if shellcheck_chk.artifact != "shellcheck.json":
    raise SystemExit(f"FAIL: shellcheck.artifact must be 'shellcheck.json', got {shellcheck_chk.artifact!r}")
if shellcheck_chk.blocking is not True:
    raise SystemExit(f"FAIL: shellcheck must be blocking, got {shellcheck_chk.blocking!r}")
if shellcheck_chk.stdout_artifact is not True:
    raise SystemExit(f"FAIL: shellcheck.stdout_artifact must be True, got {shellcheck_chk.stdout_artifact!r}")

# #48 Step 3: gitleaks registry contract — present, blocking, file-based SARIF (NOT stdout).
gitleaks_chk = {c.name: c for c in registry}.get("gitleaks")
if gitleaks_chk is None:
    raise SystemExit("FAIL: gitleaks checker must be registered (#48 Step 3)")
if gitleaks_chk.tool != "gitleaks":
    raise SystemExit(f"FAIL: gitleaks.tool must be 'gitleaks', got {gitleaks_chk.tool!r}")
if gitleaks_chk.artifact != "gitleaks.sarif":
    raise SystemExit(f"FAIL: gitleaks.artifact must be 'gitleaks.sarif', got {gitleaks_chk.artifact!r}")
if gitleaks_chk.blocking is not True:
    raise SystemExit(f"FAIL: gitleaks must be blocking, got {gitleaks_chk.blocking!r}")
if gitleaks_chk.stdout_artifact is not False:
    raise SystemExit(f"FAIL: gitleaks.stdout_artifact must be False (file-based), got {gitleaks_chk.stdout_artifact!r}")

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

# --- Issue #51: SAIL_CHECKERS allowlist restricts build_registry (order preserved, unknown
# names ignored, unset/empty = all eight). Lets fast hermetic test runs skip slow scanners. ---
if ! SAIL_CHECKERS="pytest,ruff" python3 - <<'PY' >"$LOG_FILE" 2>&1
import os
import sail.checkers as checkers

# allowlist restricts AND preserves registry order (not allowlist order)
got = [c.name for c in checkers.build_registry()]
if got != ["ruff", "pytest"]:
    raise SystemExit(f"FAIL: allowlist 'pytest,ruff' should restrict to registry-order ['ruff','pytest'], got {got!r}")

# unknown names are ignored, never crash
os.environ["SAIL_CHECKERS"] = "ruff,bogus,pytest"
got = [c.name for c in checkers.build_registry()]
if got != ["ruff", "pytest"]:
    raise SystemExit(f"FAIL: unknown allowlist names must be ignored, got {got!r}")

# surrounding whitespace tolerated
os.environ["SAIL_CHECKERS"] = " ruff , pytest "
got = [c.name for c in checkers.build_registry()]
if got != ["ruff", "pytest"]:
    raise SystemExit(f"FAIL: whitespace around allowlist names must be tolerated, got {got!r}")

# empty string = the full registry (backward compatible)
os.environ["SAIL_CHECKERS"] = ""
if len(checkers.build_registry()) != 10:
    raise SystemExit("FAIL: empty SAIL_CHECKERS must yield the full registry")

# whitespace-only = the full registry (treated as empty)
os.environ["SAIL_CHECKERS"] = "   "
if len(checkers.build_registry()) != 10:
    raise SystemExit("FAIL: whitespace-only SAIL_CHECKERS must yield the full registry")

# unset = the full registry in order (#52 adds npm-audit + diff-coverage after gitleaks)
del os.environ["SAIL_CHECKERS"]
if [c.name for c in checkers.build_registry()] != ["ruff", "mypy", "pytest", "bandit", "semgrep", "pip-audit", "shellcheck", "gitleaks", "npm-audit", "diff-coverage"]:
    raise SystemExit("FAIL: unset SAIL_CHECKERS must yield the full registry in order")

print("PASS: SAIL_CHECKERS allowlist restricts the registry; unset/empty = full registry (#51, #52)")
PY
then
  fail "sail.checkers SAIL_CHECKERS allowlist (#51) failed"
fi

echo "PASS: sail.checkers SAIL_CHECKERS allowlist (#51) verified"

# --- Issue #48 Step 2: shellcheck *.sh discovery (excl. nested .claude worktrees) + no-files no-op ---
if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
import os, tempfile
import sail.checkers as checkers

shellcheck_chk = {c.name: c for c in checkers.build_registry()}["shellcheck"]

# (a) discovery: a.sh under target is included; a *.sh under a nested .claude/ worktree is excluded.
with tempfile.TemporaryDirectory() as td:
    open(os.path.join(td, "a.sh"), "w").write("#!/bin/sh\necho hi\n")
    os.makedirs(os.path.join(td, ".claude", "worktrees", "x"))
    open(os.path.join(td, ".claude", "worktrees", "x", "b.sh"), "w").write("#!/bin/sh\necho hi\n")
    cmd = shellcheck_chk.build_command(td, os.path.join(td, "shellcheck.json"))
    if cmd[:3] != ["shellcheck", "-f", "json"]:
        raise SystemExit(f"FAIL: shellcheck command must start with shellcheck -f json: {cmd!r}")
    if os.path.join(td, "a.sh") not in cmd:
        raise SystemExit(f"FAIL: shellcheck must discover a.sh under target: {cmd!r}")
    if any("/.claude/" in tok for tok in cmd):
        raise SystemExit(f"FAIL: shellcheck must EXCLUDE *.sh under nested .claude/: {cmd!r}")

# (a2) .sail is NOT excluded — the diff baseline worktree lives under .sail/runs/.../baseline-src.
with tempfile.TemporaryDirectory() as td:
    bsrc = os.path.join(td, ".sail", "runs", "r", "baseline-src")
    os.makedirs(bsrc)
    open(os.path.join(bsrc, "c.sh"), "w").write("#!/bin/sh\necho hi\n")
    cmd = shellcheck_chk.build_command(td, os.path.join(td, "shellcheck.json"))
    if os.path.join(bsrc, "c.sh") not in cmd:
        raise SystemExit(f"FAIL: shellcheck must NOT exclude .sail trees (diff baseline): {cmd!r}")

# (b) no *.sh files → portable no-op emitting a valid empty JSON array (never zero-byte; RT-8).
with tempfile.TemporaryDirectory() as td:
    open(os.path.join(td, "notshell.py"), "w").write("x = 1\n")
    cmd = shellcheck_chk.build_command(td, os.path.join(td, "shellcheck.json"))
    if cmd != ["printf", "[]"]:
        raise SystemExit(f"FAIL: no *.sh files must yield the ['printf','[]'] no-op, got {cmd!r}")

print("PASS: sail.checkers shellcheck discovery + no-files no-op (#48 Step 2)")
PY
then
  fail "sail.checkers shellcheck discovery (#48 Step 2) failed"
fi

echo "PASS: sail.checkers shellcheck discovery (#48 Step 2) verified"

# --- Issue #48 RT-1: discovery must NOT exclude based on the target's OWN ancestor path ---
# The canonical sail invocation runs `--target .` from a cwd like
# .../.claude/worktrees/ship-NN/, so the target's absolute path itself contains /.claude/.
# Exclusion must be RELATIVE to the target: prune only .claude segments BELOW the target,
# never the target's ancestors — else every dirpath is excluded → silent no-op gate.
if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
import os, tempfile
import sail.checkers as checkers

base = tempfile.mkdtemp()
root = os.path.join(base, ".claude", "worktrees", "ship-x")
os.makedirs(root)
# a.sh directly under the target root (whose ancestor path contains /.claude/).
open(os.path.join(root, "a.sh"), "w").write("#!/bin/sh\necho hi\n")
# c.sh in a normal subdir below the target.
os.makedirs(os.path.join(root, "sub"))
open(os.path.join(root, "sub", "c.sh"), "w").write("#!/bin/sh\necho hi\n")
# b.sh under a nested .claude worktree BELOW the target — must be excluded.
os.makedirs(os.path.join(root, ".claude", "worktrees", "y"))
open(os.path.join(root, ".claude", "worktrees", "y", "b.sh"), "w").write("#!/bin/sh\necho hi\n")

found = checkers._discover_sh(root)
if os.path.join(root, "a.sh") not in found:
    raise SystemExit(f"FAIL: must INCLUDE a.sh under target whose ancestor path has /.claude/: {found!r}")
if os.path.join(root, "sub", "c.sh") not in found:
    raise SystemExit(f"FAIL: must INCLUDE c.sh in a subdir below the target: {found!r}")
if os.path.join(root, ".claude", "worktrees", "y", "b.sh") in found:
    raise SystemExit(f"FAIL: must EXCLUDE b.sh under a nested .claude worktree below target: {found!r}")

print("PASS: sail.checkers _discover_sh excludes only .claude BELOW target, not ancestors (#48 RT-1)")
PY
then
  fail "sail.checkers _discover_sh ancestor-path discovery (#48 RT-1) failed"
fi

echo "PASS: sail.checkers _discover_sh ancestor-path discovery (#48 RT-1) verified"

# --- Issue #48 Step 2: e2e — real shellcheck on a .sh with a known SC code flags it.
#     Availability-gated: skipped cleanly where shellcheck is absent (this host). ---
if command -v shellcheck >/dev/null 2>&1; then
  if ! python3 - <<'PY'
import json, os, subprocess, tempfile
import sail.checkers as checkers
shellcheck_chk = {c.name: c for c in checkers.build_registry()}["shellcheck"]
with tempfile.TemporaryDirectory() as td:
    # Unquoted positional $1 → SC2086, a default shellcheck finding. (NOTE: `var=x; echo $var`
    # does NOT trigger SC2086 — shellcheck knows a single-word literal is splitting-safe; a
    # positional/unconstrained expansion is needed for a guaranteed finding. See .ship/domain.md.)
    open(os.path.join(td, "bad.sh"), "w").write("#!/bin/sh\nls $1\n")
    out = os.path.join(td, "shellcheck.json")
    res = subprocess.run(shellcheck_chk.build_command(td, out), capture_output=True, text=True)
    # shellcheck -f json writes findings to STDOUT (no file flag); the runner persists it via
    # stdout_artifact. Here we read stdout directly to verify the command shape really flags SC2086.
    findings = json.loads(res.stdout or "[]")
    codes = {f.get("code") for f in findings}
    if 2086 not in codes:
        raise SystemExit(f"FAIL: shellcheck must flag SC2086 on unquoted $var, got codes={codes}")
print("PASS: shellcheck e2e flags SC2086 (#48 Step 2)")
PY
  then
    fail "sail.checkers shellcheck e2e (#48 Step 2) failed"
  fi
else
  echo "SKIP: shellcheck not installed — #48 Step 2 e2e check skipped"
fi

# --- Issue #48 Step 3: gitleaks build_command shape (hermetic — gitleaks NOT required) ---
if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
import os, tempfile
import sail.checkers as checkers

gitleaks_chk = {c.name: c for c in checkers.build_registry()}["gitleaks"]

with tempfile.TemporaryDirectory() as td:
    artifact = os.path.join(td, "gitleaks.sarif")
    cmd = gitleaks_chk.build_command(td, artifact)
    # Must invoke: gitleaks dir <target> ...
    if cmd[:3] != ["gitleaks", "dir", td]:
        raise SystemExit(f"FAIL: gitleaks command must start with 'gitleaks dir <target>': {cmd!r}")
    # SARIF report to the artifact path.
    if "--report-format" not in cmd or cmd[cmd.index("--report-format") + 1] != "sarif":
        raise SystemExit(f"FAIL: gitleaks must pass --report-format sarif: {cmd!r}")
    if "--report-path" not in cmd or cmd[cmd.index("--report-path") + 1] != artifact:
        raise SystemExit(f"FAIL: gitleaks must pass --report-path <artifact>: {cmd!r}")
    # --exit-code 0 so a leak still writes SARIF; the diff-delta (not rc) decides blocking.
    if "--exit-code" not in cmd or cmd[cmd.index("--exit-code") + 1] != "0":
        raise SystemExit(f"FAIL: gitleaks must pass --exit-code 0 (SARIF written even on leak): {cmd!r}")
    if "--no-banner" not in cmd:
        raise SystemExit(f"FAIL: gitleaks must pass --no-banner: {cmd!r}")
    # --config points at the shipped sail/gitleaks-exclude.toml (resolved from the module).
    if "--config" not in cmd:
        raise SystemExit(f"FAIL: gitleaks must pass --config <toml>: {cmd!r}")
    cfg = cmd[cmd.index("--config") + 1]
    if not cfg.endswith(os.path.join("sail", "gitleaks-exclude.toml")):
        raise SystemExit(f"FAIL: gitleaks --config must point at sail/gitleaks-exclude.toml, got {cfg!r}")
    if not os.path.isfile(cfg):
        raise SystemExit(f"FAIL: gitleaks --config TOML must exist on disk: {cfg!r}")

print("PASS: sail.checkers gitleaks build_command shape (#48 Step 3)")
PY
then
  fail "sail.checkers gitleaks build_command (#48 Step 3) failed"
fi

echo "PASS: sail.checkers gitleaks build_command (#48 Step 3) verified"

# --- Issue #48 Step 3: gitleaks-exclude.toml content (RT-1/RT-2 CRITICAL — parse with regex,
#     NOT tomllib/tomli; neither is available on the Python 3.9 host). ---
if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
import os, re
import sail.checkers as checkers

toml_path = os.path.join(os.path.dirname(checkers.__file__), "gitleaks-exclude.toml")
if not os.path.isfile(toml_path):
    raise SystemExit(f"FAIL: shipped config missing: {toml_path}")
with open(toml_path, encoding="utf-8") as fh:
    text = fh.read()

# (a) RT-1 CRITICAL: gitleaks --config REPLACES the default ruleset. Without
#     [extend] useDefault = true the gate detects NOTHING (silent no-op).
if not re.search(r"(?m)^\s*useDefault\s*=\s*true", text):
    raise SystemExit("FAIL: gitleaks-exclude.toml MUST set useDefault = true (else detection disabled)")

# (b) RT-2: the allowlist path regex (^|/)\.claude/ must match nested .claude worktrees but
#     NOT the .sail diff baseline nor ordinary src paths. Apply the exact regex via Python re.
allow_re = re.compile(r"(^|/)\.claude/")
if not allow_re.search("src/.claude/worktrees/x/f.py"):
    raise SystemExit("FAIL: allowlist regex must MATCH a nested src/.claude/... path")
if not allow_re.search(".claude/x.py"):
    raise SystemExit("FAIL: allowlist regex must MATCH a top-level .claude/ path")
if allow_re.search(".sail/runs/y/f.py"):
    raise SystemExit("FAIL: allowlist regex must NOT match .sail (diff baseline must be scanned)")
if allow_re.search("src/app.py"):
    raise SystemExit("FAIL: allowlist regex must NOT match ordinary src/ paths")

# The literal anchored regex must actually be present in the shipped TOML's allowlist.
if r"(^|/)\.claude/" not in text:
    raise SystemExit(r"FAIL: gitleaks-exclude.toml must contain the anchored regex (^|/)\.claude/")

print("PASS: sail gitleaks-exclude.toml content — useDefault=true + anchored .claude allowlist (#48 Step 3, RT-1/RT-2)")
PY
then
  fail "sail gitleaks-exclude.toml content (#48 Step 3) failed"
fi

echo "PASS: sail gitleaks-exclude.toml content (#48 Step 3) verified"

# --- Issue #48 Step 3: e2e — real gitleaks on a planted secret in dir mode flags it; a secret
#     under a nested .claude/worktrees/* path is excluded. Availability-gated: skipped on this host. ---
if command -v gitleaks >/dev/null 2>&1; then
  if ! python3 - <<'PY'
import json, os, subprocess, tempfile
import sail.checkers as checkers
gitleaks_chk = {c.name: c for c in checkers.build_registry()}["gitleaks"]
# Use a non-example secret: gitleaks allowlists the canonical AWS docs key AKIAIOSFODNN7EXAMPLE
# as a known fake, so it is NOT flagged. A slack-bot-token has high entropy and IS detected by the
# default ruleset (verified live, gitleaks 8.30). See .ship/domain.md.
# NOTE: the token is ASSEMBLED from fragments so the contiguous literal never appears in this source
# file — otherwise GitHub push-protection (secret scanning) blocks the push. gitleaks scans the
# temp fixture written at runtime, which holds the full concatenated token.
_TOK = "xoxb-1234567890-" + "1234567890123-AbCdEfGhIjKlMnOpQrStUvWx"
SECRET = 'slack_token = "' + _TOK + '"\n'
def scan(target):
    out = os.path.join(target, "gitleaks.sarif")
    subprocess.run(gitleaks_chk.build_command(target, out), capture_output=True, text=True)
    if not os.path.isfile(out):
        return []
    doc = json.load(open(out))
    uris = []
    for run in doc.get("runs", []):
        for r in run.get("results", []):
            for loc in r.get("locations", []):
                uris.append(loc.get("physicalLocation", {}).get("artifactLocation", {}).get("uri", ""))
    return uris
with tempfile.TemporaryDirectory() as td:
    open(os.path.join(td, "creds.txt"), "w").write(SECRET)        # real tree (must flag)
    os.makedirs(os.path.join(td, ".claude", "worktrees", "wt"))   # nested worktree (must NOT flag)
    open(os.path.join(td, ".claude", "worktrees", "wt", "creds.txt"), "w").write(SECRET)
    uris = scan(td)
    if not [u for u in uris if "/.claude/" not in u]:
        raise SystemExit(f"FAIL: gitleaks must flag the real-tree secret; uris={uris}")
    if [u for u in uris if "/.claude/" in u]:
        raise SystemExit(f"FAIL: gitleaks must EXCLUDE secrets under nested .claude/: {uris}")
print("PASS: gitleaks e2e flags real secret, excludes nested .claude/ (#48 Step 3)")
PY
  then
    fail "sail.checkers gitleaks e2e (#48 Step 3) failed"
  fi
else
  echo "SKIP: gitleaks not installed — #48 Step 3 e2e check skipped"
fi
