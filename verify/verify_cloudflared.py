#!/usr/bin/env python3
"""verify_cloudflared — health check del túnel Cloudflare (driftAllowed=true)."""
from __future__ import annotations
__VERSION__ = "1.2.0"

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_common import (  # noqa: E402
    check_apt_version,
    check_binary_version,
    check_start_limit_disabled,
    check_service_active,
    find_self,
    report,
)

COMPONENT_ID = "cloudflared"
SERVICE_NAME = "cloudflared"          # systemd unit name on Linux
DARWIN_LABEL = "com.cloudflare.cloudflared"  # launchd label on macOS
PACKAGE_NAME = "cloudflared"


def main() -> int:
    entry = find_self(COMPONENT_ID)
    expected = entry.get("version") if entry else "system"

    # En Linux cloudflared se instala descargando el binario de GitHub
    # Releases a /usr/local/bin, así que dpkg-query nunca lo encuentra y
    # apt-version avisaba de "not installed" con el túnel corriendo. El
    # binario manda; apt queda como fallback para instalaciones vía .deb.
    ver_check = check_binary_version(PACKAGE_NAME)
    if ver_check["status"] != "ok":
        ver_check = check_apt_version(PACKAGE_NAME)

    checks = [
        check_service_active(SERVICE_NAME, darwin_label=DARWIN_LABEL),
        # El drop-in de restart (v1.87.1) se puede perder: `cloudflared service
        # install` reescribe la unit. Sin esto la regresión es invisible.
        check_start_limit_disabled(SERVICE_NAME),
        ver_check,
    ]
    actual = next((c["details"].split("=")[-1].split()[0] if "=" in c["details"] else c["details"]
                   for c in checks
                   if c["name"] in ("binary-version", "apt-version") and c["status"] == "ok"),
                  None)
    return report(COMPONENT_ID, expected, actual, checks, drift_allowed=True)


if __name__ == "__main__":
    sys.exit(main())
