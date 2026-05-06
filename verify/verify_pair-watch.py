#!/usr/bin/env python3
"""verify_pair-watch — health check del auto-approver de device pairing."""
from __future__ import annotations
__VERSION__ = "1.0.0"

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_common import (  # noqa: E402
    check_json_valid,
    check_script_version,
    check_service_active,
    find_self,
    report,
)

COMPONENT_ID = "pair-watch"
SERVICE_NAME = "pair-watch"
SCRIPT_PATH = Path.home() / ".openclaw" / "scripts" / "pair_watch.py"
CONFIG_PATH = Path.home() / ".openclaw" / "pair-watch.json"


def main() -> int:
    entry = find_self(COMPONENT_ID)
    expected = entry.get("version") if entry else "unknown"

    checks = [
        check_service_active(SERVICE_NAME),
        check_script_version(SCRIPT_PATH, expected),
        check_json_valid(CONFIG_PATH),
    ]
    actual = next((c["details"].split("=")[1].split()[0]
                   for c in checks if c["name"] == "script-version" and c["status"] == "ok"),
                  None)
    return report(COMPONENT_ID, expected, actual, checks)


if __name__ == "__main__":
    sys.exit(main())
