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
__VERSION__ = "1.4.0"

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
                         darwin_label: Optional[str] = None,
                         soft: bool = False) -> CheckResult:
    """Linux: `systemctl --user is-active <service_name>`.
    macOS: `launchctl print gui/<uid>/<darwin_label>` (LaunchAgents live in
    the user-level domain, not system/). If darwin_label is None, default
    to `com.tbrain.<service_name>` — the convention for TBrain daemons.
    Pass an explicit label for non-TBrain services like cloudflared
    (`com.cloudflare.cloudflared`) or openclaw-gateway (`ai.openclaw.gateway`).

    soft=True es para componentes que pueden legítimamente no tener unit y
    cuya liveness la demuestra otro check — el gateway lo arranca el CLI de
    openclaw, no una unit nuestra, y ahí el probe al WS es la señal que vale.
    En ese modo se distingue no-existe de existe-pero-muerta:

      - unit ausente  → ok   (arquitectura esperada, no hay nada que reportar)
      - unit presente pero inactive → fail (eso sí es un problema real)

    Sin la distinción quedaba un warn perpetuo en cada nodo Linux, que es
    otra forma de ruido: enseña a ignorar el check igual que un fail fijo.
    """
    miss = "warn" if soft else "fail"
    if sys.platform == "darwin":
        import os
        label = darwin_label or f"com.tbrain.{service_name}"
        rc, out, _ = _run(["launchctl", "print", f"gui/{os.getuid()}/{label}"])
        if rc == 0 and "state = running" in out:
            return {"name": "service-active", "status": "ok",
                    "details": f"launchd: {label} running"}
        # Un LaunchAgent con WatchPaths y SIN KeepAlive sólo corre cuando el
        # fichero vigilado cambia: `state = not running` es su reposo correcto,
        # no una caída. Es el equivalente macOS del oneshot disparado por .path
        # que se arregló para Linux en v1.88.0 — allí se mira la .path, aquí se
        # mira si el agente está CARGADO y no ha salido con error.
        # Visto en el mini (2026-07-28): pair-watch daba fail permanente con
        # WatchPaths sobre devices/pending.json y "last exit code (never exited)".
        if rc == 0 and "WatchPaths" in out and "KeepAlive" not in out:
            if "last exit code = 0" in out or "never exited" in out:
                return {"name": "service-active", "status": "ok",
                        "details": f"launchd: {label} cargado, en espera "
                                   "(WatchPaths sin KeepAlive)"}
            return {"name": "service-active", "status": miss,
                    "details": f"launchd: {label} en espera pero salió con error"}
        return {"name": "service-active", "status": miss,
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
    if soft:
        # ¿Existe siquiera la unit? `systemctl cat` falla con "No files found"
        # cuando no hay fichero, tanto en --user como en system.
        absent = all(_run(scope + ["cat", service_name])[0] != 0
                     for scope in (["systemctl", "--user"], ["systemctl"]))
        if absent:
            return {"name": "service-active", "status": "ok",
                    "details": f"systemd: sin unit {service_name} "
                               "(gestionado por el CLI de openclaw)"}
        return {"name": "service-active", "status": "fail",
                "details": f"systemd: {service_name} existe pero status={out or 'unknown'}"}
    return {"name": "service-active", "status": miss,
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
    """Extrae __VERSION__ del header del script y compara.

    Escanea el fichero ENTERO, no un prefijo. Hasta v1.0.2 sólo se miraban
    las primeras 60 líneas y los daemons habían crecido por encima de ese
    límite (chat-sync 124, config-sync 356, telemetry 66), así que los tres
    reportaban "unknown" / fail en nodos perfectamente al día — y con ello
    la detección de drift quedaba ciega para todos los daemons. El regex
    está anclado a inicio de línea, y gana la primera coincidencia, así que
    el header a nivel de módulo siempre se resuelve antes que cualquier
    aparición posterior dentro de un string.
    """
    if not script_path.exists():
        return {"name": "script-version", "status": "fail",
                "details": f"script not found: {script_path}"}
    actual = None
    with script_path.open() as f:
        for line in f:
            m = re.match(r'^__VERSION__\s*=\s*"([^"]+)"\s*$', line)
            if m:
                actual = m.group(1)
                break
    if actual is None:
        return {"name": "script-version", "status": "fail",
                "details": "no __VERSION__ header found"}
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


def check_log_progress(log_path, max_age_seconds: int = 120) -> CheckResult:
    """Verifica que el log file haya sido escrito en los últimos N segundos.

    Acepta un Path o una lista de candidatos. Con lista se queda con el más
    reciente de los que existan: no todos los daemons escriben su propio
    `<id>.log` — telemetry, por ejemplo, sólo tiene los `.out.log` / `.err.log`
    que redirige la unit, y buscar un único nombre fijo daba "log file not
    found" en nodos perfectamente vivos.
    """
    candidates = [log_path] if isinstance(log_path, Path) else list(log_path)
    existing = [p for p in candidates if p.exists()]
    if existing:
        log_path = max(existing, key=lambda p: p.stat().st_mtime)
    else:
        shown = ", ".join(str(p) for p in candidates)
        return {"name": "log-progress", "status": "warn",
                "details": f"log file not found: {shown}"}
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


def check_start_limit_disabled(unit: str) -> CheckResult:
    """Verifica que el burst guard de systemd esté desactivado en la unit.

    Con el default (StartLimitIntervalSec=10s / StartLimitBurst=5) systemd se
    rinde tras 5 arranques en 10s y deja la unit muerta hasta que alguien haga
    `reset-failed`. En cloudflared eso deja el túnel caído; en pair-watch, que
    es un oneshot disparado por una .path, basta una tanda de escrituras a
    pending.json para tumbarlo — ocurrió en clawpi el 2026-07-27.

    Los arreglos viven en drop-ins (v1.87.1 cloudflared, v1.88.2 pair-watch), y
    un drop-in se puede perder: `cloudflared service install` reescribe la unit,
    una reinstalación puede no repetir el drop-in, alguien lo borra. Sin este
    check nada delata la regresión — la unit sigue `active` y el resto de
    comprobaciones en verde hasta el día que se cae y no vuelve.

    warn, no fail: es un defecto de resiliencia, no una caída. El servicio
    está funcionando; lo que falta es la red de seguridad.
    """
    if sys.platform == "darwin":
        return {"name": f"start-limit:{unit}", "status": "skipped",
                "details": "launchd no tiene equivalente a StartLimitIntervalSec"}
    for scope in (["systemctl", "--user"], ["systemctl"]):
        if _run(scope + ["cat", unit])[0] != 0:
            continue
        rc, out, _ = _run(scope + ["show", unit, "-p", "StartLimitIntervalUSec"])
        value = out.split("=", 1)[1].strip() if "=" in out else ""
        if value == "0":
            return {"name": f"start-limit:{unit}", "status": "ok",
                    "details": f"{unit}: burst guard desactivado (StartLimitIntervalUSec=0)"}
        return {"name": f"start-limit:{unit}", "status": "warn",
                "details": f"{unit}: burst guard ACTIVO "
                           f"(StartLimitIntervalUSec={value or 'desconocido'}) — "
                           "falta el drop-in; la unit puede quedarse muerta tras "
                           "varios arranques seguidos"}
    return {"name": f"start-limit:{unit}", "status": "skipped",
            "details": f"no existe la unit {unit}"}


def check_binary_version(command: str, args: Optional[list] = None,
                        extra_paths: Optional[list] = None) -> CheckResult:
    """Versión de un binario suelto, vía `<command> --version`.

    Para lo que no viene de un package manager. cloudflared se instala
    descargando el binario de GitHub Releases a /usr/local/bin, así que
    dpkg-query nunca lo encuentra y `check_apt_version` avisaba de que "no
    está instalado" en todos los nodos Linux, con el túnel corriendo.

    extra_paths: rutas donde buscar si no está en el PATH. Lo que importa no es
    que el binario esté en el PATH del verify, sino que se pueda encontrar y
    ejecutar — que es lo que hacen los daemons, que resuelven por rutas
    conocidas. Sin esto, `openclaw` daba fail en clawpi (npm con prefijo de
    usuario, binario en ~/.npm-global/bin) aunque config-sync lo resolviera
    perfectamente: medir el PATH en vez de la usabilidad es la misma clase de
    falso positivo que se limpió en v1.88.0.
    """
    path = shutil.which(command)
    if path is None:
        for cand in (extra_paths or []):
            cand = Path(cand)
            if cand.is_file() and os.access(cand, os.X_OK):
                path = str(cand)
                break
    if path is None:
        return {"name": "binary-version", "status": "fail",
                "details": f"{command} no encontrado en PATH ni en rutas conocidas"}
    rc, out, err = _run([path] + (args or ["--version"]), timeout=10)
    blob = out or err
    if rc != 0 and not blob:
        return {"name": "binary-version", "status": "fail",
                "details": f"{command} --version falló (rc={rc})"}
    m = re.search(r"\d+\.\d+\.\d+", blob)
    if not m:
        return {"name": "binary-version", "status": "warn",
                "details": f"{path}: sin versión reconocible en {blob[:60]!r}"}
    return {"name": "binary-version", "status": "ok",
            "details": f"{command}={m.group(0)} ({path})"}


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


def check_python_module(module_name: str, *, required: bool = True) -> CheckResult:
    """Imports `module_name` via the same `python3` the daemons use and reports
    its `__version__` if available. `required=False` downgrades a missing
    module to `warn` (e.g. optional features). The shorthand details
    `<module>=<version>` lets manifests/installers grep the version field
    without parsing JSON twice."""
    rc, out, err = _run(
        ["python3", "-c",
         f"import {module_name} as m; "
         f"print(getattr(m, '__version__', 'unknown'))"],
        timeout=5,
    )
    if rc == 0 and out:
        version = out.strip()
        return {"name": f"python-{module_name}", "status": "ok",
                "details": f"{module_name}={version}"}
    status = "fail" if required else "warn"
    msg = err.strip() or f"rc={rc}"
    return {"name": f"python-{module_name}", "status": status,
            "details": f"import {module_name} failed: {msg}"}


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
