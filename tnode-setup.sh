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

TNODE_SETUP_VERSION="1.63.0"
CLOUD_MODEL="kimi-k2.5:cloud"
# Pin OpenClaw to the last known-good release. v2026.4.25 introduced an
# auto-pair regression where the gateway responds 1008 to unknown devices
# even with a valid Ed25519 signature + master token, blocking cloud
# provisioning E2E. Override with `OPENCLAW_PIN_VERSION=` (empty) to take
# whatever is current.
OPENCLAW_PIN_VERSION="${OPENCLAW_PIN_VERSION-2026.6.10}"
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
# install.tbrain.app/verify/verify_<id>.py. Keep in sync with both.
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

    # Grant passwordless sudo so the agent (running as `tnode`) can perform
    # privileged ops (systemctl, apt-get, writes under /etc/, etc.) without
    # interactive prompts. Drop-in is atomic, validated via visudo, and
    # removed by --uninstall.
    local sudoers_file="/etc/sudoers.d/tnode"
    local sudoers_tmp
    sudoers_tmp="$(mktemp)"
    echo "${TNODE_USER} ALL=(ALL) NOPASSWD: ALL" > "$sudoers_tmp"
    if visudo -c -f "$sudoers_tmp" >/dev/null 2>&1; then
        install -m 0440 -o root -g root "$sudoers_tmp" "$sudoers_file"
        success "sudo NOPASSWD habilitado para $TNODE_USER (vía $sudoers_file)"
    else
        warn "sudoers drop-in falló validación visudo — saltando grant"
    fi
    rm -f "$sudoers_tmp"
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

# Set the model in OpenClaw config (agents.defaults.model.primary)
configure_openclaw_model() {
    local model_value="$1"
    local oc_config="$OPENCLAW_HOME/openclaw.json"

    if [[ ! -f "$oc_config" ]]; then
        warn "openclaw.json no encontrado, modelo se configurará automáticamente"
        return 0
    fi

    # Use Python to safely modify nested JSON config
    if command_exists python3; then
        python3 - "$oc_config" "$model_value" <<'PYEOF'
import json, sys
config_path, model = sys.argv[1], sys.argv[2]
try:
    with open(config_path) as f:
        c = json.load(f)
    # Navigate/create nested path: agents.defaults.model.primary
    agents = c.setdefault("agents", {})
    defaults = agents.setdefault("defaults", {})
    model_cfg = defaults.setdefault("model", {})
    old_model = model_cfg.get("primary", "(none)")
    model_cfg["primary"] = model
    with open(config_path, "w") as f:
        json.dump(c, f, indent=2)
    print(f"{old_model} → {model}")
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

# >>> BEGIN PATH B PLUGINS (generated by embed_pathb_plugins.py — do not edit by hand)
# Embedded tar.gz (base64) of the 4 Path B plugins: tbrain-context-engine,
# tnode, tnode-transport (dist + pure-JS ws), tnode-wake (owner-auth HTTP
# wake route — POST /api/v1/tnode/wake — que drena config-sync al entrar a Chat).
# Staged to a temp dir during provisioning and activated via the OpenClaw SDK
# (openclaw plugins install + enable) — provenance + trust + dangerous-code
# scan, NOT a drop-dir + hand-edit of plugins.entries. The transport registers
# its WS endpoint via the SDK (registerHttpRoute on the gateway port :18789);
# the CF tunnel routes /transport -> :18789 and /api/v1/tnode/ -> :18789.
_pathb_plugins_b64() {
cat <<'PATHB_B64_EOF'
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
PATHB_B64_EOF
}

materialize_pathb_plugins() {
    local stage_dir="$OPENCLAW_HOME/.pathb-stage"
    rm -rf "$stage_dir"; mkdir -p "$stage_dir"
    if ! _pathb_plugins_b64 | base64 -d | tar xz -C "$stage_dir" 2>/dev/null; then
        warn "No se pudieron desempacar los plugins Path B"
        return 0
    fi
    chown -R "$TNODE_USER":"$TNODE_USER" "$stage_dir" 2>/dev/null || true
    # SDK-standard activation: install (provenance + trust + scan) then enable,
    # NOT a drop-dir + hand-edit of plugins.entries. The gateway is started later
    # and auto-loads the enabled plugins. transport.config.persist is left off —
    # it is set at cutover (transportEnabled), inert until then.
    local pid
    for pid in tbrain-context-engine tnode tnode-transport tnode-wake; do
        if run_as_tnode openclaw plugins install "$stage_dir/$pid" --force </dev/null; then
            run_as_tnode openclaw plugins enable "$pid" </dev/null || warn "Path B: enable de $pid falló"
            info "Path B: $pid instalado (SDK)"
        else
            warn "Path B: install de $pid falló"
        fi
    done
    rm -rf "$stage_dir"
    chown "$TNODE_USER":"$TNODE_USER" "$OPENCLAW_HOME/openclaw.json" 2>/dev/null || true
    success "Plugins Path B instalados por SDK (context-engine + tnode + transport + wake)"
}
# <<< END PATH B PLUGINS

# Path B: enable the materialized plugins on every provision. materialize_pathb_plugins
# INSTALLS them into ~/.openclaw/extensions/ with provenance, but cleanup-pre-snapshot
# deletes openclaw.json so the snapshot ships NO plugins.entries; phase_tunnel then
# regenerates a minimal openclaw.json (device-pair only) on each fresh provision. Re-
# enable here, after phase_tunnel, via the SDK (openclaw plugins enable) — the plugins
# are already present in extensions/ from the snapshot, so no re-install is needed. The
# gateway hot-reloads plugins.entries (or recover_failed_openclaw_gateway restarts it),
# so it loads them. Idempotent: a no-op when already enabled (full-install path).
enable_pathb_plugins() {
    local ext_dir="$OPENCLAW_HOME/extensions"
    local pid
    for pid in tbrain-context-engine tnode tnode-transport tnode-wake; do
        if [[ -d "$ext_dir/$pid" ]]; then
            if run_as_tnode openclaw plugins enable "$pid" </dev/null >/dev/null 2>&1; then
                info "Path B: $pid enabled (SDK)"
            else
                warn "Path B: enable de $pid falló"
            fi
        fi
    done
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

    # Path B: materialize embedded plugins + enable them (openclaw.json now exists)
    materialize_pathb_plugins

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

        # 2. Call the Worker with the HMAC headers. With TNODE_AUTO_PAIR (cloud
        # provisioning) we pin the tunnel to TNODE_NODE_ID via desiredNodeId so
        # droplet name, node doc, tunnel and domain all share ONE id (the
        # worker replaces any stale tunnel with that name). BYO installs omit
        # it and keep getting a worker-minted random id.
        local provision_body provision_response
        provision_body="{\"label\": \"$(hostname -s 2>/dev/null || echo 'tnode')\"}"
        if [[ -n "${TNODE_NODE_ID:-}" ]]; then
            provision_body="{\"label\": \"$(hostname -s 2>/dev/null || echo 'tnode')\", \"desiredNodeId\": \"${TNODE_NODE_ID}\"}"
        fi
        provision_response="$(curl -fsSL -X POST "$TUNNEL_API_URL" \
            -H "Authorization: Bearer $ptoken_sig" \
            -H "X-Provision-Timestamp: $ptoken_ts" \
            -H "X-Provision-Nonce: $ptoken_nonce" \
            -H "Content-Type: application/json" \
            -d "$provision_body" \
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
            # per skills/TELEMETRY.md. The Cloudflare Tunnel ingress
            # configured above routes to :18790, so this daemon is
            # required for the client to reach the gateway through the
            # tunnel on any node that runs one.
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

            # Override Restart=on-failure (default from `cloudflared service
            # install`) → Restart=always. Cloudflare sometimes terminates
            # connectors cleanly with exit 0 (e.g. "no more connections
            # active and exiting" after a control-stream failure on the
            # CF edge side), and on-failure does NOT retry exit 0.
            # Without this override the tunnel stays dead until a human
            # runs `systemctl start cloudflared`. Drop-in survives future
            # `cloudflared service install` re-runs.
            mkdir -p /etc/systemd/system/cloudflared.service.d
            cat > /etc/systemd/system/cloudflared.service.d/restart-always.conf <<'CFDOVERRIDE'
[Service]
Restart=always
RestartSec=5s
StartLimitIntervalSec=0
CFDOVERRIDE
            systemctl daemon-reload 2>/dev/null || true

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
        # The gatewayToken lives inside openclaw.json under `gateway.tokens[0].token`
        # (or a similar path depending on OpenClaw version). We decode it from
        # `openclaw qr` output — which is the canonical wire format.
        if command -v python3 >/dev/null 2>&1; then
            gw_token=$(run_as_tnode openclaw qr --setup-code-only 2>/dev/null \
                | python3 -c "
import base64, json, sys
try:
    code = sys.stdin.read().strip()
    if not code: sys.exit(0)
    padded = code + '=' * ((4 - len(code) % 4) % 4)
    data = json.loads(base64.urlsafe_b64decode(padded))
    print(data.get('token') or data.get('gatewayToken') or '')
except Exception:
    pass
" 2>/dev/null || echo "")
        fi

        if [[ -n "$gw_token" ]]; then
            local server_url="wss://${TUNNEL_DOMAIN}/ws"
            local extra_json
            extra_json=$(python3 -c "
import json
print(json.dumps({
    'tunnelDomain': '$TUNNEL_DOMAIN',
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
    # commands. Sub-agents (install/uninstall/restart_for_subagents) are
    # also handled here — the Firestore-driven `agentsCatalog/` →
    # `agents/<id>/agent/` materialization happens on demand from
    # individual user toggles, not via a polling daemon. ──
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
        python3 - "$sync_json" <<PYEOF
import json, os, sys, datetime
path = sys.argv[1]
data = {
    "nodeId":        "${TNODE_NODE_ID}",
    "nodeSecret":    "${TNODE_NODE_SECRET}",
    "mintUrl":       "${MINT_NODE_TOKEN_URL}",
    "pullUrl":       "${PULL_LLM_CONFIG_URL}",
    "registeredAt":  datetime.datetime.utcnow().isoformat() + "Z",
    "autoPair":      True,
    "ownerUid":      "${TNODE_OWNER_UID}",
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
os.chmod(path, 0o600)
PYEOF
        success "chat-sync configurado (auto-pair)"
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
    # Initialize as `{}` (not just `touch` empty). The openclaw gateway
    # parses this file on every incoming WS connect; a 0-byte file fails
    # JSON.parse and the gateway closes EVERY client with `code=1000
    # reason=n/a` — silent close that's very hard to diagnose. pair_watch.py
    # tolerates an empty file (catches the parse error), but the gateway
    # does not. Only initialize if missing/empty to preserve pending state
    # across re-runs of the installer.
    if [[ ! -s "$OPENCLAW_HOME/devices/pending.json" ]]; then
        echo '{}' > "$OPENCLAW_HOME/devices/pending.json"
    fi

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
  TNODE_CONFIG_SYNC_POLL_IDLE_S   Backstop poll interval (default 300s; el wake da inmediatez)
  TNODE_CONFIG_SYNC_IDLE_AFTER    Empty polls before switching to idle cadence (default 5)
  TNODE_CONFIG_SYNC_DRAIN         If set, drain the command queue once and exit (wake-drain)
  TNODE_CONFIG_SYNC_ONESHOT       If set, run a single push_openclaw_config and exit
                           (used by the file-watcher trigger).
  TNODE_CONFIG_SYNC_DECL_ONESHOT  If set, refresh the declarative .md files once and
                           exit (spawned by tnode-chat-sync when a session starts).
"""
from __future__ import annotations
# 1.17.0 — MCP servers (Direction A, remote-only): mcp.install /
#          mcp.remove / restart_gateway_for_mcp handlers. Enabling a
#          server writes openclaw.json["mcpServers"][id] for http/sse
#          transports (the API key rides in `headers`) and mirrors to
#          users/{uid}/nodes/{nodeId}/mcpServers/{id}; disabling removes
#          the entry but keeps the mirror config for one-tap re-enable.
#          Secrets travel once in the command params, never stored in
#          the mirror. stdio (command/args/env) is F2, gated behind the
#          curated mcpCatalog allowlist. OpenClaw 2026.5.x is already a
#          native MCP client — this only writes its config.
# 1.16.1 — _render_himalaya_toml: message.send.save-copy = false. The
#          post-SMTP IMAP APPEND targeted himalaya's literal "Sent"
#          folder, which doesn't exist on Gmail → exit 1 on every send
#          even though the mail DID go out; agents read the non-zero
#          exit as a failed send and fell back to stale paths. Gmail/
#          Outlook/Yahoo auto-save SMTP mail to their sent folder, so
#          the copy was redundant anyway. Root-cause of the "envío no
#          funciona" report on the Mini 2026-06-12.
# 1.16.0 — workspace skills agenda + drive ship inside the daemon: the
#          startup self-heal now materializes both skills under
#          workspace/skills/ (byte-canonical via _ensure_workspace_skills;
#          embedded block generated by tnode_server/scripts/
#          embed_workspace_skills.py) and appends their usage rules to
#          workspace/TOOLS.md (_ensure_tools_rules — created if missing).
#          Rule markers are the skill binary paths, NOT section headers:
#          the 2026-06-11/12 manual rollouts left different headers per
#          node ("## Regla 5 — …" on the Mini, "## Regla: …" on Pi/
#          Oracles) and a header marker would have duplicated the rule.
#          agenda email step is conditional on the node having mail.
# 1.15.0 — channels.email.link gmail/imap hardening (fire-tested on the Mini
#          2026-06-11): (a) the branch now appends a `## Email del usuario —
#          vía himalaya` section to workspace/SOUL.md so the on-node agent
#          actually USES the linked account (before this, only the resend
#          branch wrote agent guidance and agents kept routing mail through
#          legacy skills); section is replace-on-relink (account changes) and
#          removed on unlink — unlink now also removes the resend SOUL
#          section (pre-existing gap). (b) _render_himalaya_toml maps
#          port→encryption (465/993→tls, 587/143→start-tls): the client used
#          to preload smtp 587 while the TOML hardcoded implicit tls and
#          `message send` hung forever in the handshake. (c) himalaya is
#          auto-installed on demand (macOS: brew; Linux: pinned v1.2.0
#          release binary per-arch into ~/.local/bin) and the smoke test +
#          SOUL section use the resolved absolute path (the gateway's PATH
#          may not include /opt/homebrew/bin).
# 1.11.0 — _apply_provider_to_openclaw seeds default media-generation models
#          (image=gemini-3.1-flash-image-preview, music=lyria-3-clip-preview,
#          video=grok-imagine-video) on first OpenRouter provision via
#          setdefault, so a freshly-provisioned node can generate image/music/
#          video out of the box without the user hand-picking them in Mente.
#          OR-scoped + setdefault (a Mente choice or sub-agent card still wins).
# 1.10.0 — install_subagent also reads `musicGenerationModel` /
#          `videoGenerationModel` from the agent card and sets them under
#          agents.defaults (siblings of imageGenerationModel; node-global media
#          slots, both OpenRouter-served). Write generalized to loop the three.
# 1.9.0 — install_subagent reads `imageGenerationModel` from the agent card
#         and sets agents.defaults.imageGenerationModel (node-global
#         image-generation model; OpenClaw 2026.5.x rejects the slot under
#         agents.list[]). NOT routed through _ensure_model_registered — that
#         is the *chat* allowlist; the gateway auto-enables the image plugin
#         from this key on reload. Pairs with telemetry's agent.imageModel
#         .set RPC (the in-app picker). Node-scoped: uninstall leaves it.
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
# 1.8.0 — channels.email.link: provider=resend branch. Validates the
#         API key against api.resend.com/domains, persists it to
#         ~/.openclaw/credentials/resend.json (mode 0600), and appends
#         a `## Envío de correos — vía skill email-send` section to
#         workspace/SOUL.md so the on-node agent knows to route mail
#         through the HTTPS skill instead of smtplib (DigitalOcean
#         blocks outbound 465/587). channels.email.unlink now cleans
#         up resend.json alongside the himalaya config.
# 1.2.0 — sub-agents: install_subagent / uninstall_subagent /
#         restart_gateway_for_subagents handlers (Firestore-driven
#         per-node materialization replacing the agency-agents/ dir
#         + symlink hack).
# 1.19.0 — TOOLS.md declarativo v1.1: el servidor compone TODO el estándar
#          (anti-loop/aviso/email/agenda/drive) además de Regla 0 + MCPs.
#          _sync_channels_to_firestore refleja el canal email a la subcolección
#          `channels`; _migrate_tools_v11 fuerza el compose, renderiza y limpia
#          (una vez) las copias viejas que viven fuera de los markers;
#          _ensure_tools_rules retirado; bootstrap-via-CF para nodos sin cache.
# 1.20.0 — SOUL.md / IDENTITY.md declarativos: el servidor compone sus zonas
#          gestionadas ESTÁTICAS (operativa sub-agentes/archivos/entregables en
#          SOUL; rol-coordinador en IDENTITY) vía la CF tnodeConfigSyncMd; el
#          daemon las renderiza por hash entre markers tnode:soul/identity,
#          appendeados al final (preservando la personalidad curada). _md_migrate
#          limpia (una vez) las secciones legacy fuera de los markers — incluido
#          el email, que se consolidó en TOOLS.md Regla 4. Retirados:
#          _ensure_subagents_sections + las 3 funciones de email-SOUL (himalaya/
#          email-send/unlink). _regenerate_agents_index se queda (roster).
# 1.21.0 — MCP: (a) _build_mcp_remote_entry honra secretsSchema[].valuePrefix
#          (prefijo EXACTO del header: "Bearer " o "" crudo para x-api-key /
#          CONTEXT7_API_KEY); sin el campo cae al heurístico legacy → desbloquea
#          exa/context7. (b) Reinicio del gateway coalescido server-side: el loop
#          marca dirty tras mcp.install/remove + install/uninstall_subagent (done)
#          y _restart_gateway_if_dirty SIGTERMa UNA vez al cierre del batch; el
#          restart_gateway_* explícito del cliente queda dirty-gated (no-op si ya
#          se aplicó). Quita la dependencia del dispose() del cliente (frágil, sin
#          orderBy) — arregla el punto rojo en CTX al activar un MCP, y el gemelo
#          de Sub-Agentes.
# 1.21.1 — Revierte el restart coalescido de 1.21.0 (b): el gateway YA
#          hot-recarga openclaw.json (mcp.servers + agents.list) — verificado en
#          el Mini ("[reload] config hot reload applied (mcp.servers.X)"). El
#          restart era innecesario; además el SIGTERM-por-pgrep NUNCA funcionó
#          (el patrón "openclaw-gatewa" no matchea `node …/openclaw/dist/index.js
#          gateway`, y el gateway atrapa SIGTERM). El punto rojo de CTX no era del
#          gateway sino de telemetry (deriva el dot del compiled del último
#          turno). handle_restart_gateway_for_mcp/_subagents quedan como no-ops
#          que ack-ean el comando del dispose() del cliente. Se conserva el
#          valuePrefix de 1.21.0 (a).
# 1.21.3 — embed poll skill (create+broadcast) en _ensure_workspace_skills.
# 1.22.0 — TEAM_INDEX.md declarativo (delegación entre TNodes): el servidor
#          compone agency-agents/TEAM_INDEX.md (roster de peers: alias, rol,
#          especialidad derivada del toolsJson de cada peer) + el bloque
#          "equipo" de IDENTITY.md (condicional a peers), vía la CF
#          tnodeConfigSyncMd target="team". El daemon lo renderiza como ARCHIVO
#          DEDICADO completo (no entre markers, como AGENTS_INDEX.md) por hash:
#          _team_index_sync_from_json + _render_team_index. Sin peers el roster
#          se borra. Análogo a sub-agentes (IDENTITY→AGENTS_INDEX→sessions_spawn):
#          aquí IDENTITY→TEAM_INDEX→tnode-delegate. Recompose vía trigger
#          onWrite(peers/) (server-side, junto al de TOOLS.md de F4).
# 1.23.0 — embed del skill tnode-delegate en _ensure_workspace_skills (+ FILES
#          en embed_workspace_skills.py): el daemon materializa
#          workspace/skills/tnode-delegate/ en cada boot (como agenda/drive/
#          poll) para que el nodo pueda DELEGAR a sus peers sin SCP manual.
#          Pareja del TEAM_INDEX de 1.22.0 (que ya renderiza el roster).
# 1.24.0 — USER.md declarativo: nuevo target md "user" en _MD_TARGETS. La CF
#          (soul_identity_sync.ts target=user) compone el perfil del DUEÑO
#          (users/{uid}.profile, capturado en la app) y el daemon lo renderiza
#          AL INICIO del USER.md (position=start, markers tnode:user),
#          preservando el contenido curado de abajo. Render por hash vía
#          _md_sync_from_json (sin migrate). Base del perfilamiento North Star.
# 1.26.0 — Agente `guest` dedicado (Opción B, aislamiento por-invitado):
#          _ensure_guest_agent() en el startup self-heal inserta el entry
#          `guest` en agents.list (workspace-guest neutro, modelo heredado del
#          nodo, sandbox off) y materializa el workspace de atención comercial
#          neutra (USER/SOUL/IDENTITY/AGENTS, SIN PII del dueño). chat-sync
#          1.25.0 rutea `tnode-guest-*` aquí vía prefijo `agent:guest:`. El
#          guest queda FUERA de main.subagents.allowAgents (no es target de
#          delegación, es un agente ruteado por sesión).
# 1.25.0 — Lecturas Firestore: el sync declarativo (TOOLS/SOUL/IDENTITY/USER/
#          TEAM) ya NO se pollea. Era la fuente dominante de Document reads
#          (LOOKUP) — 5 hash-reads × cada poll de comandos (3s) × cada nodo — y
#          escalaba con cada target declarativo. Ahora es EVENT-DRIVEN:
#          (1) un refresco one-time al arrancar el daemon (freshness post-boot);
#          (2) modo DECL_ONESHOT que tnode-chat-sync spawnea al detectar una
#          sesión nueva (run_decl_oneshot, siempre exit 0, nunca bloquea);
#          (3) los 5 hashes en UN GET enmascarado (_prime_node_fields) en vez de
#          5. Lecturas ∝ uso real (nodo en reposo = 0). Sin poll periódico.
# 1.27.0 — Guard-rails Capa 1 (#2.2): piso `tools.deny` en el agente `guest`.
#          Bloquea para TODOS los invitados los tools de sistema/datos del
#          dueño: shell (exec/process), filesystem (read/write/edit/dir/file),
#          sesiones/subagentes (sessions_*/subagents/agents_list), mensajería a
#          canales (message), canvas y browser. Deja web_search/web_fetch/
#          image_generate/tts/hf (público). _ensure_guest_agent ahora también
#          ENFORZA el deny en un entry guest existente (idempotente). La capa 2
#          (refinamiento per-link) la aplica el hook before_tool_call del plugin.
# 1.28.0 — Fix boot-race del startup self-heal (nodos nacidos de snapshot DO):
#          el daemon arranca como `tnode` ANTES de que el installer haga chown
#          del openclaw.json a `tnode` → el write de agents.list fallaba con
#          PermissionError y el agente `guest` NO se materializaba hasta un
#          restart manual de config-sync (la Opción B no quedaba lista de
#          fábrica). Ahora el self-heal se REINTENTA en el loop (flag
#          self_heal_done) manteniendo cadencia activa (3s) hasta confirmar que
#          el guest entry existe → queda listo segundos después del chown, sin
#          intervención. _run_startup_self_heal() distingue race (retry) de
#          error real (loguea 1x y se rinde, sin spam ni cadencia activa
#          perpetua). Idempotente (las _ensure_* ya lo eran).
# 1.29.0 — Guard-rails P3 (#2.2) delegación per-link: `sessions_spawn`/`sessions_send`
#          SALEN del floor Capa-1 (ya no se deniegan a nivel agente) y se gatean
#          per-link en el hook before_tool_call por guardRails.allowedAgents
#          (default-deny, fail-closed). Como OpenClaw gatea el spawn por
#          subagents.allowAgents del agente, el `guest` (compartido) recibe el
#          roster completo del equipo (todo agente salvo main/guest) en
#          _ensure_guest_agent + el rebuild de subagentes; el hook hace la
#          restricción real per-invitado. Idempotente.
# 1.36.0 — MCP OAuth (Notion/Linear/Asana/…) + migración a CLI. (a) Handlers
#          nuevos mcp.oauth.begin / mcp.oauth.complete: OpenClaw 2026.6.10 trae
#          OAuth nativo para MCP remotos (DCR + token store/refresh); NO lo
#          construimos. begin = `openclaw mcp add --auth oauth
#          --oauth-redirect-url https://go.tbrain.app/mcp/callback --no-probe` +
#          `mcp login` → parsea la authorize URL del stdout → la devuelve al app;
#          complete = `mcp login --code <code>` + `mcp reload`. Flujo headless
#          (el app transporta URL ida + code vuelta; el verifier PKCE se guarda
#          en el nodo). (b) handle_mcp_install/remove dejan de editar
#          openclaw.json directo y usan el CLI (`mcp set` / `mcp unset`+`logout`)
#          — principio SDK: el CLI es el contrato estable, el shape del JSON
#          deriva entre versiones. install rechaza authType=oauth (va por begin).
#          Mirror Firestore añade authType (header|oauth) + status oauth_pending.
__VERSION__ = "1.40.0"

import hashlib
import hmac
import json
import os
import platform
import re
import secrets as py_secrets
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
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
# Idle = backstop. La cola se drena de inmediato por WAKE (el app dispara el
# drain-oneshot al pasar Dashboard→Chat), así que el poll periódico solo es red
# de seguridad por si se perdió un wake. 300s (vs 15s) baja ~20× las lecturas de
# Firestore por-nodo en reposo — clave al escalar la flota. El wake da la
# inmediatez; este intervalo NO es el camino normal.
POLL_IDLE_S = float(os.environ.get("TNODE_CONFIG_SYNC_POLL_IDLE_S", "300"))
IDLE_AFTER = int(os.environ.get("TNODE_CONFIG_SYNC_IDLE_AFTER", "5"))
ONESHOT = bool(os.environ.get("TNODE_CONFIG_SYNC_ONESHOT"))
# Declarative refresh oneshot — wired as an OpenClaw SessionStart hook so the
# .md files are current at session bootstrap (replaces the background poll).
DECL_ONESHOT = bool(os.environ.get("TNODE_CONFIG_SYNC_DECL_ONESHOT"))
# Command-drain oneshot — el WAKE del app (Dashboard→Chat, vía file-watcher
# .path) dispara `python3 tnode_config_sync.py` con TNODE_CONFIG_SYNC_DRAIN=1:
# drena la cola de commands UNA vez y sale. Es el camino primario (el daemon
# solo poll-backstop). Evita el poll constante per-nodo.
DRAIN_ONESHOT = bool(os.environ.get("TNODE_CONFIG_SYNC_DRAIN"))


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

    v1.6.0: filtra por `type IN _HANDLED_TYPES` para no agarrar commands
    de otros daemons (tnode-chat-sync maneja cron.* y tasks.*). Antes,
    config-sync se llevaba *cualquier* command pending y lo marcaba como
    `error: unknown_command_type` antes que el daemon dueño lo viera —
    rompía el flow de cualquier handler que no esté en _HANDLERS.
    """
    base = _firestore_base()
    # Parent for the collectionId `commands` nested under the node doc.
    parent = f"users/{token['uid']}/nodes/{token['nodeId']}"
    url = f"{_firestore_base()}/{parent}:runQuery"

    # No orderBy: a composite index (status + createdAt + type) would be
    # needed and command queues never get deep enough for ordering to
    # matter in practice. Callers that care about order can use __name__
    # which has an implicit default index.
    body = {
        "structuredQuery": {
            "from": [{"collectionId": "commands"}],
            "where": {
                "compositeFilter": {
                    "op": "AND",
                    "filters": [
                        {"fieldFilter": {
                            "field": {"fieldPath": "status"},
                            "op": "EQUAL",
                            "value": {"stringValue": "pending"},
                        }},
                        {"fieldFilter": {
                            "field": {"fieldPath": "type"},
                            "op": "IN",
                            "value": {"arrayValue": {"values": [
                                {"stringValue": t} for t in _HANDLED_TYPES
                            ]}},
                        }},
                    ],
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


def _cli_env() -> dict:
    """Env for spawning the `openclaw` CLI. The CLI treats OPENCLAW_HOME as the
    PARENT of the config dir (it appends `.openclaw`), while this daemon uses
    OPENCLAW_HOME as the config dir itself. Inheriting our value makes the CLI
    resolve a doubled `.openclaw/.openclaw/` path (phantom device identities,
    stray restart-intents, failed CLI calls). Point it at the parent so the
    CLI lands on the real config dir."""
    env = os.environ.copy()
    env["OPENCLAW_HOME"] = str(OPENCLAW_DIR.parent)
    # Como servicio de sistema config-sync no hereda XDG_RUNTIME_DIR; sin él el
    # CLI del openclaw reintenta hallar el socket del gateway y se vuelve LENTO
    # (visto en `wiki ingest/compile` del handler drive_wiki_sync). Apuntarlo al
    # runtime dir del user lo hace conectar al instante.
    env.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    return env


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
            env=_cli_env(),
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
            env=_cli_env(),
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


def _strip_provider_prefix(slug: str, provider: str) -> str:
    """Get the INTERNAL provider id (no prefix) — what providers[p].models[].id
    must be. Idempotent: strips `<provider>/` if present, else no-op.
    """
    if not isinstance(slug, str) or not isinstance(provider, str):
        return slug
    needle = provider + "/"
    if slug.startswith(needle):
        return slug[len(needle):]
    return slug


def _build_prefixed_slug(provider: str, model: str) -> str:
    """Get the PREFIXED slug — what agents.defaults.models[key] and
    agents.list[].model.primary must be. OpenClaw 2026.5.x exige que el
    slug del agente lleve el prefix del provider local (ver memoria
    `or_api_quirks` §6); sin prefix, OpenClaw interpreta `<vendor>/<id>`
    como `<provider-local>/<model-id>` y falla con `No API key for
    provider <vendor>`. Idempotente: si ya está prefixed, no-op.
    """
    if not isinstance(model, str) or not isinstance(provider, str):
        return model
    needle = provider + "/"
    if model.startswith(needle):
        return model
    return needle + model


# v1.11.0 — default media-generation models seeded on first OpenRouter
# provision so a fresh node can generate image/music/video out of the box,
# mirroring how the cerebro (chat) model is applied. Economic tier; the user
# can switch any of them in Mente (agent.{image,music,video}Model.set), which
# wins because we only `setdefault` (never overwrite an explicit choice).
_DEFAULT_MEDIA_MODELS = {
    "imageGenerationModel": "openrouter/google/gemini-3.1-flash-image-preview",
    "musicGenerationModel": "openrouter/google/lyria-3-clip-preview",
    "videoGenerationModel": "openrouter/x-ai/grok-imagine-video",
}


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

    v1.5.0+ — slug normalization (fix OpenClaw 2026.5.x `Unknown model`):
    `providers[p].models[].id` recibe el slug INTERNO sin prefix
    (`qwen/qwen3.6-plus`), mientras que `agents.defaults.models[key]`
    recibe el slug PREFIXED (`openrouter/qwen/qwen3.6-plus`). El parser
    de OpenClaw splittea por la primera `/` para extraer el provider
    local; sin prefix `openrouter/`, falla con `No API key found for
    provider <vendor>`. Ver memoria `or_api_quirks` §6 para el contrato.

    Idempotente — acepta `model` con o sin prefix; internal_id / prefixed
    se derivan via helpers `_strip_provider_prefix` / `_build_prefixed_slug`.

    El legacy `agents.defaults.model.primary` (singular) se borra en cada
    escritura — desde OpenClaw v2026.4.24+ produce `Unknown model`.
    """
    internal_id = _strip_provider_prefix(model, provider)
    prefixed_slug = _build_prefixed_slug(provider, internal_id)

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
        (m for m in models_list if isinstance(m, dict) and m.get("id") == internal_id),
        None,
    )
    if existing is None:
        models_list.append({
            "id": internal_id,
            "name": internal_id,
            "contextWindow": ctx or _default_context_for(provider),
            "maxTokens": max_tokens,
        })
    else:
        if ctx:
            existing["contextWindow"] = ctx
        if max_tokens:
            existing["maxTokens"] = max_tokens

    agents_defaults = cfg.setdefault("agents", {}).setdefault("defaults", {})
    agents_defaults.setdefault("models", {}).setdefault(prefixed_slug, {})
    agents_defaults.pop("model", None)  # drop legacy singular key

    # Seed default media-generation models so a freshly-provisioned node can
    # generate image/music/video without the user hand-picking them in Mente.
    # OpenRouter-only (the defaults are OR slugs that need the node's OR key)
    # and setdefault-only (a prior Mente choice or sub-agent card is kept).
    if provider == "openrouter":
        for _slot, _default_slug in _DEFAULT_MEDIA_MODELS.items():
            agents_defaults.setdefault(_slot, _default_slug)

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

    # El gateway hot-recarga models.providers (apiKey incl.) + agents.defaults.models
    # de openclaw.json — verificado en vivo en 2026.6.10 (PID estable, log
    # `config hot reload applied`). NO reiniciamos: el restart sobraba y causaba
    # el parpadeo "gateway starting; retry shortly".
    # Push the new state up immediately so the client sees it.
    try:
        new_state = push_openclaw_config(token)
    except Exception as e:  # noqa: BLE001
        _log(f"post-update state push failed: {e}")
        new_state = None

    return {
        "status": "done",
        "result": {
            "provider": provider,
            "applied": "hot-reload",
            "llmMode": (new_state or {}).get("llmMode"),
        },
    }


def handle_set_agent_params(token: dict, params: dict) -> dict:
    """Fija los parámetros de generación por-agente (temperature, maxTokens)
    en `agents.list[<agentId>].params` — la ubicación ESTÁNDAR de OpenClaw que
    el runtime de texto lee (`params.temperature` / `params.maxTokens`, ver
    docs.openclaw.ai/help/faq). El campo `extraParams` NO es válido (el config
    validator lo rechaza con `Unrecognized key`).

    Verificado en vivo (2026-06-26): el gateway recoge los cambios de
    `agents.list[].params` en el siguiente turno SIN reiniciar, así que solo
    reescribimos openclaw.json. `temperature` se clampa a [0,2]; `maxTokens`
    debe ser entero positivo. Pasar `null` en cualquiera lo BORRA (vuelve al
    default del proveedor). agentId default = "main" (el agente del dueño).
    """
    agent_id = str(params.get("agentId") or "main").strip()
    has_temp = "temperature" in params
    has_max = "maxTokens" in params
    temp = params.get("temperature")
    max_tokens = params.get("maxTokens")

    if has_temp and temp is not None:
        try:
            temp = max(0.0, min(2.0, float(temp)))
        except (TypeError, ValueError):
            return {"status": "error", "result": {"error": "invalid_temperature"}}
    if has_max and max_tokens is not None:
        try:
            max_tokens = int(max_tokens)
        except (TypeError, ValueError):
            return {"status": "error", "result": {"error": "invalid_maxTokens"}}
        if max_tokens <= 0:
            max_tokens = None

    cfg = read_openclaw_json() or {}
    agents_list = cfg.setdefault("agents", {}).setdefault("list", [])
    entry = next(
        (a for a in agents_list if isinstance(a, dict) and a.get("id") == agent_id),
        None,
    )
    if entry is None:
        return {"status": "error", "result": {"error": f"agent_not_found: {agent_id}"}}

    p = entry.get("params")
    if not isinstance(p, dict):
        p = {}
    if has_temp:
        if temp is None:
            p.pop("temperature", None)
        else:
            p["temperature"] = temp
    if has_max:
        if max_tokens is None:
            p.pop("maxTokens", None)
        else:
            p["maxTokens"] = max_tokens
    if p:
        entry["params"] = p
    else:
        entry.pop("params", None)

    _write_openclaw_json(cfg)
    _log(
        f"set_agent_params {agent_id}: "
        f"temperature={p.get('temperature')} maxTokens={p.get('maxTokens')}"
    )

    try:
        push_openclaw_config(token)
    except Exception as e:  # noqa: BLE001
        _log(f"post set_agent_params push failed: {e}")

    return {"status": "done", "result": {"agentId": agent_id, "params": p}}


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

    # Pull the minted key — retry transient failures (read timeouts /
    # connection blips). A single read-timeout used to drop the command to
    # status=error with no retry, leaving the node without its LLM until a
    # manual re-trigger. HTTP errors (auth/logic) stay terminal. Re-sign per
    # attempt so a retry never trips replay / stale-timestamp checks.
    resp = None
    last_err: Exception | None = None
    for attempt in range(4):
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
            break
        except urllib.error.HTTPError as e:
            try:
                err_body = json.loads(e.read().decode("utf-8"))
            except Exception:
                err_body = {"error": e.reason}
            return {
                "status": "error",
                "result": {"error": f"pull_failed_{e.code}", "detail": err_body},
            }
        except (urllib.error.URLError, OSError) as e:  # noqa: BLE001
            last_err = e
            _log(
                f"apply_openrouter_key pull attempt {attempt + 1}/4 "
                f"transient error: {e}"
            )
            if attempt < 3:
                time.sleep(2 * (2 ** attempt))  # 2s, 4s, 8s
    if resp is None:
        return {
            "status": "error",
            "result": {
                "error": f"pull_unreachable_after_retries: {str(last_err)[:200]}"
            },
        }

    api_key = resp.get("apiKey")
    model = resp.get("model") or "qwen/qwen3.6-plus"
    base_url = resp.get("baseUrl") or "https://openrouter.ai/api/v1"
    if not api_key:
        return {"status": "error", "result": {"error": "no_api_key_returned"}}

    # El gateway hot-recarga models.providers (apiKey incl.) + agents.defaults.models
    # de openclaw.json — verificado en vivo en 2026.6.10 (PID estable, log
    # `config hot reload applied (models.providers.openrouter.apiKey)`). NO
    # reiniciamos: el restart sobraba y era la causa del parpadeo
    # "gateway starting; retry shortly" al asignar saldo (dropeaba los WS vivos).
    try:
        _apply_provider_to_openclaw(
            "openrouter", base_url, model, api_key=api_key,
            ctx=_default_context_for("openrouter"),
        )
    except Exception as e:  # noqa: BLE001
        return {"status": "error", "result": {"error": f"write_failed: {e}"}}
    try:
        new_state = push_openclaw_config(token)
    except Exception as e:  # noqa: BLE001
        _log(f"post-apply state push failed: {e}")
        new_state = None

    return {
        "status": "done",
        "result": {
            "provider": "openrouter",
            "model": model,
            "applied": "hot-reload",
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
# TEAM_INDEX.md = roster de TNodes-peer a los que delegar (skill tnode-delegate),
# hermano dedicado de AGENTS_INDEX.md. Lo compone la CF (target="team", lee
# peers/ + el toolsJson de cada peer) y el daemon lo renderiza como archivo
# completo por hash (ver "TEAM_INDEX.md renderer"). Sin peers → se borra.
_TEAM_INDEX_PATH = OPENCLAW_DIR / "agency-agents" / "TEAM_INDEX.md"


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


def _firestore_get_mcp_catalog_doc(token: dict, server_id: str) -> dict | None:
    """Read mcpCatalog/{server_id} via Firestore REST."""
    url = (
        f"https://firestore.googleapis.com/v1/projects/{PROJECT_ID}"
        f"/databases/(default)/documents/mcpCatalog/{server_id}"
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


def _firestore_upsert_mcp_server(token: dict, server_id: str, payload: dict) -> None:
    """Upsert users/{uid}/nodes/{nodeId}/mcpServers/{server_id} via PATCH +
    updateMask (idempotent; creates the doc if absent). Flat types only —
    `config` is JSON-encoded into a stringValue so we avoid a nested-map
    serializer. Only keys present in `payload` are written, so a disable
    that omits `config` keeps the stored config for one-tap re-enable."""
    cfg = load_config()
    uid = token["uid"]
    node_id = cfg["nodeId"]
    fields: dict = {}
    for k, v in payload.items():
        if isinstance(v, bool):
            fields[k] = {"booleanValue": v}
        elif isinstance(v, str):
            fields[k] = {"stringValue": v}
        elif isinstance(v, int):
            fields[k] = {"integerValue": str(v)}
        elif v is None:
            fields[k] = {"nullValue": None}
    mask = "&".join(f"updateMask.fieldPaths={k}" for k in payload.keys())
    url = (
        f"https://firestore.googleapis.com/v1/projects/{PROJECT_ID}"
        f"/databases/(default)/documents/users/{uid}/nodes/{node_id}"
        f"/mcpServers/{server_id}?{mask}"
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


def _firestore_upsert_channel(token: dict, channel_id: str, payload: dict) -> None:
    """Upsert users/{uid}/nodes/{nodeId}/channels/{channel_id} via PATCH +
    updateMask (idempotent). Flat types only. Mirrors _firestore_upsert_mcp_server.
    The server reads this subcollection to compose the email block of TOOLS.md."""
    cfg = load_config()
    uid = token["uid"]
    node_id = cfg["nodeId"]
    fields: dict = {}
    for k, v in payload.items():
        if isinstance(v, bool):
            fields[k] = {"booleanValue": v}
        elif isinstance(v, str):
            fields[k] = {"stringValue": v}
        elif isinstance(v, int):
            fields[k] = {"integerValue": str(v)}
        elif v is None:
            fields[k] = {"nullValue": None}
    mask = "&".join(f"updateMask.fieldPaths={k}" for k in payload.keys())
    url = (
        f"https://firestore.googleapis.com/v1/projects/{PROJECT_ID}"
        f"/databases/(default)/documents/users/{uid}/nodes/{node_id}"
        f"/channels/{channel_id}?{mask}"
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
    agent_id: str, action: str, recommended_model: str | None = None,
    image_generation_model: str | None = None,
    music_generation_model: str | None = None,
    video_generation_model: str | None = None,
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
        # Node-global media-generation models. A card may carry
        # `imageGenerationModel` / `musicGenerationModel` / `videoGenerationModel`
        # (each prefixed `openrouter/...`) — set them under agents.defaults
        # (per-node: OpenClaw 2026.5.x rejects these slots in agents.list[]).
        # Unlike the chat model we do NOT register them via
        # _ensure_model_registered: that adds the slug to agents.defaults.models
        # / providers[].models[] (the *chat* allowlist), which would surface a
        # media model as a selectable brain. The gateway auto-enables the
        # matching plugin from each key on reload. Node-scoped, so uninstall
        # leaves them untouched.
        media_models = {
            "imageGenerationModel": image_generation_model,
            "musicGenerationModel": music_generation_model,
            "videoGenerationModel": video_generation_model,
        }
        if any(media_models.values()):
            defaults_section = agents_section.setdefault("defaults", {})
            if isinstance(defaults_section, dict):
                for slot_key, slot_slug in media_models.items():
                    if slot_slug:
                        defaults_section[slot_key] = slot_slug
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
    # The team roster = every materialized agent except `main` and `guest`.
    _roster = sorted(
        a["id"] for a in agents_list
        if isinstance(a, dict) and a.get("id")
        and a.get("id") not in ("main", "guest")
    )
    # NB: `guest` (Opción B session-routed agent) is NOT a delegation target —
    # keep it out of main.subagents.allowAgents so main never spawns it as a
    # sub-agent (it's reached only via the `agent:guest:` sessionKey prefix).
    main_entry.setdefault("subagents", {})["allowAgents"] = _roster
    # P3 (#2.2): the shared `guest` agent may spawn the SAME team roster at the
    # OpenClaw level (so `sessions_spawn` isn't blocked by allowAgents); the
    # context-engine before_tool_call hook then restricts each guest to its
    # per-link guardRails.allowedAgents subset. Default-deny lives in the hook.
    _guest_entry = next(
        (a for a in agents_list if isinstance(a, dict) and a.get("id") == "guest"),
        None,
    )
    if _guest_entry is not None:
        _guest_entry.setdefault("subagents", {})["allowAgents"] = _roster

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


# Las secciones operativas de SOUL.md (sub-agentes / envío de archivos /
# entregables) y la de IDENTITY.md (rol-coordinador) ya NO se componen aquí:
# el servidor (soul_identity_sync.ts) las compone como zonas gestionadas
# declarativas y el daemon las renderiza por hash (ver "SOUL.md / IDENTITY.md
# renderer" más abajo). La de email salió de SOUL del todo (v1.20.0):
# TOOLS.md Regla 4 ya la cubre.


# `_EMAIL_SEND_SKILL_MD` y `_EMAIL_SEND_SEND_PY` son el contenido canónico
# del skill cuando se materializa via `channels.email.link(provider=resend)`.
# DEBEN coincidir byte-a-byte con los heredocs en `setup_workspace_skills()`
# del bash installer — cuando edites uno actualiza el otro.
_EMAIL_SEND_SKILL_MD = '''# email-send

Envía correos electrónicos vía **Resend** (HTTPS, port 443) — el único path
de envío que funciona en este nodo porque DigitalOcean bloquea SMTP
outbound (ports 465 y 587) como política anti-spam.

## Cuándo usarlo

Cuando el usuario te pida enviar un correo a alguien. Esta es la **única**
herramienta de envío en este nodo.

**NO uses** ninguna de estas — todas se cuelgan con `Network is unreachable`
o timeout porque dependen de SMTP outbound:

- `python -c "import smtplib..."`
- `himalaya message send`
- `mail`, `sendmail`, `mutt`
- `curl smtp://...`
- `nc smtp.gmail.com 465/587`

## Cómo invocar

```bash
~/.openclaw/workspace/skills/email-send/bin/send.py \\
  --to destinatario@ejemplo.com \\
  --subject "Asunto del correo" \\
  --body "Cuerpo del correo en texto plano."
```

Argumentos comunes:

- `--to <addr>` — destinatario único (obligatorio).
- `--subject <str>` — asunto (obligatorio).
- `--body <texto>` — cuerpo plain text. Si lo omites, lee de stdin
  (útil para pipes con cuerpos largos: `echo "$body" | send.py --to ... --subject ...`).
- `--html "<p>...</p>"` — cuerpo HTML opcional. Si lo pasas junto con
  `--body`, el cliente del usuario rendea el HTML y usa el text como
  fallback.
- `--cc <addr>` — repetible, para varios CC.
- `--reply-to <addr>` — header Reply-To opcional.
- `--from "<Nombre> <addr>"` — sobrescribe el sender. Por default es
  `TNode Agent <onboarding@resend.dev>` (sandbox de Resend, funciona sin
  DNS). Para mandar desde un dominio propio (e.g. `agent@tbrain.app`)
  hay que verificarlo en el dashboard de Resend primero.

## Ejemplo de turno completo

Pregunta del usuario: *"mándame un correo de bienvenida a ctobal@gmail.com"*

Tu acción (UNA invocación, no múltiples intentos):

```bash
~/.openclaw/workspace/skills/email-send/bin/send.py \\
  --to ctobal@gmail.com \\
  --subject "Bienvenido a TNode Pro" \\
  --body "Hola Tobal,

Bienvenido a tu nodo TNode Pro. Estoy listo para ayudarte con lo que necesites — desde redactar correos hasta automatizar tareas en tus canales conectados.

Saludos,
TNode Agent"
```

## Salida del comando

- **Éxito** (exit code 0): JSON a stdout
  ```json
  {"ok": true, "messageId": "<resend-uuid>", "to": "destinatario@...", "from": "..."}
  ```
  Cuando veas `ok: true` confirma al usuario que el correo se envió.

- **Fallo** (exit code 1 ó 2): mensaje de error a stderr. Códigos típicos:
  - `resend HTTP 401`: API key inválida — avisa al usuario y pídele que
    rote la key en `~/.openclaw/credentials/resend.json`.
  - `resend HTTP 403`: cuenta suspendida o límite mensual alcanzado.
  - `resend HTTP 422`: payload inválido (e.g. domain no verificado en el
    `from`, o `to` con formato incorrecto).
  - `resend network error`: improbable porque HTTPS está abierto, pero
    si pasa reporta el `reason` exacto.

## Lectura del inbox (informativo, NO usa este skill)

Para LEER correos del inbox del usuario (`tbrainplatform@gmail.com`) sí
puedes usar `himalaya` directamente — IMAP port 993 está abierto:

```bash
himalaya envelope list -f INBOX -p 1 -s 10
himalaya message read <id>
```

El `from` de los correos enviados por este skill NO es Gmail (es el
sandbox de Resend `onboarding@resend.dev`). El destinatario los ve en
inbox normal pero marca como "via resend.dev". Para envíos desde el
propio dominio del usuario hay que pasar por verificación DNS en
Resend.

## Límites del plan free de Resend

- 3,000 correos por mes.
- 100 correos por día.
- 1 dominio verificado.

Si llegas al límite y el usuario insiste, sugiérele upgradear el plan
en https://resend.com/pricing o usar un canal alternativo.
'''

_EMAIL_SEND_SEND_PY = '''#!/usr/bin/env python3
"""Send an email via Resend (https://resend.com) HTTPS API. Used by the
on-node OpenClaw agent when the host has SMTP outbound blocked (e.g.
DigitalOcean droplets, where ports 465/587 are firewalled by default).

Reads the API key from `~/.openclaw/credentials/resend.json`:

    {"api_key": "re_..."}

Exit codes:
    0  success — stdout JSON `{"ok":true,"messageId":"...","to":"..."}`
    1  transport / API error — stderr explains
    2  configuration error (missing creds, bad args)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

CRED_PATH = Path.home() / ".openclaw" / "credentials" / "resend.json"
API_URL = "https://api.resend.com/emails"
# `onboarding@resend.dev` is Resend's sandbox sender — works without DNS
# verification but lands tagged. To send from a custom domain (e.g.
# `agent@tbrain.app`) verify the domain in Resend's dashboard, then point
# this default at the verified sender or pass --from at the call site.
DEFAULT_FROM = "TNode Agent <onboarding@resend.dev>"


def _load_api_key() -> str:
    try:
        cred = json.loads(CRED_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        sys.stderr.write(
            f"credentials missing: {CRED_PATH}. Run `channels.email.link` or "
            "ask the user to provision a Resend API key.\\n"
        )
        sys.exit(2)
    except Exception as e:  # noqa: BLE001
        sys.stderr.write(f"cannot read {CRED_PATH}: {e}\\n")
        sys.exit(2)
    key = (cred.get("api_key") or "").strip()
    if not key:
        sys.stderr.write(f"api_key empty in {CRED_PATH}\\n")
        sys.exit(2)
    return key


def _post(api_key: str, payload: dict) -> dict:
    req = urllib.request.Request(
        API_URL,
        method="POST",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "User-Agent": "tnode-agent/email-send-skill (urllib)",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8", errors="replace")
        except Exception:  # noqa: BLE001
            pass
        sys.stderr.write(f"resend HTTP {e.code}: {body}\\n")
        sys.exit(1)
    except urllib.error.URLError as e:
        sys.stderr.write(f"resend network error: {e.reason}\\n")
        sys.exit(1)
    except Exception as e:  # noqa: BLE001
        sys.stderr.write(f"resend error: {e}\\n")
        sys.exit(1)


def main() -> None:
    ap = argparse.ArgumentParser(
        prog="email-send",
        description=(
            "Send an email via Resend HTTPS. The only way to send mail from "
            "this node — SMTP outbound is blocked by the cloud provider."
        ),
    )
    ap.add_argument("--to", required=True,
                    help="Recipient email (single address).")
    ap.add_argument("--subject", required=True, help="Email subject.")
    ap.add_argument(
        "--body",
        help=(
            "Plain-text body. If omitted, the script reads the body from "
            "stdin (lets you pipe long messages without quoting headaches)."
        ),
    )
    ap.add_argument(
        "--html",
        help=(
            "Optional HTML body. Sent alongside the plain text — most "
            "clients render the HTML and use plain text as fallback."
        ),
    )
    ap.add_argument(
        "--from",
        dest="from_addr",
        default=os.environ.get("EMAIL_SEND_FROM", DEFAULT_FROM),
        help=(
            "Sender header. Defaults to `TNode Agent <onboarding@resend.dev>` "
            "(Resend's sandbox sender, works without DNS). Override with the "
            "EMAIL_SEND_FROM env var or this flag once a custom domain is "
            "verified in Resend."
        ),
    )
    ap.add_argument(
        "--cc",
        action="append",
        default=[],
        help="CC address (repeatable).",
    )
    ap.add_argument(
        "--reply-to",
        dest="reply_to",
        help="Reply-To header (optional).",
    )
    args = ap.parse_args()

    body = args.body
    if body is None:
        body = sys.stdin.read()
    body = (body or "").strip()
    if not body and not args.html:
        sys.stderr.write("body is empty (pass --body or pipe via stdin)\\n")
        sys.exit(2)

    payload: dict = {
        "from": args.from_addr,
        "to": [args.to],
        "subject": args.subject,
    }
    if body:
        payload["text"] = body
    if args.html:
        payload["html"] = args.html
    if args.cc:
        payload["cc"] = args.cc
    if args.reply_to:
        payload["reply_to"] = args.reply_to

    api_key = _load_api_key()
    result = _post(api_key, payload)
    out = {
        "ok": True,
        "messageId": result.get("id", ""),
        "to": args.to,
        "from": args.from_addr,
    }
    print(json.dumps(out))


if __name__ == "__main__":
    main()
'''


def _ensure_email_send_skill() -> None:
    """Materialize the email-send skill files under workspace/skills/. Run
    by `_handle_email_link_resend` so the skill appears the moment the
    user pastes their Resend API key — no separate installer step needed.
    Idempotent and self-healing: if the user manually deletes or edits a
    file, re-running `channels.email.link` restores the canonical copy."""
    skill_dir = OPENCLAW_DIR / "workspace" / "skills" / "email-send"
    bin_dir = skill_dir / "bin"
    try:
        bin_dir.mkdir(parents=True, exist_ok=True)
        (skill_dir / "SKILL.md").write_text(
            _EMAIL_SEND_SKILL_MD, encoding="utf-8"
        )
        send_py = bin_dir / "send.py"
        send_py.write_text(_EMAIL_SEND_SEND_PY, encoding="utf-8")
        try:
            os.chmod(send_py, 0o755)
        except OSError:
            pass
    except Exception as e:  # noqa: BLE001
        _log(f"_ensure_email_send_skill: {e}")


# ── workspace skills agenda + drive (v1.16.0) ──────────────────
# Contenido canónico de los skills `agenda` (citas — feature calendario)
# y `drive` (lectura de la carpeta compartida de Google Drive). Igual que
# email-send viajan DENTRO del daemon y se materializan en el startup
# self-heal: los nodos nuevos nacen con ellos y los existentes los
# reciben al reiniciar tras el rollout — sin paso extra del installer.
# Las constantes _AGENDA_* / _DRIVE_* del bloque EMBEDDED las genera
# `scripts/embed_workspace_skills.py` (repo tnode_server) leyendo los
# skills canónicos del repo skills — regenerar ahí, NO editar a mano.

# >>> BEGIN EMBEDDED WORKSPACE SKILLS (generated — do not edit by hand)
_AGENDA_SKILL_MD = r'''# agenda

Consulta la disponibilidad del negocio y **reserva citas** para los
clientes que te escriben. El dueño configuró desde su app TNode a las
personas que atienden («recursos»: nombre, correo, horario y duración de
cita); tú eres quien agenda con los clientes.

## Cuándo usarlo

Cuando quien te escribe quiera **agendar / reservar / pedir una cita u
hora**, pregunte **disponibilidad** («¿tienen espacio mañana?») o quiera
**cancelar** una cita. SIEMPRE consulta este skill — NUNCA inventes
horarios ni confirmes citas de memoria.

## Cómo invocar

```bash
SKILL=~/.openclaw/workspace/skills/agenda/bin/agenda.py

python3 $SKILL resources                       # quiénes atienden y sus horarios
python3 $SKILL slots --date 2026-06-12         # espacios libres de todos ese día
python3 $SKILL slots --date 2026-06-12 --resource <id>
python3 $SKILL book --date 2026-06-12 --start 16:00 \
    --client "Carlos Peña" --channel whatsapp \
    [--contact "+52 55 1234 5678"] [--resource <id>]
python3 $SKILL cancel --id <appointmentId>
```

La fecha de HOY la obtienes con `date +%F`. Calcula fechas relativas
(«mañana», «el viernes») a partir de ella — formato `YYYY-MM-DD`, horas
`HH:MM` de 24h.

## Flujo de una reserva (el caso típico)

1. **Consulta** `slots --date <fecha>` (filtra `--resource` solo si el
   cliente pidió a alguien en específico).
2. **Ofrece 2–3 opciones** en lenguaje natural («con Ana hay espacio a las
   16:00 o 17:30, ¿cuál te acomoda?»). Si el día no tiene espacios, ofrece
   el siguiente día con disponibilidad.
3. **Pide SOLO los datos que te falten** (mínima fricción):
   - Nombre: siempre necesario.
   - Contacto: **NO lo pidas si el canal ya te lo da.** Por WhatsApp ya
     tienes su número → pásalo en `--contact`. Por Telegram usa su
     @usuario. Solo en el link compartido pide un teléfono o correo, UNA
     sola vez.
4. **Reserva** con `book`. Política de asignación:
   - El cliente nombró a alguien («con Ana») → pasa `--resource <id>`.
   - Sin preferencia → **omite `--resource`**: el sistema asigna a la
     persona con menos citas ese día. Confirma SIEMPRE con el nombre que
     regresa la respuesta («te atiende Beto a las 16:00»).
5. **Confirma al cliente** fecha, hora y con quién (los datos exactos del
   campo `appointment` de la respuesta — no los repitas de memoria).
6. **Avisa al recurso por correo** usando tu herramienta de correo de este
   nodo (la misma con la que mandas emails normalmente). La respuesta trae
   `resourceEmail` y `resourceName`. Formato sugerido:
   - Asunto: `Nueva cita: <cliente> — <fecha> <hora>`
   - Cuerpo: cliente, fecha, hora–fin, canal por el que reservó y contacto
     si lo tienes. Breve y claro, en español.

## Errores que DEBES manejar

- `slot_unavailable` → la respuesta incluye `alternatives` (recursos con
  sus próximos espacios libres). Ofrécelas tal cual al cliente; no
  insistas con la hora original.
- `slot_taken` → alguien ganó ese espacio hace un instante. Vuelve a pedir
  `slots` y ofrece lo nuevo.
- `resources` vacío → el dueño aún no configura su calendario. Dile al
  cliente que por ahora no puedes agendar y avisa al dueño en su próximo
  mensaje.

## Cancelaciones

Solo cancela si quien lo pide es razonablemente el dueño de la cita (mismo
canal/número que reservó, o el dueño del negocio). Tras `cancel`, avisa
por correo al recurso (la respuesta trae su correo) de que el espacio se
liberó.

## Reglas duras

- UNA invocación por consulta — no reintentes en loop; si algo falla dos
  veces, repórtalo.
- No ofrezcas horarios que no vengan de `slots`. No agendes en el pasado.
- No compartas datos de otros clientes (las citas existentes son
  confidenciales — solo di «ocupado»).
- El JSON de salida es tu fuente de verdad; léelo siempre.
'''

_AGENDA_MANIFEST = r'''{
  "name": "agenda",
  "version": "1.0.0",
  "type": "openclaw-skill",
  "entrypoint": "SKILL.md"
}
'''

_AGENDA_PY = r'''#!/usr/bin/env python3
"""agenda — consulta y reserva citas contra el calendario del nodo.

__VERSION__ = "1.0.0"

Thin client del endpoint `agendaApi` (Cloud Function, HMAC con el
nodeSecret de tnode-chat-sync.json — mismo flujo que pullLLMConfig, con el
action incluido en la firma). El transporte es `curl` via subprocess:
urllib falla TLS en el python de sistema de macOS (gotcha conocido) y curl
existe en toda la flota (Mac/Linux).

Salida: el JSON del server a stdout tal cual (el agente lo lee). Exit 0 en
ok, 1 en error — pero el JSON de error TAMBIÉN va a stdout porque trae
información accionable (p.ej. `slot_unavailable` incluye `alternatives`).

Uso:
  agenda.py resources
  agenda.py slots --date 2026-06-12 [--resource <id>]
  agenda.py book --date 2026-06-12 --start 16:00 --client "Carlos Peña" \
      [--contact "+52..."] [--channel whatsapp|telegram|guest|manual] \
      [--resource <id>]
  agenda.py cancel --id <appointmentId>
"""

import argparse
import datetime as dt
import hashlib
import hmac
import json
import os
import pathlib
import subprocess
import sys
import uuid

AGENDA_URL = os.environ.get(
    "TNODE_AGENDA_URL",
    "https://us-central1-tbrain-platform-7fc1f.cloudfunctions.net/agendaApi",
)


def _config_path() -> pathlib.Path:
    home = os.environ.get("OPENCLAW_HOME")
    base = pathlib.Path(home) if home else pathlib.Path.home() / ".openclaw"
    return base / "tnode-chat-sync.json"


def _load_auth() -> tuple[str, str]:
    path = _config_path()
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        _die(f"config_not_found: {path}")
    except json.JSONDecodeError:
        _die(f"config_invalid_json: {path}")
    node_id = data.get("nodeId")
    node_secret = data.get("nodeSecret")
    if not node_id or not node_secret:
        _die(f"config_missing_fields: {path}")
    return node_id, node_secret


def _die(msg: str) -> None:
    print(json.dumps({"error": msg}))
    sys.exit(1)


def _call(action: str, params: dict) -> None:
    node_id, node_secret = _load_auth()
    ts = str(int(dt.datetime.now().timestamp() * 1000))
    nonce = uuid.uuid4().hex
    signature = hmac.new(
        node_secret.encode(),
        f"{node_id}:{ts}:{nonce}:{action}".encode(),
        hashlib.sha256,
    ).hexdigest()
    body = json.dumps({
        "action": action,
        "nodeId": node_id,
        "timestamp": ts,
        "nonce": nonce,
        "signature": signature,
        "params": params,
    })
    try:
        proc = subprocess.run(
            [
                "curl", "-sS", "-X", "POST",
                "-H", "Content-Type: application/json",
                "--max-time", "20",
                "-d", "@-",
                AGENDA_URL,
            ],
            input=body.encode(),
            capture_output=True,
            timeout=30,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        _die(f"transport_error: {e}")
    out = proc.stdout.decode().strip()
    if proc.returncode != 0:
        _die(f"curl_failed: {proc.stderr.decode().strip()[:200]}")
    if not out:
        _die("empty_response")
    print(out)
    try:
        parsed = json.loads(out)
    except json.JSONDecodeError:
        sys.exit(1)
    sys.exit(0 if parsed.get("ok") else 1)


def _now_hhmm() -> str:
    return dt.datetime.now().strftime("%H:%M")


def _today_key() -> str:
    return dt.datetime.now().strftime("%Y-%m-%d")


def main() -> None:
    ap = argparse.ArgumentParser(prog="agenda.py")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("resources")

    p_slots = sub.add_parser("slots")
    p_slots.add_argument("--date", required=True, help="YYYY-MM-DD")
    p_slots.add_argument("--resource", default=None)

    p_book = sub.add_parser("book")
    p_book.add_argument("--date", required=True, help="YYYY-MM-DD")
    p_book.add_argument("--start", required=True, help="HH:MM")
    p_book.add_argument("--client", required=True)
    p_book.add_argument("--contact", default=None)
    p_book.add_argument(
        "--channel",
        default="guest",
        choices=["whatsapp", "telegram", "guest", "manual"],
    )
    p_book.add_argument("--resource", default=None,
                        help="omitir = auto-asigna al menos ocupado")

    p_cancel = sub.add_parser("cancel")
    p_cancel.add_argument("--id", required=True, dest="appt_id")

    args = ap.parse_args()

    if args.cmd == "resources":
        _call("resources", {})
    elif args.cmd == "slots":
        params = {
            "date": args.date,
            "nowHHmm": _now_hhmm(),
            "todayKey": _today_key(),
        }
        if args.resource:
            params["resourceId"] = args.resource
        _call("slots", params)
    elif args.cmd == "book":
        params = {
            "date": args.date,
            "start": args.start,
            "clientName": args.client,
            "channel": args.channel,
            "nowHHmm": _now_hhmm(),
            "todayKey": _today_key(),
        }
        if args.contact:
            params["clientContact"] = args.contact
        if args.resource:
            params["resourceId"] = args.resource
        _call("book", params)
    elif args.cmd == "cancel":
        _call("cancel", {"appointmentId": args.appt_id})


if __name__ == "__main__":
    main()
'''

_DRIVE_SKILL_MD = r'''# drive

Lee los archivos de la **carpeta de Google Drive que el dueño compartió
contigo** desde su app TNode. Es de **solo lectura**: puedes listar,
buscar y descargar — nunca modificar ni borrar nada de su Drive.

## Cuándo usarlo

Cuando el dueño (o un invitado) mencione **su Drive, su carpeta
compartida, o un documento por nombre** que no está en tu workspace
(«lee el contrato que está en mi carpeta», «¿qué hay en mi Drive?»,
«busca el manual de operación»). NUNCA digas que un archivo no existe
sin haber hecho `search` primero.

## Cómo invocar

```bash
SKILL=~/.openclaw/workspace/skills/drive/bin/drive.py

python3 $SKILL status                  # ¿hay carpeta conectada? ¿cómo se llama?
python3 $SKILL list                    # contenido de la carpeta (raíz)
python3 $SKILL list --folder <folderId>   # contenido de una subcarpeta
python3 $SKILL search "contrato"       # busca por nombre Y contenido
python3 $SKILL get <fileId>            # descarga → imprime la RUTA LOCAL
```

## El flujo típico (en 3 pasos)

1. **Encuentra el archivo**: `search "<palabras clave>"` (o `list` si te
   pidieron "qué hay en la carpeta"). Usa pocas palabras, sin acentos
   raros — busca por nombre y por contenido.
2. **Descárgalo**: `get <fileId>` con el id del resultado. La respuesta
   trae `savedTo` — la ruta local del archivo en
   `workspace/upload/drive/`.
3. **Léelo con tus herramientas normales** de archivos (la ruta de
   `savedTo`) y responde con lo que encontraste. No pegues el archivo
   completo en el chat: resume o cita lo relevante.

Los Google Docs / Sheets / Slides se convierten solos al descargarse:
Docs → Markdown (`.md`) · Sheets → CSV (primera hoja) · Slides → PDF.

## Errores que DEBES manejar

- `not_connected` — el dueño no ha conectado su carpeta. Dile: «Aún no
  has compartido una carpeta conmigo. En tu app TNode entra a tu nodo →
  **Archivos** → **Carpeta compartida** y sigue los pasos.»
- `access_revoked` — la carpeta dejó de estar compartida. Pídele que
  vuelva a compartirla (mismo lugar en la app) o conecte otra.
- `not_found` / `not_in_folder` — ese archivo no está en SU carpeta
  compartida (aunque exista en otro lado de su Drive, tú solo ves esa
  carpeta). Dilo tal cual y sugiérele moverlo a la carpeta compartida.
- `too_large` — el archivo pasa de 50 MB; no lo puedes descargar. Avísale.
- `export_unsupported` — ese tipo de archivo de Google (p.ej. un Form) no
  se puede exportar. Avísale.

## Reglas

- Si quien escribe es un **invitado** (no el dueño), usa el skill con
  criterio: la carpeta es del dueño. No compartas contenido sensible con
  invitados salvo que el dueño te lo haya pedido.
- Los archivos descargados son **copias locales** de ese momento; si el
  dueño dice que actualizó el archivo, descárgalo de nuevo.
- No descargues archivos que no necesites para la pregunta en turno.
'''

_DRIVE_MANIFEST = r'''{
  "name": "drive",
  "version": "1.0.0",
  "type": "openclaw-skill",
  "entrypoint": "SKILL.md"
}
'''

_DRIVE_PY = r'''#!/usr/bin/env python3
"""drive — lee la carpeta de Google Drive que el dueño compartió con el nodo.

__VERSION__ = "1.0.0"

Thin client del endpoint `driveReadApi` (Cloud Function, HMAC con el
nodeSecret de tnode-chat-sync.json; la firma incluye el namespace y el
action: `nodeId:ts:nonce:drive:<action>`). Transporte `curl` via
subprocess: urllib falla TLS en el python de sistema de macOS (gotcha
conocido) y curl existe en toda la flota (Mac/Linux).

El server confina cada nodo al árbol de la carpeta que SU dueño compartió
(solo lectura). `get` descarga el archivo a workspace/upload/drive/ y este
script imprime la RUTA LOCAL — después léelo con tus herramientas
normales de archivos.

Salida: JSON a stdout. Exit 0 en ok, 1 en error (el JSON de error también
va a stdout porque trae información accionable).

Uso:
  drive.py status
  drive.py list [--folder <folderId>] [--page-token <tok>]
  drive.py search "<texto>"
  drive.py get <fileId>
"""

import argparse
import datetime as dt
import hashlib
import hmac
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import urllib.parse
import uuid

DRIVE_URL = os.environ.get(
    "TNODE_DRIVE_URL",
    "https://us-central1-tbrain-platform-7fc1f.cloudfunctions.net/driveReadApi",
)


def _openclaw_home() -> pathlib.Path:
    home = os.environ.get("OPENCLAW_HOME")
    return pathlib.Path(home) if home else pathlib.Path.home() / ".openclaw"


def _config_path() -> pathlib.Path:
    return _openclaw_home() / "tnode-chat-sync.json"


def _load_auth() -> tuple[str, str]:
    path = _config_path()
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        _die(f"config_not_found: {path}")
    except json.JSONDecodeError:
        _die(f"config_invalid_json: {path}")
    node_id = data.get("nodeId")
    node_secret = data.get("nodeSecret")
    if not node_id or not node_secret:
        _die(f"config_missing_fields: {path}")
    return node_id, node_secret


def _die(msg: str) -> None:
    print(json.dumps({"error": msg}))
    sys.exit(1)


def _signed_body(action: str, params: dict) -> str:
    node_id, node_secret = _load_auth()
    ts = str(int(dt.datetime.now().timestamp() * 1000))
    nonce = uuid.uuid4().hex
    signature = hmac.new(
        node_secret.encode(),
        f"{node_id}:{ts}:{nonce}:drive:{action}".encode(),
        hashlib.sha256,
    ).hexdigest()
    return json.dumps({
        "action": action,
        "nodeId": node_id,
        "timestamp": ts,
        "nonce": nonce,
        "signature": signature,
        "params": params,
    })


def _call_json(action: str, params: dict) -> None:
    body = _signed_body(action, params)
    try:
        proc = subprocess.run(
            [
                "curl", "-sS", "-X", "POST",
                "-H", "Content-Type: application/json",
                "--max-time", "30",
                "-d", "@-",
                DRIVE_URL,
            ],
            input=body.encode(),
            capture_output=True,
            timeout=40,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        _die(f"transport_error: {e}")
    out = proc.stdout.decode().strip()
    if proc.returncode != 0:
        _die(f"curl_failed: {proc.stderr.decode().strip()[:200]}")
    if not out:
        _die("empty_response")
    print(out)
    try:
        parsed = json.loads(out)
    except json.JSONDecodeError:
        sys.exit(1)
    sys.exit(0 if parsed.get("ok") else 1)


def _safe_name(name: str) -> str:
    base = os.path.basename(name).strip() or "archivo"
    return re.sub(r"[^\w.\-() ]", "_", base)[:140]


def _call_get(file_id: str) -> None:
    body = _signed_body("get", {"fileId": file_id})
    hdr_path = tempfile.mktemp(prefix="drive_h_")
    out_path = tempfile.mktemp(prefix="drive_b_")
    try:
        proc = subprocess.run(
            [
                "curl", "-sS", "-X", "POST",
                "-H", "Content-Type: application/json",
                "--max-time", "120",
                "-d", "@-",
                "-D", hdr_path,
                "-o", out_path,
                DRIVE_URL,
            ],
            input=body.encode(),
            capture_output=True,
            timeout=150,
        )
        if proc.returncode != 0:
            _die(f"curl_failed: {proc.stderr.decode().strip()[:200]}")
        headers: dict[str, str] = {}
        for line in pathlib.Path(hdr_path).read_text(errors="replace").splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        fname_enc = headers.get("x-file-name")
        if not fname_enc:
            # Respuesta JSON de error del server — pásala tal cual.
            err = pathlib.Path(out_path).read_text(errors="replace").strip()
            print(err or json.dumps({"error": "download_failed"}))
            sys.exit(1)
        fname = _safe_name(urllib.parse.unquote(fname_enc))
        mime = headers.get("x-mime-type", "application/octet-stream")
        dest_dir = _openclaw_home() / "workspace" / "upload" / "drive"
        dest_dir.mkdir(parents=True, exist_ok=True)
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        dest = dest_dir / f"{stamp}-{fname}"
        os.replace(out_path, dest)
        print(json.dumps({
            "ok": True,
            "savedTo": str(dest),
            "fileName": fname,
            "mimeType": mime,
            "sizeBytes": dest.stat().st_size,
        }, ensure_ascii=False))
        sys.exit(0)
    except subprocess.TimeoutExpired:
        _die("transport_timeout")
    finally:
        for p in (hdr_path, out_path):
            try:
                os.unlink(p)
            except OSError:
                pass


def main() -> None:
    ap = argparse.ArgumentParser(prog="drive.py")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status")

    p_list = sub.add_parser("list")
    p_list.add_argument("--folder", default=None, help="subcarpeta (folderId)")
    p_list.add_argument("--page-token", default=None, dest="page_token")

    p_search = sub.add_parser("search")
    p_search.add_argument("query", help="texto a buscar (nombre o contenido)")

    p_get = sub.add_parser("get")
    p_get.add_argument("file_id", help="fileId de list/search")

    args = ap.parse_args()

    if args.cmd == "status":
        _call_json("status", {})
    elif args.cmd == "list":
        params: dict = {}
        if args.folder:
            params["folderId"] = args.folder
        if args.page_token:
            params["pageToken"] = args.page_token
        _call_json("list", params)
    elif args.cmd == "search":
        _call_json("search", {"q": args.query})
    elif args.cmd == "get":
        _call_get(args.file_id)


if __name__ == "__main__":
    main()
'''

_POLL_SKILL_MD = r'''# poll — difundir encuestas a los invitados

Crea o reparte encuestas a TODOS los miembros (invitados) del nodo. A cada uno
le aparece en su chat y puede votar; el conteo se actualiza en vivo y el dueño
lo ve desde su app.

`create` arma una encuesta nueva desde el prompt; `broadcast` reparte de nuevo
la última que el dueño creó en la app (botón + → Encuesta). Solo el dueño puede
crear/difundir — la firma HMAC con el `nodeSecret` del nodo lo garantiza del
lado del servidor; los invitados no pueden.

## Uso

Crear (y repartir) una encuesta nueva — pregunta + 2 a 12 opciones (agrega
`--multi` si permites varias respuestas):

    python3 ~/.openclaw/workspace/skills/poll/bin/poll.py create \
      --question "¿Snack para el viernes?" \
      --option "Pizza" --option "Sushi" --option "Tacos"

Difundir de nuevo la última encuesta del dueño a todos los invitados:

    python3 ~/.openclaw/workspace/skills/poll/bin/poll.py broadcast

Respuesta (JSON a stdout):

    { "ok": true, "pollId": "...", "question": "¿...?", "delivered": 3 }

- `question` — la pregunta de la encuesta difundida.
- `delivered` — a cuántos invitados llegó.

Confírmalo en lenguaje natural: "Listo, mandé la encuesta '¿...?' a 3
invitados."

## Errores (JSON `{ "error": "..." }`, exit 1)

- `missing_question` / `bad_options` — al crear faltó la pregunta o el número
  de opciones no está entre 2 y 12. Pídele los datos al dueño.
- `no_open_poll` — (solo en `broadcast`) el dueño no tiene una encuesta
  reciente. Pídele que la cree o usa `create`.
- `not_registered` / `not_paired` — el nodo aún no está vinculado.
- `bad_signature` — el `nodeSecret` no coincide (no debería pasar en un nodo
  sano).
- `transport_error` / `curl_failed` — problema de red al llamar al servidor.

## Detalles

- Endpoint: `pollApi` (Cloud Function), firma HMAC-SHA256 sobre
  `nodeId:timestamp:nonce:poll:broadcast` con el `nodeSecret` de
  `~/.openclaw/tnode-chat-sync.json`.
- El servidor resuelve al dueño del nodo, toma su encuesta más reciente y
  escribe la burbuja `[poll:{id}]` en el chat de cada miembro (Admin SDK).
- Difundir una encuesta NO es operación sensible ni de infraestructura:
  procede sin pedir permiso adicional.
'''

_POLL_MANIFEST = r'''{
  "name": "poll",
  "version": "1.1.0",
  "type": "openclaw-skill",
  "entrypoint": "SKILL.md"
}
'''

_POLL_PY = r'''#!/usr/bin/env python3
"""poll — difunde una encuesta del dueño a todos los invitados del nodo.

__VERSION__ = "1.1.0"

Thin client del endpoint `pollApi` (Cloud Function, HMAC con el nodeSecret de
tnode-chat-sync.json; la firma incluye namespace + action:
`nodeId:ts:nonce:poll:<action>`). Transporte `curl` via subprocess: urllib
falla TLS en el python de sistema de macOS (gotcha conocido) y curl existe en
toda la flota (Mac/Linux).

La encuesta puede crearse desde la app TNode (botón +) o por este skill
(`create`); en ambos casos le aparece en el chat a todos los miembros del nodo
y pueden votar (el conteo se actualiza en vivo). `broadcast` reparte de nuevo
la última encuesta. Solo el dueño puede crear/difundir — la firma HMAC con el
nodeSecret del nodo lo garantiza server-side.

Salida: JSON a stdout. Exit 0 en ok, 1 en error (el JSON de error también va a
stdout porque trae información accionable).

Uso:
  poll.py create --question "¿...?" --option A --option B [--multi]
                               # crea y reparte una encuesta nueva (2-12 opciones)
  poll.py broadcast            # difunde de nuevo la última encuesta del dueño
"""

import argparse
import datetime as dt
import hashlib
import hmac
import json
import os
import pathlib
import subprocess
import sys
import uuid

POLL_URL = os.environ.get(
    "TNODE_POLL_URL",
    "https://us-central1-tbrain-platform-7fc1f.cloudfunctions.net/pollApi",
)


def _openclaw_home() -> pathlib.Path:
    home = os.environ.get("OPENCLAW_HOME")
    return pathlib.Path(home) if home else pathlib.Path.home() / ".openclaw"


def _config_path() -> pathlib.Path:
    return _openclaw_home() / "tnode-chat-sync.json"


def _die(msg: str) -> None:
    print(json.dumps({"error": msg}))
    sys.exit(1)


def _load_auth() -> tuple[str, str]:
    path = _config_path()
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        _die(f"config_not_found: {path}")
    except json.JSONDecodeError:
        _die(f"config_invalid_json: {path}")
    node_id = data.get("nodeId")
    node_secret = data.get("nodeSecret")
    if not node_id or not node_secret:
        _die(f"config_missing_fields: {path}")
    return node_id, node_secret


def _signed_body(action: str, params: dict) -> str:
    node_id, node_secret = _load_auth()
    ts = str(int(dt.datetime.now().timestamp() * 1000))
    nonce = uuid.uuid4().hex
    signature = hmac.new(
        node_secret.encode(),
        f"{node_id}:{ts}:{nonce}:poll:{action}".encode(),
        hashlib.sha256,
    ).hexdigest()
    return json.dumps({
        "action": action,
        "nodeId": node_id,
        "timestamp": ts,
        "nonce": nonce,
        "signature": signature,
        "params": params,
    })


def _call(action: str, params: dict) -> None:
    body = _signed_body(action, params)
    try:
        proc = subprocess.run(
            [
                "curl", "-sS", "-X", "POST",
                "-H", "Content-Type: application/json",
                "--max-time", "30",
                "-d", "@-",
                POLL_URL,
            ],
            input=body.encode(),
            capture_output=True,
            timeout=40,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        _die(f"transport_error: {e}")
    out = proc.stdout.decode().strip()
    if proc.returncode != 0:
        _die(f"curl_failed: {proc.stderr.decode().strip()[:200]}")
    if not out:
        _die("empty_response")
    print(out)
    try:
        parsed = json.loads(out)
    except json.JSONDecodeError:
        sys.exit(1)
    sys.exit(0 if parsed.get("ok") else 1)


def main() -> None:
    ap = argparse.ArgumentParser(prog="poll.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("broadcast", help="difunde la última encuesta del dueño")
    p_create = sub.add_parser(
        "create", help="crea y reparte una encuesta nueva (2-12 opciones)")
    p_create.add_argument("--question", required=True, help="la pregunta")
    p_create.add_argument(
        "--option", action="append", default=[], dest="options",
        help="una opción (repetir entre 2 y 12 veces)")
    p_create.add_argument(
        "--multi", action="store_true", help="permite seleccionar varias")
    args = ap.parse_args()
    if args.cmd == "broadcast":
        _call("broadcast", {})
    elif args.cmd == "create":
        question = args.question.strip()
        options = [o.strip() for o in args.options if o.strip()]
        if not question:
            _die("missing_question")
        if len(options) < 2:
            _die("need_2_options")
        if len(options) > 12:
            _die("too_many_options")
        _call("create",
              {"question": question, "options": options, "multi": args.multi})


if __name__ == "__main__":
    main()
'''

_TNODE_DELEGATE_SKILL_MD = r'''# tnode-delegate

Delega una tarea al agente de **otro de tus nodos** (un "peer" que el dueño
enlazó en el widget **Equipo** de la app) y usa su respuesta para continuar tu
trabajo. El nodo destino resuelve la tarea con **sus** herramientas, skills y
contexto — tú no necesitas tener lo que él tiene.

## Cuándo usarlo

Cuando una tarea necesita un **canal, skill, contexto o acceso que ESTE nodo
no tiene pero otro de tus nodos SÍ**. En vez de intentar hacerla aquí o abrir
el navegador, delégasela al nodo indicado y espera su respuesta. Trátalo como
delegar a un colega especializado.

## Cómo invocar

```bash
SKILL=~/.openclaw/workspace/skills/tnode-delegate/bin/tnode-delegate.py

python3 $SKILL list                                    # a quién puedes delegar (alias + rol)
python3 $SKILL delegate --alias <alias> --text "<instrucción clara>"
python3 $SKILL delegate --alias investigador --text "Dame los 3 temas top de IA de hoy, con fuentes"
```

`delegate` imprime en stdout la **respuesta del agente del peer**. Úsala tal
cual para continuar tu flujo. Por defecto espera hasta 120 s (`--timeout`).

## Flujo típico

1. Si no recuerdas los alias disponibles, corre `list` (te da cada nodo
   enlazado con su **rol** — qué hace y cuándo conviene llamarlo).
2. `delegate --alias <alias> --text "..."` con una **instrucción clara y
   autocontenida**: el peer NO ve tu conversación, solo el texto que le mandas.
   Dale todo el contexto que necesite en ese texto.
3. Lee su respuesta (stdout) y **continúa tu tarea** con ella (resúmela,
   intégrala a tu entregable, etc.).

## Reglas duras

- UNA instrucción clara por delegación. No reintentes en loop: el skill ya
  reintenta una vez solo si el peer no respondió.
- Espera la respuesta y úsala; no repitas la delegación si ya respondió.
- NUNCA reenvíes secretos del usuario (contraseñas, tokens, API keys) por este
  canal.
- La **primera** delegación tras un rato de inactividad puede tardar ~1 minuto
  (el nodo destino se "calienta"); las siguientes responden en segundos. Es
  normal — no lo reportes como falla.

## Errores que DEBES manejar

- `unknown_peer_alias` → corre `list` para ver los alias válidos y usa uno de
  esos.
- `delegation_failed` → el peer no respondió (puede estar apagado o sin saldo
  de su LLM). Dile al usuario que **ese nodo no está disponible ahora** y, si
  aplica, intenta la tarea por otro medio.
- `list` vacío → el dueño aún no enlaza ningún nodo. Avísale que puede hacerlo
  en el widget **Equipo** de la app.
'''

_TNODE_DELEGATE_MANIFEST = r'''{
  "name": "tnode-delegate",
  "version": "1.0.0",
  "type": "openclaw-skill",
  "entrypoint": "SKILL.md"
}
'''

_TNODE_DELEGATE_PY = r'''#!/usr/bin/env python3
"""tnode-delegate — delega una tarea a OTRO de los TNodes del dueño.

__VERSION__ = "1.0.0"

El agente de ESTE nodo (A) le pasa una tarea al agente de otro nodo enlazado
(B, un "peer" configurado en el widget Equipo de la app) y lee su respuesta.
B la resuelve con SUS herramientas/skills/contexto.

Transporte: el WebSocket `/transport` de B (`wss://<peer-domain>/transport`,
plugin tnode-transport). Auth: un idToken de Firebase minteado con las
credenciales de ESTE nodo — ambos nodos son del mismo dueño, así que el
owner-gate de B lo acepta (NUNCA se copia un token de B). Los peers viven en
`users/{uid}/nodes/{nodeId}/peers/` (los escribe la app); este skill resuelve
alias→domain desde ahí.

Transporte HTTP (mint + Firestore) por `curl` — urllib falla TLS en el python
de sistema de macOS (mismo gotcha que el skill agenda). El WS necesita la lib
`websockets`; si el python actual no la tiene, el skill se re-ejecuta con uno
que sí (p.ej. el de Homebrew en Mac).

Uso:
  tnode-delegate.py list
  tnode-delegate.py delegate --alias <alias> --text "<tarea>" [--timeout 120]

`delegate` imprime la respuesta del agente del peer a stdout (exit 0); un
error va a stderr (exit != 0).
"""
# PEP 563: lazy annotations so `str | None` etc. don't break on python <3.10
# (the agent may launch the skill with an old system python).
from __future__ import annotations

import os
import subprocess
import sys

__VERSION__ = "1.0.0"


def _ensure_websockets() -> None:
    """Re-exec with a python that has `websockets` if the current one lacks it.

    The agent may launch the skill with macOS' system python (no pip libs).
    chat-sync already runs `websockets` somewhere on every node, so a capable
    interpreter exists; find it and hand off to it once."""
    try:
        import websockets.sync.client  # noqa: F401
        return
    except Exception:
        pass
    import shutil

    seen = {os.path.realpath(sys.executable)}
    candidates = [
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/usr/bin/python3",
        shutil.which("python3.13"),
        shutil.which("python3.12"),
        shutil.which("python3.11"),
        shutil.which("python3"),
    ]
    for py in candidates:
        if not py or not os.path.exists(py):
            continue
        rp = os.path.realpath(py)
        if rp in seen:
            continue
        seen.add(rp)
        try:
            probe = subprocess.run(
                [py, "-c", "import websockets.sync.client"],
                capture_output=True,
                timeout=10,
            )
        except Exception:
            continue
        if probe.returncode == 0:
            os.execv(py, [py, os.path.abspath(__file__)] + sys.argv[1:])
    print(
        "tnode-delegate: no python with 'websockets' found "
        "(pip install websockets)",
        file=sys.stderr,
    )
    sys.exit(3)


_ensure_websockets()

import argparse  # noqa: E402
import hashlib  # noqa: E402
import hmac  # noqa: E402
import json  # noqa: E402
import pathlib  # noqa: E402
import queue  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402
import uuid  # noqa: E402

from websockets.sync.client import connect as ws_connect  # noqa: E402

PROJECT_ID = "tbrain-platform-7fc1f"
FIREBASE_WEB_API_KEY = "AIzaSyCOybTP4r9J2bWXiJvXY0MQBFvaYDo_iWU"
SCOPE = "sync_admin"


def _die(msg: str, code: int = 1):
    print(f"tnode-delegate: {msg}", file=sys.stderr)
    sys.exit(code)


def _config_path() -> pathlib.Path:
    home = os.environ.get("OPENCLAW_HOME")
    base = pathlib.Path(home) if home else pathlib.Path.home() / ".openclaw"
    return base / "tnode-chat-sync.json"


def _load_cfg() -> dict:
    path = _config_path()
    try:
        cfg = json.loads(path.read_text())
    except FileNotFoundError:
        _die(f"config_not_found: {path}")
    except json.JSONDecodeError:
        _die(f"config_invalid_json: {path}")
    for k in ("nodeId", "nodeSecret", "mintUrl"):
        if not cfg.get(k):
            _die(f"config_missing_{k}: {path}")
    return cfg


def _curl_post(url: str, body: dict, bearer: str | None = None) -> dict:
    """POST JSON via curl (system-python-TLS safe). Returns the parsed JSON."""
    cmd = ["curl", "-sS", "--max-time", "30", "-X", "POST", url,
           "-H", "Content-Type: application/json"]
    if bearer:
        cmd += ["-H", f"Authorization: Bearer {bearer}"]
    cmd += ["--data-binary", json.dumps(body)]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(f"curl_failed: {out.stderr.strip()[:200]}")
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        raise RuntimeError(f"non_json_response: {out.stdout[:200]}")


def _mint(cfg: dict) -> dict:
    """HMAC(nodeSecret) → mintUrl → customToken → idToken (clones chat-sync)."""
    ts = str(int(time.time() * 1000))
    nonce = os.urandom(16).hex()
    signing = f'{cfg["nodeId"]}:{ts}:{nonce}:{SCOPE}'
    mac = hmac.new(
        cfg["nodeSecret"].encode("utf-8"),
        signing.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    mint = _curl_post(cfg["mintUrl"], {
        "nodeId": cfg["nodeId"],
        "timestamp": ts,
        "nonce": nonce,
        "signature": mac,
        "scope": SCOPE,
    })
    if "customToken" not in mint:
        raise RuntimeError(f"mint_no_custom_token: {json.dumps(mint)[:200]}")
    api_key = cfg.get("webApiKey") or FIREBASE_WEB_API_KEY
    ex = _curl_post(
        "https://identitytoolkit.googleapis.com/v1/accounts"
        f":signInWithCustomToken?key={api_key}",
        {"token": mint["customToken"], "returnSecureToken": True},
    )
    return {
        "idToken": ex["idToken"],
        "uid": mint["uid"],
        "nodeId": mint["nodeId"],
    }


def _fs_str(field) -> str | None:
    return field.get("stringValue") if isinstance(field, dict) else None


def _fs_bool(field) -> bool:
    return bool(field.get("booleanValue")) if isinstance(field, dict) else False


def _list_peers(token: dict) -> dict:
    """Read users/{uid}/nodes/{nodeId}/peers/ → {alias: {targetNodeId, domain,
    role, enabled}}."""
    parent = f"users/{token['uid']}/nodes/{token['nodeId']}"
    url = (
        f"https://firestore.googleapis.com/v1/projects/{PROJECT_ID}"
        f"/databases/(default)/documents/{parent}:runQuery"
    )
    rows = _curl_post(
        url,
        {"structuredQuery": {"from": [{"collectionId": "peers"}]}},
        bearer=token["idToken"],
    )
    if isinstance(rows, dict):
        rows = [rows]
    peers: dict = {}
    for row in rows:
        doc = row.get("document") if isinstance(row, dict) else None
        if not doc:
            continue
        f = doc.get("fields", {})
        tid = _fs_str(f.get("targetNodeId")) or doc.get("name", "").split("/")[-1]
        domain = _fs_str(f.get("domain"))
        if not domain:
            continue
        alias = _fs_str(f.get("alias")) or tid
        peers[alias] = {
            "targetNodeId": tid,
            "domain": domain,
            "role": _fs_str(f.get("role")) or "",
            "enabled": _fs_bool(f.get("enabled")),
        }
    return peers


def _delegate_once(token: dict, peer: dict, text: str, timeout_s: int) -> str:
    """Open B's /transport WS, send the turn, return the agent's final reply.

    Raises RuntimeError on transport error or an empty reply (a cold gateway
    can ack a turn then close it with 0 deltas — the caller retries)."""
    url = f"wss://{peer['domain']}/transport?token={token['idToken']}"
    session_key = f"tnode-mobile-deleg-{token['nodeId']}"
    ws = ws_connect(url, open_timeout=20)
    q: "queue.Queue[str]" = queue.Queue()

    def reader():
        try:
            for m in ws:
                q.put(m)
        except Exception as e:  # noqa: BLE001
            q.put(json.dumps({"type": "__readerr__", "e": str(e)}))

    threading.Thread(target=reader, daemon=True).start()
    ws.send(json.dumps({
        "type": "turn",
        "text": text,
        "sessionKey": session_key,
        "clientMsgId": uuid.uuid4().hex,
    }))

    deadline = time.time() + timeout_s
    final = None
    err = None
    while time.time() < deadline:
        try:
            m = q.get(timeout=max(0.2, deadline - time.time()))
        except queue.Empty:
            break
        try:
            fr = json.loads(m)
        except Exception:  # noqa: BLE001
            continue
        t = fr.get("type")
        if t == "done":
            final = fr.get("text") or ""
            break
        if t == "error":
            err = str(fr.get("message"))
            break
        if t == "__readerr__":
            err = str(fr.get("e"))
            break
    try:
        ws.close()
    except Exception:  # noqa: BLE001
        pass
    if final:
        return final
    raise RuntimeError(err or "empty_reply (peer cold or no LLM credit?)")


def main() -> int:
    ap = argparse.ArgumentParser(prog="tnode-delegate")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list", help="Lista los nodos enlazados a los que puedes delegar.")
    d = sub.add_parser("delegate", help="Delega una tarea a un peer e imprime su respuesta.")
    d.add_argument("--alias", required=True)
    d.add_argument("--text", required=True)
    d.add_argument("--timeout", type=int, default=120)
    args = ap.parse_args()

    cfg = _load_cfg()
    token = _mint(cfg)
    peers = _list_peers(token)

    if args.cmd == "list":
        if not peers:
            print("No hay nodos enlazados. Enlaza uno en el widget Equipo de la app.")
            return 0
        for alias, p in sorted(peers.items()):
            state = "activo" if p.get("enabled") else "inactivo"
            role = f" — {p['role']}" if p.get("role") else ""
            print(f"{alias} ({state}){role}")
        return 0

    peer = peers.get(args.alias)
    if peer is None:
        known = ", ".join(sorted(peers)) or "(ninguno)"
        _die(f"unknown_peer_alias: '{args.alias}'. Conocidos: {known}", 4)

    # Cold-start retry: the first turn after a gateway plugin reload can come
    # back with 0 deltas; a second attempt on the warmed gateway succeeds.
    last_err = None
    for attempt in (1, 2):
        try:
            print(_delegate_once(token, peer, args.text, args.timeout))
            return 0
        except Exception as e:  # noqa: BLE001
            last_err = e
            if attempt == 1:
                time.sleep(2)
    _die(f"delegation_failed alias='{args.alias}': {last_err}", 5)


if __name__ == "__main__":
    sys.exit(main())
'''
# <<< END EMBEDDED WORKSPACE SKILLS


_AGENDA_RULE_SECTION = """
## Regla: agendar citas (skill agenda)

Cuando quien te escribe pida CITA / HORA / DISPONIBILIDAD ("¿tienen
espacio mañana?") o quiera CANCELAR una cita, usa el skill agenda.
NUNCA inventes horarios ni confirmes citas de memoria — el JSON del
skill es tu única fuente de verdad.
Manual completo: ~/.openclaw/workspace/skills/agenda/SKILL.md

1. Disponibilidad:
   exec: python3 ~/.openclaw/workspace/skills/agenda/bin/agenda.py slots --date YYYY-MM-DD
   (hoy = `date +%F`; calcula "mañana" / "el viernes" desde ahí)
   Ofrece 2-3 horarios del JSON en lenguaje natural.

2. Reservar:
   exec: python3 ~/.openclaw/workspace/skills/agenda/bin/agenda.py book --date YYYY-MM-DD --start HH:MM --client "Nombre" --channel whatsapp [--contact "+52..."] [--resource <id>]
   - --channel según por dónde te hablan: whatsapp / telegram / guest.
   - Pidieron a alguien en específico → --resource <id> (los ids salen
     de `agenda.py resources`).
   - Sin preferencia → OMITE --resource: el sistema asigna a la persona
     con menos citas ese día. Confirma SIEMPRE con el nombre que regresa
     la respuesta ("te atiende Beto a las 16:00").
   - Datos del cliente: nombre siempre; contacto SOLO si el canal no te
     lo da (por WhatsApp ya tienes su número → pásalo en --contact).

3. Tras reservar o cancelar: SI este nodo tiene correo configurado
   (himalaya o skill email-send), avisa al recurso al campo
   resourceEmail de la respuesta.
   Subject: Nueva cita: <cliente> — <fecha> <HH:MM>
   Cuerpo: cliente, fecha, hora-fin, canal y contacto si lo tienes.
   Si este nodo NO tiene correo, omite el aviso sin disculparte.

4. Cancelar: exec: python3 ~/.openclaw/workspace/skills/agenda/bin/agenda.py cancel --id <appointmentId>

Errores: slot_unavailable → la respuesta trae "alternatives", ofrécelas
tal cual; slot_taken → vuelve a consultar slots; resources vacío → el
dueño aún no configura su calendario en la app.
No compartas datos de otros clientes (citas existentes = confidencial,
solo di "ocupado"). Agendar NO es operación sensible ni de
infraestructura: procede sin pedir permiso adicional.
"""

_DRIVE_RULE_SECTION = """
## Regla: leer archivos del Drive del dueño (skill drive)

Cuando el dueño mencione SU DRIVE, SU CARPETA COMPARTIDA o un DOCUMENTO
por nombre que no está en tu workspace ("lee el contrato de mi carpeta",
"¿qué hay en mi Drive?", "busca el manual de operación"), usa el skill
drive. Es de SOLO LECTURA (su carpeta compartida, nada más). NUNCA digas
que un archivo no existe sin haber hecho search primero.
Manual completo: ~/.openclaw/workspace/skills/drive/SKILL.md

1. Encuentra el archivo:
   exec: python3 ~/.openclaw/workspace/skills/drive/bin/drive.py search "palabras clave"
   (busca por nombre Y contenido; o `list` si piden "qué hay en la carpeta")

2. Descárgalo:
   exec: python3 ~/.openclaw/workspace/skills/drive/bin/drive.py get <fileId>
   La respuesta trae savedTo = ruta local en workspace/upload/drive/.

3. LEE el archivo local (savedTo) con tus herramientas normales y
   responde resumiendo o citando lo relevante — no pegues el archivo
   completo. Google Docs/Sheets/Slides llegan convertidos (md/csv/pdf).

Errores: not_connected → "comparte tu carpeta en la app: tu nodo →
Archivos → Carpeta compartida"; access_revoked → pídele re-compartir;
not_found / not_in_folder → no está en SU carpeta compartida (solo ves
esa carpeta), sugiérele moverlo ahí; too_large → pasa de 50 MB.

Si el archivo cambió en Drive, descárgalo de nuevo (tu copia es local).
Con invitados usa criterio: la carpeta es del dueño, no compartas
contenido sensible salvo que el dueño lo haya pedido. Leer su carpeta NO
es operación sensible: procede sin pedir permiso adicional.
"""

# v1.1: las reglas de agenda/drive (y anti-loop/aviso/email) ahora las compone
# el SERVIDOR (functions/src/tools_sync.ts) dentro de la zona gestionada del
# TOOLS.md; el daemon solo renderiza ese JSON por hash. _ensure_tools_rules
# (que las appendeaba fuera de los markers) quedó retirado — ver
# _migrate_tools_v11, que limpia las copias viejas una vez. Las constantes
# _AGENDA_RULE_SECTION / _DRIVE_RULE_SECTION quedan solo como referencia.


def _ensure_workspace_skill(name: str, files: dict) -> None:
    """Materialize one canonical workspace skill. Self-healing: a file
    that drifted from the canonical copy is rewritten on every boot; an
    identical file is left untouched (no mtime churn)."""
    skill_dir = OPENCLAW_DIR / "workspace" / "skills" / name
    try:
        (skill_dir / "bin").mkdir(parents=True, exist_ok=True)
        for rel, content in files.items():
            dest = skill_dir / rel
            try:
                if dest.is_file() and dest.read_text(encoding="utf-8") == content:
                    continue
            except Exception:  # noqa: BLE001
                pass  # unreadable/binary drift → rewrite below
            dest.write_text(content, encoding="utf-8")
            if rel.endswith(".py"):
                try:
                    os.chmod(dest, 0o755)
                except OSError:
                    pass
    except Exception as e:  # noqa: BLE001
        _log(f"_ensure_workspace_skill {name}: {e}")


def _ensure_workspace_skills() -> None:
    """agenda + drive + poll + tnode-delegate on every node (startup self-heal)."""
    _ensure_workspace_skill("agenda", {
        "SKILL.md": _AGENDA_SKILL_MD,
        "manifest.json": _AGENDA_MANIFEST,
        "bin/agenda.py": _AGENDA_PY,
    })
    _ensure_workspace_skill("drive", {
        "SKILL.md": _DRIVE_SKILL_MD,
        "manifest.json": _DRIVE_MANIFEST,
        "bin/drive.py": _DRIVE_PY,
    })
    _ensure_workspace_skill("poll", {
        "SKILL.md": _POLL_SKILL_MD,
        "manifest.json": _POLL_MANIFEST,
        "bin/poll.py": _POLL_PY,
    })
    _ensure_workspace_skill("tnode-delegate", {
        "SKILL.md": _TNODE_DELEGATE_SKILL_MD,
        "manifest.json": _TNODE_DELEGATE_MANIFEST,
        "bin/tnode-delegate.py": _TNODE_DELEGATE_PY,
    })


# ── Guest agent (Opción B: per-guest isolation) ──────────────────────────
# Invite-link visitors ("guests") run on a DEDICATED `guest` agent with its
# own NEUTRAL workspace, so they never load the owner's main workspace
# (USER.md/MEMORY.md/memory) — the root cause of the owner-identity leak.
# tnode-chat-sync routes `tnode-guest-*` sessions to this agent via the
# `agent:guest:` sessionKey prefix (the gateway honors it). The workspace is
# STATIC + neutral (warm business-attention, NO owner PII); the per-node /
# per-guest identity is injected at runtime by the tbrain-context-engine
# plugin (before_prompt_build). Model inherits the node default (no override).
_GUEST_WS_DIR = OPENCLAW_DIR / "workspace-guest"
_GUEST_AGENT_DIR = _AGENTS_DIR / "guest" / "agent"

# Guard-rails Layer 1 (#2.2): per-agent deny floor for ALL guests. Blocks the
# tools that could reach the OWNER's system/data (the guest runs with the node's
# owner-scoped creds + sandbox off): shell, filesystem, session/subagent
# control, channel messaging, canvas, and browser (SSRF). Leaves public-facing
# tools (web_search/web_fetch/image_generate/tts/huggingface). Per-link
# refinement is layered on top by the context-engine before_tool_call hook.
_GUEST_TOOLS_DENY = [
    "exec", "process",
    "read", "write", "edit", "file_write", "file_fetch", "dir_list", "dir_fetch",
    # P3 (#2.2): sessions_spawn/sessions_send LIFTED from the floor — delegation is
    # now gated per-link by the context-engine hook (guardRails.allowedAgents),
    # default-deny. Session introspection stays denied (no enumerating sessions).
    "sessions_list", "sessions_history",
    "sessions_yield", "session_status", "subagents", "agents_list",
    "message", "canvas", "browser",
    # P5: raw wiki tools blocked for all guests; kb_search (context-engine) is
    # the gated replacement — only available when allowedDocRefs is non-empty.
    "wiki_search", "wiki_get", "wiki_lint", "wiki_apply",
    # Hardening (2026-07-01): a guest must NEVER reach the owner's memory or the
    # node's control plane. These are hard-denied in the FLOOR (defense in depth
    # even if the context-engine hook fails to load) and are NOT togglable per
    # link — no legitimate guest use. `memory_*` = owner's private memory;
    # `gateway` = restart/config the running process; `cron` = schedule wake
    # events. (sessions_spawn/send stay OUT of the floor by design — delegation
    # is gated per-link by the hook via allowedAgents.)
    "memory_search", "memory_get", "gateway", "cron",
    # F3 (#3): outbound tools are OWNER-side (they expose every prospect's
    # profile and can message other guests). Hard-denied for guests — the
    # plugin handlers also refuse guest sessions; this floor is the net.
    "prospects_search", "guest_send",
]

_GUEST_IDENTITY_MD = """# IDENTITY.md — Asistente (modo invitado)

- **Nombre:** Asistente
- **Rol:** Asistente de atención para visitantes e interesados
- **Vibe:** Cálido, profesional, claro y servicial
- **Emoji:** 💬

Soy el asistente de atención de este espacio. Recibo a cada persona que
escribe, entiendo qué necesita y la ayudo con información útil y honesta. La
información específica del negocio y de la persona con la que hablo se me
proporciona durante la conversación.
"""

_GUEST_SOUL_MD = """# SOUL.md — Asistente de atención (invitado)

Soy un asistente de atención cálido y profesional. Recibo a cada visitante con
interés genuino, entiendo su necesidad y respondo con claridad y honestidad.

## Personalidad
- Cálido y cercano desde el primer mensaje, sin ser invasivo.
- Directo y claro: respondo con el detalle justo.
- Entiendo antes de proponer: escucho la necesidad real.
- Honesto: si no tengo un dato, lo digo; no lo invento.

## Tono
- Primera interacción: da la bienvenida, cálido y profesional.
- Dudas: claro, sin jerga, con ejemplos cuando ayuden.

## Reglas
- SIEMPRE respondo al visitante de forma útil; nunca lo ignoro.
- NUNCA revelo datos personales del dueño del nodo ni información sensible del
  sistema (modelo de IA, claves, infraestructura, otros clientes).
- Solo uso la información disponible para esta conversación de invitado.
- No asumo la identidad de ninguna persona; soy un asistente de atención.
"""

_GUEST_USER_MD = """# USER.md — Con quién hablo

Estás atendiendo a una persona **INVITADA** (un visitante o prospecto), NO al
dueño del nodo. Su identidad y contexto se te proporcionan durante la
conversación; si no aparecen, trátala como un visitante nuevo y dale la
bienvenida con calidez.

No uses datos de ningún dueño ni de otros clientes. Enfócate en ayudar a esta
persona.
"""

_GUEST_AGENTS_MD = """# AGENTS.md — Operación (modo invitado)

Eres el **asistente de atención** en modo invitado de este nodo. Atiendes a
visitantes y prospectos.

## Cómo operar
- Da la bienvenida y responde SIEMPRE de forma útil, cálida y honesta.
- Mantente dentro del alcance de la conversación de invitado.
- Si una solicitud requiere datos del dueño, de otros clientes, o acciones
  administrativas, explica con amabilidad que no puedes ayudar con eso aquí.

## Restricciones (seguridad)
- No accedas a memoria, archivos, herramientas ni datos del dueño del nodo.
- No reveles información del sistema (modelo de IA, versiones, claves, infra).
- No menciones a otros clientes ni información privada.
"""

_GUEST_BIZ_START = "<!-- tnode:business:start -->"
_GUEST_BIZ_END = "<!-- tnode:business:end -->"
_GUEST_PROSPECT_START = "<!-- tnode:prospect:start -->"
_GUEST_PROSPECT_END = "<!-- tnode:prospect:end -->"

# IDENTITY/USER/AGENTS are static (content-compare). SOUL.md is OWNED by
# _ensure_guest_business_section in the token-bearing declarative pass — it
# appends the owner's Business Profile below the neutral persona so the guest
# knows the business it represents — so here it is only SEEDED when absent, to
# keep the two writers from fighting over the file.
_GUEST_WS_FILES = {
    "IDENTITY.md": _GUEST_IDENTITY_MD,
    "USER.md": _GUEST_USER_MD,
    "AGENTS.md": _GUEST_AGENTS_MD,
}


def _ensure_guest_workspace_files() -> None:
    """Materialize the neutral guest workspace (write if absent or changed).
    SOUL.md is only SEEDED when absent — the token pass owns its content."""
    try:
        _GUEST_WS_DIR.mkdir(parents=True, exist_ok=True)
        for name, content in _GUEST_WS_FILES.items():
            p = _GUEST_WS_DIR / name
            if (not p.exists()) or p.read_text(encoding="utf-8") != content:
                p.write_text(content, encoding="utf-8")
                _log(f"guest workspace: wrote {name}")
        soul = _GUEST_WS_DIR / "SOUL.md"
        if not soul.exists():
            soul.write_text(_GUEST_SOUL_MD, encoding="utf-8")
            _log("guest workspace: seeded SOUL.md")
    except Exception as e:  # noqa: BLE001
        _log(f"guest workspace materialize failed: {e}")


def _firestore_get_business_profile(token: dict) -> dict | None:
    """GET users/{uid}/nodes/{nodeId}/config/businessProfile (node-scoped).
    Returns the unwrapped fields, or None when the doc is absent/unreadable."""
    try:
        url = (
            f"{_firestore_base()}/users/{token['uid']}/nodes/{token['nodeId']}"
            f"/config/businessProfile"
        )
        doc = _http_request(
            "GET", url, headers={"Authorization": f"Bearer {token['idToken']}"}
        )
    except Exception:  # noqa: BLE001 — a 404 (no profile yet) lands here too
        return None
    fields = doc.get("fields") if isinstance(doc, dict) else None
    if not fields:
        return None
    return {k: _fs_unwrap(v) for k, v in fields.items()}


def _render_guest_business_block(profile: dict | None) -> str:
    """'## Sobre el negocio' markdown from the non-empty (NON-PII) fields. Empty
    string when there is no meaningful profile (no name/type). Mirrors the CF
    buildUserDoc block so the guest and the owner agent describe the business
    the same way."""
    if not profile:
        return ""

    def _s(key: str) -> str:
        v = profile.get(key)
        return v.strip() if isinstance(v, str) else ""

    name = _s("name")
    typ = _s("type")
    if not name and not typ:
        return ""
    lines = [
        "## Sobre el negocio",
        "",
        "Atiendes a clientes de este negocio. Úsalo para responder y orientar; "
        "si te falta un dato, dilo con honestidad.",
        "",
    ]
    if name:
        lines.append(f"- Nombre: {name}")
    if typ:
        lines.append(f"- Giro: {typ}")
    if _s("description"):
        lines.append(f"- Descripción: {_s('description')}")
    if _s("city"):
        lines.append(f"- Ciudad: {_s('city')}")
    services = profile.get("services")
    if isinstance(services, list):
        svc = [s.strip() for s in services if isinstance(s, str) and s.strip()]
        if svc:
            lines.append(f"- Servicios: {', '.join(svc)}")
    if _s("hoursSummary"):
        lines.append(f"- Horario: {_s('hoursSummary')}")
    contact = " · ".join(x for x in (_s("publicPhone"), _s("publicEmail")) if x)
    if contact:
        lines.append(f"- Contacto: {contact}")
    if _s("publicAddress"):
        lines.append(f"- Dirección: {_s('publicAddress')}")
    return "\n".join(lines)


def _firestore_get_prospect_schema(token: dict) -> dict | None:
    """GET users/{uid}/nodes/{nodeId}/config/prospectSchema. None when absent."""
    try:
        url = (
            f"{_firestore_base()}/users/{token['uid']}/nodes/{token['nodeId']}"
            f"/config/prospectSchema"
        )
        doc = _http_request(
            "GET", url, headers={"Authorization": f"Bearer {token['idToken']}"}
        )
    except Exception:  # noqa: BLE001 — 404 (no schema yet) lands here
        return None
    fields = doc.get("fields") if isinstance(doc, dict) else None
    if not fields:
        return None
    return {k: _fs_unwrap(v) for k, v in fields.items()}


def _render_guest_prospect_block(schema: dict | None) -> str:
    """'## Perfilamiento del visitante' instructions for the guest agent.

    The FIXED core (likes/dislikes/indifferent/problems) renders ALWAYS —
    the guest must track it on every node, schema or not (tobal 2026-07-02).
    Owner-defined aspects render only when a prospectSchema doc exists with
    active aspects. Mirrors `prospect_update` (context-engine >=0.9.0)."""
    lines = [
        "## Perfilamiento del visitante",
        "",
        "Mientras conversas, registra lo que aprendas del visitante con la",
        "tool prospect_update, EN CUANTO detectes el dato (una llamada por",
        "dato). Hazlo en silencio: no anuncies que lo registras ni",
        "interrogues al visitante; los datos salen de la plática natural.",
        "",
        "SIEMPRE mantén al día estas 4 listas (parámetros list + item):",
        "- likes: lo que le gusta o valora",
        "- dislikes: lo que NO le gusta o le molesta",
        "- indifferent: lo que le es indiferente",
        "- problems: problemas que ha tenido (producto, servicio o en general)",
    ]
    aspects = []
    if schema and schema.get("enabled") is not False:
        raw = schema.get("aspects")
        if isinstance(raw, list):
            for a in raw:
                if not isinstance(a, dict) or a.get("active") is False:
                    continue
                key = str(a.get("key") or "").strip()
                label = str(a.get("label") or key).strip()
                if not key:
                    continue
                extra = []
                opts = a.get("options")
                if isinstance(opts, list):
                    ov = [str(o).strip() for o in opts if str(o).strip()]
                    if ov:
                        extra.append(f"opciones: {', '.join(ov)}")
                typ = str(a.get("type") or "").strip()
                if typ == "scale":
                    extra.append("escala 1-5")
                hint = str(a.get("hint") or "").strip()
                if hint:
                    extra.append(hint)
                suffix = f" ({'; '.join(extra)})" if extra else ""
                aspects.append(f"- {key}: {label}{suffix}")
    if aspects:
        lines += [
            "",
            "Aspectos del negocio (parámetros field + value; usa la clave tal",
            "cual):",
            *aspects,
        ]
    return "\n".join(lines)


def _ensure_guest_business_section(token: dict) -> None:
    """Render the owner's Business Profile into the guest workspace SOUL.md so
    the GUEST agent knows the business it represents (e.g. a taller mecánico)
    instead of confabulating. Writes the '## Sobre el negocio' block between
    markers, appended to the neutral persona. Idempotent (content-compare);
    empty markers when no profile. Token-bearing (the read needs a mint)."""
    try:
        block = _render_guest_business_block(
            _firestore_get_business_profile(token)
        )
        zone = (
            f"{_GUEST_BIZ_START}\n{block}\n{_GUEST_BIZ_END}"
            if block
            else f"{_GUEST_BIZ_START}\n{_GUEST_BIZ_END}"
        )
        prospect_block = _render_guest_prospect_block(
            _firestore_get_prospect_schema(token)
        )
        prospect_zone = (
            f"{_GUEST_PROSPECT_START}\n{prospect_block}\n{_GUEST_PROSPECT_END}"
        )
        expected = (
            _GUEST_SOUL_MD.rstrip()
            + "\n\n" + zone + "\n\n" + prospect_zone + "\n"
        )
        _GUEST_WS_DIR.mkdir(parents=True, exist_ok=True)
        p = _GUEST_WS_DIR / "SOUL.md"
        if (not p.exists()) or p.read_text(encoding="utf-8") != expected:
            p.write_text(expected, encoding="utf-8")
            _log(
                "guest workspace: business section "
                f"{'set' if block else 'cleared'} + prospect section in SOUL.md"
            )
    except Exception as e:  # noqa: BLE001
        _log(f"guest business section failed: {e}")


def _ensure_guest_agent() -> bool:
    """Ensure the dedicated `guest` agent exists in openclaw.json (Opción B).

    Idempotent startup self-heal: materializes the neutral workspace and
    inserts the agents.list entry if missing. Model inherits the node default
    (no per-agent override); sandbox off. Returns True if openclaw.json
    changed. The gateway hot-reloads agents.list, so no restart is needed."""
    _ensure_guest_workspace_files()
    if not OPENCLAW_JSON_PATH.exists():
        return False
    try:
        cfg = json.loads(OPENCLAW_JSON_PATH.read_text())
    except Exception as e:  # noqa: BLE001
        _log(f"guest agent: openclaw.json unreadable ({e})")
        return False
    agents_section = cfg.setdefault("agents", {})
    if not isinstance(agents_section, dict):
        return False
    agents_list = agents_section.setdefault("list", [])
    if not isinstance(agents_list, list):
        return False
    changed = False
    # Materialize `main` explicitly too (same as the sub-agent path) so the
    # shape is consistent on a freshly-paired node.
    if not any(isinstance(a, dict) and a.get("id") == "main" for a in agents_list):
        agents_list.insert(0, {
            "id": "main",
            "default": True,
            "workspace": str(OPENCLAW_DIR / "workspace"),
            "agentDir": str(OPENCLAW_DIR / "agents" / "main" / "agent"),
        })
        changed = True
    guest_tools = {"deny": _GUEST_TOOLS_DENY}
    # P3 (#2.2): the shared `guest` agent may spawn the team roster (every agent
    # except main/guest) at the OpenClaw level; the before_tool_call hook then
    # gates each guest to its per-link guardRails.allowedAgents subset (default-deny).
    guest_roster = sorted(
        a["id"] for a in agents_list
        if isinstance(a, dict) and a.get("id")
        and a.get("id") not in ("main", "guest")
    )
    guest_idx = next(
        (i for i, a in enumerate(agents_list)
         if isinstance(a, dict) and a.get("id") == "guest"),
        None,
    )
    if guest_idx is None:
        agents_list.append({
            "id": "guest",
            "name": "Guest",
            "workspace": str(_GUEST_WS_DIR),
            "agentDir": str(_GUEST_AGENT_DIR),
            "sandbox": {"mode": "off"},
            "tools": guest_tools,
            "subagents": {"allowAgents": guest_roster},
        })
        changed = True
    else:
        g = agents_list[guest_idx]
        if g.get("tools") != guest_tools:
            # Enforce the guard-rails Layer-1 deny floor on an existing guest entry.
            g["tools"] = guest_tools
            changed = True
        if g.setdefault("subagents", {}).get("allowAgents") != guest_roster:
            g["subagents"]["allowAgents"] = guest_roster
            changed = True
    if not changed:
        return False
    serialized = json.dumps(cfg, indent=2) + "\n"
    if OPENCLAW_JSON_PATH.read_text() == serialized:
        return False
    OPENCLAW_JSON_PATH.write_text(serialized)
    _log("guest agent: ensured agents.list entry (Opción B)")
    return True


# _ensure_tools_rules() retirado en v1.1 — las reglas (agenda/drive/anti-loop/
# aviso/email) las compone el servidor (tools_sync.ts) y _migrate_tools_v11
# limpia las copias viejas que vivían fuera de los markers.


# ── TOOLS.md renderer (zona gestionada, compuesta por el servidor) ──
# La CF tnodeConfigSyncTools + su trigger componen un JSON declarativo de
# la ZONA GESTIONADA del TOOLS.md y lo cachean en el doc del nodo
# (toolsJson + toolsHash). Aquí SOLO renderizamos esa zona entre markers,
# comparando el hash para no reescribir si nada cambió. Todo lo de fuera de
# los markers (agenda/drive de _ensure_tools_rules, reglas custom del
# usuario) se preserva. Patrón base para el resto de los .md.
_TOOLS_ZONE_START = "<!-- tnode:tools:start -->"
_TOOLS_ZONE_END = "<!-- tnode:tools:end -->"
_TOOLS_HASH_PATH = OPENCLAW_DIR / ".tnode-tools-hash"

# Fallback resiliente del golden: un nodo recién nacido (sin MCPs → sin
# toolsJson) nace con la zona gestionada conteniendo solo la Regla 0, para
# que el agente tenga la guía MCP-first desde el arranque aunque la CF no
# haya compuesto nada todavía. La CF la re-provee (idéntica) cuando hay
# cambios y el render reemplaza la zona. Mantener en sync con tools_sync.ts.
_TOOLS_REGLA_0 = """## Regla 0 - Herramienta especifica antes que el navegador (CRITICO)

Antes de abrir el navegador (browser) o usar web_search, revisa si tienes una
herramienta ESPECIFICA para la tarea y usala primero. El navegador y web_search
son SOLO el ultimo recurso (fallback), cuando NINGUNA herramienta especifica aplica."""


def _tools_golden_base() -> str:
    return f"# TOOLS.md\n\n{_TOOLS_ZONE_START}\n{_TOOLS_REGLA_0}\n{_TOOLS_ZONE_END}\n"


def _read_local_tools_hash() -> str:
    try:
        return _TOOLS_HASH_PATH.read_text(encoding="utf-8").strip()
    except Exception:  # noqa: BLE001
        return ""


def _write_local_tools_hash(value: str) -> None:
    try:
        _TOOLS_HASH_PATH.write_text(value, encoding="utf-8")
    except Exception as e:  # noqa: BLE001
        _log(f"tools-sync: hash write failed: {e}")


# Pass-scoped cache of node-doc fields. The declarative sync block reads five
# hash fields per pass; priming them in ONE masked GET turns 5+ reads into 1.
# None = not primed → _firestore_get_node_field falls back to its own per-field
# GET (callers outside the declarative pass are unaffected).
_NODE_FIELD_CACHE: dict | None = None


def _prime_node_fields(token: dict, fields: list) -> None:
    """One masked GET of all `fields` at once → cache for the current pass."""
    global _NODE_FIELD_CACHE
    try:
        mask = "&".join(f"mask.fieldPaths={f}" for f in fields)
        url = (
            f"{_firestore_base()}/users/{token['uid']}/nodes/{token['nodeId']}"
            f"?{mask}"
        )
        doc = _http_request(
            "GET", url, headers={"Authorization": f"Bearer {token['idToken']}"}
        )
        raw = doc.get("fields") or {}
        _NODE_FIELD_CACHE = {
            f: (_fs_unwrap(raw[f]) if f in raw else None) for f in fields
        }
    except Exception as e:  # noqa: BLE001
        _NODE_FIELD_CACHE = None  # priming failed → safe per-field fallback
        _log(f"prime-node-fields failed: {e}")


def _clear_node_fields_cache() -> None:
    global _NODE_FIELD_CACHE
    _NODE_FIELD_CACHE = None


def _firestore_get_node_field(token: dict, field: str):
    """GET a single masked field of the node doc (cheap). Served from the pass
    cache when primed (see _prime_node_fields) so the declarative sync block
    costs ONE read instead of one-per-field."""
    if _NODE_FIELD_CACHE is not None and field in _NODE_FIELD_CACHE:
        return _NODE_FIELD_CACHE[field]
    url = (
        f"{_firestore_base()}/users/{token['uid']}/nodes/{token['nodeId']}"
        f"?mask.fieldPaths={field}"
    )
    doc = _http_request(
        "GET", url, headers={"Authorization": f"Bearer {token['idToken']}"}
    )
    fields = doc.get("fields") or {}
    return _fs_unwrap(fields[field]) if field in fields else None


def _render_tools_zone(blocks: list) -> str:
    ordered = sorted(blocks, key=lambda b: b.get("order", 0))
    parts = [str(b.get("text", "")).strip() for b in ordered]
    return "\n\n".join(p for p in parts if p)


def _apply_tools_zone(zone_text: str) -> None:
    """Replace the content between the managed markers in workspace/TOOLS.md.
    Creates the markers (right after the title) if absent. Atomic write."""
    p = OPENCLAW_DIR / "workspace" / "TOOLS.md"
    text = p.read_text(encoding="utf-8") if p.is_file() else "# TOOLS.md\n"
    block = f"{_TOOLS_ZONE_START}\n{zone_text}\n{_TOOLS_ZONE_END}"
    if _TOOLS_ZONE_START in text and _TOOLS_ZONE_END in text:
        pre = text.split(_TOOLS_ZONE_START, 1)[0].rstrip()
        post = text.split(_TOOLS_ZONE_END, 1)[1].lstrip("\n")
        new = pre + "\n\n" + block + ("\n\n" + post if post.strip() else "\n")
    else:
        head, _, rest = text.partition("\n")
        new = head + "\n\n" + block + (
            "\n\n" + rest.lstrip("\n") if rest.strip() else "\n"
        )
    if new != text:
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(".tmp")
        tmp.write_text(new, encoding="utf-8")
        os.replace(tmp, p)


def _sync_tools_md_from_json(token: dict) -> None:
    """Render the managed zone of TOOLS.md from the node's cached toolsJson.
    Cheap hash check first; only rewrites on change. Resilient: any failure
    leaves the current TOOLS.md untouched. (v1.1: CF bootstrap for nodes that
    have no cache yet — today the golden ships Regla 0 inside the markers.)"""
    try:
        remote_hash = _firestore_get_node_field(token, "toolsHash")
    except Exception as e:  # noqa: BLE001
        _log(f"tools-sync: hash read failed: {e}")
        return
    if not remote_hash:
        # Bootstrap: nodo sin cache (golden recién nacido, sin MCPs/canales que
        # disparen el trigger). Forzamos UNA composición vía la CF para que el
        # agente nazca con todas las reglas estándar. Si falla, conservamos el
        # golden (Regla 0) y reintentamos al próximo arranque.
        resp = _bootstrap_tools_via_cf()
        if isinstance(resp, dict) and resp.get("ok"):
            _render_tools_from_resp(resp)
        return
    md = OPENCLAW_DIR / "workspace" / "TOOLS.md"
    if remote_hash == _read_local_tools_hash() and md.is_file():
        return  # sin cambios → no reescribir
    try:
        raw = _firestore_get_node_field(token, "toolsJson")
        doc = json.loads(raw) if raw else None
    except Exception as e:  # noqa: BLE001
        _log(f"tools-sync: json read/parse failed: {e}")
        return
    if not isinstance(doc, dict):
        return
    blocks = doc.get("blocks") or []
    try:
        _apply_tools_zone(_render_tools_zone(blocks))
        _write_local_tools_hash(remote_hash)
        _log(f"tools-sync: rendered {len(blocks)} blocks (hash {remote_hash[:12]})")
    except Exception as e:  # noqa: BLE001
        _log(f"tools-sync: render failed: {e}")


# ── v1.1: compose vía CF + reflejo de canales + migración one-time ──
TOOLS_SYNC_URL = os.environ.get(
    "TNODE_TOOLS_SYNC_URL",
    "https://us-central1-tbrain-platform-7fc1f.cloudfunctions.net/tnodeConfigSyncTools",
)
_CHANNELS_HASH_PATH = OPENCLAW_DIR / ".tnode-channels-hash"
_TOOLS_V11_SENTINEL = OPENCLAW_DIR / ".tnode-tools-v11-migrated"
_tools_bootstrap_attempted = False


def _compose_tools_via_cf() -> dict | None:
    """POST el endpoint HMAC para forzar que el servidor componga el TOOLS.md.
    Firma `${nodeId}:${ts}:${nonce}:tools:refresh` con nodeSecret (no necesita
    idToken). Devuelve la respuesta {ok, hash, doc}, o None si falla."""
    cfg = load_config()
    node_id = cfg.get("nodeId")
    node_secret = cfg.get("nodeSecret")
    if not node_id or not node_secret:
        return None
    ts = str(int(time.time() * 1000))
    nonce = os.urandom(16).hex()
    action = "refresh"
    sig = hmac.new(
        node_secret.encode("utf-8"),
        f"{node_id}:{ts}:{nonce}:tools:{action}".encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    body = json.dumps({
        "nodeId": node_id,
        "timestamp": ts,
        "nonce": nonce,
        "signature": sig,
        "action": action,
    }).encode("utf-8")
    try:
        req = urllib.request.Request(
            TOOLS_SYNC_URL,
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception as e:  # noqa: BLE001
        _log(f"tools-sync: CF compose failed: {e}")
        return None


def _bootstrap_tools_via_cf() -> dict | None:
    """Force-compose una sola vez por proceso, para un nodo fresco sin cache
    (sin MCPs/canales aún → ningún trigger disparó)."""
    global _tools_bootstrap_attempted
    if _tools_bootstrap_attempted:
        return None
    _tools_bootstrap_attempted = True
    return _compose_tools_via_cf()


def _render_tools_from_resp(resp: dict) -> bool:
    """Renderiza la zona gestionada desde una respuesta de compose + persiste
    el hash local."""
    doc = resp.get("doc") if isinstance(resp, dict) else None
    if not isinstance(doc, dict):
        return False
    try:
        _apply_tools_zone(_render_tools_zone(doc.get("blocks") or []))
        h = resp.get("hash") or ""
        if h:
            _write_local_tools_hash(h)
        _log(f"tools-sync: rendered {len(doc.get('blocks') or [])} blocks via CF")
        return True
    except Exception as e:  # noqa: BLE001
        _log(f"tools-sync: CF render failed: {e}")
        return False


def _strip_legacy_tools_sections(text: str) -> str:
    """Quita las secciones que ahora compone el servidor (anti-loop/aviso/email/
    agenda/drive) cuando viven FUERA de los markers; preserva la zona gestionada
    y cualquier sección custom (web-scraper/HEB, reglas del usuario)."""
    zone = ""
    pre, post = text, ""
    if _TOOLS_ZONE_START in text and _TOOLS_ZONE_END in text:
        pre = text.split(_TOOLS_ZONE_START, 1)[0]
        rest = text.split(_TOOLS_ZONE_START, 1)[1]
        zone_body = rest.split(_TOOLS_ZONE_END, 1)[0]
        post = rest.split(_TOOLS_ZONE_END, 1)[1]
        zone = f"{_TOOLS_ZONE_START}{zone_body}{_TOOLS_ZONE_END}"

    def _strip_chunk(chunk: str) -> str:
        lines = chunk.split("\n")
        out: list = []
        i, n = 0, len(lines)
        while i < n and not lines[i].startswith("## "):
            out.append(lines[i])
            i += 1
        while i < n:
            sec = [lines[i]]
            i += 1
            while i < n and not lines[i].startswith("## "):
                sec.append(lines[i])
                i += 1
            header = sec[0].strip().lower()
            body = "\n".join(sec)
            drop = (
                header.startswith("## regla anti-loop")
                or header.startswith("## regla de aviso")
                or header.startswith("## regla 4")
                or "skills/agenda/bin/agenda.py" in body
                or "skills/drive/bin/drive.py" in body
            )
            if not drop:
                out.extend(sec)
        return "\n".join(out)

    new_pre = _strip_chunk(pre).rstrip()
    new_post = _strip_chunk(post).strip()
    if zone:
        parts = [p for p in (new_pre, zone, new_post) if p]
        return "\n\n".join(parts) + "\n"
    return (new_pre + "\n") if new_pre else ""


def _migrate_tools_v11() -> None:
    """v1.1 one-time: fuerza al servidor a componer el TOOLS.md completo, lo
    renderiza en la zona gestionada, y luego quita las copias viejas de esas
    secciones que viven FUERA de los markers (para que no se dupliquen). Las
    secciones custom se preservan. Backup de TOOLS.md una vez. SOLO quita
    después de un compose+render exitoso → sin gap si la CF no responde
    (reintenta al próximo arranque)."""
    if _TOOLS_V11_SENTINEL.exists():
        return
    resp = _compose_tools_via_cf()
    if not (isinstance(resp, dict) and resp.get("ok")):
        return  # CF inalcanzable / no pareado → reintenta, no quita nada aún
    if not _render_tools_from_resp(resp):
        return
    p = OPENCLAW_DIR / "workspace" / "TOOLS.md"
    try:
        text = p.read_text(encoding="utf-8") if p.is_file() else ""
        if text:
            new = _strip_legacy_tools_sections(text)
            if new != text:
                bak = p.with_name("TOOLS.md.bak-pre-v1.1")
                if not bak.exists():
                    bak.write_text(text, encoding="utf-8")
                tmp = p.with_suffix(".tmp")
                tmp.write_text(new, encoding="utf-8")
                os.replace(tmp, p)
                _log("tools-migrate: stripped legacy sections outside markers")
        _TOOLS_V11_SENTINEL.write_text("done", encoding="utf-8")
    except Exception as e:  # noqa: BLE001
        _log(f"tools-migrate: {e}")


# ── SOUL.md / IDENTITY.md renderer (zonas gestionadas estáticas) ──
# Mismo patrón declarativo que TOOLS.md, pero el servidor compone zonas
# ESTÁTICAS (operativa sub-agentes/archivos/entregables en SOUL; rol
# coordinador en IDENTITY). El email NO va aquí (TOOLS.md Regla 4 lo cubre).
# Sin triggers: el daemon compone vía el endpoint HMAC genérico
# tnodeConfigSyncMd en la migración/bootstrap. Markers appendeados AL FINAL
# (preservando la personalidad curada de arriba). A diferencia de TOOLS.md,
# NO creamos el archivo si no existe: SOUL.md/IDENTITY.md son del agente
# (OpenClaw los siembra) — solo renderizamos en archivos ya presentes.
MD_SYNC_URL = os.environ.get(
    "TNODE_MD_SYNC_URL",
    "https://us-central1-tbrain-platform-7fc1f.cloudfunctions.net/tnodeConfigSyncMd",
)

_MD_TARGETS = {
    "soul": {
        "md_name": "SOUL.md",
        "zone_start": "<!-- tnode:soul:start -->",
        "zone_end": "<!-- tnode:soul:end -->",
        "hash_path": OPENCLAW_DIR / ".tnode-soul-hash",
        "hash_field": "soulHash",
        "json_field": "soulJson",
        "sentinel": OPENCLAW_DIR / ".tnode-soul-v2-migrated",
        "backup_name": "SOUL.md.bak-pre-v2",
        # Headers (lowercased) de las secciones que el daemon appendeaba antes y
        # que la migración quita de FUERA de los markers. Incluye las 2 de email
        # (himalaya / email-send): en v1.20.0 salieron de SOUL del todo —
        # TOOLS.md Regla 4 las cubre.
        "legacy_headers": (
            "## sub-agentes disponibles",
            "## envío de archivos al chat",
            "## entregables descargables",
            "## email del usuario",
            "## envío de correos",
        ),
    },
    "identity": {
        "md_name": "IDENTITY.md",
        "zone_start": "<!-- tnode:identity:start -->",
        "zone_end": "<!-- tnode:identity:end -->",
        "hash_path": OPENCLAW_DIR / ".tnode-identity-hash",
        "hash_field": "identityHash",
        "json_field": "identityJson",
        "sentinel": OPENCLAW_DIR / ".tnode-identity-v2-migrated",
        "backup_name": "IDENTITY.md.bak-pre-v2",
        "legacy_headers": (
            "## sub-agentes a tu disposición",
        ),
    },
    "user": {
        # Perfil del DUEÑO (capturado en la app → users/{uid}.profile, compuesto
        # por la CF). A diferencia de soul/identity va AL INICIO del USER.md
        # (position=start), preservando el contenido curado de abajo.
        "md_name": "USER.md",
        "zone_start": "<!-- tnode:user:start -->",
        "zone_end": "<!-- tnode:user:end -->",
        "hash_path": OPENCLAW_DIR / ".tnode-user-hash",
        "hash_field": "userHash",
        "json_field": "userJson",
        "sentinel": OPENCLAW_DIR / ".tnode-user-v2-migrated",
        "backup_name": "USER.md.bak-pre-profile",
        "legacy_headers": (),
        "position": "start",
    },
}

_md_bootstrap_attempted: dict = {}


def _md_read_local_hash(target: str) -> str:
    try:
        return _MD_TARGETS[target]["hash_path"].read_text(encoding="utf-8").strip()
    except Exception:  # noqa: BLE001
        return ""


def _md_write_local_hash(target: str, value: str) -> None:
    try:
        _MD_TARGETS[target]["hash_path"].write_text(value, encoding="utf-8")
    except Exception as e:  # noqa: BLE001
        _log(f"md-sync[{target}]: hash write failed: {e}")


def _md_apply_zone(target: str, zone_text: str) -> bool:
    """Replace the content between the managed markers in workspace/<md>,
    APPENDING the zone at the END (after the curated personality) when the
    markers are absent. Returns False (and does nothing) when the file does
    NOT exist — we never create SOUL/IDENTITY, they belong to the agent.
    Atomic write."""
    desc = _MD_TARGETS[target]
    p = OPENCLAW_DIR / "workspace" / desc["md_name"]
    if not p.is_file():
        return False
    start, end = desc["zone_start"], desc["zone_end"]
    text = p.read_text(encoding="utf-8")
    block = f"{start}\n{zone_text}\n{end}"
    if start in text and end in text:
        pre = text.split(start, 1)[0].rstrip()
        post = text.split(end, 1)[1].lstrip("\n")
        new = pre + "\n\n" + block + ("\n\n" + post if post.strip() else "\n")
    elif desc.get("position") == "start":
        # Insertar AL INICIO: justo después del primer encabezado H1 (# …) si
        # existe, preservando el contenido curado debajo (USER.md).
        if text.lstrip().startswith("# "):
            nl = text.index("\n") if "\n" in text else len(text)
            head, rest = text[:nl], text[nl + 1:].lstrip("\n")
            new = head + "\n\n" + block + ("\n\n" + rest if rest.strip() else "\n")
        else:
            new = block + ("\n\n" + text.lstrip("\n") if text.strip() else "\n")
    else:
        base = text.rstrip()
        new = (base + "\n\n" + block + "\n") if base else (block + "\n")
    if new != text:
        tmp = p.with_name(p.name + ".tmp")
        tmp.write_text(new, encoding="utf-8")
        os.replace(tmp, p)
    return True


def _md_compose_via_cf(target: str) -> dict | None:
    """POST the generic HMAC endpoint to force the server to compose <md>.
    Signs `${nodeId}:${ts}:${nonce}:md:${target}:refresh` with nodeSecret.
    Returns the {ok, target, hash, doc} response, or None on failure."""
    cfg = load_config()
    node_id = cfg.get("nodeId")
    node_secret = cfg.get("nodeSecret")
    if not node_id or not node_secret:
        return None
    ts = str(int(time.time() * 1000))
    nonce = os.urandom(16).hex()
    action = "refresh"
    sig = hmac.new(
        node_secret.encode("utf-8"),
        f"{node_id}:{ts}:{nonce}:md:{target}:{action}".encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    body = json.dumps({
        "nodeId": node_id,
        "timestamp": ts,
        "nonce": nonce,
        "signature": sig,
        "target": target,
        "action": action,
    }).encode("utf-8")
    try:
        req = urllib.request.Request(
            MD_SYNC_URL,
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception as e:  # noqa: BLE001
        _log(f"md-sync[{target}]: CF compose failed: {e}")
        return None


def _md_render_from_resp(target: str, resp: dict) -> bool:
    """Render the managed zone from a compose response + persist the local
    hash. Returns False (without persisting) when the file is missing so the
    caller retries on a later poll."""
    doc = resp.get("doc") if isinstance(resp, dict) else None
    if not isinstance(doc, dict):
        return False
    try:
        if not _md_apply_zone(target, _render_tools_zone(doc.get("blocks") or [])):
            return False  # file missing → not rendered yet
        h = resp.get("hash") or ""
        if h:
            _md_write_local_hash(target, h)
        _log(f"md-sync[{target}]: rendered {len(doc.get('blocks') or [])} blocks via CF")
        return True
    except Exception as e:  # noqa: BLE001
        _log(f"md-sync[{target}]: CF render failed: {e}")
        return False


def _md_sync_from_json(token: dict, target: str) -> None:
    """Render the managed zone of <md> from the node's cached {target}Json.
    Cheap hash check first; only rewrites on change. Resilient: any failure
    leaves the file untouched. Bootstrap via CF when there is no cache yet."""
    desc = _MD_TARGETS[target]
    try:
        remote_hash = _firestore_get_node_field(token, desc["hash_field"])
    except Exception as e:  # noqa: BLE001
        _log(f"md-sync[{target}]: hash read failed: {e}")
        return
    if not remote_hash:
        # Bootstrap: nodo sin cache. Forzamos UNA composición vía la CF (una
        # vez por proceso) para sembrar el hash; el render real ocurre aquí o
        # en un poll posterior cuando el archivo ya exista.
        if not _md_bootstrap_attempted.get(target):
            _md_bootstrap_attempted[target] = True
            resp = _md_compose_via_cf(target)
            if isinstance(resp, dict) and resp.get("ok"):
                _md_render_from_resp(target, resp)
        return
    md = OPENCLAW_DIR / "workspace" / desc["md_name"]
    if remote_hash == _md_read_local_hash(target) and md.is_file():
        return  # sin cambios → no reescribir
    try:
        raw = _firestore_get_node_field(token, desc["json_field"])
        doc = json.loads(raw) if raw else None
    except Exception as e:  # noqa: BLE001
        _log(f"md-sync[{target}]: json read/parse failed: {e}")
        return
    if not isinstance(doc, dict):
        return
    blocks = doc.get("blocks") or []
    try:
        if _md_apply_zone(target, _render_tools_zone(blocks)):
            _md_write_local_hash(target, remote_hash)
            _log(f"md-sync[{target}]: rendered {len(blocks)} blocks (hash {remote_hash[:12]})")
    except Exception as e:  # noqa: BLE001
        _log(f"md-sync[{target}]: render failed: {e}")


def _md_strip_legacy_sections(target: str, text: str) -> str:
    """Drop the legacy `## …` sections the daemon used to append (now
    server-composed inside the managed zone, or — for email — moved entirely
    to TOOLS.md). Preserves the managed zone and any curated content."""
    desc = _MD_TARGETS[target]
    start, end = desc["zone_start"], desc["zone_end"]
    headers = desc["legacy_headers"]
    zone = ""
    pre, post = text, ""
    if start in text and end in text:
        pre = text.split(start, 1)[0]
        rest = text.split(start, 1)[1]
        zone_body = rest.split(end, 1)[0]
        post = rest.split(end, 1)[1]
        zone = f"{start}{zone_body}{end}"

    def _strip_chunk(chunk: str) -> str:
        lines = chunk.split("\n")
        out: list = []
        i, n = 0, len(lines)
        while i < n and not lines[i].startswith("## "):
            out.append(lines[i])
            i += 1
        while i < n:
            sec = [lines[i]]
            i += 1
            while i < n and not lines[i].startswith("## "):
                sec.append(lines[i])
                i += 1
            header = sec[0].strip().lower()
            drop = any(header.startswith(h) for h in headers)
            if not drop:
                out.extend(sec)
        return "\n".join(out)

    new_pre = _strip_chunk(pre).rstrip()
    new_post = _strip_chunk(post).strip()
    if zone:
        parts = [p for p in (new_pre, zone, new_post) if p]
        return "\n\n".join(parts) + "\n"
    return (new_pre + "\n") if new_pre else ""


def _md_migrate(target: str) -> None:
    """One-time: force the server to compose <md>, render it into the managed
    zone (appended at the end), then strip the legacy sections that lived
    outside the markers. Backup once. Only strips after a successful
    compose+render → no gap if the CF is unreachable (retries next boot).
    No-op until the file exists (a fresh node before OpenClaw seeds it)."""
    desc = _MD_TARGETS[target]
    sentinel = desc["sentinel"]
    if sentinel.exists():
        return
    resp = _md_compose_via_cf(target)
    if not (isinstance(resp, dict) and resp.get("ok")):
        return  # CF inalcanzable / no pareado → reintenta, no toca nada
    if not _md_render_from_resp(target, resp):
        return  # archivo aún no existe → reintenta en otro poll
    p = OPENCLAW_DIR / "workspace" / desc["md_name"]
    try:
        text = p.read_text(encoding="utf-8") if p.is_file() else ""
        if text:
            new = _md_strip_legacy_sections(target, text)
            if new != text:
                bak = p.with_name(desc["backup_name"])
                if not bak.exists():
                    bak.write_text(text, encoding="utf-8")
                tmp = p.with_name(p.name + ".tmp")
                tmp.write_text(new, encoding="utf-8")
                os.replace(tmp, p)
                _log(f"md-migrate[{target}]: stripped legacy sections outside markers")
        sentinel.write_text("done", encoding="utf-8")
    except Exception as e:  # noqa: BLE001
        _log(f"md-migrate[{target}]: {e}")


# ── TEAM_INDEX.md renderer (roster de TNodes-peer, archivo dedicado) ──
# A diferencia de SOUL/IDENTITY (zonas entre markers en archivos del agente),
# TEAM_INDEX.md es un archivo COMPLETO que generamos nosotros — hermano de
# AGENTS_INDEX.md. Lo compone la CF (target="team", leyendo peers/ + el
# toolsJson de cada peer para derivar la especialidad) y aquí lo escribimos por
# hash. Sin peers (blocks vacío) → se borra (y el bloque "equipo" de IDENTITY
# tampoco se compone), evitando un apuntador a un roster inexistente.
_TEAM_HASH_PATH = OPENCLAW_DIR / ".tnode-team-index-hash"
_team_bootstrap_attempted = {"done": False}


def _team_read_local_hash() -> str:
    try:
        return _TEAM_HASH_PATH.read_text(encoding="utf-8").strip()
    except Exception:  # noqa: BLE001
        return ""


def _team_write_local_hash(value: str) -> None:
    try:
        _TEAM_HASH_PATH.write_text(value, encoding="utf-8")
    except Exception as e:  # noqa: BLE001
        _log(f"team-index: hash write failed: {e}")


def _render_team_index(doc: dict) -> bool:
    """Write (or delete) agency-agents/TEAM_INDEX.md from a compose doc.
    Empty body (no peers) → remove the file. Atomic write. Returns True on
    success (incl. the delete/no-op case)."""
    body = _render_tools_zone(doc.get("blocks") or []) if isinstance(doc, dict) else ""
    try:
        if not body.strip():
            if _TEAM_INDEX_PATH.exists():
                _TEAM_INDEX_PATH.unlink()
            return True
        _TEAM_INDEX_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = _TEAM_INDEX_PATH.with_name(_TEAM_INDEX_PATH.name + ".tmp")
        tmp.write_text(body.rstrip() + "\n", encoding="utf-8")
        os.replace(tmp, _TEAM_INDEX_PATH)
        return True
    except Exception as e:  # noqa: BLE001
        _log(f"team-index: render failed: {e}")
        return False


def _team_index_sync_from_json(token: dict) -> None:
    """Render agency-agents/TEAM_INDEX.md from the node's cached teamIndexJson.
    Cheap hash check first; only rewrites on change. Bootstrap via the CF
    (target=team) when there is no cache yet. Resilient: any failure leaves the
    file untouched."""
    try:
        remote_hash = _firestore_get_node_field(token, "teamIndexHash")
    except Exception as e:  # noqa: BLE001
        _log(f"team-index: hash read failed: {e}")
        return
    if not remote_hash:
        # Nodo sin cache aún (nunca tuvo peers, o golden mínimo): fuerza UNA
        # composición vía la CF (una vez por proceso) para sembrar el hash; el
        # render real ocurre aquí (sin peers el doc viene vacío → no-op).
        if not _team_bootstrap_attempted["done"]:
            _team_bootstrap_attempted["done"] = True
            resp = _md_compose_via_cf("team")
            if isinstance(resp, dict) and resp.get("ok"):
                doc = resp.get("doc")
                if isinstance(doc, dict) and _render_team_index(doc):
                    h = resp.get("hash") or ""
                    if h:
                        _team_write_local_hash(h)
        return
    if remote_hash == _team_read_local_hash():
        return  # sin cambios → no reescribir (el hash captura "con/sin peers")
    try:
        raw = _firestore_get_node_field(token, "teamIndexJson")
        doc = json.loads(raw) if raw else None
    except Exception as e:  # noqa: BLE001
        _log(f"team-index: json read/parse failed: {e}")
        return
    if not isinstance(doc, dict):
        return
    if _render_team_index(doc):
        _team_write_local_hash(remote_hash)
        n = len(doc.get("blocks") or [])
        _log(f"team-index: rendered (hash {remote_hash[:12]}, {n} block(s))")


def _resolve_himalaya_path() -> str:
    """Path absoluto al binario himalaya (which() falla bajo el PATH no
    interactivo de launchd en macOS, así que probamos ubicaciones comunes)."""
    found = shutil.which("himalaya")
    if found:
        return found
    for cand in (
        "/opt/homebrew/bin/himalaya",
        str(Path.home() / ".local" / "bin" / "himalaya"),
        "/usr/local/bin/himalaya",
    ):
        if Path(cand).is_file():
            return cand
    return "himalaya"


def _channels_firestore_payload() -> dict:
    """Mapea channels-state.json → los docs por-canal que el servidor lee para
    componer el TOOLS.md. Hoy solo `email` produce bloque (telegram es canal
    nativo, sin regla de uso)."""
    st = _read_channels_state()
    email = st.get("email") if isinstance(st.get("email"), dict) else {}
    if email.get("status") == "linked":
        provider = (email.get("provider") or "gmail").lower()
        variant = "resend" if provider == "resend" else "himalaya"
        payload = {
            "linked": True,
            "variant": variant,
            "account": email.get("address") or "",
        }
        if variant == "himalaya":
            payload["himalayaPath"] = _resolve_himalaya_path()
        return {"email": payload}
    return {"email": {"linked": False}}


def _sync_channels_to_firestore(token: dict) -> None:
    """Refleja el estado de canales a users/{uid}/nodes/{nodeId}/channels/{id}
    para que el servidor componga el bloque email. Guard por hash (evita PATCH
    en cada poll). Best-effort: los errores se loguean, nunca son fatales."""
    try:
        payload = _channels_firestore_payload()
        digest = hashlib.sha256(
            json.dumps(payload, sort_keys=True).encode("utf-8")
        ).hexdigest()
        try:
            prev = _CHANNELS_HASH_PATH.read_text(encoding="utf-8").strip()
        except Exception:  # noqa: BLE001
            prev = ""
        if digest == prev:
            return
        for channel_id, fields in payload.items():
            _firestore_upsert_channel(token, channel_id, fields)
        try:
            _CHANNELS_HASH_PATH.write_text(digest, encoding="utf-8")
        except Exception:  # noqa: BLE001
            pass
        _log(f"channels-sync: pushed {list(payload.keys())}")
    except Exception as e:  # noqa: BLE001
        _log(f"channels-sync: {e}")


def _ensure_workspace_dirs() -> None:
    """Ensure workspace/download + workspace/upload exist — the storage widget
    surfaces entries from here and the agent puts deliverables in download/.
    (Was a side effect of the retired _ensure_subagents_sections; the operative
    SOUL/IDENTITY sections it appended are now server-composed and rendered by
    _md_sync_from_json.)"""
    workspace = OPENCLAW_DIR / "workspace"
    try:
        (workspace / "download").mkdir(parents=True, exist_ok=True)
        (workspace / "upload").mkdir(parents=True, exist_ok=True)
    except Exception as e:  # noqa: BLE001
        _log(f"_ensure_workspace_dirs: {e}")


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
    image_generation_model = fields.get("imageGenerationModel")
    music_generation_model = fields.get("musicGenerationModel")
    video_generation_model = fields.get("videoGenerationModel")

    if not all(k in files for k in _SUBAGENT_FILES) or not files_sha:
        return {
            "status": "error",
            "result": {"error": f"agent_doc_incomplete: {agent_id}"},
        }

    try:
        _materialize_subagent_files(agent_id, files, files_sha)
        config_changed = _update_openclaw_config_for_subagent(
            agent_id, "install", recommended_model, image_generation_model,
            music_generation_model, video_generation_model,
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
            "imageGenerationModel": image_generation_model,
            "musicGenerationModel": music_generation_model,
            "videoGenerationModel": video_generation_model,
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


# Gateway reload for openclaw.json changes (mcp.servers + agents.list) is
# AUTOMATIC: the gateway watches openclaw.json and hot-reloads on change.
# Verified on the Mini — the instant config-sync writes the file the gateway
# logs `[reload] config hot reload applied (mcp.servers.huggingface)`. So
# enabling/disabling an MCP or sub-agent needs NO restart — just the write.
# The client still posts restart_gateway_for_mcp / _for_subagents on screen
# dispose(); we ack them as no-ops (the hot-reload already applied the change).
# NB: the legacy SIGTERM-by-pgrep approach never actually worked — it matched
# "openclaw-gatewa" while the process is `node .../openclaw/dist/index.js
# gateway`, AND the gateway traps SIGTERM (it does not exit on it). Things
# worked anyway precisely because of the hot-reload above.


def handle_restart_gateway_for_subagents(token: dict, params: dict) -> dict:
    """No-op: the gateway hot-reloads openclaw.json (agents.list + mcp.servers)
    on its own, so no restart is needed. Kept so shipped clients that still post
    this on screen dispose() get a clean `done` instead of unknown_command_type."""
    return {"status": "done", "result": {"note": "hot-reload; no restart needed"}}


# ── MCP servers (Direction A — node CONSUMES 3rd-party MCP servers) ──
#
# OpenClaw 2026.5.x is a native MCP client: enabling a server is just
# writing an entry under openclaw.json["mcpServers"][id] and restarting
# the gateway, which connects it and exposes its tools to every agent.
# F1 ships REMOTE transports only (http/sse) — the API key rides in
# `headers` and NO process runs on the node. stdio servers (command/
# args/env) are F2, gated behind the curated mcpCatalog allowlist.
# Mirror: users/{uid}/nodes/{nodeId}/mcpServers/{serverId}. Secrets
# travel once in the command params and land only in openclaw.json
# headers (the client clears them from the command doc afterwards).

_MCP_REMOTE_TRANSPORTS = ("http", "sse")
# OpenClaw 2026.5.x wants the entry under mcp.servers.<id> with transport
# "streamable-http"/"sse". The catalog + client keep the friendly
# "http"/"sse" names; translate to OpenClaw's vocabulary on write.
_MCP_OPENCLAW_TRANSPORT = {"http": "streamable-http", "sse": "sse"}

# Public OAuth redirect (Firebase Hosting, go.tbrain.app). The page captures
# `?code=` and surfaces it to the app (Fase 0: copy-paste; Fase 1+: deep link).
# The same value is registered with the provider via DCR by `openclaw mcp add
# --oauth-redirect-url`, so it MUST match what the callback page serves.
MCP_OAUTH_REDIRECT_URL = "https://go.tbrain.app/mcp/callback"


def _extract_oauth_authorize_url(text: str) -> str | None:
    """Pull the provider authorize URL out of `openclaw mcp login` stdout.
    The CLI prints a banner + the URL on its own line + a follow-up hint;
    the authorize URL is the line carrying the OAuth query (response_type /
    code_challenge). Doctor-warning noise and the embedded redirect_uri (which
    lives inside the query, not on its own line) are skipped."""
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("http") and (
            "response_type=" in line or "code_challenge=" in line or "/authorize" in line
        ):
            return line
    return None


def _build_mcp_remote_entry(fields: dict, secrets: dict) -> dict:
    """Build an openclaw.json mcpServers[] entry for a REMOTE server.
    secretsSchema entries with target=='header' are injected into
    `headers`; each value is prefixed per the spec's `valuePrefix`
    ("Bearer " for bearer auth, "" for raw-key headers like x-api-key /
    CONTEXT7_API_KEY). Specs without a `valuePrefix` (older catalog docs)
    fall back to the legacy heuristic (Authorization → "Bearer ", else
    raw). Raises ValueError on bad config or a missing required secret."""
    transport = (fields.get("transport") or "").strip()
    url = (fields.get("url") or "").strip()
    if transport not in _MCP_REMOTE_TRANSPORTS or not url:
        raise ValueError(
            f"invalid_remote_config: transport={transport or 'none'} "
            f"url={'set' if url else 'empty'}"
        )
    entry: dict = {"transport": _MCP_OPENCLAW_TRANSPORT.get(transport, transport), "url": url}
    headers: dict = {}
    for spec in fields.get("secretsSchema") or []:
        if not isinstance(spec, dict) or (spec.get("target") or "") != "header":
            continue
        key = spec.get("key") or ""
        value = secrets.get(key)
        if not value:
            if spec.get("required"):
                raise ValueError(f"missing_secret: {key}")
            continue
        value = str(value)
        header_name = spec.get("headerName") or "Authorization"
        # valuePrefix (catalog, config-sync >= 1.21): EXACTLY what to prepend
        # to the secret — "Bearer " for bearer servers, "" for raw-key headers
        # (x-api-key, CONTEXT7_API_KEY). Absent (older catalog docs) → legacy
        # heuristic: Authorization gets "Bearer ", any other header stays raw.
        if "valuePrefix" in spec:
            prefix = spec.get("valuePrefix") or ""
            if prefix and value.lower().startswith(prefix.lower()):
                headers[header_name] = value
            else:
                headers[header_name] = f"{prefix}{value}"
        elif header_name.lower() == "authorization" and not value.lower().startswith("bearer "):
            headers[header_name] = f"Bearer {value}"
        else:
            headers[header_name] = value
    if headers:
        entry["headers"] = headers
    return entry


def handle_mcp_install(token: dict, params: dict) -> dict:
    server_id = (params.get("serverId") or params.get("catalogId") or "").strip()
    if not server_id:
        return {"status": "error", "result": {"error": "missing_serverId"}}
    secrets = params.get("secrets") or {}

    doc = _firestore_get_mcp_catalog_doc(token, server_id)
    if doc is None:
        return {"status": "error", "result": {"error": f"mcp_not_found: {server_id}"}}
    fields = {k: _fs_unwrap(v) for k, v in doc.get("fields", {}).items()}

    transport = (fields.get("transport") or "").strip()
    if transport not in _MCP_REMOTE_TRANSPORTS:
        # F1 ships remote-only; stdio (command/args/env) lands in F2.
        return {
            "status": "error",
            "result": {
                "error": f"unsupported_transport: {transport or 'none'} (remote-only in F1)"
            },
        }

    # OAuth catalog entries go through mcp.oauth.begin/complete (browser
    # consent), not the static-secret path here.
    auth_type = (fields.get("authType") or "header").strip().lower()
    if auth_type == "oauth":
        return {
            "status": "error",
            "result": {"error": "oauth_server_use_begin: call mcp.oauth.begin"},
        }

    try:
        entry = _build_mcp_remote_entry(fields, secrets)
    except ValueError as e:
        return {"status": "error", "result": {"error": str(e)}}

    # Write via the CLI (openclaw mcp set), NOT by editing openclaw.json
    # directly: the CLI is the stable contract; the on-disk shape drifts
    # between versions. `set` is an idempotent upsert (clean re-enable). The
    # secret transits argv for the duration of the call — acceptable on a
    # single-tenant node; at rest it lands in openclaw.json headers exactly as
    # before. The gateway hot-reloads mcp.servers, so no restart is needed.
    res = _run_openclaw("mcp", "set", server_id, json.dumps(entry), timeout=45)
    if not res.get("ok"):
        err = (res.get("stderr") or res.get("error") or "mcp_set_failed").strip()[:500]
        _log(f"mcp_install {server_id} failed: {err}")
        try:
            _firestore_upsert_mcp_server(
                token, server_id, {"status": "error", "error": err}
            )
        except Exception:  # noqa: BLE001
            pass
        return {"status": "error", "result": {"error": err}}

    try:
        # Mirror WITHOUT secrets: drop headers before persisting config.
        safe_config = {k: v for k, v in entry.items() if k != "headers"}
        _firestore_upsert_mcp_server(
            token,
            server_id,
            {
                "catalogId": server_id,
                "authType": "header",
                "enabled": True,
                "status": "enabled",
                "config": json.dumps(safe_config),
                "error": None,
            },
        )
    except Exception as e:  # noqa: BLE001
        _log(f"mcp_install {server_id} mirror failed: {e}")

    return {"status": "done", "result": {"serverId": server_id, "transport": transport}}


def handle_mcp_remove(token: dict, params: dict) -> dict:
    server_id = (params.get("serverId") or params.get("catalogId") or "").strip()
    if not server_id:
        return {"status": "error", "result": {"error": "missing_serverId"}}
    # Remove via the CLI: `unset` drops the mcp.servers entry; `logout` clears
    # any stored OAuth token (no-op / harmless for header servers). Treat a
    # missing entry as success (idempotent disable).
    res = _run_openclaw("mcp", "unset", server_id, timeout=30)
    _run_openclaw("mcp", "logout", server_id, timeout=30)  # best-effort
    if not res.get("ok"):
        err = (res.get("stderr") or res.get("error") or "").lower()
        if "not found" not in err and "unknown" not in err and "no such" not in err:
            _log(f"mcp_remove {server_id} failed: {err[:300]}")
            return {"status": "error", "result": {"error": err[:500] or "mcp_unset_failed"}}
    try:
        # Keep `config` (omit from the mask) so re-enabling only needs the
        # secret again; flip enabled/status and clear any prior error.
        _firestore_upsert_mcp_server(
            token,
            server_id,
            {"enabled": False, "status": "disabled", "error": None},
        )
    except Exception as e:  # noqa: BLE001
        _log(f"mcp_remove {server_id} mirror failed: {e}")
    return {"status": "done", "result": {"serverId": server_id, "removed": True}}


# ── MCP OAuth (Notion / Linear / Asana / Atlassian-oauth / …) ──
#
# OpenClaw 2026.6.10 ships native OAuth for remote MCP servers (MCP SDK
# authProvider over StreamableHTTP/SSE). We DON'T build OAuth ourselves — we
# drive the CLI in two steps so a headless node can be authorized from the
# phone (no local browser needed):
#
#   begin:    `openclaw mcp add <id> --auth oauth --oauth-redirect-url <pub>
#              --no-probe` (DCR registers a client on the fly; no per-provider
#              app to pre-register) → `openclaw mcp login <id>` prints the
#              provider authorize URL → we return it to the app.
#   (user)    opens the URL, consents in their own account → provider redirects
#              to go.tbrain.app/mcp/callback?code=… → the app gets the code.
#   complete: `openclaw mcp login <id> --code <code>` exchanges + stores the
#              token (PKCE verifier was saved on this node at begin), then
#              `openclaw mcp reload` so the next turn picks it up.
#
# Verified on the Mini 2026-06-28: login (no --code) prints the URL and exits
# 0 — it does not hang waiting on a local browser.

def handle_mcp_oauth_begin(token: dict, params: dict) -> dict:
    server_id = (params.get("serverId") or params.get("catalogId") or "").strip()
    if not server_id:
        return {"status": "error", "result": {"error": "missing_serverId"}}

    doc = _firestore_get_mcp_catalog_doc(token, server_id)
    if doc is None:
        return {"status": "error", "result": {"error": f"mcp_not_found: {server_id}"}}
    fields = {k: _fs_unwrap(v) for k, v in doc.get("fields", {}).items()}

    transport = (fields.get("transport") or "").strip()
    if transport not in _MCP_REMOTE_TRANSPORTS:
        return {
            "status": "error",
            "result": {"error": f"unsupported_transport: {transport or 'none'}"},
        }
    url = (fields.get("url") or "").strip()
    if not url:
        return {"status": "error", "result": {"error": "missing_url"}}
    ot = _MCP_OPENCLAW_TRANSPORT.get(transport, transport)
    scope = (fields.get("oauthScope") or "").strip()
    meta_url = (fields.get("oauthClientMetadataUrl") or "").strip()

    # Clear any prior half-finished attempt so re-begin is idempotent
    # (mcp add fails if the server already exists).
    _run_openclaw("mcp", "unset", server_id, timeout=30)
    _run_openclaw("mcp", "logout", server_id, timeout=30)

    add = [
        "mcp", "add", server_id,
        "--url", url, "--transport", ot,
        "--auth", "oauth",
        "--oauth-redirect-url", MCP_OAUTH_REDIRECT_URL,
        "--no-probe",
    ]
    if scope:
        add += ["--oauth-scope", scope]
    if meta_url:
        add += ["--oauth-client-metadata-url", meta_url]
    res = _run_openclaw(*add, timeout=60)
    if not res.get("ok"):
        err = (res.get("stderr") or res.get("error") or "mcp_add_failed").strip()[:500]
        _log(f"mcp_oauth_begin {server_id} add failed: {err}")
        return {"status": "error", "result": {"error": err}}

    login = _run_openclaw("mcp", "login", server_id, timeout=45)
    auth_url = _extract_oauth_authorize_url(login.get("stdout", ""))
    if not auth_url:
        # Couldn't parse the URL — roll back the half-added server.
        _run_openclaw("mcp", "unset", server_id, timeout=30)
        tail = (login.get("stdout", "") + login.get("stderr", ""))[-400:]
        _log(f"mcp_oauth_begin {server_id} no auth url; tail={tail}")
        return {"status": "error", "result": {"error": "no_auth_url", "detail": tail}}

    try:
        _firestore_upsert_mcp_server(
            token,
            server_id,
            {
                "catalogId": server_id,
                "authType": "oauth",
                "enabled": False,
                "status": "oauth_pending",
                "config": json.dumps({"transport": ot, "url": url, "auth": "oauth"}),
                "error": None,
            },
        )
    except Exception as e:  # noqa: BLE001
        _log(f"mcp_oauth_begin {server_id} mirror failed: {e}")

    return {"status": "done", "result": {"serverId": server_id, "authUrl": auth_url}}


def handle_mcp_oauth_complete(token: dict, params: dict) -> dict:
    server_id = (params.get("serverId") or params.get("catalogId") or "").strip()
    code = (params.get("code") or "").strip()
    if not server_id:
        return {"status": "error", "result": {"error": "missing_serverId"}}
    if not code:
        return {"status": "error", "result": {"error": "missing_code"}}

    res = _run_openclaw("mcp", "login", server_id, "--code", code, timeout=60)
    if not res.get("ok"):
        err = (res.get("stderr") or res.get("error") or "mcp_login_failed").strip()[:500]
        _log(f"mcp_oauth_complete {server_id} failed: {err}")
        try:
            _firestore_upsert_mcp_server(
                token, server_id, {"status": "error", "error": err}
            )
        except Exception:  # noqa: BLE001
            pass
        return {"status": "error", "result": {"error": err}}

    # Token stored; dispose cached MCP runtimes so the next turn reconnects
    # with the new credentials.
    _run_openclaw("mcp", "reload", timeout=30)

    try:
        _firestore_upsert_mcp_server(
            token,
            server_id,
            {"enabled": True, "status": "enabled", "error": None},
        )
    except Exception as e:  # noqa: BLE001
        _log(f"mcp_oauth_complete {server_id} mirror failed: {e}")

    return {"status": "done", "result": {"serverId": server_id, "connected": True}}


def handle_restart_gateway_for_mcp(token: dict, params: dict) -> dict:
    """No-op (delegates to the shared handler): the gateway hot-reloads
    mcp.servers from openclaw.json, so enabling/disabling a server needs no
    restart. Kept so the client's dispose() restart gets a clean `done`."""
    return handle_restart_gateway_for_subagents(token, params)


# ── Channels — Email (Resend HTTPS / himalaya for Gmail/IMAP) ──
#
# `channels.email.link/unlink` mirror status to
# `~/.openclaw/channels-state.json`. The telemetry sidecar reads that file
# to emit the `channels` stream the mobile app subscribes to.
#
# Three providers, two backends:
#   - resend: HTTPS send via the email-send skill (only path that works on
#     DigitalOcean droplets, where outbound SMTP 465/587 is firewalled).
#     The handler validates the API key against api.resend.com, persists
#     it to ~/.openclaw/credentials/resend.json (0600), and appends a
#     SOUL section so the on-node agent picks the skill over smtplib.
#   - gmail / imap: classic IMAP+SMTP via himalaya. Works on Mac mini /
#     Pi where outbound SMTP is open. The handler writes a himalaya TOML
#     and runs a 1-envelope smoke test to confirm credentials.
#   - agentmail: gated off — needs a master API key + billing setup; the
#     handler returns `agentmail_not_implemented` until that lands.

_CHANNELS_STATE_PATH = OPENCLAW_DIR / "channels-state.json"
_HIMALAYA_CONFIG_DIR = Path.home() / ".config" / "himalaya"
_HIMALAYA_CONFIG_PATH = _HIMALAYA_CONFIG_DIR / "config.toml"
_RESEND_CRED_PATH = OPENCLAW_DIR / "credentials" / "resend.json"
_RESEND_DOMAINS_URL = "https://api.resend.com/domains"


def _read_channels_state() -> dict:
    try:
        return json.loads(_CHANNELS_STATE_PATH.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}
    except Exception:  # noqa: BLE001
        return {}


def _write_channels_state(state: dict) -> None:
    try:
        _CHANNELS_STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        _CHANNELS_STATE_PATH.write_text(
            json.dumps(state, indent=2, sort_keys=True), encoding="utf-8"
        )
        try:
            os.chmod(_CHANNELS_STATE_PATH, 0o600)
        except OSError:
            pass
    except Exception as e:  # noqa: BLE001
        _log(f"_write_channels_state failed: {e}")


def _parse_host_port(s: str, default_port: int) -> tuple[str, int]:
    s = (s or "").strip()
    if not s:
        return "", default_port
    if ":" in s:
        host, port_str = s.rsplit(":", 1)
        try:
            return host.strip(), int(port_str)
        except ValueError:
            return host.strip(), default_port
    return s, default_port


def _encryption_for(kind: str, port: int) -> str:
    """himalaya v1.2 `encryption.type` for a given port. Implicit TLS vs
    STARTTLS must match the port or the handshake deadlocks: with
    `tls` against smtp 587 the server waits for EHLO in the clear while
    the client waits for a TLS hello — `message send` hangs forever
    (fire-tested on the Mini 2026-06-11). Standard ports:
      imap: 993 = implicit tls · 143 = start-tls
      smtp: 465 = implicit tls · 587/25 = start-tls
    Unknown ports default to implicit tls."""
    if kind == "imap":
        return "start-tls" if port == 143 else "tls"
    return "start-tls" if port in (587, 25) else "tls"


def _render_himalaya_toml(
    provider: str,
    address: str,
    password: str,
    imap_host: str,
    imap_port: int,
    smtp_host: str,
    smtp_port: int,
) -> str:
    """Build a himalaya v1.2 TOML config for a single account. Both raw
    password fields hold the App Password (Gmail rejects plain passwords
    since 2022 — see feedback_imap_auth_failed_diagnosis)."""
    imap_enc = _encryption_for("imap", imap_port)
    smtp_enc = _encryption_for("smtp", smtp_port)
    return (
        "# Himalaya config — managed by tnode-config-sync; do not edit by hand.\n"
        "# Re-run channels.email.link to rotate credentials.\n"
        "\n"
        f"[accounts.{provider}]\n"
        f'default = true\n'
        f'email = "{address}"\n'
        f'display-name = "TNode Agent"\n'
        f'\n'
        f'backend.type = "imap"\n'
        f'backend.host = "{imap_host}"\n'
        f"backend.port = {imap_port}\n"
        f'backend.encryption.type = "{imap_enc}"\n'
        f'backend.login = "{address}"\n'
        f'backend.auth.type = "password"\n'
        f'backend.auth.raw = "{password}"\n'
        f"\n"
        f'message.send.backend.type = "smtp"\n'
        f'message.send.backend.host = "{smtp_host}"\n'
        f"message.send.backend.port = {smtp_port}\n"
        f'message.send.backend.encryption.type = "{smtp_enc}"\n'
        f'message.send.backend.login = "{address}"\n'
        f'message.send.backend.auth.type = "password"\n'
        f'message.send.backend.auth.raw = "{password}"\n'
        f"\n"
        f"# No IMAP-APPEND a copy to the sent folder after SMTP submit.\n"
        f"# himalaya's default folder is the literal \"Sent\", which does\n"
        f"# not exist on Gmail ([Gmail]/Sent Mail) → the send exits 1 even\n"
        f"# though the mail went out, and the agent treats it as a failure\n"
        f"# (fire-tested on the Mini 2026-06-12). Gmail/Outlook/Yahoo all\n"
        f"# auto-save SMTP-submitted mail to their sent folder anyway, so\n"
        f"# the copy would be a duplicate.\n"
        f"message.send.save-copy = false\n"
    )


def _himalaya_smoke_test(himalaya_bin: str = "himalaya") -> tuple[bool, str]:
    """Run a 1-envelope INBOX list to confirm IMAP login works. Returns
    (ok, err_message) — `ok=False` means Gmail/IMAP rejected the
    credentials or himalaya is missing."""
    try:
        result = subprocess.run(
            [himalaya_bin, "envelope", "list", "-f", "INBOX", "-p", "1", "-s", "1"],
            capture_output=True,
            text=True,
            timeout=45,
        )
        if result.returncode == 0:
            return True, ""
        # Gmail surfaces "AUTHENTICATIONFAILED" or "Invalid credentials" via
        # stderr; surface a trimmed version to the client.
        err = (result.stderr or result.stdout or "").strip()
        return False, err[:400]
    except FileNotFoundError:
        return False, "himalaya binary not found in PATH"
    except subprocess.TimeoutExpired:
        return False, "smoke test timed out (45s)"


# Pinned to the release the TOML render + agent guidance were validated
# against (Mini, 2026-06-11). Bump deliberately, re-running the fire test.
_HIMALAYA_VERSION = "v1.2.0"


def _ensure_himalaya_installed() -> tuple[str, str]:
    """Resolve the himalaya binary, installing it on demand. Returns
    `(abs_path, "")` on success or `("", err)`.

    Installed lazily (not in tnode-setup) so only nodes that actually link
    a Gmail/IMAP account pay the cost. macOS goes through brew; Linux
    (Pi / VPS) downloads the pinned static musl build for the local arch
    into ~/.local/bin — the daemon user can write there without sudo, and
    callers always use the absolute path so the gateway's PATH is moot."""
    found = shutil.which("himalaya")
    if found:
        return found, ""

    if sys.platform == "darwin":
        brew = shutil.which("brew") or next(
            (
                p
                for p in ("/opt/homebrew/bin/brew", "/usr/local/bin/brew")
                if Path(p).exists()
            ),
            None,
        )
        if not brew:
            return "", "himalaya_missing_and_no_brew"
        try:
            r = subprocess.run(
                [brew, "install", "himalaya"],
                capture_output=True,
                text=True,
                timeout=600,
            )
        except subprocess.TimeoutExpired:
            return "", "brew_install_timeout"
        if r.returncode != 0:
            return "", f"brew_install_failed: {(r.stderr or '')[-200:]}"
        found = shutil.which("himalaya") or str(Path(brew).parent / "himalaya")
        if Path(found).exists():
            return found, ""
        return "", "brew_install_no_binary"

    # Linux: pinned per-arch static build from the GitHub release.
    arch = platform.machine()
    if arch not in ("x86_64", "aarch64", "armv7l", "armv6l", "i686"):
        return "", f"unsupported_arch: {arch}"
    url = (
        "https://github.com/pimalaya/himalaya/releases/download/"
        f"{_HIMALAYA_VERSION}/himalaya.{arch}-linux.tgz"
    )
    dest_dir = Path.home() / ".local" / "bin"
    try:
        dest_dir.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory() as td:
            tgz = Path(td) / "himalaya.tgz"
            req = urllib.request.Request(
                url, headers={"User-Agent": "tnode-config-sync/himalaya-install"}
            )
            with urllib.request.urlopen(req, timeout=120) as r, open(
                tgz, "wb"
            ) as f:
                shutil.copyfileobj(r, f)
            with tarfile.open(tgz) as tf:
                tf.extractall(td)
            candidates = [p for p in Path(td).rglob("himalaya") if p.is_file()]
            if not candidates:
                return "", "tarball_no_binary"
            dest = dest_dir / "himalaya"
            shutil.copy2(candidates[0], dest)
            os.chmod(dest, 0o755)
        return str(dest), ""
    except Exception as e:  # noqa: BLE001
        return "", f"himalaya_download_failed: {str(e)[:200]}"


# La guía de correo para el agente vive ahora EXCLUSIVAMENTE en TOOLS.md
# (Regla 4, compuesta por el servidor desde la subcolección `channels` vía
# _sync_channels_to_firestore). v1.20.0 retiró las secciones de email de
# SOUL.md (himalaya + email-send) y sus upserts/strips on link/unlink —
# eran redundantes con TOOLS.md Regla 4 (que además es más completa). El
# link/unlink de email ya no toca SOUL.md.


def _resend_smoke_test(api_key: str) -> tuple[bool, str]:
    """Validate a Resend API key with a single read-only call to
    `GET /domains`. Returns `(ok, err_msg)`. 200 = valid key; 401 = bad
    key; other = surface the HTTP code."""
    req = urllib.request.Request(
        _RESEND_DOMAINS_URL,
        headers={
            "Authorization": f"Bearer {api_key}",
            "User-Agent": "tnode-config-sync/resend-smoke",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            r.read()
            return True, ""
    except urllib.error.HTTPError as e:
        if e.code == 401:
            return False, "invalid_api_key"
        if e.code == 403:
            return False, "forbidden (account suspended?)"
        return False, f"resend HTTP {e.code}"
    except urllib.error.URLError as e:
        return False, f"network: {e.reason}"
    except Exception as e:  # noqa: BLE001
        return False, str(e)[:200]


def _handle_email_link_resend(params: dict) -> dict:
    """Resend HTTPS path. The user pastes a `re_...` API key from
    https://resend.com/api-keys; we validate it against the Resend API,
    persist it to disk (0600), materialize the email-send skill files,
    and append a SOUL section telling the agent to use the skill."""
    api_key = (params.get("apiKey") or "").strip()
    if not api_key:
        return {"status": "error", "result": {"error": "missing_apiKey"}}
    if not api_key.startswith("re_"):
        return {
            "status": "error",
            "result": {
                "error": "invalid_apiKey_format",
                "detail": "Resend API keys start with 're_'",
            },
        }
    # Optional override; defaults to Resend's sandbox sender (works without
    # DNS verification). The mobile UI exposes this once the user has
    # verified a custom domain in the Resend dashboard.
    from_addr = (
        params.get("fromAddress") or "onboarding@resend.dev"
    ).strip() or "onboarding@resend.dev"

    ok, err = _resend_smoke_test(api_key)
    if not ok:
        return {
            "status": "error",
            "result": {"error": "resend_smoke_failed", "detail": err},
        }

    try:
        _RESEND_CRED_PATH.parent.mkdir(parents=True, exist_ok=True)
        _RESEND_CRED_PATH.write_text(
            json.dumps(
                {"api_key": api_key, "from": from_addr},
                indent=2, sort_keys=True,
            ),
            encoding="utf-8",
        )
        try:
            os.chmod(_RESEND_CRED_PATH, 0o600)
        except OSError:
            pass
    except Exception as e:  # noqa: BLE001
        return {"status": "error", "result": {"error": f"write_creds: {e}"}}

    # Materialize the skill files; the agent's email guidance lives in
    # TOOLS.md Regla 4 (server-composed from the `channels` subcollection),
    # not in SOUL.md anymore (v1.20.0).
    _ensure_email_send_skill()

    now_ms = int(time.time() * 1000)
    state = _read_channels_state()
    state["email"] = {
        "status": "linked",
        "provider": "resend",
        "address": from_addr,
        "domainVerified": from_addr != "onboarding@resend.dev",
        "linkedAt": now_ms,
        "lastSyncAt": now_ms,
    }
    _write_channels_state(state)
    _log(f"channels.email.link ok provider=resend from={from_addr}")
    return {
        "status": "done",
        "result": {
            "provider": "resend",
            "address": from_addr,
            "linkedAt": now_ms,
        },
    }


def handle_channels_email_link(token: dict, params: dict) -> dict:
    provider = (params.get("provider") or "").strip().lower()
    if provider == "resend":
        return _handle_email_link_resend(params)
    if provider == "agentmail":
        return {
            "status": "error",
            "result": {"error": "agentmail_not_implemented"},
        }
    if provider not in ("gmail", "imap"):
        return {
            "status": "error",
            "result": {"error": f"unknown_provider: {provider}"},
        }
    address = (params.get("address") or "").strip()
    app_password = (params.get("appPassword") or "").strip()
    if not address or "@" not in address:
        return {"status": "error", "result": {"error": "invalid_address"}}
    if not app_password:
        return {"status": "error", "result": {"error": "missing_appPassword"}}

    imap_default = "imap.gmail.com:993" if provider == "gmail" else ""
    smtp_default = "smtp.gmail.com:465" if provider == "gmail" else ""
    imap_host, imap_port = _parse_host_port(
        params.get("imapHost") or imap_default, 993
    )
    smtp_host, smtp_port = _parse_host_port(
        params.get("smtpHost") or smtp_default, 465
    )
    if not imap_host or not smtp_host:
        return {
            "status": "error",
            "result": {"error": "missing_imap_or_smtp_host"},
        }

    himalaya_bin, ierr = _ensure_himalaya_installed()
    if not himalaya_bin:
        return {
            "status": "error",
            "result": {"error": "himalaya_not_available", "detail": ierr},
        }

    try:
        _HIMALAYA_CONFIG_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
        toml = _render_himalaya_toml(
            provider, address, app_password,
            imap_host, imap_port, smtp_host, smtp_port,
        )
        _HIMALAYA_CONFIG_PATH.write_text(toml, encoding="utf-8")
        try:
            os.chmod(_HIMALAYA_CONFIG_PATH, 0o600)
        except OSError:
            pass
    except Exception as e:  # noqa: BLE001
        return {"status": "error", "result": {"error": f"write_config: {e}"}}

    ok, err = _himalaya_smoke_test(himalaya_bin)
    if not ok:
        # Roll back the half-written config so the next attempt starts
        # from a clean state. The state file isn't touched (still unlinked).
        try:
            _HIMALAYA_CONFIG_PATH.unlink()
        except FileNotFoundError:
            pass
        return {
            "status": "error",
            "result": {"error": "smoke_test_failed", "detail": err},
        }

    # El agente aprende del buzón por TOOLS.md Regla 4 (compuesta por el
    # servidor desde la subcolección `channels` que _sync_channels_to_firestore
    # refleja en el siguiente ciclo). Ya no se appendea nada a SOUL.md.
    now_ms = int(time.time() * 1000)
    state = _read_channels_state()
    state["email"] = {
        "status": "linked",
        "provider": provider,
        "address": address,
        "linkedAt": now_ms,
        "lastSyncAt": now_ms,
    }
    _write_channels_state(state)
    _log(
        f"channels.email.link ok provider={provider} address={address} "
        f"bin={himalaya_bin}"
    )
    return {
        "status": "done",
        "result": {
            "provider": provider,
            "address": address,
            "linkedAt": now_ms,
        },
    }


def handle_channels_email_unlink(token: dict, params: dict) -> dict:
    # Best-effort cleanup of both backends. We don't track which one is
    # active because a node could in theory have both linked over time
    # (Resend on the cloud half, IMAP on a local nested daemon) — clearing
    # both keeps the unlink semantics simple and idempotent.
    for path, label in (
        (_HIMALAYA_CONFIG_PATH, "himalaya"),
        (_RESEND_CRED_PATH, "resend"),
    ):
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        except Exception as e:  # noqa: BLE001
            _log(f"channels.email.unlink: rm {label}: {e}")
    # La guía de correo del agente (TOOLS.md Regla 4) se cae sola en el
    # siguiente ciclo cuando _sync_channels_to_firestore refleja el canal como
    # unlinked y el servidor recompone TOOLS.md sin el bloque de email.
    state = _read_channels_state()
    state["email"] = {"status": "unlinked"}
    _write_channels_state(state)
    _log("channels.email.unlink ok")
    return {"status": "done", "result": {}}


# ── Telegram ───────────────────────────────────────────────────

def _telegram_get_me(bot_token: str) -> tuple[bool, str, str]:
    """Validate a bot token against the Bot API `getMe`. Returns
    `(ok, username, err)`; `username` is the bot handle without the `@`."""
    url = f"https://api.telegram.org/bot{bot_token}/getMe"
    req = urllib.request.Request(
        url, headers={"User-Agent": "tnode-config-sync/telegram-getme"}
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            data = json.loads(r.read().decode("utf-8"))
        if not data.get("ok"):
            return False, "", "telegram_rejected"
        result = data.get("result") or {}
        return True, str(result.get("username") or ""), ""
    except urllib.error.HTTPError as e:
        if e.code == 401:
            return False, "", "invalid_token"
        return False, "", f"telegram HTTP {e.code}"
    except urllib.error.URLError as e:
        return False, "", f"network: {e.reason}"
    except Exception as e:  # noqa: BLE001
        return False, "", str(e)[:200]


def handle_channels_telegram_link(token: dict, params: dict) -> dict:
    """Wire a Telegram bot into openclaw.json. The client sends `botToken`,
    `accessMode` (owner|list|open), and `allowFrom` (numeric Telegram user
    IDs for owner/list). We validate the token via getMe, resolve the bot
    @username, write `channels.telegram`, and reload the gateway.

    Access mapping (mirrors the Pi's live config):
      owner/list → dmPolicy:"allowlist" + allowFrom:[ids]
      open       → dmPolicy:"open"      + allowFrom:["*"]
    Guard: never emit allowlist with an empty allowFrom — OpenClaw rejects
    that config at boot."""
    bot_token = (params.get("botToken") or "").strip()
    access_mode = (params.get("accessMode") or "owner").strip().lower()
    raw_allow = params.get("allowFrom") or []
    if not bot_token or ":" not in bot_token:
        return {"status": "error", "result": {"error": "invalid_botToken"}}
    if access_mode not in ("owner", "list", "open"):
        return {
            "status": "error",
            "result": {"error": f"invalid_accessMode: {access_mode}"},
        }

    if access_mode == "open":
        dm_policy = "open"
        allow_list = ["*"]
    else:
        if isinstance(raw_allow, list):
            ids = [str(x).strip() for x in raw_allow if str(x).strip()]
        else:
            ids = []
        if not ids:
            return {"status": "error", "result": {"error": "missing_allowFrom"}}
        if not all(i.isdigit() and len(i) >= 5 for i in ids):
            return {
                "status": "error",
                "result": {"error": "non_numeric_allowFrom"},
            }
        if access_mode == "owner":
            ids = ids[:1]
        dm_policy = "allowlist"
        allow_list = ids

    ok, username, err = _telegram_get_me(bot_token)
    if not ok:
        return {
            "status": "error",
            "result": {"error": "token_validation_failed", "detail": err},
        }

    try:
        cfg = read_openclaw_json() or {}
        channels = cfg.setdefault("channels", {})
        prev = channels.get("telegram")
        tg = dict(prev) if isinstance(prev, dict) else {}
        tg.update({
            "enabled": True,
            "botToken": bot_token,
            "dmPolicy": dm_policy,
            "allowFrom": allow_list,
        })
        tg.setdefault("groupPolicy", "allowlist")
        tg.setdefault("streaming", {"mode": "partial"})
        channels["telegram"] = tg
        _write_openclaw_json(cfg)
    except Exception as e:  # noqa: BLE001
        return {"status": "error", "result": {"error": f"write_openclaw: {e}"}}

    now_ms = int(time.time() * 1000)
    state = _read_channels_state()
    state["telegram"] = {
        "status": "linked",
        "botUsername": username,
        "accessMode": access_mode,
        "allowFrom": [] if access_mode == "open" else allow_list,
        "allowCount": 0 if access_mode == "open" else len(allow_list),
        "linkedAt": now_ms,
        "lastSyncAt": now_ms,
    }
    _write_channels_state(state)
    _log(
        f"channels.telegram.link ok bot=@{username} "
        f"mode={access_mode} n={len(allow_list)}"
    )

    restart = _restart_openclaw_with_verify()
    return {
        "status": "done" if restart.get("ok") else "error",
        "result": {
            "botUsername": username,
            "accessMode": access_mode,
            "restart": restart,
            "linkedAt": now_ms,
        },
    }


def handle_channels_telegram_unlink(token: dict, params: dict) -> dict:
    """Remove the Telegram channel from openclaw.json (drops the bot token)
    and reload the gateway. Idempotent."""
    try:
        cfg = read_openclaw_json() or {}
        channels = cfg.get("channels")
        if isinstance(channels, dict) and \
                channels.pop("telegram", None) is not None:
            _write_openclaw_json(cfg)
    except Exception as e:  # noqa: BLE001
        _log(f"channels.telegram.unlink: openclaw write: {e}")
    state = _read_channels_state()
    state["telegram"] = {"status": "unlinked"}
    _write_channels_state(state)
    _log("channels.telegram.unlink ok")
    restart = _restart_openclaw_with_verify()
    return {"status": "done", "result": {"restart": restart}}


def handle_channels_telegram_access(token: dict, params: dict) -> dict:
    """Change WHO can DM an already-linked Telegram bot (accessMode +
    allowFrom), keeping the existing botToken. Rewrites only dmPolicy/allowFrom
    in openclaw.json and reloads — no getMe (the bot is already validated)."""
    access_mode = (params.get("accessMode") or "").strip().lower()
    raw_allow = params.get("allowFrom") or []
    if access_mode not in ("owner", "list", "open"):
        return {
            "status": "error",
            "result": {"error": f"invalid_accessMode: {access_mode}"},
        }

    cfg = read_openclaw_json() or {}
    ch = cfg.get("channels") or {}
    tg = ch.get("telegram") if isinstance(ch, dict) else None
    if not isinstance(tg, dict) or not tg.get("botToken"):
        return {"status": "error", "result": {"error": "not_linked"}}

    if access_mode == "open":
        dm_policy, allow_list = "open", ["*"]
    else:
        if isinstance(raw_allow, list):
            ids = [str(x).strip() for x in raw_allow if str(x).strip()]
        else:
            ids = []
        if not ids:
            return {"status": "error", "result": {"error": "missing_allowFrom"}}
        if not all(i.isdigit() and len(i) >= 5 for i in ids):
            return {
                "status": "error",
                "result": {"error": "non_numeric_allowFrom"},
            }
        if access_mode == "owner":
            ids = ids[:1]
        dm_policy, allow_list = "allowlist", ids

    try:
        tg["dmPolicy"] = dm_policy
        tg["allowFrom"] = allow_list
        ch["telegram"] = tg
        cfg["channels"] = ch
        _write_openclaw_json(cfg)
    except Exception as e:  # noqa: BLE001
        return {"status": "error", "result": {"error": f"write_openclaw: {e}"}}

    now_ms = int(time.time() * 1000)
    state = _read_channels_state()
    prev = state.get("telegram")
    prev = dict(prev) if isinstance(prev, dict) else {"status": "linked"}
    prev.update({
        "status": "linked",
        "accessMode": access_mode,
        "allowFrom": [] if access_mode == "open" else allow_list,
        "allowCount": 0 if access_mode == "open" else len(allow_list),
        "lastSyncAt": now_ms,
    })
    state["telegram"] = prev
    _write_channels_state(state)
    _log(f"channels.telegram.access ok mode={access_mode} n={len(allow_list)}")

    restart = _restart_openclaw_with_verify()
    return {
        "status": "done" if restart.get("ok") else "error",
        "result": {"accessMode": access_mode, "restart": restart},
    }


def _derive_telegram_state_if_missing() -> None:
    """Reflect a hand-configured Telegram channel into channels-state.json.

    If openclaw.json has an enabled `channels.telegram` block but
    channels-state.json has no `telegram` entry — e.g. the bot was wired by
    hand before the app's link flow existed (the Pi's `@TBTvisionBot`) —
    derive a `linked` state so the mobile widget reflects it without forcing
    a re-link. Idempotent: never overwrites an existing telegram entry, so an
    app-driven link/unlink stays authoritative. Runs once at daemon startup.
    """
    try:
        state = _read_channels_state()
        if isinstance(state.get("telegram"), dict):
            return  # already owned by the app/daemon — don't clobber.
        cfg = read_openclaw_json() or {}
        ch = cfg.get("channels") or {}
        tg = ch.get("telegram") if isinstance(ch, dict) else None
        if not isinstance(tg, dict) or not tg.get("enabled"):
            return
        token = (tg.get("botToken") or "").strip()
        if not token or ":" not in token:
            return
        dm = (tg.get("dmPolicy") or "").strip().lower()
        allow = tg.get("allowFrom") if isinstance(tg.get("allowFrom"), list) else []
        if dm == "open" or "*" in allow:
            access_mode, allow_count = "open", 0
        else:
            access_mode = "owner" if len(allow) <= 1 else "list"
            allow_count = len(allow)
        ok, username, _ = _telegram_get_me(token)
        now_ms = int(time.time() * 1000)
        state["telegram"] = {
            "status": "linked",
            "botUsername": username if ok else None,
            "accessMode": access_mode,
            "allowFrom": [] if access_mode == "open" else allow,
            "allowCount": allow_count,
            "linkedAt": now_ms,
            "lastSyncAt": now_ms,
        }
        _write_channels_state(state)
        _log(
            f"derived telegram state from openclaw.json "
            f"(bot=@{username or '?'} mode={access_mode})"
        )
    except Exception as e:  # noqa: BLE001
        _log(f"_derive_telegram_state_if_missing: {e}")


# ── Drive → memory-wiki sync (KB del Owner, ON-DEMAND) ─────────
#
# El command `drive_wiki_sync` sincroniza la carpeta de Drive bindeada del
# Owner al vault de `memory-wiki`, para que el agente la busque con
# `wiki_search`. Drive→texto vía la CF `driveReadApi` (HMAC del nodo, ya
# incluye PDF/Slides con `asText`); ingesta con `openclaw wiki ingest` +
# `compile`. Detección de cambios por `modifiedTime` (solo re-ingesta lo
# nuevo). SIN timer — lo dispara el app, para no quemar llamadas al CF al
# escalar la flota.

_DRIVE_READ_URL = os.environ.get(
    "TNODE_DRIVE_URL",
    f"https://us-central1-{PROJECT_ID}.cloudfunctions.net/driveReadApi",
)
_WIKI_SYNC_STATE = OPENCLAW_DIR / "wiki" / ".drive-sync-state.json"
_WIKI_TEXT_GOOGLE = {
    "application/vnd.google-apps.document",
    "application/vnd.google-apps.spreadsheet",
    "application/vnd.google-apps.presentation",
}


def _drive_sign(cfg: dict, action: str) -> dict:
    ts = str(int(time.time() * 1000))
    nonce = py_secrets.token_hex(16)
    sig = hmac.new(
        cfg["nodeSecret"].encode("utf-8"),
        f'{cfg["nodeId"]}:{ts}:{nonce}:drive:{action}'.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    return {
        "action": action, "nodeId": cfg["nodeId"],
        "timestamp": ts, "nonce": nonce, "signature": sig,
    }


def _drive_call(cfg: dict, action: str, params: dict, raw: bool = False, timeout: int = 90):
    body = json.dumps({**_drive_sign(cfg, action), "params": params}).encode("utf-8")
    req = urllib.request.Request(
        _DRIVE_READ_URL, data=body,
        headers={"Content-Type": "application/json"}, method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read()
        if raw:
            return r.headers.get("x-mime-type", ""), data.decode("utf-8", "replace")
        return json.loads(data)


def _drive_is_text(mime: str, name: str) -> bool:
    if mime in _WIKI_TEXT_GOOGLE or mime == "application/pdf":
        return True
    if mime.startswith("text/") or "markdown" in mime or "csv" in mime or mime == "application/json":
        return True
    return bool(re.search(r"\.(pdf|txt|md|csv|json)$", name, re.I))


def _drive_walk(cfg: dict, folder_id, acc: list, seen: set) -> None:
    res = _drive_call(cfg, "list", {"folderId": folder_id} if folder_id else {})
    for e in res.get("entries", []):
        fid = e.get("id")
        if not fid or fid in seen:
            continue
        seen.add(fid)
        if e.get("isFolder"):
            _drive_walk(cfg, fid, acc, seen)
        else:
            acc.append(e)


def _drive_slug(name: str) -> str:
    """Slug para el vault. Compatible con IDs que generaba `wiki ingest`
    sobre el archivo temporal `dws_<safe>.md`."""
    safe = re.sub(r"[^\w.\- ]", "_", name).strip().replace(" ", "_") or "file"
    if not re.search(r"\.(md|txt)$", safe, re.I):
        safe += ".md"
    base = f"dws_{safe[:-3]}"  # strip .md → e.g. dws_Pitch_Plataforma_Agentes_IA.pdf
    return re.sub(r"[^a-z0-9]+", "-", base.lower()).strip("-") or "untitled"


def _wiki_write_source(
    vault_dir: Path,
    slug: str,
    title: str,
    content: str,
    now_iso: str,
) -> None:
    """Escribe una página source directo al vault sin subprocess wiki ingest."""
    src_file = vault_dir / "sources" / f"{slug}.md"
    src_file.parent.mkdir(parents=True, exist_ok=True)
    ingested_at = now_iso
    human_block = "<!-- openclaw:human:start -->\n<!-- openclaw:human:end -->"
    related_block = (
        "<!-- openclaw:wiki:related:start -->\n"
        "- No related pages yet.\n"
        "<!-- openclaw:wiki:related:end -->"
    )
    if src_file.exists():
        old = src_file.read_text()
        m = re.search(r"ingestedAt:\s*(\S+)", old)
        if m:
            ingested_at = m.group(1)
        m2 = re.search(r"<!-- openclaw:human:start -->.*?<!-- openclaw:human:end -->", old, re.S)
        if m2:
            human_block = m2.group(0)
        m3 = re.search(
            r"<!-- openclaw:wiki:related:start -->.*?<!-- openclaw:wiki:related:end -->", old, re.S
        )
        if m3:
            related_block = m3.group(0)
    byte_count = len(content.encode("utf-8"))
    src_file.write_text(
        f"---\n"
        f"pageType: source\n"
        f"id: source.{slug}\n"
        f"title: {title}\n"
        f"sourceType: local-file\n"
        f"sourcePath: /drive/{slug}\n"
        f"ingestedAt: {ingested_at}\n"
        f"updatedAt: {now_iso}\n"
        f"status: active\n"
        f"---\n\n"
        f"# {title}\n\n"
        f"## Source\n"
        f"- Type: `local-file`\n"
        f"- Path: `/drive/{slug}`\n"
        f"- Bytes: {byte_count}\n"
        f"- Updated: {now_iso}\n\n"
        f"## Content\n"
        f"```text\n"
        f"{content.strip()}\n"
        f"```\n\n"
        f"## Notes\n"
        f"{human_block}\n\n"
        f"## Related\n"
        f"{related_block}\n"
    )


def handle_drive_wiki_sync(token: dict, params: dict) -> dict:
    """Sincroniza la carpeta de Drive bindeada del Owner al vault de memory-wiki.
    On-demand (lo dispara el app). Detección por modifiedTime; solo re-ingesta
    lo nuevo/cambiado. Devuelve {scanned, ingested, lastSyncAt}."""
    cfg = load_config()
    if not cfg.get("nodeId") or not cfg.get("nodeSecret"):
        return {"status": "error", "result": {"error": "node_not_configured"}}
    # Asegurar memory-wiki habilitado + vault iniciado (idempotente).
    _run_openclaw("plugins", "enable", "memory-wiki", timeout=30)
    _run_openclaw("wiki", "init", timeout=60)
    # Estado previo (fileId -> {modifiedTime, name}).
    state: dict = {}
    try:
        if _WIKI_SYNC_STATE.exists():
            state = json.loads(_WIKI_SYNC_STATE.read_text())
    except Exception:  # noqa: BLE001
        state = {}
    files: list = []
    try:
        _drive_walk(cfg, None, files, set())
    except Exception as e:  # noqa: BLE001
        return {"status": "error", "result": {"error": f"drive_list_failed: {str(e)[:200]}"}}
    ingested = 0
    for entry in files:
        fid = entry.get("id")
        name = entry.get("name", fid)
        mime = entry.get("mimeType", "")
        mt = entry.get("modifiedTime", "")
        if not fid or not _drive_is_text(mime, name):
            continue
        if mt and state.get(fid, {}).get("modifiedTime") == mt:
            continue
        try:
            _, text = _drive_call(cfg, "get", {"fileId": fid, "asText": True}, raw=True)
        except Exception as ex:  # noqa: BLE001
            _log(f"drive_wiki_sync: get failed {name}: {ex}")
            continue
        slug = _drive_slug(name)
        now_iso = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
        try:
            _wiki_write_source(OPENCLAW_DIR / "wiki" / "main", slug, name, text, now_iso)
        except Exception as ex:  # noqa: BLE001
            _log(f"drive_wiki_sync: write failed {name}: {ex}")
            continue
        state[fid] = {"modifiedTime": mt, "name": name}
        ingested += 1
    if ingested:
        _run_openclaw("wiki", "compile", timeout=120)
    try:
        _WIKI_SYNC_STATE.parent.mkdir(parents=True, exist_ok=True)
        _WIKI_SYNC_STATE.write_text(json.dumps(state, indent=2))
    except Exception as ex:  # noqa: BLE001
        _log(f"drive_wiki_sync: state write failed: {ex}")
    last = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    _log(f"drive_wiki_sync: scanned={len(files)} ingested={ingested}")
    return {
        "status": "done",
        "result": {"scanned": len(files), "ingested": ingested, "lastSyncAt": last},
    }


# ── Dispatcher ─────────────────────────────────────────────────

_HANDLERS = {
    "push_openclaw_config": lambda token, params: {
        "status": "done",
        "result": {"llmMode": push_openclaw_config(token)["llmMode"]},
    },
    "update_llm_provider": handle_update_llm_provider,
    "set_agent_params": handle_set_agent_params,
    "restart_openclaw": handle_restart_openclaw,
    "detect_local_models": handle_detect_local_models,
    "apply_openrouter_key": handle_apply_openrouter_key,
    "drive_wiki_sync": handle_drive_wiki_sync,
    "install_subagent": handle_install_subagent,
    "uninstall_subagent": handle_uninstall_subagent,
    "restart_gateway_for_subagents": handle_restart_gateway_for_subagents,
    "mcp.install": handle_mcp_install,
    "mcp.remove": handle_mcp_remove,
    "mcp.oauth.begin": handle_mcp_oauth_begin,
    "mcp.oauth.complete": handle_mcp_oauth_complete,
    "restart_gateway_for_mcp": handle_restart_gateway_for_mcp,
    "channels.email.link": handle_channels_email_link,
    "channels.email.unlink": handle_channels_email_unlink,
    "channels.telegram.link": handle_channels_telegram_link,
    "channels.telegram.unlink": handle_channels_telegram_unlink,
    "channels.telegram.access": handle_channels_telegram_access,
}

# Tipos que ESTE daemon procesa. `query_pending_commands` (v1.6.0+)
# filtra por estos, así no se lleva commands de otros daemons (cron.*,
# tasks.* viven en tnode-chat-sync). Sin este filtro, el handler genérico
# marcaba como `error: unknown_command_type` antes de que el daemon
# dueño tuviera chance de procesarlos.
_HANDLED_TYPES = tuple(sorted(_HANDLERS.keys()))


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

def _run_declarative_sync(token: dict) -> None:
    """Prime the five hash fields in ONE masked GET, then render every
    declarative file (TOOLS/SOUL/IDENTITY/USER/TEAM) whose hash changed.
    Shared by the slow safety-timer in the main loop and the SessionStart
    DECL_ONESHOT hook. Each step is individually resilient (swallows its own
    errors), so one bad target never aborts the rest."""
    _prime_node_fields(
        token,
        ["toolsHash", "soulHash", "identityHash", "userHash", "teamIndexHash"],
    )
    # Reflect channel state to Firestore + the one-time v1.1 migration, then
    # render the managed zone of TOOLS.md (cheap hash check; only rewrites on
    # change; failures swallowed so the file is never left half-written).
    _sync_channels_to_firestore(token)
    _migrate_tools_v11()
    _sync_tools_md_from_json(token)
    # SOUL.md / IDENTITY.md: same declarative mechanic (one-time migrate +
    # hash-rendered managed zone).
    for _md_target in ("soul", "identity"):
        _md_migrate(_md_target)
        _md_sync_from_json(token, _md_target)
    # USER.md: owner profile (no migrate; curated content preserved below).
    _md_sync_from_json(token, "user")
    # TEAM_INDEX.md: peer roster (dedicated file, hash-rendered; gone if no peers).
    _team_index_sync_from_json(token)
    # Guest workspace SOUL.md: render the owner's Business Profile so the guest
    # agent knows the business it represents (needs the token to read the
    # node-scoped config/businessProfile doc).
    _ensure_guest_business_section(token)
    _clear_node_fields_cache()


def run_decl_oneshot() -> int:
    """Refresh the declarative files from Firestore once, then exit. Wired as an
    OpenClaw SessionStart hook so the workspace is current the moment a user
    opens a session — replacing the background poll, so reads scale with real
    usage (an idle node reads nothing). Primes all five hashes in ONE read; only
    rewrites the files whose hash changed.

    ALWAYS returns 0: a SessionStart hook must never block the session. Any
    failure (token mint, network) just leaves the existing files in place — the
    slow safety-timer and the next session-start catch up."""
    try:
        cfg = load_config()
        token = mint_token(cfg)
        _run_declarative_sync(token)
        _log("decl-oneshot: declarative refresh complete")
    except Exception as e:  # noqa: BLE001
        _log(f"decl-oneshot failed (non-fatal): {e}")
    return 0


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


def _drain_commands(token: dict) -> int:
    """Procesa TODOS los commands pendientes de la cola una vez; devuelve cuántos.
    Usado por el wake-drain oneshot (camino PRIMARIO) y por el poll-backstop del
    daemon. Re-lanza HTTPError 401 para que el caller refresque el token."""
    cmds = query_pending_commands(token)
    for cmd in cmds:
        _log(f"handling cmd {cmd['id']} type={cmd['type']}")
        try:
            update_command(token, cmd["id"], {"status": "running"})
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
                raise  # caller refresca el token
            _log(f"cmd {cmd['id']} HTTP error: {e.code} {e.reason}")
            try:
                update_command(token, cmd["id"], {
                    "status": "error", "result": {"error": f"http_{e.code}"},
                    "completedAt": int(time.time() * 1000),
                })
            except Exception:
                pass
        except Exception as e:  # noqa: BLE001
            _log(f"cmd {cmd['id']} error: {e}")
            try:
                update_command(token, cmd["id"], {
                    "status": "error", "result": {"error": str(e)[:500]},
                    "completedAt": int(time.time() * 1000),
                })
            except Exception:
                pass
    return len(cmds)


def run_command_drain_oneshot() -> int:
    """Drena la cola de commands UNA vez y sale — camino PRIMARIO, disparado por
    el WAKE del app (Dashboard→Chat) vía el file-watcher .path. Sin polling."""
    try:
        cfg = load_config()
        token = mint_token(cfg)
        n = _drain_commands(token)
        _log(f"drain-oneshot: processed {n} command(s)")
        return 0
    except Exception as e:  # noqa: BLE001
        _log(f"drain-oneshot failed: {e}")
        return 1


def _guest_agent_present() -> bool:
    """True if the `guest` agent entry is already in openclaw.json."""
    try:
        cfg = json.loads(OPENCLAW_JSON_PATH.read_text())
    except Exception:  # noqa: BLE001
        return False
    agents_list = cfg.get("agents", {}).get("list", [])
    return isinstance(agents_list, list) and any(
        isinstance(a, dict) and a.get("id") == "guest" for a in agents_list
    )


def _run_startup_self_heal() -> bool:
    """Run the idempotent startup self-heal (agents index, workspace dirs,
    skills, guest agent).

    Returns True when nothing more should be attempted (success, or a
    non-retryable error already logged). Returns False ONLY on the snapshot
    boot race: the daemon (user `tnode`) started before the installer chowned
    openclaw.json to `tnode`, so the agents.list write isn't possible yet —
    signalling main() to retry on the next loop tick until it lands, so a
    freshly-provisioned node materializes the `guest` agent (Opción B) without
    a manual config-sync restart."""
    try:
        _regenerate_agents_index()
        _ensure_workspace_dirs()
        _ensure_workspace_skills()
        _ensure_guest_agent()
    except PermissionError as e:
        _log(f"self-heal deferred (boot race, will retry): {e}")
        return False
    except Exception as e:  # noqa: BLE001
        _log(f"startup self-heal failed: {e}")
        return True
    # Confirm the guest entry actually landed. If openclaw.json wasn't readable
    # or present yet (boot race), the ensure was a silent no-op — keep retrying.
    if _guest_agent_present():
        return True
    _log("self-heal: guest agent not present yet (openclaw.json not ready) — will retry")
    return False


def main() -> int:
    if DECL_ONESHOT:
        return run_decl_oneshot()
    if ONESHOT:
        return run_oneshot()
    if DRAIN_ONESHOT:
        return run_command_drain_oneshot()

    try:
        cfg = load_config()
    except Exception as e:  # noqa: BLE001
        _log(f"config error: {e}")
        return 2

    _log(f"starting tnode-config-sync for nodeId={cfg['nodeId']}")
    # Self-heal: regenerate AGENTS_INDEX.md and ensure the workspace
    # references survive workspace drift (e.g. user wiped SOUL.md
    # manually, or the node was provisioned before v1.4.0). Best-effort
    # — failures here are logged but don't prevent the daemon loop. On a
    # snapshot-provisioned node this races the installer's chown of
    # openclaw.json (see _run_startup_self_heal); main() retries in the loop
    # below until the guest agent (Opción B) materializes — no manual restart.
    self_heal_done = _run_startup_self_heal()
    # Reflect a hand-configured Telegram channel (openclaw.json) into
    # channels-state.json so the mobile widget shows it without a re-link.
    _derive_telegram_state_if_missing()
    token: dict | None = None
    backoff = 1.0
    empty_polls = 0
    decl_bootstrap_done = False  # one-time declarative refresh on daemon startup

    # Push initial state on startup so Firestore reflects current openclaw.json
    # even if the file hasn't changed since last boot.
    startup_pushed = False

    while True:
        try:
            now = int(time.time())
            # Boot-race backstop: if the startup self-heal couldn't write
            # openclaw.json yet (daemon started before the installer's chown),
            # keep retrying every tick until the guest agent lands.
            if not self_heal_done:
                self_heal_done = _run_startup_self_heal()
                if self_heal_done:
                    _log("startup self-heal completed on loop retry (boot race cleared)")
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

            # Drena la cola (BACKSTOP). El camino primario es el WAKE: el app
            # dispara el drain-oneshot (DRAIN_ONESHOT) al pasar Dashboard→Chat.
            # Aquí solo barremos cada POLL_IDLE_S (300s) por si se perdió un wake.
            try:
                n_processed = _drain_commands(token)
            except urllib.error.HTTPError as e:
                if e.code == 401:
                    token = None
                    continue
                raise
            empty_polls = 0 if n_processed else empty_polls + 1

            # Declarative .md refresh is event-driven (NO periodic poll): on a
            # new session, tnode-chat-sync spawns this daemon with
            # DECL_ONESHOT=1. We only refresh ONCE here, on startup, so the
            # files are current right after a reboot/restart even before the
            # first session arrives.
            if not decl_bootstrap_done:
                _run_declarative_sync(token)
                decl_bootstrap_done = True

            # Stay on the active cadence while the self-heal is still pending
            # so a snapshot-provisioned node materializes the guest agent
            # quickly once openclaw.json becomes writable (boot-race fix).
            interval = (
                POLL_IDLE_S
                if (self_heal_done and empty_polls >= IDLE_AFTER)
                else POLL_ACTIVE_S
            )
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
            install_config_sync_wake_systemd
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

install_config_sync_wake_systemd() {
    if ! command_exists systemctl; then
        return 0
    fi
    _systemd_update_only_handled "tnode-config-sync-wake" && return 0

    local systemd_dir="/etc/systemd/system"

    cat > "$systemd_dir/tnode-config-sync-wake.service" <<SVCUNIT
[Unit]
Description=TNode config-sync — drain command queue once (wake)

[Service]
Type=oneshot
User=${TNODE_USER}
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=HOME=${TNODE_HOME}
Environment=OPENCLAW_HOME=${OPENCLAW_HOME}
Environment=TNODE_CONFIG_SYNC_DRAIN=1
ExecStart=/usr/bin/env python3 ${OPENCLAW_HOME}/scripts/tnode_config_sync.py
StandardOutput=append:${OPENCLAW_HOME}/logs/tnode-config-sync-wake.out.log
StandardError=append:${OPENCLAW_HOME}/logs/tnode-config-sync-wake.err.log
SVCUNIT

    cat > "$systemd_dir/tnode-config-sync-wake.path" <<PATHU
[Unit]
Description=Watch .wake and drain the command queue once (Dashboard→Chat wake)

[Path]
PathModified=${OPENCLAW_HOME}/.wake
Unit=tnode-config-sync-wake.service

[Install]
WantedBy=multi-user.target
PATHU

    systemctl daemon-reload
    systemctl enable --now tnode-config-sync-wake.path 2>/dev/null || true
    success "systemd tnode-config-sync-wake.path habilitado"
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

Chat outbox (v1.17.0+): the app writes user messages to chats/ with
delivery="pending"; when the direct WS path didn't deliver them, this
daemon injects them into the local gateway (ephemeral WS, chat.send with
the original idempotencyKey) and flips delivery="node". Firestore is the
guaranteed messaging path; the direct WS is just the low-latency one.

Shared-agent guests (v1.18.0+): other users can join this agent via an
invite link (see architecture_shared_agent_links.md). A guest chats from
their OWN space `users/<guestUid>/nodes/<nodeId>/chats` with a per-guest
sessionKey `tnode-guest-<guestUid>__<uuid>`. The outbox consumer adds a
collection-group sweep (nodeId==, delivery==pending, role==user) so a
single query covers every guest, validates each message's owner against
`nodeSyncRegistrations/<nodeId>/members/` (the authz source of truth), and
routes the assistant reply back to the guest's space by reading the uid
embedded in the sessionKey. The guest never pairs with the gateway.

Env/overrides:
  TNODE_CHAT_SYNC_CONFIG    Path to config JSON (default ~/.openclaw/tnode-chat-sync.json)
  TNODE_CHAT_SYNC_SESSIONS  Sessions dir (default ~/.openclaw/agents/<agent>/sessions)
  TNODE_CHAT_SYNC_LOG       Log file (default ~/.openclaw/logs/tnode-chat-sync.log)
  TNODE_CHAT_SYNC_POLL_MS   Polling interval ms (default 500)
  TNODE_CHAT_SYNC_OUTBOX_HOT_S / _OUTBOX_IDLE_S  Outbox poll cadence
  TNODE_CHAT_SYNC_GATEWAY_WS  Gateway WS url (default ws://127.0.0.1:18789)
  TNODE_CHAT_SYNC_DECL_THROTTLE_S  Min seconds between declarative-refresh spawns (default 5)
"""
from __future__ import annotations
# 1.26.0 — Fresh-node guest DELIVERY fix: the session tailer now re-resolves
#          `agents/*/sessions` on EVERY pass and ADDS new dirs, instead of only
#          re-resolving while the watched set was empty. On a snapshot-
#          provisioned node `agents/guest/sessions` is created only on the FIRST
#          guest turn — after the daemon started AND after `agents/main/sessions`
#          already appeared — so the one-shot resolution never watched it and the
#          guest's replies were never mirrored to Firestore (guest stuck on
#          "escribiendo" until a manual chat-sync restart). Additive + inode-keyed
#          offsets mean a dir is never dropped or re-read once seen. Pairs with
#          config-sync 1.28.0 (guest agent materializes through the boot race) to
#          make Opción B born-ready for guests on fresh nodes.
# 1.25.0 — Per-guest agent routing (Opción B): inject guest sessions under the
#          dedicated `guest` agent by prefixing the injected sessionKey with
#          `agent:guest:` (the gateway honors the prefix, verified E2E
#          2026-06-22) so guests never load the owner's main workspace
#          (USER.md/MEMORY.md/memory). The tailer now watches ALL
#          `agents/*/sessions` dirs (flush_turn already filters to
#          tnode-mobile/tnode-guest), so the guest agent's replies get mirrored
#          to each guest's own space.
# 1.23.0 — Declarative refresh trigger: when the session tailer sees a brand-new
#          live session, spawn tnode-config-sync DECL_ONESHOT to refresh the
#          workspace .md (throttled, fire-and-forget). Replaces config-sync's
#          Firestore poll → Document reads scale with sessions, not the clock.
__VERSION__ = "1.26.0"

import hashlib
import hmac
import json
import mimetypes
import os
import re
import secrets as py_secrets
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
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


def _http_error_body(e: urllib.error.HTTPError) -> str:
    """Best-effort error body for logs (e.g. mint 409 `not_paired` vs
    `no_secret` — opaque "Conflict" cost us hours on 2026-06-10)."""
    try:
        return e.read().decode("utf-8", "replace")[:200]
    except Exception:  # noqa: BLE001
        return ""


def mint_token(cfg: dict) -> dict:
    """Request a fresh Firebase custom token + exchange for idToken.

    Returns {idToken, uid, nodeId, expiresAt (epoch seconds)}.

    Scope `sync_admin` is requested explicitly (v1.11.0+) so the daemon
    can update `commands/{cmdId}` docs from cron CRUD handlers. The
    chat-write rule on chats/ is satisfied by uid==owner regardless of
    scope, so this is backward-compatible with the existing chat write
    path.
    """
    ts = str(int(time.time() * 1000))
    nonce = py_secrets.token_hex(16)
    scope = "sync_admin"
    mac = hmac.new(
        cfg["nodeSecret"].encode("utf-8"),
        f'{cfg["nodeId"]}:{ts}:{nonce}:{scope}'.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    mint_resp = _http_post_json(
        cfg["mintUrl"],
        {
            "nodeId": cfg["nodeId"],
            "timestamp": ts,
            "nonce": nonce,
            "signature": mac,
            "scope": scope,
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
        # Sentinel: client-supplied timestamp → emit as Firestore timestampValue
        # (REST PATCH cannot use real server-side serverTimestamp transforms
        # without commitWriteRequests; clock drift on the node is tolerable
        # for `mirroredAt` style fields).
        if v.get("__server_timestamp__") is True:
            return {"timestampValue": time.strftime(
                "%Y-%m-%dT%H:%M:%SZ", time.gmtime()
            )}
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
# OpenClaw's media store — where the image_generate / video_generate / tts
# tools write their output (e.g. media/tool-image-generation/<name>.png).
# The media-delivery bridge copies files from here into workspace/download/.
MEDIA_DIR = OPENCLAW_DIR / "media"


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
    cfg: dict, file_path: Path, sha: str, size: int, mime: str,
    target_uid: str | None = None,
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
    # Shared-agent guest: land the assistantFiles doc in the guest's space.
    if target_uid:
        body["targetUid"] = target_uid
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


def _confirm_assistant_file(
    cfg: dict, attachment_id: str, target_uid: str | None = None
) -> bool:
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
    if target_uid:
        body["targetUid"] = target_uid
    try:
        _http_post_json(CONFIRM_ASSISTANT_FILE_URL, body)
        return True
    except Exception as e:  # noqa: BLE001
        _log(f"confirmAssistantFile error: {e}")
        return False


def _process_one_marker(
    cfg: dict, raw_path: str, target_uid: str | None = None
) -> str | None:
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
    prep = _prepare_assistant_file(cfg, resolved, sha, size, mime, target_uid)
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
    if not _confirm_assistant_file(cfg, attachment_id, target_uid):
        # Doc is in `preparing` state — cleanup will reap after TTL. Still
        # not safe to rewrite the marker because the client needs `uploaded`
        # to render.
        return None
    _log(f"adjunto uploaded: {resolved.name} → attachmentId={attachment_id}")
    return attachment_id


def process_assistant_file_markers(
    cfg: dict, content: str, target_uid: str | None = None
) -> str:
    """Walk every `[adjunto: <path>]` in content, upload each, rewrite to
    `[archivo:{id}]`. On failure, the marker becomes `[adjunto-error: ...]`
    so the user sees why their file didn't come through.

    `target_uid` (shared-agent guest) routes the uploaded file's assistantFiles
    doc into the guest's space so their app can resolve `[archivo:id]`.

    Idempotent: an already-rewritten `[archivo:{id}]` won't match the
    regex and stays as-is, so retries of the same trajectory entry don't
    re-upload."""

    def replace(m: re.Match) -> str:
        raw_path = m.group(1).strip()
        attachment_id = _process_one_marker(cfg, raw_path, target_uid)
        if attachment_id:
            return f"[archivo:{attachment_id}]"
        return "[adjunto-error: no se pudo subir el archivo]"

    return ASSISTANT_FILE_MARKER_RE.sub(replace, content)


# ── Crons mirror + CRUD via commands/ (v1.11.0+) ──────────────────
#
# `openclaw cron list --json` enumera los cron jobs configurados en la
# gateway. Cada N segundos los reflejamos a Firestore
# `users/{uid}/nodes/{nodeId}/crons/{cronId}` para que la app cliente los
# muestre como cards en el widget "Recurrencias" sin necesidad de
# conexión WS al gateway.
#
# Commands CRUD del cliente llegan via `users/{uid}/nodes/{nodeId}/commands/{id}`
# con `type` en {`cron.add`, `cron.edit`, `cron.rm`, `cron.enable`,
# `cron.disable`}. Ejecutamos el CLI correspondiente y marcamos status.

CRON_MIRROR_INTERVAL_S = float(
    os.environ.get("TNODE_CHAT_SYNC_CRON_MIRROR_S", "10.0")
)
CRON_COMMAND_POLL_INTERVAL_S = float(
    os.environ.get("TNODE_CHAT_SYNC_CRON_CMD_S", "3.0")
)


_OPENCLAW_JSON = OPENCLAW_DIR / "openclaw.json"
_cron_cli_token_cache: dict = {"value": None, "mtime": 0.0}


def _read_gateway_token() -> str | None:
    """Read `gateway.auth.token` from `~/.openclaw/openclaw.json`. Cached
    until the file mtime changes (token rotation via re-install)."""
    try:
        st = _OPENCLAW_JSON.stat()
    except OSError:
        return None
    if _cron_cli_token_cache["mtime"] == st.st_mtime:
        return _cron_cli_token_cache["value"]
    try:
        with open(_OPENCLAW_JSON, "r") as f:
            cfg = json.load(f)
        tok = ((cfg.get("gateway") or {}).get("auth") or {}).get("token")
    except (OSError, json.JSONDecodeError):
        tok = None
    _cron_cli_token_cache["value"] = tok
    _cron_cli_token_cache["mtime"] = st.st_mtime
    return tok


# Per-node Path B cutover state, sourced from Firestore
# `users/{uid}/nodes/{nodeId}.transportEnabled` — the SAME field the Flutter
# client reads to switch its chat transport, so the app and this daemon flip
# from one source of truth (no openclaw.json `mode`, which the recognition-only
# channel schema doesn't even allow). The main loop refreshes this cache (it
# owns the minted token); the hot-path gate just reads it. Default False
# (webchat) until Firestore proves otherwise.
_TNODE_TRANSPORT_TTL_S = 10.0
_tnode_transport_cache: dict = {"active": False, "ts": 0.0}


def _refresh_tnode_transport_active(
    token: dict, project_id: str, node_id: str
) -> None:
    """Refresh `_tnode_transport_cache` from Firestore
    `users/{uid}/nodes/{nodeId}.transportEnabled`. TTL-gated (≈1 GET per
    _TNODE_TRANSPORT_TTL_S). Called from the main loop, which owns the token.
    Fail-safe: a 404 (node doc absent) means NOT cut over; transient errors
    keep the last known value so a blip doesn't flip the chat path."""
    now = time.time()
    if now - _tnode_transport_cache["ts"] < _TNODE_TRANSPORT_TTL_S:
        return
    uid = token.get("uid")
    if not uid:
        return
    # Throttle to one attempt per TTL window regardless of outcome, so a
    # persistent Firestore error can't hammer the GET every loop iteration.
    _tnode_transport_cache["ts"] = now
    url = f"{_firestore_base(project_id)}/users/{uid}/nodes/{node_id}"
    headers = {"Authorization": f"Bearer {token['idToken']}"}
    new_active = None
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as resp:
            doc = json.loads(resp.read().decode("utf-8"))
        fields = doc.get("fields") or {}
        new_active = bool(
            (fields.get("transportEnabled") or {}).get("booleanValue", False)
        )
    except urllib.error.HTTPError as e:
        if e.code == 404:
            new_active = False  # node doc not created yet → not cut over
        # else transient (401/5xx) → leave new_active None (keep last value)
    except (OSError, json.JSONDecodeError):
        pass  # transient → keep last value
    if new_active is None:
        return  # transient error — keep last known value, retry next window
    if new_active != _tnode_transport_cache["active"]:
        _log(f"tnode Path B cutover flag -> {new_active} (node={node_id})")
    _tnode_transport_cache["active"] = new_active


def _tnode_channel_active() -> bool:
    """True when the node is cut over to the Path B transport: the Flutter app
    sends turns over the `tnode-transport` plugin (its own WS endpoint) and the
    plugin owns chat persistence. While active, chat-sync stands aside for the
    CHAT path — inbound outbox consumer (`process_outbox`) + outbound TEXT
    mirror (`flush_turn`) — so it doesn't double-process. Media bridging
    (media-turns + orphan sweep) stays ON: the plugin can't deliver
    tool-generated media (the message-tool wake fails on tnode-mobile
    regardless of transport). Sourced from Firestore via
    `_refresh_tnode_transport_active` (main loop) — the SAME per-node
    `transportEnabled` flag the client reads, one source of truth."""
    return bool(_tnode_transport_cache["active"])


def _cli_env() -> dict:
    """Env for spawning the `openclaw` CLI. The CLI treats OPENCLAW_HOME as the
    PARENT of the config dir (it appends `.openclaw`), while this daemon uses
    OPENCLAW_HOME as the config dir itself. Inheriting our value makes the CLI
    resolve a doubled `.openclaw/.openclaw/` path (phantom device identities,
    stray restart-intents, failed cron/CLI calls). Point it at the parent so
    the CLI lands on the real config dir."""
    env = os.environ.copy()
    env["OPENCLAW_HOME"] = str(OPENCLAW_DIR.parent)
    return env


def _run_openclaw_cron(*args: str) -> tuple[int, str, str]:
    """Run `openclaw cron <args...>` and return (rc, stdout, stderr).
    Auto-injects `--token <gateway.auth.token>` so the CLI can connect
    to the local gateway WS — the daemon runs in the same user account
    as the gateway so reading the master token from openclaw.json is
    legitimate (this is the same file the gateway itself reads)."""
    token = _read_gateway_token()
    final_args: list[str] = list(args)
    # Append token only if caller didn't already include it.
    if token and "--token" not in final_args:
        final_args = [*final_args, "--token", token]
    try:
        result = subprocess.run(
            ["openclaw", "cron", *final_args],
            capture_output=True,
            text=True,
            timeout=30,
            env=_cli_env(),
        )
        return result.returncode, result.stdout, result.stderr
    except FileNotFoundError:
        # Probar npm-global path explícito si openclaw no está en PATH.
        for candidate in (
            Path.home() / ".npm-global/bin/openclaw",
            Path("/usr/local/bin/openclaw"),
            Path("/opt/homebrew/bin/openclaw"),
        ):
            if candidate.is_file():
                try:
                    result = subprocess.run(
                        [str(candidate), "cron", *final_args],
                        capture_output=True,
                        text=True,
                        timeout=30,
                        env=_cli_env(),
                    )
                    return result.returncode, result.stdout, result.stderr
                except Exception:  # noqa: BLE001
                    pass
        return -1, "", "openclaw binary not found"
    except subprocess.TimeoutExpired:
        return -1, "", "timeout"
    except Exception as e:  # noqa: BLE001
        return -1, "", str(e)


def _fetch_local_crons() -> list[dict] | None:
    """Returns the list of cron jobs as reported by `openclaw cron list --json`,
    or None on failure. Each job dict carries id, name, enabled, schedule,
    payload, delivery, state, agentId, etc."""
    rc, stdout, stderr = _run_openclaw_cron("list", "--json")
    if rc != 0:
        _log(f"cron list failed rc={rc}: {stderr[:200]}")
        return None
    try:
        data = json.loads(stdout)
        return list(data.get("jobs") or [])
    except json.JSONDecodeError as e:
        _log(f"cron list JSON decode error: {e}")
        return None


def _crons_collection_url(token: dict, project_id: str) -> str:
    base = _firestore_base(project_id)
    return f"{base}/users/{token['uid']}/nodes/{token['nodeId']}/crons"


def _query_existing_cron_ids(token: dict, project_id: str) -> set[str] | None:
    """List existing crons/{id} docs to compute which need delete on mirror."""
    url = _crons_collection_url(token, project_id) + "?pageSize=300"
    headers = {"Authorization": f"Bearer {token['idToken']}"}
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
        return {
            doc["name"].rsplit("/", 1)[-1]
            for doc in (data.get("documents") or [])
        }
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return set()
        _log(f"query crons failed: {e.code} {e.reason}")
        return None
    except Exception as e:  # noqa: BLE001
        _log(f"query crons error: {e}")
        return None


def _write_cron_doc(token: dict, project_id: str, job: dict) -> None:
    cron_id = job.get("id")
    if not cron_id:
        return
    base = _firestore_base(project_id)
    url = f"{base}/users/{token['uid']}/nodes/{token['nodeId']}/crons/{cron_id}"
    body = {
        "id": cron_id,
        "name": job.get("name") or cron_id,
        "enabled": bool(job.get("enabled", True)),
        "agentId": job.get("agentId") or "",
        "schedule": job.get("schedule") or {},
        "payload": job.get("payload") or {},
        "delivery": job.get("delivery") or {},
        "sessionTarget": job.get("sessionTarget") or "",
        "sessionKey": job.get("sessionKey") or "",
        "createdAtMs": job.get("createdAtMs"),
        "updatedAtMs": job.get("updatedAtMs"),
        "nextRunAtMs": (job.get("state") or {}).get("nextRunAtMs"),
        "mirroredAt": {"__server_timestamp__": True},
    }
    headers = {"Authorization": f"Bearer {token['idToken']}"}
    try:
        _http_patch_json(url, _fs_fields(body), headers)
    except urllib.error.HTTPError as e:
        _log(f"cron write {cron_id}: {e.code} {e.reason}")


def _delete_cron_doc(token: dict, project_id: str, cron_id: str) -> None:
    base = _firestore_base(project_id)
    url = f"{base}/users/{token['uid']}/nodes/{token['nodeId']}/crons/{cron_id}"
    headers = {"Authorization": f"Bearer {token['idToken']}"}
    try:
        req = urllib.request.Request(url, method="DELETE", headers=headers)
        urllib.request.urlopen(req, timeout=15).close()
    except Exception as e:  # noqa: BLE001
        _log(f"cron delete {cron_id}: {e}")


def process_crons_mirror(token: dict, project_id: str) -> None:
    """Sync `openclaw cron list --json` → Firestore `crons/`.
    Upserts each present job; deletes Firestore docs for jobs no longer
    in the local list. Idempotent — safe to call frequently."""
    jobs = _fetch_local_crons()
    if jobs is None:
        return
    local_ids = {j.get("id") for j in jobs if j.get("id")}
    remote_ids = _query_existing_cron_ids(token, project_id)
    if remote_ids is None:
        # Couldn't enumerate — only do upserts, skip deletes to avoid
        # nuking docs by accident on a transient error.
        for job in jobs:
            _write_cron_doc(token, project_id, job)
        return
    for job in jobs:
        _write_cron_doc(token, project_id, job)
    for orphan in remote_ids - local_ids:
        _delete_cron_doc(token, project_id, orphan)


# ── Command handler ─────────────────────────────────────────────

_CRON_COMMAND_TYPES = frozenset({
    "cron.add", "cron.edit", "cron.rm",
    "cron.enable", "cron.disable",
})


def _build_cron_add_args(params: dict) -> list[str]:
    """Translate a `cron.add` command params dict into CLI flags.
    Required: name, schedule (every|cron|at), message.
    Optional: agent, sessionTarget, channel, announce, description."""
    args: list[str] = []
    name = (params.get("name") or "").strip()
    if name:
        args += ["--name", name]
    message = params.get("message")
    if isinstance(message, str) and message.strip():
        args += ["--message", message]
    every = params.get("every")
    if isinstance(every, str) and every.strip():
        args += ["--every", every]
    cron_expr = params.get("cron")
    if isinstance(cron_expr, str) and cron_expr.strip():
        args += ["--cron", cron_expr]
    at = params.get("at")
    if isinstance(at, str) and at.strip():
        args += ["--at", at]
    agent = params.get("agent") or "main"
    args += ["--agent", agent]
    session = params.get("sessionTarget")
    if isinstance(session, str) and session in ("main", "isolated"):
        args += ["--session", session]
    if params.get("announce", True):
        args += ["--announce"]
    if params.get("disabled"):
        args += ["--disabled"]
    desc = params.get("description")
    if isinstance(desc, str) and desc.strip():
        args += ["--description", desc]
    return args + ["--json"]


def _build_cron_edit_args(cron_id: str, params: dict) -> list[str]:
    args: list[str] = [cron_id]
    if "name" in params and isinstance(params["name"], str):
        args += ["--name", params["name"]]
    if "message" in params and isinstance(params["message"], str):
        args += ["--message", params["message"]]
    if "every" in params and isinstance(params["every"], str):
        args += ["--every", params["every"]]
    if "cron" in params and isinstance(params["cron"], str):
        args += ["--cron", params["cron"]]
    if "agent" in params and isinstance(params["agent"], str):
        args += ["--agent", params["agent"]]
    if "description" in params and isinstance(params["description"], str):
        args += ["--description", params["description"]]
    # NOTE: `openclaw cron edit` does NOT accept --json (only `add` and
    # `list` do). Including it makes the CLI fail with
    # "unknown option '--json'" and the edit is never applied.
    return args


def _execute_cron_command(cmd_type: str, params: dict) -> tuple[bool, str]:
    """Dispatch a `cron.*` command type to the openclaw CLI.
    Returns (ok, summary)."""
    cron_id = (params.get("id") or params.get("cronId") or "").strip()
    if cmd_type == "cron.add":
        args = _build_cron_add_args(params)
        rc, stdout, stderr = _run_openclaw_cron("add", *args)
        if rc != 0:
            return False, (stderr or stdout or f"rc={rc}")[:300]
        return True, "added"
    if cmd_type == "cron.edit":
        if not cron_id:
            return False, "missing id"
        args = _build_cron_edit_args(cron_id, params)
        rc, stdout, stderr = _run_openclaw_cron("edit", *args)
        if rc != 0:
            return False, (stderr or stdout or f"rc={rc}")[:300]
        return True, "edited"
    if cmd_type == "cron.rm":
        if not cron_id:
            return False, "missing id"
        rc, stdout, stderr = _run_openclaw_cron("rm", cron_id)
        if rc != 0:
            return False, (stderr or stdout or f"rc={rc}")[:300]
        return True, "removed"
    if cmd_type == "cron.enable":
        if not cron_id:
            return False, "missing id"
        rc, stdout, stderr = _run_openclaw_cron("enable", cron_id)
        if rc != 0:
            return False, (stderr or stdout or f"rc={rc}")[:300]
        return True, "enabled"
    if cmd_type == "cron.disable":
        if not cron_id:
            return False, "missing id"
        rc, stdout, stderr = _run_openclaw_cron("disable", cron_id)
        if rc != 0:
            return False, (stderr or stdout or f"rc={rc}")[:300]
        return True, "disabled"
    return False, f"unknown command type: {cmd_type}"


def _query_pending_cron_commands(token: dict, project_id: str) -> list[dict]:
    """Same shape as query_pending_uploads but for commands/ with
    cron.* type and status==pending."""
    parent = (
        f"projects/{project_id}/databases/(default)/documents"
        f"/users/{token['uid']}/nodes/{token['nodeId']}"
    )
    url = f"https://firestore.googleapis.com/v1/{parent}:runQuery"
    body = {
        "structuredQuery": {
            "from": [{"collectionId": "commands"}],
            "where": {
                "compositeFilter": {
                    "op": "AND",
                    "filters": [
                        {"fieldFilter": {
                            "field": {"fieldPath": "status"},
                            "op": "EQUAL",
                            "value": {"stringValue": "pending"},
                        }},
                        {"fieldFilter": {
                            "field": {"fieldPath": "type"},
                            "op": "IN",
                            "value": {"arrayValue": {"values": [
                                {"stringValue": t} for t in sorted(_CRON_COMMAND_TYPES)
                            ]}},
                        }},
                    ],
                }
            },
            "limit": 10,
        }
    }
    headers = {
        "Authorization": f"Bearer {token['idToken']}",
        "Content-Type": "application/json",
    }
    try:
        req = urllib.request.Request(
            url, data=json.dumps(body).encode(), headers=headers, method="POST"
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw = json.loads(resp.read())
    except Exception as e:  # noqa: BLE001
        _log(f"query cron commands failed: {e}")
        return []
    out = []
    for row in raw:
        if "document" not in row:
            continue
        doc = row["document"]
        cmd_id = doc["name"].rsplit("/", 1)[-1]
        fields = doc.get("fields") or {}
        cmd_type = (fields.get("type") or {}).get("stringValue", "")
        params_field = fields.get("params") or {}
        params = _fs_unwrap_map(params_field)
        out.append({"id": cmd_id, "type": cmd_type, "params": params})
    return out


def _fs_unwrap_map(field: dict) -> dict:
    """Unwrap a Firestore map field into a plain Python dict.
    Conservative — only handles the subset of types our commands use."""
    inner = field.get("mapValue", {}).get("fields", {})
    out: dict = {}
    for k, v in inner.items():
        if "stringValue" in v:
            out[k] = v["stringValue"]
        elif "booleanValue" in v:
            out[k] = v["booleanValue"]
        elif "integerValue" in v:
            try:
                out[k] = int(v["integerValue"])
            except (TypeError, ValueError):
                out[k] = 0
        elif "doubleValue" in v:
            out[k] = v["doubleValue"]
        elif "mapValue" in v:
            out[k] = _fs_unwrap_map({"mapValue": v["mapValue"]})
    return out


def _update_cron_command(
    token: dict, project_id: str, cmd_id: str, status: str, result: str
) -> None:
    base = _firestore_base(project_id)
    url = (
        f"{base}/users/{token['uid']}/nodes/{token['nodeId']}/commands/{cmd_id}"
        f"?updateMask.fieldPaths=status&updateMask.fieldPaths=result"
        f"&updateMask.fieldPaths=updatedAt"
    )
    body = {
        "status": status,
        "result": {"summary": result[:500]},
        "updatedAt": {"__server_timestamp__": True},
    }
    headers = {"Authorization": f"Bearer {token['idToken']}"}
    try:
        _http_patch_json(url, _fs_fields(body), headers)
    except urllib.error.HTTPError as e:
        _log(f"cron cmd update {cmd_id}: {e.code} {e.reason}")


def process_cron_commands(token: dict, project_id: str) -> None:
    """Pop pending cron.* commands, execute, mirror state (the mirror loop
    re-runs anyway, but doing it inline keeps the UI responsive)."""
    pending = _query_pending_cron_commands(token, project_id)
    if not pending:
        return
    for cmd in pending:
        cmd_id = cmd["id"]
        ok, summary = _execute_cron_command(cmd["type"], cmd["params"])
        new_status = "done" if ok else "error"
        _update_cron_command(token, project_id, cmd_id, new_status, summary)
        _log(f"cron cmd {cmd_id} type={cmd['type']} → {new_status}: {summary[:80]}")
    # Refresh mirror so the client sees the post-command state immediately.
    process_crons_mirror(token, project_id)


# ── Tasks mirror (v1.13.0+) ─────────────────────────────────────
#
# OpenClaw TaskFlow registra cada tarea durable (subagent run, cron
# trigger, CLI background spawn, ACP request) en
# `~/.openclaw/tasks/runs.sqlite` table `task_runs`. Cada N segundos
# mirroreamos un subconjunto a Firestore
# `users/{uid}/nodes/{nodeId}/tasks/{taskId}` para que el widget
# "Tareas" en la app cliente las muestre sin necesidad de conexión WS
# al gateway.
#
# Retención en Firestore (no podamos la SQLite local — esa la gobierna
# OpenClaw con cleanup_after):
#   - todas las tareas activas (`queued`, `running`)
#   - últimas TASKS_KEEP_TERMINATED terminadas por endedAt DESC
#   - el resto se borra del mirror (siguen vivas localmente)
#
# v1 es read-only — no hay commands/ para tasks (cancel + notify
# llegan en v2). El cliente Flutter solo lee la colección.

TASKS_MIRROR_INTERVAL_S = float(
    os.environ.get("TNODE_CHAT_SYNC_TASKS_MIRROR_S", "10.0")
)
TASKS_KEEP_TERMINATED = int(
    os.environ.get("TNODE_CHAT_SYNC_TASKS_KEEP", "30")
)

TASKS_DB_PATH = OPENCLAW_DIR / "tasks" / "runs.sqlite"

_TASKS_TERMINAL_STATUSES = frozenset({
    "succeeded", "failed", "timed_out", "cancelled", "lost",
})


def _fetch_local_tasks() -> list[dict] | None:
    """Read `task_runs` from the gateway's local SQLite. Returns a list of
    Firestore-shape dicts (camelCase) or None on error. Empty list when
    the DB exists but has no rows yet."""
    if not TASKS_DB_PATH.exists():
        return []
    try:
        # Read-only URI mode + short timeout. The gateway uses WAL so
        # readers don't block writers; mode=ro is the minimal lock.
        uri = f"file:{TASKS_DB_PATH}?mode=ro"
        conn = sqlite3.connect(uri, uri=True, timeout=2.0)
        conn.row_factory = sqlite3.Row
        rows = conn.execute("SELECT * FROM task_runs").fetchall()
        conn.close()
        return [_task_row_to_firestore(r) for r in rows]
    except sqlite3.Error as e:
        _log(f"tasks db read error: {e}")
        return None


def _task_row_to_firestore(row) -> dict:
    """Map a sqlite3.Row from `task_runs` to the camelCase shape the
    Flutter client expects (matches `TaskRun.fromMap`)."""
    d = dict(row)
    return {
        "taskId": d["task_id"],
        "runtime": d.get("runtime") or "",
        "taskKind": d.get("task_kind"),
        "sourceId": d.get("source_id"),
        "agentId": d.get("agent_id"),
        "runId": d.get("run_id"),
        "sessionKey": (
            d.get("requester_session_key")
            or d.get("child_session_key")
        ),
        "label": d.get("label"),
        "task": d.get("task") or "",
        "status": d.get("status") or "",
        "notifyPolicy": d.get("notify_policy"),
        "progressSummary": d.get("progress_summary"),
        "terminalSummary": d.get("terminal_summary"),
        "terminalOutcome": d.get("terminal_outcome"),
        "error": d.get("error"),
        "createdAtMs": d.get("created_at"),
        "startedAtMs": d.get("started_at"),
        "endedAtMs": d.get("ended_at"),
        "lastEventAtMs": d.get("last_event_at"),
    }


def _select_tasks_to_mirror(tasks: list[dict]) -> list[dict]:
    """Retention policy: all active + top N terminated by endedAt DESC."""
    active = [
        t for t in tasks
        if t["status"] not in _TASKS_TERMINAL_STATUSES
    ]
    terminated = [
        t for t in tasks
        if t["status"] in _TASKS_TERMINAL_STATUSES
    ]
    terminated.sort(
        key=lambda t: t.get("endedAtMs") or 0,
        reverse=True,
    )
    return active + terminated[:TASKS_KEEP_TERMINATED]


def _tasks_collection_url(token: dict, project_id: str) -> str:
    base = _firestore_base(project_id)
    return f"{base}/users/{token['uid']}/nodes/{token['nodeId']}/tasks"


def _query_existing_task_ids(
    token: dict, project_id: str,
) -> set[str] | None:
    """List existing tasks/{id} docs to compute deletes on mirror."""
    url = _tasks_collection_url(token, project_id) + "?pageSize=300"
    headers = {"Authorization": f"Bearer {token['idToken']}"}
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
        return {
            doc["name"].rsplit("/", 1)[-1]
            for doc in (data.get("documents") or [])
        }
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return set()
        _log(f"query tasks failed: {e.code} {e.reason}")
        return None
    except Exception as e:  # noqa: BLE001
        _log(f"query tasks error: {e}")
        return None


def _write_task_doc(token: dict, project_id: str, task: dict) -> None:
    task_id = task.get("taskId")
    if not task_id:
        return
    base = _firestore_base(project_id)
    url = (
        f"{base}/users/{token['uid']}/nodes/{token['nodeId']}"
        f"/tasks/{task_id}"
    )
    body = dict(task)
    body["mirroredAt"] = {"__server_timestamp__": True}
    headers = {"Authorization": f"Bearer {token['idToken']}"}
    try:
        _http_patch_json(url, _fs_fields(body), headers)
    except urllib.error.HTTPError as e:
        _log(f"task write {task_id}: {e.code} {e.reason}")


def _delete_task_doc(token: dict, project_id: str, task_id: str) -> None:
    base = _firestore_base(project_id)
    url = (
        f"{base}/users/{token['uid']}/nodes/{token['nodeId']}"
        f"/tasks/{task_id}"
    )
    headers = {"Authorization": f"Bearer {token['idToken']}"}
    try:
        req = urllib.request.Request(url, method="DELETE", headers=headers)
        urllib.request.urlopen(req, timeout=15).close()
    except Exception as e:  # noqa: BLE001
        _log(f"task delete {task_id}: {e}")


def process_tasks_mirror(token: dict, project_id: str) -> None:
    """Snapshot SQLite `task_runs` → Firestore `tasks/`. Idempotent."""
    all_tasks = _fetch_local_tasks()
    if all_tasks is None:
        return
    to_mirror = _select_tasks_to_mirror(all_tasks)
    local_ids = {t["taskId"] for t in to_mirror if t.get("taskId")}
    remote_ids = _query_existing_task_ids(token, project_id)
    if remote_ids is None:
        # Couldn't enumerate — only upsert, skip deletes to avoid
        # accidental loss on a transient error.
        for task in to_mirror:
            _write_task_doc(token, project_id, task)
        return
    for task in to_mirror:
        _write_task_doc(token, project_id, task)
    for orphan in remote_ids - local_ids:
        _delete_task_doc(token, project_id, orphan)


# ── Task artifact commands (v1.14.0+) ───────────────────────────
#
# Cuando la app cliente abre el detail sheet de una tarea, detecta paths
# bajo `~/.openclaw/workspace/` mencionados por el agente y los muestra
# como entregables descargables. Tap → push `commands/{id}` con
# `type: 'tasks.fetchArtifact'` y `params: {taskId, path}`. Acá validamos
# el path (anti-traversal, must be under workspace, < MAX bytes, exists)
# y reusamos prepareAssistantFile + confirmAssistantFile — mismo path que
# los uploads del chat, así que las storage rules y GC ya cubren el doc.
#
# Resultado en `commands/{id}.result`:
#   { summary, attachmentId, publicUrl, name, mime, size }
# El cliente hace GET al publicUrl (no firebasestorage.googleapis.com —
# bloqueado por DNS de carriers MX) y lo abre con open_filex / share.

_TASK_COMMAND_TYPES = frozenset({"tasks.fetchArtifact"})
TASK_COMMAND_POLL_INTERVAL_S = float(
    os.environ.get("TNODE_CHAT_SYNC_TASK_CMD_S", "3.0")
)
TASK_ARTIFACT_MAX_BYTES = int(
    os.environ.get("TNODE_CHAT_SYNC_ARTIFACT_MAX_BYTES", str(50 * 1024 * 1024))
)
WORKSPACE_DIR = (OPENCLAW_DIR / "workspace").resolve()


def _resolve_artifact_path(raw: str) -> Path | None:
    """Convert `~/...` or absolute path to a real Path under WORKSPACE_DIR.
    Returns None if the path escapes the workspace or doesn't resolve."""
    if not raw:
        return None
    expanded = raw
    if expanded.startswith("~/"):
        expanded = str(Path.home() / expanded[2:])
    try:
        p = Path(expanded).resolve()
    except OSError:
        return None
    workspace_str = str(WORKSPACE_DIR)
    if not (str(p) == workspace_str or str(p).startswith(workspace_str + os.sep)):
        return None
    return p


def _fetch_artifact_for_task(
    cfg: dict, task_id: str, raw_path: str,
) -> tuple[bool, str, dict]:
    """Validate workspace path + upload via assistant-file CF.
    Returns (ok, summary, result_data)."""
    if not task_id:
        return False, "missing taskId", {}
    p = _resolve_artifact_path(raw_path)
    if p is None:
        return False, "path not in workspace", {}
    if not p.is_file():
        return False, "file not found", {}
    try:
        size = p.stat().st_size
    except OSError as e:
        return False, f"stat failed: {e}", {}
    if size > TASK_ARTIFACT_MAX_BYTES:
        return (
            False,
            f"file too big ({size} bytes, max {TASK_ARTIFACT_MAX_BYTES})",
            {},
        )

    try:
        sha = _sha256_of(p)
    except OSError as e:
        return False, f"hash failed: {e}", {}
    mime = _guess_mime(p)

    prep = _prepare_assistant_file(cfg, p, sha, size, mime)
    if not prep:
        return False, "prepareAssistantFile failed", {}
    attachment_id = prep.get("attachmentId")
    upload_url = prep.get("uploadUrl")
    if not attachment_id or not upload_url:
        return False, "prepare returned no upload target", {}
    if not _put_file_to_signed_url(upload_url, p, mime):
        return False, "PUT to signed url failed", {}
    if not _confirm_assistant_file(cfg, attachment_id):
        return False, "confirmAssistantFile failed", {}

    # Resolved later from Firestore once the confirm CF has written the
    # `publicUrl` field on the assistantFiles doc. Saves us from hardcoding
    # GCS bucket paths here.
    return True, f"uploaded {p.name} ({size} bytes)", {
        "attachmentId": attachment_id,
        "name": p.name,
        "mime": mime,
        "size": size,
        "taskId": task_id,
        # publicUrl resolved at command-result time.
    }


def _get_assistant_file_public_url(
    token: dict, project_id: str, attachment_id: str,
) -> str | None:
    """Read `users/{uid}/nodes/{nodeId}/assistantFiles/{id}.publicUrl`.
    The confirmAssistantFile CF writes this field; we poll a few times
    in case the CF hasn't finished by the time we read."""
    base = _firestore_base(project_id)
    url = (
        f"{base}/users/{token['uid']}/nodes/{token['nodeId']}"
        f"/assistantFiles/{attachment_id}"
    )
    headers = {"Authorization": f"Bearer {token['idToken']}"}
    for _ in range(5):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=10) as resp:
                doc = json.loads(resp.read())
            fields = doc.get("fields") or {}
            val = (fields.get("publicUrl") or {}).get("stringValue")
            if val:
                return val
        except urllib.error.HTTPError as e:
            if e.code == 404:
                pass  # doc not yet written by CF — retry
            else:
                _log(f"assistantFiles get {attachment_id}: {e.code}")
                return None
        except Exception as e:  # noqa: BLE001
            _log(f"assistantFiles get {attachment_id} error: {e}")
            return None
        time.sleep(0.5)
    return None


def _execute_task_command(
    cmd_type: str, params: dict, cfg: dict,
) -> tuple[bool, str, dict]:
    """Returns (ok, summary, extra_result_fields)."""
    if cmd_type == "tasks.fetchArtifact":
        return _fetch_artifact_for_task(
            cfg,
            (params.get("taskId") or "").strip(),
            (params.get("path") or "").strip(),
        )
    return False, f"unknown task command type: {cmd_type}", {}


def _query_pending_task_commands(token: dict, project_id: str) -> list[dict]:
    """Same shape as `_query_pending_cron_commands` but for tasks.* types."""
    parent = (
        f"projects/{project_id}/databases/(default)/documents"
        f"/users/{token['uid']}/nodes/{token['nodeId']}"
    )
    url = f"https://firestore.googleapis.com/v1/{parent}:runQuery"
    body = {
        "structuredQuery": {
            "from": [{"collectionId": "commands"}],
            "where": {
                "compositeFilter": {
                    "op": "AND",
                    "filters": [
                        {"fieldFilter": {
                            "field": {"fieldPath": "status"},
                            "op": "EQUAL",
                            "value": {"stringValue": "pending"},
                        }},
                        {"fieldFilter": {
                            "field": {"fieldPath": "type"},
                            "op": "IN",
                            "value": {"arrayValue": {"values": [
                                {"stringValue": t}
                                for t in sorted(_TASK_COMMAND_TYPES)
                            ]}},
                        }},
                    ],
                }
            },
            "limit": 10,
        }
    }
    headers = {
        "Authorization": f"Bearer {token['idToken']}",
        "Content-Type": "application/json",
    }
    try:
        req = urllib.request.Request(
            url, data=json.dumps(body).encode(), headers=headers, method="POST"
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw = json.loads(resp.read())
    except Exception as e:  # noqa: BLE001
        _log(f"query task commands failed: {e}")
        return []
    out = []
    for row in raw:
        if "document" not in row:
            continue
        doc = row["document"]
        cmd_id = doc["name"].rsplit("/", 1)[-1]
        fields = doc.get("fields") or {}
        cmd_type = (fields.get("type") or {}).get("stringValue", "")
        params_field = fields.get("params") or {}
        params = _fs_unwrap_map(params_field)
        out.append({"id": cmd_id, "type": cmd_type, "params": params})
    return out


def _update_task_command(
    token: dict,
    project_id: str,
    cmd_id: str,
    status: str,
    summary: str,
    extra: dict,
) -> None:
    """Like `_update_cron_command` but writes the full result dict (with
    attachmentId, publicUrl, etc.), not only a summary string."""
    base = _firestore_base(project_id)
    url = (
        f"{base}/users/{token['uid']}/nodes/{token['nodeId']}/commands/{cmd_id}"
        f"?updateMask.fieldPaths=status&updateMask.fieldPaths=result"
        f"&updateMask.fieldPaths=updatedAt"
    )
    result_body: dict = {"summary": (summary or "")[:500]}
    for k, v in extra.items():
        if k == "summary":
            continue
        result_body[k] = v
    body = {
        "status": status,
        "result": result_body,
        "updatedAt": {"__server_timestamp__": True},
    }
    headers = {"Authorization": f"Bearer {token['idToken']}"}
    try:
        _http_patch_json(url, _fs_fields(body), headers)
    except urllib.error.HTTPError as e:
        _log(f"task cmd update {cmd_id}: {e.code} {e.reason}")


def process_task_commands(
    token: dict, project_id: str, cfg: dict,
) -> None:
    """Pop pending tasks.* commands and execute them."""
    pending = _query_pending_task_commands(token, project_id)
    if not pending:
        return
    for cmd in pending:
        cmd_id = cmd["id"]
        ok, summary, extra = _execute_task_command(
            cmd["type"], cmd["params"], cfg,
        )
        # Resolve publicUrl post-confirm — confirmAssistantFile writes it
        # to assistantFiles/{id}; we read it back so the client has
        # everything it needs from the command result alone (no extra
        # Firestore listener required).
        if ok and "attachmentId" in extra and "publicUrl" not in extra:
            public_url = _get_assistant_file_public_url(
                token, project_id, extra["attachmentId"],
            )
            if public_url:
                extra["publicUrl"] = public_url
            else:
                ok = False
                summary = "publicUrl not available after confirm"
        new_status = "done" if ok else "error"
        _update_task_command(
            token, project_id, cmd_id, new_status, summary, extra,
        )
        _log(f"task cmd {cmd_id} type={cmd['type']} → {new_status}: {summary[:80]}")


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
    # Channel-delivery mirrors: OpenClaw records `message send` outbounds (and
    # other channel deliveries) as an assistant message with
    # `model="delivery-mirror"` and NO runId/sessionKey — distinct from a real
    # agent turn (which carries the actual model + a runId, and on v2026.5.x
    # arrives via `model.completed`). The channel already delivered the message
    # to its real target; with no sessionKey, flush_turn can't route it and
    # defaults it to the OWNER's space — leaking guest-/channel-targeted sends
    # into the owner's chat. Incident 2026-06-18: `openclaw message send
    # --channel tnode --target <guest>` showed up in the owner's chat on nodes
    # where OpenClaw emits the send as a delivery-mirror instead of a
    # model.completed turn (the VPS happened to emit model.completed and routed
    # correctly; the Mini emitted delivery-mirror and leaked — same OpenClaw +
    # chat-sync versions). Never mirror these to the app thread.
    if msg.get("model") == "delivery-mirror":
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


def _derive_originating_channel(session_key) -> str | None:
    """Map a gateway sessionKey to an `originatingChannel` tag (v1.12.0+).

    The Flutter client uses `sessionKey = "tnode-mobile-<uuid>"` for the
    owner and `"tnode-guest-<guestUid>__<uuid>"` for a shared-agent guest
    (v1.18.0+). The gateway prefixes it as `"agent:<agentId>:<sessionKey>"`
    in trajectory events. We tag turns so sub-agents and historial conserven
    el origen del mensaje (owner vs invitado vs WhatsApp, webchat, CLI).
    """
    if not isinstance(session_key, str):
        return None
    if "tnode-guest-" in session_key:
        return "tnode-guest"
    if "tnode-mobile-" in session_key:
        return "tnode-mobile"
    return None


def _is_guest_session(session_key) -> bool:
    return isinstance(session_key, str) and "tnode-guest-" in session_key


def _guest_uid_from_session(session_key) -> str | None:
    """Extract the destination uid from a guest sessionKey of the form
    `tnode-guest-<hex(uid)>__<uuid>` (possibly prefixed by the gateway as
    `agent:<agentId>:`). Returns None for owner/non-guest sessions.

    The uid is HEX-ENCODED because the gateway lowercases sessionKeys, which
    would corrupt a raw Firebase uid (those are case-sensitive and mixed
    case). Hex is all lowercase digits, so it survives the case-fold and
    decodes back exactly. The `__` separator is unambiguous (neither hex nor
    the uuid suffix contains a double underscore)."""
    if not isinstance(session_key, str):
        return None
    m = re.search(r"tnode-guest-([0-9a-fA-F]+)__", session_key)
    if not m:
        return None
    try:
        uid = bytes.fromhex(m.group(1)).decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        return None
    return uid or None


def _route_session_key(session_key: str) -> str:
    """Route guest sessions to the dedicated `guest` agent (Opción B).

    The gateway honors an `agent:<id>:` prefix on the injected sessionKey
    (verified E2E 2026-06-22) and strips it for routing/storage. Guests
    (`tnode-guest-*`) get their OWN agent + neutral workspace so they never
    load the owner's main workspace (USER.md/MEMORY.md/memory). Owner sessions
    (`tnode-mobile-*`) and channel sessions are left untouched → default
    `main` agent. Idempotent: a key already carrying an `agent:` prefix is
    returned as-is (we only prefix raw `tnode-guest-*` keys)."""
    if isinstance(session_key, str) and session_key.startswith("tnode-guest-"):
        return "agent:guest:" + session_key
    return session_key


def _session_key_for_media_file(filename: str) -> str | None:
    """Best-effort: find which session generated a tool media file by scanning
    the most recently active agent trajectories for the filename, returning
    that entry's sessionKey. Lets the orphan media sweep route guest-generated
    media back to the guest's space instead of defaulting to the owner
    (HOTFIX 2026-06-13 — shared-agent guest media leaked to owner)."""
    try:
        traj = sorted(
            (OPENCLAW_DIR / "agents").glob("*/sessions/*.trajectory.jsonl"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )[:8]
    except OSError:
        return None
    for tf in traj:
        try:
            with open(tf, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if filename not in line:
                        continue
                    try:
                        sk = json.loads(line).get("sessionKey")
                    except Exception:  # noqa: BLE001
                        continue
                    if isinstance(sk, str) and sk:
                        return sk
        except OSError:
            continue
    return None


def _strip_media_directives(text: str) -> str:
    """Drop standalone `MEDIA:<path>` directive lines from mirrored text.

    OpenClaw's media protocol has the agent emit `MEDIA:<abs-path>` so a
    channel adapter sends the file and strips the line (WhatsApp/Telegram do
    this). On tnode-mobile the file is delivered out-of-band by the orphan
    media sweep / `[adjunto:]` bridge, so the raw directive must not survive
    into the chat text — it surfaced as a literal
    `MEDIA:/home/tnode/...png` bubble under the generated image
    (shared-agent E2E, 2026-06-13). Inline prose that merely mentions
    "MEDIA:" is preserved; only lines that START with the directive go."""
    if "MEDIA:" not in text:
        return text
    kept = [
        ln for ln in text.splitlines() if not ln.lstrip().startswith("MEDIA:")
    ]
    return "\n".join(kept).strip()


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
    content = _strip_media_directives(content)
    run_id = entry.get("runId") or data.get("runId")
    ts_raw = entry.get("ts") or entry.get("timestamp") or data.get("ts")
    session_key = entry.get("sessionKey")
    channel = _derive_originating_channel(session_key)
    if not content or _is_silent_ack("assistant", content):
        # App-originated sessions (owner outbox / shared-agent guest) have a
        # client holding an "escribiendo…" indicator keyed off this turn.
        # Dropping a NO_REPLY silently leaves it blinking forever (incident
        # 2026-06-10: guest "hola" → model replied NO_REPLY → no doc → stuck
        # bubble). Write an empty `noReply` closure doc so the client can
        # settle. Channel sessions (telegram/whatsapp/cron/CLI) keep the old
        # silent skip — nothing waits on a Firestore doc there.
        if channel in ("tnode-mobile", "tnode-guest") and run_id:
            return {
                "role": "assistant",
                "content": "",
                "noReply": True,
                "ts": ts_raw,
                "turnId": run_id,
                "idempotencyKey": run_id,
                "entryId": None,
                "originatingChannel": channel,
                "sessionKey": session_key,
                "targetUid": _guest_uid_from_session(session_key),
            }
        return None
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
        "originatingChannel": channel,
        # Raw key so flush_turn can scope the mirror to app sessions only.
        "sessionKey": session_key,
        # For a shared-agent guest, route the reply back to the guest's space.
        "targetUid": _guest_uid_from_session(session_key),
    }


def _copy_media_to_download(abs_path: str) -> str | None:
    """Copy a tool-generated media file (image_generate/video_generate output
    under ~/.openclaw/media/) into workspace/download/ so it (a) satisfies the
    assistant-file workspace policy and (b) shows up in the app's
    Almacenamiento -> Descarga tab. Returns the workspace-relative path for an
    `[adjunto: ...]` marker, or None if the source is missing or sits outside
    the media store (path-injection guard)."""
    raw = (abs_path or "").strip()
    if raw.startswith("MEDIA:"):
        raw = raw[len("MEDIA:"):].strip()
    if not raw:
        return None
    try:
        src = Path(os.path.expanduser(raw)).resolve(strict=False)
        media_root = MEDIA_DIR.resolve(strict=False)
        src.relative_to(media_root)
    except (ValueError, OSError):
        _log(f"media-bridge: rejected '{raw}' (outside media dir)")
        return None
    if not src.is_file():
        _log(f"media-bridge: source missing {src}")
        return None
    dest_dir = WORKSPACE_DIR / "download"
    dest = dest_dir / src.name
    try:
        dest_dir.mkdir(parents=True, exist_ok=True)
        if not dest.exists() or dest.stat().st_size != src.stat().st_size:
            shutil.copy2(src, dest)
    except OSError as e:
        _log(f"media-bridge: copy failed {src} -> {dest}: {e}")
        return None
    return f"workspace/download/{src.name}"


def media_turn_from_trajectory(entry: dict):
    """Bridge OpenClaw tool-generated media (image/video/audio) into the mobile
    chat. OpenClaw delivers such media via its `message` tool, recorded in the
    `trace.artifacts` trajectory event as `data.messagingToolSentMediaUrls`.
    chat-sync's normal `model.completed` path syncs only the text, so the media
    files never reach the phone.

    We copy each sent file into workspace/download/ and return an assistant
    turn whose content carries `[adjunto: ...]` markers — the existing
    assistant-file pipeline then uploads them. The turn reuses the runId, so
    the resulting `a_{runId}` doc OVERWRITES the text-only doc written by the
    sibling `model.completed`, yielding one combined text+media bubble. Returns
    None for events that didn't send media."""
    if entry.get("type") != "trace.artifacts":
        return None
    data = entry.get("data") or {}
    raw_urls = data.get("messagingToolSentMediaUrls") or []
    if not isinstance(raw_urls, list) or not raw_urls:
        return None
    # Dedupe preserving order (OpenClaw repeats one path per attachment slot).
    seen: dict[str, None] = {}
    for u in raw_urls:
        if isinstance(u, str) and u.strip():
            seen.setdefault(u.strip(), None)
    markers = [f"[adjunto: {rel}]"
               for rel in (_copy_media_to_download(u) for u in seen) if rel]
    if not markers:
        return None
    # Image-only bubble: the caption text already arrives via the sibling
    # `model.completed` turn (written as `a_{runId}`). We MUST use a distinct
    # doc id here — `write_message` is create-only (currentDocument.exists=
    # false), so reusing `a_{runId}` would 412-drop this write and the media
    # would never land. The `:media` suffix makes a separate follow-up bubble
    # carrying the attachment.
    content = "\n".join(markers)
    run_id = entry.get("runId") or data.get("runId")
    media_key = f"{run_id}:media" if run_id else None
    ts_raw = entry.get("ts") or entry.get("timestamp") or data.get("ts")
    return {
        "role": "assistant",
        "content": content,
        "ts": ts_raw,
        "turnId": run_id,
        "idempotencyKey": media_key,
        "entryId": None,
        "originatingChannel": _derive_originating_channel(entry.get("sessionKey")),
        "targetUid": _guest_uid_from_session(entry.get("sessionKey")),
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


# ── Declarative config refresh trigger ─────────────────────────
# A new session means OpenClaw is about to bootstrap from the workspace .md
# files (SOUL/IDENTITY/TOOLS/USER/TEAM), composed server-side and rendered by
# tnode-config-sync. Instead of config-sync POLLING Firestore for changes every
# few seconds (the old dominant source of Document reads), we refresh on demand:
# when the tailer first sees a brand-new live session, spawn config-sync's
# DECL_ONESHOT. Reads now scale with real usage — an idle node reads nothing.

DECL_TRIGGER_THROTTLE_S = float(
    os.environ.get("TNODE_CHAT_SYNC_DECL_THROTTLE_S", "5.0")
)
_last_decl_trigger = 0.0


def _trigger_declarative_refresh() -> None:
    """Spawn tnode-config-sync in DECL_ONESHOT mode to refresh the workspace
    .md files. Fire-and-forget, best-effort, throttled: a burst of sessions
    coalesces into one refresh (config changes are rare), and any failure is
    swallowed so chat mirroring is never affected."""
    global _last_decl_trigger
    now = time.time()
    if now - _last_decl_trigger < DECL_TRIGGER_THROTTLE_S:
        return
    _last_decl_trigger = now
    try:
        script = Path(__file__).resolve().parent / "tnode_config_sync.py"
        if not script.is_file():
            return
        subprocess.Popen(
            [sys.executable, str(script)],
            env={**os.environ, "TNODE_CONFIG_SYNC_DECL_ONESHOT": "1"},
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        _log("decl-refresh: spawned config-sync DECL_ONESHOT (new session)")
    except Exception as e:  # noqa: BLE001
        _log(f"decl-refresh trigger failed (non-fatal): {e}")


# ── File tailer ────────────────────────────────────────────────

class SessionTailer:
    def __init__(self, sessions_dirs):
        # Accept a single Path (back-compat) or a list of Paths. Opción B:
        # we watch ALL agent session dirs (main + guest + any others) so the
        # dedicated `guest` agent's replies get mirrored too. flush_turn
        # filters to tnode-mobile/tnode-guest sessions, so other agents'
        # turns (channels, catalog sub-agents) are ignored downstream.
        if isinstance(sessions_dirs, (str, Path)):
            sessions_dirs = [sessions_dirs]
        self.sessions_dirs: list[Path] = [Path(d) for d in sessions_dirs]
        # (dev, inode) -> offset  (inode-keyed, so multiple dirs never collide)
        self.offsets: dict[tuple, int] = {}
        # Watcher start time (monotonic file mtime). Files with mtime newer
        # than this are "born after the watcher started" — i.e. live sessions
        # we need to mirror from byte 0, not historical logs to skip.
        self.start_time = time.time()

    def _iter_files(self):
        # Re-resolve agent session dirs on EVERY pass and ADD any new ones, so
        # dirs created AFTER startup are picked up without a manual restart.
        # When systemd starts the daemon right after install the OpenClaw agent
        # dirs (~/.openclaw/agents/<id>/sessions) don't exist yet, and — crucial
        # for Opción B on a snapshot-provisioned node — `agents/guest/sessions`
        # is created only on the FIRST guest turn, long after the daemon started
        # and after `agents/main/sessions` already appeared. A resolution that
        # only re-ran while the watched set was empty never watched it, so the
        # guest's replies were never mirrored. Additive + inode-keyed offsets
        # mean a dir is never dropped or re-read once seen.
        added = [
            d for d in resolve_all_sessions_dirs()
            if d.is_dir() and d not in self.sessions_dirs
        ]
        if added:
            self.sessions_dirs = self.sessions_dirs + added
            _log(
                "sessions dirs appeared — now watching "
                + ", ".join(str(d) for d in self.sessions_dirs)
            )
        dirs = [d for d in self.sessions_dirs if d.is_dir()]
        if not dirs:
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
        all_files = sorted(f for d in dirs for f in d.glob("*.jsonl"))
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
                    # Brand-new live session → refresh the declarative .md so
                    # the NEXT bootstrap reads current config (replaces the
                    # config-sync poll). Throttled + non-blocking inside.
                    _trigger_declarative_refresh()
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


def resolve_all_sessions_dirs() -> list[Path]:
    """All agent session dirs to watch (main first, then the rest). Opción B:
    guests run on the dedicated `guest` agent, so we tail every
    `~/.openclaw/agents/*/sessions` dir. flush_turn only mirrors
    tnode-mobile/tnode-guest sessions downstream, so non-app agents (channels,
    catalog sub-agents) are ignored. The TNODE_CHAT_SYNC_SESSIONS override
    pins a single dir (tests)."""
    override = os.environ.get("TNODE_CHAT_SYNC_SESSIONS")
    if override:
        return [Path(override)]
    agents_dir = OPENCLAW_DIR / "agents"
    if not agents_dir.is_dir():
        return [OPENCLAW_DIR / "sessions"]  # fallback, won't exist
    dirs: list[Path] = []
    main_s = agents_dir / "main" / "sessions"
    if main_s.is_dir():
        dirs.append(main_s)
    for sub in sorted(agents_dir.iterdir()):
        s = sub / "sessions"
        if s.is_dir() and s != main_s:
            dirs.append(s)
    return dirs or [main_s]


# ── Chat outbox consumer (v1.17.0+) ────────────────────────────
# Firestore-first messaging: the mobile app writes every user message to
# `users/{uid}/nodes/{nodeId}/chats/u_{idempotencyKey}` with
# delivery="pending" and *also* tries the direct WS fast path (which on
# success flips delivery="ws"). When the direct WS is down (tunnel QUIC
# drop, gateway restart, iOS suspend) nobody delivers the message — this
# consumer picks the stale pending docs up, injects them into the local
# gateway over an ephemeral WebSocket, and flips delivery="node". The
# gateway dedupes chat.send by idempotencyKey, so a message that raced
# through both paths lands exactly once.

try:
    from websockets.sync.client import connect as _ws_connect  # type: ignore
    _WS_OUTBOX_AVAILABLE = True
except Exception:  # noqa: BLE001 — websockets missing or <13 (no sync API)
    _WS_OUTBOX_AVAILABLE = False

OUTBOX_POLL_HOT_S = float(os.environ.get("TNODE_CHAT_SYNC_OUTBOX_HOT_S", "2.5"))
OUTBOX_POLL_IDLE_S = float(os.environ.get("TNODE_CHAT_SYNC_OUTBOX_IDLE_S", "10.0"))
# Stay on the hot clock this long after seeing pendings; trajectory
# activity (user is around) also bumps the window by OUTBOX_TAIL_HOT_S.
OUTBOX_HOT_WINDOW_S = 300.0
OUTBOX_TAIL_HOT_S = 60.0
# Give the app's direct-WS fast path a head start before injecting —
# avoids pointless double-sends when the WS is healthy.
OUTBOX_MIN_AGE_S = 3.0
OUTBOX_MAX_ATTEMPTS = 5
GATEWAY_WS_URL = os.environ.get(
    "TNODE_CHAT_SYNC_GATEWAY_WS", "ws://127.0.0.1:18789"
)

# Firestore REST returns RFC3339 with up to nanosecond fractions;
# datetime.fromisoformat caps at microseconds — truncate before parsing.
_ISO_FRAC_RE = re.compile(r"\.(\d{6})\d+")


def _iso_to_epoch(s) -> float | None:
    if not isinstance(s, str) or not s:
        return None
    try:
        s2 = _ISO_FRAC_RE.sub(r".\1", s).replace("Z", "+00:00")
        return datetime.fromisoformat(s2).timestamp()
    except (ValueError, TypeError):
        return None


class _GatewayDown(Exception):
    """Local gateway unreachable / not answering — node-level problem,
    abort the whole batch without burning per-doc attempts."""


class _GatewayAuthFailed(Exception):
    """Gateway rejected our connect handshake — config-level problem."""


def query_pending_outbox(token: dict, project_id: str, limit: int = 10) -> list:
    """Pending user messages (delivery=="pending") under this node's
    chats/. Equality-only filters ride the automatic single-field
    indexes — adding orderBy would require shipping a composite index,
    so ordering by createdAt happens client-side instead."""
    parent = (
        f"projects/{project_id}/databases/(default)/documents"
        f"/users/{token['uid']}/nodes/{token['nodeId']}"
    )
    url = f"https://firestore.googleapis.com/v1/{parent}:runQuery"
    body = {
        "structuredQuery": {
            "from": [{"collectionId": "chats"}],
            "where": {
                "compositeFilter": {
                    "op": "AND",
                    "filters": [
                        {
                            "fieldFilter": {
                                "field": {"fieldPath": "delivery"},
                                "op": "EQUAL",
                                "value": {"stringValue": "pending"},
                            }
                        },
                        {
                            "fieldFilter": {
                                "field": {"fieldPath": "role"},
                                "op": "EQUAL",
                                "value": {"stringValue": "user"},
                            }
                        },
                    ],
                }
            },
            "limit": limit,
        }
    }
    headers = {"Authorization": f"Bearer {token['idToken']}"}
    raw = _http_post_json_authed(url, body, headers, timeout=20)
    out = []
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
        out.append({"id": doc_id, "uid": token["uid"], "fields": doc.get("fields", {})})
    return out


_CG_NAME_RE = re.compile(
    r"/documents/users/([^/]+)/nodes/([^/]+)/chats/([^/]+)$"
)


def query_pending_outbox_cg(token: dict, project_id: str, limit: int = 20) -> list:
    """Pending user messages across EVERY space for this node (owner + all
    shared-agent guests) via one collection-group query on `chats`
    (nodeId==, delivery==pending, role==user). The owning uid is parsed
    from each doc's resource name. Requires the collection-group composite
    index and the collection-group read rule (architecture §5.2).

    Guest docs carry an explicit `nodeId` field (the client writes it from
    v1.18+); legacy owner docs without it are still covered by the
    space-scoped `query_pending_outbox`."""
    parent = f"projects/{project_id}/databases/(default)/documents"
    url = f"https://firestore.googleapis.com/v1/{parent}:runQuery"
    body = {
        "structuredQuery": {
            "from": [{"collectionId": "chats", "allDescendants": True}],
            "where": {
                "compositeFilter": {
                    "op": "AND",
                    "filters": [
                        {"fieldFilter": {
                            "field": {"fieldPath": "nodeId"},
                            "op": "EQUAL",
                            "value": {"stringValue": token["nodeId"]},
                        }},
                        {"fieldFilter": {
                            "field": {"fieldPath": "delivery"},
                            "op": "EQUAL",
                            "value": {"stringValue": "pending"},
                        }},
                        {"fieldFilter": {
                            "field": {"fieldPath": "role"},
                            "op": "EQUAL",
                            "value": {"stringValue": "user"},
                        }},
                    ],
                }
            },
            "limit": limit,
        }
    }
    headers = {"Authorization": f"Bearer {token['idToken']}"}
    raw = _http_post_json_authed(url, body, headers, timeout=20)
    out = []
    if not isinstance(raw, list):
        return out
    for item in raw:
        doc = item.get("document") if isinstance(item, dict) else None
        if not doc:
            continue
        m = _CG_NAME_RE.search(doc.get("name", ""))
        if not m:
            continue
        uid, ndid, doc_id = m.group(1), m.group(2), m.group(3)
        if ndid != token["nodeId"]:
            continue
        out.append({"id": doc_id, "uid": uid, "fields": doc.get("fields", {})})
    return out


def load_node_members(token: dict, project_id: str, state: dict) -> set:
    """Set of guest uids allowed to chat with this node (members/ with
    revoked==false). Cached 60s in `state` to keep the outbox sweep cheap.
    On query failure, falls back to the last good cache (or empty)."""
    now = time.time()
    cached = state.get("_members_cache")
    if cached and (now - cached[0]) < 60.0:
        return cached[1]
    parent = (
        f"projects/{project_id}/databases/(default)/documents"
        f"/nodeSyncRegistrations/{token['nodeId']}"
    )
    url = f"https://firestore.googleapis.com/v1/{parent}:runQuery"
    body = {
        "structuredQuery": {
            "from": [{"collectionId": "members"}],
            "where": {"fieldFilter": {
                "field": {"fieldPath": "revoked"},
                "op": "EQUAL",
                "value": {"booleanValue": False},
            }},
            "limit": 500,
        }
    }
    headers = {"Authorization": f"Bearer {token['idToken']}"}
    uids: set = set()
    try:
        raw = _http_post_json_authed(url, body, headers, timeout=20)
        for item in raw or []:
            doc = item.get("document") if isinstance(item, dict) else None
            if not doc:
                continue
            muid = doc.get("name", "").rsplit("/", 1)[-1]
            if muid:
                uids.add(muid)
    except Exception as e:  # noqa: BLE001
        _log(f"outbox: members query failed ({e}) — using cached/owner-only")
        return cached[1] if cached else set()
    state["_members_cache"] = (now, uids)
    return uids


def update_chat_outbox_doc(
    token: dict, project_id: str, uid: str, message_id: str, fields: dict, mask: list
) -> bool:
    """PATCH delivery-tracking fields on a chats/ doc owned by `uid` (the
    node owner, or a shared-agent guest). The `currentDocument.exists=true`
    precondition keeps a PATCH racing a user delete from resurrecting the
    doc as a delivery-fields-only husk. Returns False (swallowed) when the
    doc is gone."""
    parent = (
        f"users/{uid}/nodes/{token['nodeId']}/chats/{message_id}"
    )
    mask_q = "&".join(f"updateMask.fieldPaths={k}" for k in mask)
    url = (
        f"https://firestore.googleapis.com/v1/projects/{project_id}"
        f"/databases/(default)/documents/{parent}"
        f"?{mask_q}&currentDocument.exists=true"
    )
    headers = {"Authorization": f"Bearer {token['idToken']}"}
    try:
        _http_patch_json(url, {"fields": fields}, headers)
        return True
    except urllib.error.HTTPError as e:
        # 400/404/409: doc deleted underneath us. 403: we can't write this
        # space (e.g. a non-member's hand-crafted doc with no node doc to
        # satisfy the rules' exists() guard) — swallow so one bad doc never
        # crashes the sweep.
        if e.code in (400, 403, 404, 409):
            return False
        raise


def _now_ts_value() -> dict:
    return {
        "timestampValue": time.strftime(
            "%Y-%m-%dT%H:%M:%SZ", time.gmtime()
        )
    }


def _gateway_send_pending(items: list) -> tuple[list, str | None]:
    """Inject pending user messages into the local gateway over one
    ephemeral WS connection (challenge → connect → chat.send per item).

    items: [{id, sessionKey, content, idempotencyKey}, ...] in send order.
    Returns (results, abort_reason) where results is a list of
    (doc_id, ok, err) for items that got a definitive answer; items not
    in results were never attempted (connection died mid-batch —
    abort_reason says why) and keep their pending state untouched.
    Raises _GatewayDown / _GatewayAuthFailed when nothing was attempted.
    """
    gw_token = _read_gateway_token()
    if not gw_token:
        raise _GatewayAuthFailed("no gateway.auth.token in openclaw.json")

    deadline = time.time() + 15.0 + 5.0 * len(items)

    def _recv_json(conn):
        remaining = deadline - time.time()
        if remaining <= 0:
            raise TimeoutError("deadline exceeded")
        raw = conn.recv(timeout=remaining)
        try:
            return json.loads(raw)
        except (TypeError, ValueError):
            return None

    try:
        conn = _ws_connect(GATEWAY_WS_URL, open_timeout=5, close_timeout=2)
    except Exception as e:  # noqa: BLE001
        raise _GatewayDown(str(e) or type(e).__name__)

    results: list = []
    try:
        # 1) Wait for the connect.challenge event. The nonce is only
        # needed for device-identity signatures, which backend clients
        # authenticating with the master gateway token don't send.
        while True:
            try:
                frame = _recv_json(conn)
            except TimeoutError:
                raise _GatewayDown("timeout waiting for connect.challenge")
            except Exception as e:  # noqa: BLE001
                raise _GatewayDown(f"recv during handshake: {e}")
            if (
                isinstance(frame, dict)
                and frame.get("type") == "event"
                and frame.get("event") == "connect.challenge"
            ):
                break

        # 2) connect req — token-only backend client (same trust as the
        # `openclaw cron` CLI calls this daemon already makes).
        connect_id = py_secrets.token_hex(8)
        conn.send(json.dumps({
            "type": "req",
            "id": connect_id,
            "method": "connect",
            "params": {
                "minProtocol": 4,
                "maxProtocol": 4,
                "client": {
                    "id": "gateway-client",
                    "displayName": "tnode-chat-sync",
                    "version": __VERSION__,
                    "platform": sys.platform,
                    "mode": "backend",
                },
                "auth": {"token": gw_token},
                "role": "operator",
                "scopes": ["operator.read", "operator.write"],
                "caps": [],
            },
        }))
        while True:
            try:
                frame = _recv_json(conn)
            except TimeoutError:
                raise _GatewayDown("timeout waiting for connect res")
            except Exception as e:  # noqa: BLE001
                raise _GatewayDown(f"recv during handshake: {e}")
            if (
                isinstance(frame, dict)
                and frame.get("type") == "res"
                and frame.get("id") == connect_id
            ):
                if not frame.get("ok"):
                    err = frame.get("error") or {}
                    raise _GatewayAuthFailed(
                        f"{err.get('code')}: {err.get('message')}"
                    )
                break

        # 3) chat.send per item, awaiting each res to preserve order.
        for it in items:
            send_id = py_secrets.token_hex(8)
            try:
                conn.send(json.dumps({
                    "type": "req",
                    "id": send_id,
                    "method": "chat.send",
                    "params": {
                        "sessionKey": _route_session_key(it["sessionKey"]),
                        "message": it["content"],
                        "idempotencyKey": it["idempotencyKey"],
                    },
                }))
            except Exception as e:  # noqa: BLE001
                return results, f"send: {e}"
            while True:
                try:
                    frame = _recv_json(conn)
                except TimeoutError:
                    return results, "timeout waiting for chat.send res"
                except Exception as e:  # noqa: BLE001
                    return results, f"recv: {e}"
                if (
                    isinstance(frame, dict)
                    and frame.get("type") == "res"
                    and frame.get("id") == send_id
                ):
                    if frame.get("ok"):
                        # Observabilidad #4: si el gateway echa el runId en el
                        # res, logueamos aquí el puente cid↔runId del inject
                        # (best-effort; el empate autoritativo lo hace el
                        # cliente). cid del outbox = idempotencyKey.
                        _res = frame.get("result")
                        _rid = _res.get("runId") if isinstance(_res, dict) else None
                        if _rid:
                            _log(f"inject-join cid={it['idempotencyKey']} runId={_rid}")
                        results.append((it["id"], True, ""))
                    else:
                        err = frame.get("error") or {}
                        results.append((
                            it["id"],
                            False,
                            f"{err.get('code')}: {err.get('message')}",
                        ))
                    break
        return results, None
    finally:
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass


def process_outbox(token: dict, project_id: str, state: dict) -> bool:
    """One outbox sweep: query pendings, inject eligible ones, flip
    delivery. Returns True when pendings were seen (feeds hot mode)."""
    # Stage-3 cutover: when the native TNode channel is live it consumes the
    # inbound outbox itself (its gateway poll reads the same pending u_* docs
    # and dispatches them). Stand aside to avoid double dispatch. See
    # _tnode_channel_active().
    if _tnode_channel_active():
        return False
    if not _WS_OUTBOX_AVAILABLE:
        if not state.get("warned_no_ws"):
            state["warned_no_ws"] = True
            _log("outbox: websockets>=13 not importable — consumer disabled")
        return False

    # Dual query: legacy space-scoped (owner — covers old docs without a
    # nodeId field) + collection-group (owner's new docs + every guest).
    # Dedup by (uid, doc_id) so an owner doc that satisfies both is sent once.
    docs_by_key: dict[tuple, dict] = {}
    try:
        for d in query_pending_outbox(token, project_id):
            docs_by_key[(d["uid"], d["id"])] = d
    except Exception as e:  # noqa: BLE001
        _log(f"outbox: owner query failed ({e})")
    try:
        for d in query_pending_outbox_cg(token, project_id):
            docs_by_key[(d["uid"], d["id"])] = d
    except Exception as e:  # noqa: BLE001
        _log(f"outbox: collection-group query failed ({e})")
    docs = list(docs_by_key.values())
    if not docs:
        return False

    owner_uid = token["uid"]
    members: set | None = None  # lazily loaded only if a guest doc appears

    now = time.time()
    items = []
    for d in docs:
        uid = d.get("uid") or owner_uid
        f = d.get("fields", {})
        # Authorize non-owner (guest) messages against members/ — the rule
        # alone can't stop a user inventing nodeIds in their own space, so
        # the real consume-gate lives here (architecture §8.2).
        if uid != owner_uid:
            if members is None:
                members = load_node_members(token, project_id, state)
            if uid not in members:
                _log(f"outbox: {d['id']} from non-member {uid[:8]} — failed")
                update_chat_outbox_doc(
                    token, project_id, uid, d["id"],
                    fields={
                        "delivery": {"stringValue": "failed"},
                        "deliveryError": {"stringValue": "not_a_member"},
                        "updatedAt": _now_ts_value(),
                    },
                    mask=["delivery", "deliveryError", "updatedAt"],
                )
                continue
        created = _iso_to_epoch(_fs_field_to_python(f.get("createdAt")))
        attempts = _fs_field_to_python(f.get("deliveryAttempts")) or 0
        last_attempt = _iso_to_epoch(
            _fs_field_to_python(f.get("lastDeliveryAttemptAt"))
        )
        # Client clock ahead of ours — treat as brand new, wait it out.
        if created is not None and created > now:
            continue
        if created is not None and (now - created) < OUTBOX_MIN_AGE_S:
            continue
        if attempts > 0 and last_attempt is not None:
            wait = min(600.0, 30.0 * (2 ** max(0, attempts - 1)))
            if (now - last_attempt) < wait:
                continue
        items.append({
            "id": d["id"],
            "uid": uid,
            "content": _fs_field_to_python(f.get("content")) or "",
            "sessionKey": _fs_field_to_python(f.get("sessionKey")) or "",
            "idempotencyKey": (
                _fs_field_to_python(f.get("idempotencyKey"))
                or (d["id"][2:] if d["id"].startswith("u_") else d["id"])
            ),
            "created": created or 0.0,
            "attempts": int(attempts),
        })

    if not items:
        return True  # pendings exist but are cooling down — stay hot

    items.sort(key=lambda x: x["created"])

    # Docs a client can't deliver land in failed immediately.
    sendable = []
    for it in items:
        if not it["sessionKey"]:
            _log(f"outbox: {it['id']} missing sessionKey — marking failed")
            update_chat_outbox_doc(
                token, project_id, it["uid"], it["id"],
                fields={
                    "delivery": {"stringValue": "failed"},
                    "deliveryError": {"stringValue": "missing sessionKey"},
                    "updatedAt": _now_ts_value(),
                },
                mask=["delivery", "deliveryError", "updatedAt"],
            )
        else:
            sendable.append(it)
    if not sendable:
        return True

    try:
        results, abort_reason = _gateway_send_pending(sendable)
    except _GatewayDown as e:
        if (now - state.get("last_gwdown_warn", 0.0)) > 60:
            state["last_gwdown_warn"] = now
            _log(f"outbox: gateway unreachable ({e}) — batch deferred")
        return True
    except _GatewayAuthFailed as e:
        if (now - state.get("last_auth_warn", 0.0)) > 60:
            state["last_auth_warn"] = now
            _log(f"outbox: gateway handshake rejected ({e})")
        return True

    by_id = {it["id"]: it for it in sendable}
    delivered = 0
    for doc_id, ok, err in results:
        it = by_id.get(doc_id) or {"attempts": 0, "uid": owner_uid}
        uid = it.get("uid", owner_uid)
        if ok:
            delivered += 1
            # Observabilidad #4: traza por-cid del inject (el path de fallback
            # outbox es el más difícil de depurar — guest pipeline). cid = idem.
            _log(f"inject ok cid={it.get('idempotencyKey', '?')} doc={doc_id}")
            update_chat_outbox_doc(
                token, project_id, uid, doc_id,
                fields={
                    "delivery": {"stringValue": "node"},
                    "updatedAt": _now_ts_value(),
                },
                mask=["delivery", "updatedAt"],
            )
        else:
            n = int(it.get("attempts", 0)) + 1
            if n >= OUTBOX_MAX_ATTEMPTS:
                _log(f"outbox: {doc_id} failed permanently: {err}")
                update_chat_outbox_doc(
                    token, project_id, uid, doc_id,
                    fields={
                        "delivery": {"stringValue": "failed"},
                        "deliveryError": {"stringValue": (err or "")[:500]},
                        "deliveryAttempts": {"integerValue": str(n)},
                        "lastDeliveryAttemptAt": _now_ts_value(),
                        "updatedAt": _now_ts_value(),
                    },
                    mask=[
                        "delivery", "deliveryError", "deliveryAttempts",
                        "lastDeliveryAttemptAt", "updatedAt",
                    ],
                )
            else:
                _log(f"outbox: {doc_id} attempt {n} failed: {err}")
                update_chat_outbox_doc(
                    token, project_id, uid, doc_id,
                    fields={
                        "deliveryAttempts": {"integerValue": str(n)},
                        "lastDeliveryAttemptAt": _now_ts_value(),
                        "updatedAt": _now_ts_value(),
                    },
                    mask=[
                        "deliveryAttempts", "lastDeliveryAttemptAt",
                        "updatedAt",
                    ],
                )
    if delivered:
        _log(f"outbox: injected {delivered}/{len(sendable)} pending message(s)")
    if abort_reason:
        _log(f"outbox: batch aborted mid-way ({abort_reason}) — rest deferred")
    return True


# ── Main loop ──────────────────────────────────────────────────

def main() -> int:
    try:
        cfg = load_config()
    except Exception as e:  # noqa: BLE001
        _log(f"config error: {e}")
        return 2

    # Project id is derived from the mintUrl hostname.
    project_id = "tbrain-platform-7fc1f"

    sessions_dirs = resolve_all_sessions_dirs()
    _log("watching " + ", ".join(str(d) for d in sessions_dirs))

    tailer = SessionTailer(sessions_dirs)
    token: dict | None = None
    backoff = 1.0

    # Assistant turns are buffered here keyed by the JSONL entry id until
    # their sibling `openclaw:bootstrap-context:full` event arrives with
    # the real runId — which is the same id the Flutter client observed
    # over the WebSocket, so writing `a_{runId}` deduplicates live streams
    # against the mirror on the client side.
    pending: dict[str, dict] = {}  # entryId -> turn + {bufferedAt: float}
    PENDING_TIMEOUT_S = 15.0

    def flush_turn(t: dict, *, is_media: bool = False):
        if token is None:
            return
        # Stage-3 cutover: when the native TNode channel is live it delivers
        # the agent's TEXT replies itself. Skip the text mirror to avoid double
        # bubbles, but KEEP media (is_media=True from media-turns + orphan
        # sweep) — the plugin can't deliver tool-generated media. See
        # _tnode_channel_active().
        if not is_media and _tnode_channel_active():
            return
        mid = message_id_for(t)
        # Rewrite `[adjunto: <path>]` markers from the agent's text into
        # `[archivo:{id}]` after uploading the files to Storage. Skip
        # entirely when no marker present (fast path — the `in` check
        # avoids regex compilation when the agent didn't attach anything).
        content = t["content"]
        if "[adjunto:" in content:
            content = process_assistant_file_markers(
                cfg, content, t.get("targetUid")
            )
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
            # correlationId uniforme (#4): en el doc assistant = runId. En Path A
            # (gateway chat.send) el gateway REUSA el idempotencyKey del cliente
            # como runId (verificado E2E 2026-06-22) → correlationId = cid y casa
            # con el doc u_. En Path B (transport) el runId es random y el PLUGIN
            # estampa el cid directo en su propio write.
            body["correlationId"] = t["turnId"]
        if t.get("originatingChannel"):
            body["originatingChannel"] = t["originatingChannel"]
        if t.get("noReply"):
            body["noReply"] = True
        # Mirror scope (v1.19.1): the app thread carries the app's own
        # conversations. Turns from channel sessions (telegram/whatsapp/
        # webchat/CLI/cron) used to land in the owner's mobile thread too —
        # reported as "broadcast" confusion on 2026-06-10 when a Telegram
        # reply showed up in the app. Turns without a sessionKey (legacy
        # OpenClaw ≤2026.4.x message path) keep flowing for compat.
        sk = t.get("sessionKey")
        if isinstance(sk, str) and (
            "tnode-mobile-" not in sk and "tnode-guest-" not in sk
        ):
            _log(f"skip {mid}: channel session, not mirrored to app thread")
            return
        # Shared-agent guests get their reply in their OWN space; everyone
        # else (owner / non-guest sessions) lands in the owner's space.
        # Privacy guard: if this is a guest session but we couldn't decode
        # the target uid, DROP the write — never fall back to the owner's
        # space (that would leak a guest's conversation to the owner).
        if t.get("originatingChannel") == "tnode-guest" and not t.get("targetUid"):
            _log(f"skip {mid}: guest session, undecodable target uid")
            return
        dest_uid = t.get("targetUid") or token["uid"]
        try:
            write_message(
                token,
                project_id,
                dest_uid,
                token["nodeId"],
                mid,
                body,
            )
            _log(
                f"wrote {mid} (runId={t.get('turnId') or 'hash'})"
                + (f" → guest {dest_uid[:8]}" if t.get("targetUid") else "")
            )
        except urllib.error.HTTPError as e:
            if e.code == 401:
                _log("idToken expired mid-write — refreshing")
                raise
            _log(f"write error: {e.code} {e.reason}")
        except Exception as e:  # noqa: BLE001
            _log(f"write error: {e}")

    # ── Orphan media sweep (v1.16.0) ──────────────────────────────────────
    # OpenClaw delivers tool-generated media (image/video/music_generate) by
    # waking the requester session and calling the `message` tool. On the
    # tnode-mobile channel that send FAILS ("Action send requires a target" —
    # the mobile chat is Firestore-mirrored, it has no messaging target), so
    # `messagingToolSentMediaUrls` stays empty and `media_turn_from_trajectory`
    # never fires; the generated file is orphaned under
    # ~/.openclaw/media/tool-*-generation/ and never reaches the chat. This
    # sweep bridges those orphans straight from disk, independent of the flaky
    # wake/send. Guards: a file already mirrored by the normal path lands in
    # workspace/download/ (skip it); GRACE lets the normal path win the race;
    # MAX_AGE stops a fresh deploy from back-filling old files (no chat flood);
    # the doc id is derived from name+size so re-sweeps/restarts are create-only
    # no-ops.
    MEDIA_SWEEP_SUBDIRS = (
        "tool-image-generation",
        "tool-video-generation",
        "tool-music-generation",
    )
    MEDIA_SWEEP_GRACE_S = 90
    MEDIA_SWEEP_MAX_AGE_S = 300
    MEDIA_SWEEP_INTERVAL_S = 30

    def sweep_orphan_media():
        now_s = time.time()
        for sub in MEDIA_SWEEP_SUBDIRS:
            d = MEDIA_DIR / sub
            if not d.is_dir():
                continue
            for src in sorted(d.iterdir()):
                try:
                    if not src.is_file():
                        continue
                    st = src.stat()
                    age = now_s - st.st_mtime
                    if age < MEDIA_SWEEP_GRACE_S or age > MEDIA_SWEEP_MAX_AGE_S:
                        continue
                    dest = WORKSPACE_DIR / "download" / src.name
                    if dest.exists() and dest.stat().st_size == st.st_size:
                        continue  # normal bridge (or a prior sweep) already handled it
                except OSError:
                    continue
                rel = _copy_media_to_download(str(src))
                if not rel:
                    continue
                key = hashlib.sha256(
                    f"{src.name}:{st.st_size}".encode()
                ).hexdigest()[:16]
                ts_iso = time.strftime(
                    "%Y-%m-%dT%H:%M:%SZ", time.gmtime(st.st_mtime)
                )
                # HOTFIX 2026-06-13: route guest-generated media to the guest,
                # not the owner. The wake/`message`-tool delivery fails on
                # app/guest sessions, so this orphan sweep is the only path —
                # but it used to hardcode `tnode-mobile` (owner) with no
                # targetUid, leaking guest media into the owner's chat. Now we
                # correlate the file with its originating session via the
                # trajectory and set the real channel/targetUid. Unknown →
                # owner (legacy fallback); guest-but-undecodable → the flush
                # privacy guard drops it (never leaks to owner).
                sk = _session_key_for_media_file(src.name)
                channel = _derive_originating_channel(sk) or "tnode-mobile"
                target_uid = _guest_uid_from_session(sk)
                _log(
                    f"media-sweep: bridging orphan {src.name} (age={int(age)}s) "
                    f"channel={channel} guest={'y' if target_uid else 'n'}"
                )
                flush_turn({
                    "role": "assistant",
                    "content": f"[adjunto: {rel}]",
                    "ts": ts_iso,
                    "turnId": None,
                    "idempotencyKey": f"genmedia_{key}:media",
                    "originatingChannel": channel,
                    "sessionKey": sk,
                    "targetUid": target_uid,
                }, is_media=True)

    # When `mintNodeToken` keeps returning 404 (server-side registration doc
    # gone), we re-register at most this often to avoid hammering the
    # endpoint if rotation itself is failing.
    REREGISTER_COOLDOWN_S = 300
    last_reregister_attempt = 0.0
    # Proactive token renewal (v1.19.0): start renewing this far before
    # expiry. A renewal failure must NOT freeze the loop while the current
    # token is still valid — incident 2026-06-10: mint 409 `not_paired`
    # (registration re-created unclaimed) put the whole loop in a 60s
    # error/backoff cycle for 2h42m, freezing outbox + watcher.
    TOKEN_RENEW_AHEAD_S = 300
    MINT_RETRY_COOLDOWN_S = 30
    last_mint_attempt = 0.0

    # Cadence for chat-attachment polling. Runs alongside the JSONL tail
    # loop but at a slower clock so we don't pound Firestore — 2s feels
    # snappy in the UI (the user sees the chip flip from "procesando" to
    # "listo" within ~3s of the PUT landing).
    last_uploads_check = 0.0
    # Cadence para crons mirror y CRUD commands (v1.11.0+). Mirror cada
    # ~10s, comandos pendientes cada ~3s para responsividad de la UI.
    last_cron_mirror_check = 0.0
    last_cron_command_check = 0.0
    last_tasks_mirror_check = 0.0
    last_task_command_check = 0.0
    last_media_sweep_check = 0.0
    # Outbox consumer (v1.17.0): adaptive clock — hot after trajectory
    # activity or recent pendings, idle otherwise.
    last_outbox_check = 0.0
    outbox_hot_until = 0.0
    outbox_state: dict = {}

    while True:
        try:
            now = int(time.time())
            if token is None or now >= token["expiresAt"]:
                # No usable token — nothing can be written until mint works.
                last_mint_attempt = now
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
                    _log(f"mintNodeToken failed: {e.code} {_http_error_body(e)}")
                    raise
                _log(f"minted token for uid={token['uid']} node={token['nodeId']}")
                backoff = 1.0
            elif (
                (token["expiresAt"] - now) <= TOKEN_RENEW_AHEAD_S
                and (now - last_mint_attempt) >= MINT_RETRY_COOLDOWN_S
            ):
                # Proactive renewal — the current token is still valid, so a
                # failure here only logs and retries on cooldown; the loop
                # (tailer, outbox, flips) keeps running on the old token.
                last_mint_attempt = now
                try:
                    token = mint_token(cfg)
                    _log(
                        f"token renewed for uid={token['uid']} "
                        f"node={token['nodeId']}"
                    )
                except urllib.error.HTTPError as e:
                    if e.code == 404 and (now - last_reregister_attempt) >= REREGISTER_COOLDOWN_S:
                        last_reregister_attempt = now
                        try:
                            new_secret = reregister_with_server(cfg)
                            persist_node_secret(cfg, new_secret)
                            cfg["nodeSecret"] = new_secret
                            _log(
                                "re-registered ok (proactive renewal) — "
                                "new nodeSecret persisted"
                            )
                        except Exception as re:  # noqa: BLE001
                            _log(f"re-register failed: {re}")
                    _log(
                        f"token renewal failed ({e.code} {_http_error_body(e)}) "
                        "— keeping current token, will retry"
                    )
                except Exception as re:  # noqa: BLE001
                    _log(f"token renewal failed: {re} — keeping current token")

            # Refresh the per-node Path B cutover flag into the cache that
            # _tnode_channel_active() reads (TTL-gated; same Firestore field the
            # client reads). The token block above guarantees a usable token.
            if token is not None:
                _refresh_tnode_transport_active(token, project_id, cfg["nodeId"])

            for line in tailer.read_new_lines():
                # Any trajectory activity means the user is around — keep
                # the outbox poll on the hot clock so a WS-down message
                # lands within a few seconds instead of the idle interval.
                outbox_hot_until = max(
                    outbox_hot_until, time.time() + OUTBOX_TAIL_HOT_S
                )
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

                # Case 0b: media-generation delivery (image/video/audio).
                # OpenClaw sends tool-generated media via the `message` tool;
                # the paths land in `trace.artifacts.messagingToolSentMediaUrls`,
                # not in `model.completed`. Bridge them as chat attachments —
                # same runId, so this overwrites the text-only doc with one
                # combined text+media bubble.
                media_turn = media_turn_from_trajectory(entry)
                if media_turn is not None:
                    try:
                        flush_turn(media_turn, is_media=True)
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

            # Cron CRUD commands poll — fast clock so the app sees the
            # operation reflected within a few seconds.
            if (
                token is not None
                and (now_f - last_cron_command_check) >= CRON_COMMAND_POLL_INTERVAL_S
            ):
                last_cron_command_check = now_f
                try:
                    process_cron_commands(token, project_id)
                except urllib.error.HTTPError as e:
                    if e.code == 401:
                        _log("cron commands poll: idToken rejected — refreshing")
                        token = None

            # Cron mirror — periodic snapshot of `openclaw cron list --json`
            # to Firestore. Skipped when a command just ran (process_cron_commands
            # already refreshes the mirror as its last step).
            if (
                token is not None
                and (now_f - last_cron_mirror_check) >= CRON_MIRROR_INTERVAL_S
            ):
                last_cron_mirror_check = now_f
                try:
                    process_crons_mirror(token, project_id)
                except urllib.error.HTTPError as e:
                    if e.code == 401:
                        _log("cron mirror: idToken rejected — refreshing")
                        token = None

            # Tasks mirror — periodic SQLite → Firestore snapshot of
            # TaskFlow runs.
            if (
                token is not None
                and (now_f - last_tasks_mirror_check) >= TASKS_MIRROR_INTERVAL_S
            ):
                last_tasks_mirror_check = now_f
                try:
                    process_tasks_mirror(token, project_id)
                except urllib.error.HTTPError as e:
                    if e.code == 401:
                        _log("tasks mirror: idToken rejected — refreshing")
                        token = None

            # Task artifact commands — fast clock so the app sees the
            # download ready within a few seconds after tapping.
            if (
                token is not None
                and (now_f - last_task_command_check) >= TASK_COMMAND_POLL_INTERVAL_S
            ):
                last_task_command_check = now_f
                try:
                    process_task_commands(token, project_id, cfg)
                except urllib.error.HTTPError as e:
                    if e.code == 401:
                        _log("task commands: idToken rejected — refreshing")
                        token = None

            # Orphan media sweep — bridge tool-generated images/video/music that
            # OpenClaw's `message` send failed to deliver (see sweep_orphan_media).
            if (
                token is not None
                and (now_f - last_media_sweep_check) >= MEDIA_SWEEP_INTERVAL_S
            ):
                last_media_sweep_check = now_f
                try:
                    sweep_orphan_media()
                except urllib.error.HTTPError as e:
                    if e.code == 401:
                        _log("media sweep: idToken rejected — refreshing")
                        token = None

            # Chat outbox consumer (v1.17.0) — Firestore-first messaging.
            # Picks up user messages the app wrote with delivery="pending"
            # (direct WS down) and injects them into the local gateway.
            outbox_interval = (
                OUTBOX_POLL_HOT_S
                if now_f < outbox_hot_until
                else OUTBOX_POLL_IDLE_S
            )
            if (
                token is not None
                and (now_f - last_outbox_check) >= outbox_interval
            ):
                last_outbox_check = now_f
                try:
                    if process_outbox(token, project_id, outbox_state):
                        outbox_hot_until = time.time() + OUTBOX_HOT_WINDOW_S
                except urllib.error.HTTPError as e:
                    if e.code == 401:
                        _log("outbox poll: idToken rejected — refreshing")
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
        Darwin) install_telemetry_launchd ;;
        Linux)  install_telemetry_systemd ;;
    esac
}

install_telemetry_launchd() {
    # macOS path (Mini etc). The websockets module isn't shipped with
    # Apple's Python — ensure_websockets_modern handles install + version
    # validation (>=13 required, see comment on the function).
    ensure_websockets_modern
    # psutil powers the `health` stream (CPU/RAM/disk). Apple's Python
    # ships without it; install via pip. Soft-fail: sidecar still works
    # for `usage` stream even if psutil is unavailable.
    ensure_psutil_installed || true

    local plist_label="com.tbrain.tnode-telemetry"
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
        <string>${OPENCLAW_HOME}/scripts/tnode_telemetry.py</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>${OPENCLAW_HOME}/logs/tnode-telemetry.out.log</string>
    <key>StandardErrorPath</key><string>${OPENCLAW_HOME}/logs/tnode-telemetry.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key><string>${HOME}</string>
        <key>OPENCLAW_HOME</key><string>${OPENCLAW_HOME}</string>
        <key>TNODE_TELEMETRY_HOST</key><string>127.0.0.1</string>
        <key>TNODE_TELEMETRY_PORT</key><string>18790</string>
        <key>TNODE_TELEMETRY_UPSTREAM</key><string>ws://127.0.0.1:18789</string>
    </dict>
    <key>WorkingDirectory</key><string>${OPENCLAW_HOME}</string>
</dict>
</plist>
PLIST

    launchctl unload "$plist_dest" 2>/dev/null || true
    launchctl load "$plist_dest"
    success "LaunchAgent tnode-telemetry cargado"
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
# 1.14.0 — agent.{music,video}Model.get/set RPCs — node-global music/video
#          generation model selectors (siblings of imageModel). Generalized
#          _node_image_model_get/set into _node_media_model_get/set(config_key)
#          so one pair drives all three slots (image/music/videoGenerationModel).
#          Both modalities are OpenRouter-served (Lyria 3 / grok-imagine-video).
# 1.13.1 — _node_image_model_set reloads the gateway async so the RPC returns
#          fast (daemon restart blocked past the client timeout → false
#          "tiempo de espera agotado" even though the slug was persisted).
# 1.13.0 — agent.imageModel.get/set RPCs — node-global image-generation
#          model selector. Writes agents.defaults.imageGenerationModel
#          (per-node, not per-agent: OpenClaw 2026.5.x rejects the slot
#          under agents.list[]). The gateway auto-enables the image plugin
#          from this key on reload, so no providers[].models[] upsert.
#          Backs the "Modelo de imagen" picker in the client.
# 1.12.0 — storage.download RPC implemented. Reads file from
#          workspace/download/, negotiates a signed PUT URL via
#          prepareAssistantFile (same HMAC path as the chat-sync
#          assistant_file pipeline), uploads, flips the assistantFiles
#          doc to `uploaded`, and returns {attachmentId, publicUrl} so
#          the mobile client can fetch + open with the OS handler.
# 1.8.15 — _agent_model_set now upserts the slug under
#          providers[p].models[] (in addition to the existing
#          defaults.models merge from 1.8.14). Without the catalog
#          insert, switching a per-agent model in Cerebro left the
#          gateway's allowlist updated but the provider catalog stale,
#          which the resolver fell back through silently to the
#          previous default. Idempotent; no-op on un-prefixed slugs.
# 1.8.14 — _agent_model_set merges into defaults.models instead of
#          overwriting it (preserves multi-agent distinct picks).
# 1.16.0 — agent.context.get RPC: friendly compiled-context breakdown
#          (tools-by-source + system-prompt/tool/chat token split) for the
#          CTX detail screen. Reads the newest trajectory's context.compiled
#          and correlates live usage from sessions.json.
# 1.17.0 — CTX dot honesto: un MCP configurado pero ausente del compiled ya no
#          es siempre "error" (rojo). Si telemetry lo vio por primera vez DESPUÉS
#          del último turno (recién activado, el gateway lo hot-recargó pero aún
#          no entra a un contexto compilado) queda "connected" + pendingTurn:true
#          ("listo en tu próximo mensaje"); solo si estaba desde antes del último
#          turno y sus tools no aparecieron es "error" real (token malo). Arregla
#          el rojo falso al activar un MCP y abrir CTX sin mandar mensaje. El
#          gateway NO necesita reinicio (hot-reload); ver config-sync 1.21.1.
__VERSION__ = "1.17.0"

import argparse
import asyncio
import hashlib
import hmac
import json
import logging
import mimetypes
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
CHANNELS_STREAM = "channels"

# Path that `tnode-config-sync` writes when `channels.email.link/unlink` is
# handled. Telemetry tails its mtime to emit the `channels` stream so the
# mobile app reflects state changes within ~1s without a round-trip.
_CHANNELS_STATE_PATH = OPENCLAW_HOME / "channels-state.json"
USAGE_VERSION = 1

HEALTH_STREAM = "health"
HEALTH_VERSION = 3
HEALTH_TICK_SEC = float(os.environ.get("TNODE_TELEMETRY_HEALTH_TICK_SEC", "15"))

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


def _newest_trajectory() -> Optional[Path]:
    """The most-recently-modified `<sessionId>.trajectory.jsonl` under the main
    agent's sessions dir — i.e. the conversation the user is in right now."""
    try:
        files = list(SESSIONS_DIR.glob("*.trajectory.jsonl"))
        if not files:
            return None
        return max(files, key=lambda p: p.stat().st_mtime)
    except Exception:  # noqa: BLE001
        return None


def _last_context_compiled(path: Path) -> Optional[Dict[str, Any]]:
    """Last `context.compiled` trace event in a trajectory (one is emitted per
    turn, right before the model call). None if the file has none yet."""
    found = None
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                if '"context.compiled"' not in line:
                    continue
                try:
                    obj = json.loads(line)
                except (ValueError, TypeError):
                    continue
                if isinstance(obj, dict) and obj.get("type") == "context.compiled":
                    found = obj
    except Exception as e:  # noqa: BLE001
        logger.warning("ctx: failed to read trajectory %s: %s", path, e)
    return found


# First time telemetry saw each configured MCP id (epoch seconds). Lets the
# CTX dot tell "freshly enabled, hot-loaded, lands next turn" (stays connected)
# apart from "was available last turn but never compiled" (real error).
_mcp_first_seen: Dict[str, float] = {}


def _collect_compiled_context() -> Dict[str, Any]:
    """Friendly breakdown of the agent's *compiled* context for the current
    session — what `agent.context.get` returns to the CTX screen.

    Reads the newest trajectory's last `context.compiled` event (the exact tool
    set + system-prompt size the runner fed the model) and correlates it with
    the live token usage from sessions.json (`_collect_active_ctx`). Tools are
    grouped by source: native tools vs `<server>__` MCP-prefixed ones. Each MCP
    source is flagged connected/error by whether its tools actually made it into
    the compiled context vs being merely configured in openclaw.json (the red-dot
    diagnostic). Heavy `parameters` JSON-schemas are stripped — the screen only
    needs name+description. `fresh: false` => no compiled context yet (fresh node
    / new session before its first turn)."""
    traj = _newest_trajectory()
    evt = _last_context_compiled(traj) if traj else None
    if evt is None:
        return {"fresh": False, "reason": "no-context-compiled"}

    data = evt.get("data") or {}
    tools = data.get("tools") if isinstance(data.get("tools"), list) else []
    messages = data.get("messages") if isinstance(data.get("messages"), list) else []
    prompt = data.get("prompt") if isinstance(data.get("prompt"), str) else ""

    # System-prompt size: originalChars is the true length (the text itself is
    # truncated in the trace by a field-size limit, but the count is exact).
    sp = data.get("systemPrompt")
    sp_chars = 0
    if isinstance(sp, dict):
        sp_chars = int(sp.get("originalChars") or sp.get("limitChars") or 0)
    elif isinstance(sp, str):
        sp_chars = len(sp)

    # Tool weight: serialize WITH parameters (that's what occupies context),
    # then strip parameters from the payload we ship.
    try:
        tools_chars = len(json.dumps(tools, separators=(",", ":")))
    except Exception:  # noqa: BLE001
        tools_chars = 0

    def _toks(chars: int) -> int:
        return int(round(chars / 4.0)) if chars and chars > 0 else 0

    sp_tokens = _toks(sp_chars)
    tools_tokens = _toks(tools_chars)

    # Live usage (authoritative used/max/model) correlated from sessions.json.
    live = _collect_active_ctx()
    used_fresh = bool(live.get("fresh"))
    used = live.get("used") if used_fresh else None
    window = live.get("max") if used_fresh else None
    model = live.get("model") or evt.get("modelId")

    if used_fresh and isinstance(used, int):
        chat_tokens = max(0, used - sp_tokens - tools_tokens)
    else:
        try:
            msg_chars = len(json.dumps(messages, separators=(",", ":")))
        except Exception:  # noqa: BLE001
            msg_chars = 0
        chat_tokens = _toks(msg_chars + len(prompt))
        used = sp_tokens + tools_tokens + chat_tokens

    pct = round(used / window, 4) if (window and used) else None

    # Group tools by source (native = no `<server>__` prefix).
    grouped: Dict[str, list] = {}
    for t in tools:
        if not isinstance(t, dict):
            continue
        name = str(t.get("name") or "")
        src = name.split("__", 1)[0] if "__" in name else "system"
        grouped.setdefault(src, []).append({
            "name": name,
            "description": str(t.get("description") or ""),
        })

    # Connected/error per MCP: configured in openclaw.json but absent from the
    # compiled tool set => it failed to load/auth.
    try:
        cfg = _load_openclaw_json()
        configured = (cfg.get("mcp") or {}).get("servers") or {}
        configured_ids = list(configured.keys()) if isinstance(configured, dict) else []
    except Exception:  # noqa: BLE001
        configured_ids = []

    sources = [
        {
            "id": src_id,
            "kind": "system" if src_id == "system" else "mcp",
            "toolCount": len(src_tools),
            "status": "connected",
            "tools": src_tools,
        }
        for src_id, src_tools in grouped.items()
    ]
    # A configured MCP whose tools aren't in the compiled set is either freshly
    # enabled (the gateway hot-reloaded it but no turn has compiled it in yet —
    # its tools land in the agent's NEXT message) or genuinely failed (it was
    # available when the last turn compiled but its tools never showed, e.g. a
    # bad token). Distinguish by recency: an id first seen AFTER the last turn's
    # trajectory write stays "connected" (hot-loaded, ready next turn) with a
    # `pendingTurn` hint; one seen before that turn is a real "error". Fixes the
    # stale red dot when you enable an MCP and open CTX before sending a message.
    now = time.time()
    for known in list(_mcp_first_seen):
        if known not in configured_ids:
            del _mcp_first_seen[known]
    for mid in configured_ids:
        _mcp_first_seen.setdefault(mid, now)
    try:
        last_turn_at = traj.stat().st_mtime if traj else 0.0
    except OSError:
        last_turn_at = 0.0
    for mid in configured_ids:
        if mid not in grouped:
            fresh = _mcp_first_seen.get(mid, now) > last_turn_at
            entry = {
                "id": mid, "kind": "mcp", "toolCount": 0,
                "status": "connected" if fresh else "error", "tools": [],
            }
            if fresh:
                entry["pendingTurn"] = True
            sources.append(entry)
    # Stable order: system first, then MCPs by tool count desc, then id.
    sources.sort(key=lambda s: (s["kind"] != "system", -s["toolCount"], s["id"]))

    return {
        "fresh": True,
        "sessionId": evt.get("sessionId"),
        "ts": evt.get("ts"),
        "model": model,
        "provider": evt.get("provider"),
        "window": window,
        "used": used,
        "usedFresh": used_fresh,
        "pct": pct,
        "sections": {
            "systemPrompt": {"chars": sp_chars, "tokens": sp_tokens},
            "tools": {"count": len(tools), "chars": tools_chars, "tokens": tools_tokens},
            "chat": {"messages": len(messages), "tokens": chat_tokens},
        },
        "sources": sources,
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
        self._channels_task: Optional[asyncio.Task] = None
        self._channels_cache: Optional[Dict[str, Any]] = None
        self._channels_state_mtime: float = 0.0

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
        self._channels_task = asyncio.create_task(self._channels_loop())

    async def stop_background(self) -> None:
        for task in (
            self._tail_task,
            self._refresh_task,
            self._refresh_pending,
            self._health_task,
            self._channels_task,
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
        self._channels_task = None

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
        if self._channels_cache is None:
            # Build a synthetic empty snapshot so the widget renders
            # "Sin vincular" instead of a loading spinner forever even
            # before config-sync writes channels-state.json the first time.
            self._channels_cache = self._build_channels_event(self._read_channels_state())
        snaps.append(self._channels_cache)
        return snaps

    @staticmethod
    def _read_channels_state() -> Dict[str, Any]:
        try:
            return json.loads(
                _CHANNELS_STATE_PATH.read_text(encoding="utf-8")
            )
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return {}

    @staticmethod
    def _build_channels_event(state: Dict[str, Any]) -> Dict[str, Any]:
        """Normalize the channels-state.json contents into the stream event
        the mobile client expects. Missing channels collapse to a
        well-formed `unlinked` shape so the UI always has something to
        bind to."""
        whatsapp = state.get("whatsapp") if isinstance(state, dict) else None
        email = state.get("email") if isinstance(state, dict) else None
        telegram = state.get("telegram") if isinstance(state, dict) else None
        if not isinstance(whatsapp, dict):
            whatsapp = {"status": "unlinked"}
        if not isinstance(email, dict):
            email = {"status": "unlinked"}
        if not isinstance(telegram, dict):
            telegram = {"status": "unlinked"}
        return {
            "type": "event",
            "stream": CHANNELS_STREAM,
            "v": 1,
            "payload": {
                "whatsapp": whatsapp,
                "email": email,
                "telegram": telegram,
            },
        }

    async def _channels_loop(self) -> None:
        """Watch `channels-state.json` for mtime changes and broadcast a
        fresh `channels` event whenever config-sync mutates it. Cheap poll
        (1s) — inotify would be slightly nicer but adds a deps chain just
        for one file."""
        while True:
            try:
                try:
                    mtime = _CHANNELS_STATE_PATH.stat().st_mtime
                except (FileNotFoundError, OSError):
                    mtime = 0.0
                if mtime != self._channels_state_mtime or self._channels_cache is None:
                    self._channels_state_mtime = mtime
                    state = self._read_channels_state()
                    event = self._build_channels_event(state)
                    self._channels_cache = event
                    if self._clients:
                        await self._broadcast(event)
            except asyncio.CancelledError:
                raise
            except Exception as e:  # noqa: BLE001
                logger.warning("channels loop error: %s", e)
            await asyncio.sleep(1.0)


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


# ── Storage RPC handlers ─────────────────────────────────────────────
#
# Intercepts `storage.list / storage.delete / storage.download` RPCs from
# the downstream client. Backs the "Archivos → Local" tabs (Carga /
# Descarga) by listing files in `~/.openclaw/workspace/{upload,download}/`
# directly from disk. `storage.download` (v1.12.0+) reuses the same
# `prepareAssistantFile` HMAC bridge that `tnode-chat-sync` already uses
# for `[adjunto:]` markers — file → signed PUT → Cloud Storage → signed
# READ URL → mobile client downloads via OS file handler.

_STORAGE_FOLDERS = {"upload", "download"}
_STORAGE_MAX_LIST = 500
# Same 50MB ceiling enforced by the `prepareAssistantFile` CF — checked
# up-front so the user sees a clear error instead of a generic HTTP 400.
_STORAGE_DOWNLOAD_MAX_BYTES = 50 * 1024 * 1024
# CF endpoints (same constants as chat-sync; redefined here to avoid a
# cross-daemon import).
_PREPARE_ASSISTANT_FILE_URL = (
    "https://us-central1-tbrain-platform-7fc1f.cloudfunctions.net/prepareAssistantFile"
)
_CONFIRM_ASSISTANT_FILE_URL = (
    "https://us-central1-tbrain-platform-7fc1f.cloudfunctions.net/confirmAssistantFile"
)
_STORAGE_DOWNLOAD_TIMEOUT_SEC = 30
_STORAGE_DOWNLOAD_PUT_TIMEOUT_SEC = 120


class StorageError(Exception):
    """Application-level storage RPC error. The `code` lands in
    `rpc-response.error.code` so the client can branch on it."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _resolve_workspace_root() -> Optional[Path]:
    root = OPENCLAW_HOME / "workspace"
    if root.is_dir():
        return root
    return None


def _safe_workspace_path(folder: str, name: str) -> Path:
    """Return workspace/<folder>/<name> if both are safe. Rejects folders
    outside the allow-list, traversal sequences, separators, and any path
    that escapes the workspace root after resolution."""
    if folder not in _STORAGE_FOLDERS:
        raise StorageError(
            "invalid-folder",
            f"folder must be one of {sorted(_STORAGE_FOLDERS)}",
        )
    if not name or "/" in name or "\\" in name or name.startswith("."):
        raise StorageError("invalid-name", "name must be a plain basename")
    if ".." in name:
        raise StorageError("invalid-name", "name must not contain traversal")
    root = _resolve_workspace_root()
    if root is None:
        raise StorageError(
            "workspace-missing", "workspace dir not found on this node"
        )
    folder_dir = (root / folder).resolve()
    p = (folder_dir / name).resolve()
    try:
        p.relative_to(folder_dir)
    except ValueError:
        raise StorageError("path-escape", "resolved path escapes folder")
    return p


def _ext_to_kind(name: str) -> str:
    """Mirror the `FileKind` enum on the Flutter side so the row icon and
    color are picked consistently. Anything unknown lands in `other` and
    the UI shows a neutral icon."""
    lower = name.lower()
    if lower.endswith(".pdf"):
        return "pdf"
    for ext in (".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".bmp"):
        if lower.endswith(ext):
            return "image"
    for ext in (
        ".sh", ".py", ".dart", ".js", ".ts", ".json", ".yaml", ".yml",
        ".go", ".rs", ".rb", ".java", ".kt", ".swift", ".html", ".css",
    ):
        if lower.endswith(ext):
            return "code"
    for ext in (".csv", ".tsv", ".xlsx", ".xls"):
        if lower.endswith(ext):
            return "sheet"
    for ext in (".zip", ".tar", ".gz", ".tgz", ".tar.gz", ".7z", ".bz2"):
        if lower.endswith(ext):
            return "archive"
    for ext in (".txt", ".md", ".log"):
        if lower.endswith(ext):
            return "text"
    return "other"


def _storage_list(folder: str) -> Dict[str, Any]:
    if folder not in _STORAGE_FOLDERS:
        raise StorageError(
            "invalid-folder",
            f"folder must be one of {sorted(_STORAGE_FOLDERS)}",
        )
    root = _resolve_workspace_root()
    if root is None:
        return {"entries": []}
    folder_dir = root / folder
    if not folder_dir.is_dir():
        return {"entries": []}
    entries: list[Dict[str, Any]] = []
    try:
        with os.scandir(folder_dir) as it:
            for de in it:
                if not de.is_file(follow_symlinks=False):
                    continue
                if de.name.startswith("."):
                    continue
                try:
                    st = de.stat(follow_symlinks=False)
                except OSError:
                    continue
                entries.append({
                    "name": de.name,
                    "sizeBytes": int(st.st_size),
                    "mtimeMs": int(st.st_mtime * 1000),
                    "kind": _ext_to_kind(de.name),
                })
    except OSError as e:
        raise StorageError("read-failed", str(e))
    entries.sort(key=lambda e: e["mtimeMs"], reverse=True)
    return {"entries": entries[:_STORAGE_MAX_LIST]}


def _storage_delete(folder: str, name: str) -> Dict[str, Any]:
    p = _safe_workspace_path(folder, name)
    if not p.exists():
        raise StorageError("not-found", f"{name!r} not in {folder!r}")
    if not p.is_file():
        raise StorageError("not-file", f"{name!r} is not a regular file")
    try:
        p.unlink()
    except OSError as e:
        raise StorageError("delete-failed", str(e))
    logger.info("storage.delete %s/%s", folder, name)
    return {"ok": True, "folder": folder, "name": name}


def _sha256_of_file(path: Path) -> str:
    """Streaming SHA-256 so a 50MB file doesn't spike memory."""
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(64 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _guess_mime_for_storage(path: Path) -> str:
    mt, _ = mimetypes.guess_type(str(path))
    return mt or "application/octet-stream"


def _storage_prepare_assistant_file(
    auth: Dict[str, Any], path: Path, sha: str, size: int, mime: str
) -> Dict[str, Any]:
    """POST /prepareAssistantFile. HMAC scheme is the same one chat-sync
    uses for `[adjunto:]` markers — `assistant_file:<sha>` in the signing
    string binds the signature to this specific file."""
    node_id = auth["nodeId"]
    node_secret = auth["nodeSecret"]
    ts = str(int(time.time() * 1000))
    nonce = py_secrets.token_hex(16)
    signing = f"{node_id}:{ts}:{nonce}:assistant_file:{sha}"
    sig = hmac.new(
        node_secret.encode(), signing.encode(), hashlib.sha256
    ).hexdigest()
    body = json.dumps({
        "nodeId": node_id,
        "timestamp": ts,
        "nonce": nonce,
        "signature": sig,
        "fileName": path.name,
        "mimeType": mime,
        "sizeBytes": size,
        "sha256": sha,
    }).encode()
    req = urllib.request.Request(
        _PREPARE_ASSISTANT_FILE_URL,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(
            req, timeout=_STORAGE_DOWNLOAD_TIMEOUT_SEC
        ) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        try:
            detail = e.read().decode()
        except Exception:  # noqa: BLE001
            detail = e.reason
        raise StorageError(
            "prepare-failed",
            f"prepareAssistantFile HTTP {e.code}: {detail}",
        )
    except Exception as e:  # noqa: BLE001
        raise StorageError("prepare-failed", f"prepareAssistantFile: {e}")


def _storage_put_to_signed_url(url: str, path: Path, mime: str) -> None:
    """Single PUT — server-side cap is 50MB so we don't bother chunking."""
    try:
        with path.open("rb") as f:
            data = f.read()
        req = urllib.request.Request(
            url, data=data, method="PUT",
            headers={"Content-Type": mime},
        )
        with urllib.request.urlopen(
            req, timeout=_STORAGE_DOWNLOAD_PUT_TIMEOUT_SEC
        ) as resp:
            if not (200 <= resp.status < 300):
                raise StorageError(
                    "put-failed", f"signed PUT HTTP {resp.status}"
                )
    except urllib.error.HTTPError as e:
        raise StorageError(
            "put-failed", f"signed PUT HTTP {e.code}: {e.reason}"
        )
    except StorageError:
        raise
    except Exception as e:  # noqa: BLE001
        raise StorageError("put-failed", f"signed PUT: {e}")


def _storage_confirm_assistant_file(
    auth: Dict[str, Any], attachment_id: str
) -> None:
    """POST /confirmAssistantFile. Flips the doc to `status='uploaded'`
    so the assistantFileProvider on the client emits ready state."""
    node_id = auth["nodeId"]
    node_secret = auth["nodeSecret"]
    ts = str(int(time.time() * 1000))
    nonce = py_secrets.token_hex(16)
    signing = f"{node_id}:{ts}:{nonce}:confirm:{attachment_id}"
    sig = hmac.new(
        node_secret.encode(), signing.encode(), hashlib.sha256
    ).hexdigest()
    body = json.dumps({
        "nodeId": node_id,
        "timestamp": ts,
        "nonce": nonce,
        "signature": sig,
        "attachmentId": attachment_id,
    }).encode()
    req = urllib.request.Request(
        _CONFIRM_ASSISTANT_FILE_URL,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(
            req, timeout=_STORAGE_DOWNLOAD_TIMEOUT_SEC
        ) as resp:
            resp.read()
    except urllib.error.HTTPError as e:
        try:
            detail = e.read().decode()
        except Exception:  # noqa: BLE001
            detail = e.reason
        raise StorageError(
            "confirm-failed",
            f"confirmAssistantFile HTTP {e.code}: {detail}",
        )
    except Exception as e:  # noqa: BLE001
        raise StorageError("confirm-failed", f"confirmAssistantFile: {e}")


def _storage_download(folder: str, name: str) -> Dict[str, Any]:
    """Resolve workspace/<folder>/<name>, push to Cloud Storage via the
    existing assistant_file HMAC pipeline, return {attachmentId, publicUrl,
    fileName, mimeType, sizeBytes} so the Flutter client can fetch + open.

    The mobile UI surfaces these files in the "Descarga" tab; pressing the
    kebab → "Descargar" calls this RPC, awaits the response, and hands the
    publicUrl to OpenFilex the same way `AssistantFileChip` does for files
    the agent attached via `[adjunto:]` markers in chat."""
    p = _safe_workspace_path(folder, name)
    if not p.exists():
        raise StorageError("not-found", f"{name!r} not in {folder!r}")
    if not p.is_file():
        raise StorageError("not-file", f"{name!r} is not a regular file")
    try:
        size = p.stat().st_size
    except OSError as e:
        raise StorageError("stat-failed", str(e))
    if size <= 0:
        raise StorageError("empty-file", f"{name!r} is empty")
    if size > _STORAGE_DOWNLOAD_MAX_BYTES:
        raise StorageError(
            "too-large",
            f"{name!r} exceeds {_STORAGE_DOWNLOAD_MAX_BYTES} bytes",
        )
    auth = _load_node_auth()
    if auth is None:
        raise StorageError(
            "auth-unavailable",
            "tnode-chat-sync.json missing nodeId/nodeSecret",
        )
    try:
        sha = _sha256_of_file(p)
    except OSError as e:
        raise StorageError("read-failed", str(e))
    mime = _guess_mime_for_storage(p)
    prep = _storage_prepare_assistant_file(auth, p, sha, size, mime)
    attachment_id = prep.get("attachmentId")
    upload_url = prep.get("uploadUrl")
    public_url = prep.get("publicUrl")
    if not attachment_id or not upload_url or not public_url:
        raise StorageError(
            "prepare-incomplete",
            f"prepareAssistantFile response missing fields: {prep}",
        )
    _storage_put_to_signed_url(upload_url, p, mime)
    _storage_confirm_assistant_file(auth, attachment_id)
    logger.info(
        "storage.download %s/%s → attachmentId=%s", folder, name, attachment_id
    )
    return {
        "attachmentId": attachment_id,
        "publicUrl": public_url,
        "fileName": name,
        "sanitizedFileName": prep.get("sanitizedFileName") or name,
        "mimeType": mime,
        "sizeBytes": size,
    }


def _dispatch_storage(method: str, params: Dict[str, Any]) -> Dict[str, Any]:
    if method == "storage.list":
        return _storage_list(str(params.get("folder", "")).strip())
    if method == "storage.delete":
        return _storage_delete(
            str(params.get("folder", "")).strip(),
            str(params.get("name", "")).strip(),
        )
    if method == "storage.download":
        return _storage_download(
            str(params.get("folder", "")).strip(),
            str(params.get("name", "")).strip(),
        )
    raise StorageError("unknown-method", f"Unknown method {method!r}")


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


def _cli_env() -> dict:
    """Env for spawning the `openclaw` CLI. The CLI treats OPENCLAW_HOME as the
    PARENT of the config dir (it appends `.openclaw`), while this daemon uses
    OPENCLAW_HOME as the config dir itself. Inheriting our value makes the CLI
    resolve a doubled `.openclaw/.openclaw/` path (phantom identities, stray
    restart-intents — this is what writes gateway-restart-intent.json to the
    wrong place). Point it at the parent so the CLI lands on the real dir."""
    env = os.environ.copy()
    env["OPENCLAW_HOME"] = str(OPENCLAW_HOME.parent)
    return env


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
                env=_cli_env() if cmd[0] == "openclaw" else None,
            )
            if result.returncode == 0:
                logger.info("gateway reload OK via %s", cmd[0])
                return True
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
    logger.warning("gateway reload failed — config will apply on next boot")
    return False


def _reload_gateway_async() -> None:
    """Fire-and-forget gateway reload so the RPC response reaches the client
    before the reload blocks. `openclaw daemon restart` waits for the gateway
    to come back (can exceed the client's ~15s RPC timeout), which made
    `agent.imageModel.set` look like it failed ("tiempo de espera agotado")
    even though the model WAS written to disk. The config on disk is the
    source of truth, so we run the reload in a daemon thread and return now."""
    import threading
    threading.Thread(
        target=_reload_gateway, name="gateway-reload", daemon=True
    ).start()


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


def _normalize_agent_slug(slug: str) -> str:
    """v1.10.1+ — Normaliza slugs OR canónicos sin prefix → con prefix
    `openrouter/`. Idempotente y safe para slugs ya prefixed o de providers
    runtime custom (LM Studio en `custom-127-0-0-1-<port>/...`, Ollama, etc).

    OpenClaw 2026.5.x requiere prefix del provider local (memoria
    `or_api_quirks` §6). Sin prefix, parser interpreta `<vendor>/<id>` como
    `<provider-local>/<model>` y falla `Unknown model: <vendor>/<id>`.

    Heurística (más conservadora que v1.10.0 que falsamente prefijó
    `custom-127-0-0-1-1234/qwen/qwen3.5-9b` rompiendo LM Studio en Mini):
    - Solo slugs de EXACTAMENTE 2 segmentos son candidatos a normalize.
      Slugs de 3+ segmentos (e.g. `openrouter/qwen/qwen3.6-plus`,
      `custom-127-0-0-1-1234/qwen/qwen3.5-9b`) YA tienen provider prefix.
    - Si el primer segmento es un provider local conocido (`openrouter`,
      `groq`, `moonshot`, `ollama`, `lmstudio`, `llama-cpp`) NO normalizar.
    - Si empieza con `custom-` o contiene `.`/`_` (IP-like), provider runtime
      custom — NO normalizar.
    - Lo demás: slug OR canónico `<vendor>/<id>`, prepend `openrouter/`.
    """
    if not isinstance(slug, str) or "/" not in slug:
        return slug
    parts = slug.split("/")
    if len(parts) != 2:
        return slug
    first = parts[0]
    _local_providers = (
        "openrouter", "groq", "moonshot", "ollama", "lmstudio", "llama-cpp",
    )
    if first in _local_providers:
        return slug
    if first.startswith("custom-") or any(c in first for c in (".", "_")):
        return slug
    return "openrouter/" + slug


def _agent_model_set(agent_id: str, model_slug: str) -> Dict[str, Any]:
    """Sets the per-agent primary model. If the node has no `agents.list[]`
    entry for `agent_id`, one is created (`{id, default, model: {primary}}`),
    so this works on freshly-provisioned nodes that only have
    `defaults.models`. Atomic file write + best-effort gateway reload.

    Critically also adds `model_slug` to `agents.defaults.models` (the plural
    dict). OpenClaw v2026.4.x builds the agent's allowlist from that key —
    if the slug isn't there, the resolver silently falls back to the
    pre-existing default and the user's selection is ignored at runtime.
    Merges (doesn't replace) so multiple agents can keep distinct models.

    v1.10.0+ — `model_slug` se normaliza al inicio (`_normalize_agent_slug`)
    para garantizar prefix `openrouter/` cuando el cliente envía slugs OR
    canónicos sin prefix (slugs heredados pre-2026-05-09 en Firestore).
    """
    model_slug = _normalize_agent_slug(model_slug)
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


def _node_media_model_get(config_key: str) -> Dict[str, Any]:
    """Returns a node-global media-generation model from `agents.defaults`
    (`imageGenerationModel` / `musicGenerationModel` / `videoGenerationModel`).
    Unlike the chat model these are NOT per-agent — OpenClaw 2026.5.x only
    honors them under `agents.defaults` (the `agents.list[]` schema rejects
    them). `null` when the node has no model configured for that slot."""
    config = _load_openclaw_json()
    val = ((config.get("agents") or {}).get("defaults") or {}).get(config_key)
    return {config_key: val if isinstance(val, str) else None}


def _node_media_model_set(config_key: str, model_slug: str) -> Dict[str, Any]:
    """Sets a node-global media-generation model under `agents.defaults`
    (`imageGenerationModel` / `musicGenerationModel` / `videoGenerationModel`).
    Node-scoped, not per-agent (see _node_media_model_get). The slug is
    normalized to carry the `openrouter/` prefix like the chat model. The
    gateway auto-enables the matching generation plugin from this key on
    reload, so unlike _agent_model_set we don't upsert a providers[].models[]
    catalog entry (its text-oriented contextWindow/maxTokens wouldn't fit a
    media model). Atomic write + best-effort async reload."""
    model_slug = _normalize_agent_slug(model_slug)
    if not isinstance(model_slug, str) or "/" not in model_slug:
        raise AgentError(
            "invalid-model-slug",
            f"model must be 'provider/model', got {model_slug!r}",
        )
    config = _load_openclaw_json()
    agents = config.setdefault("agents", {})
    if not isinstance(agents, dict):
        raise AgentError("agents-malformed", "agents is not an object")
    defaults = agents.setdefault("defaults", {})
    if not isinstance(defaults, dict):
        raise AgentError("defaults-malformed", "agents.defaults is not an object")
    defaults[config_key] = model_slug
    _save_openclaw_json_atomic(config)
    # Reload in the background: `openclaw daemon restart` can block past the
    # client's RPC timeout, which surfaced as a false "tiempo de espera agotado"
    # even though the model was already persisted. Fire-and-forget so the client
    # gets a fast OK; the config on disk is the source of truth.
    _reload_gateway_async()
    logger.info("node.%s.set → %s (reload=async)", config_key, model_slug)
    return {config_key: model_slug, "gatewayReloaded": True}


def _dispatch_agent(method: str, params: Dict[str, Any]) -> Dict[str, Any]:
    agent_id = str(params.get("agentId") or "main")
    if method == "agent.model.get":
        return _agent_model_get(agent_id)
    if method == "agent.model.set":
        return _agent_model_set(agent_id, str(params.get("model", "")))
    # Node-global media-generation models (agents.defaults.<X>GenerationModel).
    # agentId is ignored — these slots are per-node, not per-agent. The gateway
    # auto-enables the matching plugin (image/music/video) from each key.
    if method == "agent.imageModel.get":
        return _node_media_model_get("imageGenerationModel")
    if method == "agent.imageModel.set":
        return _node_media_model_set("imageGenerationModel", str(params.get("model", "")))
    if method == "agent.musicModel.get":
        return _node_media_model_get("musicGenerationModel")
    if method == "agent.musicModel.set":
        return _node_media_model_set("musicGenerationModel", str(params.get("model", "")))
    if method == "agent.videoModel.get":
        return _node_media_model_get("videoGenerationModel")
    if method == "agent.videoModel.set":
        return _node_media_model_set("videoGenerationModel", str(params.get("model", "")))
    # Read-only: compiled-context breakdown for the CTX screen. agentId ignored
    # (the active session is whichever trajectory was touched most recently).
    if method == "agent.context.get":
        return _collect_compiled_context()
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
                    if await self._maybe_handle_storage_rpc(message):
                        continue
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

    async def _maybe_handle_storage_rpc(self, message: Any) -> bool:
        """If `message` is a `storage.*` RPC, answer it locally and return
        True so the caller skips the upstream forward."""
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
        if not isinstance(method, str) or not method.startswith("storage."):
            return False
        req_id = frame.get("id", "")
        raw_params = frame.get("params") or {}
        params = raw_params if isinstance(raw_params, dict) else {}
        try:
            payload = _dispatch_storage(method, params)
            response = {
                "type": "res",
                "id": req_id,
                "ok": True,
                "payload": payload,
            }
        except StorageError as e:
            response = {
                "type": "res",
                "id": req_id,
                "ok": False,
                "error": {"code": e.code, "message": e.message},
            }
        except Exception as e:  # noqa: BLE001
            logger.exception("storage rpc %s failed", method)
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
# path → raw GitHub). Default goes straight to raw GitHub because the
# install.tbrain.app/* path on the Free CF plan is served by a Bulk Redirect
# that does NOT preserve $1 (Page Rule budget consumed by update/health/
# updates.tbrain.app). Override with VERIFY_BASE_URL=... if a path-preserving
# CDN is set up later (Pro plan + Page Rule for install.tbrain.app/verify/*).
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
# are preserved). Idempotent.
update_openclaw_gateway_only() {
    if ! command_exists npm; then
        die "openclaw-gateway: npm requerido"
    fi
    local npm_target="openclaw"
    [[ -n "$OPENCLAW_PIN_VERSION" ]] && npm_target="openclaw@$OPENCLAW_PIN_VERSION"
    run_with_progress "Actualizando openclaw kernel ($npm_target)" --estimate 30 npm install -g "$npm_target"

    local tnode_uid
    tnode_uid="$(id -u "$TNODE_USER" 2>/dev/null || echo "")"
    case "$OS" in
        Darwin)
            # launchd: kickstart by killing the gateway; launchctl restarts it
            pkill -f "openclaw-gatewa" 2>/dev/null || true
            sleep 1
            ;;
        Linux)
            if [[ "$(id -u)" == "0" ]] && [[ -n "$tnode_uid" ]]; then
                su - "$TNODE_USER" -c "export XDG_RUNTIME_DIR=/run/user/$tnode_uid; systemctl --user restart openclaw-gateway" 2>/dev/null || true
            else
                systemctl --user restart openclaw-gateway 2>/dev/null || true
            fi
            ;;
    esac
    success "openclaw-gateway refreshed"
}

# Detect a stale openclaw-gateway daemon — binary updated on disk (via
# `npm install -g openclaw@*`, `openclaw update`, or any other path that
# bypasses the installer) but the daemon still has the old code in RAM —
# and reload it. Without this, clients on the new version handshake with
# the stale gateway and get "protocol mismatch" rejection loops every
# 10s. Linux-only (macOS LaunchAgent path not covered here).
ensure_openclaw_gateway_fresh() {
    [[ "$OS" == "Darwin" ]] && return 0
    command_exists systemctl || return 0
    local tnode_uid
    tnode_uid="$(id -u "$TNODE_USER" 2>/dev/null || echo "")"
    [[ -z "$tnode_uid" ]] && return 0

    # Helper: run `systemctl --user` against the tnode user-bus. Uses
    # `sudo -u` (passwordless from root) + `env` to set XDG_RUNTIME_DIR
    # without the quoting hazards of `su -c "..."`.
    _gw_systemctl() {
        if [[ "$(id -u)" == "0" ]]; then
            sudo -u "$TNODE_USER" env "XDG_RUNTIME_DIR=/run/user/$tnode_uid" systemctl --user "$@"
        else
            systemctl --user "$@"
        fi
    }

    local unit_active
    unit_active="$(_gw_systemctl is-active openclaw-gateway 2>/dev/null || true)"
    [[ "$unit_active" != "active" ]] && return 0

    # Locate the openclaw npm package dir; its mtime bumps on every
    # `npm install -g openclaw@*` so it's the most reliable "binary
    # updated" signal across all update paths.
    local pkg_dir=""
    local cand
    for cand in /usr/lib/node_modules/openclaw /usr/local/lib/node_modules/openclaw; do
        if [[ -d "$cand" ]]; then pkg_dir="$cand"; break; fi
    done
    [[ -z "$pkg_dir" ]] && return 0

    local pkg_mtime daemon_start_ts daemon_start_epoch
    pkg_mtime="$(stat -c %Y "$pkg_dir" 2>/dev/null)" || return 0
    daemon_start_ts="$(_gw_systemctl show openclaw-gateway --property=ActiveEnterTimestamp --value 2>/dev/null)"
    [[ -z "$daemon_start_ts" ]] && return 0
    daemon_start_epoch="$(date -d "$daemon_start_ts" +%s 2>/dev/null)" || return 0

    if [[ "$pkg_mtime" -le "$daemon_start_epoch" ]]; then
        info "openclaw-gateway al día (paquete sin cambios desde último start)"
        return 0
    fi

    local installed_ver
    installed_ver="$(openclaw --version 2>/dev/null | awk '{print $2}')"
    warn "openclaw-gateway corre binary obsoleto (paquete actualizado tras start del daemon)"
    info "Reiniciando openclaw-gateway para cargar ${installed_ver:-versión instalada}..."
    _gw_systemctl daemon-reload 2>/dev/null || true
    _gw_systemctl restart openclaw-gateway 2>/dev/null || true
    sleep 2
    success "openclaw-gateway reiniciado (ahora corre ${installed_ver:-binary nuevo})"
}

# Refresh cloudflared binary via OS package manager + restart its service.
# Tunnel credentials/config are untouched.
update_cloudflared_only() {
    case "$OS" in
        Darwin)
            ensure_brew_on_path
            if command_exists brew; then
                run_with_progress "brew upgrade cloudflared" --estimate 25 \
                    brew upgrade cloudflare/cloudflare/cloudflared 2>/dev/null || true
            else
                warn "brew no disponible — skip cloudflared upgrade"
            fi
            launchctl kickstart -k system/com.cloudflare.cloudflared 2>/dev/null || true
            ;;
        Linux)
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
            ;;
    esac
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

    # Remove sudo NOPASSWD drop-in before deleting the user. Otherwise we
    # leak a sudoers entry referencing a non-existent user — many sudo
    # versions warn on every invocation when that happens.
    if [[ "$OS" != "Darwin" ]] && [[ -f /etc/sudoers.d/tnode ]]; then
        if _uninstall_sudo rm -f /etc/sudoers.d/tnode; then
            success "sudoers drop-in /etc/sudoers.d/tnode eliminado"
        else
            warn "no pude borrar /etc/sudoers.d/tnode — bórralo manual"
        fi
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
        # Path B: re-enable the materialized plugins after phase_tunnel.
        enable_pathb_plugins
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
    # Belt-and-suspenders: detect a gateway daemon running stale binary
    # (e.g. `openclaw update` ran outside the installer) and reload it.
    # In a fresh install or after --component=openclaw-gateway this is a
    # no-op; the cost is one stat + one systemctl show per run.
    ensure_openclaw_gateway_fresh
    phase_components_manifest
    [[ "$NO_SMOKE_TEST" == "0" && "$UPDATE_ONLY" == "1" ]] && run_smoke_test_all
    phase_summary
}

main "$@"
