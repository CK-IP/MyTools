from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from typing import Any


def _coerce_issue_id(value: Any) -> int:
    if isinstance(value, bool):
        raise ValueError("issue id must be an integer")
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        text = value.strip()
        if not text:
            raise ValueError("issue id must be an integer")
        return int(text, 10)
    raise ValueError("issue id must be an integer")


def _coerce_issue_ids(values: Any) -> list[int]:
    if values is None or values == "":
        return []
    if isinstance(values, dict):
        values = values.keys()
    elif isinstance(values, (str, bytes)):
        text = values.decode() if isinstance(values, bytes) else values
        text = text.strip()
        if not text:
            return []
        if text.startswith("["):
            values = json.loads(text)
        else:
            values = [chunk for chunk in text.replace(",", " ").split() if chunk]
    out: list[int] = []
    for value in values:
        issue_id = _coerce_issue_id(value)
        if issue_id not in out:
            out.append(issue_id)
    return out


def _coerce_graph(graph: Any) -> dict[int, tuple[int, ...]]:
    if graph is None:
        return {}
    if isinstance(graph, (str, bytes)):
        text = graph.decode() if isinstance(graph, bytes) else graph
        graph = json.loads(text)
    if not isinstance(graph, dict):
        raise ValueError("graph must be a mapping of issue id -> dependencies")
    normalized: dict[int, tuple[int, ...]] = {}
    for raw_issue, raw_deps in graph.items():
        issue_id = _coerce_issue_id(raw_issue)
        if raw_deps is None or raw_deps == "":
            deps: tuple[int, ...] = ()
        else:
            if isinstance(raw_deps, (str, bytes)):
                text = raw_deps.decode() if isinstance(raw_deps, bytes) else raw_deps
                text = text.strip()
                if not text:
                    deps = ()
                elif text.startswith("["):
                    deps = tuple(_coerce_issue_ids(json.loads(text)))
                else:
                    deps = tuple(_coerce_issue_ids(text))
            else:
                deps = tuple(_coerce_issue_ids(raw_deps))
        normalized[issue_id] = deps
    return normalized


def normalize_cap(value: Any) -> int:
    cap = _coerce_issue_id(value)
    if cap < 2 or cap > 10:
        raise ValueError("cap must be between 2 and 10 inclusive")
    return cap


def wave_eligible(graph: Any, merged: Any = None, exclude: Any = None) -> list[int]:
    normalized = _coerce_graph(graph)
    merged_set = set(_coerce_issue_ids(merged))
    excluded_set = set(_coerce_issue_ids(exclude))
    eligible = []
    for issue_id in sorted(normalized):
        if issue_id in merged_set or issue_id in excluded_set:
            continue
        if all(dep in merged_set for dep in normalized[issue_id]):
            eligible.append(issue_id)
    return eligible


def launchable(eligible: Any, cap: Any, in_flight: Any = None) -> list[int]:
    cap_value = normalize_cap(cap)
    in_flight_set = set(_coerce_issue_ids(in_flight))
    launch: list[int] = []
    live_count = len(in_flight_set)
    for issue_id in _coerce_issue_ids(eligible):
        if issue_id in in_flight_set or issue_id in launch:
            continue
        if live_count + len(launch) >= cap_value:
            break
        launch.append(issue_id)
    return launch


@dataclass(frozen=True)
class WaveRunState:
    graph: dict[int, tuple[int, ...]]
    merged: tuple[int, ...]
    in_flight: tuple[int, ...]
    awaiting_merge: tuple[int, ...]
    cap: int

    def eligible(self) -> list[int]:
        # A live issue — actively building (in_flight) OR built-green-awaiting the serial merge
        # slot (awaiting_merge) — is excluded from eligibility so it is never re-offered/re-launched.
        return wave_eligible(self.graph, self.merged, self.in_flight + self.awaiting_merge)

    def launchable(self) -> list[int]:
        # The cap counts concurrent BUILDS (#91: "how many issues may build at the same time"), so
        # only in_flight builds consume a slot. An awaiting_merge branch has finished building and
        # is merely queued for the serial merge re-check — it is excluded from eligibility (above)
        # but must NOT hold a build-cap slot, else throughput collapses as merges queue up.
        return launchable(self.eligible(), self.cap, self.in_flight)


def make_run_state(graph: Any, cap: Any, merged: Any = None, in_flight: Any = None, awaiting_merge: Any = None) -> WaveRunState:
    return WaveRunState(
        graph=_coerce_graph(graph),
        merged=tuple(_coerce_issue_ids(merged)),
        in_flight=tuple(_coerce_issue_ids(in_flight)),
        awaiting_merge=tuple(_coerce_issue_ids(awaiting_merge)),
        cap=normalize_cap(cap),
    )


def _parse_json_or_list(text: str) -> Any:
    text = text.strip()
    if not text:
        return []
    if text.startswith("[") or text.startswith("{"):
        return json.loads(text)
    return [chunk for chunk in text.replace(",", " ").split() if chunk]


def run_waves(args: argparse.Namespace) -> int:
    command = getattr(args, "waves_command", None)
    try:
        if command == "cap":
            print(normalize_cap(getattr(args, "value", None)))
            return 0

        if command == "eligible":
            graph = _coerce_graph(getattr(args, "graph", None))
            merged = _coerce_issue_ids(_parse_json_or_list(getattr(args, "merged", "")))
            exclude = _coerce_issue_ids(_parse_json_or_list(getattr(args, "exclude", "")))
            out = wave_eligible(graph, merged=merged, exclude=exclude)
            if out:
                print(" ".join(str(issue) for issue in out))
            return 0

        if command == "launchable":
            eligible = _parse_json_or_list(getattr(args, "eligible", ""))
            in_flight = _parse_json_or_list(getattr(args, "in_flight", ""))
            out = launchable(eligible, getattr(args, "cap", None), in_flight=in_flight)
            if out:
                print(" ".join(str(issue) for issue in out))
            return 0

        if command == "state":
            state = make_run_state(
                getattr(args, "graph", None),
                getattr(args, "cap", None),
                merged=getattr(args, "merged", ""),
                in_flight=getattr(args, "in_flight", ""),
                awaiting_merge=getattr(args, "awaiting_merge", ""),
            )
            print(
                json.dumps(
                    {
                        "graph": {str(issue): list(deps) for issue, deps in state.graph.items()},
                        "merged": list(state.merged),
                        "in_flight": list(state.in_flight),
                        "awaiting_merge": list(state.awaiting_merge),
                        "cap": state.cap,
                        "eligible": state.eligible(),
                        "launchable": state.launchable(),
                    },
                    sort_keys=True,
                )
            )
            return 0
    except (TypeError, ValueError, json.JSONDecodeError) as exc:
        print(f"sail waves: {exc}", file=sys.stderr)
        return 1

    print("sail waves: missing or unknown subcommand", file=sys.stderr)
    return 2


__all__ = [
    "WaveRunState",
    "launchable",
    "make_run_state",
    "normalize_cap",
    "run_waves",
    "wave_eligible",
]
