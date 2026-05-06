#!/usr/bin/env python3
"""verify_plugin-skill — verify genérico para skills no-daemon con manifest.json.

Usage: verify_plugin-skill.py <skill-dir>

Lee <skill-dir>/manifest.json y valida:
  - JSON parseable
  - Campos requeridos: name, version, type, entrypoint
  - name coincide con basename(skill-dir)
  - entrypoint apunta a archivo existente
  - version coincide con la registrada en components-manifest.json del nodo

Ejemplo: verify_plugin-skill.py ~/.openclaw/skills/agentmail
"""
from __future__ import annotations
__VERSION__ = "1.0.0"

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_common import find_self, report  # noqa: E402


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    skill_dir = Path(sys.argv[1]).expanduser().resolve()
    skill_name = skill_dir.name
    manifest_path = skill_dir / "manifest.json"
    checks = []
    actual = None

    if not manifest_path.exists():
        checks.append({"name": "manifest-exists", "status": "fail",
                       "details": f"manifest.json missing at {manifest_path}"})
        return report(skill_name, "unknown", None, checks)
    checks.append({"name": "manifest-exists", "status": "ok",
                   "details": str(manifest_path)})

    try:
        m = json.loads(manifest_path.read_text())
    except Exception as e:
        checks.append({"name": "json-valid", "status": "fail",
                       "details": f"parse error: {e}"})
        return report(skill_name, "unknown", None, checks)
    checks.append({"name": "json-valid", "status": "ok", "details": "parsed"})

    required = ("name", "version", "type", "entrypoint")
    missing = [k for k in required if not m.get(k)]
    if missing:
        checks.append({"name": "required-fields", "status": "fail",
                       "details": f"missing: {', '.join(missing)}"})
        return report(skill_name, "unknown", None, checks)
    checks.append({"name": "required-fields", "status": "ok",
                   "details": f"all 4 present"})

    if m["name"] != skill_name:
        checks.append({"name": "name-match", "status": "fail",
                       "details": f"manifest.name={m['name']} ≠ dir={skill_name}"})
    else:
        checks.append({"name": "name-match", "status": "ok",
                       "details": f"name={skill_name}"})

    entrypoint = skill_dir / m["entrypoint"]
    if not entrypoint.exists():
        checks.append({"name": "entrypoint-exists", "status": "fail",
                       "details": f"{m['entrypoint']} not found"})
    else:
        checks.append({"name": "entrypoint-exists", "status": "ok",
                       "details": m["entrypoint"]})

    actual = m["version"]
    entry = find_self(skill_name)
    expected = entry.get("version") if entry else m["version"]
    if expected != actual:
        checks.append({"name": "version-match", "status": "fail",
                       "details": f"manifest={actual} but registry expects={expected}"})
    else:
        checks.append({"name": "version-match", "status": "ok",
                       "details": f"version={actual}"})

    return report(skill_name, expected, actual, checks)


if __name__ == "__main__":
    sys.exit(main())
