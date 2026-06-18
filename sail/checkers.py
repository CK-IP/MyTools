from __future__ import annotations

import os
import shutil
from dataclasses import dataclass
from typing import List


@dataclass(frozen=True)
class Checker:
    name: str
    tool: str
    artifact: str
    blocking: bool = True

    def available(self) -> bool:
        return shutil.which(self.tool) is not None

    def classify(self, rc: int) -> str:
        return "passed" if rc == 0 else "failed"

    def build_command(self, target: str, artifact_path: str) -> List[str]:
        if self.name == "ruff":
            return ["ruff", "check", "--output-format", "sarif", "--output-file", artifact_path, target]
        if self.name == "mypy":
            return ["mypy", "--junit-xml", artifact_path, target]
        if self.name == "pytest":
            coverage_path = os.path.join(os.path.dirname(artifact_path), "coverage.xml")
            return [
                "pytest",
                target,
                "--junitxml",
                artifact_path,
                "--cov=" + target,
                "--cov-report",
                "xml:" + coverage_path,
                "--cov-fail-under",
                "0",
            ]
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
