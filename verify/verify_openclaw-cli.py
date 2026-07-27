#!/usr/bin/env python3
"""verify_openclaw-cli — health check del CLI de OpenClaw.

El CLI y el gateway salen del MISMO package npm (`openclaw`): el installer hace
`npm install -g openclaw@<pin>` y de ahí salen los dos. Por eso este verify
comparte el check de npm con verify_openclaw-gateway; lo que añade es que el
binario `openclaw` esté realmente en el PATH y responda, que es lo que usan
`tnode-config-sync` (`openclaw daemon restart`, `openclaw plugins enable`) y el
propio installer.

No hay unit que comprobar: el CLI no es un servicio. La liveness del gateway la
cubre verify_openclaw-gateway.

Hasta v1.90.0 este verify no existía y el componente salía siempre como
`skipped` en el health-check.
"""
from __future__ import annotations
__VERSION__ = "1.1.0"

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_common import (  # noqa: E402
    check_binary_version,
    check_npm_version,
    find_self,
    report,
)

COMPONENT_ID = "openclaw-cli"
# Un solo package provee gateway y CLI. `@openclaw/cli` no existe en el
# registry — ese nombre equivocado es lo que hacía que el manifiesto grabara
# "unknown" para este componente en todos los nodos hasta v1.88.0.
NPM_PACKAGE = "openclaw"
BINARY = "openclaw"


def main() -> int:
    entry = find_self(COMPONENT_ID)
    expected = entry.get("version") if entry else "unknown"

    # Las mismas rutas que resuelve `_openclaw_binary()` en tnode-config-sync.
    # Si el daemon puede ejecutarlo, el verify no debe decir que falta.
    extra = [
        Path.home() / ".local" / "bin" / BINARY,
        Path.home() / ".npm-global" / "bin" / BINARY,
        Path("/usr/local/bin") / BINARY,
        Path("/opt/homebrew/bin") / BINARY,
    ]

    checks = [
        check_npm_version(NPM_PACKAGE),
        check_binary_version(BINARY, extra_paths=extra),
    ]

    # La versión de npm es la autoritativa; el binario puede reportar un formato
    # distinto ("OpenClaw 2026.6.10 (aa69b12)") y sólo se usa como respaldo.
    actual = next((c["details"].split("@")[-1]
                   for c in checks
                   if c["name"] == "npm-version" and c["status"] == "ok"), None)
    if actual is None:
        actual = next((c["details"].split("=")[-1].split()[0]
                       for c in checks
                       if c["name"] == "binary-version" and c["status"] == "ok"), None)

    return report(COMPONENT_ID, expected, actual, checks)


if __name__ == "__main__":
    sys.exit(main())
