from __future__ import annotations

import json
import os
import uuid
from datetime import datetime, timezone

from sail import SCHEMA_VERSION


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


class RunState:
    def __init__(self, run_dir, data):
        self.run_dir = run_dir
        self.run_id = data["run_id"]
        self.started_at = data["started_at"]
        self.schema_version = data["schema_version"]
        self.gates = data["gates"]
        self.data = data

    @classmethod
    def init(cls, run_dir, gate_names):
        os.makedirs(run_dir, exist_ok=True)
        data = {
            "run_id": uuid.uuid4().hex,
            "started_at": _utc_now_iso(),
            "schema_version": SCHEMA_VERSION,
            "gates": [
                {
                    "name": name,
                    "status": "pending",
                    "artifact": None,
                    "rc": None,
                    "reason": None,
                    "seq": None,
                    "started_at": None,
                    "finished_at": None,
                }
                for name in gate_names
            ],
        }
        return cls(run_dir, data)

    def save(self):
        path = os.path.join(self.run_dir, "run-state.json")
        tmp_path = path + ".tmp"
        with open(tmp_path, "w", encoding="utf-8") as fh:
            json.dump(self.data, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp_path, path)

    @classmethod
    def load(cls, run_dir):
        path = os.path.join(run_dir, "run-state.json")
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return cls(run_dir, data)
