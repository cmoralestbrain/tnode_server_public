#!/usr/bin/env python3
"""verify_cloudflared — health check del túnel Cloudflare (driftAllowed=true)."""
from __future__ import annotations
__VERSION__ = "1.0.0"

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_common import (  # noqa: E402
    check_apt_version,
    check_service_active,
    find_self,
    report,
)

COMPONENT_ID = "cloudflared"
SERVICE_NAME = "cloudflared"
PACKAGE_NAME = "cloudflared"


def main() -> int:
    entry = find_self(COMPONENT_ID)
    expected = entry.get("version") if entry else "system"

    checks = [
        check_service_active(SERVICE_NAME),
        check_apt_version(PACKAGE_NAME),
    ]
    actual = next((c["details"].split("=")[-1] if "=" in c["details"] else c["details"]
                   for c in checks if c["name"] == "apt-version" and c["status"] == "ok"),
                  None)
    return report(COMPONENT_ID, expected, actual, checks, drift_allowed=True)


if __name__ == "__main__":
    sys.exit(main())
