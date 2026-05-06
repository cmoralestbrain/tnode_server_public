#!/usr/bin/env python3
"""verify_common — helpers compartidos por los verify_<comp>.py de Fase 2.

Cada verify_<comp>.py importa este módulo y construye una lista de checks. El
output al stdout sigue el schema acordado en Fase 1:

    {
      "component":        "<id>",
      "versionExpected":  "X.Y.Z",
      "versionActual":    "X.Y.Z" | "unknown",
      "status":           "ok" | "warn" | "fail",
      "checks": [
        {"name": "<check>", "status": "ok|warn|fail", "details": "..."},
        ...
      ],
      "error":            null | "<message>"
    }

Exit codes:
  0 → status == "ok"
  1 → status == "warn" (e.g. cloudflared driftAllowed)
  2 → status == "fail"

Stdlib only (Python 3.9+). Diseñado para correr en Mac/Linux sin deps externas.
"""
from __future__ import annotations
__VERSION__ = "1.0.0"

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional

CheckResult = dict
ChecksList = list


def _run(cmd: list[str], timeout: int = 5) -> tuple[int, str, str]:
    """Run subprocess, return (rc, stdout, stderr). Never raises."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except FileNotFoundError:
        return 127, "", f"command not found: {cmd[0]}"
    except subprocess.TimeoutExpired:
        return 124, "", f"timeout after {timeout}s"
    except Exception as e:
        return 1, "", f"{type(e).__name__}: {e}"


def load_manifest(path: Path) -> Optional[dict]:
    """Lee components-manifest.json o manifest.json. Devuelve None si no existe."""
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def find_self(component_id: str, manifest_path: Optional[Path] = None) -> Optional[dict]:
    """Localiza la entry del componente en el components-manifest.json del nodo."""
    mp = manifest_path or Path.home() / ".openclaw" / "components-manifest.json"
    m = load_manifest(mp)
    if not m:
        return None
    for entry in m.get("components", []):
        if entry.get("id") == component_id:
            return entry
    return None


def check_service_active(service_name: str,
                         darwin_label: Optional[str] = None) -> CheckResult:
    """Linux: `systemctl --user is-active <service_name>`.
    macOS: `launchctl print gui/<uid>/<darwin_label>` (LaunchAgents live in
    the user-level domain, not system/). If darwin_label is None, default
    to `com.tbrain.<service_name>` — the convention for TBrain daemons.
    Pass an explicit label for non-TBrain services like cloudflared
    (`com.cloudflare.cloudflared`) or openclaw-gateway (`ai.openclaw.gateway`).
    """
    if sys.platform == "darwin":
        import os
        label = darwin_label or f"com.tbrain.{service_name}"
        rc, out, _ = _run(["launchctl", "print", f"gui/{os.getuid()}/{label}"])
        if rc == 0 and "state = running" in out:
            return {"name": "service-active", "status": "ok",
                    "details": f"launchd: {label} running"}
        return {"name": "service-active", "status": "fail",
                "details": f"launchd: {label} not running (rc={rc})"}
    # Linux: try user service first (matches install_*_systemd in installer),
    # fall back to system service for legacy installs.
    rc, out, _ = _run(["systemctl", "--user", "is-active", service_name])
    if rc == 0 and out == "active":
        return {"name": "service-active", "status": "ok",
                "details": f"systemd --user: {service_name} active"}
    rc, out, _ = _run(["systemctl", "is-active", service_name])
    if rc == 0 and out == "active":
        return {"name": "service-active", "status": "ok",
                "details": f"systemd: {service_name} active"}
    return {"name": "service-active", "status": "fail",
            "details": f"systemd: {service_name} status={out or 'unknown'}"}


def check_script_sha256(script_path: Path, expected_sha: Optional[str]) -> CheckResult:
    """Compara sha256 del script con el esperado. Si expected es None, solo computa."""
    if not script_path.exists():
        return {"name": "script-sha256", "status": "fail",
                "details": f"script not found: {script_path}"}
    h = hashlib.sha256(script_path.read_bytes()).hexdigest()
    if expected_sha is None:
        return {"name": "script-sha256", "status": "ok",
                "details": f"sha256={h[:16]}… (no expected to compare)"}
    if h == expected_sha:
        return {"name": "script-sha256", "status": "ok",
                "details": f"sha256 matches: {h[:16]}…"}
    return {"name": "script-sha256", "status": "fail",
            "details": f"sha256 drift: actual={h[:16]}… expected={expected_sha[:16]}…"}


def check_script_version(script_path: Path, expected_version: str) -> CheckResult:
    """Extrae __VERSION__ del header del script y compara."""
    if not script_path.exists():
        return {"name": "script-version", "status": "fail",
                "details": f"script not found: {script_path}"}
    actual = None
    with script_path.open() as f:
        for i, line in enumerate(f):
            if i > 60:
                break
            m = re.match(r'^__VERSION__\s*=\s*"([^"]+)"\s*$', line)
            if m:
                actual = m.group(1)
                break
    if actual is None:
        return {"name": "script-version", "status": "fail",
                "details": "no __VERSION__ header in first 60 lines"}
    if actual == expected_version:
        return {"name": "script-version", "status": "ok",
                "details": f"version={actual} matches expected"}
    return {"name": "script-version", "status": "fail",
            "details": f"version drift: actual={actual} expected={expected_version}"}


def check_http_probe(url: str, timeout: int = 3,
                     expect_status: tuple[int, ...] = (200,)) -> CheckResult:
    """GET el URL, valida status. WebSocket URLs (ws://) se chequean como TCP connect."""
    if url.startswith("ws://") or url.startswith("wss://"):
        import socket
        host_port = url.split("://", 1)[1].split("/", 1)[0]
        host, _, port_s = host_port.partition(":")
        port = int(port_s) if port_s else (443 if url.startswith("wss") else 80)
        try:
            with socket.create_connection((host, port), timeout=timeout):
                return {"name": "http-probe", "status": "ok",
                        "details": f"tcp connect to {host}:{port} OK"}
        except Exception as e:
            return {"name": "http-probe", "status": "fail",
                    "details": f"tcp connect to {host}:{port} failed: {e}"}
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status in expect_status:
                return {"name": "http-probe", "status": "ok",
                        "details": f"GET {url} → {resp.status}"}
            return {"name": "http-probe", "status": "fail",
                    "details": f"GET {url} → {resp.status} (expected {expect_status})"}
    except urllib.error.HTTPError as e:
        if e.code in expect_status:
            return {"name": "http-probe", "status": "ok",
                    "details": f"GET {url} → {e.code}"}
        return {"name": "http-probe", "status": "fail",
                "details": f"GET {url} → {e.code}"}
    except Exception as e:
        return {"name": "http-probe", "status": "fail",
                "details": f"GET {url} failed: {type(e).__name__}: {e}"}


def check_json_valid(path: Path) -> CheckResult:
    """Parse JSON al disco; reporta ok/fail."""
    if not path.exists():
        return {"name": "json-valid", "status": "fail",
                "details": f"not found: {path}"}
    try:
        json.loads(path.read_text())
        return {"name": "json-valid", "status": "ok",
                "details": f"{path} is valid JSON"}
    except Exception as e:
        return {"name": "json-valid", "status": "fail",
                "details": f"{path} parse error: {e}"}


def check_log_progress(log_path: Path, max_age_seconds: int = 120) -> CheckResult:
    """Verifica que el log file haya sido escrito en los últimos N segundos."""
    if not log_path.exists():
        return {"name": "log-progress", "status": "warn",
                "details": f"log file not found: {log_path}"}
    age = time.time() - log_path.stat().st_mtime
    if age <= max_age_seconds:
        return {"name": "log-progress", "status": "ok",
                "details": f"log mtime age={age:.0f}s (≤{max_age_seconds}s)"}
    return {"name": "log-progress", "status": "warn",
            "details": f"log stale: age={age:.0f}s > {max_age_seconds}s"}


def check_npm_version(package_name: str) -> CheckResult:
    """Extrae la version del package npm globalmente instalado."""
    if shutil.which("npm") is None:
        return {"name": "npm-version", "status": "fail", "details": "npm no encontrado"}
    rc, out, err = _run(["npm", "ls", "-g", "--json", "--depth=0", package_name], timeout=15)
    if rc != 0 and not out:
        return {"name": "npm-version", "status": "fail",
                "details": f"npm ls failed: {err or 'rc='+str(rc)}"}
    try:
        data = json.loads(out)
        version = data.get("dependencies", {}).get(package_name, {}).get("version")
        if not version:
            return {"name": "npm-version", "status": "fail",
                    "details": f"package {package_name} not installed globally"}
        return {"name": "npm-version", "status": "ok",
                "details": f"{package_name}@{version}"}
    except json.JSONDecodeError as e:
        return {"name": "npm-version", "status": "fail",
                "details": f"npm ls JSON parse error: {e}"}


def check_apt_version(package_name: str) -> CheckResult:
    """Linux: dpkg-query la version. Mac: brew list."""
    if sys.platform == "darwin":
        rc, out, _ = _run(["brew", "list", "--versions", package_name], timeout=10)
        if rc == 0 and out:
            return {"name": "apt-version", "status": "ok",
                    "details": f"brew: {out}"}
        return {"name": "apt-version", "status": "warn",
                "details": f"brew: {package_name} not installed"}
    rc, out, _ = _run(["dpkg-query", "-W", "-f=${Version}", package_name], timeout=5)
    if rc == 0 and out:
        return {"name": "apt-version", "status": "ok",
                "details": f"apt: {package_name}={out}"}
    return {"name": "apt-version", "status": "warn",
            "details": f"apt: {package_name} not installed (rc={rc})"}


def report(component: str, version_expected: str, version_actual: Optional[str],
           checks: ChecksList, error: Optional[str] = None,
           drift_allowed: bool = False) -> int:
    """Imprime el JSON estructurado a stdout y retorna el exit code."""
    statuses = [c["status"] for c in checks]
    if error:
        status = "fail"
    elif "fail" in statuses:
        status = "warn" if drift_allowed and statuses.count("fail") == sum(
            1 for c in checks if c["name"] == "apt-version") else "fail"
    elif "warn" in statuses:
        status = "warn"
    else:
        status = "ok"

    payload = {
        "component": component,
        "versionExpected": version_expected,
        "versionActual": version_actual or "unknown",
        "status": status,
        "checks": checks,
        "error": error,
    }
    print(json.dumps(payload, indent=2))

    if status == "ok":
        return 0
    if status == "warn":
        return 1
    return 2


if __name__ == "__main__":
    print("verify_common is a library; import from verify_<comp>.py", file=sys.stderr)
    sys.exit(2)
