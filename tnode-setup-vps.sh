#!/usr/bin/env bash
# tnode-setup.sh — Configura un nodo completo para TNode en un solo comando.
#
# Instala y configura: Ollama + modelo LLM, OpenClaw, Cloudflare Tunnel (o Tailscale),
# tnode-qr y pair-watch (auto-approve pairing).
#
# Usage:
#   curl -fsSL https://install.tbrain.app | bash
#   bash tnode-setup.sh [OPTIONS]
#
# Options:
#   --yes, -y         Non-interactive (accept all defaults)
#   --no-ollama       Skip Ollama installation
#   --no-tunnel       Skip Cloudflare Tunnel (use --with-tailscale instead)
#   --with-tailscale  Install Tailscale alongside or instead of tunnel
#   --no-tailscale    Alias for default (Tailscale not installed by default)
#   --tunnel-token T  Pre-provisioned Cloudflare tunnel token
#   --no-qr           Skip QR display at the end
#   --model <name>    LLM model (default: auto-detect GPU → qwen3.5 / CPU → qwen3:1.7b)
#   --cloud           Use cloud model (kimi-k2.5:cloud) instead of local
#   --verbose         Enable debug output
#   --version         Print version and exit
set -euo pipefail

# ─────────────────────────────────────────────
# Auto-pair mode (cloud-provisioned droplets)
# ─────────────────────────────────────────────
# When TNODE_AUTO_PAIR=1 is set (by cloud-init user_data written by the
# provisionTNode Cloud Function), the installer reuses the pre-supplied
# nodeId / nodeSecret / ownerUid instead of generating fresh ones and
# showing a QR. BYO installs leave TNODE_AUTO_PAIR unset and execute the
# legacy path unchanged.
#
# See: tnode_client/architecture_cloud_provisioning.md §8
if [[ "${TNODE_AUTO_PAIR:-}" == "1" ]]; then
    : "${TNODE_NODE_ID:?TNODE_NODE_ID required when TNODE_AUTO_PAIR=1}"
    : "${TNODE_NODE_SECRET:?TNODE_NODE_SECRET required when TNODE_AUTO_PAIR=1}"
    : "${TNODE_OWNER_UID:?TNODE_OWNER_UID required when TNODE_AUTO_PAIR=1}"
    : "${TNODE_OP_ID:?TNODE_OP_ID required when TNODE_AUTO_PAIR=1}"
    : "${TNODE_PROGRESS_URL:?TNODE_PROGRESS_URL required when TNODE_AUTO_PAIR=1}"
fi

# Progress heartbeat — only emits in auto-pair mode; no-op for BYO.
# Signs the payload with HMAC-SHA256 of nodeSecret (same scheme the watcher
# uses elsewhere). The Cloud Function receiving these updates the
# `nodes/{nodeId}.provisioning.steps[]` doc so the mobile app timeline
# advances live.
report_progress_heartbeat() {
    [[ "${TNODE_AUTO_PAIR:-}" == "1" ]] || return 0
    local phase="${1:?phase required}"
    local extra_json="${2:-}"  # optional JSON object (as string, no outer quotes)
    local body sig
    if [[ -n "$extra_json" ]]; then
        body=$(printf '{"nodeId":"%s","phase":"%s","opId":"%s","extra":%s}' \
            "$TNODE_NODE_ID" "$phase" "$TNODE_OP_ID" "$extra_json")
    else
        body=$(printf '{"nodeId":"%s","phase":"%s","opId":"%s"}' \
            "$TNODE_NODE_ID" "$phase" "$TNODE_OP_ID")
    fi
    sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$TNODE_NODE_SECRET" -hex | awk '{print $2}')
    curl -fsS -X POST \
        -H "Content-Type: application/json" \
        -H "X-HMAC-SHA256: $sig" \
        -H "X-TNode-OpId: $TNODE_OP_ID" \
        -d "$body" "$TNODE_PROGRESS_URL" >/dev/null 2>&1 || true
}

# Emit an "install_started" heartbeat as the very first action after env
# validation, so the provisionTNode CF can tell the difference between
# "installer never ran" (cloud-init / curl failure) and "installer ran but
# died later" (apt / npm failure mid-way).
report_progress_heartbeat "install_started"

# ─────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────
# Default HOME when running under cloud-init / systemd (no user profile).
# `set -u` would otherwise fail the next `$HOME` expansion.
: "${HOME:=/root}"
export HOME

# Ensure common binary paths are available (critical for piped installs
# where the shell profile hasn't been sourced)
for _p in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/bin" /usr/sbin; do
    case ":$PATH:" in
        *":$_p:"*) ;;
        *) [[ -d "$_p" ]] && export PATH="$_p:$PATH" ;;
    esac
done
unset _p

TNODE_SETUP_VERSION="1.12.1"
CLOUD_MODEL="kimi-k2.5:cloud"
# Pin OpenClaw to the last known-good release. v2026.4.25 introduced an
# auto-pair regression where the gateway responds 1008 to unknown devices
# even with a valid Ed25519 signature + master token, blocking cloud
# provisioning E2E. Override with `OPENCLAW_PIN_VERSION=` (empty) to take
# whatever is current.
OPENCLAW_PIN_VERSION="${OPENCLAW_PIN_VERSION-2026.4.23}"
TNODE_USER="tnode"
TNODE_HOME=""      # set in setup_tnode_user()
OPENCLAW_HOME=""   # set in setup_tnode_user()
TNODE_BIN=""       # set in setup_tnode_user()

# API provider helpers (bash 3.2 compatible — no associative arrays)
api_provider_valid() {
    case "$1" in groq|openrouter|together) return 0 ;; *) return 1 ;; esac
}
api_provider_base_url() {
    case "$1" in
        groq)       echo "https://api.groq.com/openai/v1" ;;
        openrouter) echo "https://openrouter.ai/api/v1" ;;
        together)   echo "https://api.together.xyz/v1" ;;
    esac
}
api_provider_default_model() {
    case "$1" in
        groq)       echo "groq/llama-3.3-70b-versatile" ;;
        openrouter) echo "openrouter/anthropic/claude-3.5-haiku" ;;
        together)   echo "together/meta-llama/Llama-3.3-70B-Instruct-Turbo" ;;
    esac
}

# ─────────────────────────────────────────────
# CLI flags (defaults)
# ─────────────────────────────────────────────
YES=0
NO_OLLAMA=0
NO_TUNNEL=0           # --no-tunnel: skip Cloudflare Tunnel
WITH_TAILSCALE=0      # --with-tailscale: install Tailscale (not default anymore)
NO_TAILSCALE=0        # legacy compat, same as default now
NO_QR=0
MODEL=""          # empty = auto-detect (GPU → qwen3.5, CPU → qwen2.5:1.5b)
MODEL_EXPLICIT=0  # 1 if user passed --model
USE_CLOUD=0
USE_API=0         # 1 if --api flag set
API_PROVIDER=""   # groq, openrouter, together
API_KEY=""        # API key for external provider
TUNNEL_TOKEN=""       # --tunnel-token: pre-provisioned Cloudflare tunnel token
TUNNEL_DOMAIN=""      # set by phase_tunnel
VERBOSE=0
UPDATE_ONLY=0         # --update-only: refresh scripts/binaries, never rotate secrets
COMPONENT=""          # --component <name>: only run install_<name> + verify, implies --update-only
NO_SMOKE_TEST=0       # --no-smoke-test: skip post-update verify_<X>.py (escape hatch)
UNINSTALL=0           # --uninstall: stop+remove local services and ~/.openclaw, NO server-side cleanup
PURGE_BINARIES=0      # --purge-binaries: also delete /usr/local/bin/cloudflared and /usr/bin/openclaw

# Components supported by --component=<name> dispatcher. Mirrored in
# install.tbrain.app/verify/verify_<id>.py. Keep in sync with tnode-setup.sh.
SUPPORTED_COMPONENTS=(
    "openclaw-gateway"
    "tnode-chat-sync"
    "tnode-config-sync"
    "tnode-telemetry"
    "pair-watch"
    "cloudflared"
)

# Tunnel provisioning API
TUNNEL_API_URL="https://api.tbrain.app/v1/tunnel/provision"
# Firebase Function that issues short-lived HMAC tokens. The shared HMAC
# secret never leaves Firebase Secret Manager + Worker env; the installer
# only ever sees a per-request signed token (expires in 300s, single-use
# nonce). Same pattern as `setupKey` for OpenRouter.
PROVISION_TOKEN_URL="https://us-central1-tbrain-platform-7fc1f.cloudfunctions.net/getProvisionToken"
# Firebase Functions for chat-sync (tnode-chat-sync watcher on this node
# mirrors conversations to Firestore so the mobile app never loses a turn
# when it's closed).
REGISTER_NODE_SYNC_URL="https://us-central1-tbrain-platform-7fc1f.cloudfunctions.net/registerNodeSync"
MINT_NODE_TOKEN_URL="https://us-central1-tbrain-platform-7fc1f.cloudfunctions.net/mintNodeToken"
# Firebase Function that hands the per-node OR apiKey to the on-node
# daemon when it receives apply_openrouter_key. HMAC-signed with the same
# per-node secret as mintNodeToken. Key is minted/topped-up from the app.
PULL_LLM_CONFIG_URL="https://us-central1-tbrain-platform-7fc1f.cloudfunctions.net/pullLLMConfig"

# ─────────────────────────────────────────────
# Colors
# ─────────────────────────────────────────────
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    BOLD='\033[1m'
    GREEN='\033[38;2;0;229;204m'
    YELLOW='\033[38;2;255;176;32m'
    RED='\033[38;2;230;57;70m'
    BLUE='\033[38;2;100;149;237m'
    MUTED='\033[38;2;136;146;176m'
    NC='\033[0m'
else
    BOLD='' GREEN='' YELLOW='' RED='' BLUE='' MUTED='' NC=''
fi

# ─────────────────────────────────────────────
# Logging helpers
# ─────────────────────────────────────────────
info()    { echo -e "    ${MUTED}$*${NC}"; }
success() { echo -e "    ${GREEN}✓${NC} $*"; }
warn()    { echo -e "    ${YELLOW}⚠${NC} $*"; }
fail()    { echo -e "    ${RED}✗${NC} $*" >&2; }
die()     { fail "$*"; exit 1; }

phase() {
    local num="$1"; shift
    echo ""
    echo -e "  ${BOLD}[${num}]${NC} ${BOLD}$*${NC}"
}

# ─────────────────────────────────────────────
# Utility functions
# ─────────────────────────────────────────────
command_exists() { command -v "$1" >/dev/null 2>&1; }

# In --update-only mode, the systemd unit was provisioned during a prior
# full install and should NOT be regenerated — writing to /etc/systemd/system
# requires root, which fails on the Pi (tbrainadmin) and on VPSs when the
# operator runs `update.tbrain.app/update.sh | bash` as a non-root user.
# Each install_<comp>_systemd calls this at the top; if it returns 0, the
# rest of the function (the unit-file write + daemon-reload + enable) is
# skipped. Picks user vs system path automatically.
_systemd_update_only_handled() {
    [[ "${UPDATE_ONLY:-0}" != "1" ]] && return 1
    local unit="$1"
    local user_path="${HOME}/.config/systemd/user/${unit}.service"
    local sys_path="/etc/systemd/system/${unit}.service"
    if [[ -f "$user_path" ]]; then
        XDG_RUNTIME_DIR="/run/user/$(id -u)" systemctl --user daemon-reload 2>/dev/null || true
        XDG_RUNTIME_DIR="/run/user/$(id -u)" systemctl --user restart "$unit" 2>/dev/null || true
        success "systemd --user ${unit} reloaded+restarted (update-only)"
        return 0
    fi
    if [[ -f "$sys_path" ]]; then
        if sudo -n systemctl daemon-reload 2>/dev/null && sudo -n systemctl restart "$unit" 2>/dev/null; then
            success "systemd ${unit} restarted via sudo (update-only)"
        else
            warn "systemd ${unit}: could not restart without sudo; run 'sudo systemctl restart ${unit}' manually"
        fi
        return 0
    fi
    return 1
}

# Run a command as the tnode user (no-op if already tnode or on macOS)
run_as_tnode() {
    if [[ "$OS" == "Darwin" ]] || [[ "$(id -un)" == "$TNODE_USER" ]]; then
        "$@"
    else
        # Set XDG_RUNTIME_DIR so systemctl --user works via su
        local tnode_uid
        tnode_uid="$(id -u "$TNODE_USER" 2>/dev/null || echo "")"
        local env_prefix=""
        if [[ -n "$tnode_uid" ]] && [[ -d "/run/user/$tnode_uid" ]]; then
            env_prefix="export XDG_RUNTIME_DIR=/run/user/$tnode_uid; "
        fi
        su - "$TNODE_USER" -s /bin/bash -c "${env_prefix}$(printf '%q ' "$@")"
    fi
}

# Create tnode user if on Linux and running as root
setup_tnode_user() {
    if [[ "$OS" == "Darwin" ]]; then
        # macOS: no user creation, use current user
        TNODE_HOME="$HOME"
        OPENCLAW_HOME="${OPENCLAW_HOME:-$TNODE_HOME/.openclaw}"
        TNODE_BIN="$TNODE_HOME/bin"
        return 0
    fi

    if [[ "$(id -u)" != "0" ]]; then
        # Not root: use current user
        TNODE_USER="$(id -un)"
        TNODE_HOME="$HOME"
        OPENCLAW_HOME="${OPENCLAW_HOME:-$TNODE_HOME/.openclaw}"
        TNODE_BIN="$TNODE_HOME/bin"
        return 0
    fi

    # Linux + root: create dedicated tnode user
    if id "$TNODE_USER" >/dev/null 2>&1; then
        success "Usuario $TNODE_USER ya existe"
    else
        useradd --create-home --shell /bin/bash "$TNODE_USER" 2>/dev/null || true
        # Lock password (no direct login, use su from root)
        passwd -l "$TNODE_USER" >/dev/null 2>&1 || true
        success "Usuario $TNODE_USER creado (sin contraseña, acceso via: su - $TNODE_USER)"
    fi

    TNODE_HOME="$(eval echo "~$TNODE_USER")"
    OPENCLAW_HOME="$TNODE_HOME/.openclaw"
    TNODE_BIN="$TNODE_HOME/bin"

    # Enable lingering so systemd --user services persist without SSH session
    if command_exists loginctl; then
        loginctl enable-linger "$TNODE_USER" 2>/dev/null || true
        success "loginctl enable-linger $TNODE_USER (servicios persisten sin sesión)"
    fi

    # Ensure XDG_RUNTIME_DIR exists for tnode (needed by systemctl --user)
    local tnode_uid
    tnode_uid="$(id -u "$TNODE_USER" 2>/dev/null || echo "")"
    if [[ -n "$tnode_uid" ]] && [[ ! -d "/run/user/$tnode_uid" ]]; then
        mkdir -p "/run/user/$tnode_uid"
        chown "$TNODE_USER":"$TNODE_USER" "/run/user/$tnode_uid"
        chmod 700 "/run/user/$tnode_uid"
    fi

    # Start the user manager service so `systemctl --user` works from inside
    # `su - tnode` without requiring a reboot. Without this, enable-linger
    # only takes effect on next boot and the DBUS user bus returns
    # "No medium found" until then.
    if [[ -n "$tnode_uid" ]] && command_exists systemctl; then
        systemctl start "user@${tnode_uid}.service" 2>/dev/null || true
    fi
}

# Progress bar for long-running commands (spinner + bar + elapsed time)
# Usage: run_with_progress "Label" [--estimate SECS] command args...
run_with_progress() {
    local label="$1"; shift
    local estimate=45  # default estimated duration in seconds
    if [[ "${1:-}" == "--estimate" ]]; then
        estimate="$2"; shift 2
    fi
    local logfile
    logfile="$(mktemp)"
    local start_time=$SECONDS
    local spinner_frames
    spinner_frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local bar_width=20

    # Run command in background, capture output
    "$@" >"$logfile" 2>&1 &
    local pid=$!

    # Animated progress bar
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$(( SECONDS - start_time ))
        # Progress: ramp to 90% based on estimate, hold there until done
        local pct=$(( elapsed * 90 / (estimate > 0 ? estimate : 1) ))
        if [[ "$pct" -gt 90 ]]; then pct=90; fi
        local filled=$(( pct * bar_width / 100 ))
        local empty=$(( bar_width - filled ))
        local s_idx=$(( i % ${#spinner_frames[@]} ))
        local spinner="${spinner_frames[$s_idx]}"
        # Build bar string
        local bar=""
        local j=0
        while [[ "$j" -lt "$filled" ]]; do bar="${bar}█"; j=$(( j + 1 )); done
        j=0
        while [[ "$j" -lt "$empty" ]]; do bar="${bar}░"; j=$(( j + 1 )); done
        printf "\r    ${MUTED}%s %s [%s] %d%% (%ds)${NC}" "$spinner" "$label" "$bar" "$pct" "$elapsed"
        i=$(( i + 1 ))
        sleep 0.3
    done

    # Get exit code
    wait "$pid"
    local rc=$?
    local elapsed=$(( SECONDS - start_time ))

    # Final state: full bar or error
    if [[ "$rc" == "0" ]]; then
        local bar=""
        local j=0
        while [[ "$j" -lt "$bar_width" ]]; do bar="${bar}█"; j=$(( j + 1 )); done
        printf "\r    ${GREEN}✓${NC} %s ${MUTED}[%s] 100%% (%ds)${NC}\n" "$label" "$bar" "$elapsed"
    else
        printf "\r    ${RED}✗${NC} %s ${MUTED}(%ds)${NC}\n" "$label" "$elapsed"
        fail "Falló: $label"
        tail -5 "$logfile" | while IFS= read -r line; do
            echo -e "      ${MUTED}${line}${NC}"
        done
    fi

    if [[ "$VERBOSE" == "1" ]] && [[ "$rc" == "0" ]]; then
        tail -5 "$logfile" | while IFS= read -r line; do
            echo -e "      ${MUTED}${line}${NC}"
        done
    fi

    rm -f "$logfile"
    return $rc
}

detect_os() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"
    case "$ARCH" in
        aarch64) ARCH="arm64" ;;
    esac
}

confirm() {
    if [[ "$YES" == "1" ]]; then return 0; fi
    local prompt="$1"
    echo -en "    ${prompt} [Y/n] "
    read -r answer < /dev/tty 2>/dev/null || answer="y"
    case "${answer:-y}" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

# Ensures Python's `websockets` library is at version >= 13.
# Background: tnode_telemetry.py uses the new server-handler signature
# `async def handler(ws):` which only works with websockets >= 11. Older
# versions (e.g. Ubuntu 22.04's `python3-websockets` apt package ships
# 9.1) silently RESET incoming TCP connections without logging anything,
# because the lib invokes the handler with an extra `path` arg and the
# call fails before the WS upgrade completes. Symptom from the client
# side: pair-QR scan times out / app shows "no se pudo conectar" with no
# server-side log entry. Fix: pip-install >= 13 over the apt package.
ensure_websockets_modern() {
    local current
    current="$(/usr/bin/env python3 -c 'import websockets; print(websockets.__version__)' 2>/dev/null || echo 'none')"
    if [[ "$current" != "none" ]]; then
        local major
        major="$(echo "$current" | cut -d. -f1)"
        if [[ "$major" =~ ^[0-9]+$ ]] && [[ "$major" -ge 13 ]]; then
            success "websockets ${current} OK (>=13)"
            return 0
        fi
        info "websockets ${current} es muy viejo — actualizando a >=13"
    else
        info "websockets no está instalado — instalando >=13"
    fi

    # 1) Ensure pip is available — install directly (no run_with_progress) so
    # apt/dnf/yum failures surface their real exit code instead of being
    # hidden behind a spinner that always reports "OK".
    if ! /usr/bin/env python3 -m pip --version >/dev/null 2>&1; then
        info "Instalando python3-pip (necesario para upgrade de websockets)..."
        local pip_install_log
        pip_install_log="$(mktemp)"
        local pip_install_rc=0
        if command_exists apt-get; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y python3-pip >"$pip_install_log" 2>&1 || pip_install_rc=$?
        elif command_exists dnf; then
            dnf install -y python3-pip >"$pip_install_log" 2>&1 || pip_install_rc=$?
        elif command_exists yum; then
            yum install -y python3-pip >"$pip_install_log" 2>&1 || pip_install_rc=$?
        elif [[ "$(uname)" == "Darwin" ]]; then
            : # macOS python3 trae pip incluido
        else
            rm -f "$pip_install_log"
            die "No hay package manager (apt/dnf/yum) — instala python3-pip manualmente y reintenta"
        fi
        if [[ "$pip_install_rc" -ne 0 ]]; then
            warn "package install de python3-pip falló (exit ${pip_install_rc}). Últimas líneas:"
            tail -10 "$pip_install_log" >&2 || true
            rm -f "$pip_install_log"
            die "No se pudo instalar python3-pip — websockets no se puede actualizar y el sidecar fallará"
        fi
        rm -f "$pip_install_log"
        # Validate: check the install actually produced a working pip. apt
        # sometimes reports success without doing anything (stale dpkg lock,
        # bad mirror state) — catch that here instead of letting it cascade.
        if ! /usr/bin/env python3 -m pip --version >/dev/null 2>&1; then
            die "python3-pip se instaló sin error, pero 'python3 -m pip' sigue sin responder. Revisa el state de apt/dpkg"
        fi
        success "python3-pip OK"
    fi

    # 2) pip-install websockets. Try plain --upgrade first; fall back to
    # --break-system-packages for PEP 668 (Ubuntu 24.04+, Debian 12+) where
    # system Python is marked "externally managed".
    info "Actualizando websockets vía pip..."
    local ws_install_log
    ws_install_log="$(mktemp)"
    local ws_install_rc=0
    /usr/bin/env python3 -m pip install --upgrade "websockets>=13,<14" >"$ws_install_log" 2>&1 || ws_install_rc=$?
    if [[ "$ws_install_rc" -ne 0 ]] && grep -q "externally-managed-environment" "$ws_install_log"; then
        info "Reintentando con --break-system-packages (PEP 668)"
        ws_install_rc=0
        /usr/bin/env python3 -m pip install --upgrade --break-system-packages "websockets>=13,<14" >"$ws_install_log" 2>&1 || ws_install_rc=$?
    fi
    if [[ "$ws_install_rc" -ne 0 ]]; then
        warn "pip install websockets falló (exit ${ws_install_rc}). Últimas líneas:"
        tail -10 "$ws_install_log" >&2 || true
        rm -f "$ws_install_log"
        die "No se pudo actualizar websockets a >=13 — el sidecar tnode-telemetry resetará todas las conexiones del cliente"
    fi
    rm -f "$ws_install_log"

    # 3) Validate the install actually landed. pip can report success while
    # leaving an old shadow copy first in sys.path (e.g. apt's
    # python3-websockets in /usr/lib/python3/dist-packages takes precedence
    # over /usr/local/lib/... on some distros). Confirm what tnode user sees.
    local final_version
    final_version="$(/usr/bin/env python3 -c 'import websockets; print(websockets.__version__)' 2>/dev/null || echo 'none')"
    if [[ "$final_version" == "none" ]]; then
        die "Tras pip install, 'import websockets' falla. Revisa sys.path con: python3 -c 'import sys; print(sys.path)'"
    fi
    local final_major
    final_major="$(echo "$final_version" | cut -d. -f1)"
    if [[ ! "$final_major" =~ ^[0-9]+$ ]] || [[ "$final_major" -lt 13 ]]; then
        die "Tras pip install, websockets sigue en ${final_version}. Probablemente apt's python3-websockets está shadowing el pip install — desinstala con: apt remove -y python3-websockets"
    fi
    success "websockets actualizado a ${final_version}"
}

# Ensures Python `psutil` is importable. The telemetry sidecar uses psutil
# to collect CPU/RAM/disk metrics for the `health` stream — without it,
# the sidecar logs a warning and silently disables the stream, so the
# mobile dashboard's Salud widget shows no data (Mini incident 2026-05-07).
# Linux: apt/dnf/yum already install python3-psutil during phase_helpers,
# so this is mostly a safety net. macOS: Apple's Python ships without it,
# pip-install with PEP 668 fallback (matches ensure_websockets_modern).
ensure_psutil_installed() {
    if /usr/bin/env python3 -c 'import psutil' >/dev/null 2>&1; then
        local v
        v="$(/usr/bin/env python3 -c 'import psutil; print(psutil.__version__)' 2>/dev/null || echo 'unknown')"
        success "psutil ${v} OK"
        return 0
    fi
    info "psutil no está instalado — el stream health del sidecar lo necesita"

    if ! /usr/bin/env python3 -m pip --version >/dev/null 2>&1; then
        warn "python3-pip no disponible — saltando install de psutil (health stream quedará deshabilitado)"
        return 1
    fi

    local install_log
    install_log="$(mktemp)"
    local rc=0
    /usr/bin/env python3 -m pip install psutil >"$install_log" 2>&1 || rc=$?
    if [[ "$rc" -ne 0 ]] && grep -q "externally-managed-environment" "$install_log"; then
        info "Reintentando con --break-system-packages (PEP 668)"
        rc=0
        /usr/bin/env python3 -m pip install --break-system-packages psutil >"$install_log" 2>&1 || rc=$?
    fi
    if [[ "$rc" -ne 0 ]]; then
        warn "pip install psutil falló (exit ${rc}). Últimas líneas:"
        tail -10 "$install_log" >&2 || true
        rm -f "$install_log"
        warn "Health stream del sidecar quedará deshabilitado en este nodo"
        return 1
    fi
    rm -f "$install_log"

    local final_version
    final_version="$(/usr/bin/env python3 -c 'import psutil; print(psutil.__version__)' 2>/dev/null || echo 'none')"
    if [[ "$final_version" == "none" ]]; then
        warn "Tras pip install, 'import psutil' falla. Health stream deshabilitado"
        return 1
    fi
    success "psutil instalado (${final_version})"
}

# Resolve Homebrew binary
resolve_brew() {
    local brew=""
    brew="$(command -v brew 2>/dev/null || true)"
    if [[ -n "$brew" ]]; then echo "$brew"; return 0; fi
    if [[ -x "/opt/homebrew/bin/brew" ]]; then echo "/opt/homebrew/bin/brew"; return 0; fi
    if [[ -x "/usr/local/bin/brew" ]]; then echo "/usr/local/bin/brew"; return 0; fi
    return 1
}

ensure_brew_on_path() {
    if ! command_exists brew; then
        local brew_bin
        brew_bin="$(resolve_brew || true)"
        if [[ -n "$brew_bin" ]]; then
            eval "$("$brew_bin" shellenv)"
        fi
    fi
}

# Add ~/bin to PATH in shell rc if not present
ensure_path_in_rc() {
    local rc_file=""
    case "$OS" in
        Darwin) rc_file="$HOME/.zshrc" ;;
        Linux)  rc_file="$HOME/.bashrc" ;;
    esac
    if [[ -z "$rc_file" ]]; then return; fi

    local path_line='export PATH="$HOME/bin:$PATH"'
    if [[ -f "$rc_file" ]] && grep -qF 'HOME/bin' "$rc_file"; then
        return 0
    fi
    echo "" >> "$rc_file"
    echo "# Added by TNode setup" >> "$rc_file"
    echo "$path_line" >> "$rc_file"
    success "Added ~/bin to PATH in $rc_file"
}

# Same as ensure_path_in_rc but for tnode user's home
ensure_path_in_rc_for_tnode() {
    local rc_file="$TNODE_HOME/.bashrc"
    if [[ "$OS" == "Darwin" ]]; then rc_file="$TNODE_HOME/.zshrc"; fi
    if [[ -z "$rc_file" ]]; then return; fi

    local path_line='export PATH="$HOME/bin:$PATH"'
    if [[ -f "$rc_file" ]] && grep -qF 'HOME/bin' "$rc_file"; then
        return 0
    fi
    echo "" >> "$rc_file"
    echo "# Added by TNode setup" >> "$rc_file"
    echo "$path_line" >> "$rc_file"
    chown "$TNODE_USER":"$TNODE_USER" "$rc_file" 2>/dev/null || true
    success "Added ~/bin to PATH in $rc_file"
}

# ─────────────────────────────────────────────
# GPU detection → smart model default
# ─────────────────────────────────────────────
detect_gpu() {
    # Returns 0 (true) if GPU with sufficient VRAM is available
    case "$OS" in
        Darwin)
            # macOS Apple Silicon always has unified memory → GPU-capable
            if [[ "$ARCH" == "arm64" ]]; then
                return 0
            fi
            # Intel Mac: check for discrete GPU
            if system_profiler SPDisplaysDataType 2>/dev/null | grep -qi "Metal\|Radeon\|NVIDIA"; then
                return 0
            fi
            return 1
            ;;
        Linux)
            # Check NVIDIA GPU
            if command_exists nvidia-smi; then
                local vram_mb
                vram_mb="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")"
                if [[ "${vram_mb:-0}" -ge 4000 ]]; then
                    return 0
                fi
            fi
            # Check for ROCm (AMD)
            if command_exists rocm-smi; then
                return 0
            fi
            return 1
            ;;
    esac
    return 1
}

select_default_model() {
    # If user explicitly set --model, respect it
    if [[ "$MODEL_EXPLICIT" == "1" ]]; then
        return 0
    fi
    if [[ "$USE_CLOUD" == "1" ]]; then
        MODEL="$CLOUD_MODEL"
        return 0
    fi
    if [[ "$USE_API" == "1" ]]; then
        # API mode: use provider's default model
        MODEL="$(api_provider_default_model "$API_PROVIDER")"
        info "Modo API ($API_PROVIDER) → modelo: $MODEL"
        return 0
    fi

    if detect_gpu; then
        MODEL="qwen3.5"
        info "GPU detectada → modelo grande: $MODEL (~6.6 GB)"
    else
        MODEL="qwen2.5:1.5b"
        info "Sin GPU dedicada → modelo ligero: $MODEL (~1.0 GB, optimizado para CPU)"
    fi
}

# ─────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y)        YES=1 ;;
            --no-ollama)     NO_OLLAMA=1 ;;
            --no-tunnel)     NO_TUNNEL=1 ;;
            --with-tailscale) WITH_TAILSCALE=1 ;;
            --no-tailscale)  NO_TAILSCALE=1 ;;  # legacy compat (Tailscale off by default now)
            --tunnel-token)  TUNNEL_TOKEN="${2:?--tunnel-token requires a value}"; shift ;;
            --no-qr)         NO_QR=1 ;;
            --model)         MODEL="${2:?--model requires a value}"; MODEL_EXPLICIT=1; shift ;;
            --cloud)         USE_CLOUD=1; MODEL="$CLOUD_MODEL" ;;
            --api)
                USE_API=1; NO_OLLAMA=1; API_PROVIDER="openrouter"
                # If next arg is not a flag, treat it as API key
                if [[ -n "${2:-}" ]] && [[ "${2}" != --* ]]; then
                    API_KEY="$2"
                    shift
                fi
                ;;
            --verbose)       VERBOSE=1 ;;
            --update-only)   UPDATE_ONLY=1 ;;
            --component)
                COMPONENT="${2:?--component requires a value (e.g. tnode-chat-sync)}"
                UPDATE_ONLY=1
                shift
                ;;
            --no-smoke-test) NO_SMOKE_TEST=1 ;;
            --uninstall)     UNINSTALL=1 ;;
            --purge-binaries) PURGE_BINARIES=1 ;;
            --version)       echo "tnode-setup v${TNODE_SETUP_VERSION}"; exit 0 ;;
            -h|--help)       print_usage; exit 0 ;;
            *)               warn "Unknown flag: $1" ;;
        esac
        shift
    done

    # Validate --component against the supported list
    if [[ -n "$COMPONENT" ]]; then
        local found=0
        local c
        for c in "${SUPPORTED_COMPONENTS[@]}"; do
            if [[ "$c" == "$COMPONENT" ]]; then
                found=1
                break
            fi
        done
        if [[ "$found" == "0" ]]; then
            local list="${SUPPORTED_COMPONENTS[*]}"
            die "Unknown --component '$COMPONENT'. Supported: ${list// /, }"
        fi
    fi
}

print_usage() {
    cat <<EOF
TNode Setup v${TNODE_SETUP_VERSION}

Usage: bash tnode-setup.sh [OPTIONS]
       curl -fsSL https://install.tbrain.app | bash

Options:
  --yes, -y           Non-interactive mode
  --no-ollama         Skip Ollama installation
  --no-tunnel         Skip Cloudflare Tunnel (use Tailscale or LAN instead)
  --with-tailscale    Install Tailscale alongside tunnel (or as alternative)
  --tunnel-token T    Pre-provisioned Cloudflare tunnel token
  --no-qr             Skip QR display at the end
  --model <name>      LLM model (default: auto-detect GPU/CPU)
  --cloud             Use cloud model (${CLOUD_MODEL})
  --api [key]         Use cloud API (OpenRouter). Key opcional, incluida por defecto.
  --verbose           Enable debug output
  --update-only       Refresh scripts/binaries without rotating secrets.
                      Aborts if required state (tunnel.json, gateway token)
                      is missing instead of regenerating it.
  --component <name>  Only install/refresh the named component (implies
                      --update-only). Supported: openclaw-gateway,
                      tnode-chat-sync, tnode-config-sync, tnode-telemetry,
                      pair-watch, cloudflared.
  --no-smoke-test     Skip post-update verify_<X>.py smoke test.
  --uninstall         Local cleanup only: stop+disable systemd/launchd units,
                      remove unit files, delete ~/.openclaw. Does NOT touch
                      server-side state (Firestore, Cloudflare tunnel) — for
                      that, delete the node from the TNode mobile app first
                      (which invokes the deleteAgent Cloud Function).
  --purge-binaries    With --uninstall, also delete /usr/local/bin/cloudflared
                      and /usr/bin/openclaw. Off by default (other apps may
                      use them).
  --version           Print version and exit
  -h, --help          Show this help

Model defaults:
  GPU detected    → qwen3.5 (~6.6 GB VRAM)
  CPU only        → qwen2.5:1.5b (~1.0 GB, fast on CPU)
  --api           → claude-3.5-haiku via OpenRouter (incluido)

Connectivity:
  Default         → Cloudflare Tunnel (wss://, sin VPN requerido)
  --no-tunnel     → Requiere Tailscale (--with-tailscale) o acceso LAN
  --with-tailscale → Tailscale como fallback adicional

Examples:
  # VPS sin GPU — API cloud + tunnel (default):
  bash tnode-setup.sh --api

  # VPS con key propia:
  bash tnode-setup.sh --api sk-or-v1-xxx

  # Sin tunnel (dev local con Tailscale):
  bash tnode-setup.sh --no-tunnel --with-tailscale

  # Mac Mini con Apple Silicon — LLM local:
  bash tnode-setup.sh

  # Raspberry Pi — solo gateway, LLM en otro nodo:
  bash tnode-setup.sh --no-ollama --yes

  # Refrescar scripts/binarios sin rotar secretos:
  curl -fsSL https://install.tbrain.app | bash -s -- --update-only --yes

  # Actualizar solo un daemon (incluye verify smoke-test):
  curl -fsSL https://install.tbrain.app | bash -s -- --component tnode-chat-sync --yes
EOF
}

print_banner() {
    echo ""
    echo -e "  ${BOLD}╭─────────────────────────────────────╮${NC}"
    echo -e "  ${BOLD}│   TNode Setup v${TNODE_SETUP_VERSION}               │${NC}"
    echo -e "  ${BOLD}│   Configura tu nodo para TNode      │${NC}"
    echo -e "  ${BOLD}╰─────────────────────────────────────╯${NC}"
}

# ═════════════════════════════════════════════
# PHASE 1: Validations
# ═════════════════════════════════════════════
phase_validate() {
    phase "1/7" "Validaciones"

    detect_os

    # Supported platform?
    case "${OS}/${ARCH}" in
        Darwin/arm64)   success "macOS arm64 (Apple Silicon)" ;;
        Linux/arm64)    success "Linux arm64 (Raspberry Pi / ARM server)" ;;
        Linux/x86_64)   success "Linux x86_64" ;;
        Darwin/x86_64)  success "macOS x86_64 (Intel)" ;;
        *)              die "Plataforma no soportada: ${OS}/${ARCH}" ;;
    esac

    # Create tnode user (Linux) or use current user (macOS / non-root)
    setup_tnode_user

    # Internet check
    if curl -fsSL --max-time 5 https://registry.npmjs.org/ >/dev/null 2>&1; then
        success "Conexión a internet"
    else
        die "Sin conexión a internet"
    fi

    # Python 3
    if command_exists python3; then
        local pyver
        pyver="$(python3 --version 2>&1 | awk '{print $2}')"
        success "Python $pyver"
    else
        warn "Python 3 no encontrado — pair-watch requiere Python 3.9+"
        if [[ "$OS" == "Darwin" ]]; then
            info "Se instalará con Xcode command line tools"
        fi
    fi

    # Memory pre-check. OpenClaw's npm install needs ~1 GB; on Ubuntu 512 MB
    # droplets it gets killed by the OOM killer mid-install (seen on
    # do $5/mo droplets). Fail fast with a useful message.
    if [[ "$OS" == "Linux" ]] && [[ -r /proc/meminfo ]]; then
        local mem_kb mem_mb
        mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
        mem_mb=$((mem_kb / 1024))
        if [[ "$mem_mb" -gt 0 ]] && [[ "$mem_mb" -lt 512 ]]; then
            die "RAM insuficiente: ${mem_mb} MB. OpenClaw requiere >=1024 MB (npm install será killed por OOM). Upgrade a un droplet de al menos 1 GB."
        elif [[ "$mem_mb" -gt 0 ]] && [[ "$mem_mb" -lt 1024 ]]; then
            warn "RAM limitada: ${mem_mb} MB. Recomendado >=1024 MB — npm install de OpenClaw puede ser killed por OOM."
            info "Si querés intentarlo igual, activá swap antes:"
            info "  fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"
        else
            [[ "$mem_mb" -gt 0 ]] && success "RAM ${mem_mb} MB"
        fi
    fi

    # Auto-detect: if no GPU and user didn't explicitly choose local/cloud, use API mode
    if [[ "$USE_API" == "0" ]] && [[ "$USE_CLOUD" == "0" ]] && [[ "$MODEL_EXPLICIT" == "0" ]]; then
        if ! detect_gpu; then
            info "Sin GPU detectada → activando modo API automáticamente"
            USE_API=1
            NO_OLLAMA=1
            API_PROVIDER="openrouter"
        fi
    fi

    # Auto-detect model based on GPU
    select_default_model
}

# ═════════════════════════════════════════════
# PHASE 2: Ollama
# ═════════════════════════════════════════════
phase_ollama() {
    phase "2/7" "Ollama"

    if [[ "$USE_API" == "1" ]]; then
        info "Modo API ($API_PROVIDER) — no se necesita Ollama local"
        success "LLM via API: $API_PROVIDER"
        return 0
    fi

    if [[ "$NO_OLLAMA" == "1" ]]; then
        info "Saltando Ollama (--no-ollama)"
        return 0
    fi

    # Install Ollama if not present
    if command_exists ollama; then
        local ollama_ver
        ollama_ver="$(ollama --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "?")"
        success "Ollama v${ollama_ver} ya instalado"
    else
        info "Instalando Ollama..."
        case "$OS" in
            Darwin)
                local tmp_dir
                tmp_dir="$(mktemp -d)"
                curl -fSL --progress-bar -o "$tmp_dir/Ollama-darwin.zip" \
                    "https://ollama.com/download/Ollama-darwin.zip"
                # Stop existing if running
                pkill -x Ollama 2>/dev/null || true
                sleep 1
                # Remove old version
                [[ -d "/Applications/Ollama.app" ]] && rm -rf "/Applications/Ollama.app"
                # Install
                unzip -q "$tmp_dir/Ollama-darwin.zip" -d "$tmp_dir"
                mv "$tmp_dir/Ollama.app" "/Applications/"
                # Symlink CLI
                if [[ ! -L "/usr/local/bin/ollama" ]] || \
                   [[ "$(readlink "/usr/local/bin/ollama" 2>/dev/null)" != "/Applications/Ollama.app/Contents/Resources/ollama" ]]; then
                    mkdir -p "/usr/local/bin" 2>/dev/null || sudo mkdir -p "/usr/local/bin"
                    ln -sf "/Applications/Ollama.app/Contents/Resources/ollama" "/usr/local/bin/ollama" 2>/dev/null || \
                        sudo ln -sf "/Applications/Ollama.app/Contents/Resources/ollama" "/usr/local/bin/ollama"
                fi
                # Start Ollama
                open -a Ollama --args hidden
                sleep 3  # Give it time to start the API server
                rm -rf "$tmp_dir"
                success "Ollama instalado en /Applications"
                ;;
            Linux)
                info "Ejecutando installer oficial de Ollama..."
                # Download to temp file first — Ollama's installer uses set -eu
                # and EXIT traps that kill parent scripts when piped directly
                local ollama_tmp
                ollama_tmp="$(mktemp)"
                curl -fsSL https://ollama.com/install.sh -o "$ollama_tmp"
                bash "$ollama_tmp" || true
                rm -f "$ollama_tmp"
                # Ensure systemd service is started
                if command_exists systemctl; then
                    systemctl daemon-reload 2>/dev/null || true
                    systemctl enable ollama 2>/dev/null || true
                    systemctl start ollama 2>/dev/null || true
                fi
                # Refresh PATH — Ollama installs to /usr/local/bin
                hash -r 2>/dev/null || true
                success "Ollama instalado"
                ;;
        esac
    fi

    # Verify Ollama API is running (wait up to 30s)
    info "Esperando que Ollama API esté lista..."
    local retries=0
    while ! curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; do
        retries=$((retries + 1))
        if [[ $retries -ge 15 ]]; then
            warn "Ollama no responde en localhost:11434"
            if [[ "$OS" == "Linux" ]] && command_exists systemctl; then
                info "Intentando reiniciar servicio..."
                systemctl restart ollama 2>/dev/null || true
                sleep 3
                if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
                    success "Ollama API lista (tras reinicio)"
                    break
                fi
            fi
            warn "Ollama no responde — intenta iniciarlo manualmente"
            return 0
        fi
        sleep 2
    done
    if [[ $retries -lt 15 ]]; then
        success "Ollama API lista"
    fi

    # Pull model (only for local models, not cloud)
    if [[ "$USE_CLOUD" == "1" ]]; then
        info "Modo cloud: modelo $MODEL se descarga on-demand, no requiere pull"
    else
        if ollama list 2>/dev/null | grep -q "${MODEL%%:*}"; then
            success "Modelo $MODEL ya disponible"
        else
            info "Descargando modelo $MODEL (esto puede tardar varios minutos)..."
            run_with_progress "Descargando $MODEL" --estimate 120 ollama pull "$MODEL"
            success "Modelo $MODEL listo"
        fi
    fi
}

# ═════════════════════════════════════════════
# PHASE 3: OpenClaw via Ollama
# ═════════════════════════════════════════════

# Ensure Node.js is available (required by OpenClaw)
ensure_nodejs() {
    if command_exists node && command_exists npm; then
        local node_ver
        node_ver="$(node --version 2>&1)"
        success "Node.js $node_ver (npm $(npm --version 2>&1))"
        return 0
    fi

    # Node exists without npm (e.g. Ubuntu 24 ships Node 18 without npm).
    # Must purge the distro package first — NodeSource `apt install nodejs` does
    # NOT reliably upgrade an Ubuntu-provided `nodejs` package, leaving the box
    # with Node 18 and no npm after the installer "succeeds".
    local needs_purge=0
    if command_exists node && ! command_exists npm; then
        info "Node.js $(node --version) detectado sin npm — reinstalando Node.js 22..."
        needs_purge=1
    fi

    info "Instalando Node.js (requerido por TNode Kernel)..."
    case "$OS" in
        Darwin)
            ensure_brew_on_path
            if command_exists brew; then
                run_with_progress "Instalando Node.js + git via Homebrew" --estimate 30 brew install node git
            else
                die "Homebrew necesario para instalar Node.js en macOS"
            fi
            ;;
        Linux)
            if command_exists apt-get; then
                if [[ "$needs_purge" == "1" ]]; then
                    # Remove distro nodejs + libnode* so NodeSource can take over cleanly.
                    apt-get purge -y nodejs libnode-dev libnode72 libnode109 nodejs-doc >/dev/null 2>&1 || true
                    apt-get autoremove -y >/dev/null 2>&1 || true
                fi
                # Run NodeSource setup foreground (no spinner) — its output is load-bearing
                # for debugging when the repo fails to register.
                info "Configurando repositorio NodeSource..."
                curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1 || die "NodeSource setup falló"
                run_with_progress "Instalando Node.js 22 + git + python3-websockets + python3-psutil" --estimate 30 apt-get install -y nodejs git python3-websockets python3-psutil
            elif command_exists dnf; then
                info "Configurando repositorio NodeSource..."
                curl -fsSL https://rpm.nodesource.com/setup_22.x | bash - >/dev/null 2>&1 || die "NodeSource setup falló"
                run_with_progress "Instalando Node.js 22 + git + python3-websockets + python3-psutil" --estimate 30 dnf install -y nodejs git python3-websockets python3-psutil
            elif command_exists yum; then
                info "Configurando repositorio NodeSource..."
                curl -fsSL https://rpm.nodesource.com/setup_22.x | bash - >/dev/null 2>&1 || die "NodeSource setup falló"
                run_with_progress "Instalando Node.js 22 + git + python3-websockets + python3-psutil" --estimate 30 yum install -y nodejs git python3-websockets python3-psutil
            else
                die "No se encontró package manager (apt/dnf/yum) para instalar Node.js"
            fi
            # Distro `python3-websockets` packages are often stuck on 9.x —
            # force-upgrade so the telemetry sidecar can accept WS clients.
            ensure_websockets_modern
            # Validate psutil landed (apt above already pulled python3-psutil);
            # falls through to pip-install if the distro lacks the apt pkg.
            ensure_psutil_installed || true
            ;;
    esac

    # Refresh PATH
    hash -r 2>/dev/null || true

    if command_exists node && command_exists npm; then
        success "Node.js $(node --version) (npm $(npm --version)) instalado"
    else
        die "Node.js/npm no se encontró en PATH después de instalar — revisa el log"
    fi

    # git is required by npm to resolve some openclaw dependencies (otherwise
    # `npm install -g openclaw` fails with ENOENT on `spawn git` in phase 3/7).
    if ! command_exists git; then
        die "git no está instalado — requerido por npm para dependencias de OpenClaw"
    fi
}

# Activate a model in OpenClaw config via agents.defaults.models = {id: {}}.
# The plural-dict form is required by OpenClaw v2026.4.24+; the legacy
# singular `model.primary` triggers `Unknown model` for non-registry ids.
configure_openclaw_model() {
    local model_value="$1"
    local oc_config="$OPENCLAW_HOME/openclaw.json"

    if [[ ! -f "$oc_config" ]]; then
        warn "openclaw.json no encontrado, modelo se configurará automáticamente"
        return 0
    fi

    if command_exists python3; then
        python3 - "$oc_config" "$model_value" <<'PYEOF'
import json, sys
config_path, model = sys.argv[1], sys.argv[2]
try:
    with open(config_path) as f:
        c = json.load(f)
    agents = c.setdefault("agents", {})
    defaults = agents.setdefault("defaults", {})
    old_models = list((defaults.get("models") or {}).keys())
    defaults["models"] = {model: {}}
    defaults.pop("model", None)  # drop legacy singular key if present
    with open(config_path, "w") as f:
        json.dump(c, f, indent=2)
    old_str = ", ".join(old_models) if old_models else "(none)"
    print(f"{old_str} → {model}")
except Exception as e:
    print(f"error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
    else
        warn "Python3 no disponible — configura modelo manualmente en $oc_config"
    fi
}

# Configure gateway to bind on all interfaces (needed for Tailscale access)
configure_gateway_bind() {
    local oc_config="$OPENCLAW_HOME/openclaw.json"
    local use_tunnel="${1:-0}"  # 1 if Cloudflare Tunnel is active

    if [[ ! -f "$oc_config" ]]; then
        echo '{}' > "$oc_config"
    fi

    if command_exists python3; then
        # In --update-only mode, refuse to mint a new token if one is missing
        # — that would silently break every paired client. Fail loudly so
        # the operator can run a full install instead.
        local update_only="${UPDATE_ONLY:-0}"
        python3 - "$oc_config" "$use_tunnel" "$update_only" <<'PYEOF'
import json, os, sys
config_path = sys.argv[1]
use_tunnel = sys.argv[2] == "1"
update_only = sys.argv[3] == "1"
try:
    with open(config_path) as f:
        c = json.load(f)
    gw = c.setdefault("gateway", {})
    if use_tunnel:
        # Cloudflare Tunnel: only listen on localhost, cloudflared handles external
        gw["bind"] = "loopback"
        # bind=loopback alone makes `openclaw qr` refuse to render with
        # "Gateway is only bound to loopback. Set gateway.bind=lan, enable
        # tailscale serve, or configure plugins.entries.device-pair.config.publicUrl."
        # The tunnel IS the public URL — write it into device-pair so the
        # QR carries the tunnel hostname instead of refusing. Auto-pair
        # mode used to set this elsewhere; BYO-tunnel installs (curl pipe
        # without TNODE_AUTO_PAIR) hit the bug because nothing else wrote
        # publicUrl. Pulling the domain from tunnel.json — written by
        # phase_tunnel BEFORE this function is called — keeps the value
        # consistent with whatever the provisioning Worker handed us.
        tunnel_json = os.path.join(os.path.dirname(config_path), "tunnel.json")
        try:
            with open(tunnel_json) as tj:
                domain = (json.load(tj) or {}).get("domain", "")
        except FileNotFoundError:
            domain = ""
        if domain:
            entries = c.setdefault("plugins", {}).setdefault("entries", {})
            dp = entries.setdefault("device-pair", {})
            dp["enabled"] = True
            dp.setdefault("config", {})["publicUrl"] = f"wss://{domain}"
    else:
        # No tunnel: listen on all interfaces (for Tailscale/LAN access)
        gw["bind"] = "lan"
    gw["mode"] = "local"
    # Ensure auth token mode is set, AND a token actually exists. The
    # OpenClaw gateway requires both: setting mode without a token leaves
    # the gateway in a state where it rejects every request with
    # "Gateway auth is set to token, but no token is configured", which
    # blocks `tnode-qr` and any pairing flow. Generate a fresh 48-hex-char
    # token (24 bytes) when missing — same shape used by older installs.
    auth = gw.setdefault("auth", {})
    auth.setdefault("mode", "token")
    if auth.get("mode") == "token" and not auth.get("token"):
        if update_only:
            print(
                "ERROR: --update-only refusing to mint gateway.auth.token "
                "(missing or empty). Re-run a full install to recover.",
                file=sys.stderr,
            )
            sys.exit(2)
        import secrets
        auth["token"] = secrets.token_hex(24)
    with open(config_path, "w") as f:
        json.dump(c, f, indent=2)
    bind_mode = "loopback (tunnel)" if use_tunnel else "lan"
    print(f"bind={bind_mode}, mode=local")
except SystemExit:
    raise
except Exception as e:
    print(f"error: {e}", file=sys.stderr)
PYEOF
        local rc=$?
        if [[ "$rc" != "0" ]] && [[ "$update_only" == "1" ]]; then
            die "configure_gateway_bind: refused to mint missing gateway.auth.token under --update-only"
        fi
    fi
}

# Configure OpenClaw to use an external API provider instead of local Ollama
configure_api_provider() {
    local provider="$1"
    local api_key="$2"
    local model="$3"
    local oc_config="$OPENCLAW_HOME/openclaw.json"

    if ! command_exists python3; then
        warn "Python3 no disponible — configura API provider manualmente"
        return 1
    fi

    # Create openclaw.json if it doesn't exist
    if [[ ! -f "$oc_config" ]]; then
        echo '{}' > "$oc_config"
    fi

    python3 - "$oc_config" "$provider" "$api_key" "$model" <<'PYEOF'
import json, sys

config_path = sys.argv[1]
provider = sys.argv[2]
api_key = sys.argv[3]
model_full = sys.argv[4]  # e.g. "openrouter/anthropic/claude-3.5-haiku"

# Strip provider prefix from model id (openrouter/anthropic/claude-3.5-haiku → anthropic/claude-3.5-haiku)
model_id = model_full.split("/", 1)[1] if "/" in model_full else model_full

PROVIDER_CONFIG = {
    "groq": {
        "base_url": "https://api.groq.com/openai/v1",
        "context_window": 131072,
        "max_tokens": 4096,
    },
    "openrouter": {
        "base_url": "https://openrouter.ai/api/v1",
        "context_window": 200000,
        "max_tokens": 4096,
    },
    "together": {
        "base_url": "https://api.together.xyz/v1",
        "context_window": 131072,
        "max_tokens": 4096,
    },
}

try:
    with open(config_path) as f:
        c = json.load(f)

    pc = PROVIDER_CONFIG.get(provider)
    if not pc:
        print(f"error: provider desconocido: {provider}", file=sys.stderr)
        sys.exit(1)

    # Set models.providers.<provider> with the correct OpenClaw structure
    models = c.setdefault("models", {})
    providers = models.setdefault("providers", {})
    providers[provider] = {
        "baseUrl": pc["base_url"],
        "apiKey": api_key,
        "models": [{
            "id": model_id,
            "name": model_id,
            "contextWindow": pc["context_window"],
            "maxTokens": pc["max_tokens"],
        }]
    }

    with open(config_path, "w") as f:
        json.dump(c, f, indent=2)

    print(f"→ {model_id} (via {provider})")

except Exception as e:
    print(f"error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

phase_openclaw() {
    phase "3/7" "TNode Kernel"

    # Step 1: Ensure Node.js is present (OpenClaw needs it)
    ensure_nodejs

    # Step 2: Check if OpenClaw already installed and functional
    # Refresh PATH in case npm global bin is not yet visible
    hash -r 2>/dev/null || true
    local npm_global_bin=""
    if command_exists npm; then
        npm_global_bin="$(npm config get prefix 2>/dev/null)/bin"
        case ":$PATH:" in
            *":$npm_global_bin:"*) ;;
            *) [[ -d "$npm_global_bin" ]] && export PATH="$npm_global_bin:$PATH" ;;
        esac
    fi

    local openclaw_ok=0
    local oc_ver=""
    if command_exists openclaw && openclaw --version >/dev/null 2>&1; then
        oc_ver="$(openclaw --version 2>&1 | head -1 || echo "?")"
        openclaw_ok=1
    fi

    # When pinned, demand exact match. Anything else (older or newer) gets
    # reinstalled via npm@$OPENCLAW_PIN_VERSION.
    if [[ "$openclaw_ok" == "1" && -n "$OPENCLAW_PIN_VERSION" ]] \
       && ! grep -qF "$OPENCLAW_PIN_VERSION" <<<"$oc_ver"; then
        info "OpenClaw $oc_ver no coincide con pin $OPENCLAW_PIN_VERSION — reinstalando"
        openclaw_ok=0
    fi

    if [[ "$openclaw_ok" == "1" ]]; then
        success "OpenClaw ya instalado: $oc_ver"
        if [[ "$NO_OLLAMA" == "0" ]]; then
            info "Reconfigurando modelo → ollama/$MODEL"
            ollama launch openclaw --model "$MODEL" --yes 2>&1 | tail -5 || true
        fi
    else
        # Step 3: Install OpenClaw.
        # When pinned, the `ollama launch` path is skipped because it
        # always pulls whatever is current — bypassing the pin. We go
        # straight to npm with an explicit version. With pin disabled,
        # the original ollama-then-npm fallback chain runs.
        if [[ -z "$OPENCLAW_PIN_VERSION" && "$NO_OLLAMA" == "0" ]] \
           && command_exists ollama; then
            info "Instalando OpenClaw via ollama launch..."
            if run_with_progress "ollama launch openclaw" --estimate 60 ollama launch openclaw --model "$MODEL" --yes; then
                hash -r 2>/dev/null || true
            else
                warn "ollama launch openclaw falló — intentando via npm"
            fi
        fi

        # npm install (always when pinned; fallback otherwise).
        hash -r 2>/dev/null || true
        local need_npm_install=0
        if ! command_exists openclaw || ! openclaw --version >/dev/null 2>&1; then
            need_npm_install=1
        elif [[ -n "$OPENCLAW_PIN_VERSION" ]] \
             && ! grep -qF "$OPENCLAW_PIN_VERSION" <<<"$(openclaw --version 2>&1 | head -1)"; then
            need_npm_install=1
        fi
        if [[ "$need_npm_install" == "1" ]]; then
            if command_exists npm; then
                local npm_target="openclaw"
                if [[ -n "$OPENCLAW_PIN_VERSION" ]]; then
                    npm_target="openclaw@$OPENCLAW_PIN_VERSION"
                fi
                run_with_progress "Instalando TNode Kernel via npm ($npm_target)" --estimate 45 npm install -g "$npm_target"
                hash -r 2>/dev/null || true
            else
                warn "npm no disponible — no se puede instalar OpenClaw"
            fi
        fi

        # Verify
        hash -r 2>/dev/null || true
        if command_exists openclaw && openclaw --version >/dev/null 2>&1; then
            success "TNode Kernel instalado: $(openclaw --version 2>&1 | head -1 | sed 's/OpenClaw/TNode Kernel/')"
        else
            warn "OpenClaw no se encontró en PATH después de instalar"
        fi
    fi

    # ── Post-install config (runs as tnode user) ──
    if command_exists openclaw && openclaw --version >/dev/null 2>&1; then

        # Resolve API key before switching to tnode user (may need interactive prompt)
        if [[ "$USE_API" == "1" ]]; then
            if [[ -z "$API_KEY" ]]; then
                local env_var_name
                env_var_name="$(echo "${API_PROVIDER}_API_KEY" | tr '[:lower:]' '[:upper:]')"
                eval "API_KEY=\"\${${env_var_name}:-}\""
            fi
            if [[ -z "$API_KEY" ]]; then
                if [[ "$API_PROVIDER" == "openrouter" ]]; then
                    # OpenRouter keys are minted per-node from the mobile app
                    # after pairing. The tnode-config-sync daemon installed
                    # below fetches the key via pullLLMConfig (HMAC) when it
                    # receives the apply_openrouter_key command from the app.
                    info "API key de OpenRouter: se obtendrá tras pair + mint (tnode-config-sync)"
                else
                    local provider_upper
                    provider_upper="$(echo "$API_PROVIDER" | tr '[:lower:]' '[:upper:]')"
                    if [[ "$YES" == "1" ]]; then
                        die "Modo API requiere --api-key <key> o variable de entorno ${provider_upper}_API_KEY"
                    fi
                    echo ""
                    echo -en "    ${YELLOW}API Key para $API_PROVIDER: ${NC}"
                    read -r API_KEY < /dev/tty 2>/dev/null || true
                    if [[ -z "$API_KEY" ]]; then
                        die "API key requerida para modo --api $API_PROVIDER"
                    fi
                fi
            fi
        fi

        # All OpenClaw config runs as tnode user
        openclaw_configure_as_tnode
    fi
}

# Configure OpenClaw and transfer ownership to tnode user
openclaw_configure_as_tnode() {
    # Ensure OPENCLAW_HOME exists and is owned by tnode before plugin install
    mkdir -p "$OPENCLAW_HOME"
    chown -R "$TNODE_USER":"$TNODE_USER" "$OPENCLAW_HOME" 2>/dev/null || true

    # Install web-search plugin as tnode (creates openclaw.json)
    if [[ -d "$OPENCLAW_HOME/extensions/openclaw-web-search" ]]; then
        success "Plugin web-search ya instalado"
    else
        run_with_progress "Instalando plugin web-search" --estimate 15 run_as_tnode openclaw plugins install @ollama/openclaw-web-search || true
    fi

    # Configure gateway bind (writes to openclaw.json — run as root, chown after)
    info "Configurando gateway para acceso remoto..."
    local bind_result
    bind_result="$(configure_gateway_bind "0" 2>&1 || true)"
    if [[ -n "$bind_result" ]]; then
        success "Gateway $bind_result"
    fi

    if [[ "$USE_API" == "1" ]]; then
        if [[ -z "$API_KEY" ]] && [[ "$API_PROVIDER" == "openrouter" ]]; then
            info "Provider $API_PROVIDER: configuración diferida (tnode-config-sync la aplicará tras comando apply_openrouter_key)"
        else
            info "Configurando provider $API_PROVIDER → $MODEL"
            local api_result
            api_result="$(configure_api_provider "$API_PROVIDER" "$API_KEY" "$MODEL" 2>&1 || true)"
            if [[ -n "$api_result" ]]; then
                success "Modelo: $api_result"
            fi
        fi
    else
        local model_id="ollama/$MODEL"
        info "Configurando modelo → $model_id"
        local model_result
        model_result="$(configure_openclaw_model "$model_id" 2>&1 || true)"
        if [[ -n "$model_result" ]]; then
            success "Modelo: $model_result"
        fi
    fi

    # Transfer all config ownership to tnode before starting services
    chown -R "$TNODE_USER":"$TNODE_USER" "$OPENCLAW_HOME" 2>/dev/null || true

    # Install gateway service as tnode
    run_with_progress "Instalando gateway service" --estimate 10 run_as_tnode openclaw gateway install || true

    # Start gateway as tnode user
    local tnode_uid
    tnode_uid="$(id -u "$TNODE_USER" 2>/dev/null || echo "")"
    if [[ "$OS" != "Darwin" ]] && [[ "$(id -u)" == "0" ]] && [[ -n "$tnode_uid" ]]; then
        # From root: start systemd --user service for tnode via XDG_RUNTIME_DIR
        su - "$TNODE_USER" -c "export XDG_RUNTIME_DIR=/run/user/$tnode_uid; systemctl --user start openclaw-gateway" 2>/dev/null || true
    else
        systemctl --user start openclaw-gateway 2>&1 || true
    fi

    # Verify gateway is running
    sleep 2
    if curl -sf http://localhost:18789/ >/dev/null 2>&1 || \
       run_as_tnode openclaw gateway status >/dev/null 2>&1; then
        success "Gateway daemon activo (puerto 18789)"
    else
        warn "Gateway puede tardar unos segundos en iniciar"
        info "Verifica con: su - $TNODE_USER -c 'openclaw gateway status'"
    fi
}

# ═════════════════════════════════════════════
# PHASE 4: Tailscale
# ═════════════════════════════════════════════
# ═════════════════════════════════════════════
# PHASE 4: Cloudflare Tunnel
# ═════════════════════════════════════════════
phase_tunnel() {
    phase "4/7" "TBrain Tunnel"

    if [[ "$NO_TUNNEL" == "1" ]]; then
        info "Saltando Cloudflare Tunnel (--no-tunnel)"
        return 0
    fi

    # ── 4a: Install cloudflared ──
    local cfd_bin=""
    if command_exists cloudflared; then
        cfd_bin="$(command -v cloudflared)"
    fi

    if [[ -n "$cfd_bin" ]]; then
        local cfd_ver
        cfd_ver="$("$cfd_bin" version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "?")"
        success "cloudflared $cfd_ver ya instalado"
    else
        info "Instalando cloudflared..."
        case "$OS" in
            Darwin)
                ensure_brew_on_path
                if command_exists brew; then
                    run_with_progress "Instalando cloudflared via Homebrew" --estimate 20 brew install cloudflare/cloudflare/cloudflared
                    cfd_bin="$(command -v cloudflared 2>/dev/null || true)"
                    success "cloudflared instalado via Homebrew"
                else
                    warn "Homebrew no disponible — instala cloudflared manualmente"
                    warn "https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
                    NO_TUNNEL=1
                    return 0
                fi
                ;;
            Linux)
                local arch
                arch="$(uname -m)"
                local cfd_arch="amd64"
                case "$arch" in
                    aarch64|arm64) cfd_arch="arm64" ;;
                    armv7*|armhf) cfd_arch="arm" ;;
                esac
                local cfd_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cfd_arch}"
                run_with_progress "Descargando cloudflared" --estimate 15 bash -c "curl -fsSL '$cfd_url' -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared"
                cfd_bin="/usr/local/bin/cloudflared"
                if [[ -x "$cfd_bin" ]]; then
                    success "cloudflared instalado"
                else
                    warn "No se pudo instalar cloudflared"
                    NO_TUNNEL=1
                    return 0
                fi
                ;;
        esac
    fi

    # ── 4b: Provision tunnel ──
    local tunnel_json="$OPENCLAW_HOME/tunnel.json"

    # Check if tunnel already provisioned
    if [[ -f "$tunnel_json" ]]; then
        TUNNEL_DOMAIN="$(python3 -c "import json; print(json.load(open('$tunnel_json')).get('domain',''))" 2>/dev/null || true)"
        if [[ -n "$TUNNEL_DOMAIN" ]]; then
            success "Tunnel ya provisionado: $TUNNEL_DOMAIN"
            # Reconfigure gateway to loopback for tunnel mode
            configure_gateway_bind "1" >/dev/null 2>&1
            return 0
        fi
    fi

    # Past this point we'd call the provisioning API and rotate nodeId +
    # nodeSecret. Refuse in --update-only mode — the operator should run
    # a full install if they really want a fresh tunnel.
    if [[ "$UPDATE_ONLY" == "1" ]]; then
        die "phase_tunnel: --update-only requires existing $tunnel_json with a 'domain' field. Run a full install to provision."
    fi

    if [[ -n "$TUNNEL_TOKEN" ]]; then
        # Pre-provisioned token (--tunnel-token flag)
        info "Usando tunnel token pre-provisionado"
    else
        # Call provisioning API
        info "Provisionando tunnel via TBrain API..."

        # 1. Fetch a short-lived HMAC token from Firebase Function.
        local token_response ptoken_ts ptoken_nonce ptoken_sig
        token_response="$(curl -fsSL "$PROVISION_TOKEN_URL" --max-time 15 2>/dev/null || true)"
        if [[ -z "$token_response" ]]; then
            warn "No se pudo obtener token de provisioning"
            warn "Puedes reintentar luego o usar --with-tailscale como alternativa"
            NO_TUNNEL=1
            return 0
        fi
        ptoken_ts="$(echo "$token_response" | python3 -c "import json,sys; print(json.load(sys.stdin)['timestamp'])" 2>/dev/null || true)"
        ptoken_nonce="$(echo "$token_response" | python3 -c "import json,sys; print(json.load(sys.stdin)['nonce'])" 2>/dev/null || true)"
        ptoken_sig="$(echo "$token_response" | python3 -c "import json,sys; print(json.load(sys.stdin)['signature'])" 2>/dev/null || true)"
        if [[ -z "$ptoken_ts" ]] || [[ -z "$ptoken_nonce" ]] || [[ -z "$ptoken_sig" ]]; then
            warn "Token de provisioning inválido"
            NO_TUNNEL=1
            return 0
        fi

        # 2. Call the Worker with the HMAC headers.
        local provision_response
        provision_response="$(curl -fsSL -X POST "$TUNNEL_API_URL" \
            -H "Authorization: Bearer $ptoken_sig" \
            -H "X-Provision-Timestamp: $ptoken_ts" \
            -H "X-Provision-Nonce: $ptoken_nonce" \
            -H "Content-Type: application/json" \
            -d "{\"label\": \"$(hostname -s 2>/dev/null || echo 'tnode')\"}" \
            --max-time 30 2>/dev/null || true)"

        if [[ -z "$provision_response" ]]; then
            warn "No se pudo contactar la API de provisioning"
            warn "Puedes reintentar luego o usar --with-tailscale como alternativa"
            NO_TUNNEL=1
            return 0
        fi

        # Extract fields from response
        local tunnel_id node_id
        TUNNEL_TOKEN="$(echo "$provision_response" | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])" 2>/dev/null || true)"
        tunnel_id="$(echo "$provision_response" | python3 -c "import json,sys; print(json.load(sys.stdin)['tunnelId'])" 2>/dev/null || true)"
        node_id="$(echo "$provision_response" | python3 -c "import json,sys; print(json.load(sys.stdin)['nodeId'])" 2>/dev/null || true)"
        TUNNEL_DOMAIN="$(echo "$provision_response" | python3 -c "import json,sys; print(json.load(sys.stdin)['domain'])" 2>/dev/null || true)"

        if [[ -z "$TUNNEL_TOKEN" ]] || [[ -z "$TUNNEL_DOMAIN" ]]; then
            warn "Respuesta de provisioning inválida"
            warn "Respuesta: $provision_response"
            NO_TUNNEL=1
            return 0
        fi

        # Save tunnel config
        python3 -c "
import json
data = {
    'mode': 'cloudflare',
    'tunnelId': '$tunnel_id',
    'nodeId': '$node_id',
    'domain': '$TUNNEL_DOMAIN',
    'provisionedAt': __import__('datetime').datetime.utcnow().isoformat() + 'Z'
}
with open('$tunnel_json', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
        chown "$TNODE_USER":"$TNODE_USER" "$tunnel_json" 2>/dev/null || true
        success "Tunnel provisionado: $TUNNEL_DOMAIN"

        # Register this node for chat-sync to Firestore. The installer uses
        # the same short-lived HMAC token flow as tunnel provisioning; the
        # Firebase Function returns a per-node secret that only ever lives
        # on THIS machine (watcher) and in Firestore (admin-only read).
        if register_node_sync "$node_id" "$tunnel_json"; then
            # Install the Firestore mirror daemon — mirrors assistant turns
            # so chat history survives app-close. Depends on nodeSecret
            # just written above.
            install_tnode_chat_sync
            # Install the telemetry sidecar — WS proxy on :18790 that
            # forwards to :18789 and injects live events (usage, health…)
            # per skills/TELEMETRY.md. The Cloudflare Tunnel ingress is
            # configured by the provisioning Worker to point at :18790, so
            # this daemon is required for the client to reach the gateway.
            install_tnode_telemetry
        else
            warn "Registro chat-sync falló (no bloqueante). Podrás reintentar con: tnode-chat-sync reregister"
        fi
    fi

    # ── 4c: Install cloudflared service ──
    info "Instalando servicio cloudflared..."
    case "$OS" in
        Linux)
            # Install as system service (runs as root, tunnel handles its own permissions)
            "$cfd_bin" service install "$TUNNEL_TOKEN" 2>/dev/null || true
            if systemctl is-active --quiet cloudflared 2>/dev/null; then
                success "Servicio cloudflared activo"
            else
                systemctl start cloudflared 2>/dev/null || true
                sleep 2
                if systemctl is-active --quiet cloudflared 2>/dev/null; then
                    success "Servicio cloudflared iniciado"
                else
                    warn "cloudflared service no arrancó — verifica con: systemctl status cloudflared"
                fi
            fi
            ;;
        Darwin)
            "$cfd_bin" service install "$TUNNEL_TOKEN" 2>/dev/null || true
            success "Servicio cloudflared instalado"
            ;;
    esac

    # ── 4d: Reconfigure gateway to loopback (tunnel handles external) ──
    info "Reconfigurando gateway para modo tunnel..."
    local rebind_result
    rebind_result="$(configure_gateway_bind "1" 2>&1 || true)"
    if [[ -n "$rebind_result" ]]; then
        success "Gateway $rebind_result"
    fi

    # ── 4e: Verify tunnel is working ──
    info "Verificando conectividad del tunnel..."
    local tunnel_ok=0
    for i in 1 2 3 4 5 6; do
        if curl -sf "https://$TUNNEL_DOMAIN/" --max-time 5 >/dev/null 2>&1; then
            tunnel_ok=1
            break
        fi
        sleep 3
    done

    if [[ "$tunnel_ok" == "1" ]]; then
        success "Tunnel verificado: https://$TUNNEL_DOMAIN"
    else
        warn "Tunnel provisionado pero aún no responde — puede tardar unos segundos más"
        info "Verifica con: curl -sf https://$TUNNEL_DOMAIN/"
    fi

    # ── 4f: Report tunnel info to the provisioning CF (auto-pair mode only) ──
    # This lets the Flutter app build a NodeConfig for the cloud-provisioned
    # node (serverUrl + gatewayToken) without the user scanning a QR.
    if [[ "${TNODE_AUTO_PAIR:-}" == "1" ]] && [[ -n "$TUNNEL_DOMAIN" ]]; then
        local gw_token=""
        # In auto-pair (cloud) mode gateway.bind=loopback, so the tunnel
        # handles external traffic and `openclaw qr` refuses to render a
        # code. Read the token straight from openclaw.json instead.
        local oc_json="/home/tnode/.openclaw/openclaw.json"
        if command -v python3 >/dev/null 2>&1 && [[ -r "$oc_json" ]]; then
            gw_token=$(python3 -c "
import json
try:
    with open('$oc_json') as f:
        d = json.load(f)
    print(d.get('gateway', {}).get('auth', {}).get('token') or '')
except Exception:
    pass
" 2>/dev/null || echo "")
        fi

        if [[ -n "$gw_token" ]]; then
            local server_url="wss://${TUNNEL_DOMAIN}/ws"
            # tunnelId (CF UUID) is needed by `deleteAgent` to deprovision the
            # tunnel cleanly. Read from tunnel.json (written in phase 4b).
            local tunnel_uuid=""
            local tunnel_json_path="$OPENCLAW_HOME/tunnel.json"
            if command -v python3 >/dev/null 2>&1 && [[ -r "$tunnel_json_path" ]]; then
                tunnel_uuid=$(python3 -c "
import json
try:
    with open('$tunnel_json_path') as f:
        d = json.load(f)
    print(d.get('tunnelId') or '')
except Exception:
    pass
" 2>/dev/null || echo "")
            fi
            local extra_json
            extra_json=$(python3 -c "
import json
print(json.dumps({
    'tunnelDomain': '$TUNNEL_DOMAIN',
    'tunnelId':     '$tunnel_uuid',
    'gatewayToken': '$gw_token',
    'serverUrl':    '$server_url',
}))
" 2>/dev/null || echo "{}")
            report_progress_heartbeat "tunnel_ready" "$extra_json"
            info "tunnel_ready heartbeat enviado (domain=$TUNNEL_DOMAIN)"
        else
            warn "No se pudo extraer gatewayToken — el app tendrá que resolver manualmente"
        fi
    fi
}

# ═════════════════════════════════════════════
# PHASE 5: Tailscale (optional fallback)
# ═════════════════════════════════════════════
phase_tailscale() {
    phase "5/7" "Tailscale"

    # Tailscale is no longer installed by default — only with --with-tailscale
    if [[ "$WITH_TAILSCALE" != "1" ]]; then
        info "Saltando Tailscale (usa --with-tailscale para instalar)"
        return 0
    fi

    local ts_bin=""
    # macOS: Tailscale CLI is at /usr/local/bin/tailscale (from cask)
    if [[ -x "/usr/local/bin/tailscale" ]]; then
        ts_bin="/usr/local/bin/tailscale"
    elif command_exists tailscale; then
        ts_bin="$(command -v tailscale)"
    fi

    if [[ -n "$ts_bin" ]]; then
        local ts_ver
        ts_ver="$("$ts_bin" version 2>&1 | head -1 || echo "?")"
        success "Tailscale $ts_ver ya instalado"
    else
        info "Instalando Tailscale..."
        case "$OS" in
            Darwin)
                ensure_brew_on_path
                if command_exists brew; then
                    run_with_progress "Instalando Tailscale via Homebrew" --estimate 30 brew install --cask tailscale
                    # Start Tailscale app
                    open -a Tailscale 2>/dev/null || true
                    ts_bin="/usr/local/bin/tailscale"
                    success "Tailscale instalado via Homebrew"
                else
                    warn "Homebrew no disponible — instala Tailscale manualmente: https://tailscale.com/download"
                    return 0
                fi
                ;;
            Linux)
                run_with_progress "Instalando Tailscale" --estimate 20 bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
                hash -r 2>/dev/null || true
                ts_bin="$(command -v tailscale 2>/dev/null || true)"
                if [[ -z "$ts_bin" ]] && [[ -x "/usr/bin/tailscale" ]]; then
                    ts_bin="/usr/bin/tailscale"
                fi
                # Enable and start tailscaled service
                if command_exists systemctl; then
                    systemctl enable tailscaled 2>/dev/null || true
                    systemctl start tailscaled 2>/dev/null || true
                fi
                success "Tailscale instalado"
                ;;
        esac
    fi

    # Check connection and auto-connect if needed
    if [[ -n "$ts_bin" ]]; then
        local ts_ip
        ts_ip="$("$ts_bin" ip -4 2>/dev/null || true)"
        if [[ -n "$ts_ip" ]]; then
            success "Tailscale conectado: $ts_ip"
        else
            # Auto-run tailscale up
            warn "Tailscale instalado pero no conectado"
            info "Conectando Tailscale..."
            echo ""
            echo -e "    ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "    ${YELLOW}  Tailscale va a mostrar un link de autenticación.${NC}"
            echo -e "    ${YELLOW}  Ábrelo en tu navegador y autentícate.${NC}"
            echo -e "    ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""

            # Use sudo on Linux (needed for tailscale up), not on macOS
            local ts_up_cmd=("$ts_bin" up)
            if [[ "$OS" == "Linux" ]] && [[ "$(id -u)" != "0" ]]; then
                ts_up_cmd=(sudo "$ts_bin" up)
            fi

            # Run tailscale up — this blocks until authenticated
            if "${ts_up_cmd[@]}" 2>&1; then
                sleep 2
                ts_ip="$("$ts_bin" ip -4 2>/dev/null || true)"
                if [[ -n "$ts_ip" ]]; then
                    success "Tailscale conectado: $ts_ip"
                else
                    warn "Tailscale up completó pero no se obtuvo IP"
                    info "Verifica con: tailscale status"
                fi
            else
                warn "tailscale up falló"
                info "Ejecuta manualmente: sudo tailscale up"
                info "Luego corre 'tnode-qr' para generar el QR de pairing"
            fi
        fi
    fi
}

# ═════════════════════════════════════════════
# PHASE 5: TNode helpers
# ═════════════════════════════════════════════
phase_helpers() {
    phase "6/7" "TNode helpers"

    # ── 5a: Install qrencode (for terminal QR display) — as root ──
    install_qrencode

    # ── 5b: tnode-qr (installed in tnode's ~/bin) ──
    run_as_tnode mkdir -p "$TNODE_BIN"
    # Write script to temp then move (run_as_tnode can't do heredoc easily)
    local tmp_qr
    tmp_qr="$(mktemp)"
    write_tnode_qr "$tmp_qr"
    chmod +x "$tmp_qr"
    mv "$tmp_qr" "$TNODE_BIN/tnode-qr"
    chown "$TNODE_USER":"$TNODE_USER" "$TNODE_BIN/tnode-qr" 2>/dev/null || true
    success "tnode-qr → $TNODE_BIN/tnode-qr"

    # Ensure ~/bin is in PATH for tnode user
    export PATH="$TNODE_BIN:$PATH"
    ensure_path_in_rc_for_tnode

    # ── 5c: pair-watch ──
    install_pair_watch

    # ── 5d: tnode-config-sync (event-driven command executor + state
    # mirror; replaces llm-config-watcher). Runs on every node regardless
    # of provider so the Flutter app can query state/current and dispatch
    # commands. The legacy install_llm_config_watcher function above is
    # kept for rollback but no longer wired into phase_helpers. ──
    install_tnode_config_sync
}

install_qrencode() {
    if command_exists qrencode; then
        success "qrencode ya instalado"
        return 0
    fi

    info "Instalando qrencode (para QR en terminal)..."
    case "$OS" in
        Darwin)
            ensure_brew_on_path
            if command_exists brew; then
                brew install qrencode 2>&1 | tail -2 || true
            fi
            ;;
        Linux)
            if command_exists apt-get; then
                apt-get install -y qrencode 2>&1 | tail -2 || true
            elif command_exists dnf; then
                dnf install -y qrencode 2>&1 | tail -2 || true
            elif command_exists yum; then
                yum install -y qrencode 2>&1 | tail -2 || true
            fi
            ;;
    esac

    if command_exists qrencode; then
        success "qrencode instalado"
    else
        info "qrencode no disponible — setup code se mostrará como texto"
    fi
}

write_tnode_qr() {
    local dest="$1"
    cat > "$dest" << 'TNODE_QR_SCRIPT'
#!/usr/bin/env bash
# tnode-qr — Generate OpenClaw setup code for TNode pairing.
#
# URL priority:
#   1. Cloudflare Tunnel (wss://<domain>/ws) — from ~/.openclaw/tunnel.json
#   2. Tailscale IP (ws://<ts-ip>:<port>) — if Tailscale is connected
#   3. LAN IP (ws://<lan-ip>:<port>) — local dev fallback
#
# Usage:
#   tnode-qr                    # auto-detect best URL
#   tnode-qr --mode tunnel      # force tunnel mode
#   tnode-qr --mode tailscale   # force Tailscale mode
#   tnode-qr --mode lan         # force LAN mode
#   tnode-qr --json             # output JSON
#   tnode-qr --setup-code-only  # output only the setup code
set -euo pipefail

MODE="auto"
EXTRA_ARGS=()

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="${2:?--mode requires: auto|tunnel|tailscale|lan}"; shift ;;
        *) EXTRA_ARGS+=("$1") ;;
    esac
    shift
done

# Ensure PATH has common locations
for _p in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
    case ":$PATH:" in *":$_p:"*) ;; *) [ -d "$_p" ] && export PATH="$_p:$PATH" ;; esac
done

# Detect OpenClaw binary
OC_BIN=""
for _p in "$(command -v openclaw 2>/dev/null || true)" \
          "/opt/homebrew/bin/openclaw" \
          "/usr/local/bin/openclaw" \
          "$HOME/.local/bin/openclaw"; do
    if [[ -n "$_p" ]] && [[ -x "$_p" ]]; then
        OC_BIN="$_p"
        break
    fi
done

if [[ -z "$OC_BIN" ]]; then
    echo "Error: openclaw no encontrado" >&2
    exit 1
fi

# Read gateway port from config (default 18789)
GW_PORT="18789"
if command -v python3 >/dev/null 2>&1 && [[ -f "$HOME/.openclaw/openclaw.json" ]]; then
    _port="$(python3 -c "
import json
try:
    with open('$HOME/.openclaw/openclaw.json') as f: c = json.load(f)
    print(c.get('gateway',{}).get('port', 18789))
except: print(18789)
" 2>/dev/null || echo 18789)"
    GW_PORT="${_port:-18789}"
fi

# ── Resolve PUBLIC_URL based on mode/priority ──

PUBLIC_URL=""
URL_SOURCE=""

# Priority 1: Cloudflare Tunnel
resolve_tunnel() {
    local tunnel_json="$HOME/.openclaw/tunnel.json"
    if [[ -f "$tunnel_json" ]] && command -v python3 >/dev/null 2>&1; then
        local domain
        domain="$(python3 -c "
import json
with open('$tunnel_json') as f: d = json.load(f)
print(d.get('domain', ''))
" 2>/dev/null || true)"
        if [[ -n "$domain" ]]; then
            PUBLIC_URL="wss://${domain}/ws"
            URL_SOURCE="tunnel"
        fi
    fi
}

# Priority 2: Tailscale
resolve_tailscale() {
    local ts_bin=""
    if [[ -x "/usr/local/bin/tailscale" ]]; then
        ts_bin="/usr/local/bin/tailscale"
    elif command -v tailscale >/dev/null 2>&1; then
        ts_bin="$(command -v tailscale)"
    elif [[ -x "/usr/bin/tailscale" ]]; then
        ts_bin="/usr/bin/tailscale"
    fi

    if [[ -n "$ts_bin" ]]; then
        local ts_ip
        ts_ip="$("$ts_bin" ip -4 2>/dev/null || true)"
        if [[ -n "$ts_ip" ]]; then
            PUBLIC_URL="ws://${ts_ip}:${GW_PORT}"
            URL_SOURCE="tailscale"
        fi
    fi
}

# Priority 3: LAN IP
resolve_lan() {
    local lan_ip=""
    if command -v hostname >/dev/null 2>&1; then
        lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    fi
    if [[ -z "$lan_ip" ]] && command -v ipconfig >/dev/null 2>&1; then
        lan_ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
    fi
    if [[ -n "$lan_ip" ]]; then
        PUBLIC_URL="ws://${lan_ip}:${GW_PORT}"
        URL_SOURCE="lan"
    fi
}

case "$MODE" in
    auto)
        resolve_tunnel
        [[ -z "$PUBLIC_URL" ]] && resolve_tailscale
        [[ -z "$PUBLIC_URL" ]] && resolve_lan
        ;;
    tunnel)
        resolve_tunnel
        if [[ -z "$PUBLIC_URL" ]]; then
            echo "Error: No se encontró tunnel configurado" >&2
            echo "Verifica ~/.openclaw/tunnel.json" >&2
            exit 1
        fi
        ;;
    tailscale)
        resolve_tailscale
        if [[ -z "$PUBLIC_URL" ]]; then
            echo "Error: Tailscale no encontrado o no conectado" >&2
            echo "Ejecuta: sudo tailscale up" >&2
            exit 1
        fi
        ;;
    lan)
        resolve_lan
        if [[ -z "$PUBLIC_URL" ]]; then
            echo "Error: No se pudo detectar IP LAN" >&2
            exit 1
        fi
        ;;
    *)
        echo "Error: modo inválido '$MODE' (usa: auto|tunnel|tailscale|lan)" >&2
        exit 1
        ;;
esac

if [[ -z "$PUBLIC_URL" ]]; then
    echo "Error: no se pudo resolver URL de conexión" >&2
    echo "Opciones:" >&2
    echo "  1. Instala Cloudflare Tunnel (re-ejecuta el installer)" >&2
    echo "  2. Instala Tailscale: https://tailscale.com/download" >&2
    echo "  3. Usa --mode lan para acceso local" >&2
    exit 1
fi

# ── Generate setup code ──

# Generate setup code with localhost, then swap URL
SETUP_CODE=$("$OC_BIN" qr --url "ws://127.0.0.1:${GW_PORT}" --setup-code-only 2>/dev/null || true)
if [[ -z "$SETUP_CODE" ]]; then
    echo "Error: no se pudo generar setup code" >&2
    echo "Verifica que el gateway esté corriendo: openclaw gateway status" >&2
    exit 1
fi

# Swap URL using Python (stdlib base64 + json)
NEW_CODE=$(python3 -c "
import base64, json, sys
code = sys.argv[1]
url = sys.argv[2]
padded = code + '=' * (4 - len(code) % 4)
data = json.loads(base64.urlsafe_b64decode(padded))
data['url'] = url
print(base64.urlsafe_b64encode(json.dumps(data).encode()).decode().rstrip('='))
" "$SETUP_CODE" "$PUBLIC_URL")

# ── Output ──

if [[ " ${EXTRA_ARGS[*]:-} " == *" --json "* ]]; then
    echo "{\"setupCode\":\"$NEW_CODE\",\"gatewayUrl\":\"$PUBLIC_URL\",\"source\":\"$URL_SOURCE\"}"
elif [[ " ${EXTRA_ARGS[*]:-} " == *" --setup-code-only "* ]]; then
    echo "$NEW_CODE"
else
    echo ""
    echo "  Setup code (paste in TNode app):"
    echo ""
    echo "  $NEW_CODE"
    echo ""
    echo "  Gateway: $PUBLIC_URL ($URL_SOURCE)"
    echo ""
    # Show QR if qrencode is available
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ANSIUTF8 "$NEW_CODE"
    else
        echo "  (instala qrencode para ver QR en terminal)"
    fi
fi
TNODE_QR_SCRIPT
}

# ── register_node_sync ─────────────────────────────────────────
# Called right after the tunnel is provisioned (so $node_id is known).
# Fetches an HMAC token from getProvisionToken, POSTs registerNodeSync,
# receives a per-node secret and stores it at ~/.openclaw/tnode-chat-sync.json
# for the tnode-chat-sync watcher to pick up.
#
# Usage: register_node_sync <nodeId> <tunnel_json_path>
register_node_sync() {
    local node_id="$1"
    local tunnel_json="$2"
    local sync_json="$OPENCLAW_HOME/tnode-chat-sync.json"

    if [[ -z "$node_id" ]]; then
        warn "register_node_sync: nodeId vacío, skip"
        return 1
    fi

    # AUTO-PAIR MODE: the provisionTNode CF already wrote
    # nodeSyncRegistrations/{nodeId} with the nodeSecret before the droplet
    # booted. All we need locally is the JSON config file that the chat-sync
    # watcher reads — skip the HMAC dance entirely.
    if [[ "${TNODE_AUTO_PAIR:-}" == "1" ]]; then
        info "chat-sync auto-pair: using pre-provisioned nodeSecret"
        mkdir -p "$OPENCLAW_HOME"
        # Watchers (tnode-chat-sync, tnode-config-sync) use THIS nodeId as the
        # path for commands / chats / state. The Flutter app keys those paths
        # by the tunnel nodeId (extracted from serverUrl=wss://tnode-<id>…),
        # NOT the provisioning nodeId. So write the tunnel id here.
        # `reportProvisioningProgress` mirrors `nodeSyncRegistrations/{provId}`
        # to `nodeSyncRegistrations/{tunnelId}` on the `tunnel_ready` heartbeat
        # so mintNodeToken accepts it.
        python3 - "$sync_json" <<PYEOF
import json, os, sys, datetime
path = sys.argv[1]
data = {
    "nodeId":        "${node_id}",
    "nodeSecret":    "${TNODE_NODE_SECRET}",
    "mintUrl":       "${MINT_NODE_TOKEN_URL}",
    "pullUrl":       "${PULL_LLM_CONFIG_URL}",
    "registeredAt":  datetime.datetime.utcnow().isoformat() + "Z",
    "autoPair":      True,
    "ownerUid":      "${TNODE_OWNER_UID}",
    "provisioningNodeId": "${TNODE_NODE_ID}",
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
os.chmod(path, 0o600)
PYEOF
        success "chat-sync configurado (auto-pair, nodeId=$node_id)"
        report_progress_heartbeat "chat_sync_registered"
        return 0
    fi

    if [[ -f "$sync_json" ]]; then
        # Already registered — preserve secret, but ensure pullUrl is present
        # so older installs pick up the tnode-config-sync flow on upgrade
        # (pullUrl is still used by the apply_openrouter_key handler).
        python3 -c "
import json
path = '$sync_json'
try:
    d = json.load(open(path))
    if d.get('pullUrl') != '$PULL_LLM_CONFIG_URL':
        d['pullUrl'] = '$PULL_LLM_CONFIG_URL'
        with open(path, 'w') as f:
            json.dump(d, f, indent=2)
except Exception:
    pass
" 2>/dev/null || true
        success "chat-sync ya registrado (preservando secret existente)"
        return 0
    fi

    info "Registrando nodo para chat-sync..."

    # 1. Short-lived HMAC token from Firebase.
    local token_response ptoken_ts ptoken_nonce ptoken_sig
    token_response="$(curl -fsSL "$PROVISION_TOKEN_URL" --max-time 15 2>/dev/null || true)"
    if [[ -z "$token_response" ]]; then
        warn "No se pudo obtener provisioning token para chat-sync"
        return 1
    fi
    ptoken_ts="$(echo "$token_response" | python3 -c "import json,sys; print(json.load(sys.stdin)['timestamp'])" 2>/dev/null || true)"
    ptoken_nonce="$(echo "$token_response" | python3 -c "import json,sys; print(json.load(sys.stdin)['nonce'])" 2>/dev/null || true)"
    ptoken_sig="$(echo "$token_response" | python3 -c "import json,sys; print(json.load(sys.stdin)['signature'])" 2>/dev/null || true)"
    if [[ -z "$ptoken_ts" ]] || [[ -z "$ptoken_nonce" ]] || [[ -z "$ptoken_sig" ]]; then
        warn "Token de chat-sync inválido"
        return 1
    fi

    # 2. Exchange with registerNodeSync.
    local register_response node_secret
    register_response="$(curl -fsSL -X POST "$REGISTER_NODE_SYNC_URL" \
        -H "Content-Type: application/json" \
        -d "$(python3 -c "
import json, sys
print(json.dumps({
    'nodeId': '$node_id',
    'timestamp': '$ptoken_ts',
    'nonce': '$ptoken_nonce',
    'signature': '$ptoken_sig',
}))
")" \
        --max-time 30 2>/dev/null || true)"

    if [[ -z "$register_response" ]]; then
        warn "registerNodeSync no respondió"
        return 1
    fi
    node_secret="$(echo "$register_response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('nodeSecret',''))" 2>/dev/null || true)"
    if [[ -z "$node_secret" ]]; then
        warn "registerNodeSync devolvió respuesta sin nodeSecret: $register_response"
        return 1
    fi

    # 3. Persist. Permisos 600 (legible solo por el watcher user).
    python3 -c "
import json, os
data = {
    'nodeId': '$node_id',
    'nodeSecret': '$node_secret',
    'mintUrl': '$MINT_NODE_TOKEN_URL',
    'pullUrl': '$PULL_LLM_CONFIG_URL',
    'registeredAt': __import__('datetime').datetime.utcnow().isoformat() + 'Z',
}
path = '$sync_json'
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
os.chmod(path, 0o600)
"
    chown "$TNODE_USER":"$TNODE_USER" "$sync_json" 2>/dev/null || true
    success "chat-sync registrado (secret en $sync_json)"
    return 0
}

install_pair_watch() {
    local DEST_SCRIPTS="$OPENCLAW_HOME/scripts"
    local CONFIG_PATH="$OPENCLAW_HOME/pair-watch.json"
    local LOG_DIR="$OPENCLAW_HOME/logs"

    mkdir -p "$DEST_SCRIPTS" "$LOG_DIR" "$OPENCLAW_HOME/devices"
    chown -R "$TNODE_USER":"$TNODE_USER" "$OPENCLAW_HOME" 2>/dev/null || true

    # ── pair_watch.py (embedded) ──
    write_pair_watch_py "$DEST_SCRIPTS/pair_watch.py"
    chmod +x "$DEST_SCRIPTS/pair_watch.py"

    # ── pair-watch CLI wrapper (embedded) ──
    write_pair_watch_cli "$DEST_SCRIPTS/pair-watch"
    chmod +x "$DEST_SCRIPTS/pair-watch"

    success "pair-watch scripts → $DEST_SCRIPTS"

    # ── Config (idempotent) ──
    if [[ ! -f "$CONFIG_PATH" ]]; then
        cat > "$CONFIG_PATH" <<'PWCONFIG'
{
  "mode": "auto",
  "trustedNetworks": [
    "127.0.0.0/8",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "100.64.0.0/10"
  ],
  "approveTimeoutMs": 15000,
  "logLevel": "info"
}
PWCONFIG
        success "Config pair-watch creada (mode=auto)"
    else
        success "Config pair-watch preservada"
    fi

    # ── Detect openclaw binary and substitute in script ──
    local oc_bin
    oc_bin="$(command -v openclaw 2>/dev/null || true)"
    if [[ -n "$oc_bin" ]] && [[ "$oc_bin" != "/opt/homebrew/bin/openclaw" ]]; then
        if [[ "$OS" == "Darwin" ]]; then
            sed -i '' "s|/opt/homebrew/bin/openclaw|$oc_bin|g" "$DEST_SCRIPTS/pair_watch.py"
        else
            sed -i "s|/opt/homebrew/bin/openclaw|$oc_bin|g" "$DEST_SCRIPTS/pair_watch.py"
        fi
    fi

    # ── OS-specific watcher ──
    touch "$OPENCLAW_HOME/devices/pending.json"

    # Ensure all files owned by tnode
    chown -R "$TNODE_USER":"$TNODE_USER" "$OPENCLAW_HOME" 2>/dev/null || true

    case "$OS" in
        Darwin) install_pair_watch_launchd "$DEST_SCRIPTS" ;;
        Linux)  install_pair_watch_systemd ;;
    esac
}

install_pair_watch_launchd() {
    local scripts_dir="$1"
    local plist_label="com.tbrain.pair-watch"
    local plist_dest="$HOME/Library/LaunchAgents/${plist_label}.plist"

    mkdir -p "$(dirname "$plist_dest")"

    cat > "$plist_dest" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${plist_label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>${OPENCLAW_HOME}/scripts/pair_watch.py</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>${OPENCLAW_HOME}/devices/pending.json</string>
    </array>
    <key>ThrottleInterval</key>
    <integer>2</integer>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${OPENCLAW_HOME}/logs/pair-watch.out.log</string>
    <key>StandardErrorPath</key>
    <string>${OPENCLAW_HOME}/logs/pair-watch.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>${OPENCLAW_HOME}</string>
</dict>
</plist>
PLIST

    launchctl unload "$plist_dest" 2>/dev/null || true
    launchctl load "$plist_dest"
    success "LaunchAgent pair-watch cargado"
}

install_pair_watch_systemd() {
    if ! command_exists systemctl; then
        warn "systemctl no disponible — saltando systemd setup"
        return 0
    fi
    _systemd_update_only_handled "pair-watch" && return 0

    # Always install as system-level units that run as tnode user
    local systemd_dir="/etc/systemd/system"

    cat > "$systemd_dir/pair-watch.service" <<SVCUNIT
[Unit]
Description=OpenClaw pair-watch auto-approver (oneshot)
After=network.target

[Service]
Type=oneshot
User=${TNODE_USER}
ExecStart=/usr/bin/python3 ${OPENCLAW_HOME}/scripts/pair_watch.py
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=HOME=${TNODE_HOME}
StandardOutput=append:${OPENCLAW_HOME}/logs/pair-watch.out.log
StandardError=append:${OPENCLAW_HOME}/logs/pair-watch.err.log

[Install]
WantedBy=multi-user.target
SVCUNIT

    cat > "$systemd_dir/pair-watch.path" <<PATHUNIT
[Unit]
Description=Watch OpenClaw pending.json and trigger pair-watch.service
After=network.target

[Path]
PathModified=${OPENCLAW_HOME}/devices/pending.json
Unit=pair-watch.service

[Install]
WantedBy=multi-user.target
PATHUNIT

    systemctl daemon-reload
    systemctl enable --now pair-watch.path 2>/dev/null || true
    success "systemd pair-watch.path habilitado (User=$TNODE_USER)"
}

# ─────────────────────────────────────────────────────────────
# llm-config-watcher: pulls per-node OR apiKey via HMAC every
# POLL_INTERVAL seconds and keeps openclaw.json in sync with the
# key minted from the mobile app. Only installed for OpenRouter
# (other providers manage their own keys).
# ─────────────────────────────────────────────────────────────

write_llm_config_watcher_py() {
    local dest="$1"
    cat > "$dest" <<'LLMPYEOF'
#!/usr/bin/env python3
"""tnode-llm-config-watcher — see tnode_server repo for full docs."""
from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

HOME = Path(os.environ.get("HOME", str(Path.home())))
OPENCLAW_HOME = Path(os.environ.get("OPENCLAW_HOME", str(HOME / ".openclaw")))
SYNC_JSON = OPENCLAW_HOME / "tnode-chat-sync.json"
CONFIG_JSON = OPENCLAW_HOME / "openclaw.json"
LOG_DIR = OPENCLAW_HOME / "logs"
LOG_FILE = LOG_DIR / "llm-config-watcher.log"

POLL_INTERVAL = int(os.environ.get("TNODE_LLM_POLL_INTERVAL", "300"))
HTTP_TIMEOUT = 15
DEFAULT_PROVIDER = "openrouter"


def setup_logging() -> logging.Logger:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log = logging.getLogger("llm-config-watcher")
    log.setLevel(logging.INFO)
    if log.handlers:
        return log
    fh = logging.FileHandler(LOG_FILE)
    fh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    log.addHandler(fh)
    sh = logging.StreamHandler(sys.stderr)
    sh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    log.addHandler(sh)
    return log


class PullError(Exception):
    def __init__(self, status: int, body: Any) -> None:
        super().__init__(f"pullLLMConfig {status}: {body}")
        self.status = status
        self.body = body


def sign(node_secret: str, node_id: str, timestamp: str, nonce: str) -> str:
    return hmac.new(
        node_secret.encode(),
        f"{node_id}:{timestamp}:{nonce}".encode(),
        hashlib.sha256,
    ).hexdigest()


def pull_config(node_id: str, node_secret: str, pull_url: str) -> dict[str, Any] | None:
    timestamp = str(int(time.time() * 1000))
    nonce = secrets.token_hex(16)
    signature = sign(node_secret, node_id, timestamp, nonce)
    payload = json.dumps(
        {"nodeId": node_id, "timestamp": timestamp, "nonce": nonce, "signature": signature}
    ).encode()
    req = urllib.request.Request(
        pull_url, data=payload, method="POST",
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            body = raw
        err_code = (body.get("error") if isinstance(body, dict) else None) or ""
        if e.code == 404 and err_code in ("not_provisioned", "not_registered", "not_paired"):
            return None
        raise PullError(e.code, body) from e


def load_current_config() -> dict[str, Any]:
    if not CONFIG_JSON.exists():
        return {}
    try:
        with CONFIG_JSON.open() as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def apply_config(config, api_key, model, base_url, provider) -> bool:
    models = config.setdefault("models", {})
    providers = models.setdefault("providers", {})
    prev = providers.get(provider, {})
    next_block = {
        "baseUrl": base_url,
        "apiKey": api_key,
        "models": [{
            "id": model, "name": model,
            "contextWindow": 200000, "maxTokens": 4096,
        }],
    }
    if prev == next_block:
        return False
    providers[provider] = next_block
    return True


def write_config_atomic(config) -> None:
    tmp = CONFIG_JSON.with_suffix(".json.tmp")
    with tmp.open("w") as f:
        json.dump(config, f, indent=2)
    os.replace(tmp, CONFIG_JSON)


def restart_openclaw(log) -> None:
    oc = shutil.which("openclaw") or "/usr/local/bin/openclaw"
    try:
        subprocess.run([oc, "daemon", "restart"], check=False, timeout=30, capture_output=True)
        log.info("openclaw daemon restart invoked")
    except (OSError, subprocess.TimeoutExpired) as e:
        log.error(f"openclaw daemon restart failed: {e}")


def load_sync():
    if not SYNC_JSON.exists():
        raise FileNotFoundError(f"{SYNC_JSON} missing — node not registered")
    with SYNC_JSON.open() as f:
        data = json.load(f)
    node_id = data.get("nodeId")
    node_secret = data.get("nodeSecret")
    pull_url = data.get("pullUrl")
    if not (node_id and node_secret and pull_url):
        raise ValueError(f"{SYNC_JSON} missing nodeId/nodeSecret/pullUrl")
    return node_id, node_secret, pull_url


def tick(log) -> None:
    node_id, node_secret, pull_url = load_sync()
    try:
        resp = pull_config(node_id, node_secret, pull_url)
    except PullError as e:
        if 400 <= e.status < 500:
            log.error(f"pull {e.status}: {e.body} — config broken, exiting")
            sys.exit(2)
        log.warning(f"pull failed (transient): {e}")
        return
    if resp is None:
        log.info("not provisioned yet — skipping")
        return
    api_key = resp.get("apiKey")
    model = resp.get("model")
    base_url = resp.get("baseUrl")
    provider = resp.get("provider", DEFAULT_PROVIDER)
    if not (api_key and model and base_url):
        log.error(f"pull returned malformed body: {resp}")
        return
    cfg = load_current_config()
    if not apply_config(cfg, api_key, model, base_url, provider):
        log.info("config up to date")
        return
    write_config_atomic(cfg)
    log.info(
        f"openclaw.json updated (provider={provider}, model={model}, "
        f"apiKey=...{api_key[-4:]}) — restarting daemon"
    )
    restart_openclaw(log)


def main() -> None:
    log = setup_logging()
    once = "--once" in sys.argv[1:]
    if once:
        log.info("llm-config-watcher running single tick (--once)")
        tick(log)
        return
    log.info(f"llm-config-watcher starting (poll={POLL_INTERVAL}s)")
    while True:
        try:
            tick(log)
        except FileNotFoundError as e:
            log.error(str(e))
            sys.exit(1)
        except Exception as e:
            log.exception(f"unexpected error: {e}")
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
LLMPYEOF
}

install_llm_config_watcher() {
    local DEST_SCRIPTS="$OPENCLAW_HOME/scripts"
    mkdir -p "$DEST_SCRIPTS" "$OPENCLAW_HOME/logs"

    write_llm_config_watcher_py "$DEST_SCRIPTS/llm_config_watcher.py"
    chmod +x "$DEST_SCRIPTS/llm_config_watcher.py"
    chown -R "$TNODE_USER":"$TNODE_USER" "$OPENCLAW_HOME" 2>/dev/null || true

    success "llm-config-watcher → $DEST_SCRIPTS/llm_config_watcher.py"

    case "$OS" in
        Darwin) install_llm_watcher_launchd ;;
        Linux)  install_llm_watcher_systemd ;;
    esac
}

install_llm_watcher_launchd() {
    local plist_label="com.tbrain.llm-config-watcher"
    local plist_dest="$HOME/Library/LaunchAgents/${plist_label}.plist"

    mkdir -p "$(dirname "$plist_dest")"

    cat > "$plist_dest" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${plist_label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>${OPENCLAW_HOME}/scripts/llm_config_watcher.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${OPENCLAW_HOME}/logs/llm-config-watcher.out.log</string>
    <key>StandardErrorPath</key>
    <string>${OPENCLAW_HOME}/logs/llm-config-watcher.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>OPENCLAW_HOME</key>
        <string>${OPENCLAW_HOME}</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>${OPENCLAW_HOME}</string>
</dict>
</plist>
PLIST

    launchctl unload "$plist_dest" 2>/dev/null || true
    launchctl load "$plist_dest"
    success "LaunchAgent llm-config-watcher cargado"
}

install_llm_watcher_systemd() {
    if ! command_exists systemctl; then
        warn "systemctl no disponible — saltando systemd setup del watcher"
        return 0
    fi

    local systemd_dir="/etc/systemd/system"

    cat > "$systemd_dir/tnode-llm-config-watcher.service" <<SVCUNIT
[Unit]
Description=TNode LLM config watcher — pulls per-node OR apiKey via HMAC
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${TNODE_USER}
ExecStart=/usr/bin/python3 ${OPENCLAW_HOME}/scripts/llm_config_watcher.py
Restart=always
RestartSec=15
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=HOME=${TNODE_HOME}
Environment=OPENCLAW_HOME=${OPENCLAW_HOME}
StandardOutput=append:${OPENCLAW_HOME}/logs/llm-config-watcher.out.log
StandardError=append:${OPENCLAW_HOME}/logs/llm-config-watcher.err.log

[Install]
WantedBy=multi-user.target
SVCUNIT

    systemctl daemon-reload
    systemctl enable --now tnode-llm-config-watcher.service 2>/dev/null || true
    success "systemd tnode-llm-config-watcher habilitado (User=$TNODE_USER)"
}

# ─────────────────────────────────────────────────────────────
# tnode-config-sync: event-driven replacement for llm-config-watcher.
# Subscribes to users/{uid}/nodes/{nodeId}/commands via a Firebase
# custom token (scope=sync_admin) and executes them on-demand
# (update_llm_provider, restart_openclaw, apply_openrouter_key, ...).
# Also mirrors openclaw.json → state/current on file changes (OS-level
# path watcher: launchd WatchPaths on macOS, systemd .path unit on Linux).
#
# Embedded inline (same rationale as tnode-chat-sync above): the canonical
# source is cmoralestbrain/skills/tnode-config-sync/ but that repo is
# private, so the installer ships the daemon verbatim. Keep in sync via
# the tnode-config-sync-v* tags in that repo.
# ─────────────────────────────────────────────────────────────

write_tnode_config_sync_py() {
    local dest="$1"
    cat > "$dest" <<'CFGSYNCPYEOF'
#!/usr/bin/env python3
"""tnode-config-sync — on-node command executor and config mirror.

Consumes pending commands from Firestore and reflects local openclaw.json
state back up. Shares credentials and auth pattern with tnode-chat-sync
(HMAC-signed mint via Cloud Function, idToken refresh loop).

Command queue:   users/{uid}/nodes/{nodeId}/commands/{cmdId}
State doc:       users/{uid}/nodes/{nodeId}/state/current

Env/overrides:
  TNODE_CONFIG_SYNC_CONFIG        Path to config JSON (default ~/.openclaw/tnode-chat-sync.json)
  TNODE_CONFIG_SYNC_OPENCLAW_JSON Path to openclaw.json (default ~/.openclaw/openclaw.json)
  TNODE_CONFIG_SYNC_LOG           Log file (default ~/.openclaw/logs/tnode-config-sync.log)
  TNODE_CONFIG_SYNC_POLL_ACTIVE_S Active polling interval (default 3s)
  TNODE_CONFIG_SYNC_POLL_IDLE_S   Idle polling interval (default 15s)
  TNODE_CONFIG_SYNC_IDLE_AFTER    Empty polls before switching to idle cadence (default 5)
  TNODE_CONFIG_SYNC_ONESHOT       If set, run a single push_openclaw_config and exit
                           (used by the file-watcher trigger).
"""
from __future__ import annotations
# 1.4.0 — AGENTS_INDEX.md auto-generation. install_subagent and
#         uninstall_subagent now regenerate
#         ~/.openclaw/agency-agents/AGENTS_INDEX.md (Markdown table of
#         installed sub-agents with id | tagline | role, derived from
#         each agent's IDENTITY.md + SOUL.md), and idempotently append
#         "Sub-agentes" sections to workspace/SOUL.md (operative: when
#         to read the INDEX) and workspace/IDENTITY.md (identitarian:
#         "you are a coordinator, delegate") so the main agent picks
#         up the roster on next bootstrap. Daemon startup also runs
#         the regen + section-ensure as self-heal against workspace
#         drift. Without this, qwen-3.6-plus had no in-context cue to
#         delegate and answered every prompt as the main itself even
#         when sub-agents were materialized.
# 1.3.1 — _update_openclaw_config_for_subagent tolerates missing
#         agents.list[]. OpenClaw 2026.4.x infers `main` implicitly
#         when openclaw.json only carries agents.defaults.models (no
#         agents.list); the previous implementation tried to iterate
#         cfg["agents"]["list"] directly and tripped on KeyError on the
#         first sub-agent install. Now setdefault-s the list and
#         materializes a `main` entry with the canonical workspace +
#         agents/main/agent paths if missing.
# 1.3.0 — merge semantics for the model catalog. _apply_provider_to_openclaw
#         now upserts providers[p].models[] (by id) and merges the slug
#         into agents.defaults.models instead of replacing both wholesale —
#         re-applying an OpenRouter key no longer clobbers the expanded
#         catalog (Cerebro's per-agent picks, sub-agent recommended models).
#         install_subagent now propagates the sub-agent's primary model to
#         the runtime catalog and allowlist via the new helper
#         _ensure_model_registered, fixing the "model not allowed" failure
#         on delegate after a fresh sub-agent install.
# 1.2.0 — sub-agents: install_subagent / uninstall_subagent /
#         restart_gateway_for_subagents handlers (Firestore-driven
#         per-node materialization replacing the agency-agents/ dir
#         + symlink hack).
__VERSION__ = "1.4.0"

import hashlib
import hmac
import json
import os
import re
import secrets as py_secrets
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# ── Constants ──────────────────────────────────────────────────

PROJECT_ID = "tbrain-platform-7fc1f"
SCOPE = "sync_admin"

# Public API key (project-scoped, gates only signInWithCustomToken). Same one
# used by tnode-chat-sync and the iOS app.
FIREBASE_WEB_API_KEY_FALLBACK = os.environ.get(
    "TNODE_CONFIG_SYNC_WEB_API_KEY",
    "AIzaSyCOybTP4r9J2bWXiJvXY0MQBFvaYDo_iWU",
)

HOME = Path.home()
OPENCLAW_DIR = Path(os.environ.get("OPENCLAW_HOME", str(HOME / ".openclaw")))
CONFIG_PATH = Path(
    os.environ.get("TNODE_CONFIG_SYNC_CONFIG", str(OPENCLAW_DIR / "tnode-chat-sync.json"))
)
OPENCLAW_JSON_PATH = Path(
    os.environ.get("TNODE_CONFIG_SYNC_OPENCLAW_JSON", str(OPENCLAW_DIR / "openclaw.json"))
)
LOG_PATH = Path(
    os.environ.get("TNODE_CONFIG_SYNC_LOG", str(OPENCLAW_DIR / "logs" / "tnode-config-sync.log"))
)
POLL_ACTIVE_S = float(os.environ.get("TNODE_CONFIG_SYNC_POLL_ACTIVE_S", "3"))
POLL_IDLE_S = float(os.environ.get("TNODE_CONFIG_SYNC_POLL_IDLE_S", "15"))
IDLE_AFTER = int(os.environ.get("TNODE_CONFIG_SYNC_IDLE_AFTER", "5"))
ONESHOT = bool(os.environ.get("TNODE_CONFIG_SYNC_ONESHOT"))


# ── Logging ────────────────────────────────────────────────────

def _log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    line = f"[{ts}] {msg}\n"
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG_PATH, "a") as f:
            f.write(line)
    except OSError:
        pass
    sys.stderr.write(line)


# ── HTTP helpers ───────────────────────────────────────────────

def _http_request(
    method: str,
    url: str,
    payload: dict | None = None,
    headers: dict | None = None,
    timeout: int = 15,
) -> dict:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req_headers = {"Content-Type": "application/json"}
    if headers:
        req_headers.update(headers)
    req = urllib.request.Request(url, data=data, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        # Attach the server body so the main loop can log it before
        # backoff — invaluable for debugging 400s that would otherwise
        # just say "Bad Request".
        try:
            body = e.read().decode("utf-8")
            e.server_body = body  # type: ignore[attr-defined]
        except Exception:
            e.server_body = ""  # type: ignore[attr-defined]
        raise


# ── Config + auth ──────────────────────────────────────────────

def load_config() -> dict:
    if not CONFIG_PATH.is_file():
        raise RuntimeError(
            f"Config {CONFIG_PATH} missing. Run tnode-setup.sh register step."
        )
    with open(CONFIG_PATH) as f:
        cfg = json.load(f)
    for k in ("nodeId", "nodeSecret", "mintUrl"):
        if not cfg.get(k):
            raise RuntimeError(f"Config missing {k}")
    return cfg


def _read_current_secret() -> str | None:
    """Re-read tnode-chat-sync.json from disk to pick up self-heal rotations
    by chat-sync (v1.8.15+ regenerates nodeSecret when mintNodeToken returns
    404). Without this, config-sync keeps the boot-time secret in RAM and
    loops 409 not_paired forever. Returns None on missing/invalid file."""
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f).get("nodeSecret")
    except Exception:
        return None


def mint_token(cfg: dict) -> dict:
    """Mint a Firebase ID token with scope=sync_admin.

    Returns {idToken, uid, nodeId, expiresAt (epoch seconds)}.
    """
    fresh_secret = _read_current_secret()
    if fresh_secret and fresh_secret != cfg.get("nodeSecret"):
        _log("nodeSecret rotated on disk (chat-sync self-heal); reloading")
        cfg["nodeSecret"] = fresh_secret  # mutate caller's cfg in-place
    ts = str(int(time.time() * 1000))
    nonce = py_secrets.token_hex(16)
    signing = f'{cfg["nodeId"]}:{ts}:{nonce}:{SCOPE}'
    mac = hmac.new(
        cfg["nodeSecret"].encode("utf-8"),
        signing.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    mint_resp = _http_request(
        "POST",
        cfg["mintUrl"],
        {
            "nodeId": cfg["nodeId"],
            "timestamp": ts,
            "nonce": nonce,
            "signature": mac,
            "scope": SCOPE,
        },
    )
    custom_token = mint_resp["customToken"]
    api_key = cfg.get("webApiKey") or FIREBASE_WEB_API_KEY_FALLBACK
    exchange = _http_request(
        "POST",
        f"https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key={api_key}",
        {"token": custom_token, "returnSecureToken": True},
    )
    return {
        "idToken": exchange["idToken"],
        "uid": mint_resp["uid"],
        "nodeId": mint_resp["nodeId"],
        "expiresAt": int(time.time()) + int(exchange.get("expiresIn", "3600")) - 60,
    }


# ── Firestore REST: typed value encoding ───────────────────────

def _fs_value(v):
    if v is None:
        return {"nullValue": None}
    if isinstance(v, bool):
        return {"booleanValue": v}
    if isinstance(v, int):
        return {"integerValue": str(v)}
    if isinstance(v, float):
        return {"doubleValue": v}
    if isinstance(v, str):
        return {"stringValue": v}
    if isinstance(v, dict):
        return {"mapValue": {"fields": {k: _fs_value(x) for k, x in v.items()}}}
    if isinstance(v, list):
        return {"arrayValue": {"values": [_fs_value(x) for x in v]}}
    return {"stringValue": str(v)}


def _fs_fields(d: dict) -> dict:
    return {"fields": {k: _fs_value(v) for k, v in d.items()}}


def _fs_decode(field: dict):
    """Decode a Firestore typed value back to Python."""
    if "nullValue" in field:
        return None
    if "booleanValue" in field:
        return field["booleanValue"]
    if "integerValue" in field:
        return int(field["integerValue"])
    if "doubleValue" in field:
        return float(field["doubleValue"])
    if "stringValue" in field:
        return field["stringValue"]
    if "timestampValue" in field:
        return field["timestampValue"]
    if "mapValue" in field:
        fields = field["mapValue"].get("fields", {})
        return {k: _fs_decode(v) for k, v in fields.items()}
    if "arrayValue" in field:
        values = field["arrayValue"].get("values", [])
        return [_fs_decode(v) for v in values]
    return None


def _firestore_base() -> str:
    return (
        f"https://firestore.googleapis.com/v1/projects/{PROJECT_ID}"
        "/databases/(default)/documents"
    )


# ── Firestore operations ───────────────────────────────────────

def query_pending_commands(token: dict) -> list[dict]:
    """Run a structured query for pending commands.

    Returns list of {id, type, params, createdAt, status} dicts.
    """
    base = _firestore_base()
    # Parent for the collectionId `commands` nested under the node doc.
    parent = f"users/{token['uid']}/nodes/{token['nodeId']}"
    url = f"{_firestore_base()}/{parent}:runQuery"

    # No orderBy: a composite index (status + createdAt) would be needed
    # and command queues never get deep enough for ordering to matter in
    # practice. Callers that care about order can use __name__ which has
    # an implicit default index.
    body = {
        "structuredQuery": {
            "from": [{"collectionId": "commands"}],
            "where": {
                "fieldFilter": {
                    "field": {"fieldPath": "status"},
                    "op": "EQUAL",
                    "value": {"stringValue": "pending"},
                }
            },
            "limit": 10,
        }
    }
    headers = {"Authorization": f"Bearer {token['idToken']}"}
    resp = _http_request("POST", url, body, headers)

    # runQuery returns a list; each element may have a `document` key or be
    # an empty row (when no matches).
    cmds = []
    if isinstance(resp, list):
        rows = resp
    else:
        # Single-object response when the gateway returns only one element.
        rows = [resp]
    for row in rows:
        doc = row.get("document") if isinstance(row, dict) else None
        if not doc:
            continue
        name = doc.get("name", "")
        cmd_id = name.rsplit("/", 1)[-1]
        fields = doc.get("fields", {})
        cmds.append(
            {
                "id": cmd_id,
                "type": _fs_decode(fields.get("type", {"stringValue": ""})),
                "params": _fs_decode(fields.get("params", {"mapValue": {"fields": {}}}))
                or {},
                "createdAt": _fs_decode(fields.get("createdAt", {"nullValue": None})),
                "status": _fs_decode(fields.get("status", {"stringValue": ""})),
            }
        )
    return cmds


def update_command(token: dict, cmd_id: str, patch: dict) -> None:
    """PATCH a command doc with the given fields (status/result/completedAt)."""
    uid = token["uid"]
    node_id = token["nodeId"]
    # updateMask ensures we only touch these fields (Firestore rule also
    # enforces immutability of type/params/createdAt).
    mask_params = "&".join(
        f"updateMask.fieldPaths={urllib.parse.quote(k)}" for k in patch.keys()
    )
    url = (
        f"{_firestore_base()}/users/{uid}/nodes/{node_id}/commands/{cmd_id}"
        f"?{mask_params}"
    )
    headers = {"Authorization": f"Bearer {token['idToken']}"}
    _http_request("PATCH", url, _fs_fields(patch), headers)


def write_state(token: dict, state: dict) -> None:
    """Upsert users/{uid}/nodes/{nodeId}/state/current with the given state."""
    uid = token["uid"]
    node_id = token["nodeId"]
    url = f"{_firestore_base()}/users/{uid}/nodes/{node_id}/state/current"
    headers = {"Authorization": f"Bearer {token['idToken']}"}
    _http_request("PATCH", url, _fs_fields(state), headers)


# ── LLM mode derivation ────────────────────────────────────────

# Matches URLs whose host is localhost or a private-range IPv4 address.
# Used to detect LLM providers that run locally on the node (LM Studio,
# Ollama, llama.cpp, or any custom openai-compatible server). Provider
# name is irrelevant — users frequently use non-standard names like
# `custom-127-0-0-1-1234`.
_LOCAL_URL_RE = re.compile(
    r"^https?://(?:localhost|127\.\d+\.\d+\.\d+|0\.0\.0\.0|"
    r"192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+|"
    r"172\.(?:1[6-9]|2\d|3[01])\.\d+\.\d+)(?::\d+)?(?:/|$)"
)


def _is_local_url(url: str) -> bool:
    return bool(_LOCAL_URL_RE.match((url or "").strip().lower()))


def derive_llm_mode(openclaw_cfg: dict) -> str:
    """Return 'local' | 'openrouter' | 'none' based on openclaw.json.

    The client UI uses this to decide whether to show the "activate LLM"
    banner — the label 'local' is a slight misnomer (it really means
    "anything other than plain OpenRouter"), but keeping it simple keeps
    the banner logic identical for self-hosted and alt-cloud setups.

    - 'openrouter' when an `openrouter` provider has a real api key —
      unlocks the top-up card.
    - 'local' when ANY provider has a baseUrl pointing at localhost/LAN,
      OR any non-openrouter provider has both a baseUrl and an api key
      (e.g. Groq, Moonshot, Together, custom OpenAI-compat endpoints).
      Node has a working LLM → banner stays hidden.
    - 'none' when nothing is configured → client shows the selector.
    """
    providers = (
        openclaw_cfg.get("models", {}).get("providers", {})
        if isinstance(openclaw_cfg, dict)
        else {}
    )
    if not providers:
        return "none"

    openrouter = providers.get("openrouter") or {}
    or_key = (openrouter.get("apiKey") or "").strip()
    if or_key and or_key not in ("", "not-needed"):
        return "openrouter"

    for name, prov in providers.items():
        if name == "openrouter":
            continue  # already ruled out above (no usable key)
        base_url = (prov.get("baseUrl") or "").strip()
        api_key = (prov.get("apiKey") or "").strip()
        if _is_local_url(base_url):
            return "local"
        # Remote non-openrouter provider with a populated key counts as
        # "functional" for banner purposes (node is ready to serve).
        if base_url and api_key and api_key != "not-needed":
            return "local"

    return "none"


def read_openclaw_json() -> dict | None:
    if not OPENCLAW_JSON_PATH.is_file():
        return None
    try:
        with open(OPENCLAW_JSON_PATH) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        _log(f"failed to read {OPENCLAW_JSON_PATH}: {e}")
        return None


def push_openclaw_config(token: dict) -> dict:
    """Read openclaw.json, derive llmMode, push to Firestore state/current."""
    cfg = read_openclaw_json()
    if cfg is None:
        # Still push the "none" state so the client can react.
        state = {
            "openclawConfig": None,
            "llmMode": "none",
            "updatedAt": int(time.time() * 1000),
        }
    else:
        state = {
            "openclawConfig": cfg,
            "llmMode": derive_llm_mode(cfg),
            "updatedAt": int(time.time() * 1000),
        }
    write_state(token, state)
    return state


# ── HTTP GET helper ────────────────────────────────────────────

def _http_get(url: str, timeout: int = 10) -> dict:
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8")
        return json.loads(raw) if raw else {}


# ── OpenClaw CLI helpers ───────────────────────────────────────

def _openclaw_binary() -> str | None:
    """Locate the openclaw CLI binary on PATH or common install locations."""
    bin_path = shutil.which("openclaw")
    if bin_path:
        return bin_path
    for cand in (
        HOME / ".local" / "bin" / "openclaw",
        Path("/usr/local/bin/openclaw"),
        Path("/opt/homebrew/bin/openclaw"),
    ):
        if cand.is_file() and os.access(cand, os.X_OK):
            return str(cand)
    return None


def _run_openclaw(*args: str, timeout: int = 60) -> dict:
    bin_path = _openclaw_binary()
    if not bin_path:
        return {"ok": False, "error": "openclaw_not_found"}
    try:
        proc = subprocess.run(
            [bin_path, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        result = {
            "ok": proc.returncode == 0,
            "code": proc.returncode,
            "stdout": proc.stdout[-2000:],
            "stderr": proc.stderr[-2000:],
        }
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "timeout"}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e)[:500]}

    # Fallback for fresh VPS installs where systemctl --user has no DBUS bus
    # ("No medium found"). `openclaw daemon restart` / `gateway restart` fail
    # in that case; spawn the gateway manually so the node keeps working
    # until the user logs out and back in (or reboots).
    if not result["ok"] and args and args[-1] == "restart":
        stderr = result.get("stderr", "")
        if "No medium found" in stderr or "Failed to connect to bus" in stderr:
            fallback = _spawn_openclaw_gateway(bin_path)
            result["fallback"] = fallback
            if fallback.get("ok"):
                result["ok"] = True
    return result


def _spawn_openclaw_gateway(bin_path: str) -> dict:
    """Kill any running openclaw gateway and relaunch it in the background.
    Used when systemctl --user is unavailable (fresh VPS, no linger session)."""
    subprocess.run(["pkill", "-f", "openclaw gateway"], check=False)
    try:
        subprocess.Popen(
            [bin_path, "gateway"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
        return {"ok": True, "method": "spawn"}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": f"spawn_failed: {e}"}


def _gateway_main_pid() -> int | None:
    """Return the gateway process PID, or None if not running.

    Linux: systemctl --user show openclaw-gateway --property=MainPID --value.
    Mac: pgrep -f openclaw-gateway (no systemd, launchd doesn't expose PID
    portably from a non-root context).
    """
    if sys.platform == "darwin":
        try:
            out = subprocess.check_output(
                ["pgrep", "-f", "openclaw-gateway"], text=True, timeout=5,
            ).strip()
            return int(out.splitlines()[0]) if out else None
        except (subprocess.CalledProcessError, ValueError, subprocess.TimeoutExpired):
            return None
    # Linux user service
    env = os.environ.copy()
    env.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    try:
        out = subprocess.check_output(
            ["systemctl", "--user", "show", "openclaw-gateway",
             "--property=MainPID", "--value"],
            text=True, timeout=5, env=env,
        ).strip()
        return int(out) if out and out != "0" else None
    except (subprocess.CalledProcessError, ValueError, subprocess.TimeoutExpired,
            FileNotFoundError):
        return None


def _restart_openclaw_with_verify(timeout: int = 60) -> dict:
    """Restart openclaw and verify the MainPID actually rotated.

    Some hosts return ok=True from `openclaw daemon restart` while the
    gateway process keeps running with the old PID — openclaw.json on disk
    is fresh but the in-memory config stays stale, so the user keeps seeing
    "No API key found for provider X". When that happens, force-kill the old
    PID; systemd Restart=always (Linux) or launchd KeepAlive (Mac) respawns
    it within ~3s.
    """
    old_pid = _gateway_main_pid()
    result = _run_openclaw("daemon", "restart", timeout=timeout)
    result["oldPid"] = old_pid
    if not result.get("ok"):
        result["pidVerified"] = "skipped_restart_failed"
        return result
    time.sleep(3)
    new_pid = _gateway_main_pid()
    result["newPid"] = new_pid
    if old_pid is None:
        result["pidVerified"] = "old_pid_unknown"
        return result
    if new_pid is not None and new_pid != old_pid:
        result["pidVerified"] = "ok"
        return result
    _log(
        f"openclaw restart didn't rotate PID (old={old_pid} new={new_pid}); "
        f"sending SIGTERM to old PID and trusting Restart=always to respawn"
    )
    try:
        os.kill(old_pid, signal.SIGTERM)
    except ProcessLookupError:
        result["pidVerified"] = "old_pid_already_gone"
        return result
    except OSError as e:
        result["pidVerified"] = f"sigterm_failed: {e}"
        return result
    time.sleep(3)
    result["newPid"] = _gateway_main_pid()
    result["pidVerified"] = "forced"
    return result


# ── openclaw.json writer ───────────────────────────────────────

_CTX_DEFAULTS = {
    "openrouter": 200000,
    "groq": 131072,
    "ollama": 32768,
    "lmstudio": 131072,
    "llama-cpp": 131072,
}


def _default_context_for(provider: str) -> int:
    return _CTX_DEFAULTS.get(provider, 8192)


_KNOWN_PROVIDER_PREFIXES = frozenset(_CTX_DEFAULTS.keys())


def _split_provider_slug(slug: str) -> tuple[str, str]:
    """`'openrouter/qwen/qwen3.6-plus'` → `('openrouter', 'qwen/qwen3.6-plus')`.
    Returns `('', slug)` if the slug doesn't start with a known provider
    prefix — keeps interop between the prefixed `agent.model.primary` form
    and the unprefixed `providers[p].models[].id` form."""
    if not isinstance(slug, str) or "/" not in slug:
        return "", slug if isinstance(slug, str) else ""
    head, rest = slug.split("/", 1)
    if head in _KNOWN_PROVIDER_PREFIXES:
        return head, rest
    return "", slug


def _ensure_model_registered(cfg: dict, model_slug: str) -> bool:
    """Idempotently make `model_slug` reachable from a freshly-loaded gateway:
    upsert under `models.providers[p].models[]` (catalog id without the
    provider prefix) and add the same id to `agents.defaults.models`.
    Skips the catalog write if the inferred provider isn't yet configured
    (e.g. a sub-agent install on a node before `apply_openrouter_key`).
    Returns `True` if cfg was modified."""
    provider, catalog_id = _split_provider_slug(model_slug)
    if not provider:
        return False

    changed = False
    providers = (cfg.setdefault("models", {}).setdefault("providers", {}))
    p = providers.get(provider)
    if isinstance(p, dict):
        models_list = p.setdefault("models", [])
        if isinstance(models_list, list) and not any(
            isinstance(m, dict) and m.get("id") == catalog_id for m in models_list
        ):
            models_list.append({
                "id": catalog_id,
                "name": catalog_id,
                "contextWindow": _default_context_for(provider),
                "maxTokens": 4096,
            })
            changed = True

    defaults_models = (
        cfg.setdefault("agents", {})
        .setdefault("defaults", {})
        .setdefault("models", {})
    )
    if isinstance(defaults_models, dict) and catalog_id not in defaults_models:
        defaults_models[catalog_id] = {}
        changed = True

    return changed


def _write_openclaw_json(cfg: dict) -> None:
    """Atomically write openclaw.json with the given config dict."""
    tmp = OPENCLAW_JSON_PATH.with_suffix(".json.tmp")
    tmp.parent.mkdir(parents=True, exist_ok=True)
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
    os.replace(tmp, OPENCLAW_JSON_PATH)


def _apply_provider_to_openclaw(
    provider: str,
    base_url: str,
    model: str,
    api_key: str = "",
    ctx: int | None = None,
    max_tokens: int = 4096,
) -> dict:
    """Upsert a provider block inside openclaw.json. Returns updated cfg.

    Merge semantics (v1.3.0+): `providers[p].models[]` and
    `agents.defaults.models` are extended in-place rather than replaced.
    Earlier versions clobbered the expanded model catalog (e.g. Cerebro's
    14-model list and any sub-agent's recommended model) every time the
    user re-applied an OpenRouter key, leaving the gateway with a single
    allowed model and breaking sub-agent delegation.

    `agents.defaults.models` MUST stay as a dict keyed by id (without the
    provider prefix). The legacy singular `agents.defaults.model.primary`
    is dropped on touch — it still triggers `Unknown model` on OpenClaw
    v2026.4.24+ for any id outside OpenClaw's internal registry.
    """
    cfg = read_openclaw_json() or {}
    providers = cfg.setdefault("models", {}).setdefault("providers", {})
    p = providers.setdefault(provider, {
        "baseUrl": base_url,
        "apiKey": api_key or "",
        "models": [],
    })
    p["baseUrl"] = base_url
    if api_key:
        p["apiKey"] = api_key

    models_list = p.setdefault("models", [])
    if not isinstance(models_list, list):
        models_list = []
        p["models"] = models_list
    existing = next(
        (m for m in models_list if isinstance(m, dict) and m.get("id") == model),
        None,
    )
    if existing is None:
        models_list.append({
            "id": model,
            "name": model,
            "contextWindow": ctx or _default_context_for(provider),
            "maxTokens": max_tokens,
        })
    else:
        if ctx:
            existing["contextWindow"] = ctx
        if max_tokens:
            existing["maxTokens"] = max_tokens

    agents_defaults = cfg.setdefault("agents", {}).setdefault("defaults", {})
    agents_defaults.setdefault("models", {}).setdefault(model, {})
    agents_defaults.pop("model", None)  # drop legacy singular key

    _write_openclaw_json(cfg)
    return cfg


# ── Command handlers ───────────────────────────────────────────

def handle_update_llm_provider(token: dict, params: dict) -> dict:
    provider = str(params.get("provider") or "").strip()
    base_url = str(params.get("baseUrl") or "").strip()
    model = str(params.get("model") or "").strip()
    api_key = str(params.get("apiKey") or "")
    ctx = params.get("ctx")
    max_tokens = params.get("maxTokens") or 4096

    if provider not in _CTX_DEFAULTS and provider != "openai-compat":
        return {
            "status": "error",
            "result": {"error": f"unsupported_provider: {provider}"},
        }
    if not base_url or not model:
        return {
            "status": "error",
            "result": {"error": "missing_baseUrl_or_model"},
        }

    try:
        _apply_provider_to_openclaw(
            provider, base_url, model, api_key,
            ctx=int(ctx) if ctx else None,
            max_tokens=int(max_tokens),
        )
    except Exception as e:  # noqa: BLE001
        return {"status": "error", "result": {"error": f"write_failed: {e}"}}

    restart = _restart_openclaw_with_verify()
    # Push the new state up immediately so the client sees it.
    try:
        new_state = push_openclaw_config(token)
    except Exception as e:  # noqa: BLE001
        _log(f"post-update state push failed: {e}")
        new_state = None

    return {
        "status": "done" if restart.get("ok") else "error",
        "result": {
            "provider": provider,
            "restart": restart,
            "llmMode": (new_state or {}).get("llmMode"),
        },
    }


def handle_restart_openclaw(token: dict, params: dict) -> dict:
    result = _restart_openclaw_with_verify()
    return {
        "status": "done" if result.get("ok") else "error",
        "result": result,
    }


def handle_detect_local_models(token: dict, params: dict) -> dict:
    base_url = str(params.get("baseUrl") or "").strip().rstrip("/")
    provider = str(params.get("provider") or "").strip()
    if not base_url:
        return {"status": "error", "result": {"error": "missing_baseUrl"}}

    try:
        if provider == "ollama":
            data = _http_get(f"{base_url}/api/tags")
            models = [m.get("name") for m in data.get("models", []) if m.get("name")]
        else:
            # OpenAI-compatible (lmstudio, llama-cpp, openai-compat)
            data = _http_get(f"{base_url}/v1/models")
            models = [m.get("id") for m in data.get("data", []) if m.get("id")]
    except urllib.error.URLError as e:
        return {"status": "error", "result": {"error": f"unreachable: {e.reason}"}}
    except Exception as e:  # noqa: BLE001
        return {"status": "error", "result": {"error": str(e)[:500]}}

    return {
        "status": "done",
        "result": {"provider": provider, "baseUrl": base_url, "models": models},
    }


def handle_apply_openrouter_key(token: dict, params: dict) -> dict:
    """Fetch the provisioned OpenRouter key via pullLLMConfig (legacy HMAC)
    and apply it to openclaw.json. The key must already have been minted
    by the Flutter app calling the `mintNodeKey` callable.
    """
    cfg = load_config()
    pull_url = cfg.get("pullLLMConfigUrl") or (
        f"https://us-central1-{PROJECT_ID}.cloudfunctions.net/pullLLMConfig"
    )

    ts = str(int(time.time() * 1000))
    nonce = py_secrets.token_hex(16)
    signing = f'{cfg["nodeId"]}:{ts}:{nonce}'  # legacy signature (no scope)
    mac = hmac.new(
        cfg["nodeSecret"].encode("utf-8"),
        signing.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()

    try:
        resp = _http_request(
            "POST",
            pull_url,
            {
                "nodeId": cfg["nodeId"],
                "timestamp": ts,
                "nonce": nonce,
                "signature": mac,
            },
        )
    except urllib.error.HTTPError as e:
        try:
            err_body = json.loads(e.read().decode("utf-8"))
        except Exception:
            err_body = {"error": e.reason}
        return {
            "status": "error",
            "result": {"error": f"pull_failed_{e.code}", "detail": err_body},
        }

    api_key = resp.get("apiKey")
    model = resp.get("model") or "qwen/qwen3.6-plus"
    base_url = resp.get("baseUrl") or "https://openrouter.ai/api/v1"
    if not api_key:
        return {"status": "error", "result": {"error": "no_api_key_returned"}}

    try:
        _apply_provider_to_openclaw(
            "openrouter", base_url, model, api_key=api_key,
            ctx=_default_context_for("openrouter"),
        )
    except Exception as e:  # noqa: BLE001
        return {"status": "error", "result": {"error": f"write_failed: {e}"}}

    restart = _restart_openclaw_with_verify()
    try:
        new_state = push_openclaw_config(token)
    except Exception as e:  # noqa: BLE001
        _log(f"post-apply state push failed: {e}")
        new_state = None

    return {
        "status": "done" if restart.get("ok") else "error",
        "result": {
            "provider": "openrouter",
            "model": model,
            "restart": restart,
            "llmMode": (new_state or {}).get("llmMode"),
        },
    }


# ── Sub-agents handlers ────────────────────────────────────────
# install/uninstall/restart_for_subagents commands let the user toggle
# individual sub-agents from the app on a per-node basis. Each install
# fetches the curated agent files (SOUL.md / AGENTS.md / IDENTITY.md)
# from `agentsCatalog/{agentId}` in Firestore, materializes them into
# `~/.openclaw/agents/<id>/agent/`, and updates `agents.list[]` plus
# `main.subagents.allowAgents`. Uninstall removes the curated files
# (preserving runtime state in `.openclaw/`) and revokes the entry.
#
# Replaces the former `tnode-agents-sync` polling daemon — sub-agents
# are now user-driven, not pre-installed wholesale.

_AGENTS_DIR = OPENCLAW_DIR / "agents"
_SUBAGENT_FILES = ("SOUL.md", "AGENTS.md", "IDENTITY.md")
_SUBAGENT_DEFAULT_MODEL = "openrouter/qwen/qwen3.6-plus"
_AGENTS_INDEX_PATH = OPENCLAW_DIR / "agency-agents" / "AGENTS_INDEX.md"


def _firestore_get_agent_doc(token: dict, agent_id: str) -> dict | None:
    """Read agentsCatalog/{agent_id} via Firestore REST."""
    url = (
        f"https://firestore.googleapis.com/v1/projects/{PROJECT_ID}"
        f"/databases/(default)/documents/agentsCatalog/{agent_id}"
    )
    try:
        req = urllib.request.Request(
            url,
            headers={"Authorization": f'Bearer {token["idToken"]}'},
            method="GET",
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def _fs_unwrap(value: dict):
    """Convert a Firestore REST typed value into a native Python object."""
    if "stringValue" in value:
        return value["stringValue"]
    if "integerValue" in value:
        return int(value["integerValue"])
    if "doubleValue" in value:
        return float(value["doubleValue"])
    if "booleanValue" in value:
        return value["booleanValue"]
    if "nullValue" in value:
        return None
    if "timestampValue" in value:
        return value["timestampValue"]
    if "mapValue" in value:
        return {
            k: _fs_unwrap(v)
            for k, v in value["mapValue"].get("fields", {}).items()
        }
    if "arrayValue" in value:
        return [_fs_unwrap(v) for v in value["arrayValue"].get("values", [])]
    return None


def _firestore_upsert_installed_subagent(
    token: dict, agent_id: str, payload: dict
) -> None:
    """Write `users/{uid}/nodes/{nodeId}/installedSubagents/{agent_id}`.
    Uses PATCH with documentMask to be idempotent."""
    cfg = load_config()
    uid = token["uid"]
    node_id = cfg["nodeId"]
    fields = {}
    for k, v in payload.items():
        if isinstance(v, str):
            fields[k] = {"stringValue": v}
        elif isinstance(v, bool):
            fields[k] = {"booleanValue": v}
        elif isinstance(v, int):
            fields[k] = {"integerValue": str(v)}
        elif v is None:
            fields[k] = {"nullValue": None}
    mask = "&".join(f"updateMask.fieldPaths={k}" for k in payload.keys())
    url = (
        f"https://firestore.googleapis.com/v1/projects/{PROJECT_ID}"
        f"/databases/(default)/documents/users/{uid}/nodes/{node_id}"
        f"/installedSubagents/{agent_id}?{mask}"
    )
    body = json.dumps({"fields": fields}).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f'Bearer {token["idToken"]}',
            "Content-Type": "application/json",
        },
        method="PATCH",
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        resp.read()


def _firestore_delete_installed_subagent(token: dict, agent_id: str) -> None:
    cfg = load_config()
    uid = token["uid"]
    node_id = cfg["nodeId"]
    url = (
        f"https://firestore.googleapis.com/v1/projects/{PROJECT_ID}"
        f"/databases/(default)/documents/users/{uid}/nodes/{node_id}"
        f"/installedSubagents/{agent_id}"
    )
    req = urllib.request.Request(
        url,
        headers={"Authorization": f'Bearer {token["idToken"]}'},
        method="DELETE",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            resp.read()
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise


def _materialize_subagent_files(agent_id: str, files: dict, files_sha: str) -> None:
    """Write SOUL/AGENTS/IDENTITY + .source.json. Preserves any pre-existing
    runtime files under .openclaw/ (the gateway owns those)."""
    target_dir = _AGENTS_DIR / agent_id / "agent"
    parent = _AGENTS_DIR / agent_id

    # Wipe legacy symlink (from earlier hack-era) before writing real files.
    if target_dir.is_symlink():
        target_dir.unlink()

    parent.mkdir(parents=True, exist_ok=True)
    target_dir.mkdir(parents=True, exist_ok=True)

    for name in _SUBAGENT_FILES:
        if name in files:
            (target_dir / name).write_text(files[name], encoding="utf-8")
    (target_dir / ".source.json").write_text(
        json.dumps(
            {
                "filesSha": files_sha,
                "materializedAt": time.strftime(
                    "%Y-%m-%dT%H:%M:%SZ", time.gmtime()
                ),
                "source": "config_sync_command",
            },
            indent=2,
        )
    )


def _remove_subagent_files(agent_id: str) -> None:
    """Remove curated SOUL/AGENTS/IDENTITY/.source.json. Preserves
    `.openclaw/` (sessions, history) so re-installing keeps context."""
    target_dir = _AGENTS_DIR / agent_id / "agent"
    if not target_dir.exists():
        return
    for name in (*_SUBAGENT_FILES, ".source.json"):
        f = target_dir / name
        if f.is_file():
            f.unlink()


def _update_openclaw_config_for_subagent(
    agent_id: str, action: str, recommended_model: str | None = None
) -> bool:
    """Add/remove an entry in agents.list[] and update main.subagents
    .allowAgents accordingly. Returns True if the file changed.

    OpenClaw 2026.4.x infers `main` implicitly when agents.list[] is
    absent — a freshly-paired node only carries `agents.defaults.models`
    in openclaw.json. We materialize the main entry explicitly on first
    sub-agent install so we have something to append alongside (and so
    callers that DO read agents.list[] see a consistent shape)."""
    if not OPENCLAW_JSON_PATH.exists():
        return False
    cfg = json.loads(OPENCLAW_JSON_PATH.read_text())
    agents_section = cfg.setdefault("agents", {})
    if not isinstance(agents_section, dict):
        _log("openclaw.json: agents is not an object; cannot update sub-agents")
        return False
    agents_list = agents_section.setdefault("list", [])
    if not isinstance(agents_list, list):
        _log("openclaw.json: agents.list is not an array; cannot update sub-agents")
        return False
    main_idx = next(
        (i for i, a in enumerate(agents_list)
         if isinstance(a, dict) and a.get("id") == "main"),
        None,
    )
    if main_idx is None:
        agents_list.insert(0, {
            "id": "main",
            "default": True,
            "workspace": str(OPENCLAW_DIR / "workspace"),
            "agentDir": str(OPENCLAW_DIR / "agents" / "main" / "agent"),
        })
        main_idx = 0

    agent_dir = str(_AGENTS_DIR / agent_id / "agent")
    existing_idx = next(
        (i for i, a in enumerate(agents_list)
         if isinstance(a, dict) and a.get("id") == agent_id),
        None,
    )

    if action == "install":
        entry = (
            dict(agents_list[existing_idx])
            if existing_idx is not None
            else {}
        )
        entry["id"] = agent_id
        entry.setdefault("name", agent_id)
        entry["workspace"] = agent_dir
        entry["agentDir"] = agent_dir
        if recommended_model:
            entry.setdefault("model", {})["primary"] = recommended_model
        elif not entry.get("model", {}).get("primary"):
            entry.setdefault("model", {})["primary"] = _SUBAGENT_DEFAULT_MODEL
        if existing_idx is None:
            agents_list.append(entry)
        else:
            agents_list[existing_idx] = entry
        # Propagate the sub-agent's primary model to the runtime catalog
        # AND the gateway allowlist. Without this, install_subagent puts a
        # slug in agents.list[i].model.primary that the gateway accepts on
        # spawn but rejects on delegate ("model not allowed") because it
        # was never registered under providers[p].models[] /
        # agents.defaults.models. Idempotent — safe to re-run.
        _ensure_model_registered(cfg, entry["model"]["primary"])
    elif action == "uninstall":
        if existing_idx is None:
            return False
        agents_list.pop(existing_idx)
    else:
        return False

    # Rebuild main.subagents.allowAgents from the resulting list.
    main_entry = agents_list[
        next(
            i for i, a in enumerate(agents_list)
            if isinstance(a, dict) and a.get("id") == "main"
        )
    ]
    main_entry.setdefault("subagents", {})["allowAgents"] = sorted(
        a["id"] for a in agents_list
        if isinstance(a, dict) and a.get("id") and a.get("id") != "main"
    )

    serialized = json.dumps(cfg, indent=2) + "\n"
    if OPENCLAW_JSON_PATH.read_text() == serialized:
        return False
    OPENCLAW_JSON_PATH.write_text(serialized)
    return True


def _extract_tagline(p: Path) -> str:
    """First non-blank, non-heading line of an IDENTITY.md (the tagline
    OpenClaw's `convert.sh` puts right under the H1)."""
    if not p.is_file():
        return ""
    try:
        for line in p.read_text(encoding="utf-8").splitlines()[1:]:
            line = line.strip()
            if line and not line.startswith("#"):
                return line
    except Exception:  # noqa: BLE001
        pass
    return ""


def _extract_role(p: Path) -> str:
    """Match `**Role**: ...` from a SOUL.md (the canonical "when to use"
    sentence). Returns empty string when the agent's SOUL.md doesn't
    define a Role line — a few do (cms-developer, customer-service,
    healthcare-customer-service, hospitality-guest-services)."""
    if not p.is_file():
        return ""
    try:
        m = re.search(
            r"\*\*Role\*\*\s*:\s*(.+?)(?:\n|$)",
            p.read_text(encoding="utf-8"),
        )
        if m:
            return m.group(1).strip()
    except Exception:  # noqa: BLE001
        pass
    return ""


def _shorten(s: str, n: int = 140) -> str:
    """Single-line, escape `|` for Markdown tables, truncate at `n`."""
    s = (s or "").replace("|", "\\|").replace("\n", " ").strip()
    return (s[:n].rsplit(" ", 1)[0] + "…") if len(s) > n else s


def _regenerate_agents_index() -> None:
    """Rebuild ~/.openclaw/agency-agents/AGENTS_INDEX.md from sub-agents
    materialized under agents/<id>/agent/. Idempotent — safe to call
    after every install/uninstall and on daemon startup. The path
    `agency-agents/` is a holdover from the pre-v3 layout where the
    whole catalog lived there; today only the index file does, kept at
    the same path so the workspace SOUL.md/IDENTITY.md references stay
    stable across versions."""
    if not _AGENTS_DIR.is_dir():
        return
    rows: list[tuple[str, str, str]] = []
    for d in sorted(_AGENTS_DIR.iterdir()):
        if not d.is_dir() or d.name == "main":
            continue
        agent_dir = d / "agent"
        if not (agent_dir / "SOUL.md").is_file():
            continue
        rows.append((
            d.name,
            _extract_tagline(agent_dir / "IDENTITY.md"),
            _extract_role(agent_dir / "SOUL.md"),
        ))

    lines = [
        "# Sub-agents Index",
        "",
        'Roster of sub-agents available via `sessions_spawn(runtime="subagent", agentId=<id>, task="...")`.',
        "Generated automatically from each agent's `IDENTITY.md` (especialidad) and `SOUL.md` (Role/cuándo usarlo).",
        "",
        "| id | especialidad | cuándo usarlo (Role) |",
        "|---|---|---|",
    ]
    for slug, tag, role in rows:
        lines.append(f"| `{slug}` | {_shorten(tag)} | {_shorten(role)} |")
    lines.append("")
    lines.append(f"_{len(rows)} sub-agents indexed._")

    try:
        _AGENTS_INDEX_PATH.parent.mkdir(parents=True, exist_ok=True)
        _AGENTS_INDEX_PATH.write_text(
            "\n".join(lines) + "\n", encoding="utf-8"
        )
    except Exception as e:  # noqa: BLE001
        _log(f"_regenerate_agents_index: write failed: {e}")


_SUBAGENTS_SECTION_SOUL = """
## Sub-agentes disponibles

Lee `~/.openclaw/agency-agents/AGENTS_INDEX.md` al iniciar tu sesión para conocer el roster completo y sus especialidades. Úsalo para decidir cuándo invocar `sessions_spawn(runtime="subagent", agentId=<id>, task=...)`.
"""

_SUBAGENTS_SECTION_IDENTITY = """
## Sub-agentes a tu disposición

Eres el coordinador principal. Cuando una tarea encaja con la especialidad de un sub-agente del roster (ver `~/.openclaw/agency-agents/AGENTS_INDEX.md`), delégala con `sessions_spawn(runtime="subagent", agentId=<id>, task=...)` en lugar de hacerla tú mismo.
"""

_SEND_FILE_SECTION_SOUL = """
## Envío de archivos al chat

Cuando produzcas un archivo (PDF, imagen, código, etc.) que el usuario quiera abrir desde su app, NO le pases la ruta como texto. Incluye un marker exacto en tu respuesta así:

    [adjunto: /ruta/absoluta/al/archivo.pdf]

El sistema detecta el marker, sube el archivo a un canal seguro y lo reemplaza por un chip descargable en el chat (el usuario lo toca y se abre con su visor nativo).

Reglas:
- El archivo debe vivir bajo `~/.openclaw/workspace/`. Cualquier otra ruta es rechazada por seguridad.
- Tamaño máximo: 50 MB.
- Tipos comunes aceptados: PDF, imágenes, texto, código, ZIP/TAR/GZ, JSON/XML.
- Puedes mezclar varios markers con texto normal: "Aquí tienes el reporte [adjunto: workspace/foo.pdf] y los datos [adjunto: workspace/bar.csv]".
- NO uses `MEDIA:`, `file://`, ni rutas crudas — siempre el formato `[adjunto: <ruta>]`.
"""


def _ensure_subagents_sections() -> None:
    """Idempotently append operative sections to workspace/SOUL.md +
    workspace/IDENTITY.md. Each section carries its own header marker
    so the function is safe to call repeatedly — install_subagent and
    every config-sync boot run it as a guard against workspace drift.

    Sections appended:
      - `## Sub-agentes disponibles` (SOUL): how to use the roster.
      - `## Sub-agentes a tu disposición` (IDENTITY): delegate, don't do.
      - `## Envío de archivos al chat` (SOUL): `[adjunto: <path>]` marker
        protocol so the agent knows how to surface files to the mobile
        app — sidecar tnode-chat-sync v1.10.0+ rewrites the marker into
        an `[archivo:{id}]` after uploading the file."""
    workspace = OPENCLAW_DIR / "workspace"
    targets = (
        ("SOUL.md", "## Sub-agentes disponibles", _SUBAGENTS_SECTION_SOUL),
        ("IDENTITY.md", "## Sub-agentes a tu disposición",
         _SUBAGENTS_SECTION_IDENTITY),
        ("SOUL.md", "## Envío de archivos al chat", _SEND_FILE_SECTION_SOUL),
    )
    for fname, marker, section in targets:
        p = workspace / fname
        if not p.is_file():
            continue
        try:
            text = p.read_text(encoding="utf-8")
            if marker in text:
                continue
            p.write_text(text.rstrip() + "\n" + section, encoding="utf-8")
        except Exception as e:  # noqa: BLE001
            _log(f"_ensure_subagents_sections: skipping {fname}: {e}")


def handle_install_subagent(token: dict, params: dict) -> dict:
    agent_id = (params.get("agentId") or "").strip()
    if not agent_id:
        return {"status": "error", "result": {"error": "missing_agentId"}}

    doc = _firestore_get_agent_doc(token, agent_id)
    if doc is None:
        return {
            "status": "error",
            "result": {"error": f"agent_not_found: {agent_id}"},
        }
    fields = {k: _fs_unwrap(v) for k, v in doc.get("fields", {}).items()}
    files = fields.get("files") or {}
    files_sha = fields.get("filesSha") or ""
    recommended_model = fields.get("recommendedModel")

    if not all(k in files for k in _SUBAGENT_FILES) or not files_sha:
        return {
            "status": "error",
            "result": {"error": f"agent_doc_incomplete: {agent_id}"},
        }

    try:
        _materialize_subagent_files(agent_id, files, files_sha)
        config_changed = _update_openclaw_config_for_subagent(
            agent_id, "install", recommended_model
        )
        _firestore_upsert_installed_subagent(
            token,
            agent_id,
            {
                "agentId": agent_id,
                "status": "installed",
                "filesSha": files_sha,
            },
        )
        _regenerate_agents_index()
        _ensure_subagents_sections()
    except Exception as e:  # noqa: BLE001
        _log(f"install_subagent {agent_id} failed: {e}")
        return {"status": "error", "result": {"error": str(e)[:500]}}

    return {
        "status": "done",
        "result": {
            "agentId": agent_id,
            "filesSha": files_sha,
            "configChanged": config_changed,
            "recommendedModel": recommended_model,
        },
    }


def handle_uninstall_subagent(token: dict, params: dict) -> dict:
    agent_id = (params.get("agentId") or "").strip()
    if not agent_id:
        return {"status": "error", "result": {"error": "missing_agentId"}}

    try:
        _remove_subagent_files(agent_id)
        config_changed = _update_openclaw_config_for_subagent(
            agent_id, "uninstall"
        )
        _firestore_delete_installed_subagent(token, agent_id)
        _regenerate_agents_index()
    except Exception as e:  # noqa: BLE001
        _log(f"uninstall_subagent {agent_id} failed: {e}")
        return {"status": "error", "result": {"error": str(e)[:500]}}

    return {
        "status": "done",
        "result": {"agentId": agent_id, "configChanged": config_changed},
    }


def handle_restart_gateway_for_subagents(token: dict, params: dict) -> dict:
    """Sends SIGTERM to openclaw-gateway. systemd Restart=always respawns
    with the new agents.list[]. Coalesce: client should send this once
    after a batch of install/uninstall commands."""
    pids: list[int] = []
    try:
        out = subprocess.check_output(
            ["pgrep", "-f", "openclaw-gatewa"], text=True
        )
        pids = [int(p) for p in out.split() if p.strip()]
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    if not pids:
        return {"status": "done", "result": {"pids": [], "note": "no_running"}}
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    return {"status": "done", "result": {"pids": pids}}


# ── Dispatcher ─────────────────────────────────────────────────

_HANDLERS = {
    "push_openclaw_config": lambda token, params: {
        "status": "done",
        "result": {"llmMode": push_openclaw_config(token)["llmMode"]},
    },
    "update_llm_provider": handle_update_llm_provider,
    "restart_openclaw": handle_restart_openclaw,
    "detect_local_models": handle_detect_local_models,
    "apply_openrouter_key": handle_apply_openrouter_key,
    "install_subagent": handle_install_subagent,
    "uninstall_subagent": handle_uninstall_subagent,
    "restart_gateway_for_subagents": handle_restart_gateway_for_subagents,
}


def handle_command(token: dict, cmd: dict) -> dict:
    cmd_type = cmd.get("type") or ""
    params = cmd.get("params") or {}
    handler = _HANDLERS.get(cmd_type)
    if handler is None:
        return {
            "status": "error",
            "result": {"error": f"unknown_command_type: {cmd_type}"},
        }
    return handler(token, params)


# ── Main loop ──────────────────────────────────────────────────

def run_oneshot() -> int:
    """Push a single openclaw.json snapshot and exit.

    Used by the OS file-watcher: when openclaw.json changes, the watcher
    triggers `python3 tnode_config_sync.py` with TNODE_CONFIG_SYNC_ONESHOT=1 so the
    snapshot is reflected to Firestore immediately (no 15s latency).
    """
    try:
        cfg = load_config()
        token = mint_token(cfg)
        state = push_openclaw_config(token)
        _log(f"oneshot push ok — llmMode={state['llmMode']}")
        return 0
    except Exception as e:  # noqa: BLE001
        _log(f"oneshot failed: {e}")
        return 1


def main() -> int:
    if ONESHOT:
        return run_oneshot()

    try:
        cfg = load_config()
    except Exception as e:  # noqa: BLE001
        _log(f"config error: {e}")
        return 2

    _log(f"starting tnode-config-sync for nodeId={cfg['nodeId']}")
    # Self-heal: regenerate AGENTS_INDEX.md and ensure the workspace
    # references survive workspace drift (e.g. user wiped SOUL.md
    # manually, or the node was provisioned before v1.4.0). Best-effort
    # — failures here are logged but don't prevent the daemon loop.
    try:
        _regenerate_agents_index()
        _ensure_subagents_sections()
    except Exception as e:  # noqa: BLE001
        _log(f"startup self-heal failed: {e}")
    token: dict | None = None
    backoff = 1.0
    empty_polls = 0

    # Push initial state on startup so Firestore reflects current openclaw.json
    # even if the file hasn't changed since last boot.
    startup_pushed = False

    while True:
        try:
            now = int(time.time())
            if token is None or now >= token["expiresAt"]:
                token = mint_token(cfg)
                _log(f"minted token for uid={token['uid']} node={token['nodeId']}")
                backoff = 1.0

            if not startup_pushed:
                try:
                    state = push_openclaw_config(token)
                    _log(f"startup push ok — llmMode={state['llmMode']}")
                    startup_pushed = True
                except urllib.error.HTTPError as e:
                    if e.code == 401:
                        token = None
                        continue
                    _log(f"startup push failed: {e.code} {e.reason}")

            cmds = query_pending_commands(token)
            if cmds:
                empty_polls = 0
                for cmd in cmds:
                    _log(f"handling cmd {cmd['id']} type={cmd['type']}")
                    try:
                        update_command(
                            token, cmd["id"], {"status": "running"}
                        )
                        outcome = handle_command(token, cmd)
                        patch = {
                            "status": outcome.get("status", "done"),
                            "result": outcome.get("result") or {},
                            "completedAt": int(time.time() * 1000),
                        }
                        update_command(token, cmd["id"], patch)
                        _log(f"cmd {cmd['id']} -> {patch['status']}")
                    except urllib.error.HTTPError as e:
                        if e.code == 401:
                            token = None
                            break
                        _log(f"cmd {cmd['id']} HTTP error: {e.code} {e.reason}")
                        try:
                            update_command(
                                token,
                                cmd["id"],
                                {
                                    "status": "error",
                                    "result": {"error": f"http_{e.code}"},
                                    "completedAt": int(time.time() * 1000),
                                },
                            )
                        except Exception:
                            pass
                    except Exception as e:  # noqa: BLE001
                        _log(f"cmd {cmd['id']} error: {e}")
                        try:
                            update_command(
                                token,
                                cmd["id"],
                                {
                                    "status": "error",
                                    "result": {"error": str(e)[:500]},
                                    "completedAt": int(time.time() * 1000),
                                },
                            )
                        except Exception:
                            pass
            else:
                empty_polls += 1

            interval = POLL_IDLE_S if empty_polls >= IDLE_AFTER else POLL_ACTIVE_S
            time.sleep(interval)
        except KeyboardInterrupt:
            return 0
        except urllib.error.HTTPError as e:
            if e.code == 401:
                # Persistent 401 (e.g. clock skew, revoked node, stale
                # nodeSecret) used to spam ~10 lines/sec. Reuse the existing
                # `backoff` variable (reset to 1.0 on a successful mint at
                # the top of the loop) so we slow down without blocking
                # legitimate single-shot refreshes.
                _log(f"idToken rejected — refreshing; backoff={backoff:.1f}s")
                token = None
                time.sleep(backoff)
                backoff = min(60.0, backoff * 2)
                continue
            body = getattr(e, "server_body", "")
            _log(
                f"HTTP error: {e.code} {e.reason} body={body[:300]}; "
                f"backoff={backoff:.1f}s"
            )
            time.sleep(backoff)
            backoff = min(60.0, backoff * 2)
        except Exception as e:  # noqa: BLE001
            _log(f"loop error: {e}; backoff={backoff:.1f}s")
            time.sleep(backoff)
            backoff = min(60.0, backoff * 2)


if __name__ == "__main__":
    sys.exit(main())
CFGSYNCPYEOF
}

install_tnode_config_sync() {
    local DEST_SCRIPTS="$OPENCLAW_HOME/scripts"
    mkdir -p "$DEST_SCRIPTS" "$OPENCLAW_HOME/logs"

    write_tnode_config_sync_py "$DEST_SCRIPTS/tnode_config_sync.py"
    chmod +x "$DEST_SCRIPTS/tnode_config_sync.py"
    chown -R "$TNODE_USER":"$TNODE_USER" "$OPENCLAW_HOME" 2>/dev/null || true

    success "tnode-config-sync → $DEST_SCRIPTS/tnode_config_sync.py"

    case "$OS" in
        Darwin)
            install_config_sync_launchd
            install_config_sync_launchd_watcher
            ;;
        Linux)
            install_config_sync_systemd
            install_config_sync_systemd_watcher
            ;;
    esac
}

install_config_sync_launchd() {
    local plist_label="com.tbrain.tnode-config-sync"
    local plist_dest="$HOME/Library/LaunchAgents/${plist_label}.plist"

    mkdir -p "$(dirname "$plist_dest")"

    cat > "$plist_dest" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${plist_label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/env</string>
        <string>python3</string>
        <string>${OPENCLAW_HOME}/scripts/tnode_config_sync.py</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>${OPENCLAW_HOME}/logs/tnode-config-sync.out.log</string>
    <key>StandardErrorPath</key><string>${OPENCLAW_HOME}/logs/tnode-config-sync.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key><string>${HOME}</string>
        <key>OPENCLAW_HOME</key><string>${OPENCLAW_HOME}</string>
    </dict>
    <key>WorkingDirectory</key><string>${OPENCLAW_HOME}</string>
</dict>
</plist>
PLIST

    launchctl unload "$plist_dest" 2>/dev/null || true
    launchctl load "$plist_dest"
    success "LaunchAgent tnode-config-sync cargado"
}

install_config_sync_launchd_watcher() {
    local plist_label="com.tbrain.tnode-config-sync-watch"
    local plist_dest="$HOME/Library/LaunchAgents/${plist_label}.plist"

    mkdir -p "$(dirname "$plist_dest")"

    cat > "$plist_dest" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${plist_label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/env</string>
        <string>python3</string>
        <string>${OPENCLAW_HOME}/scripts/tnode_config_sync.py</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key><string>${HOME}</string>
        <key>OPENCLAW_HOME</key><string>${OPENCLAW_HOME}</string>
        <key>TNODE_CONFIG_SYNC_ONESHOT</key><string>1</string>
    </dict>
    <key>WatchPaths</key>
    <array>
        <string>${OPENCLAW_HOME}/openclaw.json</string>
    </array>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>StandardOutPath</key><string>${OPENCLAW_HOME}/logs/tnode-config-sync-watch.out.log</string>
    <key>StandardErrorPath</key><string>${OPENCLAW_HOME}/logs/tnode-config-sync-watch.err.log</string>
</dict>
</plist>
PLIST

    launchctl unload "$plist_dest" 2>/dev/null || true
    launchctl load "$plist_dest"
    success "LaunchAgent tnode-config-sync-watch cargado"
}

install_config_sync_systemd() {
    if ! command_exists systemctl; then
        warn "systemctl no disponible — saltando systemd setup del config-sync"
        return 0
    fi
    _systemd_update_only_handled "tnode-config-sync" && return 0

    local systemd_dir="/etc/systemd/system"

    cat > "$systemd_dir/tnode-config-sync.service" <<SVCUNIT
[Unit]
Description=TNode config-sync — command executor + openclaw.json mirror
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${TNODE_USER}
ExecStart=/usr/bin/env python3 ${OPENCLAW_HOME}/scripts/tnode_config_sync.py
Restart=always
RestartSec=10
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=HOME=${TNODE_HOME}
Environment=OPENCLAW_HOME=${OPENCLAW_HOME}
StandardOutput=append:${OPENCLAW_HOME}/logs/tnode-config-sync.out.log
StandardError=append:${OPENCLAW_HOME}/logs/tnode-config-sync.err.log

[Install]
WantedBy=multi-user.target
SVCUNIT

    systemctl daemon-reload
    systemctl enable --now tnode-config-sync.service 2>/dev/null || true
    success "systemd tnode-config-sync habilitado (User=$TNODE_USER)"
}

install_config_sync_systemd_watcher() {
    if ! command_exists systemctl; then
        return 0
    fi
    _systemd_update_only_handled "tnode-config-sync-watch" && return 0

    local systemd_dir="/etc/systemd/system"

    cat > "$systemd_dir/tnode-config-sync-watch.service" <<SVCUNIT
[Unit]
Description=TNode config-sync — push openclaw.json change (oneshot)

[Service]
Type=oneshot
User=${TNODE_USER}
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=HOME=${TNODE_HOME}
Environment=OPENCLAW_HOME=${OPENCLAW_HOME}
Environment=TNODE_CONFIG_SYNC_ONESHOT=1
ExecStart=/usr/bin/env python3 ${OPENCLAW_HOME}/scripts/tnode_config_sync.py
StandardOutput=append:${OPENCLAW_HOME}/logs/tnode-config-sync-watch.out.log
StandardError=append:${OPENCLAW_HOME}/logs/tnode-config-sync-watch.err.log
SVCUNIT

    cat > "$systemd_dir/tnode-config-sync-watch.path" <<PATHU
[Unit]
Description=Watch openclaw.json and trigger tnode-config-sync-watch.service

[Path]
PathChanged=${OPENCLAW_HOME}/openclaw.json
Unit=tnode-config-sync-watch.service

[Install]
WantedBy=multi-user.target
PATHU

    systemctl daemon-reload
    systemctl enable --now tnode-config-sync-watch.path 2>/dev/null || true
    success "systemd tnode-config-sync-watch.path habilitado"
}

# ─────────────────────────────────────────────────────────────
# tnode-chat-sync: mirrors OpenClaw session turns to Firestore
# so chat history survives app close / device switches. Runs
# regardless of which LLM provider powers the node.
#
# The Python daemon is embedded verbatim from the canonical
# cmoralestbrain/skills/tnode-chat-sync/scripts/tnode_chat_sync.py
# (repo is private — we can't curl it). Keep in sync via the
# tnode-chat-sync tag published in that repo.
# ─────────────────────────────────────────────────────────────

write_tnode_chat_sync_py() {
    local dest="$1"
    cat > "$dest" <<'CHATSYNCPYEOF'
#!/usr/bin/env python3
"""tnode-chat-sync — mirrors OpenClaw session turns to Firestore.

Why: the TNode mobile app talks to its OpenClaw agent over a raw WebSocket.
If the user closes the app while the agent is still responding, that turn
is lost because it never hit disk in a place the app can fetch later.

This watcher tails the JSONL session files under
  ~/.openclaw/agents/<agent_id>/sessions/*.jsonl
and, for every new turn (a message line with role=user|assistant),
writes it to Firestore at
  users/{uid}/nodes/{nodeId}/chats/{messageId}
using a Firebase custom token minted by the `mintNodeToken` Cloud Function.

Authentication:
- Config at ~/.openclaw/tnode-chat-sync.json is created by tnode-setup.sh
  post-pairing with {nodeId, nodeSecret, mintUrl}.
- For each token mint cycle: sign HMAC(nodeSecret, f"{nodeId}:{ts}:{nonce}"),
  POST to mintUrl, receive Firebase customToken, exchange at
  identitytoolkit for an idToken valid ~1h.

Design notes:
- stdlib only (urllib, hmac, hashlib, json, time, os, pathlib).
- Dedup: Firestore doc id is deterministic:
    * user messages  -> u_<hash(content+ts)>  (or u_<idempotencyKey> if
      the line carries one; not usually present server-side)
    * assistant msgs -> a_<hash(content+ts)>
  This keeps the watcher idempotent on restart and avoids duplicating a
  message the Flutter client already wrote client-side.
- Polling cadence: 500ms. Low CPU, good-enough latency for chat UX.
- File tracking: (device, inode) -> byte offset. Handles rotation.

Env/overrides:
  TNODE_CHAT_SYNC_CONFIG    Path to config JSON (default ~/.openclaw/tnode-chat-sync.json)
  TNODE_CHAT_SYNC_SESSIONS  Sessions dir (default ~/.openclaw/agents/<agent>/sessions)
  TNODE_CHAT_SYNC_LOG       Log file (default ~/.openclaw/logs/tnode-chat-sync.log)
  TNODE_CHAT_SYNC_POLL_MS   Polling interval ms (default 500)
"""
from __future__ import annotations
__VERSION__ = "1.10.0"

import hashlib
import hmac
import json
import mimetypes
import os
import re
import secrets as py_secrets
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

FIREBASE_API_KEY_URL = "https://us-central1-tbrain-platform-7fc1f.cloudfunctions.net"
# The web API key is public — it gates only anonymous signup/signin with a
# Firebase customToken (which itself requires HMAC-signed mint). We fetch it
# lazily once from a helper endpoint; if unavailable, fall back to the
# hard-coded project value shipped with the mobile app.
# This is the iOS app's public API key for project tbrain-platform-7fc1f.
# Firebase API keys are designed to be public (they only identify the
# project; auth still gates access). Using the iOS key is fine for REST
# identitytoolkit calls from any environment.
FIREBASE_WEB_API_KEY_FALLBACK = os.environ.get(
    "TNODE_CHAT_SYNC_WEB_API_KEY",
    "AIzaSyCOybTP4r9J2bWXiJvXY0MQBFvaYDo_iWU",
)

# Endpoints used by the self-healing path. When `mintNodeToken` returns 404
# (which means the gateway-side `nodeSyncRegistrations/{nodeId}` doc is gone
# — typically a Firestore reset wiped it), we re-run the registration flow
# the installer used at first install: pull a short-lived provisioning HMAC
# from `getProvisionToken`, then trade it for a fresh nodeSecret at
# `registerNodeSync`. The new secret overwrites the local config and the
# next mint cycle picks up where it left off, no manual intervention.
PROVISION_TOKEN_URL = (
    "https://us-central1-tbrain-platform-7fc1f.cloudfunctions.net/getProvisionToken"
)
REGISTER_NODE_SYNC_URL = (
    "https://us-central1-tbrain-platform-7fc1f.cloudfunctions.net/registerNodeSync"
)

# Assistant file uploads (v1.10.0+) — the inverse of process_uploads. When
# the agent writes `[adjunto: <path>]` in its turn text, we read the file,
# negotiate a signed PUT URL with `prepareAssistantFile`, upload, then
# `confirmAssistantFile` flips the doc to `uploaded` and we rewrite the
# marker as `[archivo:{attachmentId}]` before persisting to chats/.
PREPARE_ASSISTANT_FILE_URL = (
    "https://us-central1-tbrain-platform-7fc1f.cloudfunctions.net/prepareAssistantFile"
)
CONFIRM_ASSISTANT_FILE_URL = (
    "https://us-central1-tbrain-platform-7fc1f.cloudfunctions.net/confirmAssistantFile"
)
# Hard cap (mirrors server-side MAX_BYTES). Agents that try to attach a
# 200MB log get a friendly "[adjunto-error: too-large]" rewrite instead.
ASSISTANT_FILE_MAX_BYTES = 50 * 1024 * 1024
# Marker grammar (intentionally narrow — must escape the closing `]` if
# the path contains one, which is extremely rare in practice).
ASSISTANT_FILE_MARKER_RE = re.compile(r"\[adjunto:\s*([^\]\n]+?)\s*\]")

HOME = Path.home()
OPENCLAW_DIR = Path(os.environ.get("OPENCLAW_HOME", str(HOME / ".openclaw")))
CONFIG_PATH = Path(
    os.environ.get("TNODE_CHAT_SYNC_CONFIG", str(OPENCLAW_DIR / "tnode-chat-sync.json"))
)
LOG_PATH = Path(
    os.environ.get("TNODE_CHAT_SYNC_LOG", str(OPENCLAW_DIR / "logs" / "tnode-chat-sync.log"))
)
POLL_MS = int(os.environ.get("TNODE_CHAT_SYNC_POLL_MS", "500"))

# ── Chat attachments (v1.9.0+) ──────────────────────────────────
# Files the mobile app uploads via the (+) menu land in Firestore at
# `users/{uid}/nodes/{nodeId}/uploads/{attachmentId}` with status=pending.
# We poll every UPLOAD_POLL_INTERVAL_S, download the public URL into the
# agent's workspace, verify sha256, and flip status to downloaded so the
# Flutter client can send the WS message with the workspace path.
UPLOAD_DIR = Path(
    os.environ.get("TNODE_CHAT_SYNC_UPLOAD_DIR",
                   str(OPENCLAW_DIR / "workspace" / "upload"))
)
UPLOAD_POLL_INTERVAL_S = float(
    os.environ.get("TNODE_CHAT_SYNC_UPLOAD_POLL_S", "2.0")
)
# Server-side cap is 50MB (`prepareChatAttachment`); we re-validate locally
# so a manipulated signed URL can't drown the disk.
UPLOAD_MAX_BYTES = 50 * 1024 * 1024
UPLOAD_DOWNLOAD_CHUNK = 64 * 1024


def _log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    line = f"[{ts}] {msg}\n"
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG_PATH, "a") as f:
            f.write(line)
    except OSError:
        pass
    sys.stderr.write(line)


def _http_post_json(url: str, payload: dict, timeout: int = 15) -> dict:
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8")
        return json.loads(raw)


def _http_patch_json(url: str, payload: dict, headers: dict, timeout: int = 15) -> dict:
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json", **headers},
        method="PATCH",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8")
        return json.loads(raw) if raw else {}


def _http_post_json_authed(
    url: str, payload: dict, headers: dict, timeout: int = 30
) -> dict:
    """POST with auth headers — used for Firestore runQuery."""
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json", **headers},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8")
        return json.loads(raw) if raw else {}


def load_config() -> dict:
    if not CONFIG_PATH.is_file():
        raise RuntimeError(
            f"Config {CONFIG_PATH} missing. Run tnode-setup.sh register step."
        )
    with open(CONFIG_PATH) as f:
        cfg = json.load(f)
    for k in ("nodeId", "nodeSecret", "mintUrl"):
        if not cfg.get(k):
            raise RuntimeError(f"Config missing {k}")
    return cfg


def mint_token(cfg: dict) -> dict:
    """Request a fresh Firebase custom token + exchange for idToken.

    Returns {idToken, uid, nodeId, expiresAt (epoch seconds)}.
    """
    ts = str(int(time.time() * 1000))
    nonce = py_secrets.token_hex(16)
    mac = hmac.new(
        cfg["nodeSecret"].encode("utf-8"),
        f'{cfg["nodeId"]}:{ts}:{nonce}'.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    mint_resp = _http_post_json(
        cfg["mintUrl"],
        {
            "nodeId": cfg["nodeId"],
            "timestamp": ts,
            "nonce": nonce,
            "signature": mac,
        },
    )
    custom_token = mint_resp["customToken"]
    uid = mint_resp["uid"]
    node_id = mint_resp["nodeId"]

    api_key = cfg.get("webApiKey") or FIREBASE_WEB_API_KEY_FALLBACK
    if not api_key:
        raise RuntimeError(
            "No Firebase web API key configured. Set webApiKey in config or"
            " TNODE_CHAT_SYNC_WEB_API_KEY env var."
        )
    exchange = _http_post_json(
        f"https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key={api_key}",
        {"token": custom_token, "returnSecureToken": True},
    )
    return {
        "idToken": exchange["idToken"],
        "uid": uid,
        "nodeId": node_id,
        "expiresAt": int(time.time()) + int(exchange.get("expiresIn", "3600")) - 60,
    }


def reregister_with_server(cfg: dict) -> str:
    """Pull a fresh provisioning HMAC and re-create the
    `nodeSyncRegistrations/{nodeId}` doc on the server. Returns the new
    nodeSecret. The caller must persist it to disk and update its in-memory
    cfg before the next mint attempt.

    Used as a self-healing recovery when `mintNodeToken` starts returning
    404 (the registration doc was deleted out from under us). The server
    rotates the secret on every successful re-register, so callers can rely
    on this rebuilding the trust chain end-to-end.

    **Caveat**: the freshly-minted doc has nodeSecret but no `linkedUserId`
    until the `attachNodeSync` trigger fires. That trigger is bound to
    `users/{uid}/nodes/{nodeId}` writes, so the mint loop will continue to
    fail with 409 ("not linked") until the Flutter client touches the
    subdoc. The client's NodesNotifier upserts the subdoc on every
    add/update/remove; restoring the linkedUserId without user interaction
    requires a boot-time upsert (planned follow-up) or any node mutation.
    """
    # 1) Pull the short-lived provisioning HMAC. GET, no auth.
    req = urllib.request.Request(PROVISION_TOKEN_URL, method="GET")
    with urllib.request.urlopen(req, timeout=15) as resp:
        ptoken = json.loads(resp.read().decode("utf-8"))
    for k in ("timestamp", "nonce", "signature"):
        if not ptoken.get(k):
            raise RuntimeError(f"getProvisionToken response missing {k}")

    # 2) Trade it for a fresh nodeSecret. Server replaces the
    # nodeSyncRegistrations/{nodeId} doc with a newly-rotated one.
    response = _http_post_json(
        REGISTER_NODE_SYNC_URL,
        {
            "nodeId": cfg["nodeId"],
            "timestamp": ptoken["timestamp"],
            "nonce": ptoken["nonce"],
            "signature": ptoken["signature"],
        },
    )
    new_secret = response.get("nodeSecret")
    if not new_secret:
        raise RuntimeError(
            f"registerNodeSync returned no nodeSecret: {response}"
        )
    return new_secret


def persist_node_secret(cfg: dict, new_secret: str) -> None:
    """Atomically write the rotated nodeSecret back to the config file
    while preserving every other field (mintUrl, pullUrl, registeredAt, …)."""
    on_disk: dict
    try:
        with CONFIG_PATH.open() as f:
            on_disk = json.load(f)
    except (OSError, json.JSONDecodeError):
        on_disk = dict(cfg)
    on_disk["nodeSecret"] = new_secret
    on_disk["reregisteredAt"] = (
        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    )
    tmp = CONFIG_PATH.with_suffix(".json.tmp")
    with tmp.open("w") as f:
        json.dump(on_disk, f, indent=2)
    os.replace(tmp, CONFIG_PATH)
    try:
        os.chmod(CONFIG_PATH, 0o600)
    except OSError:
        pass


def _firestore_base(project_id: str) -> str:
    return f"https://firestore.googleapis.com/v1/projects/{project_id}/databases/(default)/documents"


# Firestore REST uses typed values. Helpers:

def _fs_value(v):
    if v is None:
        return {"nullValue": None}
    if isinstance(v, bool):
        return {"booleanValue": v}
    if isinstance(v, int):
        return {"integerValue": str(v)}
    if isinstance(v, float):
        return {"doubleValue": v}
    if isinstance(v, str):
        return {"stringValue": v}
    if isinstance(v, dict):
        return {"mapValue": {"fields": {k: _fs_value(x) for k, x in v.items()}}}
    if isinstance(v, list):
        return {"arrayValue": {"values": [_fs_value(x) for x in v]}}
    return {"stringValue": str(v)}


def _fs_fields(d: dict) -> dict:
    return {"fields": {k: _fs_value(v) for k, v in d.items()}}


def write_message(
    token: dict,
    project_id: str,
    uid: str,
    node_id: str,
    message_id: str,
    body: dict,
) -> None:
    base = _firestore_base(project_id)
    # PATCH with documentPath + updateMask-less body == upsert semantics.
    url = (
        f"{base}/users/{uid}/nodes/{node_id}/chats/{message_id}"
        f"?currentDocument.exists=false"
    )
    headers = {"Authorization": f"Bearer {token['idToken']}"}
    try:
        _http_patch_json(url, _fs_fields(body), headers)
    except urllib.error.HTTPError as e:
        # 409 = already exists (dedup hit). Safe to ignore.
        if e.code in (409, 412):
            return
        raise


# ── Chat attachments (uploads/) ────────────────────────────────

def _fs_field_to_python(v):
    """Inverse of _fs_value — pull a Python value out of a Firestore
    REST field map. Returns None when the field shape is unknown."""
    if not isinstance(v, dict):
        return None
    if "stringValue" in v:
        return v["stringValue"]
    if "integerValue" in v:
        try:
            return int(v["integerValue"])
        except (TypeError, ValueError):
            return None
    if "doubleValue" in v:
        return v["doubleValue"]
    if "booleanValue" in v:
        return v["booleanValue"]
    if "timestampValue" in v:
        return v["timestampValue"]
    return None


def query_pending_uploads(token: dict, project_id: str, limit: int = 20) -> list:
    """Run a structured query for uploads with status=pending under this
    node. Returns a list of {id, fields} dicts (Firestore REST shape).

    The query is scoped to the node — we don't sweep across users. The
    daemon's custom token doesn't have permission to read other users
    anyway; the query just makes that explicit and lets Firestore use
    the (status, createdAt) composite index."""
    parent = (
        f"projects/{project_id}/databases/(default)/documents"
        f"/users/{token['uid']}/nodes/{token['nodeId']}"
    )
    url = f"https://firestore.googleapis.com/v1/{parent}:runQuery"
    body = {
        "structuredQuery": {
            "from": [{"collectionId": "uploads"}],
            "where": {
                "fieldFilter": {
                    "field": {"fieldPath": "status"},
                    "op": "EQUAL",
                    "value": {"stringValue": "pending"},
                }
            },
            "orderBy": [
                {"field": {"fieldPath": "createdAt"}, "direction": "ASCENDING"},
            ],
            "limit": limit,
        }
    }
    headers = {"Authorization": f"Bearer {token['idToken']}"}
    raw = _http_post_json_authed(url, body, headers, timeout=20)
    out = []
    # runQuery returns a list of `{document}` entries. The list can be
    # empty (no matches) or contain `{readTime: ...}` entries which we
    # skip.
    if not isinstance(raw, list):
        return out
    for item in raw:
        doc = item.get("document") if isinstance(item, dict) else None
        if not doc:
            continue
        name = doc.get("name", "")
        doc_id = name.rsplit("/", 1)[-1] if name else ""
        if not doc_id:
            continue
        out.append({"id": doc_id, "fields": doc.get("fields", {})})
    return out


def _sanitize_segment(s: str) -> str:
    """Belt-and-suspenders: even though the CF already sanitized
    `sanitizedFileName`, drop anything that's not alnum/dot/dash/underscore
    so a malicious doc can't escape the upload dir."""
    safe = []
    for ch in s:
        if ch.isalnum() or ch in (".", "-", "_"):
            safe.append(ch)
        else:
            safe.append("_")
    out = "".join(safe).strip("._")
    return out or "file"


def download_public_url_to_file(url: str, dest: Path, max_bytes: int) -> tuple:
    """Stream a public URL into `dest`, capping at max_bytes and computing
    sha256 on the fly. Returns (hex_sha256, bytes_written). Raises on
    HTTP error, oversize, or write failure (after cleaning up partial)."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    h = hashlib.sha256()
    written = 0
    tmp = dest.with_suffix(dest.suffix + ".part")
    try:
        with urllib.request.urlopen(url, timeout=60) as resp:
            with open(tmp, "wb") as f:
                while True:
                    chunk = resp.read(UPLOAD_DOWNLOAD_CHUNK)
                    if not chunk:
                        break
                    written += len(chunk)
                    if written > max_bytes:
                        raise RuntimeError(
                            f"file exceeds {max_bytes} bytes — aborting"
                        )
                    h.update(chunk)
                    f.write(chunk)
        os.replace(tmp, dest)
    except Exception:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        raise
    return h.hexdigest(), written


def update_upload_doc(
    token: dict,
    project_id: str,
    attachment_id: str,
    fields: dict,
    mask: list,
) -> None:
    """PATCH a single upload doc with an updateMask covering only the
    fields we're writing. Without the mask, Firestore replaces the
    entire doc (and would wipe the original fileName/sizeBytes/etc)."""
    parent = (
        f"users/{token['uid']}/nodes/{token['nodeId']}/uploads/{attachment_id}"
    )
    mask_q = "&".join(f"updateMask.fieldPaths={k}" for k in mask)
    url = (
        f"https://firestore.googleapis.com/v1/projects/{project_id}"
        f"/databases/(default)/documents/{parent}?{mask_q}"
    )
    headers = {"Authorization": f"Bearer {token['idToken']}"}
    _http_patch_json(url, {"fields": fields}, headers)


def mark_upload_failed(
    token: dict, project_id: str, attachment_id: str, reason: str
) -> None:
    try:
        update_upload_doc(
            token,
            project_id,
            attachment_id,
            fields={
                "status": {"stringValue": "failed"},
                "errorReason": {"stringValue": reason[:500]},
            },
            mask=["status", "errorReason"],
        )
    except Exception as e:  # noqa: BLE001
        _log(f"upload {attachment_id}: mark failed errored: {e}")


def process_uploads(token: dict, project_id: str) -> None:
    """Poll pending uploads, download each into workspace/upload/,
    verify sha256, and flip status. Best-effort — failures are logged +
    written back to the doc so the user sees them in the chip.

    Raises HTTPError(401) so the main loop refreshes the token. Other
    errors are swallowed (logged) so one bad attachment doesn't stall
    the daemon's chat-mirror loop."""
    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
    try:
        pending = query_pending_uploads(token, project_id)
    except urllib.error.HTTPError as e:
        if e.code == 401:
            raise
        _log(f"uploads query: HTTP {e.code} {e.reason}")
        return
    except Exception as e:  # noqa: BLE001
        _log(f"uploads query error: {e}")
        return

    for doc in pending:
        aid = doc["id"]
        f = doc["fields"]
        sanitized = _fs_field_to_python(f.get("sanitizedFileName", {})) or ""
        public_url = _fs_field_to_python(f.get("publicUrl", {})) or ""
        expected_sha = _fs_field_to_python(f.get("sha256", {})) or ""
        size_bytes = _fs_field_to_python(f.get("sizeBytes", {})) or 0
        if not sanitized or not public_url or not expected_sha:
            _log(f"upload {aid}: missing required fields, marking failed")
            mark_upload_failed(token, project_id, aid, "missing required fields")
            continue
        if isinstance(size_bytes, int) and size_bytes > UPLOAD_MAX_BYTES:
            _log(f"upload {aid}: oversize {size_bytes}, marking failed")
            mark_upload_failed(token, project_id, aid, "exceeds local size cap")
            continue

        ts = time.strftime("%Y%m%d-%H%M%S")
        sha8 = expected_sha[:8]
        dest_name = _sanitize_segment(f"{ts}-{sha8}-{sanitized}")
        dest_path = UPLOAD_DIR / dest_name
        local_path = f"workspace/upload/{dest_name}"

        try:
            actual_sha, written = download_public_url_to_file(
                public_url, dest_path, UPLOAD_MAX_BYTES
            )
        except urllib.error.HTTPError as e:
            _log(f"upload {aid}: download HTTP {e.code} {e.reason}")
            mark_upload_failed(token, project_id, aid, f"download http {e.code}")
            continue
        except Exception as e:  # noqa: BLE001
            _log(f"upload {aid}: download error: {e}")
            mark_upload_failed(token, project_id, aid, f"download: {e}"[:200])
            continue

        if actual_sha != expected_sha:
            _log(
                f"upload {aid}: sha mismatch expected={expected_sha[:16]}… "
                f"actual={actual_sha[:16]}…"
            )
            try:
                dest_path.unlink()
            except FileNotFoundError:
                pass
            mark_upload_failed(token, project_id, aid, "sha256 mismatch")
            continue

        # Refresh ttlExpiresAt → downloadedAt + 24h so the cleanup CF
        # keeps the doc around for a full day after the download (the
        # original ttl was set from createdAt + 24h, which may be sooner).
        now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        ttl_iso = time.strftime(
            "%Y-%m-%dT%H:%M:%SZ",
            time.gmtime(time.time() + 24 * 3600),
        )
        try:
            update_upload_doc(
                token,
                project_id,
                aid,
                fields={
                    "status": {"stringValue": "downloaded"},
                    "localPath": {"stringValue": local_path},
                    "downloadedAt": {"timestampValue": now_iso},
                    "ttlExpiresAt": {"timestampValue": ttl_iso},
                },
                mask=["status", "localPath", "downloadedAt", "ttlExpiresAt"],
            )
            _log(
                f"upload {aid}: downloaded {written}B → {local_path}"
            )
        except urllib.error.HTTPError as e:
            if e.code == 401:
                raise
            _log(f"upload {aid}: status update HTTP {e.code} {e.reason}")
        except Exception as e:  # noqa: BLE001
            _log(f"upload {aid}: status update error: {e}")


# ── JSONL turn extraction ──────────────────────────────────────

# ── Assistant file uploads (v1.10.0+) ─────────────────────────────
#
# Resolves a path written by the agent (typically absolute under
# `~/.openclaw/workspace/...` or relative like `workspace/foo.pdf`) to a
# real file on disk, gated to live under OPENCLAW_DIR/workspace for
# safety — we don't want the agent leaking `/etc/passwd` or its own
# auth-profiles.json via a clever marker.

WORKSPACE_DIR = OPENCLAW_DIR / "workspace"


def _resolve_workspace_path(raw: str) -> Path | None:
    raw = raw.strip()
    if not raw:
        return None
    # Strip surrounding quotes the agent sometimes adds.
    for q in ('"', "'", "`"):
        if raw.startswith(q) and raw.endswith(q):
            raw = raw[1:-1].strip()
    # Expand ~ and env vars so `~/.openclaw/workspace/foo.pdf` works.
    raw = os.path.expandvars(os.path.expanduser(raw))
    # Strip the MEDIA: prefix some agents emit accidentally (saw in the wild
    # before the SOUL update — keep handling it gracefully for stragglers).
    if raw.startswith("MEDIA:"):
        raw = raw[len("MEDIA:"):].strip()
    p = Path(raw)
    if not p.is_absolute():
        # Treat `workspace/foo.pdf` as relative to OPENCLAW_HOME.
        p = OPENCLAW_DIR / p
    try:
        p = p.resolve(strict=False)
    except OSError:
        return None
    # Reject anything outside the workspace dir.
    try:
        workspace_resolved = WORKSPACE_DIR.resolve(strict=False)
        p.relative_to(workspace_resolved)
    except (ValueError, OSError):
        return None
    if not p.is_file():
        return None
    return p


def _sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(64 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _guess_mime(path: Path) -> str:
    mt, _ = mimetypes.guess_type(str(path))
    return mt or "application/octet-stream"


def _hmac_signature(node_secret: str, signing_string: str) -> str:
    return hmac.new(
        node_secret.encode(),
        signing_string.encode(),
        hashlib.sha256,
    ).hexdigest()


def _prepare_assistant_file(
    cfg: dict, file_path: Path, sha: str, size: int, mime: str
) -> dict | None:
    """POST /prepareAssistantFile. Returns response dict or None on error.
    Allowed errors get logged but don't crash the watcher — the marker is
    left untouched in the message so the user at least sees the path."""
    node_id = cfg["nodeId"]
    node_secret = cfg["nodeSecret"]
    ts = str(int(time.time() * 1000))
    nonce = py_secrets.token_hex(16)
    signing = f"{node_id}:{ts}:{nonce}:assistant_file:{sha}"
    body = {
        "nodeId": node_id,
        "timestamp": ts,
        "nonce": nonce,
        "signature": _hmac_signature(node_secret, signing),
        "fileName": file_path.name,
        "mimeType": mime,
        "sizeBytes": size,
        "sha256": sha,
    }
    try:
        return _http_post_json(PREPARE_ASSISTANT_FILE_URL, body)
    except urllib.error.HTTPError as e:
        _log(f"prepareAssistantFile {e.code}: {e.reason}")
        return None
    except Exception as e:  # noqa: BLE001
        _log(f"prepareAssistantFile error: {e}")
        return None


def _put_file_to_signed_url(url: str, file_path: Path, mime: str) -> bool:
    try:
        with open(file_path, "rb") as f:
            data = f.read()
        req = urllib.request.Request(
            url, data=data, method="PUT",
            headers={"Content-Type": mime},
        )
        with urllib.request.urlopen(req, timeout=120) as resp:
            return 200 <= resp.status < 300
    except urllib.error.HTTPError as e:
        _log(f"PUT signed URL {e.code}: {e.reason}")
        return False
    except Exception as e:  # noqa: BLE001
        _log(f"PUT signed URL error: {e}")
        return False


def _confirm_assistant_file(cfg: dict, attachment_id: str) -> bool:
    node_id = cfg["nodeId"]
    node_secret = cfg["nodeSecret"]
    ts = str(int(time.time() * 1000))
    nonce = py_secrets.token_hex(16)
    signing = f"{node_id}:{ts}:{nonce}:confirm:{attachment_id}"
    body = {
        "nodeId": node_id,
        "timestamp": ts,
        "nonce": nonce,
        "signature": _hmac_signature(node_secret, signing),
        "attachmentId": attachment_id,
    }
    try:
        _http_post_json(CONFIRM_ASSISTANT_FILE_URL, body)
        return True
    except Exception as e:  # noqa: BLE001
        _log(f"confirmAssistantFile error: {e}")
        return False


def _process_one_marker(cfg: dict, raw_path: str) -> str | None:
    """Resolve + upload + confirm. Returns attachmentId on success, None on
    any failure (caller leaves the marker untouched or rewrites it as
    `[adjunto-error:...]`)."""
    resolved = _resolve_workspace_path(raw_path)
    if resolved is None:
        _log(f"adjunto: rejected path '{raw_path}' (not under workspace)")
        return None
    try:
        size = resolved.stat().st_size
    except OSError as e:
        _log(f"adjunto: stat failed for {resolved}: {e}")
        return None
    if size <= 0:
        _log(f"adjunto: empty file {resolved}")
        return None
    if size > ASSISTANT_FILE_MAX_BYTES:
        _log(f"adjunto: too large {resolved} ({size} bytes)")
        return None
    try:
        sha = _sha256_of(resolved)
    except OSError as e:
        _log(f"adjunto: sha256 failed for {resolved}: {e}")
        return None
    mime = _guess_mime(resolved)
    prep = _prepare_assistant_file(cfg, resolved, sha, size, mime)
    if prep is None:
        return None
    attachment_id = prep.get("attachmentId")
    upload_url = prep.get("uploadUrl")
    if not attachment_id or not upload_url:
        _log(f"adjunto: prepare response missing fields: {prep}")
        return None
    if not _put_file_to_signed_url(upload_url, resolved, mime):
        _log(f"adjunto: PUT failed for {resolved}")
        return None
    if not _confirm_assistant_file(cfg, attachment_id):
        # Doc is in `preparing` state — cleanup will reap after TTL. Still
        # not safe to rewrite the marker because the client needs `uploaded`
        # to render.
        return None
    _log(f"adjunto uploaded: {resolved.name} → attachmentId={attachment_id}")
    return attachment_id


def process_assistant_file_markers(cfg: dict, content: str) -> str:
    """Walk every `[adjunto: <path>]` in content, upload each, rewrite to
    `[archivo:{id}]`. On failure, the marker becomes `[adjunto-error: ...]`
    so the user sees why their file didn't come through.

    Idempotent: an already-rewritten `[archivo:{id}]` won't match the
    regex and stays as-is, so retries of the same trajectory entry don't
    re-upload."""

    def replace(m: re.Match) -> str:
        raw_path = m.group(1).strip()
        attachment_id = _process_one_marker(cfg, raw_path)
        if attachment_id:
            return f"[archivo:{attachment_id}]"
        return "[adjunto-error: no se pudo subir el archivo]"

    return ASSISTANT_FILE_MARKER_RE.sub(replace, content)


def extract_content(raw):
    if raw is None:
        return ""
    if isinstance(raw, str):
        return raw
    if isinstance(raw, list):
        parts = []
        for part in raw:
            if isinstance(part, dict) and part.get("type") == "text" and part.get("text"):
                parts.append(part["text"])
            elif isinstance(part, str):
                parts.append(part)
        return "\n".join(p for p in parts if p)
    return str(raw)


# OpenClaw's built-in heartbeat periodically injects a system prompt asking
# the agent to reply HEARTBEAT_OK when no action is needed. That ack is
# bookkeeping, not real output — mirroring it to Firestore would surface as
# a push notification on the client's lockscreen.
#
# Some agents don't reply with the literal ack: they narrate what they did
# during the heartbeat ("Gateway reconectado… según HEARTBEAT.md.",
# "No hay solicitudes pendientes. Termino sin output según HEARTBEAT.md.").
# HEARTBEAT.md is the server-side instructions file and never legitimately
# appears in user-facing answers, so any assistant turn that references it
# is treated as heartbeat bookkeeping and dropped.
# Assistant turns whose entire content is one of these sentinels are
# agent-internal signals (heartbeat acks, refusal markers) that should NOT
# be surfaced to the user. NO_REPLY / NO_RESPONSE are emitted when the agent
# declines to answer (e.g. guardrail-triggered questions about the model).
# NO_RE handles the truncated form we've observed when the response is cut
# off at the first token boundary.
_SILENT_ACK_PATTERNS = frozenset({
    "HEARTBEAT_OK", "HEARTBEAT OK",
    "NO_REPLY", "NO_RESPONSE", "NO_RE",
})
_HEARTBEAT_MARKER = "HEARTBEAT.MD"


def _is_silent_ack(role: str, content: str) -> bool:
    if role != "assistant":
        return False
    upper = content.strip().upper()
    if upper in _SILENT_ACK_PATTERNS:
        return True
    return _HEARTBEAT_MARKER in upper


def parse_line(line: str):
    """Parse a JSONL line into the raw entry dict, or None if not JSON."""
    line = line.strip()
    if not line:
        return None
    try:
        return json.loads(line)
    except json.JSONDecodeError:
        return None


def assistant_turn_from(entry: dict):
    """Return a normalized assistant turn dict (without runId) or None.

    Extracts content from a `type:"message", role:"assistant"` entry.
    The runId is NOT in this entry — it arrives later in a sibling
    `type:"custom", customType:"openclaw:bootstrap-context:full"` whose
    `parentId` matches `entry.id`. `main()` resolves that and sets turnId.
    """
    if entry.get("type") != "message":
        return None
    msg = entry.get("message") or {}
    role = (msg.get("role") or entry.get("role") or "").lower()
    # User messages are written to Firestore directly by the Flutter client
    # with clean content and stable UUIDs. The watcher only needs to mirror
    # assistant turns — they stream over WebSocket and would be lost if the
    # app closes mid-response.
    if role != "assistant":
        return None
    content = extract_content(msg.get("content") or entry.get("content"))
    if not content.strip():
        return None
    if _is_silent_ack(role, content):
        return None
    ts_raw = entry.get("timestamp") or entry.get("ts") or msg.get("timestamp")
    # Legacy path: some older OpenClaw builds did attach runId to the
    # message entry. Keep it as a best-effort fallback.
    legacy_run = (
        entry.get("runId") or entry.get("turnId") or msg.get("runId")
    )
    return {
        "role": role,
        "content": content,
        "ts": ts_raw,
        "turnId": legacy_run,
        "idempotencyKey": entry.get("idempotencyKey") or msg.get("idempotencyKey"),
        "entryId": entry.get("id"),
    }


def runid_from_custom(entry: dict):
    """Return (parentId, runId) if entry is the bootstrap-context custom
    event that follows an assistant message; else (None, None).

    Used only on legacy OpenClaw (v2026.4.x) sessions that don't ship a
    sibling `*.trajectory.jsonl`. Newer builds (v2026.5.x) deprecated this
    custom event and put runId directly on `type:"model.completed"` in
    the trajectory file — see `assistant_turn_from_trajectory` below.
    """
    if entry.get("type") != "custom":
        return (None, None)
    if entry.get("customType") != "openclaw:bootstrap-context:full":
        return (None, None)
    data = entry.get("data") or {}
    return (entry.get("parentId"), data.get("runId"))


def assistant_turn_from_trajectory(entry: dict):
    """Return a normalized assistant turn from an OpenClaw v2026.5.x
    `type:"model.completed"` trajectory event, or None if `entry` is not
    that shape.

    The trajectory event already carries the runId, so the resulting turn
    can be flushed immediately — no buffering / bootstrap-context wait,
    and the Firestore doc id will be `a_{runId}` (matching what the
    Flutter client uses for live-stream dedup).
    """
    if entry.get("type") != "model.completed":
        return None
    data = entry.get("data") or {}
    texts = data.get("assistantTexts") or []
    if not isinstance(texts, list):
        return None
    content = "\n".join(t for t in texts if isinstance(t, str)).strip()
    if not content:
        return None
    if _is_silent_ack("assistant", content):
        return None
    run_id = entry.get("runId") or data.get("runId")
    ts_raw = entry.get("ts") or entry.get("timestamp") or data.get("ts")
    return {
        "role": "assistant",
        "content": content,
        "ts": ts_raw,
        "turnId": run_id,
        # Use the runId as the idempotency key too — message_id_for() reads
        # idempotencyKey to build the Firestore doc id. Without this the
        # trajectory flow falls through to a content-hash id, breaking the
        # promised `a_{runId}` shape and weakening the dedup guarantee.
        "idempotencyKey": run_id,
        "entryId": None,  # no buffering needed — runId is already populated
    }


def message_id_for(turn: dict) -> str:
    """Deterministic id so restarts don't duplicate."""
    if turn.get("idempotencyKey"):
        prefix = "u_" if turn["role"] == "user" else "a_"
        return f"{prefix}{turn['idempotencyKey']}"
    h = hashlib.sha256(
        f'{turn["role"]}|{turn.get("ts") or ""}|{turn["content"][:256]}'.encode()
    ).hexdigest()[:32]
    prefix = "u_" if turn["role"] == "user" else "a_"
    return f"{prefix}{h}"


# ── File tailer ────────────────────────────────────────────────

class SessionTailer:
    def __init__(self, sessions_dir: Path):
        self.sessions_dir = sessions_dir
        # (dev, inode) -> offset
        self.offsets: dict[tuple, int] = {}
        # Watcher start time (monotonic file mtime). Files with mtime newer
        # than this are "born after the watcher started" — i.e. live sessions
        # we need to mirror from byte 0, not historical logs to skip.
        self.start_time = time.time()

    def _iter_files(self):
        if not self.sessions_dir.is_dir():
            # When systemd starts the daemon immediately after install, the
            # OpenClaw agent dir (~/.openclaw/agents/main/) doesn't exist yet
            # — it's only created when the user completes the first pair.
            # Re-resolve on every miss so the watcher self-heals without
            # needing a manual restart.
            new_dir = resolve_sessions_dir()
            if new_dir.is_dir() and new_dir != self.sessions_dir:
                _log(f"sessions dir appeared — now watching {new_dir}")
                self.sessions_dir = new_dir
            else:
                return []
        # OpenClaw v2026.5.x writes a sibling `<sessionId>.trajectory.jsonl`
        # next to each `<sessionId>.jsonl`. The trajectory file is canonical
        # and includes `type:"model.completed"` events with the runId we
        # need for client-side dedup. When present we tail ONLY the
        # trajectory file for that session and ignore the legacy main jsonl
        # (which still has `type:"message"` entries but no longer ships the
        # `bootstrap-context:full` correlation event the watcher used to
        # rely on, so it would always time out and write hash-based ids
        # — duplicating against the live-WS message in the client).
        all_files = sorted(self.sessions_dir.glob("*.jsonl"))
        traj_sessions = {
            p.name[: -len(".trajectory.jsonl")]
            for p in all_files
            if p.name.endswith(".trajectory.jsonl")
        }
        out: list[Path] = []
        for p in all_files:
            if p.name.endswith(".trajectory.jsonl"):
                out.append(p)
                continue
            session_id = p.stem
            if session_id in traj_sessions:
                # Legacy jsonl is shadowed by a trajectory file — skip it.
                continue
            out.append(p)
        return out

    def read_new_lines(self):
        for path in self._iter_files():
            try:
                st = path.stat()
            except OSError:
                continue
            key = (st.st_dev, st.st_ino)
            offset = self.offsets.get(key)
            if offset is None:
                # First time seeing this file. Two cases:
                #   - Created before the watcher started  → historical,
                #     skip to EOF so we don't flood Firestore with old turns.
                #   - Created after the watcher started  → brand-new live
                #     session; read from byte 0 (OpenClaw writes several
                #     bootstrap lines + the first user/assistant pair in the
                #     same flush, so we'd otherwise lose the whole thing).
                if st.st_mtime > self.start_time:
                    offset = 0
                else:
                    self.offsets[key] = st.st_size
                    continue
            if st.st_size < offset:
                # Truncation or rotation — reset
                offset = 0
            if st.st_size == offset:
                continue
            try:
                with open(path, "r") as f:
                    f.seek(offset)
                    chunk = f.read()
                    new_offset = f.tell()
            except OSError:
                continue
            self.offsets[key] = new_offset
            for line in chunk.splitlines():
                yield line


def resolve_sessions_dir() -> Path:
    override = os.environ.get("TNODE_CHAT_SYNC_SESSIONS")
    if override:
        return Path(override)
    # Discover the default agent dir under ~/.openclaw/agents/*/sessions
    agents_dir = OPENCLAW_DIR / "agents"
    if not agents_dir.is_dir():
        return OPENCLAW_DIR / "sessions"  # fallback, won't exist
    # Prefer 'main' if present, else first alphabetical
    if (agents_dir / "main" / "sessions").is_dir():
        return agents_dir / "main" / "sessions"
    for sub in sorted(agents_dir.iterdir()):
        s = sub / "sessions"
        if s.is_dir():
            return s
    return agents_dir / "main" / "sessions"


# ── Main loop ──────────────────────────────────────────────────

def main() -> int:
    try:
        cfg = load_config()
    except Exception as e:  # noqa: BLE001
        _log(f"config error: {e}")
        return 2

    # Project id is derived from the mintUrl hostname.
    project_id = "tbrain-platform-7fc1f"

    sessions_dir = resolve_sessions_dir()
    _log(f"watching {sessions_dir}")

    tailer = SessionTailer(sessions_dir)
    token: dict | None = None
    backoff = 1.0

    # Assistant turns are buffered here keyed by the JSONL entry id until
    # their sibling `openclaw:bootstrap-context:full` event arrives with
    # the real runId — which is the same id the Flutter client observed
    # over the WebSocket, so writing `a_{runId}` deduplicates live streams
    # against the mirror on the client side.
    pending: dict[str, dict] = {}  # entryId -> turn + {bufferedAt: float}
    PENDING_TIMEOUT_S = 15.0

    def flush_turn(t: dict):
        if token is None:
            return
        mid = message_id_for(t)
        # Rewrite `[adjunto: <path>]` markers from the agent's text into
        # `[archivo:{id}]` after uploading the files to Storage. Skip
        # entirely when no marker present (fast path — the `in` check
        # avoids regex compilation when the agent didn't attach anything).
        content = t["content"]
        if "[adjunto:" in content:
            content = process_assistant_file_markers(cfg, content)
        body = {
            "id": mid,
            "role": t["role"],
            "content": content,
            "status": "complete",
            "source": "watcher",
            "createdAt": t.get("ts") or "",
            "updatedAt": t.get("ts") or "",
        }
        if t.get("turnId"):
            body["turnId"] = t["turnId"]
        try:
            write_message(
                token,
                project_id,
                token["uid"],
                token["nodeId"],
                mid,
                body,
            )
            _log(f"wrote {mid} (runId={t.get('turnId') or 'hash'})")
        except urllib.error.HTTPError as e:
            if e.code == 401:
                _log("idToken expired mid-write — refreshing")
                raise
            _log(f"write error: {e.code} {e.reason}")
        except Exception as e:  # noqa: BLE001
            _log(f"write error: {e}")

    # When `mintNodeToken` keeps returning 404 (server-side registration doc
    # gone), we re-register at most this often to avoid hammering the
    # endpoint if rotation itself is failing.
    REREGISTER_COOLDOWN_S = 300
    last_reregister_attempt = 0.0

    # Cadence for chat-attachment polling. Runs alongside the JSONL tail
    # loop but at a slower clock so we don't pound Firestore — 2s feels
    # snappy in the UI (the user sees the chip flip from "procesando" to
    # "listo" within ~3s of the PUT landing).
    last_uploads_check = 0.0

    while True:
        try:
            now = int(time.time())
            if token is None or now >= token["expiresAt"]:
                try:
                    token = mint_token(cfg)
                except urllib.error.HTTPError as e:
                    if e.code == 404 and (now - last_reregister_attempt) >= REREGISTER_COOLDOWN_S:
                        _log(
                            "mintNodeToken 404 — registration doc missing on server; "
                            "attempting self-heal via registerNodeSync"
                        )
                        last_reregister_attempt = now
                        try:
                            new_secret = reregister_with_server(cfg)
                            persist_node_secret(cfg, new_secret)
                            cfg["nodeSecret"] = new_secret
                            _log("re-registered ok — new nodeSecret persisted")
                            # Loop back to retry mint with the new secret.
                            continue
                        except Exception as re:  # noqa: BLE001
                            _log(f"re-register failed: {re}")
                    raise
                _log(f"minted token for uid={token['uid']} node={token['nodeId']}")
                backoff = 1.0

            for line in tailer.read_new_lines():
                entry = parse_line(line)
                if entry is None:
                    continue

                # Case 0 (preferred — OpenClaw v2026.5.x trajectory event):
                # `model.completed` carries the runId and the final
                # assistant text in one shot. Flush directly so the doc
                # lands as `a_{runId}` and matches the live-stream
                # message the Flutter client already wrote with the same
                # turnId. No buffering / timeout wait.
                turn = assistant_turn_from_trajectory(entry)
                if turn is not None:
                    try:
                        flush_turn(turn)
                    except urllib.error.HTTPError as e:
                        if e.code == 401:
                            token = None
                            break
                    continue

                # Case A: assistant message → buffer waiting for runId.
                turn = assistant_turn_from(entry)
                if turn is not None:
                    if turn.get("turnId"):
                        # Legacy build: runId was on the message itself.
                        try:
                            flush_turn(turn)
                        except urllib.error.HTTPError as e:
                            if e.code == 401:
                                token = None
                                break
                    elif turn.get("entryId"):
                        turn["bufferedAt"] = time.time()
                        pending[turn["entryId"]] = turn
                    else:
                        # No entry id to correlate — write with hash fallback.
                        try:
                            flush_turn(turn)
                        except urllib.error.HTTPError as e:
                            if e.code == 401:
                                token = None
                                break
                    continue

                # Case B: bootstrap-context custom event → resolve a
                # pending assistant turn with its runId.
                parent_id, run_id = runid_from_custom(entry)
                if parent_id and run_id and parent_id in pending:
                    pending_turn = pending.pop(parent_id)
                    pending_turn["turnId"] = run_id
                    try:
                        flush_turn(pending_turn)
                    except urllib.error.HTTPError as e:
                        if e.code == 401:
                            token = None
                            break

            # Flush anything that has been pending too long — avoids
            # losing turns if OpenClaw fails to emit the custom event.
            deadline = time.time() - PENDING_TIMEOUT_S
            expired = [k for k, v in pending.items() if v["bufferedAt"] < deadline]
            for k in expired:
                t = pending.pop(k)
                _log(f"flushing stale assistant turn {k} (no runId after {PENDING_TIMEOUT_S}s)")
                try:
                    flush_turn(t)
                except urllib.error.HTTPError as e:
                    if e.code == 401:
                        token = None
                        break

            # Chat-attachment poll — slower clock than the JSONL tail.
            now_f = time.time()
            if (
                token is not None
                and (now_f - last_uploads_check) >= UPLOAD_POLL_INTERVAL_S
            ):
                last_uploads_check = now_f
                try:
                    process_uploads(token, project_id)
                except urllib.error.HTTPError as e:
                    if e.code == 401:
                        _log("uploads poll: idToken rejected — refreshing")
                        token = None

            time.sleep(POLL_MS / 1000.0)
        except KeyboardInterrupt:
            return 0
        except Exception as e:  # noqa: BLE001
            _log(f"loop error: {e}; backoff={backoff:.1f}s")
            time.sleep(backoff)
            backoff = min(60.0, backoff * 2)


if __name__ == "__main__":
    sys.exit(main())

CHATSYNCPYEOF
}

install_tnode_chat_sync() {
    local DEST_SCRIPTS="$OPENCLAW_HOME/scripts"
    mkdir -p "$DEST_SCRIPTS" "$OPENCLAW_HOME/logs"

    write_tnode_chat_sync_py "$DEST_SCRIPTS/tnode_chat_sync.py"
    chmod +x "$DEST_SCRIPTS/tnode_chat_sync.py"
    chown -R "$TNODE_USER":"$TNODE_USER" "$OPENCLAW_HOME" 2>/dev/null || true

    success "tnode-chat-sync → $DEST_SCRIPTS/tnode_chat_sync.py"

    case "$OS" in
        Darwin) install_chat_sync_launchd ;;
        Linux)  install_chat_sync_systemd ;;
    esac
}

install_chat_sync_launchd() {
    local plist_label="com.tbrain.tnode-chat-sync"
    local plist_dest="$HOME/Library/LaunchAgents/${plist_label}.plist"

    mkdir -p "$(dirname "$plist_dest")"

    cat > "$plist_dest" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${plist_label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/env</string>
        <string>python3</string>
        <string>${OPENCLAW_HOME}/scripts/tnode_chat_sync.py</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>${OPENCLAW_HOME}/logs/tnode-chat-sync.out.log</string>
    <key>StandardErrorPath</key><string>${OPENCLAW_HOME}/logs/tnode-chat-sync.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key><string>${HOME}</string>
        <key>OPENCLAW_HOME</key><string>${OPENCLAW_HOME}</string>
    </dict>
    <key>WorkingDirectory</key><string>${OPENCLAW_HOME}</string>
</dict>
</plist>
PLIST

    launchctl unload "$plist_dest" 2>/dev/null || true
    launchctl load "$plist_dest"
    success "LaunchAgent tnode-chat-sync cargado"
}

install_chat_sync_systemd() {
    if ! command_exists systemctl; then
        warn "systemctl no disponible — saltando systemd setup del chat-sync"
        return 0
    fi
    _systemd_update_only_handled "tnode-chat-sync" && return 0

    local systemd_dir="/etc/systemd/system"

    cat > "$systemd_dir/tnode-chat-sync.service" <<SVCUNIT
[Unit]
Description=TNode chat-to-Firestore sync watcher
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${TNODE_USER}
ExecStart=/usr/bin/env python3 ${OPENCLAW_HOME}/scripts/tnode_chat_sync.py
Restart=always
RestartSec=10
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=HOME=${TNODE_HOME}
Environment=OPENCLAW_HOME=${OPENCLAW_HOME}
StandardOutput=append:${OPENCLAW_HOME}/logs/tnode-chat-sync.out.log
StandardError=append:${OPENCLAW_HOME}/logs/tnode-chat-sync.err.log

[Install]
WantedBy=multi-user.target
SVCUNIT

    systemctl daemon-reload
    systemctl enable --now tnode-chat-sync.service 2>/dev/null || true
    success "systemd tnode-chat-sync habilitado (User=$TNODE_USER)"
}

# ═════════════════════════════════════════════
# tnode-telemetry: WS proxy + live events (TELEMETRY.md)
# ═════════════════════════════════════════════

install_tnode_telemetry() {
    local DEST_SCRIPTS="$OPENCLAW_HOME/scripts"
    mkdir -p "$DEST_SCRIPTS" "$OPENCLAW_HOME/logs"

    write_tnode_telemetry_py "$DEST_SCRIPTS/tnode_telemetry.py"
    chmod +x "$DEST_SCRIPTS/tnode_telemetry.py"
    chown -R "$TNODE_USER":"$TNODE_USER" "$OPENCLAW_HOME" 2>/dev/null || true

    success "tnode-telemetry → $DEST_SCRIPTS/tnode_telemetry.py"

    case "$OS" in
        Linux) install_telemetry_systemd ;;
        # Darwin support deferred — existing cloud nodes are Linux VPSs.
    esac
}

install_telemetry_systemd() {
    if ! command_exists systemctl; then
        warn "systemctl no disponible — saltando systemd setup del telemetry"
        return 0
    fi
    _systemd_update_only_handled "tnode-telemetry" && return 0

    local systemd_dir="/etc/systemd/system"

    cat > "$systemd_dir/tnode-telemetry.service" <<SVCUNIT
[Unit]
Description=TNode telemetry — WS proxy + live events over the openclaw gateway
Documentation=https://github.com/cmoralestbrain/skills/blob/main/TELEMETRY.md
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${TNODE_USER}
ExecStart=/usr/bin/env python3 ${OPENCLAW_HOME}/scripts/tnode_telemetry.py
Restart=always
RestartSec=2
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=HOME=${TNODE_HOME}
Environment=OPENCLAW_HOME=${OPENCLAW_HOME}
Environment=TNODE_TELEMETRY_HOST=127.0.0.1
Environment=TNODE_TELEMETRY_PORT=18790
Environment=TNODE_TELEMETRY_UPSTREAM=ws://127.0.0.1:18789
StandardOutput=append:${OPENCLAW_HOME}/logs/tnode-telemetry.out.log
StandardError=append:${OPENCLAW_HOME}/logs/tnode-telemetry.err.log

[Install]
WantedBy=multi-user.target
SVCUNIT

    systemctl daemon-reload
    systemctl enable --now tnode-telemetry.service 2>/dev/null || true
    success "systemd tnode-telemetry habilitado (User=$TNODE_USER)"
}

write_tnode_telemetry_py() {
    local dest="$1"
    cat > "$dest" <<'TELEMETRYPYEOF'
#!/usr/bin/env python3
"""tnode-telemetry — WebSocket proxy + telemetry emitter for openclaw-gateway.

Listens on 127.0.0.1:18790, forwards all frames bidirectionally to the
local openclaw-gateway (127.0.0.1:18789) so the mobile client keeps a
single logical WebSocket per node, and injects telemetry events defined in
skills/TELEMETRY.md.

Iteration 1: one stream → `usage`.
  - Snapshot on client connect (best-effort, marked stale until OR roundtrip).
  - Delta per agent turn-end, parsed from the session jsonl files the
    gateway writes under ~/.openclaw/agents/main/sessions/.
  - Health stream reserved for iteration 2.

Runs as its own systemd unit (tnode-telemetry.service).
"""
from __future__ import annotations
# 1.8.15 — _agent_model_set now upserts the slug under
#          providers[p].models[] (in addition to the existing
#          defaults.models merge from 1.8.14). Without the catalog
#          insert, switching a per-agent model in Cerebro left the
#          gateway's allowlist updated but the provider catalog stale,
#          which the resolver fell back through silently to the
#          previous default. Idempotent; no-op on un-prefixed slugs.
# 1.8.14 — _agent_model_set merges into defaults.models instead of
#          overwriting it (preserves multi-agent distinct picks).
__VERSION__ = "1.9.0"

import argparse
import asyncio
import hashlib
import hmac
import json
import logging
import os
import secrets as py_secrets
import signal
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, Optional, Set

try:
    import websockets
    from websockets.exceptions import ConnectionClosed, WebSocketException
except ImportError:
    print(
        "tnode-telemetry: 'websockets' package not installed. "
        "Install via: apt install python3-websockets   (or pip install websockets)",
        file=sys.stderr,
    )
    sys.exit(1)

try:
    import psutil  # type: ignore
    _HAS_PSUTIL = True
except ImportError:
    _HAS_PSUTIL = False


# ── Defaults / environment ───────────────────────────────────────────

LISTEN_HOST = os.environ.get("TNODE_TELEMETRY_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("TNODE_TELEMETRY_PORT", "18790"))
UPSTREAM_URI = os.environ.get(
    "TNODE_TELEMETRY_UPSTREAM", "ws://127.0.0.1:18789"
)

OPENCLAW_HOME = Path(
    os.environ.get("OPENCLAW_HOME", str(Path.home() / ".openclaw"))
)
SESSIONS_DIR = OPENCLAW_HOME / "agents" / "main" / "sessions"
OPENCLAW_JSON = OPENCLAW_HOME / "openclaw.json"
CHAT_SYNC_CONFIG = OPENCLAW_HOME / "tnode-chat-sync.json"

# How often the sessions tailer re-checks new bytes. Cheap enough at 250 ms.
TAIL_INTERVAL_MS = int(os.environ.get("TNODE_TELEMETRY_TAIL_INTERVAL_MS", "250"))

# After a turn lands, wait this long before asking OpenRouter for the
# authoritative usage total. OR takes a beat to update its ledger, and we
# want to coalesce bursts (agent thinking + tool + final reply can fire
# multiple turns within a few hundred ms).
OR_REFRESH_DEBOUNCE_SEC = float(
    os.environ.get("TNODE_TELEMETRY_OR_DEBOUNCE_SEC", "2.5")
)

# Background refresh interval: OR is polled this often even without new
# turns, so a reopened app always sees a fresh total within this window.
OR_REFRESH_PERIODIC_SEC = float(
    os.environ.get("TNODE_TELEMETRY_OR_PERIODIC_SEC", "300")
)

# Timeout for the HMAC round-trip to pullLLMUsage.
OR_REFRESH_TIMEOUT_SEC = float(
    os.environ.get("TNODE_TELEMETRY_OR_TIMEOUT_SEC", "8")
)

PROJECT_ID = os.environ.get("TNODE_PROJECT_ID", "tbrain-platform-7fc1f")
DEFAULT_PULL_LLM_USAGE_URL = (
    f"https://us-central1-{PROJECT_ID}.cloudfunctions.net/pullLLMUsage"
)

# Max number of concurrent clients we expect (one phone per session). Higher
# is fine, this is just a logging heuristic.
WARN_CONCURRENT_CLIENTS = 16


# ── Logging ───────────────────────────────────────────────────────────

logger = logging.getLogger("tnode-telemetry")


def _setup_logging(verbose: bool) -> None:
    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )


# ── Usage accumulator ─────────────────────────────────────────────────

class UsageAccumulator:
    """Tracks cumulative LLM spend for this node across all sessions.

    Source of truth: the agent session jsonls. Every assistant message with
    `usage` and `stopReason` fields represents one turn that was billed. We
    sum `cost.total` across all turns written since the gateway was
    installed.

    On startup we re-ingest every jsonl so a daemon restart preserves the
    running total without a round-trip to OpenRouter. This matches VPS 1
    behavior — OpenClaw auto-selects the funded provider and doesn't need
    a remote sync.
    """

    def __init__(self, sessions_dir: Path) -> None:
        self._sessions_dir = sessions_dir
        self._total_usd: float = 0.0
        self._total_input_tokens: int = 0
        self._total_output_tokens: int = 0
        # Per-jsonl byte offset so we only parse new deltas on each tick.
        self._offsets: Dict[Path, int] = {}
        # Deduplicate turns by message id (jsonl `id` field of the assistant
        # message), because we re-parse files from the last offset on each
        # tick and occasionally the tail overlaps.
        self._seen_turn_ids: Set[str] = set()
        self._last_turn: Optional[Dict[str, Any]] = None

    @property
    def total_usd(self) -> float:
        return self._total_usd

    @property
    def total_input_tokens(self) -> int:
        return self._total_input_tokens

    @property
    def total_output_tokens(self) -> int:
        return self._total_output_tokens

    @property
    def last_turn(self) -> Optional[Dict[str, Any]]:
        return self._last_turn

    def bootstrap(self) -> None:
        """Parse all existing jsonls once at startup. Idempotent — running
        it again resets the accumulator and re-ingests."""
        self._total_usd = 0.0
        self._total_input_tokens = 0
        self._total_output_tokens = 0
        self._offsets.clear()
        self._seen_turn_ids.clear()
        self._last_turn = None
        if not self._sessions_dir.is_dir():
            return
        for path in sorted(self._sessions_dir.glob("*.jsonl")):
            self._consume_new(path)

    def tick(self) -> list[Dict[str, Any]]:
        """Check every jsonl for new bytes, return the list of new turn
        deltas (each a dict safe to ship in a usage event payload)."""
        if not self._sessions_dir.is_dir():
            return []
        new_deltas: list[Dict[str, Any]] = []
        for path in sorted(self._sessions_dir.glob("*.jsonl")):
            new_deltas.extend(self._consume_new(path))
        return new_deltas

    def _consume_new(self, path: Path) -> list[Dict[str, Any]]:
        try:
            size = path.stat().st_size
        except FileNotFoundError:
            return []
        offset = self._offsets.get(path, 0)
        if size <= offset:
            return []
        deltas: list[Dict[str, Any]] = []
        try:
            with path.open("rb") as f:
                f.seek(offset)
                chunk = f.read(size - offset)
        except OSError as e:
            logger.warning("could not read %s: %s", path, e)
            return []
        # Find the last complete line to avoid consuming a partial write.
        nl = chunk.rfind(b"\n")
        if nl < 0:
            return []
        complete = chunk[: nl + 1]
        self._offsets[path] = offset + len(complete)
        for raw in complete.splitlines():
            line = raw.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            delta = self._ingest_entry(entry)
            if delta is not None:
                deltas.append(delta)
        return deltas

    def _ingest_entry(self, entry: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        if entry.get("type") != "message":
            return None
        msg = entry.get("message") or {}
        if msg.get("role") != "assistant":
            return None
        usage = msg.get("usage")
        if not isinstance(usage, dict):
            return None
        turn_id = entry.get("id")
        if not turn_id or turn_id in self._seen_turn_ids:
            return None
        self._seen_turn_ids.add(turn_id)

        cost_total = 0.0
        cost = usage.get("cost")
        if isinstance(cost, dict):
            try:
                cost_total = float(cost.get("total") or 0.0)
            except (TypeError, ValueError):
                cost_total = 0.0
        try:
            input_tokens = int(usage.get("input") or 0)
        except (TypeError, ValueError):
            input_tokens = 0
        try:
            output_tokens = int(usage.get("output") or 0)
        except (TypeError, ValueError):
            output_tokens = 0

        self._total_usd += cost_total
        self._total_input_tokens += input_tokens
        self._total_output_tokens += output_tokens

        delta = {
            "turnId": turn_id,
            "input": input_tokens,
            "output": output_tokens,
            "costUsd": cost_total,
            "model": msg.get("model"),
            "provider": msg.get("provider"),
            "ts": entry.get("timestamp") or msg.get("timestamp"),
        }
        self._last_turn = delta
        return delta


# ── Auth + OpenRouter usage fetcher ──────────────────────────────────

def _load_node_auth() -> Optional[Dict[str, Any]]:
    """Read nodeId/nodeSecret + mtime from the chat-sync config. Both daemons
    share the same HMAC credential (set by the installer via registerNodeSync).

    Returns the file's mtime alongside the parsed payload so callers can
    cheaply detect rotation by comparing the cached mtime against the
    current stat without re-parsing JSON on every poll.
    """
    try:
        st = CHAT_SYNC_CONFIG.stat()
        data = json.loads(CHAT_SYNC_CONFIG.read_text())
    except Exception as e:
        logger.warning("failed to read %s: %s", CHAT_SYNC_CONFIG, e)
        return None
    node_id = data.get("nodeId")
    node_secret = data.get("nodeSecret")
    if not node_id or not node_secret:
        return None
    return {
        "nodeId": node_id,
        "nodeSecret": node_secret,
        "pullUsageUrl": data.get("pullLLMUsageUrl") or DEFAULT_PULL_LLM_USAGE_URL,
        "_mtime": st.st_mtime,
    }


def _fetch_or_usage_sync(auth: Dict[str, str]) -> Optional[Dict[str, Any]]:
    """Blocking HMAC call to pullLLMUsage. Run via asyncio.to_thread so we
    don't stall the event loop. Returns None on any failure — caller keeps
    its last-known good value."""
    ts = str(int(time.time() * 1000))
    nonce = py_secrets.token_hex(16)
    signing = f'{auth["nodeId"]}:{ts}:{nonce}'
    mac = hmac.new(
        auth["nodeSecret"].encode(),
        signing.encode(),
        hashlib.sha256,
    ).hexdigest()
    body = json.dumps({
        "nodeId": auth["nodeId"],
        "timestamp": ts,
        "nonce": nonce,
        "signature": mac,
    }).encode()
    req = urllib.request.Request(
        auth["pullUsageUrl"],
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=OR_REFRESH_TIMEOUT_SEC) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        try:
            detail = json.loads(e.read().decode())
        except Exception:  # noqa: BLE001
            detail = {"error": e.reason}
        logger.warning("pullLLMUsage HTTP %d: %s", e.code, detail)
    except Exception as e:  # noqa: BLE001
        logger.warning("pullLLMUsage failed: %s", e)
    return None


async def fetch_or_usage(auth: Dict[str, str]) -> Optional[Dict[str, Any]]:
    return await asyncio.to_thread(_fetch_or_usage_sync, auth)


# ── Telemetry event helpers ───────────────────────────────────────────

USAGE_STREAM = "usage"
USAGE_VERSION = 1

HEALTH_STREAM = "health"
HEALTH_VERSION = 3
HEALTH_TICK_SEC = float(os.environ.get("TNODE_TELEMETRY_HEALTH_TICK_SEC", "15"))

# TODO Channels v1 → CHANNELS_PROTOCOL_v1.md §2
# CHANNELS_STREAM = "channels"
# CHANNELS_VERSION = 1
# WA_PAIR_PATH = os.environ.get("TNODE_WA_PAIR_PATH", str(OPENCLAW_HOME / "wa-pair" / "wa-pair.js"))
# WA_AUTH_DIR = OPENCLAW_HOME / "credentials" / "whatsapp" / "default"
# WA_STATE_FILE = WA_AUTH_DIR / "state.json"
# WA_PAIR_TIMEOUT_SEC = 180

SESSIONS_STORE_FILE = SESSIONS_DIR / "sessions.json"


def _collect_health() -> Optional[Dict[str, Any]]:
    """Point-in-time system metrics scaled to 0..1 ratios. None if psutil
    is missing — caller should skip emission, not stall."""
    if not _HAS_PSUTIL:
        return None
    try:
        cpu = psutil.cpu_percent(interval=None) / 100.0
        vm = psutil.virtual_memory()
        ram = vm.percent / 100.0
        du = psutil.disk_usage("/")
        disk = du.percent / 100.0
        load_avg = list(os.getloadavg()) if hasattr(os, "getloadavg") else None
        uptime = int(time.time() - psutil.boot_time())
        return {
            "cpu": round(cpu, 4),
            "ram": round(ram, 4),
            "disk": round(disk, 4),
            "ramUsedMb": int(vm.used / (1024 * 1024)),
            "ramTotalMb": int(vm.total / (1024 * 1024)),
            "diskUsedGb": round(du.used / (1024 ** 3), 1),
            "diskTotalGb": round(du.total / (1024 ** 3), 1),
            "cpuCores": psutil.cpu_count(logical=True),
            "uptimeSec": uptime,
            "loadAvg1m": round(load_avg[0], 2) if load_avg else None,
        }
    except Exception as e:  # noqa: BLE001
        logger.warning("health collect failed: %s", e)
        return None


def _collect_active_ctx() -> Dict[str, Any]:
    """Read OpenClaw's session store and return the latest fresh context-window
    usage. Mirrors what `/context json` reports — fields come straight from the
    LLM response `usage` captured by the agent runner. We pick the session with
    the most recent `updatedAt` that also has `totalTokensFresh == true` and a
    numeric `totalTokens`; that is "the last real turn this node served" which
    is what the user is about to see in their app.

    Returns a dict always; `fresh: false` means no session has usable data yet
    (common right after restart, or with local LLM backends that don't surface
    `usage` — e.g. LM Studio)."""
    try:
        with open(SESSIONS_STORE_FILE, "r") as f:
            store = json.load(f)
    except FileNotFoundError:
        return {"fresh": False, "reason": "no-sessions-store"}
    except Exception as e:  # noqa: BLE001
        logger.warning("ctx: failed to read sessions.json: %s", e)
        return {"fresh": False, "reason": "read-error"}

    best = None
    for key, entry in store.items():
        if not isinstance(entry, dict):
            continue
        if entry.get("totalTokensFresh") is not True:
            continue
        total = entry.get("totalTokens")
        ctx_max = entry.get("contextTokens")
        if not isinstance(total, (int, float)) or total < 0:
            continue
        if not isinstance(ctx_max, (int, float)) or ctx_max <= 0:
            continue
        updated = entry.get("updatedAt") or 0
        if best is None or updated > best["updatedAt"]:
            best = {
                "sessionKey": key,
                "updatedAt": updated,
                "used": int(total),
                "max": int(ctx_max),
                "inputTokens": entry.get("inputTokens"),
                "outputTokens": entry.get("outputTokens"),
                "model": entry.get("model"),
            }

    if best is None:
        return {"fresh": False}

    pct = best["used"] / best["max"] if best["max"] else 0.0
    return {
        "fresh": True,
        "used": best["used"],
        "max": best["max"],
        "pct": round(pct, 4),
        "inputTokens": best["inputTokens"],
        "outputTokens": best["outputTokens"],
        "model": best["model"],
    }


def build_health_event(metrics: Dict[str, Any], ctx: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    payload: Dict[str, Any] = {
        "ts": _now_iso(),
        "snapshot": True,
        **metrics,
    }
    if ctx is not None:
        payload["ctx"] = ctx
    return {
        "type": "event",
        "stream": HEALTH_STREAM,
        "v": HEALTH_VERSION,
        "payload": payload,
    }


def build_usage_payload(
    accumulator: UsageAccumulator,
    or_cache: Optional[Dict[str, Any]],
    *,
    snapshot: bool,
    stale: bool = False,
    delta: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Merge OR authoritative totals (when available) with the local
    token-level bookkeeping. Falls back to locals while OR is unreachable."""
    if or_cache:
        total = float(or_cache.get("usage") or 0.0)
        limit = float(or_cache.get("limit") or 0.0)
        remaining = float(or_cache.get("limitRemaining") or max(limit - total, 0.0))
        usage_daily = float(or_cache.get("usageDaily") or 0.0)
        usage_weekly = float(or_cache.get("usageWeekly") or 0.0)
        usage_monthly = float(or_cache.get("usageMonthly") or 0.0)
        disabled = bool(or_cache.get("disabled") or False)
    else:
        total = accumulator.total_usd
        limit = 0.0
        remaining = 0.0
        usage_daily = 0.0
        usage_weekly = 0.0
        usage_monthly = 0.0
        disabled = False
        # If we have no OR cache yet, flag stale so the client can paint a
        # softer "hydrating" state instead of a hard zero.
        stale = True

    payload: Dict[str, Any] = {
        "ts": _now_iso(),
        "snapshot": snapshot,
        "totalUsd": round(total, 6),
        "limitUsd": round(limit, 6),
        "limitRemaining": round(max(remaining, 0.0), 6),
        "usageDaily": round(usage_daily, 6),
        "usageWeekly": round(usage_weekly, 6),
        "usageMonthly": round(usage_monthly, 6),
        "disabled": disabled,
        "totalInputTokens": accumulator.total_input_tokens,
        "totalOutputTokens": accumulator.total_output_tokens,
    }
    if stale:
        payload["stale"] = True
    if delta is not None:
        payload["delta"] = delta
    return {
        "type": "event",
        "stream": USAGE_STREAM,
        "v": USAGE_VERSION,
        "payload": payload,
    }


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# ── Proxy + emitter ───────────────────────────────────────────────────

class TelemetryProxy:
    """One instance per running daemon. Holds the shared accumulator, the
    set of currently-connected client writer handles, and the cached
    OpenRouter usage snapshot kept fresh by a background refresher."""

    def __init__(self) -> None:
        self._accumulator = UsageAccumulator(SESSIONS_DIR)
        self._clients: Set["ClientSession"] = set()
        self._tail_task: Optional[asyncio.Task] = None
        self._refresh_task: Optional[asyncio.Task] = None
        self._refresh_pending: Optional[asyncio.Task] = None
        self._health_task: Optional[asyncio.Task] = None
        self._auth: Optional[Dict[str, str]] = None
        self._or_cache: Optional[Dict[str, Any]] = None
        self._health_cache: Optional[Dict[str, Any]] = None
        # TODO Channels v1 → CHANNELS_PROTOCOL_v1.md §4
        # self._channels_state: Dict[str, Any] = _load_channels_state()
        # self._channels_cache: Optional[Dict[str, Any]] = None
        # self._wa_pair_proc: Optional[asyncio.subprocess.Process] = None
        # self._wa_pair_task: Optional[asyncio.Task] = None
        # self._wa_pair_lock = asyncio.Lock()

    async def start_background(self) -> None:
        self._accumulator.bootstrap()
        self._auth = _load_node_auth()
        if not self._auth:
            logger.warning(
                "no HMAC auth available (chat-sync config missing) — "
                "usage events will report only local token totals"
            )
        logger.info(
            "telemetry ready: listening %s:%d → upstream %s, sessions=%s, "
            "bootstrap tokens in=%d out=%d, auth=%s",
            LISTEN_HOST, LISTEN_PORT, UPSTREAM_URI, SESSIONS_DIR,
            self._accumulator.total_input_tokens,
            self._accumulator.total_output_tokens,
            "ok" if self._auth else "missing",
        )
        # Kick off an initial refresh so the first client connect already
        # has authoritative OR data cached. We don't await — the ws server
        # starts in parallel and the snapshot method tolerates a cold cache.
        self._refresh_task = asyncio.create_task(self._refresh_loop())
        self._tail_task = asyncio.create_task(self._tail_loop())
        if _HAS_PSUTIL:
            self._health_task = asyncio.create_task(self._health_loop())
        else:
            logger.warning(
                "psutil not installed — `health` stream disabled. "
                "Install with: apt install python3-psutil"
            )
        # TODO Channels v1 → CHANNELS_PROTOCOL_v1.md §4
        # No periodic loop — channels is event-driven (RPC-triggered).
        # On boot we just hydrate the in-memory state from state.json
        # so initial_snapshots() can serve a `linked` snapshot to
        # incoming clients without waiting for any event.
        # self._channels_cache = build_channels_event(self._channels_state, snapshot=True)

    async def stop_background(self) -> None:
        # TODO Channels v1 → kill self._wa_pair_proc if running, then await
        # self._wa_pair_task. State on disk persists; the next boot will
        # snapshot whatever was last `linked` or fall back to `unlinked`.
        for task in (
            self._tail_task,
            self._refresh_task,
            self._refresh_pending,
            self._health_task,
        ):
            if task is None:
                continue
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
        self._tail_task = None
        self._refresh_task = None
        self._refresh_pending = None
        self._health_task = None

    async def _tail_loop(self) -> None:
        while True:
            try:
                deltas = self._accumulator.tick()
                if deltas:
                    # OR ledger takes a moment to settle; debounce the fetch
                    # so a burst of turns triggers only one authoritative
                    # refresh. The delta event still ships immediately with
                    # the last known OR totals so the UI animates right away.
                    self._schedule_or_refresh()
                for delta in deltas:
                    event = build_usage_payload(
                        self._accumulator, self._or_cache,
                        snapshot=False, delta=delta,
                    )
                    await self._broadcast(event)
                    logger.info(
                        "usage delta: turn=%s tokens=%d/%d total(OR)=%.6f clients=%d",
                        delta.get("turnId"),
                        delta.get("input", 0), delta.get("output", 0),
                        event["payload"]["totalUsd"], len(self._clients),
                    )
            except asyncio.CancelledError:
                raise
            except Exception as e:  # noqa: BLE001
                logger.exception("tail loop error: %s", e)
            await asyncio.sleep(TAIL_INTERVAL_MS / 1000.0)

    async def _health_loop(self) -> None:
        """Periodic CPU/RAM/disk snapshot broadcast. First call to
        `psutil.cpu_percent(interval=None)` always returns 0.0 — we prime
        the counter and start the loop from the second tick."""
        try:
            psutil.cpu_percent(interval=None)
        except Exception:  # noqa: BLE001
            pass
        while True:
            try:
                metrics = _collect_health()
                ctx = _collect_active_ctx()
                if metrics:
                    event = build_health_event(metrics, ctx=ctx)
                    self._health_cache = event
                    await self._broadcast(event)
            except asyncio.CancelledError:
                raise
            except Exception as e:  # noqa: BLE001
                logger.exception("health loop error: %s", e)
            await asyncio.sleep(HEALTH_TICK_SEC)

    async def _refresh_loop(self) -> None:
        """Periodic background refresh of the OR usage cache. Separate from
        the debounced per-turn refresh — this one guarantees freshness even
        on quiet nodes (client top-ups, disabled flag flips, etc.)."""
        while True:
            try:
                await self._refresh_or_cache()
            except asyncio.CancelledError:
                raise
            except Exception as e:  # noqa: BLE001
                logger.exception("periodic refresh failed: %s", e)
            await asyncio.sleep(OR_REFRESH_PERIODIC_SEC)

    def _schedule_or_refresh(self) -> None:
        """Debounce: if a refresh is already pending, leave it alone — it
        will pick up the latest state when it fires. Otherwise start one."""
        if self._refresh_pending and not self._refresh_pending.done():
            return
        self._refresh_pending = asyncio.create_task(
            self._delayed_refresh(OR_REFRESH_DEBOUNCE_SEC)
        )

    async def _delayed_refresh(self, delay: float) -> None:
        try:
            await asyncio.sleep(delay)
            await self._refresh_or_cache(announce=True)
        except asyncio.CancelledError:
            raise
        except Exception as e:  # noqa: BLE001
            logger.warning("delayed refresh failed: %s", e)

    def _maybe_reload_auth(self) -> None:
        """Re-read chat-sync.json if its mtime moved since we cached it.

        Catches the case where `tnode-chat-sync` self-heals and rotates the
        nodeSecret on disk while we keep using the in-RAM copy from startup.
        Without this we'd 401-loop forever on pullLLMUsage until manual
        `systemctl restart tnode-telemetry` — same class of bug as
        `config_sync_stale_secret` (memoria) but on the telemetry daemon.
        Re-load is a single stat()+json.loads, fine to call before every
        OR refresh.
        """
        if not self._auth:
            return
        try:
            st = CHAT_SYNC_CONFIG.stat()
        except OSError:
            return
        cached_mtime = self._auth.get("_mtime", 0.0) or 0.0
        if st.st_mtime <= cached_mtime:
            return
        fresh = _load_node_auth()
        if not fresh:
            return
        if fresh["nodeSecret"] != self._auth["nodeSecret"]:
            logger.info(
                "chat-sync.json rotated (mtime moved %.0f → %.0f); "
                "reloading nodeSecret",
                cached_mtime, st.st_mtime,
            )
        self._auth = fresh

    async def _refresh_or_cache(self, announce: bool = False) -> None:
        if not self._auth:
            return
        self._maybe_reload_auth()
        fresh = await fetch_or_usage(self._auth)
        if not fresh:
            return
        self._or_cache = fresh
        logger.debug(
            "OR cache refreshed: usage=%.6f limit=%.6f remaining=%.6f",
            float(fresh.get("usage") or 0.0),
            float(fresh.get("limit") or 0.0),
            float(fresh.get("limitRemaining") or 0.0),
        )
        if announce and self._clients:
            event = build_usage_payload(
                self._accumulator, self._or_cache, snapshot=True,
            )
            await self._broadcast(event)

    async def _broadcast(self, event: Dict[str, Any]) -> None:
        if not self._clients:
            return
        encoded = json.dumps(event, separators=(",", ":"))
        stale: list["ClientSession"] = []
        for client in list(self._clients):
            try:
                await client.send_downstream(encoded)
            except ConnectionClosed:
                stale.append(client)
            except Exception as e:  # noqa: BLE001
                logger.warning("broadcast to client failed: %s", e)
                stale.append(client)
        for client in stale:
            self._clients.discard(client)

    async def handle_client(self, ws_client) -> None:
        session = ClientSession(self, ws_client)
        self._clients.add(session)
        if len(self._clients) > WARN_CONCURRENT_CLIENTS:
            logger.warning(
                "unusually high client count: %d (check for leaked connections)",
                len(self._clients),
            )
        try:
            await session.run()
        finally:
            self._clients.discard(session)

    def initial_snapshots(self) -> list[Dict[str, Any]]:
        """Every telemetry stream's last-known snapshot, shipped on connect
        so the client never sees an empty widget while waiting for the
        first tick. Skips streams that haven't produced data yet."""
        snaps: list[Dict[str, Any]] = []
        snaps.append(build_usage_payload(
            self._accumulator, self._or_cache, snapshot=True,
        ))
        if self._health_cache is not None:
            snaps.append(self._health_cache)
        # TODO Channels v1 → CHANNELS_PROTOCOL_v1.md §5
        # Always include the channels snapshot — even when state is
        # `unlinked` we want the client to render the empty card immediately
        # rather than fall back to defaults.
        # if self._channels_cache is not None:
        #     snaps.append(self._channels_cache)
        return snaps


# ── Mind RPC handlers ────────────────────────────────────────────────
#
# Intercepts `mind.list / mind.read / mind.write` RPCs from the downstream
# client and answers them locally instead of proxying to the OpenClaw
# kernel. The agent's editable .md files (SOUL, IDENTITY, MEMORY, …) live
# in the agent's workspace dir; we discover the right one at request time.

MIND_DIR_OVERRIDE = os.environ.get("TNODE_TELEMETRY_MIND_DIR")
_MIND_READ_ONLY_NAMES = {"HEARTBEAT.MD"}


class MindError(Exception):
    """Application-level mind RPC error. The `code` ends up in the
    `rpc-response.error.code` field so the client can branch on it
    (e.g. `hash-mismatch` triggers the 3-way conflict UI)."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _resolve_mind_dir() -> Optional[Path]:
    """Locate the directory holding the agent's `.md` files. Tries, in
    order: an explicit override, the OpenClaw workspace root (where the
    main agent's SOUL/IDENTITY/MEMORY/HEARTBEAT etc. actually live), the
    conventional `agents/main` paths, and finally the first
    `workspace/agents/*` subdir that contains at least one `.md`."""
    if MIND_DIR_OVERRIDE:
        p = Path(MIND_DIR_OVERRIDE)
        return p if p.is_dir() else None
    candidates = [
        OPENCLAW_HOME / "workspace",
        OPENCLAW_HOME / "agents" / "main",
        OPENCLAW_HOME / "workspace" / "agents" / "main",
    ]
    for c in candidates:
        if c.is_dir() and any(c.glob("*.md")):
            return c
    ws_agents = OPENCLAW_HOME / "workspace" / "agents"
    if ws_agents.is_dir():
        for child in sorted(ws_agents.iterdir()):
            if child.is_dir() and any(child.glob("*.md")):
                return child
    return None


def _safe_mind_path(name: str, mind_dir: Path) -> Optional[Path]:
    """Return mind_dir/name only if name is a safe `.md` basename. Rejects
    path separators, dotfiles, traversal segments, and files outside the
    resolved mind_dir."""
    if not name or "/" in name or "\\" in name or name.startswith("."):
        return None
    if ".." in name:
        return None
    if not name.lower().endswith(".md"):
        return None
    try:
        resolved_dir = mind_dir.resolve()
        p = (mind_dir / name).resolve()
        p.relative_to(resolved_dir)
    except (OSError, ValueError):
        return None
    return p


def _sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _is_mind_read_only(name: str) -> bool:
    return name.upper() in _MIND_READ_ONLY_NAMES


def _mind_file_meta(p: Path, content: str) -> Dict[str, Any]:
    st = p.stat()
    return {
        "name": p.name,
        "size": st.st_size,
        "modifiedAt": int(st.st_mtime * 1000),
        "hash": _sha256_text(content),
        "isReadOnly": _is_mind_read_only(p.name),
    }


def _mind_list(mind_dir: Path) -> Dict[str, Any]:
    files = []
    for p in sorted(mind_dir.glob("*.md")):
        if p.name.startswith("."):
            continue
        try:
            content = p.read_text(encoding="utf-8")
        except OSError as e:
            logger.warning("mind.list skipping %s: %s", p, e)
            continue
        files.append(_mind_file_meta(p, content))
    return {"files": files}


def _mind_read(mind_dir: Path, name: str) -> Dict[str, Any]:
    p = _safe_mind_path(name, mind_dir)
    if p is None or not p.is_file():
        raise MindError("not-found", f"File {name!r} not found")
    content = p.read_text(encoding="utf-8")
    out = _mind_file_meta(p, content)
    out["content"] = content
    return out


def _mind_write(
    mind_dir: Path,
    name: str,
    content: str,
    base_hash: Optional[str],
    note: Optional[str],
) -> Dict[str, Any]:
    p = _safe_mind_path(name, mind_dir)
    if p is None:
        raise MindError("invalid-name", f"Invalid file name {name!r}")
    if _is_mind_read_only(p.name):
        raise MindError("forbidden", f"{p.name} is read-only")
    if not p.is_file():
        raise MindError("not-found", f"File {name!r} not found")
    current = p.read_text(encoding="utf-8")
    current_hash = _sha256_text(current)
    if base_hash and base_hash != current_hash:
        raise MindError(
            "hash-mismatch",
            "File changed in the agent since the editor opened it",
        )
    # Atomic replace: write to .tmp, then rename. Avoids partial-write
    # corruption if the daemon is killed mid-save.
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(content, encoding="utf-8")
    os.replace(tmp, p)
    new_meta = _mind_file_meta(p, content)
    logger.info(
        "mind.write %s (%d bytes, note=%r)",
        p.name, new_meta["size"], note,
    )
    return {"ok": True, **new_meta}


def _dispatch_mind(method: str, params: Dict[str, Any]) -> Dict[str, Any]:
    mind_dir = _resolve_mind_dir()
    if mind_dir is None:
        raise MindError(
            "mind-dir-missing",
            "No mind directory found on this node",
        )
    if method == "mind.list":
        return _mind_list(mind_dir)
    if method == "mind.read":
        return _mind_read(mind_dir, str(params.get("name", "")))
    if method == "mind.write":
        return _mind_write(
            mind_dir,
            str(params.get("name", "")),
            str(params.get("content", "")),
            params.get("baseHash"),
            params.get("note"),
        )
    raise MindError("unknown-method", f"Unknown method {method!r}")


# ── agent.model.* RPC ─────────────────────────────────────────────────


class AgentError(Exception):
    """Application-level agent RPC error. The `code` ends up in the
    `rpc-response.error.code` field so the client can branch on it."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _load_openclaw_json() -> Dict[str, Any]:
    if not OPENCLAW_JSON.is_file():
        raise AgentError("openclaw-json-missing", f"missing {OPENCLAW_JSON}")
    try:
        return json.loads(OPENCLAW_JSON.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise AgentError("openclaw-json-read", str(e))


def _save_openclaw_json_atomic(config: Dict[str, Any]) -> None:
    tmp = OPENCLAW_JSON.with_suffix(".json.tmp")
    try:
        tmp.write_text(
            json.dumps(config, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        os.replace(tmp, OPENCLAW_JSON)
    except OSError as e:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise AgentError("openclaw-json-write", str(e))


def _find_agent(config: Dict[str, Any], agent_id: str) -> Optional[Dict[str, Any]]:
    """Returns the explicit `agents.list[]` entry for `agent_id`, or None if
    the agent isn't listed (the gateway then falls back to `defaults.models`).
    Distinguished from `agent-list-malformed`, which is a real config error."""
    lst = (config.get("agents") or {}).get("list")
    if lst is None:
        return None
    if not isinstance(lst, list):
        raise AgentError("agent-list-malformed", "agents.list is not an array")
    for a in lst:
        if isinstance(a, dict) and a.get("id") == agent_id:
            return a
    return None


def _default_model_from_config(config: Dict[str, Any]) -> Optional[str]:
    """First key of `agents.defaults.models` (dict form) or first item if
    list-of-strings. Returns None if the node doesn't define defaults."""
    dm = ((config.get("agents") or {}).get("defaults") or {}).get("models")
    if isinstance(dm, dict) and dm:
        return next(iter(dm.keys()))
    if isinstance(dm, list) and dm and isinstance(dm[0], str):
        return dm[0]
    return None


def _reload_gateway() -> bool:
    """Best-effort restart of openclaw-gateway. Tries `openclaw daemon
    restart` first (portable across home/VPS), falls back to systemctl.
    Returns True on success — RPC still succeeds if reload fails because
    config is already on disk and applies on next boot."""
    import subprocess
    candidates = [
        ["openclaw", "daemon", "restart"],
        ["systemctl", "--user", "restart", "openclaw-gateway"],
        ["sudo", "-n", "systemctl", "restart", "openclaw-gateway"],
    ]
    for cmd in candidates:
        try:
            result = subprocess.run(
                cmd, check=False, capture_output=True, text=True, timeout=15,
            )
            if result.returncode == 0:
                logger.info("gateway reload OK via %s", cmd[0])
                return True
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
    logger.warning("gateway reload failed — config will apply on next boot")
    return False


def _agent_model_get(agent_id: str) -> Dict[str, Any]:
    """Returns the effective model the gateway uses for `agent_id`. The
    `effective` field is what the UI should show as "active" — it falls
    back to `agents.defaults.models` when the agent has no explicit
    `model.primary`. `primary` is the explicit override (None if absent).
    `explicit` indicates whether the agent has its own list entry at all."""
    config = _load_openclaw_json()
    agent = _find_agent(config, agent_id)
    primary: Optional[str] = None
    fallbacks: List[str] = []
    explicit = False
    if agent is not None:
        explicit = True
        model = agent.get("model") or {}
        primary = model.get("primary") if isinstance(model.get("primary"), str) else None
        fb = model.get("fallbacks")
        if isinstance(fb, list):
            fallbacks = [s for s in fb if isinstance(s, str)]
    effective = primary or _default_model_from_config(config)
    return {
        "agentId": agent_id,
        "primary": primary,
        "effective": effective,
        "fallbacks": fallbacks,
        "explicit": explicit,
    }


def _agent_model_set(agent_id: str, model_slug: str) -> Dict[str, Any]:
    """Sets the per-agent primary model. If the node has no `agents.list[]`
    entry for `agent_id`, one is created (`{id, default, model: {primary}}`),
    so this works on freshly-provisioned nodes that only have
    `defaults.models`. Atomic file write + best-effort gateway reload.

    Critically also adds `model_slug` to `agents.defaults.models` (the plural
    dict). OpenClaw v2026.4.x builds the agent's allowlist from that key —
    if the slug isn't there, the resolver silently falls back to the
    pre-existing default and the user's selection is ignored at runtime.
    Merges (doesn't replace) so multiple agents can keep distinct models."""
    if not isinstance(model_slug, str) or "/" not in model_slug:
        raise AgentError(
            "invalid-model-slug",
            f"model must be 'provider/model', got {model_slug!r}",
        )
    config = _load_openclaw_json()
    agents = config.setdefault("agents", {})
    if not isinstance(agents, dict):
        raise AgentError("agents-malformed", "agents is not an object")
    lst = agents.setdefault("list", [])
    if not isinstance(lst, list):
        raise AgentError("agent-list-malformed", "agents.list is not an array")
    agent: Optional[Dict[str, Any]] = None
    for a in lst:
        if isinstance(a, dict) and a.get("id") == agent_id:
            agent = a
            break
    created = False
    if agent is None:
        agent = {"id": agent_id, "default": agent_id == "main"}
        lst.append(agent)
        created = True
    if not isinstance(agent.get("model"), dict):
        agent["model"] = {}
    agent["model"]["primary"] = model_slug
    defaults = agents.setdefault("defaults", {})
    if not isinstance(defaults, dict):
        raise AgentError("defaults-malformed", "agents.defaults is not an object")
    defaults_models = defaults.setdefault("models", {})
    if not isinstance(defaults_models, dict):
        raise AgentError(
            "defaults-models-malformed",
            "agents.defaults.models is not an object",
        )
    if model_slug not in defaults_models:
        defaults_models[model_slug] = {}
    # v1.8.15: also upsert the slug under providers[p].models[] so the
    # gateway accepts delegate calls immediately. Earlier versions only
    # touched defaults.models; the provider catalog stayed stale until
    # the next apply_openrouter_key, which is the wrong primitive to
    # rely on (and replaces the catalog wholesale pre-config-sync 1.3.0).
    # Idempotent and skips silently when the inferred provider isn't
    # configured yet (e.g. a freshly-paired node before key apply).
    _provider_prefixes = ("openrouter", "groq", "ollama", "lmstudio", "llama-cpp")
    parts = model_slug.split("/", 1)
    if len(parts) == 2 and parts[0] in _provider_prefixes:
        _provider, _catalog_id = parts
        _p_block = (
            (config.get("models") or {}).get("providers", {}).get(_provider)
        )
        if isinstance(_p_block, dict):
            _models_list = _p_block.setdefault("models", [])
            if isinstance(_models_list, list) and not any(
                isinstance(m, dict) and m.get("id") == _catalog_id
                for m in _models_list
            ):
                _models_list.append({
                    "id": _catalog_id,
                    "name": _catalog_id,
                    "contextWindow": 200000 if _provider == "openrouter" else 32768,
                    "maxTokens": 4096,
                })
    _save_openclaw_json_atomic(config)
    reload_ok = _reload_gateway()
    logger.info(
        "agent.model.set %s → %s (created=%s reload=%s)",
        agent_id, model_slug, created, reload_ok,
    )
    return {
        "agentId": agent_id,
        "primary": model_slug,
        "effective": model_slug,
        "fallbacks": list(agent["model"].get("fallbacks") or []),
        "explicit": True,
        "created": created,
        "gatewayReloaded": reload_ok,
    }


def _dispatch_agent(method: str, params: Dict[str, Any]) -> Dict[str, Any]:
    agent_id = str(params.get("agentId") or "main")
    if method == "agent.model.get":
        return _agent_model_get(agent_id)
    if method == "agent.model.set":
        return _agent_model_set(agent_id, str(params.get("model", "")))
    raise AgentError("unknown-method", f"unknown method {method!r}")


class ClientSession:
    """A single downstream client (app WebSocket) paired with an upstream
    connection to the openclaw-gateway. Proxies frames transparently and
    interleaves telemetry events on the downstream side."""

    def __init__(self, proxy: TelemetryProxy, ws_client) -> None:
        self._proxy = proxy
        self._client = ws_client
        self._upstream = None
        self._upstream_lock = asyncio.Lock()
        self._remote_addr = getattr(ws_client, "remote_address", None)

    async def send_downstream(self, message: str) -> None:
        await self._client.send(message)

    async def run(self) -> None:
        logger.info("client connected: remote=%s", self._remote_addr)
        try:
            self._upstream = await websockets.connect(
                UPSTREAM_URI,
                ping_interval=20,
                ping_timeout=20,
                max_size=None,
            )
        except (OSError, WebSocketException) as e:
            logger.error("failed to open upstream: %s", e)
            try:
                await self._client.close(code=1011, reason="upstream unavailable")
            except Exception:  # noqa: BLE001
                pass
            return
        try:
            # Fire-and-forget snapshots — ship them before the first
            # upstream frame so every widget has data to render.
            try:
                for snap in self._proxy.initial_snapshots():
                    await self._client.send(
                        json.dumps(snap, separators=(",", ":"))
                    )
            except Exception as e:  # noqa: BLE001
                logger.warning("failed to send snapshot: %s", e)
            down = asyncio.create_task(self._forward(self._client, self._upstream, "c→u"))
            up = asyncio.create_task(self._forward(self._upstream, self._client, "u→c"))
            done, pending = await asyncio.wait(
                {down, up}, return_when=asyncio.FIRST_COMPLETED
            )
            for t in pending:
                t.cancel()
            for t in done:
                exc = t.exception()
                if exc and not isinstance(exc, ConnectionClosed):
                    logger.warning("proxy task errored: %s", exc)
        finally:
            try:
                await self._upstream.close()
            except Exception:  # noqa: BLE001
                pass
            logger.info("client disconnected: remote=%s", self._remote_addr)

    async def _forward(self, src, dst, direction: str) -> None:
        try:
            async for message in src:
                if direction == "c→u":
                    if await self._maybe_handle_mind_rpc(message):
                        continue
                    if await self._maybe_handle_agent_rpc(message):
                        continue
                # TODO Channels v1 → CHANNELS_PROTOCOL_v1.md §3
                # Only on the upstream direction (c→u) inspect for
                # `{"type":"rpc","method":"channels.*"}`. If matched, dispatch
                # to self._proxy.handle_channels_rpc(method, params) and
                # send back the rpc-response/rpc-error to self._client
                # WITHOUT forwarding the message to the gateway. Any other
                # message (or u→c direction) keeps the current passthrough.
                # Keep the parse cheap and tolerant — non-JSON or non-rpc
                # frames must fall through unchanged.
                await dst.send(message)
        except ConnectionClosed:
            pass

    async def _maybe_handle_mind_rpc(self, message: Any) -> bool:
        """If `message` is a `mind.*` RPC, answer it locally and return True
        so the caller skips the upstream forward. Anything else returns
        False and is proxied as before."""
        if not isinstance(message, str):
            return False
        try:
            frame = json.loads(message)
        except (ValueError, TypeError):
            return False
        if not isinstance(frame, dict):
            return False
        if frame.get("type") != "req":
            return False
        method = frame.get("method")
        if not isinstance(method, str) or not method.startswith("mind."):
            return False
        req_id = frame.get("id", "")
        raw_params = frame.get("params") or {}
        params = raw_params if isinstance(raw_params, dict) else {}
        try:
            payload = _dispatch_mind(method, params)
            response = {
                "type": "res",
                "id": req_id,
                "ok": True,
                "payload": payload,
            }
        except MindError as e:
            response = {
                "type": "res",
                "id": req_id,
                "ok": False,
                "error": {"code": e.code, "message": e.message},
            }
        except Exception as e:  # noqa: BLE001
            logger.exception("mind rpc %s failed", method)
            response = {
                "type": "res",
                "id": req_id,
                "ok": False,
                "error": {"code": "internal", "message": str(e)},
            }
        try:
            await self.send_downstream(
                json.dumps(response, separators=(",", ":"))
            )
        except ConnectionClosed:
            pass
        return True

    async def _maybe_handle_agent_rpc(self, message: Any) -> bool:
        """If `message` is an `agent.*` RPC, answer it locally and return
        True so the caller skips the upstream forward. Otherwise False
        and the message is proxied as before."""
        if not isinstance(message, str):
            return False
        try:
            frame = json.loads(message)
        except (ValueError, TypeError):
            return False
        if not isinstance(frame, dict):
            return False
        if frame.get("type") != "req":
            return False
        method = frame.get("method")
        if not isinstance(method, str) or not method.startswith("agent."):
            return False
        req_id = frame.get("id", "")
        raw_params = frame.get("params") or {}
        params = raw_params if isinstance(raw_params, dict) else {}
        try:
            payload = _dispatch_agent(method, params)
            response = {
                "type": "res",
                "id": req_id,
                "ok": True,
                "payload": payload,
            }
        except AgentError as e:
            response = {
                "type": "res",
                "id": req_id,
                "ok": False,
                "error": {"code": e.code, "message": e.message},
            }
        except Exception as e:  # noqa: BLE001
            logger.exception("agent rpc %s failed", method)
            response = {
                "type": "res",
                "id": req_id,
                "ok": False,
                "error": {"code": "internal", "message": str(e)},
            }
        try:
            await self.send_downstream(
                json.dumps(response, separators=(",", ":"))
            )
        except ConnectionClosed:
            pass
        return True


# ── Entrypoint ────────────────────────────────────────────────────────

async def _serve(proxy: TelemetryProxy) -> None:
    await proxy.start_background()

    async def _handler(ws):
        await proxy.handle_client(ws)

    stop = asyncio.get_running_loop().create_future()

    def _request_shutdown(*_: Any) -> None:
        if not stop.done():
            stop.set_result(None)

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            asyncio.get_running_loop().add_signal_handler(sig, _request_shutdown)
        except NotImplementedError:
            # Windows/some containers — fall back to default handlers.
            pass

    async with websockets.serve(
        _handler,
        LISTEN_HOST,
        LISTEN_PORT,
        ping_interval=20,
        ping_timeout=20,
        max_size=None,
    ):
        await stop
        await proxy.stop_background()


def main() -> None:
    parser = argparse.ArgumentParser(description="tnode-telemetry daemon")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()
    _setup_logging(args.verbose)
    try:
        asyncio.run(_serve(TelemetryProxy()))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
TELEMETRYPYEOF
}

# ═════════════════════════════════════════════
# PHASE 6: Validation + QR
# ═════════════════════════════════════════════
phase_summary() {
    phase "7/7" "Todo listo"

    echo ""
    echo -e "    ${BOLD}┌──────────────┬──────────────────────────┐${NC}"

    # OpenClaw
    local oc_status="no instalado"
    if command_exists openclaw && openclaw --version >/dev/null 2>&1; then
        oc_status="$(openclaw --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "instalado")"
    fi
    printf "    ${BOLD}│${NC} %-12s ${BOLD}│${NC} %-24s ${BOLD}│${NC}\n" "TNode Kernel" "$oc_status"

    # LLM provider
    local llm_label="Ollama"
    local llm_status="no instalado"
    if [[ "$USE_API" == "1" ]]; then
        llm_label="LLM API"
        llm_status="$API_PROVIDER ($MODEL)"
    elif command_exists ollama; then
        local ol_ver
        ol_ver="$(ollama --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "?")"
        llm_status="v${ol_ver} ($MODEL)"
    fi
    if [[ "$USE_API" == "0" ]] && [[ "$NO_OLLAMA" == "1" ]]; then llm_status="saltado"; fi
    printf "    ${BOLD}│${NC} %-12s ${BOLD}│${NC} %-24s ${BOLD}│${NC}\n" "$llm_label" "$llm_status"

    # Cloudflare Tunnel
    local tunnel_status="no instalado"
    if [[ -n "$TUNNEL_DOMAIN" ]]; then
        tunnel_status="$TUNNEL_DOMAIN"
    elif [[ "$NO_TUNNEL" == "1" ]]; then
        tunnel_status="saltado"
    fi
    printf "    ${BOLD}│${NC} %-12s ${BOLD}│${NC} %-24s ${BOLD}│${NC}\n" "Tunnel" "$tunnel_status"

    # Tailscale
    local ts_status="no instalado"
    local ts_bin=""
    [[ -x "/usr/local/bin/tailscale" ]] && ts_bin="/usr/local/bin/tailscale"
    [[ -z "$ts_bin" ]] && [[ -x "/usr/bin/tailscale" ]] && ts_bin="/usr/bin/tailscale"
    [[ -z "$ts_bin" ]] && command_exists tailscale && ts_bin="$(command -v tailscale)"
    if [[ -n "$ts_bin" ]]; then
        local ts_ip
        ts_ip="$("$ts_bin" ip -4 2>/dev/null || true)"
        if [[ -n "$ts_ip" ]]; then
            ts_status="$ts_ip"
        else
            ts_status="desconectado"
        fi
    fi
    if [[ "$WITH_TAILSCALE" != "1" ]]; then ts_status="saltado"; fi
    printf "    ${BOLD}│${NC} %-12s ${BOLD}│${NC} %-24s ${BOLD}│${NC}\n" "Tailscale" "$ts_status"

    # pair-watch
    local pw_status="no instalado"
    if [[ -f "$OPENCLAW_HOME/pair-watch.json" ]]; then
        local pw_mode
        pw_mode="$(python3 -c "import json; print(json.load(open('$OPENCLAW_HOME/pair-watch.json')).get('mode','?'))" 2>/dev/null || echo "?")"
        pw_status="activo ($pw_mode)"
    fi
    printf "    ${BOLD}│${NC} %-12s ${BOLD}│${NC} %-24s ${BOLD}│${NC}\n" "pair-watch" "$pw_status"

    echo -e "    ${BOLD}└──────────────┴──────────────────────────┘${NC}"

    # QR code
    if [[ "$NO_QR" == "1" ]]; then
        echo ""
        return 0
    fi

    # Auto-pair mode: the app already knows about this node (the
    # provisionTNode CF wrote users/{uid}/nodes/{nodeId} before the droplet
    # booted). Skip the QR ritual — pairing is already done.
    if [[ "${TNODE_AUTO_PAIR:-}" == "1" ]]; then
        echo ""
        info "auto-pair mode: pairing ya establecido por provisionTNode — no se genera QR"
        report_progress_heartbeat "pairing_ready"
        return 0
    fi

    echo ""
    if [[ -x "$TNODE_BIN/tnode-qr" ]]; then
        # Check if we have any connectivity method (tunnel or tailscale)
        local can_qr=0
        if [[ -n "$TUNNEL_DOMAIN" ]]; then
            can_qr=1
        elif [[ -n "${ts_bin:-}" ]]; then
            local ts_ip_check=""
            ts_ip_check="$("$ts_bin" ip -4 2>/dev/null || true)"
            [[ -n "$ts_ip_check" ]] && can_qr=1
        fi

        if [[ "$can_qr" == "1" ]] && command_exists openclaw; then
            # Wait for gateway to be ready (may still be starting)
            local gw_ready=0
            for i in 1 2 3 4 5 6 7 8 9 10; do
                if curl -sf http://localhost:18789/ >/dev/null 2>&1; then
                    gw_ready=1
                    break
                fi
                sleep 3
            done
            if [[ "$gw_ready" == "0" ]]; then
                warn "Gateway no responde en :18789 — ejecuta 'tnode-qr' manualmente cuando esté listo"
                return 0
            fi
            info "Generando setup code de pairing..."
            echo ""
            run_as_tnode "$TNODE_BIN/tnode-qr" 2>/dev/null || info "No se pudo generar QR — ejecuta 'su - $TNODE_USER -c tnode-qr' manualmente"
            echo ""
            echo -e "    ${GREEN}Escanea este QR o pega el setup code en la app TNode${NC}"
            echo -e "    ${GREEN}para vincular este nodo.${NC}"
        else
            if [[ -z "$TUNNEL_DOMAIN" ]]; then
                info "Sin tunnel ni Tailscale — ejecuta 'tnode-qr' cuando configures conectividad"
            fi
            info "Ejecuta 'tnode-qr' para generar el QR de pairing"
        fi
    fi

    echo ""
    echo -e "    ${MUTED}Descarga TNode: https://tbrain.app/download${NC}"
    echo ""

    # Show tnode user info on Linux
    if [[ "$OS" != "Darwin" ]] && [[ "$(id -u)" == "0" ]]; then
        echo -e "    ${BOLD}Acceso al usuario tnode:${NC}"
        echo -e "    ${MUTED}  su - $TNODE_USER                        # Cambiar a usuario tnode${NC}"
        echo ""
    fi

    echo -e "    ${BOLD}Comandos útiles (como $TNODE_USER):${NC}"
    echo -e "    ${MUTED}  tnode-qr                              # Generar QR/setup code${NC}"
    echo -e "    ${MUTED}  ~/.openclaw/scripts/pair-watch status  # Estado pair-watch${NC}"
    echo -e "    ${MUTED}  openclaw gateway status                # Estado gateway${NC}"
    echo -e "    ${MUTED}  openclaw daemon restart                # Reiniciar gateway${NC}"
    if [[ "$USE_API" == "0" ]] && [[ "$NO_OLLAMA" == "0" ]]; then
        echo -e "    ${MUTED}  ollama list                            # Modelos instalados${NC}"
    fi
    echo ""
}

# ═════════════════════════════════════════════
# EMBEDDED FILES
# ═════════════════════════════════════════════

write_pair_watch_py() {
    local dest="$1"
    cat > "$dest" << 'PAIR_WATCH_PY_EOF'
#!/usr/bin/env python3
"""
pair_watch.py — Auto-approve OpenClaw device pairing requests.

Triggered by launchd via WatchPaths on ~/.openclaw/devices/pending.json.
Reads ~/.openclaw/pair-watch.json for mode and trustedNetworks config.

Modes:
  - auto             → approve every pending request
  - manual           → noop (pure logger; humans approve via CLI)
  - trusted-network  → approve only requests whose remoteIp matches a trusted CIDR
                       (empty trustedNetworks list → fail-open, behaves as auto)

Stdlib only (Python 3.9+).
"""
__VERSION__ = "1.0.0"

import fcntl
import ipaddress
import json
import os
import subprocess
import sys
import time
from pathlib import Path

# ─────────────────────────────────────────────
# Paths (overridable by env for tests)
# ─────────────────────────────────────────────
HOME = Path(os.environ.get("PAIR_WATCH_HOME", os.path.expanduser("~")))
OPENCLAW_DIR = Path(os.environ.get("OPENCLAW_DIR", HOME / ".openclaw"))
CONFIG_PATH = Path(os.environ.get("PAIR_WATCH_CONFIG", OPENCLAW_DIR / "pair-watch.json"))
PENDING_PATH = OPENCLAW_DIR / "devices" / "pending.json"
SEEN_PATH = OPENCLAW_DIR / "devices" / ".pair-watch-seen"
LOCK_PATH = OPENCLAW_DIR / "devices" / ".pair-watch.lock"
LOG_PATH = OPENCLAW_DIR / "logs" / "pair-watch.log"

# Default openclaw binary location on macOS (homebrew). install.sh substitutes
# this if a different path is detected at install time.
OPENCLAW_BIN = os.environ.get("OPENCLAW_BIN", "/opt/homebrew/bin/openclaw")

DEFAULT_CONFIG = {
    "mode": "auto",
    "trustedNetworks": [
        "127.0.0.0/8",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "100.64.0.0/10",
    ],
    "approveTimeoutMs": 15000,
    "logLevel": "info",
}

LEVELS = {"debug": 10, "info": 20, "warn": 30, "error": 40}
_log_level_threshold = LEVELS["info"]


# ─────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────
def log(level: str, msg: str) -> None:
    if LEVELS.get(level, 20) < _log_level_threshold:
        return
    ts = time.strftime("%Y-%m-%dT%H:%M:%S")
    line = f"{ts} [{level.upper()}] {msg}"
    print(line, flush=True)
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG_PATH, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass  # logging must never crash the watcher


# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
def load_config() -> dict:
    global _log_level_threshold
    if not CONFIG_PATH.exists():
        log("warn", f"config not found at {CONFIG_PATH}, using defaults")
        cfg = dict(DEFAULT_CONFIG)
    else:
        try:
            with open(CONFIG_PATH) as f:
                user = json.load(f)
            cfg = {**DEFAULT_CONFIG, **user}
        except Exception as e:
            log("error", f"failed to read config: {e}, using defaults")
            cfg = dict(DEFAULT_CONFIG)

    _log_level_threshold = LEVELS.get(cfg.get("logLevel", "info"), 20)
    return cfg


# ─────────────────────────────────────────────
# Pending / seen state
# ─────────────────────────────────────────────
def load_pending() -> dict:
    if not PENDING_PATH.exists():
        return {}
    try:
        with open(PENDING_PATH) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception as e:
        log("error", f"failed to read pending.json: {e}")
        return {}


def load_seen() -> set:
    if not SEEN_PATH.exists():
        return set()
    try:
        with open(SEEN_PATH) as f:
            return {line.strip() for line in f if line.strip()}
    except Exception:
        return set()


def save_seen(seen: set) -> None:
    try:
        SEEN_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(SEEN_PATH, "w") as f:
            for item in sorted(seen):
                f.write(item + "\n")
    except Exception as e:
        log("error", f"failed to save seen: {e}")


# ─────────────────────────────────────────────
# Decision logic
# ─────────────────────────────────────────────
def ip_in_cidrs(ip_str: str, cidrs: list) -> bool:
    try:
        ip = ipaddress.ip_address(ip_str)
    except (ValueError, TypeError):
        return False
    for cidr in cidrs:
        try:
            if ip in ipaddress.ip_network(cidr, strict=False):
                return True
        except ValueError:
            log("warn", f"invalid CIDR in config: {cidr}")
    return False


def decide(req: dict, cfg: dict) -> str:
    """Returns 'approve', 'wait', or 'skip'."""
    mode = cfg.get("mode", "auto")

    if mode == "manual":
        return "wait"

    if mode == "auto":
        return "approve"

    if mode == "trusted-network":
        cidrs = cfg.get("trustedNetworks", [])
        if not cidrs:
            log("debug", "trusted-network with empty list → fail-open")
            return "approve"
        ip = req.get("remoteIp")
        if not ip:
            log("warn", "no remoteIp in request, waiting for human")
            return "wait"
        if ip_in_cidrs(ip, cidrs):
            return "approve"
        log("info", f"remoteIp {ip} not in trusted networks, waiting for human")
        return "wait"

    log("error", f"unknown mode: {mode}")
    return "wait"


# ─────────────────────────────────────────────
# Approve action
# ─────────────────────────────────────────────
def run_approve(request_id: str, cfg: dict) -> bool:
    timeout = cfg.get("approveTimeoutMs", 15000) / 1000.0
    try:
        result = subprocess.run(
            [OPENCLAW_BIN, "devices", "approve", request_id],
            capture_output=True,
            text=True,
            timeout=timeout,
            env={
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                "HOME": str(HOME),
            },
        )
    except FileNotFoundError:
        log("error", f"openclaw binary not found at {OPENCLAW_BIN}")
        return False
    except subprocess.TimeoutExpired:
        log("error", f"approve timed out after {timeout}s")
        return False

    if result.returncode != 0:
        log("error", f"approve failed (rc={result.returncode}): {result.stderr.strip()}")
        return False

    if result.stdout.strip():
        log("debug", f"approve stdout: {result.stdout.strip()}")
    return True


# ─────────────────────────────────────────────
# Main loop
# ─────────────────────────────────────────────
def main() -> int:
    cfg = load_config()
    log("debug", f"mode={cfg.get('mode')}, trustedNetworks={cfg.get('trustedNetworks')}")

    # Mutual exclusion: launchd may fire bursts on file change. Use flock so
    # only one instance processes pending at a time.
    LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    lock_fd = open(LOCK_PATH, "w")
    try:
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("debug", "another instance is running, exiting")
        return 0

    try:
        pending = load_pending()
        if not pending:
            log("debug", "no pending requests")
            return 0

        seen = load_seen()
        log("info", f"{len(pending)} pending request(s) found")

        for request_id, req in pending.items():
            if request_id in seen:
                log("debug", f"already processed {request_id[:8]}, skipping")
                continue

            remote_ip = req.get("remoteIp", "?")
            display = req.get("displayName", "?")
            decision = decide(req, cfg)
            log(
                "info",
                f"request {request_id[:8]} ({display}, ip={remote_ip}) → {decision}",
            )

            if decision == "approve":
                ok = run_approve(request_id, cfg)
                if ok:
                    log("info", f"✓ approved {request_id[:8]}")
                    seen.add(request_id)
                else:
                    log("error", f"✗ approve failed for {request_id[:8]}")
            elif decision == "skip":
                seen.add(request_id)
            # decision == "wait" → leave it; humans will approve via CLI

        save_seen(seen)
        return 0
    finally:
        try:
            fcntl.flock(lock_fd.fileno(), fcntl.LOCK_UN)
            lock_fd.close()
        except Exception:
            pass


if __name__ == "__main__":
    sys.exit(main())
PAIR_WATCH_PY_EOF
}

write_pair_watch_cli() {
    local dest="$1"
    cat > "$dest" << 'PAIR_WATCH_CLI_EOF'
#!/usr/bin/env bash
# pair-watch — CLI wrapper for pair-watch config management.
#
# Usage:
#   pair-watch mode <auto|manual|trusted-network>
#   pair-watch trusted list
#   pair-watch trusted add <cidr>
#   pair-watch trusted remove <cidr>
#   pair-watch status
#   pair-watch test
#   pair-watch logs [N]
set -euo pipefail

CONFIG="$HOME/.openclaw/pair-watch.json"
SCRIPT="$HOME/.openclaw/scripts/pair_watch.py"
LOG="$HOME/.openclaw/logs/pair-watch.log"

ensure_config() {
    if [ ! -f "$CONFIG" ]; then
        echo "error: config not found at $CONFIG" >&2
        echo "       run tnode-setup first" >&2
        exit 1
    fi
}

cmd_mode() {
    ensure_config
    local new_mode="$1"
    case "$new_mode" in
        auto|manual|trusted-network) ;;
        *)
            echo "error: invalid mode '$new_mode'" >&2
            echo "       valid: auto | manual | trusted-network" >&2
            exit 1
            ;;
    esac
    python3 - "$CONFIG" "$new_mode" <<'PYEOF'
import json, sys
path, mode = sys.argv[1], sys.argv[2]
with open(path) as f: c = json.load(f)
old = c.get("mode", "auto")
c["mode"] = mode
with open(path, "w") as f: json.dump(c, f, indent=2)
print(f"mode: {old} → {mode}")
PYEOF
}

cmd_trusted() {
    ensure_config
    local action="${1:-list}"
    case "$action" in
        list)
            python3 - "$CONFIG" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: c = json.load(f)
nets = c.get("trustedNetworks", [])
if not nets:
    print("(empty — fail-open)")
else:
    for n in nets: print(n)
PYEOF
            ;;
        add)
            local cidr="${2:?usage: pair-watch trusted add <cidr>}"
            python3 - "$CONFIG" "$cidr" <<'PYEOF'
import json, sys, ipaddress
path, cidr = sys.argv[1], sys.argv[2]
ipaddress.ip_network(cidr, strict=False)  # validate
with open(path) as f: c = json.load(f)
nets = c.setdefault("trustedNetworks", [])
if cidr in nets:
    print(f"already present: {cidr}")
else:
    nets.append(cidr)
    with open(path, "w") as f: json.dump(c, f, indent=2)
    print(f"added: {cidr}")
PYEOF
            ;;
        remove)
            local cidr="${2:?usage: pair-watch trusted remove <cidr>}"
            python3 - "$CONFIG" "$cidr" <<'PYEOF'
import json, sys
path, cidr = sys.argv[1], sys.argv[2]
with open(path) as f: c = json.load(f)
nets = c.get("trustedNetworks", [])
if cidr not in nets:
    print(f"not found: {cidr}")
    sys.exit(1)
nets.remove(cidr)
with open(path, "w") as f: json.dump(c, f, indent=2)
print(f"removed: {cidr}")
PYEOF
            ;;
        *)
            echo "usage: pair-watch trusted <list|add|remove> [cidr]" >&2
            exit 1
            ;;
    esac
}

cmd_status() {
    ensure_config
    echo "── pair-watch config ($CONFIG) ──"
    cat "$CONFIG"
    echo ""
    case "$(uname -s)" in
        Darwin)
            echo "── LaunchAgent status (macOS) ──"
            if launchctl list com.tbrain.pair-watch >/dev/null 2>&1; then
                launchctl list com.tbrain.pair-watch | head -10
            else
                echo "(not loaded)"
            fi
            ;;
        Linux)
            echo "── systemd path unit status (Linux) ──"
            if command -v systemctl >/dev/null 2>&1; then
                if [[ "$(id -u)" == "0" ]]; then
                    systemctl status pair-watch.path --no-pager 2>&1 | head -6 || true
                else
                    systemctl --user status pair-watch.path --no-pager 2>&1 | head -6 || true
                fi
            else
                echo "(systemctl not available)"
            fi
            ;;
        *)
            echo "── watcher status ──"
            echo "(platform $(uname -s) not supported)"
            ;;
    esac
    echo ""
    echo "── recent log ──"
    if [ -f "$LOG" ]; then
        tail -10 "$LOG"
    else
        echo "(no log yet at $LOG)"
    fi
}

cmd_test() {
    if [ ! -f "$SCRIPT" ]; then
        echo "error: script not found at $SCRIPT" >&2
        exit 1
    fi
    echo "── running pair_watch.py manually ──"
    python3 "$SCRIPT"
}

cmd_logs() {
    local n="${1:-50}"
    if [ ! -f "$LOG" ]; then
        echo "(no log at $LOG)"
        exit 0
    fi
    tail -"$n" "$LOG"
}

usage() {
    cat <<EOF
pair-watch — auto-approve OpenClaw device pairing

Usage:
  pair-watch mode <auto|manual|trusted-network>
  pair-watch trusted list
  pair-watch trusted add <cidr>
  pair-watch trusted remove <cidr>
  pair-watch status
  pair-watch test
  pair-watch logs [N]
EOF
}

case "${1:-}" in
    mode)    shift; cmd_mode "${1:?usage: pair-watch mode <auto|manual|trusted-network>}" ;;
    trusted) shift; cmd_trusted "$@" ;;
    status)  cmd_status ;;
    test)    cmd_test ;;
    logs)    shift; cmd_logs "$@" ;;
    -h|--help|help|"") usage ;;
    *) echo "unknown command: $1" >&2; usage; exit 1 ;;
esac
PAIR_WATCH_CLI_EOF
}

# ═════════════════════════════════════════════
# Fase 2 (components-manifest) — verify scripts + manifest writer
# ═════════════════════════════════════════════
# Default canónico: `install.tbrain.app/verify/*` (CF Page Rule preservando
# path → raw GitHub). Aprovecha CF edge cache (escala a 5000 nodos sin
# rate-limit de GitHub raw) y desacopla del provider del repo público.
# Default goes straight to raw GitHub because the install.tbrain.app/* path
# on the Free CF plan is served by a Bulk Redirect that does NOT preserve $1
# (Page Rule budget consumed by update/health/updates.tbrain.app). Override
# with VERIFY_BASE_URL=... if a path-preserving CDN is set up later (Pro
# plan + Page Rule for install.tbrain.app/verify/*).
VERIFY_BASE_URL="${VERIFY_BASE_URL:-https://raw.githubusercontent.com/cmoralestbrain/tnode_server_public/main/verify}"

install_verify_scripts() {
    info "Instalando verify scripts a \$OPENCLAW_HOME/verify/..."
    local verify_dir="$OPENCLAW_HOME/verify"
    run_as_tnode mkdir -p "$verify_dir"
    local files=(
        verify_common.py
        verify_tnode-chat-sync.py
        verify_tnode-config-sync.py
        verify_tnode-telemetry.py
        verify_pair-watch.py
        verify_openclaw-gateway.py
        verify_cloudflared.py
        verify_plugin-npm.py
        verify_plugin-skill.py
        verify_tnode-llm-config-watcher.py
    )
    local ok=0 fail=0
    for f in "${files[@]}"; do
        local url="${VERIFY_BASE_URL}/$f"
        local dest="$verify_dir/$f"
        local tmp; tmp="$(mktemp)"
        if curl -fsSL --max-time 10 "$url" -o "$tmp" 2>/dev/null; then
            mv "$tmp" "$dest"
            chmod +x "$dest"
            chown "$TNODE_USER":"$TNODE_USER" "$dest" 2>/dev/null || true
            ok=$((ok+1))
        else
            rm -f "$tmp"
            fail=$((fail+1))
        fi
    done
    if [[ $fail -eq 0 ]]; then
        success "verify scripts ($ok/${#files[@]}) instalados en $verify_dir"
    else
        warn "verify scripts: $ok/${#files[@]} instalados; $fail fallaron (verifica $VERIFY_BASE_URL/*)"
    fi
}

write_components_manifest() {
    info "Generando components-manifest.json (auto-discovery + extracted versions)..."
    local manifest="$OPENCLAW_HOME/components-manifest.json"
    run_as_tnode python3 - "$manifest" "$OPENCLAW_HOME" <<'COMPMANIFEST_PYEOF'
import json, sys, subprocess
from datetime import datetime, timezone
from pathlib import Path

manifest_path = Path(sys.argv[1])
openclaw_home = Path(sys.argv[2])
scripts_dir = openclaw_home / "scripts"

def extract_ver(p):
    if not p.exists(): return None
    try:
        for line in p.read_text().splitlines()[:60]:
            if line.startswith('__VERSION__ = "'):
                return line.split('"')[1]
    except Exception:
        pass
    return None

def npm_ver(pkg):
    try:
        out = subprocess.check_output(["npm", "ls", "-g", "--json", "--depth=0", pkg],
                                      timeout=15, stderr=subprocess.DEVNULL).decode()
        return json.loads(out).get("dependencies", {}).get(pkg, {}).get("version")
    except Exception:
        return None

components = []

for comp_id, fname in [
    ("tnode-chat-sync",   "tnode_chat_sync.py"),
    ("tnode-config-sync", "tnode_config_sync.py"),
    ("tnode-telemetry",   "tnode_telemetry.py"),
    ("pair-watch",        "pair_watch.py"),
]:
    components.append({
        "id": comp_id, "kind": "daemon-embedded",
        "version": extract_ver(scripts_dir / fname) or "unknown",
        "source": f"scripts/{fname}",
    })

for comp_id, npm_name in [
    ("openclaw-gateway", "@openclaw/gateway"),
    ("openclaw-cli",     "@openclaw/cli"),
]:
    components.append({
        "id": comp_id, "kind": "binary-npm",
        "version": npm_ver(npm_name) or "unknown",
        "source": npm_name,
    })

for comp_id in ["cloudflared", "qrencode"]:
    components.append({
        "id": comp_id, "kind": "binary-os",
        "version": "system", "source": "system-package",
        "driftAllowed": True,
    })

skills_dir = openclaw_home / "skills"
if skills_dir.is_dir():
    for d in sorted(skills_dir.iterdir()):
        mf = d / "manifest.json"
        if not mf.is_file(): continue
        try:
            m = json.loads(mf.read_text())
            components.append({
                "id": m.get("name", d.name),
                "kind": "plugin-skill",
                "version": m.get("version", "unknown"),
                "source": f"skills/{d.name}/",
                "entrypoint": m.get("entrypoint"),
            })
        except Exception as e:
            print(f"WARN: skipping {mf}: {e}", file=sys.stderr)

ext_dir = openclaw_home / "extensions"
if ext_dir.is_dir():
    for d in sorted(ext_dir.iterdir()):
        pkg = d / "package.json"
        if not pkg.is_file(): continue
        try:
            m = json.loads(pkg.read_text())
            components.append({
                "id": m.get("name", d.name),
                "kind": "plugin-extension",
                "version": m.get("version", "unknown"),
                "source": f"extensions/{d.name}/",
            })
        except Exception as e:
            print(f"WARN: skipping {pkg}: {e}", file=sys.stderr)

manifest_path.write_text(json.dumps({
    "schemaVersion": 1,
    "generatedAt":   datetime.now(timezone.utc).isoformat(),
    "components":    components,
}, indent=2) + "\n")
print(f"OK: wrote {len(components)} components → {manifest_path}")
COMPMANIFEST_PYEOF
    chown "$TNODE_USER":"$TNODE_USER" "$OPENCLAW_HOME/components-manifest.json" 2>/dev/null || true
    success "components-manifest.json generado"
}

phase_components_manifest() {
    info "═══ Fase 2: Components manifest ═══"
    install_verify_scripts
    write_components_manifest
}

# ═════════════════════════════════════════════
# Single-component update path (--component=<X>)
# ═════════════════════════════════════════════

# Refresh the openclaw npm package + restart the user-level gateway service
# without touching tunnel.json or openclaw.json (auth token + provider config
# are preserved). Idempotent. Linux-only (this is the VPS installer).
update_openclaw_gateway_only() {
    if ! command_exists npm; then
        die "openclaw-gateway: npm requerido"
    fi
    local npm_target="openclaw"
    [[ -n "$OPENCLAW_PIN_VERSION" ]] && npm_target="openclaw@$OPENCLAW_PIN_VERSION"
    run_with_progress "Actualizando openclaw kernel ($npm_target)" --estimate 30 npm install -g "$npm_target"

    local tnode_uid
    tnode_uid="$(id -u "$TNODE_USER" 2>/dev/null || echo "")"
    if [[ "$(id -u)" == "0" ]] && [[ -n "$tnode_uid" ]]; then
        su - "$TNODE_USER" -c "export XDG_RUNTIME_DIR=/run/user/$tnode_uid; systemctl --user restart openclaw-gateway" 2>/dev/null || true
    else
        systemctl --user restart openclaw-gateway 2>/dev/null || true
    fi
    success "openclaw-gateway refreshed"
}

# Refresh cloudflared binary by re-downloading the latest release + restart
# the system service. Tunnel credentials/config are untouched.
update_cloudflared_only() {
    local arch cfd_arch="amd64"
    arch="$(uname -m)"
    case "$arch" in
        aarch64|arm64) cfd_arch="arm64" ;;
        armv7*|armhf)  cfd_arch="arm" ;;
    esac
    local cfd_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cfd_arch}"
    run_with_progress "Descargando cloudflared latest" --estimate 15 \
        bash -c "curl -fsSL '$cfd_url' -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared"
    systemctl restart cloudflared 2>/dev/null || true
    success "cloudflared refreshed"
}

# Map component id → absolute path of its verify script (verify_<id>.py)
verify_script_for() {
    local comp="$1"
    local p="$OPENCLAW_HOME/verify/verify_${comp}.py"
    [[ -f "$p" ]] && echo "$p" || echo ""
}

# Run verify_<comp>.py and translate exit codes into installer-level outcomes.
# abort_on_fail=1 (default): die on exit≥2; abort_on_fail=0: warn + return rc
# (used by run_smoke_test_all to collect aggregate results).
run_smoke_test_one() {
    local comp="$1"
    local abort_on_fail="${2:-1}"
    local script
    script="$(verify_script_for "$comp")"
    if [[ -z "$script" ]]; then
        warn "smoke test $comp: verify_${comp}.py no encontrado, skip"
        return 0
    fi
    if ! command_exists python3; then
        warn "smoke test $comp: python3 no disponible, skip"
        return 0
    fi
    info "Smoke test: $comp"
    local out rc=0
    out="$(run_as_tnode python3 "$script" 2>&1)" || rc=$?
    case "$rc" in
        0) success "smoke $comp: OK"; return 0 ;;
        1) warn    "smoke $comp: warn — $(echo "$out" | tail -1)"; return 0 ;;
        *)
            if [[ "$abort_on_fail" == "1" ]]; then
                echo "$out" >&2
                die "smoke $comp: FAIL (exit $rc). Re-run con --no-smoke-test para forzar."
            fi
            warn "smoke $comp: FAIL (exit $rc) — $(echo "$out" | tail -1)"
            return "$rc"
            ;;
    esac
}

# Iterate the components manifest and verify every daemon/binary-os entry.
# Aggregates failures and dies once at the end so the operator sees the full
# picture (rather than aborting on the first failure).
run_smoke_test_all() {
    info "═══ Smoke tests ═══"
    local manifest="$OPENCLAW_HOME/components-manifest.json"
    if [[ ! -f "$manifest" ]]; then
        warn "components-manifest.json no encontrado, skip smoke tests"
        return 0
    fi
    local comps
    comps="$(python3 -c "
import json
m = json.load(open('$manifest'))
for c in m.get('components', []):
    if c.get('kind', '') in ('daemon', 'daemon-embedded', 'binary-os', 'binary-npm', 'kernel'):
        print(c.get('id', ''))
" 2>/dev/null || echo "")"
    if [[ -z "$comps" ]]; then
        warn "manifest sin daemon/binary-os/binary-npm/kernel — skip smoke tests"
        return 0
    fi
    local failed=0 c
    while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        run_smoke_test_one "$c" "0" || failed=$((failed + 1))
    done <<<"$comps"

    # Always run the deprecation gate even if the component isn't in the local
    # manifest — a zombie llm-config-watcher install on a previously-paired
    # node will not appear in components-manifest.json (the new installer
    # doesn't write it), so we'd miss it without this explicit pass.
    run_smoke_test_one "tnode-llm-config-watcher" "0" || failed=$((failed + 1))

    if [[ "$failed" -gt 0 ]]; then
        die "smoke tests: $failed componente(s) fallaron"
    fi
    success "smoke tests: todos OK"
}

# ═════════════════════════════════════════════
# UNINSTALL — local cleanup only
# ═════════════════════════════════════════════
# Stops + removes the systemd / launchd units this installer creates and
# deletes ~/.openclaw. Does NOT touch server-side state: the Cloudflare
# tunnel + DNS + Firestore docs are owned by the `deleteAgent` callable
# in tnode_client/functions/src/provisioning/delete.ts, triggered from
# the mobile app's "Eliminar nodo" UI. Run that BEFORE this script for a
# clean teardown; otherwise tunnel + Firestore residue persists until
# `cleanupOrphanedTunnels` (admin-only) prunes it.

# Systemd .service units this installer creates (system + user scope).
# pair-watch and tnode-config-sync-watch each install as BOTH a .service
# (the action) and a .path (the file watcher that triggers it), so they
# appear in both lists. cloudflared-update.{service,timer} are NOT here —
# they're auto-created by `cloudflared service install` and removed by
# `cloudflared service uninstall` (do_uninstall calls that explicitly).
UNINSTALL_SYSTEMD_SERVICES=(
    cloudflared
    tnode-chat-sync
    tnode-config-sync
    tnode-config-sync-watch
    tnode-telemetry
    tnode-llm-config-watcher
    pair-watch
)
# Systemd .path units (file watchers).
UNINSTALL_SYSTEMD_PATHS=(
    pair-watch
    tnode-config-sync-watch
)
# Launchd plist labels (macOS).
UNINSTALL_LAUNCHD_LABELS=(
    com.tbrain.pair-watch
    com.tbrain.llm-config-watcher
    com.tbrain.tnode-config-sync
    com.tbrain.tnode-config-sync-watch
    com.tbrain.tnode-chat-sync
    com.tbrain.tnode-telemetry
)

# Run a privileged command directly if root, via `sudo -n` otherwise.
# Non-interactive on purpose — uninstall is meant to work under
# `curl ... | bash --yes` where there's no TTY for a sudo password.
_uninstall_sudo() {
    if [[ "$(id -u)" == "0" ]]; then
        "$@"
    else
        sudo -n "$@" 2>/dev/null
    fi
}

# Stop+disable+remove a single systemd unit at both user and system scope.
# `type` is "service" or "path". Missing units are silently skipped, so
# this is safe to call against a partial install.
_uninstall_systemd_unit() {
    local name="$1" type="${2:-service}"
    local unit="${name}.${type}"
    local user_path="$HOME/.config/systemd/user/${unit}"
    local sys_path="/etc/systemd/system/${unit}"

    if [[ -f "$user_path" ]]; then
        local rt="/run/user/$(id -u)"
        XDG_RUNTIME_DIR="$rt" systemctl --user stop "$unit" 2>/dev/null || true
        XDG_RUNTIME_DIR="$rt" systemctl --user disable "$unit" 2>/dev/null || true
        rm -f "$user_path"
        info "removido (user): $unit"
    fi
    if [[ -f "$sys_path" ]]; then
        _uninstall_sudo systemctl stop "$unit" 2>/dev/null || true
        _uninstall_sudo systemctl disable "$unit" 2>/dev/null || true
        if _uninstall_sudo rm -f "$sys_path"; then
            info "removido (system): $unit"
        else
            warn "no pude remover $sys_path (sin sudo)"
        fi
    fi
}

# Unload + remove a launchd plist by label (macOS).
_uninstall_launchd_label() {
    local label="$1"
    local plist="$HOME/Library/LaunchAgents/${label}.plist"
    if [[ -f "$plist" ]]; then
        launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
        info "removido (launchd): $label"
    fi
}

do_uninstall() {
    detect_os

    # ── 0. Pre-flight: sudo check ──────────────────────────────
    # On Linux, almost every cleanup step needs root: deleting unit files
    # under /etc/systemd/system/, killing the dedicated `tnode` user with
    # systemd --user under linger, and `userdel -r tnode`. If we aren't
    # root and can't get sudo non-interactively (curl|bash has no TTY for
    # a sudo password prompt), abort early with a clear instruction
    # instead of failing silently halfway through.
    if [[ "$OS" != "Darwin" ]] && [[ "$(id -u)" != "0" ]]; then
        if ! sudo -n true 2>/dev/null; then
            warn "Necesitas root para limpiar /etc/systemd/system y el user dedicado 'tnode'."
            warn "Re-corre así (cualquiera de las dos):"
            warn "  sudo -v && curl -fsSL https://install.tbrain.app | bash -s -- --uninstall --yes"
            warn "  curl -fsSL https://install.tbrain.app -o /tmp/uninstall.sh && sudo bash /tmp/uninstall.sh --uninstall --yes"
            die "abortando — sin sudo no-interactivo no puedo terminar"
        fi
    fi

    # ── 1. Locate every ~/.openclaw on this host ───────────────
    # The installer writes ~/.openclaw under different users depending on
    # how it was invoked: as root → /home/tnode/.openclaw (creates a
    # dedicated `tnode` user); as a regular user → $HOME/.openclaw. A
    # node may end up with both if the operator switched modes between
    # runs. Find every candidate so we don't miss state.
    local candidates=()
    [[ -d "$HOME/.openclaw" ]] && candidates+=("$HOME/.openclaw")
    if [[ "$OS" != "Darwin" ]]; then
        local h
        for h in /home/*/.openclaw; do
            [[ -d "$h" ]] || continue
            # Skip if it's already in the list (e.g. when $HOME == /home/<user>).
            local already=0
            local existing
            for existing in "${candidates[@]}"; do
                [[ "$existing" == "$h" ]] && already=1 && break
            done
            [[ "$already" == "0" ]] && candidates+=("$h")
        done
    fi

    phase "1/5" "Uninstall — limpieza local"

    # Best-effort identity readout from any candidate (warning context only).
    local nodeId="" tunnelDomain="" cand
    for cand in "${candidates[@]}"; do
        if [[ -r "$cand/tnode-chat-sync.json" ]] && command_exists python3; then
            nodeId=$(python3 -c "import json; print(json.load(open('$cand/tnode-chat-sync.json')).get('nodeId',''))" 2>/dev/null || echo "")
        fi
        if [[ -r "$cand/tunnel.json" ]] && command_exists python3; then
            tunnelDomain=$(python3 -c "import json; print(json.load(open('$cand/tunnel.json')).get('domain',''))" 2>/dev/null || echo "")
        fi
        [[ -n "$nodeId" ]] && break
    done

    if [[ ${#candidates[@]} -eq 0 ]]; then
        info "No hay ningún ~/.openclaw en este host."
    else
        info "Estado detectado:"
        [[ -n "$nodeId" ]]       && info "  nodeId:        $nodeId"
        [[ -n "$tunnelDomain" ]] && info "  tunnelDomain:  $tunnelDomain"
        info "  Candidatos a borrar:"
        for cand in "${candidates[@]}"; do
            info "    $cand"
        done
    fi

    warn "Esto borra SOLO el estado local en este nodo."
    warn "El estado server-side (Firestore + tunnel CF) NO se limpia automáticamente."
    warn "Para limpiarlo, borra el nodo desde la app móvil ANTES de continuar"
    warn "(eso dispara la Cloud Function deleteAgent que hace el teardown completo)."

    if [[ "$YES" == "0" ]]; then
        echo
        printf "    ¿Continuar con uninstall local? [y/N] "
        local ans
        read -r ans
        case "${ans:-n}" in
            [yY]|[yY][eE][sS]) ;;
            *) info "Cancelado por el usuario."; exit 0 ;;
        esac
    fi

    # ── 2. cloudflared service uninstall ───────────────────────
    # `cloudflared service install` creates THREE units atomically:
    # cloudflared.service AND cloudflared-update.{service,timer}. Its
    # own `service uninstall` knows about all three; running it first
    # avoids leaving the auto-update timer behind after we delete
    # cloudflared.service manually below.
    phase "2/5" "cloudflared service uninstall"
    if command_exists cloudflared; then
        # Suppress output: cloudflared logs ERR + a long systemctl line
        # whenever its service unit doesn't exist (the common idempotent
        # case where it was already removed). Real failures get caught
        # by the manual unit-file removal in step 3.
        if [[ "$OS" == "Darwin" ]]; then
            cloudflared service uninstall >/dev/null 2>&1 || true
        else
            _uninstall_sudo cloudflared service uninstall >/dev/null 2>&1 || true
        fi
        info "cloudflared service uninstall ejecutado"
    else
        info "cloudflared no instalado — saltando"
    fi

    # ── 3. Dismantle dedicated tnode user + system units ───────
    phase "3/5" "Detener servicios y remover unit files"
    if [[ "$OS" == "Darwin" ]]; then
        for label in "${UNINSTALL_LAUNCHD_LABELS[@]}"; do
            _uninstall_launchd_label "$label"
        done
    else
        # Disable linger on the dedicated `tnode` user (if it exists);
        # otherwise its `systemd --user` instance keeps respawning
        # openclaw-gateway and friends even after we delete unit files.
        # Stop the user manager service explicitly so the kill takes
        # effect now, not on next boot.
        if id tnode >/dev/null 2>&1; then
            _uninstall_sudo loginctl disable-linger tnode 2>/dev/null || true
            local tnode_uid
            tnode_uid=$(id -u tnode 2>/dev/null || echo "")
            if [[ -n "$tnode_uid" ]]; then
                _uninstall_sudo systemctl stop "user@${tnode_uid}.service" 2>/dev/null || true
            fi
            info "linger desactivado y user@${tnode_uid:-?}.service detenido"
        fi
        # Remove every system-scope unit file we might have created.
        for svc in "${UNINSTALL_SYSTEMD_SERVICES[@]}"; do
            _uninstall_systemd_unit "$svc" "service"
        done
        for pth in "${UNINSTALL_SYSTEMD_PATHS[@]}"; do
            _uninstall_systemd_unit "$pth" "path"
        done
        _uninstall_sudo systemctl daemon-reload 2>/dev/null || true
        # reset-failed clears systemd's cached "loaded: not-found" state
        # for units we just removed, so `systemctl status` returns clean.
        _uninstall_sudo systemctl reset-failed 2>/dev/null || true
    fi
    success "servicios detenidos y unit files removidos"

    # ── 4. Kill leftover processes + remove every ~/.openclaw ──
    phase "4/5" "Kill procesos sobrevivientes + borrar estado local"
    if [[ "$OS" != "Darwin" ]]; then
        # Some embedded daemons (openclaw-gateway, tnode_*.py) may still
        # be running outside any unit (e.g. orphaned by user@.service
        # teardown above, or started via SSH for debugging). Nuke them
        # by pattern so the rm -rf below doesn't race against active
        # writers re-creating files in ~/.openclaw.
        _uninstall_sudo pkill -9 -f openclaw-gateway 2>/dev/null || true
        _uninstall_sudo pkill -9 -f tnode_chat_sync 2>/dev/null || true
        _uninstall_sudo pkill -9 -f tnode_config_sync 2>/dev/null || true
        _uninstall_sudo pkill -9 -f tnode_telemetry 2>/dev/null || true
        _uninstall_sudo pkill -9 -f tnode_llm_config_watcher 2>/dev/null || true
        _uninstall_sudo pkill -9 -f "cloudflared --no-autoupdate tunnel run" 2>/dev/null || true
        sleep 1
    fi

    if [[ ${#candidates[@]} -eq 0 ]]; then
        info "no hay ~/.openclaw — nada que borrar"
    else
        for cand in "${candidates[@]}"; do
            if rm -rf "$cand" 2>/dev/null; then
                success "borrado: $cand"
            elif _uninstall_sudo rm -rf "$cand"; then
                success "borrado (via sudo): $cand"
            else
                warn "no pude borrar $cand"
            fi
        done
    fi

    # Optionally remove the dedicated `tnode` user. Done last so that
    # `userdel -r` can clear /home/tnode entirely (~/.config/systemd/user
    # unit files, ~/.cache, ~/.local, etc. — not just ~/.openclaw which
    # we already nuked above).
    if [[ "$OS" != "Darwin" ]] && id tnode >/dev/null 2>&1; then
        if _uninstall_sudo userdel -r tnode 2>/dev/null; then
            success "user dedicado 'tnode' eliminado (incluyendo /home/tnode)"
        else
            # userdel -r prints "directory not empty" when something is
            # still holding a file open. Force-kill once more and retry.
            _uninstall_sudo pkill -9 -u tnode 2>/dev/null || true
            sleep 1
            if _uninstall_sudo userdel -r tnode 2>/dev/null; then
                success "user dedicado 'tnode' eliminado tras retry"
            else
                warn "no pude userdel -r tnode — re-corre el uninstall"
            fi
        fi
    fi

    # ── 5. Optional: purge installer-managed binaries ──────────
    if [[ "$PURGE_BINARIES" == "1" ]]; then
        phase "5/5" "Borrar binarios (--purge-binaries)"
        local bin
        for bin in /usr/local/bin/cloudflared /usr/bin/openclaw; do
            if [[ -e "$bin" ]]; then
                if _uninstall_sudo rm -f "$bin"; then
                    success "borrado: $bin"
                else
                    warn "no pude borrar $bin"
                fi
            fi
        done
    else
        phase "5/5" "Binarios preservados"
        info "/usr/local/bin/cloudflared y /usr/bin/openclaw NO se tocan."
        info "Pasa --purge-binaries si los quieres borrar también."
    fi

    echo
    success "Uninstall local completo."
    echo
    info "Próximos pasos:"
    info "  • Server-side (si no lo hiciste): borra el nodo desde la app móvil"
    info "  • Reinstalar:  curl -fsSL https://install.tbrain.app | bash"
}

# Dispatch a single-component refresh: install/update the named component,
# regenerate the manifest so its version is current, then smoke-test it.
cmd_component() {
    local comp="$COMPONENT"
    # Single-component path bypasses phase_validate, so seed OS/ARCH and
    # OPENCLAW_HOME / TNODE_USER / TNODE_HOME the same way the full flow would.
    detect_os
    setup_tnode_user
    info "═══ Componente único: $comp ═══"
    case "$comp" in
        openclaw-gateway)   update_openclaw_gateway_only ;;
        tnode-chat-sync)    install_tnode_chat_sync ;;
        tnode-config-sync)  install_tnode_config_sync ;;
        tnode-telemetry)    install_tnode_telemetry ;;
        pair-watch)         install_pair_watch ;;
        cloudflared)        update_cloudflared_only ;;
        *) die "cmd_component: $comp no soportado (debería haber sido validado en parse_args)" ;;
    esac
    install_verify_scripts
    write_components_manifest
    if [[ "$NO_SMOKE_TEST" == "0" ]]; then
        run_smoke_test_one "$comp" "1"
    fi
}

# ═════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════
main() {
    parse_args "$@"

    # Auto non-interactive when piped (curl | bash)
    if [[ ! -t 0 ]] && [[ "$YES" == "0" ]]; then
        YES=1
        info "Detectado pipe (stdin no es TTY) → modo no-interactivo activado"
    fi

    if [[ "$VERBOSE" == "1" ]]; then
        set -x
    fi

    print_banner

    # --uninstall: stop+remove local services and ~/.openclaw, then exit.
    # Server-side cleanup (Firestore + CF tunnel) is owned by the
    # `deleteAgent` callable triggered from the mobile app — see
    # do_uninstall() and tnode_client/functions/src/provisioning/delete.ts.
    if [[ "$UNINSTALL" == "1" ]]; then
        do_uninstall
        exit 0
    fi

    # --component=<X>: skip the multi-phase flow and only refresh that one.
    if [[ -n "$COMPONENT" ]]; then
        cmd_component
        exit 0
    fi

    phase_validate
    if [[ "$UPDATE_ONLY" == "0" ]]; then
        # Full install path
        phase_ollama
        phase_openclaw
        phase_tunnel
        phase_tailscale
    else
        # Update-only path: skip ollama / openclaw kernel reinstall / tunnel
        # provisioning / tailscale. Kernel + cloudflared refresh is delegated
        # to `--component=<id>` so operators choose explicitly when to bump.
        info "modo --update-only: skip ollama / openclaw / tunnel / tailscale"
    fi
    phase_helpers
    # In update-only mode, phase_helpers refreshes pair-watch + tnode-config-sync
    # but not tnode-chat-sync / tnode-telemetry (those normally install only
    # after a fresh tunnel provisioning). Refresh them too if their scripts
    # already exist on disk (i.e. node was previously paired).
    if [[ "$UPDATE_ONLY" == "1" ]]; then
        if [[ -f "$OPENCLAW_HOME/scripts/tnode_chat_sync.py" ]]; then
            install_tnode_chat_sync
        fi
        if [[ -f "$OPENCLAW_HOME/scripts/tnode_telemetry.py" ]]; then
            install_tnode_telemetry
        fi
    fi
    phase_components_manifest
    [[ "$NO_SMOKE_TEST" == "0" && "$UPDATE_ONLY" == "1" ]] && run_smoke_test_all
    phase_summary
}

main "$@"
