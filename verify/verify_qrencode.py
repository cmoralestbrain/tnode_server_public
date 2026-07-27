#!/usr/bin/env python3
"""verify_qrencode — health check del generador de QR (driftAllowed=true).

Se usa para pintar el QR de emparejamiento (`tnode-qr`). No es un daemon: no
hay unit que comprobar, sólo que el binario esté presente y responda.

Hasta v1.90.0 este verify no existía y el componente salía siempre como
`skipped` en el health-check: nunca se comprobaba nada de él.
"""
from __future__ import annotations
__VERSION__ = "1.0.0"

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_common import (  # noqa: E402
    check_apt_version,
    check_binary_version,
    find_self,
    report,
)

COMPONENT_ID = "qrencode"
PACKAGE_NAME = "qrencode"


def main() -> int:
    entry = find_self(COMPONENT_ID)
    # El manifiesto lo registra como "system" (kind=binary-os, driftAllowed).
    expected = entry.get("version") if entry else "system"

    # El binario manda. En Linux suele venir de apt (/usr/bin/qrencode) y en
    # Mac de brew, pero lo que importa es que exista y responda: se comprueba
    # primero con `qrencode --version` y apt/brew queda como fallback para el
    # caso de que el binario no esté en el PATH del usuario que corre el verify.
    ver_check = check_binary_version(PACKAGE_NAME)
    if ver_check["status"] != "ok":
        ver_check = check_apt_version(PACKAGE_NAME)

    checks = [ver_check]

    actual = next((c["details"].split("=")[-1].split()[0] if "=" in c["details"] else c["details"]
                   for c in checks
                   if c["name"] in ("binary-version", "apt-version") and c["status"] == "ok"),
                  None)
    return report(COMPONENT_ID, expected, actual, checks, drift_allowed=True)


if __name__ == "__main__":
    sys.exit(main())
