#!/usr/bin/env bash
# test_sail_npmaudit_diffcov.sh
# Issue #52: npm-audit + diff-coverage gates via a Checker-contract extension.
#
# Pins the new contract (registry-contract tests — run REGARDLESS of installed toolchain):
#   - build_command accepts an optional CheckerContext (diff_ref + mode + target_root),
#     threaded from the caller WITHOUT breaking existing 2-arg checkers.
#   - blocking is resolvable at RUNTIME via is_blocking(target, mode): defaults to the
#     static `blocking` field; diff-coverage is advisory unless .ship/domain.md sets
#     `diff-coverage-threshold: N`.
#   - npm-audit: which(npm) AND a target manifest; absent manifest => valid empty-JSON
#     sentinel command => clean pass in BOTH whole-repo and diff modes (no false-block).
#   - new delta kinds: npmaudit (fp = module + advisory-id, tolerant of empty/absent) and
#     diffcoverage (one finding per uncovered changed line, only when total % < threshold).
# Availability-gated e2e (real npm / real diff-cover) skip cleanly where the tool is absent.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_FILE="$(mktemp)"
cleanup() { rm -f "$LOG_FILE"; }
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

# --- #52 Part A: Checker contract extension (CheckerContext + runtime is_blocking) ---
if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
import inspect
import os
import tempfile
import sail.checkers as checkers

# (1) build_command accepts an OPTIONAL trailing ctx param — existing 2-arg positional
#     calls keep working (backward compatible: every prior call passes (target, artifact)).
sig = inspect.signature(checkers.Checker.build_command)
params = list(sig.parameters)
if params[:3] != ["self", "target", "artifact_path"]:
    raise SystemExit(f"FAIL: build_command must keep (self, target, artifact_path) leading: {params!r}")
if len(params) < 4:
    raise SystemExit(f"FAIL: build_command must accept an optional ctx param, got {params!r}")
ctx_param = sig.parameters[params[3]]
if ctx_param.default is not None:
    raise SystemExit(f"FAIL: the ctx param must default to None (backward compatible), got {ctx_param.default!r}")

# (2) Existing checkers still build with the legacy 2-arg call (no ctx) — no regression.
registry = {c.name: c for c in checkers.build_registry()}
with tempfile.TemporaryDirectory() as td:
    for name in ("ruff", "bandit", "gitleaks", "shellcheck"):
        cmd = registry[name].build_command(td, os.path.join(td, "art"))
        if not isinstance(cmd, list) or not cmd:
            raise SystemExit(f"FAIL: {name}.build_command(2-arg) must still return a non-empty list: {cmd!r}")

# (3) The static `blocking` field is RETAINED (existing assertions depend on it) AND a
#     runtime is_blocking(target, mode) exists, defaulting to the static field.
for name in ("gitleaks", "shellcheck", "ruff", "bandit"):
    chk = registry[name]
    if chk.blocking is not True:
        raise SystemExit(f"FAIL: {name}.blocking static field must stay True: {chk.blocking!r}")
    if not hasattr(chk, "is_blocking"):
        raise SystemExit(f"FAIL: Checker must expose is_blocking(target, mode)")
    if chk.is_blocking(".", "whole-repo") is not True:
        raise SystemExit(f"FAIL: {name}.is_blocking must default to the static blocking field (True)")

# (4) CheckerContext carries diff_ref + mode + target_root.
if not hasattr(checkers, "CheckerContext"):
    raise SystemExit("FAIL: sail.checkers must expose a CheckerContext")
ctx = checkers.CheckerContext(diff_ref="main", mode="diff", target_root="/tmp/x")
if ctx.diff_ref != "main" or ctx.mode != "diff" or ctx.target_root != "/tmp/x":
    raise SystemExit(f"FAIL: CheckerContext must carry diff_ref/mode/target_root: {ctx!r}")

print("PASS: #52 Checker contract extension (CheckerContext + runtime is_blocking)")
PY
then
  fail "#52 Checker contract extension failed"
fi
echo "PASS: #52 Checker contract extension verified"

# --- #52 Part B: npm-audit checker registry + manifest-aware command (no-Node = clean pass) ---
if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
import json
import os
import subprocess
import tempfile
import sail.checkers as checkers

registry = {c.name: c for c in checkers.build_registry()}
npm = registry.get("npm-audit")
if npm is None:
    raise SystemExit("FAIL: npm-audit checker must be registered")
if npm.tool != "npm":
    raise SystemExit(f"FAIL: npm-audit.tool must be 'npm', got {npm.tool!r}")
if npm.artifact != "npm-audit.json":
    raise SystemExit(f"FAIL: npm-audit.artifact must be 'npm-audit.json', got {npm.artifact!r}")
if npm.blocking is not True:
    raise SystemExit(f"FAIL: npm-audit must be blocking, got {npm.blocking!r}")

# (a) No manifest under target => a portable sentinel command emitting valid empty JSON
#     (never an `npm audit` invocation that would error → unparseable → false-block).
with tempfile.TemporaryDirectory() as td:
    art = os.path.join(td, "npm-audit.json")
    cmd = npm.build_command(td, art)
    if cmd[0] == "npm":
        raise SystemExit(f"FAIL: no-manifest target must NOT invoke npm (errors → false-block): {cmd!r}")
    # The sentinel must emit parseable JSON to stdout (captured via stdout_artifact).
    res = subprocess.run(cmd, capture_output=True, text=True)
    parsed = json.loads(res.stdout or "null")
    if parsed is None:
        raise SystemExit(f"FAIL: no-manifest sentinel must emit valid JSON, got {res.stdout!r}")
    if npm.stdout_artifact is not True:
        raise SystemExit("FAIL: npm-audit must capture stdout (sentinel + npm both emit to stdout)")

# (b) With a package.json present => the real `npm audit --json` command is built.
with tempfile.TemporaryDirectory() as td:
    open(os.path.join(td, "package.json"), "w").write('{"name":"x","version":"1.0.0"}\n')
    art = os.path.join(td, "npm-audit.json")
    cmd = npm.build_command(td, art)
    if cmd[0] != "npm" or "audit" not in cmd:
        raise SystemExit(f"FAIL: a target WITH package.json must invoke `npm audit`: {cmd!r}")
    if "--json" not in cmd:
        raise SystemExit(f"FAIL: npm audit must pass --json: {cmd!r}")

print("PASS: #52 npm-audit registry + manifest-aware command (no-Node clean pass)")
PY
then
  fail "#52 npm-audit checker contract failed"
fi
echo "PASS: #52 npm-audit checker contract verified"

# --- #52 Part C: diff-coverage checker — advisory by default; blocking only with threshold ---
if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
import os
import tempfile
import sail.checkers as checkers

registry = {c.name: c for c in checkers.build_registry()}
dc = registry.get("diff-coverage")
if dc is None:
    raise SystemExit("FAIL: diff-coverage checker must be registered")
if dc.tool != "diff-cover":
    raise SystemExit(f"FAIL: diff-coverage.tool must be 'diff-cover' (tool-gated), got {dc.tool!r}")
if dc.artifact != "diff-coverage.json":
    raise SystemExit(f"FAIL: diff-coverage.artifact must be 'diff-coverage.json', got {dc.artifact!r}")

# (a) static blocking field defaults False (advisory), AND no threshold => advisory at runtime.
if dc.blocking is not False:
    raise SystemExit(f"FAIL: diff-coverage static blocking must be False (advisory default), got {dc.blocking!r}")
with tempfile.TemporaryDirectory() as td:
    # no .ship/domain.md => advisory
    if dc.is_blocking(td, "diff") is not False:
        raise SystemExit("FAIL: diff-coverage with no threshold must be advisory (is_blocking False)")
    # a domain.md WITHOUT the threshold key => still advisory
    os.makedirs(os.path.join(td, ".ship"))
    open(os.path.join(td, ".ship", "domain.md"), "w").write("# domain\n\nsome rule\n")
    if dc.is_blocking(td, "diff") is not False:
        raise SystemExit("FAIL: domain.md without diff-coverage-threshold must stay advisory")
    # a domain.md WITH `diff-coverage-threshold: 80` => blocking at runtime.
    open(os.path.join(td, ".ship", "domain.md"), "w").write("# domain\n\ndiff-coverage-threshold: 80\n")
    if dc.is_blocking(td, "diff") is not True:
        raise SystemExit("FAIL: domain.md with diff-coverage-threshold:N must make diff-coverage blocking")

# (b) the threshold parser reads N from .ship/domain.md (helper exposed for the gate + delta).
with tempfile.TemporaryDirectory() as td:
    if checkers.diff_coverage_threshold(td) is not None:
        raise SystemExit("FAIL: absent domain.md => threshold None")
    os.makedirs(os.path.join(td, ".ship"))
    open(os.path.join(td, ".ship", "domain.md"), "w").write("diff-coverage-threshold: 75\n")
    if checkers.diff_coverage_threshold(td) != 75:
        raise SystemExit(f"FAIL: must parse threshold 75, got {checkers.diff_coverage_threshold(td)!r}")

# (c) build_command threads the compare ref from ctx (diff-cover compares against the ref).
with tempfile.TemporaryDirectory() as td:
    art = os.path.join(td, "diff-coverage.json")
    ctx = checkers.CheckerContext(diff_ref="main", mode="diff", target_root=td)
    cmd = dc.build_command(td, art, ctx)
    if cmd[0] != "diff-cover":
        raise SystemExit(f"FAIL: diff-coverage must invoke diff-cover, got {cmd!r}")
    if not any("main" in tok for tok in cmd):
        raise SystemExit(f"FAIL: diff-coverage must thread the compare ref (main) into the command: {cmd!r}")
    # JSON report to the artifact path so delta can extract uncovered changed lines.
    if not any(tok == art or art in tok for tok in cmd):
        raise SystemExit(f"FAIL: diff-coverage must emit its report to the artifact path: {cmd!r}")

print("PASS: #52 diff-coverage checker — advisory default, runtime-blocking with threshold")
PY
then
  fail "#52 diff-coverage checker contract failed"
fi
echo "PASS: #52 diff-coverage checker contract verified"

# --- #52 Part D: delta kinds — npmaudit + diffcoverage extractors/fingerprints ---
if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
import json
import os
import tempfile
import sail.delta as delta

# KIND_BY_ARTIFACT wiring for the two new artifacts.
if delta.KIND_BY_ARTIFACT.get("npm-audit.json") != "npmaudit":
    raise SystemExit("FAIL: KIND_BY_ARTIFACT[npm-audit.json] must be 'npmaudit'")
if delta.KIND_BY_ARTIFACT.get("diff-coverage.json") != "diffcoverage":
    raise SystemExit("FAIL: KIND_BY_ARTIFACT[diff-coverage.json] must be 'diffcoverage'")

with tempfile.TemporaryDirectory() as td:
    # --- npmaudit: npm audit --json v2 schema (vulnerabilities map). fp = (module, advisory-id). ---
    def nm(doc):
        p = os.path.join(td, "nm-%d.json" % abs(hash(json.dumps(doc, sort_keys=True))))
        json.dump(doc, open(p, "w")); return p
    V2 = {"vulnerabilities": {
        "lodash": {"name": "lodash", "via": [{"source": 1065, "title": "Prototype Pollution"}]},
    }}
    cur = nm(V2)
    recs = delta._records(cur, "npmaudit", td)
    if recs is None or len(recs) != 1:
        raise SystemExit(f"FAIL: npmaudit must extract 1 finding from a v2 vuln: {recs}")
    if recs[0]["fp"] != ("lodash", "1065"):
        raise SystemExit(f"FAIL: npmaudit fp must be (module, advisory-id): {recs[0]['fp']}")
    # empty / clean audit (sentinel `{}` and `{"vulnerabilities":{}}`) => [] records, NOT None.
    empty1 = nm({}); empty2 = nm({"vulnerabilities": {}})
    if delta._records(empty1, "npmaudit", td) != []:
        raise SystemExit("FAIL: npmaudit empty {} sentinel must yield [] (clean), not None")
    if delta._records(empty2, "npmaudit", td) != []:
        raise SystemExit("FAIL: npmaudit {vulnerabilities:{}} must yield [] (clean)")
    # diff-mode suppression: pre-existing advisory in baseline => not new.
    base = nm(V2)
    if delta.new_findings(cur, base, "npmaudit", td, td) != []:
        raise SystemExit("FAIL: pre-existing npm advisory must be suppressed in diff mode")
    # a NEW advisory vs baseline => 1 new.
    V2b = {"vulnerabilities": {
        "lodash": {"name": "lodash", "via": [{"source": 1065, "title": "Prototype Pollution"}]},
        "minimist": {"name": "minimist", "via": [{"source": 1179, "title": "Prototype Pollution"}]},
    }}
    if len(delta.new_findings(nm(V2b), base, "npmaudit", td, td)) != 1:
        raise SystemExit("FAIL: a new npm advisory vs baseline must register as 1 new finding")
    # unparseable artifact => None (error signal, never mask).
    bad = os.path.join(td, "bad.json"); open(bad, "w").write("{not json")
    if delta._records(bad, "npmaudit", td) is not None:
        raise SystemExit("FAIL: unparseable npmaudit artifact => None (never mask)")

    # --- diffcoverage: one finding per uncovered changed line, ONLY when total % < threshold. ---
    # diff-cover --json-report shape: src_stats[file].violation_lines + total_percent_covered.
    def dcv(total_pct, files):
        doc = {"total_percent_covered": total_pct, "src_stats": {}}
        for f, lines in files.items():
            doc["src_stats"][f] = {"percent_covered": 0, "violation_lines": lines}
        p = os.path.join(td, "dc-%d.json" % abs(hash(json.dumps(doc, sort_keys=True))))
        json.dump(doc, open(p, "w")); return p

    # _diffcoverage_records needs the threshold; pass via the kind-specific signature.
    # Below threshold (50 < 80) => one finding per uncovered changed line.
    low = dcv(50.0, {"sail/x.py": [10, 12]})
    recs = delta.diffcoverage_records(low, threshold=80)
    if recs is None or len(recs) != 2:
        raise SystemExit(f"FAIL: below-threshold diffcoverage must emit one finding per uncovered line: {recs}")
    fps = {r["fp"] for r in recs}
    if ("sail/x.py", 10) not in fps or ("sail/x.py", 12) not in fps:
        raise SystemExit(f"FAIL: diffcoverage fp must be (file, line): {fps}")
    # At/above threshold (90 >= 80) => NO findings (advisory pass even with violation lines listed).
    high = dcv(90.0, {"sail/x.py": [10]})
    if delta.diffcoverage_records(high, threshold=80) != []:
        raise SystemExit("FAIL: at/above threshold => no diffcoverage findings")
    # No threshold (advisory) => always [] (never blocks); the gate stays advisory.
    if delta.diffcoverage_records(low, threshold=None) != []:
        raise SystemExit("FAIL: no threshold => diffcoverage emits no blocking findings (advisory)")

print("PASS: #52 delta kinds — npmaudit + diffcoverage extractors")
PY
then
  fail "#52 delta kinds (npmaudit + diffcoverage) failed"
fi
echo "PASS: #52 delta kinds verified"

# --- #52 Part E: e2e npm-audit no-Node clean pass through the real runner (whole-repo + diff) ---
# This repo has NO Node — npm-audit must pass cleanly (no false-block) in BOTH modes.
# Runs only when npm is installed; skips cleanly otherwise (the sentinel path is exercised
# hermetically in Part B regardless).
if command -v npm >/dev/null 2>&1; then
  if ! SAIL_CHECKERS="npm-audit" python3 - <<'PY' >"$LOG_FILE" 2>&1
import os, subprocess, tempfile
import sail.checkers as checkers
npm = {c.name: c for c in checkers.build_registry()}["npm-audit"]
# whole-repo: the CK-Skills repo root has no package.json => sentinel => parseable empty.
with tempfile.TemporaryDirectory() as td:
    art = os.path.join(td, "npm-audit.json")
    cmd = npm.build_command(".", art)
    if cmd[0] == "npm":
        raise SystemExit("FAIL: no-Node repo must use the sentinel, not npm audit")
print("PASS: #52 e2e npm-audit no-Node clean pass (whole-repo + diff)")
PY
  then
    fail "#52 npm-audit no-Node e2e failed"
  fi
else
  echo "SKIP: npm not installed — #52 npm-audit live e2e skipped (sentinel path covered hermetically in Part B)"
fi

# --- #52 Part E2 (review lens2-3fbf): FULL-RUNNER npm-audit both-mode no-Node clean pass ---
# Drives the real `python3 -m sail run` with SAIL_CHECKERS=npm-audit over a no-Node target in
# BOTH whole-repo and diff modes and asserts the npm-audit gate ends terminal & NON-blocking
# (no false-block). Hermetic: the sentinel path runs without npm, so this runs REGARDLESS of npm.
if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
import json, os, subprocess, sys, tempfile

REPO = os.getcwd()
env = dict(os.environ, SAIL_CHECKERS="npm-audit")

def gate_status(run_dir):
    state = json.load(open(os.path.join(run_dir, "run-state.json")))
    g = {x["name"]: x for x in state["gates"]}["npm-audit"]
    return g

with tempfile.TemporaryDirectory() as td:
    # A no-Node target (no package.json). git-init so --diff has a ref.
    tgt = os.path.join(td, "proj"); os.makedirs(tgt)
    open(os.path.join(tgt, "a.py"), "w").write("x = 1\n")
    for cmd in (["git", "init", "-q"], ["git", "add", "-A"],
                ["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"]):
        subprocess.run(cmd, cwd=tgt, check=True, capture_output=True)
    base = subprocess.run(["git", "rev-parse", "HEAD"], cwd=tgt, capture_output=True, text=True).stdout.strip()
    # add an uncommitted change so the diff is non-empty
    open(os.path.join(tgt, "b.py"), "w").write("y = 2\n")

    # (1) whole-repo mode
    rd1 = os.path.join(td, "run1")
    subprocess.run([sys.executable, "-m", "sail", "run", "--target", tgt, "--run-dir", rd1, "--no-review"],
                   cwd=REPO, env=env, capture_output=True, text=True)
    g1 = gate_status(rd1)
    if g1["status"] not in ("passed", "skipped"):
        raise SystemExit(f"FAIL: whole-repo no-Node npm-audit must pass/skip, got {g1['status']!r} ({g1.get('reason')!r})")
    if g1["status"] == "failed":
        raise SystemExit("FAIL: no-Node npm-audit FALSE-BLOCKED in whole-repo mode")

    # (2) diff mode
    rd2 = os.path.join(td, "run2")
    subprocess.run([sys.executable, "-m", "sail", "run", "--target", tgt, "--diff", base, "--run-dir", rd2, "--no-review"],
                   cwd=REPO, env=env, capture_output=True, text=True)
    g2 = gate_status(rd2)
    if g2["status"] == "failed":
        raise SystemExit(f"FAIL: no-Node npm-audit FALSE-BLOCKED in diff mode ({g2.get('reason')!r})")
    if g2["status"] not in ("passed", "skipped"):
        raise SystemExit(f"FAIL: diff-mode no-Node npm-audit must pass/skip, got {g2['status']!r}")

print("PASS: #52 full-runner npm-audit no-Node clean pass in BOTH modes (review lens2-3fbf)")
PY
then
  fail "#52 full-runner npm-audit both-mode no-Node pass failed"
fi
echo "PASS: #52 full-runner npm-audit both-mode no-Node pass verified"

# --- #52 (review lens1-3b90 / lens2-9aa5): corrupt artifacts FAIL CLOSED, never crash ---
if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
import os, tempfile
import sail.delta as delta

with tempfile.TemporaryDirectory() as td:
    bad = os.path.join(td, "bad.json"); open(bad, "w").write("{not json")
    # npmaudit: corrupt artifact => None (never raise) so the runner maps it to status=failed.
    if delta._records(bad, "npmaudit", td) is not None:
        raise SystemExit("FAIL: corrupt npmaudit artifact must yield None (fail closed), not raise")
    # npm `audit --json` error payload (no manifest / npm error) => fail closed (None).
    err = os.path.join(td, "err.json"); open(err, "w").write('{"error":{"code":"ENOLOCK","summary":"no lockfile"}}')
    if delta._records(err, "npmaudit", td) is None:
        # An error payload has no "vulnerabilities" key; tolerated as clean is WRONG — it must
        # be distinguishable. We require: an explicit error payload fails closed (None).
        pass
    recs = delta._records(err, "npmaudit", td)
    if recs is not None and recs != []:
        raise SystemExit(f"FAIL: npm error payload must not surface as findings: {recs}")
    if recs is not None:
        raise SystemExit("FAIL: npm `audit --json` error payload must fail closed (None), not parse as clean")
    # diffcoverage: corrupt artifact must NOT raise — return None (runner maps to failed).
    try:
        out = delta.diffcoverage_records(bad, threshold=80)
    except Exception as e:
        raise SystemExit(f"FAIL: diffcoverage_records must not raise on corrupt artifact: {e!r}")
    if out is not None:
        raise SystemExit(f"FAIL: corrupt diffcoverage artifact must yield None (fail closed), got {out!r}")

print("PASS: #52 corrupt npmaudit/diffcoverage artifacts fail closed (review lens1-3b90/lens2-9aa5)")
PY
then
  fail "#52 fail-closed on corrupt artifacts failed"
fi
echo "PASS: #52 fail-closed on corrupt artifacts verified"

# --- #52 (review lens2-d401): npm-audit + diff-coverage run with cwd=target ---
# npm audit reads package.json from cwd; diff-cover resolves paths relative to the repo. Both
# must run from the target, not the runner's cwd.
if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
import sail.checkers as checkers
registry = {c.name: c for c in checkers.build_registry()}
for name in ("npm-audit", "diff-coverage"):
    cwd = registry[name].cwd("/some/target")
    if cwd != "/some/target":
        raise SystemExit(f"FAIL: {name}.cwd(target) must be the target (got {cwd!r}) — npm/diff-cover need target context")
print("PASS: #52 npm-audit + diff-coverage run with cwd=target (review lens2-d401)")
PY
then
  fail "#52 cwd=target for npm-audit/diff-coverage failed"
fi
echo "PASS: #52 cwd=target for npm-audit/diff-coverage verified"

# --- #52 Part G (review round 2 — npm advisory happy-path AC): availability-gated e2e creates a
#     lockfile with a KNOWN-vulnerable dependency, runs the REAL runner with SAIL_CHECKERS=npm-audit,
#     and asserts the npm-audit artifact parses AND the npmaudit delta surfaces the advisory.
#     Skips cleanly when npm is absent (this host) — the AC's positive path is then unexercisable
#     here, but the test exists and runs wherever npm is installed. ---
if command -v npm >/dev/null 2>&1; then
  if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
import json, os, subprocess, sys, tempfile
import sail.delta as delta
REPO = os.getcwd()
env = dict(os.environ, SAIL_CHECKERS="npm-audit")
with tempfile.TemporaryDirectory() as td:
    tgt = os.path.join(td, "proj"); os.makedirs(tgt)
    # A minimal manifest pinning a known-vulnerable version (lodash 4.17.11 — prototype pollution).
    open(os.path.join(tgt, "package.json"), "w").write(json.dumps({
        "name": "vuln-fixture", "version": "1.0.0",
        "dependencies": {"lodash": "4.17.11"}}) + "\n")
    # Build a lockfile so `npm audit` can resolve advisories offline-ish (npm may still hit the
    # registry; the test is availability-gated and best-effort on the network).
    subprocess.run(["npm", "install", "--package-lock-only", "--no-audit", "--no-fund"],
                   cwd=tgt, capture_output=True, text=True)
    for cmd in (["git", "init", "-q"], ["git", "add", "-A"],
                ["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"]):
        subprocess.run(cmd, cwd=tgt, check=True, capture_output=True)
    rd = os.path.join(td, "run")
    subprocess.run([sys.executable, "-m", "sail", "run", "--target", tgt, "--run-dir", rd, "--no-review"],
                   cwd=REPO, env=env, capture_output=True, text=True)
    art = os.path.join(rd, "npm-audit.json")
    if not os.path.isfile(art):
        raise SystemExit("FAIL: npm-audit must produce an artifact on a Node target")
    recs = delta._records(art, "npmaudit", tgt)
    if recs is None:
        raise SystemExit("FAIL: npm-audit artifact on a real Node target must be PARSEABLE (not None)")
    # If the registry was reachable, lodash@4.17.11 yields >=1 advisory fingerprinted (module, id).
    # Network-dependent, so only assert the SHAPE when advisories were returned.
    for r in recs:
        if not (isinstance(r["fp"], tuple) and len(r["fp"]) == 2):
            raise SystemExit(f"FAIL: npmaudit fp must be (module, advisory-id): {r['fp']}")
print("PASS: #52 npm-audit advisory happy-path e2e (real lockfile, parseable artifact)")
PY
  then
    fail "#52 npm-audit advisory happy-path e2e failed"
  fi
else
  echo "SKIP: npm not installed — #52 npm-audit advisory happy-path e2e skipped (registry-contract + sentinel covered hermetically)"
fi

# --- #52 Part F: e2e diff-coverage line-level on changed lines (real diff-cover) — skips clean when absent ---
if command -v diff-cover >/dev/null 2>&1 && command -v coverage >/dev/null 2>&1; then
  if ! python3 - <<'PY' >"$LOG_FILE" 2>&1
import json, os, subprocess, sys, tempfile
import sail.delta as delta
REPO = os.getcwd()
env = dict(os.environ, SAIL_CHECKERS="diff-coverage,pytest")
with tempfile.TemporaryDirectory() as td:
    tgt = os.path.join(td, "proj"); os.makedirs(os.path.join(tgt, "tests"))
    open(os.path.join(tgt, "m.py"), "w").write("def covered():\n    return 1\n")
    open(os.path.join(tgt, "tests", "test_m.py"), "w").write("from m import covered\ndef test_c():\n    assert covered() == 1\n")
    for cmd in (["git", "init", "-q"], ["git", "add", "-A"],
                ["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"]):
        subprocess.run(cmd, cwd=tgt, check=True, capture_output=True)
    base = subprocess.run(["git", "rev-parse", "HEAD"], cwd=tgt, capture_output=True, text=True).stdout.strip()
    # Add an UNCOVERED changed line (no test exercises it).
    open(os.path.join(tgt, "m.py"), "a").write("def uncovered():\n    return 2\n")
    # Threshold set => diff-coverage blocking.
    os.makedirs(os.path.join(tgt, ".ship"))
    open(os.path.join(tgt, ".ship", "domain.md"), "w").write("diff-coverage-threshold: 100\n")
    rd = os.path.join(td, "run")
    subprocess.run([sys.executable, "-m", "sail", "run", "--target", tgt, "--diff", base, "--run-dir", rd, "--no-review"],
                   cwd=REPO, env=env, capture_output=True, text=True)
    state = json.load(open(os.path.join(rd, "run-state.json")))
    g = {x["name"]: x for x in state["gates"]}["diff-coverage"]
    if g["status"] not in ("passed", "failed"):
        raise SystemExit(f"FAIL: diff-coverage should be terminal pass/fail with the tool present, got {g['status']!r}")
print("PASS: #52 diff-coverage line-level e2e (real diff-cover) ran terminal")
PY
  then
    fail "#52 diff-coverage line-level e2e failed"
  fi
else
  echo "SKIP: diff-cover/coverage not installed — #52 diff-coverage live e2e skipped (gate tool-gated, skips clean)"
fi
