#!/usr/bin/env bash
# test_sail_145_shell_runtime.sh
# Leadsman red-phase contract for #145: the shell-runtime verification gate. It executes
# CHANGED shell surfaces the way the runtime actually uses them — sourced under the real login
# shell (zsh) and, for symlink-installed libs, through the symlink path — before merge. Pins:
#   T1  is_shell_surface classifier (.sh / first-line shebang / sourced-lib root; .md excluded)
#   T2  discover_shell_surfaces reads first lines (extensionless shebang) and skips non-shell
#   T3  #127 caught: a zsh-incompatible sourced lib (${BASH_SOURCE[0]} under set -u) → finding
#   T4  #127 negative: a zsh-safe lib → no finding (mutation guard, not vacuous)
#   T5  #128 caught: symlink-path source-resolution breakage → finding via the SYMLINK probe,
#       green via the direct probe (both symlink-as-operand and cwd dimensions controlled)
#   T6  parse_install_symlinks maps the real INSTALL.md $(pwd)/REL → ~/.claude/DEST forms
#   T7  ShellRuntimeChecker: registry membership, artifact, available()==zsh, affected_by scope
#   T8  delta wiring: shell-runtime.json in KIND_BY_ARTIFACT + DIFF_ONLY_ARTIFACTS + extractor
#   T9  injection-safety: no shell=True / no path interpolated into a zsh -c code string
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_FILE="$(mktemp)"
cleanup() { rm -f "$LOG_FILE"; }
trap cleanup EXIT
fail() {
  echo "FAIL: $1" >&2
  [ -s "$LOG_FILE" ] && { echo "---- output ----" >&2; sed 's/^/  /' "$LOG_FILE" >&2; echo "----------------" >&2; }
  exit 1
}
cd "$REPO_ROOT"
# Hermetic: a real shell exports SAIL_* codex knobs; clear them so subtests control their own env.
unset "${!SAIL_@}"

command -v zsh >/dev/null 2>&1 || { echo "SKIP: zsh not available on this host"; exit 0; }

# ---- T1: classifier ----------------------------------------------------------------------
python3 - >"$LOG_FILE" 2>&1 <<'PY' || fail "T1 classifier"
import sail.shell_runtime as sr
assert sr.is_shell_surface("home/lib/foo.sh", None) is True, "T1: .sh must be a shell surface"
assert sr.is_shell_surface("README.md", None) is False, "T1: .md is not a shell surface"
assert sr.is_shell_surface("sail/plan.py", None) is False, "T1: .py is not a shell surface"
assert sr.is_shell_surface("bin/tool", "#!/usr/bin/env bash") is True, "T1: shebang'd extensionless file is a shell surface"
assert sr.is_shell_surface("bin/tool", "#!/bin/zsh") is True, "T1: zsh shebang counts"
assert sr.is_shell_surface("hooks/anything", None) is True, "T1: file under a sourced-lib root (hooks/) counts"
assert sr.is_shell_surface("config/surf-worker.sh", None) is True, "T1: config/ shell lib counts"
# a markdown file whose first line happens to open a fenced ```bash block is NOT a shell surface
assert sr.is_shell_surface("guide.md", "```bash") is False, "T1: markdown fence is not a shell surface"
# exact interpreter match — 'sh' is a substring of fish/csh but those are NOT sh-family surfaces
assert sr.is_shell_surface("bin/f", "#!/usr/bin/env fish") is False, "T1: fish is not a shell surface"
assert sr.is_shell_surface("bin/c", "#!/bin/csh") is False, "T1: csh is not a shell surface"
print("T1 OK")
PY
echo "PASS T1 (classifier)"

# ---- T2: discovery reads first lines; non-shell skips -------------------------------------
python3 - >"$LOG_FILE" 2>&1 <<'PY' || fail "T2 discovery"
import os, tempfile, sail.shell_runtime as sr
with tempfile.TemporaryDirectory() as t:
    os.makedirs(os.path.join(t, "bin"))
    open(os.path.join(t, "a.py"), "w").write("x = 1\n")
    open(os.path.join(t, "b.md"), "w").write("# doc\n")
    open(os.path.join(t, "lib.sh"), "w").write("echo hi\n")
    open(os.path.join(t, "bin", "tool"), "w").write("#!/usr/bin/env bash\necho hi\n")
    found = set(sr.discover_shell_surfaces(t, ["a.py", "b.md", "lib.sh", "bin/tool"]))
    assert "lib.sh" in found, f"T2: .sh must be discovered ({found})"
    assert os.path.join("bin", "tool") in found or "bin/tool" in found, f"T2: shebang'd file must be discovered ({found})"
    assert "a.py" not in found and "b.md" not in found, f"T2: non-shell must skip ({found})"
    assert sr.discover_shell_surfaces(t, ["a.py", "b.md"]) == [], "T2: an all-non-shell diff discovers nothing (zero-cost)"
print("T2 OK")
PY
echo "PASS T2 (discovery)"

# ---- T3/T4: #127 bash-under-zsh caught, zsh-safe lib clean (mutation guard) ---------------
python3 - >"$LOG_FILE" 2>&1 <<'PY' || fail "T3/T4 #127"
import os, tempfile, sail.shell_runtime as sr
with tempfile.TemporaryDirectory() as t:
    # zsh-incompatible: ${BASH_SOURCE[0]} is unbound under zsh set -u
    bad = os.path.join(t, "home", "lib"); os.makedirs(bad)
    open(os.path.join(bad, "bad.sh"), "w").write('here="$(dirname "${BASH_SOURCE[0]}")"\n')
    open(os.path.join(bad, "good.sh"), "w").write('here="${0:A:h}"\n:\n')
    # only ~/.claude/lib-installed sourced libs are probed — declare both in a temp INSTALL.md
    open(os.path.join(t, "INSTALL.md"), "w").write(
        'ln -s "$(pwd)/home/lib/bad.sh" ~/.claude/lib/bad.sh\n'
        'ln -s "$(pwd)/home/lib/good.sh" ~/.claude/lib/good.sh\n')
    imd = os.path.join(t, "INSTALL.md")
    findings = sr.run_shell_runtime(t, ["home/lib/bad.sh"], install_md_path=imd)
    assert findings, "T3: a zsh-incompatible sourced lib must produce a blocking finding"
    # mutation guard: a zsh-safe lib must be clean (else the probe is vacuous)
    clean = sr.run_shell_runtime(t, ["home/lib/good.sh"], install_md_path=imd)
    assert clean == [], f"T4: a zsh-safe lib must probe clean ({clean})"
print("T3/T4 OK")
PY
echo "PASS T3/T4 (#127 bash-under-zsh + mutation guard)"

# ---- T5: #128 symlink-path source-resolution — red via symlink, green via direct ----------
python3 - >"$LOG_FILE" 2>&1 <<'PY' || fail "T5 #128"
import os, tempfile, sail.shell_runtime as sr
with tempfile.TemporaryDirectory() as t:
    libd = os.path.join(t, "home", "lib"); os.makedirs(libd)
    # locates a sibling via its own source path (%x) — breaks when sourced through a symlink
    open(os.path.join(libd, "resolver.sh"), "w").write(
        'here="$(dirname "${(%):-%x}")"\n. "$here/sibling.sh"\n')
    open(os.path.join(libd, "sibling.sh"), "w").write(":\n")
    # INSTALL.md maps this lib to a ~/.claude symlink dest → the symlink probe fires
    open(os.path.join(t, "INSTALL.md"), "w").write(
        'ln -s "$(pwd)/home/lib/resolver.sh" ~/.claude/lib/resolver.sh\n')
    findings = sr.run_shell_runtime(t, ["home/lib/resolver.sh"], install_md_path=os.path.join(t, "INSTALL.md"))
    # the DIRECT probe (realpath) resolves the sibling fine; the SYMLINK probe must catch the break
    probes = {f.get("probe") for f in findings}
    assert findings, "T5: symlink-path breakage must produce a finding"
    assert "symlink" in probes, f"T5: the SYMLINK probe must be the one that fires ({probes})"
print("T5 OK")
PY
echo "PASS T5 (#128 symlink source-resolution)"

# ---- T6: INSTALL.md parser handles the real $(pwd)/REL → ~/.claude/DEST forms -------------
python3 - >"$LOG_FILE" 2>&1 <<'PY' || fail "T6 INSTALL parser"
import os, sail.shell_runtime as sr
repo = os.getcwd()
mp = sr.parse_install_symlinks(os.path.join(repo, "INSTALL.md"), repo)
# map values are absolute ~/.claude dests keyed by absolute repo-relative source
srcs = {os.path.relpath(s, repo): d for s, d in mp.items()}
assert any(k == "config/surf-worker.sh" for k in srcs), f"T6: surf-worker.sh must be mapped ({list(srcs)[:8]})"
assert any(k == "home/lib/sail-git-lifecycle.sh" for k in srcs), f"T6: sail-git-lifecycle.sh must be mapped"
for k, d in srcs.items():
    assert os.path.expanduser("~/.claude") in d, f"T6: dest must be under ~/.claude ({k}->{d})"
print("T6 OK", len(mp), "mappings")
PY
echo "PASS T6 (INSTALL.md parser)"

# ---- T7: checker contract ----------------------------------------------------------------
python3 - >"$LOG_FILE" 2>&1 <<'PY' || fail "T7 checker"
import shutil, sail.checkers as checkers
reg = {c.name: c for c in checkers.build_registry()}
assert "shell-runtime" in reg, f"T7: shell-runtime must be registered ({list(reg)})"
c = reg["shell-runtime"]
assert c.artifact == "shell-runtime.json", f"T7: artifact {c.artifact!r}"
# available() gates on zsh
assert c.available() == (shutil.which("zsh") is not None), "T7: available() must gate on zsh"
# affected_by: shell surfaces True, non-shell False
assert c.affected_by(["home/lib/x.sh"]) is True, "T7: .sh diff must affect"
assert c.affected_by(["hooks/foo"]) is True, "T7: sourced-lib root must affect"
assert c.affected_by(["sail/plan.py", "README.md"]) is False, "T7: non-shell diff must NOT affect (zero-cost skip)"
assert c.affected_by([]) is True, "T7: empty/unknown changed set fails safe to True"
print("T7 OK")
PY
echo "PASS T7 (checker contract)"

# ---- T8: delta wiring --------------------------------------------------------------------
python3 - >"$LOG_FILE" 2>&1 <<'PY' || fail "T8 delta wiring"
import json, os, tempfile, sail.delta as delta
assert "shell-runtime.json" in delta.KIND_BY_ARTIFACT, "T8: must be in KIND_BY_ARTIFACT"
assert "shell-runtime.json" in delta.DIFF_ONLY_ARTIFACTS, "T8: must be DIFF_ONLY (skip baseline gen)"
kind = delta.KIND_BY_ARTIFACT["shell-runtime.json"]
# an extractor keyed on this kind must read a JSON finding list
extract = getattr(delta, "_EXTRACTORS", {}).get(kind) or getattr(delta, "shellruntime_records", None)
assert extract is not None, "T8: a shell-runtime extractor must exist"
with tempfile.TemporaryDirectory() as d:
    p = os.path.join(d, "shell-runtime.json")
    json.dump([{"surface": "home/lib/bad.sh", "probe": "direct", "detail": "boom"}], open(p, "w"))
    recs = extract(p)
    assert len(recs) == 1, f"T8: extractor must surface the one finding ({recs})"
    json.dump([], open(p, "w"))
    assert extract(p) == [], "T8: empty list == green"
print("T8 OK")
PY
echo "PASS T8 (delta wiring)"

# ---- T9: injection safety — no shell=True; paths never interpolated into zsh -c code ------
python3 - >"$LOG_FILE" 2>&1 <<'PY' || fail "T9 injection safety"
import inspect, sail.shell_runtime as sr
src = inspect.getsource(sr)
assert "shell=True" not in src, "T9: never shell=True"
# the zsh snippet is a FIXED template that sources via positional $1 — never an interpolated path
assert '"$1"' in sr.ZSH_SOURCE_SNIPPET, "T9: the probe snippet must source via positional $1"
assert "{" not in sr.ZSH_SOURCE_SNIPPET, "T9: the zsh snippet must be a fixed literal (no f-string interpolation of a path)"
print("T9 OK")
PY
echo "PASS T9 (injection safety)"

# ---- T10: NO false positive on standalone/non-lib files (the round-1 CRITICAL/HIGH) ---------
python3 - >"$LOG_FILE" 2>&1 <<'PY' || fail "T10 no false positive"
import os, tempfile, sail.shell_runtime as sr
with tempfile.TemporaryDirectory() as t:
    os.makedirs(os.path.join(t, "config"))
    # a standalone bash-EXECUTED script (own shebang) with a bash-ism that fails under zsh source;
    # it is NOT installed into ~/.claude/lib, so it is never sourced under zsh → must NOT be probed
    open(os.path.join(t, "config", "standalone.sh"), "w").write('#!/usr/bin/env bash\nunset "${!FOO_@}"\n')
    # a non-shell plist under config/
    open(os.path.join(t, "config", "x.plist"), "w").write("<plist/>\n")
    open(os.path.join(t, "INSTALL.md"), "w").write("# no ~/.claude/lib mappings\n")
    res = sr.run_shell_runtime(t, ["config/standalone.sh", "config/x.plist"],
                               install_md_path=os.path.join(t, "INSTALL.md"))
    assert res == [], f"T10: standalone/non-lib files must NOT be zsh-source-probed (no false positive) ({res})"
print("T10 OK")
PY
echo "PASS T10 (no false positive on standalone scripts / plists)"

# ---- T11: the probe env is an allowlist — inherited secrets are NOT passed through -----------
python3 - >"$LOG_FILE" 2>&1 <<'PY' || fail "T11 env allowlist"
import os, sail.shell_runtime as sr
os.environ["GH_TOKEN"] = "secret-should-not-leak"
os.environ["AWS_SECRET_ACCESS_KEY"] = "also-secret"
env = sr._clean_env("/tmp/fake-home")
assert "GH_TOKEN" not in env, "T11: inherited GH_TOKEN must not reach the probe"
assert "AWS_SECRET_ACCESS_KEY" not in env, "T11: inherited cloud creds must not reach the probe"
assert env.get("HOME") == "/tmp/fake-home", "T11: HOME is the temp probe home"
assert "PATH" in env, "T11: PATH must survive so zsh resolves"
print("T11 OK")
PY
echo "PASS T11 (env allowlist drops secrets)"

# ---- T12: a CHANGED lib resolving an UNCHANGED installed sibling must NOT false-fail -----------
python3 - >"$LOG_FILE" 2>&1 <<'PY' || fail "T12 symlink sibling fidelity"
import os, tempfile, sail.shell_runtime as sr
with tempfile.TemporaryDirectory() as t:
    libd = os.path.join(t, "home", "lib"); os.makedirs(libd)
    # changed lib sources an installed SIBLING via its own (symlink) source path — the #128 layout
    open(os.path.join(libd, "changed.sh"), "w").write(
        'here="$(dirname "${(%):-%x}")"\n. "$here/sibling.sh"\n')
    open(os.path.join(libd, "sibling.sh"), "w").write(":\n")   # unchanged, but installed
    open(os.path.join(t, "INSTALL.md"), "w").write(
        'ln -s "$(pwd)/home/lib/changed.sh" ~/.claude/lib/changed.sh\n'
        'ln -s "$(pwd)/home/lib/sibling.sh" ~/.claude/lib/sibling.sh\n')
    # only changed.sh is in the diff; sibling.sh is unchanged but installed alongside it
    res = sr.run_shell_runtime(t, ["home/lib/changed.sh"], install_md_path=os.path.join(t, "INSTALL.md"))
    assert res == [], f"T12: a changed lib resolving an installed sibling must probe clean, not false-fail ({res})"
print("T12 OK")
PY
echo "PASS T12 (symlink sibling-resolution fidelity)"

echo "ALL PASS: test_sail_145_shell_runtime.sh"
