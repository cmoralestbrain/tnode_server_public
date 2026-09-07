#!/usr/bin/env python3
"""verify_tnode-skill-manager — el CLI está, el cache existe y `verify` del
propio CLI no reporta drift entre cache, state y workspace."""
from __future__ import annotations
__VERSION__ = "1.0.0"

import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_common import (  # noqa: E402
    check_json_valid,
    check_script_version,
    find_self,
    report,
)

COMPONENT_ID = "tnode-skill-manager"
OPENCLAW_HOME = Path(os.environ.get("OPENCLAW_HOME") or (Path.home() / ".openclaw"))
SCRIPT_PATH = OPENCLAW_HOME / "scripts" / "tnode_skill_manager.py"
INDEX_PATH = OPENCLAW_HOME / "tnode-skills" / "cache" / "index.json"
STATE_PATH = OPENCLAW_HOME / "tnode-skills" / "state.json"


def check_cli_verify() -> dict:
    if not SCRIPT_PATH.exists():
        return {"name": "cli-verify", "status": "fail", "details": "script not found"}
    try:
        env = dict(os.environ, OPENCLAW_HOME=str(OPENCLAW_HOME))
        p = subprocess.run([sys.executable, str(SCRIPT_PATH), "verify"],
                           capture_output=True, text=True, timeout=60, env=env)
        d = json.loads(p.stdout or "{}")
    except Exception as e:  # noqa: BLE001
        return {"name": "cli-verify", "status": "fail", "details": f"{type(e).__name__}: {e}"}
    if d.get("ok"):
        return {"name": "cli-verify", "status": "ok", "details": d.get("summary", "ok")}
    probs = d.get("problems") or []
    return {"name": "cli-verify", "status": "fail",
            "details": "; ".join(f"{x.get('skill')}: {', '.join(x.get('errors') or [])}" for x in probs)[:300]
            or d.get("error", "verify failed")}


def main() -> int:
    entry = find_self(COMPONENT_ID)
    expected = entry.get("version") if entry else "unknown"
    checks = [
        check_script_version(SCRIPT_PATH, expected),
        check_json_valid(INDEX_PATH),
        check_json_valid(STATE_PATH),
        check_cli_verify(),
    ]
    actual = next((c["details"].split("=")[1].split()[0]
                   for c in checks if c["name"] == "script-version" and c["status"] == "ok"),
                  None)
    return report(COMPONENT_ID, expected, actual, checks)


if __name__ == "__main__":
    sys.exit(main())
