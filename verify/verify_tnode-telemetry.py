#!/usr/bin/env python3
"""verify_tnode-telemetry — health check del sidecar WebSocket proxy + telemetry."""
from __future__ import annotations
__VERSION__ = "1.0.1"

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_common import (  # noqa: E402
    check_http_probe,
    check_log_progress,
    check_python_module,
    check_script_version,
    check_service_active,
    find_self,
    report,
)

COMPONENT_ID = "tnode-telemetry"
SERVICE_NAME = "tnode-telemetry"
SCRIPT_PATH = Path.home() / ".openclaw" / "scripts" / "tnode_telemetry.py"
LOG_PATH = Path.home() / ".openclaw" / "logs" / "tnode-telemetry.log"
TELEMETRY_WS_URL = "ws://127.0.0.1:18790"


def main() -> int:
    entry = find_self(COMPONENT_ID)
    expected = entry.get("version") if entry else "unknown"

    checks = [
        check_service_active(SERVICE_NAME),
        check_script_version(SCRIPT_PATH, expected),
        check_http_probe(TELEMETRY_WS_URL, timeout=3),
        check_log_progress(LOG_PATH, max_age_seconds=300),
        # `health` stream needs psutil. websockets >=13 powers the WS server
        # (see ensure_websockets_modern in installers).
        check_python_module("psutil"),
        check_python_module("websockets"),
    ]
    actual = next((c["details"].split("=")[1].split()[0]
                   for c in checks if c["name"] == "script-version" and c["status"] == "ok"),
                  None)
    return report(COMPONENT_ID, expected, actual, checks)


if __name__ == "__main__":
    sys.exit(main())
