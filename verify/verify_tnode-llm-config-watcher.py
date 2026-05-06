#!/usr/bin/env python3
"""verify_tnode-llm-config-watcher — deprecation gate.

The legacy llm-config-watcher daemon was retired in favor of tnode-config-sync
(v1.5.2 / 2026-04-19). It must NOT exist on any node — its presence indicates
a zombie install that was never cleaned up. Reports fail with status=2 so
health-check.py / smoke-test in the installer flag it for the operator.

Cleanup recipe (paste into the affected node):
    systemctl --user disable --now tnode-llm-config-watcher 2>/dev/null || true
    launchctl unload ~/Library/LaunchAgents/com.tbrain.llm-config-watcher.plist 2>/dev/null || true
    rm -f ~/.openclaw/scripts/llm_config_watcher.py
    rm -f ~/.config/systemd/user/tnode-llm-config-watcher.service
    rm -f ~/Library/LaunchAgents/com.tbrain.llm-config-watcher.plist
"""
from __future__ import annotations
__VERSION__ = "1.0.0"

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_common import find_self, report  # noqa: E402

COMPONENT_ID = "tnode-llm-config-watcher"

# Files that should NOT exist on a clean node.
LEGACY_PATHS = [
    Path.home() / ".openclaw" / "scripts" / "llm_config_watcher.py",
    Path.home() / ".config" / "systemd" / "user" / "tnode-llm-config-watcher.service",
    Path.home() / "Library" / "LaunchAgents" / "com.tbrain.llm-config-watcher.plist",
]


def check_no_legacy_files() -> dict:
    found = [str(p) for p in LEGACY_PATHS if p.exists()]
    if found:
        return {
            "name": "deprecated-files-absent",
            "status": "fail",
            "details": (
                f"deprecated files present ({len(found)}): "
                + ", ".join(found)
                + ". Remove per cleanup recipe in the verify script header."
            ),
        }
    return {
        "name": "deprecated-files-absent",
        "status": "ok",
        "details": "no legacy llm-config-watcher artifacts found",
    }


def main() -> int:
    entry = find_self(COMPONENT_ID)
    # The component MAY appear in a stale manifest with a real version; we
    # don't care — the only thing we care about is the file system being clean.
    expected = (entry or {}).get("version", "deprecated")
    checks = [check_no_legacy_files()]
    return report(COMPONENT_ID, expected, "deprecated", checks)


if __name__ == "__main__":
    sys.exit(main())
