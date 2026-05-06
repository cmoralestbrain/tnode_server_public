#!/usr/bin/env python3
"""verify_plugin-npm — verify genérico para extensions OpenClaw instaladas via npm.

Usage: verify_plugin-npm.py <component-id> <npm-package-name>

Ejemplo: verify_plugin-npm.py openclaw-web-search @openclaw/web-search
"""
from __future__ import annotations
__VERSION__ = "1.0.0"

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_common import check_npm_version, find_self, report  # noqa: E402


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    component_id, npm_package = sys.argv[1], sys.argv[2]

    entry = find_self(component_id)
    expected = entry.get("version") if entry else "unknown"

    checks = [check_npm_version(npm_package)]
    actual = None
    if checks[0]["status"] == "ok":
        actual = checks[0]["details"].split("@")[-1]

    return report(component_id, expected, actual, checks, drift_allowed=True)


if __name__ == "__main__":
    sys.exit(main())
