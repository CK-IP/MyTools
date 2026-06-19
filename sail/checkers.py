from __future__ import annotations

import os
import shutil
import configparser
import re
from dataclasses import dataclass
from typing import List


def _testpaths_from_ini(path, section):
    parser = configparser.ConfigParser()
    parser.read(path, encoding="utf-8")
    if not parser.has_section(section):
        return False, []
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
        return False, []
    rest = text[header.end():]
    nxt = re.search(r"(?m)^\[", rest)
    body = rest[: nxt.start()] if nxt else rest
    list_match = re.search(r"(?ms)^\s*testpaths\s*=\s*\[(.*?)\]", body)
    if list_match:
        return True, re.findall(r"""["']([^"']+)["']""", list_match.group(1))
    str_match = re.search(r"""(?m)^\s*testpaths\s*=\s*["']([^"']+)["']\s*$""", body)
    if str_match:
        return True, [str_match.group(1)]
    return True, []


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
    testpaths = []
    for filename, section, parser, dedicated in candidates:
        path = os.path.join(target, filename)
        if not os.path.isfile(path):
            continue
        try:
            present, parsed = parser(path, section)
        except Exception:
            present, parsed = dedicated, []
        if dedicated or present:
            config_file = path
            testpaths = parsed
            break
    if testpaths:
        # Honor explicitly-configured testpaths verbatim; a missing or renamed configured
        # path is surfaced by pytest (a real misconfiguration) rather than silently
        # widening the gate's scope back to tests/ or the whole target.
        paths = [entry if os.path.isabs(entry) else os.path.join(target, entry) for entry in testpaths]
    else:
        tests_dir = os.path.join(target, "tests")
        paths = [tests_dir] if os.path.isdir(tests_dir) else [target]
    return paths, config_file


@dataclass(frozen=True)
class Checker:
    name: str
    tool: str
    artifact: str
    blocking: bool = True

    def available(self) -> bool:
        return shutil.which(self.tool) is not None

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

    def cwd(self, target):
        # pytest runs from the target root so the project's own execution model holds
        # (relative fixture paths, conftest discovery) — matching `pytest tests/` run from
        # the repo root. Other checkers receive the target as an argument and need no cwd.
        return target if self.name == "pytest" else None

    def build_command(self, target: str, artifact_path: str) -> List[str]:
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
            return ["bandit", "-r", target, "-f", "sarif", "-o", artifact_path]
        if self.name == "semgrep":
            return ["semgrep", "--sarif", "--output", artifact_path, target]
        if self.name == "pip-audit":
            return ["pip-audit", "-f", "json", "-o", artifact_path]
        raise ValueError(f"unknown checker {self.name!r}")


def build_registry() -> list[Checker]:
    return [
        Checker("ruff", "ruff", "ruff.sarif"),
        Checker("mypy", "mypy", "mypy.junit.xml"),
        Checker("pytest", "pytest", "junit.xml"),
        Checker("bandit", "bandit", "bandit.sarif"),
        Checker("semgrep", "semgrep", "semgrep.sarif"),
        Checker("pip-audit", "pip-audit", "pip-audit.json"),
    ]
