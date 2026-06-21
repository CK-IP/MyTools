from __future__ import annotations

import os
import shutil
import configparser
import re
from dataclasses import dataclass
from typing import List, Optional

# bandit -r does NOT honor .gitignore, and CLI -x REPLACES (not appends to) bandit's built-in
# default excludes. bandit matches -x entries as fnmatch globs against the full path (bare dir
# names like ".git" do NOT prune nested dirs — verified on bandit 1.8.6), so use */<dir>/* glob
# form. Restate the defaults in glob form and add .claude (nested git worktrees) and .sail (sail
# run dirs, incl. the diff-mode baseline worktree) — else bandit scans nested checkouts the clean
# diff baseline lacks → spurious "new" findings → false block.
_BANDIT_EXCLUDE = (
    "*/.svn/*,*/CVS/*,*/.bzr/*,*/.hg/*,*/.git/*,*/__pycache__/*,*/.tox/*,*/.eggs/*,*.egg,"
    "*/.claude/*"
)


def _discover_sh(target):
    # Return sorted *.sh paths under target, excluding any path with a .claude segment
    # BELOW the target (nested git worktrees — mirrors the #44 _BANDIT_EXCLUDE idiom).
    # Exclusion is RELATIVE to the target: the canonical invocation runs `--target .` from a
    # cwd like .../.claude/worktrees/ship-NN/, so the target's OWN ancestor path contains
    # /.claude/ — an absolute-substring match would exclude every dirpath → silent no-op gate
    # (RT-1). .sail is NOT excluded: the diff-mode baseline worktree lives at
    # .sail/runs/.../baseline-src and must be scanned.
    found = []
    for dirpath, _dirnames, filenames in os.walk(target):
        rel = os.path.relpath(dirpath, target)
        parts = [] if rel == "." else rel.split(os.sep)
        if ".claude" in parts:
            continue
        for fn in filenames:
            if fn.endswith(".sh"):
                found.append(os.path.join(dirpath, fn))
    return sorted(found)


def _testpaths_from_ini(path, section):
    # Returns (section_present, testpaths) where testpaths is None when the testpaths KEY
    # is absent (caller falls back), or a list (possibly empty for an explicit empty value).
    parser = configparser.ConfigParser()
    parser.read(path, encoding="utf-8")
    if not parser.has_section(section):
        return False, None
    if not parser.has_option(section, "testpaths"):
        return True, None
    raw = parser.get(section, "testpaths", fallback="")
    return True, raw.split()


def _testpaths_from_pyproject(path, _section):
    # Minimal stdlib parse: tomllib is unavailable on Python 3.9, so read the
    # [tool.pytest.ini_options] table's testpaths assignment directly. Supports the
    # single-line and multi-line list forms and the bare-string form; anything else
    # leaves testpaths empty (the section is still honored as the pytest config).
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    header = re.search(r"(?m)^\[tool\.pytest\.ini_options\]\s*$", text)
    if not header:
        return False, None
    rest = text[header.end():]
    nxt = re.search(r"(?m)^\[", rest)
    body = rest[: nxt.start()] if nxt else rest
    list_match = re.search(r"(?ms)^\s*testpaths\s*=\s*\[(.*?)\]", body)
    if list_match:
        return True, re.findall(r"""["']([^"']+)["']""", list_match.group(1))
    str_match = re.search(r"""(?m)^\s*testpaths\s*=\s*["']([^"']+)["']\s*$""", body)
    if str_match:
        return True, [str_match.group(1)]
    return True, None


def _resolve_pytest_paths(target):
    # Return (test_paths, config_file). Honor the project's configured testpaths in
    # pytest's discovery precedence; else tests/; else the target itself. config_file is
    # the first file that actually configures pytest (so the gate can pin it with -c).
    # pytest.ini is pytest-dedicated (always config when present); the other sources only
    # count when their pytest section is present, so a config file lacking a pytest
    # section does not shadow a later one.
    candidates = [
        ("pytest.ini", "pytest", _testpaths_from_ini, True),
        ("pyproject.toml", "tool.pytest.ini_options", _testpaths_from_pyproject, False),
        ("tox.ini", "pytest", _testpaths_from_ini, False),
        ("setup.cfg", "tool:pytest", _testpaths_from_ini, False),
    ]
    config_file = None
    # Tri-state: None = no testpaths key seen (fall back); [] = explicitly empty (honor:
    # no positionals); non-empty list = configured paths (honor verbatim).
    testpaths = None
    for filename, section, parser, dedicated in candidates:
        path = os.path.join(target, filename)
        if not os.path.isfile(path):
            continue
        try:
            present, parsed = parser(path, section)
        except Exception:
            present, parsed = dedicated, None
        if dedicated or present:
            config_file = path
            testpaths = parsed
            break
    if testpaths:
        # Honor explicitly-configured testpaths verbatim; a missing or renamed configured
        # path is surfaced by pytest (a real misconfiguration) rather than silently
        # widening the gate's scope back to tests/ or the whole target.
        paths = [entry if os.path.isabs(entry) else os.path.join(target, entry) for entry in testpaths]
    elif testpaths == []:
        # Explicitly-empty testpaths (key present, no entries): pass no positionals so pytest
        # collects per its own config — do NOT widen back to tests/ or the whole target.
        paths = []
    else:
        # testpaths is None — the key was absent — fall back to tests/, else the target.
        tests_dir = os.path.join(target, "tests")
        paths = [tests_dir] if os.path.isdir(tests_dir) else [target]
    return paths, config_file


_NODE_MANIFESTS = ("package.json", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock")


def _has_node_manifest(target: str) -> bool:
    # npm-audit must only invoke `npm audit` when the target actually has a Node manifest.
    # `npm audit --json` with no package.json/lockfile ERRORS -> unparseable artifact ->
    # delta None -> false-block (RT-7). Detect a manifest at the target root; absent => the
    # caller emits a valid empty-JSON sentinel so a no-Node repo passes cleanly in BOTH modes.
    return any(os.path.isfile(os.path.join(target, m)) for m in _NODE_MANIFESTS)


def diff_coverage_threshold(target: str) -> Optional[int]:
    # Parse `diff-coverage-threshold: N` from <target>/.ship/domain.md. Returns the int N,
    # or None when the file or the key is absent (advisory mode). Regex parse — no tomllib on
    # the Python 3.9 host (matches the _testpaths_from_pyproject idiom). The first match wins.
    path = os.path.join(target, ".ship", "domain.md")
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return None
    m = re.search(r"(?mi)^\s*diff-coverage-threshold\s*:\s*(\d+)\s*$", text)
    return int(m.group(1)) if m else None


@dataclass(frozen=True)
class CheckerContext:
    # Runtime context threaded into build_command / is_blocking so a checker can scope to the
    # change (diff_ref + mode) without the static dataclass fields needing to know it. All
    # fields optional/defaulted so a checker that ignores ctx is unaffected.
    diff_ref: Optional[str] = None
    mode: Optional[str] = None
    target_root: Optional[str] = None


@dataclass(frozen=True)
class Checker:
    name: str
    tool: str
    artifact: str
    blocking: bool = True
    stdout_artifact: bool = False

    def available(self) -> bool:
        return shutil.which(self.tool) is not None

    def is_blocking(self, target: str, mode: str) -> bool:
        # Runtime blocking decision. Defaults to the static `blocking` field (the prior
        # contract, unchanged for every existing checker). Subclasses override to decide
        # per target/mode (diff-coverage: advisory unless .ship/domain.md sets a threshold).
        return self.blocking

    def classify(self, rc: int) -> str:
        if self.name == "pytest":
            if rc == 0:
                return "passed"
            # rc=2 is pytest's "interrupted" code — in an unattended subprocess gate
            # (no TTY/signal) this is a collection/config abort, not an interactive
            # interrupt; rc=5 is "no tests collected". Per issue #33 both are
            # non-blocking (recorded via reason()), distinct from a real failure (rc=1).
            if rc in (2, 5):
                return "skipped"
            return "failed"
        return "passed" if rc == 0 else "failed"

    def reason(self, rc: int):
        if self.name == "pytest":
            if rc == 1:
                return "test failures (rc=1)"
            if rc == 2:
                return "collection/config error (rc=2) — not a test failure"
            if rc == 5:
                return "no tests collected (rc=5)"
        return None

    # Checkers that resolve files/manifests from the process cwd (not from an argument) must
    # run FROM the target: pytest (conftest/fixtures), npm-audit (reads package.json from cwd),
    # diff-coverage (diff-cover resolves the git diff + report paths relative to the repo root).
    _CWD_AT_TARGET = ("pytest", "npm-audit", "diff-coverage")

    def cwd(self, target):
        return target if self.name in self._CWD_AT_TARGET else None

    def build_command(self, target: str, artifact_path: str, ctx: "Optional[CheckerContext]" = None) -> List[str]:
        if self.name == "ruff":
            return ["ruff", "check", "--output-format", "sarif", "--output-file", artifact_path, target]
        if self.name == "mypy":
            return ["mypy", "--junit-xml", artifact_path, target]
        if self.name == "pytest":
            coverage_path = os.path.join(os.path.dirname(artifact_path), "coverage.xml")
            test_paths, config_file = _resolve_pytest_paths(target)
            argv = ["pytest", *test_paths, "--rootdir", target]
            if config_file is not None:
                argv += ["-c", config_file]
            argv += [
                "--junitxml",
                artifact_path,
                "--cov=" + target,
                "--cov-report",
                "xml:" + coverage_path,
                "--cov-fail-under",
                "0",
            ]
            return argv
        if self.name == "bandit":
            return ["bandit", "-r", target, "-x", _BANDIT_EXCLUDE, "-f", "sarif", "-o", artifact_path]
        if self.name == "semgrep":
            return ["semgrep", "--sarif", "--output", artifact_path, target]
        if self.name == "pip-audit":
            return ["pip-audit", "-f", "json", "-o", artifact_path]
        if self.name == "shellcheck":
            sh_files = _discover_sh(target)
            if sh_files:
                return ["shellcheck", "-f", "json", *sh_files]
            # No *.sh files: a portable no-op that emits a valid empty JSON array to stdout
            # (captured via stdout_artifact). Never a zero-byte artifact, which delta would
            # read as None → false-fail (RT-8).
            return ["printf", "[]"]
        if self.name == "gitleaks":
            # gitleaks --config REPLACES the default ruleset, so the shipped TOML keeps it via
            # [extend] useDefault=true (RT-1). Resolve the config relative to THIS module so it
            # works regardless of the scanned target / cwd. --exit-code 0 so a leak (gitleaks
            # default rc=1) still writes the SARIF; the diff-delta — not rc — decides blocking.
            config = os.path.join(os.path.dirname(__file__), "gitleaks-exclude.toml")
            return [
                "gitleaks", "dir", target,
                "--report-format", "sarif",
                "--report-path", artifact_path,
                "--no-banner",
                "--exit-code", "0",
                "--config", config,
            ]
        if self.name == "npm-audit":
            # Target-aware: only invoke `npm audit --json` when a Node manifest exists at the
            # target. `npm audit --json` with no package.json/lockfile ERRORS -> unparseable
            # artifact -> delta None -> false-block (RT-7). Absent manifest => a portable
            # sentinel emitting a valid empty-JSON object to stdout (captured via
            # stdout_artifact), so a no-Node repo parses to an empty delta and passes cleanly
            # in BOTH whole-repo and diff modes. npm audit also writes JSON to stdout (no file
            # flag), so the runner persists stdout for both the real and sentinel paths.
            if _has_node_manifest(target):
                return ["npm", "audit", "--json"]
            return ["printf", "{}"]
        if self.name == "diff-coverage":
            # Line-level coverage of CHANGED lines only (strictly better than /fortify's
            # file-level coverage). diff-cover compares a coverage.xml against the diff vs the
            # compare ref threaded in via ctx, emitting a per-file/per-line JSON report. The
            # compare ref defaults to the static "main" only as a last resort; normally ctx
            # carries the run's diff_ref. coverage.xml is produced by the pytest gate alongside
            # its junit artifact (same run-dir), so diff-cover reads it as the coverage source.
            compare = (ctx.diff_ref if ctx and ctx.diff_ref else "main")
            coverage_xml = os.path.join(os.path.dirname(artifact_path), "coverage.xml")
            return [
                "diff-cover", coverage_xml,
                "--compare-branch", compare,
                "--json-report", artifact_path,
                "--fail-under", "0",
            ]
        raise ValueError(f"unknown checker {self.name!r}")


class DiffCoverageChecker(Checker):
    # diff-coverage's blocking decision is RUNTIME, not static: advisory by default, blocking
    # only when .ship/domain.md sets `diff-coverage-threshold: N`. The static `blocking` field
    # stays False (advisory default) so the prior contract / decision-log shape is preserved;
    # is_blocking overrides per target. frozen dataclass => construct via the dataclass init.
    def is_blocking(self, target: str, mode: str) -> bool:
        return diff_coverage_threshold(target) is not None


def build_registry() -> list[Checker]:
    registry = [
        Checker("ruff", "ruff", "ruff.sarif"),
        Checker("mypy", "mypy", "mypy.junit.xml"),
        Checker("pytest", "pytest", "junit.xml"),
        Checker("bandit", "bandit", "bandit.sarif"),
        Checker("semgrep", "semgrep", "semgrep.sarif"),
        Checker("pip-audit", "pip-audit", "pip-audit.json"),
        Checker("shellcheck", "shellcheck", "shellcheck.json", stdout_artifact=True),
        Checker("gitleaks", "gitleaks", "gitleaks.sarif"),
        Checker("npm-audit", "npm", "npm-audit.json", stdout_artifact=True),
        DiffCoverageChecker("diff-coverage", "diff-cover", "diff-coverage.json", blocking=False),
    ]
    # Opt-in allowlist (comma-separated checker names) to restrict the registry — e.g. fast
    # hermetic test runs that only need ruff/pytest as background gates (#51). Unset/empty =
    # all eight (unchanged). Order follows the registry, not the allowlist. Unknown names are
    # ignored (never crash); a fully-unknown allowlist yields an empty registry, which the
    # runner handles (no gates) and the LLM-review arm is unaffected.
    allow = os.environ.get("SAIL_CHECKERS")
    if allow is not None and allow.strip():
        names = {n.strip() for n in allow.split(",") if n.strip()}
        registry = [checker for checker in registry if checker.name in names]
    return registry
