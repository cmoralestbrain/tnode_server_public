#!/usr/bin/env python3
"""health-check.py — agrega verify_<id>.py + detecta drift contra manifest-latest.

Fase 4.3 del components-manifest plan. Corre en cada nodo (~/.openclaw/) y
escupe un JSON estructurado con el estado actual de todos los componentes:

  - lee ~/.openclaw/components-manifest.json (versiones actuales on-disk,
    escritas por write_components_manifest del installer);
  - opcionalmente fetch https://updates.tbrain.app/components-manifest-latest.json
    (versiones esperadas del último tag git);
  - por cada componente con verify_<id>.py disponible, ejecuta el verify y
    captura status + checks;
  - calcula drift entre versionActual y versionExpected;
  - agrega todo a un JSON con summary + exit code 0/1/2.

Stdlib only (urllib + subprocess + json). El script se distribuye via
install.tbrain.app/scripts/health-check.py y se ejecuta por curl+pipe.

Uso:
  curl -fsSL https://health.tbrain.app | bash         # via wrapper
  python3 health-check.py                             # local
  python3 health-check.py --no-fetch-latest           # sin red
  python3 health-check.py --updates-url URL           # override updates source

Exit codes:
  0  todos los componentes OK + sin drift bloqueante
  1  warn — drift detectado (incluso si driftAllowed=true) o algún verify warn
  2  fail — al menos un verify fail O fetch del manifest-latest falló sin
     --no-fetch-latest
"""
from __future__ import annotations

__VERSION__ = "1.1.0"

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DEFAULT_OPENCLAW_HOME = Path.home() / ".openclaw"
DEFAULT_UPDATES_URL = "https://updates.tbrain.app/components-manifest-latest.json"
FETCH_TIMEOUT_S = 10


def _err(msg: str) -> None:
    print(f"[health-check] {msg}", file=sys.stderr)


def load_local_manifest(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise SystemExit(
            f"local manifest not found: {path}. Run the installer at least once."
        )
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as e:
        raise SystemExit(f"local manifest is not valid JSON: {e}") from e


def fetch_latest_manifest(url: str) -> dict[str, Any] | None:
    req = urllib.request.Request(url, headers={"User-Agent": "tnode-health-check/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=FETCH_TIMEOUT_S) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError) as e:
        _err(f"fetch latest manifest failed ({type(e).__name__}): {e}")
        return None


def index_by_id(components: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {c["id"]: c for c in components if "id" in c}


def run_verify(verify_dir: Path, comp_id: str) -> dict[str, Any]:
    """Run verify_<id>.py and return its parsed JSON output + verifyStatus.

    Exit code semantics (per Fase 2 contract):
      0 = ok, 1 = warn, 2+ = fail.
    """
    script = verify_dir / f"verify_{comp_id}.py"
    if not script.is_file():
        return {"verifyStatus": "skipped", "reason": f"no verify_{comp_id}.py", "raw": None}

    try:
        proc = subprocess.run(
            [sys.executable, str(script)],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        return {"verifyStatus": "fail", "reason": "verify timed out (30s)", "raw": None}
    except OSError as e:
        return {"verifyStatus": "fail", "reason": f"exec failed: {e}", "raw": None}

    raw = None
    if proc.stdout.strip():
        try:
            raw = json.loads(proc.stdout)
        except json.JSONDecodeError:
            raw = {"_unparsed_stdout": proc.stdout.strip()[:500]}

    rc = proc.returncode
    if rc == 0:
        status = "ok"
    elif rc == 1:
        status = "warn"
    else:
        status = "fail"

    return {
        "verifyStatus": status,
        "exitCode": rc,
        "stderr": proc.stderr.strip()[:500] or None,
        "raw": raw,
    }


def compute_drift(
    actual: str, expected: str | None, drift_allowed: bool
) -> tuple[str, str | None]:
    """Returns (drift_label, severity) where severity ∈ {ok, warn, fail}.

    Labels:
      none      — actual == expected
      unknown   — expected is null/missing/unknown OR actual is unknown
      outdated  — actual != expected and drift not allowed
      drift-ok  — actual != expected but driftAllowed=true (e.g. cloudflared)
    """
    if expected is None or expected in ("unknown", "latest"):
        return "unknown", "ok"
    if actual in ("unknown", ""):
        return "unknown", "warn"
    if actual == expected:
        return "none", "ok"
    if drift_allowed:
        return "drift-ok", "warn"
    return "outdated", "warn"


def aggregate(
    local_components: list[dict[str, Any]],
    expected_index: dict[str, dict[str, Any]] | None,
    verify_dir: Path,
) -> dict[str, Any]:
    rows: list[dict[str, Any]] = []
    summary = {"total": 0, "ok": 0, "warn": 0, "fail": 0, "skipped": 0,
               "drift": 0, "manifestStale": 0}

    for comp in local_components:
        comp_id = comp.get("id")
        if not comp_id:
            continue
        summary["total"] += 1

        manifest_v = comp.get("version", "unknown")
        kind = comp.get("kind", "unknown")
        drift_allowed = bool(comp.get("driftAllowed", False))

        expected_v: str | None = None
        if expected_index is not None:
            expected_v = (expected_index.get(comp_id) or {}).get("version")

        # El verify corre ANTES de calcular el drift, a propósito: mide lo que
        # hay en disco AHORA, mientras que el manifiesto sólo dice lo que había
        # la última vez que corrió el installer. Cuando algo actualiza los
        # daemons sin regenerarlo —un sync externo, una copia a mano— el
        # manifiesto queda obsoleto y el drift calculado sobre él es ficción.
        # Visto en clawpi el 2026-07-27: manifiesto del 21 de mayo con 1.12.0 /
        # 1.4.0 / 1.9.0, ficheros del 24 de julio con 1.33.0 / 1.59.0 / 1.19.0,
        # y el health-check reportando "outdated" en tres daemons que estaban
        # perfectamente al día.
        verify_result = run_verify(verify_dir, comp_id)
        vs = verify_result["verifyStatus"]
        summary[vs if vs in summary else "skipped"] += 1

        measured_v = (verify_result.get("raw") or {}).get("versionActual") or "unknown"

        # Manda lo medido; el manifiesto es fuente de segunda mano.
        actual_v = measured_v if measured_v != "unknown" else manifest_v

        # Un manifiesto desincronizado es un problema real y se reporta como tal,
        # en vez de dejar que se disfrace de drift. Sólo se marca cuando ambas
        # versiones son reales y distintas: "system" / "latest" / "unknown" en el
        # manifiesto son valores por diseño (cloudflared, qrencode), no
        # desincronía.
        placeholders = ("unknown", "system", "latest", "")
        manifest_stale = (
            manifest_v not in placeholders
            and measured_v not in placeholders
            and manifest_v != measured_v
        )
        if manifest_stale:
            summary["manifestStale"] = summary.get("manifestStale", 0) + 1

        drift_label, drift_severity = compute_drift(actual_v, expected_v, drift_allowed)
        if drift_label not in ("none", "unknown"):
            summary["drift"] += 1

        row = {
            "id":              comp_id,
            "kind":            kind,
            "versionActual":   actual_v,
            "versionExpected": expected_v,
            "drift":           drift_label,
            "driftSeverity":   drift_severity,
            "verifyStatus":    vs,
            "verify":          verify_result,
        }
        if manifest_stale:
            row["manifestStale"] = True
            row["versionManifest"] = manifest_v
        rows.append(row)

    return {"components": rows, "summary": summary}


def overall_exit_code(summary: dict[str, int]) -> int:
    if summary.get("fail", 0) > 0:
        return 2
    # manifestStale entra como warn: no es una caída, pero es accionable —se
    # arregla con un `curl update.tbrain.app/update.sh | bash`, que regenera el
    # manifiesto— y silenciarlo es lo que dejaba pasar el drift ficticio.
    if (summary.get("warn", 0) > 0
            or summary.get("drift", 0) > 0
            or summary.get("manifestStale", 0) > 0):
        return 1
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Health check + drift detection for TNode components"
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=DEFAULT_OPENCLAW_HOME / "components-manifest.json",
        help="Path to local components-manifest.json (default: ~/.openclaw/...)",
    )
    parser.add_argument(
        "--verify-dir",
        type=Path,
        default=DEFAULT_OPENCLAW_HOME / "verify",
        help="Directory with verify_<id>.py (default: ~/.openclaw/verify)",
    )
    parser.add_argument(
        "--updates-url",
        default=os.environ.get("UPDATES_URL", DEFAULT_UPDATES_URL),
        help="URL of components-manifest-latest.json (default: updates.tbrain.app)",
    )
    parser.add_argument(
        "--no-fetch-latest",
        action="store_true",
        help="Skip fetching expected versions; report only actual + verify status",
    )
    parser.add_argument(
        "--no-pretty",
        action="store_true",
        help="Compact JSON output (no indentation)",
    )
    args = parser.parse_args(argv)

    local = load_local_manifest(args.manifest)
    local_components = local.get("components", [])

    expected_index: dict[str, dict[str, Any]] | None = None
    expected_meta: dict[str, Any] = {}
    if not args.no_fetch_latest:
        latest = fetch_latest_manifest(args.updates_url)
        if latest is None:
            # Couldn't reach updates source — continue without drift detection.
            # Don't fail hard; the operator may be offline or behind a firewall.
            expected_meta = {"fetched": False, "url": args.updates_url}
        else:
            expected_index = index_by_id(latest.get("components", []))
            expected_meta = {
                "fetched": True,
                "url":     args.updates_url,
                "tag":     latest.get("tag"),
                "generatedAt": latest.get("generatedAt"),
            }
    else:
        expected_meta = {"fetched": False, "skipped": True}

    agg = aggregate(local_components, expected_index, args.verify_dir)
    rc = overall_exit_code(agg["summary"])

    output = {
        "schemaVersion":    1,
        "generatedAt":      datetime.now(timezone.utc).isoformat(),
        "host":             os.uname().nodename if hasattr(os, "uname") else None,
        "localManifest":    {
            "schemaVersion": local.get("schemaVersion"),
            "generatedAt":   local.get("generatedAt"),
        },
        "expectedManifest": expected_meta,
        "components":       agg["components"],
        "summary":          agg["summary"],
        "exitCode":         rc,
    }

    indent = None if args.no_pretty else 2
    print(json.dumps(output, indent=indent, default=str))
    return rc


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
