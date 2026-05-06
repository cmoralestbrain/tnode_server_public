#!/usr/bin/env python3
"""verify_tnode-chat-sync — health check del daemon que mirrora session turns a Firestore."""
from __future__ import annotations
__VERSION__ = "1.0.0"

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_common import (  # noqa: E402
    check_json_valid,
    check_log_progress,
    check_script_version,
    check_service_active,
    find_self,
    report,
)

COMPONENT_ID = "tnode-chat-sync"
SERVICE_NAME = "tnode-chat-sync"
SCRIPT_PATH = Path.home() / ".openclaw" / "scripts" / "tnode_chat_sync.py"
CONFIG_PATH = Path.home() / ".openclaw" / "tnode-chat-sync.json"
LOG_PATH = Path.home() / ".openclaw" / "logs" / "tnode-chat-sync.log"


def main() -> int:
    entry = find_self(COMPONENT_ID)
    expected = entry.get("version") if entry else "unknown"

    checks = [
        check_service_active(SERVICE_NAME),
        check_script_version(SCRIPT_PATH, expected),
        check_json_valid(CONFIG_PATH),
        check_log_progress(LOG_PATH, max_age_seconds=180),
    ]
    actual = next((c["details"].split("=")[1].split()[0]
                   for c in checks if c["name"] == "script-version" and c["status"] == "ok"),
                  None)
    return report(COMPONENT_ID, expected, actual, checks)


if __name__ == "__main__":
    sys.exit(main())
