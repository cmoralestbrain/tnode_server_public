#!/usr/bin/env python3
"""verify_openclaw-gateway — health check del gateway WebSocket de OpenClaw."""
from __future__ import annotations
__VERSION__ = "1.0.0"

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_common import (  # noqa: E402
    check_http_probe,
    check_json_valid,
    check_npm_version,
    check_service_active,
    find_self,
    report,
)

COMPONENT_ID = "openclaw-gateway"
SERVICE_NAME = "openclaw-gateway"           # systemd --user unit on Linux
DARWIN_LABEL = "ai.openclaw.gateway"        # launchd label on macOS
NPM_PACKAGE = "@openclaw/gateway"
OPENCLAW_JSON = Path.home() / ".openclaw" / "openclaw.json"
GATEWAY_WS_URL = "ws://127.0.0.1:18789"


def main() -> int:
    entry = find_self(COMPONENT_ID)
    expected = entry.get("version") if entry else "unknown"

    checks = [
        check_service_active(SERVICE_NAME, darwin_label=DARWIN_LABEL),
        check_npm_version(NPM_PACKAGE),
        check_http_probe(GATEWAY_WS_URL, timeout=3),
        check_json_valid(OPENCLAW_JSON),
    ]
    actual = next((c["details"].split("@")[1]
                   for c in checks if c["name"] == "npm-version" and c["status"] == "ok"),
                  None)
    return report(COMPONENT_ID, expected, actual, checks)


if __name__ == "__main__":
    sys.exit(main())
