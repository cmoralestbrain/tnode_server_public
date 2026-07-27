#!/usr/bin/env python3
"""verify_pair-watch — health check del auto-approver de device pairing."""
from __future__ import annotations
__VERSION__ = "1.2.0"

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_common import (  # noqa: E402
    check_json_valid,
    check_script_version,
    check_service_active,
    check_start_limit_disabled,
    find_self,
    report,
)

COMPONENT_ID = "pair-watch"
# En Linux lo que debe estar activo es la .path, no la .service: la service es
# un oneshot que dispara la path cuando cambia pending.json, y su estado en
# reposo es `inactive` (viene además `disabled`, porque la que se habilita es
# la path). Mirar la .service daba fail permanente en nodos Linux sanos.
# En Mac es un LaunchAgent único con WatchPaths, así que ahí vale el label.
SERVICE_NAME = "pair-watch.path"
DARWIN_LABEL = "com.tbrain.pair-watch"
SCRIPT_PATH = Path.home() / ".openclaw" / "scripts" / "pair_watch.py"
CONFIG_PATH = Path.home() / ".openclaw" / "pair-watch.json"


def main() -> int:
    entry = find_self(COMPONENT_ID)
    expected = entry.get("version") if entry else "unknown"

    checks = [
        check_service_active(SERVICE_NAME, darwin_label=DARWIN_LABEL),
        # Las dos units necesitan el guard: la .service es la que agota el
        # límite de arranques, y la .path cae detrás por unit-start-limit-hit.
        check_start_limit_disabled("pair-watch.service"),
        check_start_limit_disabled(SERVICE_NAME),
        check_script_version(SCRIPT_PATH, expected),
        check_json_valid(CONFIG_PATH),
    ]
    actual = next((c["details"].split("=")[1].split()[0]
                   for c in checks if c["name"] == "script-version" and c["status"] == "ok"),
                  None)
    return report(COMPONENT_ID, expected, actual, checks)


if __name__ == "__main__":
    sys.exit(main())
