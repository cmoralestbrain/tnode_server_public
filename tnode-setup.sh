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

TNODE_SETUP_VERSION="1.68.0"
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
alqTBa7CyPVqdxBNM+PPxoNvM0uzDdzLS4LZe7ylI1mLY/hLEFHzMQuE6HZ26BZ5qalmuaEer4f1
9ChVXrRLZra32ua77F47ZBvzXrGYiM57aiE2TWwbPSDqhkp5kKAnAh3tV5dNRcmYuphqJQcL8hM2
xiV0j3MnWkPBGIh5Bz++On9BWFjq6Wfr+2fFKgy3pH0MeYMJiTyjyg/VnTZR0IP2R7/aM9cv1kVl
KbLb4TpVEcz0PlvsxejyupGvmr1qk48JGlVNdbviIdygslq5k9fygiEflkVBH4vSNmuEmXKqr2fS
B6k/6I4CeyX8sDFvLPfKkrt2NGDkLnQgiybkFf4UjPjDA9oc4nK2UJ2I9Xq3kmc3B4pOb3JTY5xZ
9yqNdsmQq+WpmjdHqeW41mKUnLgrNifyiqnOy2p2SEa7XOow1MxSrV6jm7VUNDI3Np+EfLzBKlDl
DDqLIsjtdJW6fuBz8h6mealD9nnvoZNz/RyquW2Qeb6QPGwKBb44y65zHe0wY4pbNlc1zVqjXonH
p+tVIt5pMGNNEpl8vxnJTgfDhNThqrPMNEalhWhrMWAjGTLPZXOZ3ir1RdFz35rTR1hM4yUW8ltd
Gn60IyyFubaenbnr9CZMEvYd+hDM+DuxabAeFhd0ShfSjU5lFkhzmVKcjZWni2FvUU4dktO9slmN
RX436pG9Ur/MjNTRIrInc0Ux1hw1+8uksMpR1UGhnyyLh3gvnlDz6S8ydWIx98ERH/H3gzWP2F3y
2EH5xGx72SPmSzDzZnG2WUR6uYq6yPapbbKakCKtVIKJi+t+MsvUU2ZPCaQLCakWWWhiaUdxLDVt
tjuJBDdI5PR83lzRA77SbQl6rMVGBtlq9jPHkX4gmO2zjq4ty93DNEgSsQt+wAuiPoy21T5GT5ek
ZszNsdAwu0xAiDPtdMA06kIjZRwiU7Ze6gi9Ii2kVnJ4KnT5hEhnqMVwPSpk8uX0KNM2Dty+2970
11ouvjzoja861cRfat7ZOT6P21/sJg2Z7brhd09xqVtMbqLGZF/e1ZWC2pQKTFSqSpv4okOlirO8
zORqfC02oMhCLj0q1KPDerFFLQqH2nrS1obTeTHKUo1wuDko9TI7vkarVZ15WPhtS109SyF61yIm
JAh4Bf8gZ8IHh/LtCj1uztkIN+xS9HI9GY7EyCpjGNt+aT9YJuVtnwqze9kM5zc5elbfFwLJ+TBQ
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
# 1.41.0 — Cron declarativo del resurtido (P3 supplier_restock): la CF
#          syncInventoryFlowOnWrite compone inventoryCronJson/inventoryCronHash
#          en el node doc al tocar config/inventoryFlow; _sync_inventory_cron
#          (dentro del pase declarativo, hash-gated con stamp local
#          .tnode-inventory-cron-hash) materializa el job "tnode-inventario"
#          vía CLI del core: rm de los jobs con ese nombre + add fresco si
#          enabled (agent main, sesión isolated, sin --announce — la entrega
#          es la ApprovalCard). Motor 100% agente; el daemon solo declara.
# 1.42.0 — El cron declarativo deja el CLI y va por RPC WS token-only
#          (`_gateway_rpc`: connect backend sin identidad de device →
#          cron.list/cron.add/cron.remove). En nodo FRESCO el device del CLI
#          nace operator.read y los writes caen en el treadmill "scope
#          upgrade pending approval" que ni pair-watch puede aprobar (cada
#          connect re-acuña el requestId; el gateway re-persiste los scopes
#          del token, patchear paired.json no dura) — el cron jamás
#          materializaba (E2E VPS 167.71.81.30, 2026-07-04). El token maestro
#          autentica full-operator, igual que el inject de chat-sync.
# 1.43.0 — TEAM_INDEX.md ON-NODE (Harness Eng. F1): _team_index_sync_from_json
#          deja de leer teamIndexJson/teamIndexHash de la CF y compone el roster
#          LOCALMENTE (_compose_team_index_doc: puerto byte-idéntico de la CF
#          buildTeamIndexDoc; peers/ + toolsJson de cada peer → _derive_peer_
#          specialty). Hash-gate local (sha256 del body). Primer índice migrado
#          del patrón CF→SKILL (motor=plantilla local, datos=Firestore hot).
#          Paridad byte-a-byte verificada en shadow (TNODE_TEAM_SHADOW_ONLY)
#          antes del flip. La CF buildTeamIndexDoc+trigger quedan como no-op
#          hasta retirarse cuando toda la flota esté en >=1.43.0.
__VERSION__ = "1.43.0"

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


def _run_openclaw(*args: str, timeout: int = 60, stdout_limit: int = 2000) -> dict:
    """stdout_limit trunca al TAIL (default 2000, como siempre); 0 = sin
    truncar — necesario cuando el caller parsea JSON del stdout (un JSON
    truncado por la cabeza parece parsear y truena con 'Extra data')."""
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
            "stdout": proc.stdout[-stdout_limit:] if stdout_limit else proc.stdout,
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


# ── TEAM_INDEX.md compositor ON-NODE (F1: reemplaza la CF buildTeamIndexDoc) ──
# Puerto byte-idéntico de tnode_client/functions/src/soul_identity_sync.ts:
# buildTeamIndexDoc + derivePeerSpecialty. Compone el roster localmente desde
# peers/ (+ el toolsJson de cada peer) en vez de recibir teamIndexJson de la CF.
# El renderer/hash-gate (_render_team_index) NO cambia — solo el origen del doc.
_TEAM_FEATURE_LABELS = {
    "feature:agenda": "agendar citas",
    "feature:drive": "leer Drive",
    "feature:email": "correo",
    "feature:poll": "encuestas",
}


def _tv_str(field):
    """String de un valor Firestore REST (helper local del compositor — los
    _fs_str/_fs_bool viven en la región embebida del skill delegate, fuera de
    este namespace)."""
    return field.get("stringValue") if isinstance(field, dict) else None


def _tv_bool(field):
    return bool(field.get("booleanValue")) if isinstance(field, dict) else False


def _derive_peer_specialty(tools_json: str | None) -> str:
    """Deriva la 'especialidad' de un peer desde su toolsJson compuesto:
    mapea ids de bloque (feature:* / mcp:*) a etiquetas legibles."""
    if not tools_json:
        return ""
    try:
        doc = json.loads(tools_json)
    except Exception:  # noqa: BLE001
        return ""
    blocks = doc.get("blocks") if isinstance(doc, dict) else None
    if not isinstance(blocks, list):
        blocks = []
    feats: list[str] = []
    mcps: list[str] = []
    for b in blocks:
        bid = b.get("id") if isinstance(b, dict) else None
        if not isinstance(bid, str):
            continue
        if bid in _TEAM_FEATURE_LABELS:
            feats.append(_TEAM_FEATURE_LABELS[bid])
        elif bid.startswith("mcp:"):
            mcps.append(bid[4:])
    parts: list[str] = []
    if feats:
        parts.append(", ".join(feats))
    if mcps:
        parts.append("MCP: " + ", ".join(mcps))
    return " · ".join(parts)


def _md_cell(s: str) -> str:
    """Celda de tabla Markdown segura: escapa `|`, colapsa saltos, fallback."""
    v = re.sub(r"\s*\n+\s*", " ", (s or "").replace("|", "\\|")).strip()
    return v or "—"


def _read_node_tools_json(token: dict, node_id: str) -> str | None:
    """Cross-read del toolsJson de OTRO nodo (para derivar su especialidad)."""
    url = (
        f"{_firestore_base()}/users/{token['uid']}/nodes/{node_id}"
        f"?mask.fieldPaths=toolsJson"
    )
    try:
        doc = _http_request(
            "GET", url,
            headers={"Authorization": f"Bearer {token['idToken']}"},
        )
    except Exception:  # noqa: BLE001
        return None
    fields = (doc or {}).get("fields") or {}
    return _fs_unwrap(fields["toolsJson"]) if "toolsJson" in fields else None


def _team_read_peers(token: dict) -> list:
    """Peers enabled (domain OPCIONAL — espeja la CF, no _list_peers que exige
    domain), ordenados por alias. Cada uno: {id, tid, alias, role}."""
    parent = f"users/{token['uid']}/nodes/{token['nodeId']}"
    url = (
        f"https://firestore.googleapis.com/v1/projects/{PROJECT_ID}"
        f"/databases/(default)/documents/{parent}:runQuery"
    )
    rows = _http_request(
        "POST", url,
        payload={"structuredQuery": {"from": [{"collectionId": "peers"}]}},
        headers={"Authorization": f"Bearer {token['idToken']}"},
    )
    if isinstance(rows, dict):
        rows = [rows]
    peers: list = []
    for row in rows:
        doc = row.get("document") if isinstance(row, dict) else None
        if not doc:
            continue
        f = doc.get("fields", {})
        if not _tv_bool(f.get("enabled")):
            continue
        did = doc.get("name", "").split("/")[-1]
        tid = (_tv_str(f.get("targetNodeId")) or did).strip()
        alias = (_tv_str(f.get("alias")) or tid).strip()
        role = (_tv_str(f.get("role")) or "").strip()
        peers.append({"id": did, "tid": tid, "alias": alias, "role": role})
    peers.sort(key=lambda p: (p["alias"] or p["id"]).lower())
    return peers


def _compose_team_index_doc(token: dict) -> dict:
    """Puerto on-node de la CF buildTeamIndexDoc. Devuelve el mismo doc
    {schema,target,blocks:[{order,id,kind,text}]} — texto byte-idéntico."""
    peers = _team_read_peers(token)
    if not peers:
        return {"schema": 1, "target": "TEAM_INDEX.md", "blocks": []}
    rows = [
        f"| `{p['alias']}` | {_md_cell(p['role'])} | "
        f"{_md_cell(_derive_peer_specialty(_read_node_tools_json(token, p['tid'])))} | "
        f"`{p['tid']}` |"
        for p in peers
    ]
    body = "\n".join(
        [
            "# Equipo de TNodes",
            "",
            "Otros nodos del dueño a los que puedes **delegar** tareas con "
            '`tnode-delegate delegate --alias <alias> --text "..."`. Cada uno '
            "resuelve con SUS canales, skills y contexto.",
            "Generado automáticamente desde el widget Equipo de la app; cambia "
            "al enlazar/desenlazar nodos. La columna *especialidad* se deriva de "
            "las herramientas reales de cada nodo.",
            "",
            "| alias | rol | especialidad | nodeId |",
            "|---|---|---|---|",
            *rows,
            "",
            f"_{len(peers)} nodo(s) en tu equipo._",
        ]
    )
    return {
        "schema": 1,
        "target": "TEAM_INDEX.md",
        "blocks": [{"order": 0, "id": "team-index", "kind": "static", "text": body}],
    }


def _team_shadow_check(token: dict) -> None:
    """MODO SOMBRA (F1 cutover): compone el TEAM_INDEX localmente y lo compara,
    byte-a-byte, contra el teamIndexJson que la CF sigue produciendo. NO renderiza
    nada. Si difiere, escribe un diff a .tnode-team-shadow.diff. Gate de paridad
    antes de retirar la CF."""
    try:
        local = _compose_team_index_doc(token)
        local_body = _render_tools_zone(local.get("blocks") or [])
        raw = _firestore_get_node_field(token, "teamIndexJson")
        cf = json.loads(raw) if raw else {"blocks": []}
        cf_body = _render_tools_zone(cf.get("blocks") or [])
        if local_body == cf_body:
            _log(
                f"team-shadow: PARITY ok "
                f"({len(local.get('blocks') or [])} block(s), {len(local_body)} chars)"
            )
            return
        import difflib
        d = "\n".join(
            difflib.unified_diff(
                cf_body.splitlines(), local_body.splitlines(),
                fromfile="cf", tofile="local", lineterm="",
            )
        )
        (OPENCLAW_DIR / ".tnode-team-shadow.diff").write_text(
            d[:6000], encoding="utf-8"
        )
        _log(
            f"team-shadow: DIFF local={len(local_body)} cf={len(cf_body)} "
            f"→ .tnode-team-shadow.diff"
        )
    except Exception as e:  # noqa: BLE001
        _log(f"team-shadow: error {e}")


def _team_index_sync_from_json(token: dict) -> None:
    """Render agency-agents/TEAM_INDEX.md desde el COMPOSITOR ON-NODE (F1).
    Compone el roster localmente (peers/ + toolsJson de cada peer) en vez de leer
    el teamIndexJson de la CF. Hash-gate local (sha256 del body renderizado, que
    captura con/sin peers). Sin peers → body vacío → _render_team_index borra el
    archivo. Resiliente: cualquier fallo deja el archivo intacto. El nombre de la
    función se conserva por el call-site en _run_declarative_sync."""
    try:
        doc = _compose_team_index_doc(token)
        body = _render_tools_zone(doc.get("blocks") or [])
    except Exception as e:  # noqa: BLE001
        _log(f"team-index: compose failed: {e}")
        return
    digest = hashlib.sha256(body.encode("utf-8")).hexdigest()
    if digest == _team_read_local_hash():
        return  # sin cambios → no reescribir
    if _render_team_index(doc):
        _team_write_local_hash(digest)
        n = len(doc.get("blocks") or [])
        _log(f"team-index: rendered LOCAL (hash {digest[:12]}, {n} block(s))")


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

# ── Cron declarativo del resurtido (v1.41.0) ─────────────────────
# La CF syncInventoryFlowOnWrite (inventory_flow.ts) compone
# inventoryCronJson/inventoryCronHash en el node doc cuando el dueño toca
# config/inventoryFlow; aquí lo materializamos con el CLI del core (mismo
# patrón declarativo por hash que TOOLS.md). El motor del flujo es 100%
# agente (cron nativo OpenClaw, sesión aislada); este daemon SOLO garantiza
# que el job exista/desaparezca según lo declarado — no orquesta nada.
_INVENTORY_CRON_HASH_PATH = OPENCLAW_DIR / ".tnode-inventory-cron-hash"


def _read_inventory_cron_hash() -> str:
    try:
        return _INVENTORY_CRON_HASH_PATH.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def _write_inventory_cron_hash(value: str) -> None:
    try:
        _INVENTORY_CRON_HASH_PATH.write_text(value, encoding="utf-8")
    except OSError:
        pass


_GATEWAY_WS_URL = "ws://127.0.0.1:18789"


def _gateway_rpc(method: str, params: dict, timeout: float = 20.0) -> dict:
    """RPC al gateway local por WS con connect BACKEND token-only (SIN
    identidad de device) — el mismo mecanismo con el que chat-sync inyecta
    el outbox. El CLI NO sirve para los writes de cron en nodo FRESCO: su
    device nace con solo `operator.read` y cualquier write cae en un
    treadmill de "scope upgrade pending approval" que ni pair-watch puede
    aprobar (cada connect del CLI re-acuña el requestId y el approve llega
    tarde; el gateway además re-persiste los scopes del token, así que
    patchear paired.json tampoco dura). Medido E2E en el VPS 167.71.81.30
    (2026-07-04). El token maestro de openclaw.json autentica full-operator.

    Devuelve el frame `res` del método. Lanza RuntimeError si no hay
    token/lib, el connect falla o el método responde error."""
    try:
        from websockets.sync.client import connect as _ws_connect  # noqa: PLC0415
    except Exception as e:  # noqa: BLE001
        raise RuntimeError(f"websockets>=13 no importable: {e}")
    try:
        cfg = json.loads((OPENCLAW_DIR / "openclaw.json").read_text())
        tok = ((cfg.get("gateway") or {}).get("auth") or {}).get("token") or ""
    except Exception as e:  # noqa: BLE001
        raise RuntimeError(f"openclaw.json unreadable: {e}")
    if not tok:
        raise RuntimeError("no gateway.auth.token in openclaw.json")

    deadline = time.time() + timeout

    conn = _ws_connect(
        _GATEWAY_WS_URL, open_timeout=5, close_timeout=2,
        max_size=8 * 1024 * 1024,
    )

    def _recv() -> dict:
        remaining = deadline - time.time()
        if remaining <= 0:
            raise RuntimeError("gateway rpc deadline exceeded")
        try:
            return json.loads(conn.recv(timeout=remaining))
        except (TypeError, ValueError):
            return {}

    try:
        while True:
            f = _recv()
            if f.get("type") == "event" and f.get("event") == "connect.challenge":
                break
        cid = os.urandom(8).hex()
        conn.send(json.dumps({
            "type": "req", "id": cid, "method": "connect",
            "params": {
                "minProtocol": 4, "maxProtocol": 4,
                "client": {
                    "id": "gateway-client",
                    "displayName": "tnode-config-sync",
                    "version": __VERSION__,
                    "platform": sys.platform,
                    "mode": "backend",
                },
                "auth": {"token": tok},
                "role": "operator",
                "scopes": ["operator.read", "operator.write", "operator.admin"],
                "caps": [],
            },
        }))
        while True:
            f = _recv()
            if f.get("type") == "res" and f.get("id") == cid:
                if not f.get("ok"):
                    err = f.get("error") or {}
                    raise RuntimeError(
                        f"gateway connect: {err.get('code')}: {err.get('message')}"
                    )
                break
        rid = os.urandom(8).hex()
        conn.send(json.dumps(
            {"type": "req", "id": rid, "method": method, "params": params}
        ))
        while True:
            f = _recv()
            if f.get("type") == "res" and f.get("id") == rid:
                if not f.get("ok"):
                    err = f.get("error") or {}
                    raise RuntimeError(
                        f"{method}: {err.get('code')}: {err.get('message')}"
                    )
                return f
    finally:
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass


def _find_cron_job_ids(name: str) -> list:
    """Ids de los cron jobs del gateway con ese nombre (incluye disabled)."""
    res = _gateway_rpc("cron.list", {"includeDisabled": True})
    jobs = ((res.get("payload") or {}).get("jobs")) or []
    return [j.get("id") for j in jobs if j.get("name") == name and j.get("id")]


def _sync_inventory_cron(token: dict) -> None:
    """Materializa el cron declarado en inventoryCronJson (hash-gated).

    Estrategia rm+add (sin diffear campos): en cambio de hash se quitan los
    jobs con el nombre gestionado y, si enabled, se crea uno fresco. El add va
    SIN --announce: la entrega al dueño es la ApprovalCard (server-write de
    approvalApi), y announce truena con multi-canal (visto en P2: "Channel is
    required when multiple channels are configured"). El hash local solo se
    estampa en éxito — gateway caído reintenta al próximo pase."""
    try:
        remote_hash = _firestore_get_node_field(token, "inventoryCronHash")
    except Exception as e:  # noqa: BLE001
        _log(f"inventory-cron: hash read failed: {e}")
        return
    if not remote_hash or remote_hash == _read_inventory_cron_hash():
        return
    try:
        raw = _firestore_get_node_field(token, "inventoryCronJson")
        doc = json.loads(raw) if raw else None
    except Exception as e:  # noqa: BLE001
        _log(f"inventory-cron: json read/parse failed: {e}")
        return
    if not isinstance(doc, dict):
        return
    name = str(doc.get("name") or "tnode-inventario")
    try:
        for jid in _find_cron_job_ids(name):
            _gateway_rpc("cron.remove", {"id": jid})
        if doc.get("enabled") is True and doc.get("message"):
            every = int(doc.get("everyMinutes") or 15)
            _gateway_rpc("cron.add", {
                "name": name,
                "agentId": str(doc.get("agent") or "main"),
                "sessionTarget": str(doc.get("session") or "isolated"),
                "wakeMode": "now",
                "enabled": True,
                "schedule": {"kind": "every", "everyMs": every * 60000},
                "payload": {
                    "kind": "agentTurn",
                    "message": str(doc.get("message")),
                    "thinking": str(doc.get("thinking") or "low"),
                    "timeoutSeconds": int(doc.get("timeoutSeconds") or 480),
                },
                # Entrega explícita al canal del app: "last" truena en nodos
                # multi-canal ("Channel is required…", visto en P2 con
                # telegram+tnode) y best-effort evita que un fallo de entrega
                # marque el job en error (la ApprovalCard va por server-write,
                # no depende de esto; esto solo acarrea reportes del agente).
                "delivery": {
                    "mode": "announce",
                    "channel": "tnode",
                    "bestEffort": True,
                },
            })
            _log(
                f"inventory-cron: materialized '{name}' every {every}m "
                f"(hash {remote_hash[:12]})"
            )
        else:
            _log(
                f"inventory-cron: disabled — removed '{name}' "
                f"(hash {remote_hash[:12]})"
            )
        _write_inventory_cron_hash(remote_hash)
    except Exception as e:  # noqa: BLE001
        _log(f"inventory-cron: sync failed (will retry): {e}")


def _run_declarative_sync(token: dict) -> None:
    """Prime the hash fields in ONE masked GET, then render every
    declarative file (TOOLS/SOUL/IDENTITY/USER/TEAM) whose hash changed.
    Shared by the slow safety-timer in the main loop and the SessionStart
    DECL_ONESHOT hook. Each step is individually resilient (swallows its own
    errors), so one bad target never aborts the rest."""
    _prime_node_fields(
        token,
        [
            "toolsHash", "soulHash", "identityHash", "userHash",
            "teamIndexHash", "inventoryCronHash",
        ],
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
    # Cron declarativo del resurtido (hash-gated; rm+add vía CLI del core).
    _sync_inventory_cron(token)
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
        if os.environ.get("TNODE_TEAM_SHADOW_ONLY"):
            # F1 cutover: solo corre el gate de paridad del compositor on-node
            # contra la CF. No renderiza ni toca ningún archivo.
            _team_shadow_check(token)
            return 0
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
  TNODE_CHAT_SYNC_PRESENCE_FILE    App-presence touch file (default ~/.openclaw/app-presence)
  TNODE_CHAT_SYNC_PRESENCE_FRESH_S Presence freshness window (default 90)
  TNODE_CHAT_SYNC_UPLOAD_POLL_IDLE_S / _CRON_CMD_IDLE_S / _TASK_CMD_IDLE_S
                            Idle backstop cadences for uploads/commands (default 30)
  TNODE_CHAT_SYNC_CRON_MIRROR_IDLE_S / _TASKS_MIRROR_IDLE_S  Idle mirror scan (default 60)
  TNODE_CHAT_SYNC_MIRROR_RECONCILE_S  Mirror full-reconcile backstop (default 600)
"""
from __future__ import annotations
# 1.28.0 — Adaptive Firestore cadence (read-cost fix, auditoría 2026-07-04:
#          ~146k queries/día/nodo con la flota EN REPOSO). Los relojes rápidos
#          (uploads 2s, cron/task commands 3s, mirrors 10s, transport GET 10s)
#          solo corren así mientras el nodo está HOT: actividad reciente de
#          trajectory/outbox, o el app sosteniendo un WS a través del sidecar
#          de telemetría (archivo app-presence, tnode-telemetry 1.18.0+).
#          En idle: backstops de 30s (uploads/commands), 60s (mirror scans) y
#          90s (transport TTL). Los mirrors de crons/tasks además quedan
#          change-gated por hash del snapshot local + reconcile de 600s — un
#          nodo en reposo ya no re-lista ni re-escribe cada cron doc cada 10s.
#          El outbox conserva su idle de 10s: es el camino GARANTIZADO de
#          entrada para guests (Firestore-first, sin WS) y no debe degradarse.
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
__VERSION__ = "1.28.0"

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

# ── Adaptive cadence (v1.28.0) ──────────────────────────────────
# Every Firestore poll runs on two clocks: HOT (the historical fast
# cadences) while somebody is actually using the node, IDLE (slow
# backstops) otherwise. Hot signals:
#   - trajectory/outbox activity (the pre-existing outbox hot window), and
#   - the app holding a WS client through the telemetry sidecar, which
#     touches APP_PRESENCE_FILE every ~30s while ≥1 client is connected
#     (tnode-telemetry 1.18.0+). File missing → activity signal only.
# The outbox keeps its own 10s idle clock — it is the GUARANTEED inbound
# path for guests (Firestore-first, no WS) and must not back off further.
APP_PRESENCE_FILE = Path(
    os.environ.get(
        "TNODE_CHAT_SYNC_PRESENCE_FILE", str(OPENCLAW_DIR / "app-presence")
    )
)
APP_PRESENCE_FRESH_S = float(
    os.environ.get("TNODE_CHAT_SYNC_PRESENCE_FRESH_S", "90")
)


def _app_present(now: float) -> bool:
    """True while the telemetry sidecar reports a live app WS client
    (presence file mtime within APP_PRESENCE_FRESH_S). Local stat() —
    zero Firestore cost; called once per main-loop pass."""
    try:
        return (now - APP_PRESENCE_FILE.stat().st_mtime) < APP_PRESENCE_FRESH_S
    except OSError:
        return False


# Idle backstops for the fast pollers. Worst case with the app open but
# without WS presence (shouldn't happen — the app keeps the sidecar WS on
# every node screen) a cron/upload command takes up to ~30s to reflect;
# the first hit found flips the node hot so the rest of the editing
# session runs at the fast cadence again.
UPLOAD_POLL_IDLE_S = float(
    os.environ.get("TNODE_CHAT_SYNC_UPLOAD_POLL_IDLE_S", "30.0")
)
CRON_COMMAND_POLL_IDLE_S = float(
    os.environ.get("TNODE_CHAT_SYNC_CRON_CMD_IDLE_S", "30.0")
)
TASK_COMMAND_POLL_IDLE_S = float(
    os.environ.get("TNODE_CHAT_SYNC_TASK_CMD_IDLE_S", "30.0")
)
CRON_MIRROR_IDLE_S = float(
    os.environ.get("TNODE_CHAT_SYNC_CRON_MIRROR_IDLE_S", "60.0")
)
TASKS_MIRROR_IDLE_S = float(
    os.environ.get("TNODE_CHAT_SYNC_TASKS_MIRROR_IDLE_S", "60.0")
)
# Mirrors are change-gated by a hash of the local snapshot; this backstop
# forces a full list+reconcile against Firestore even without local
# changes, healing any drift (e.g. docs edited/deleted server-side).
MIRROR_RECONCILE_S = float(
    os.environ.get("TNODE_CHAT_SYNC_MIRROR_RECONCILE_S", "600")
)

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


def process_uploads(token: dict, project_id: str) -> bool:
    """Poll pending uploads, download each into workspace/upload/,
    verify sha256, and flip status. Best-effort — failures are logged +
    written back to the doc so the user sees them in the chip.

    Returns True when pending docs were seen (feeds the hot window).
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
        return False
    except Exception as e:  # noqa: BLE001
        _log(f"uploads query error: {e}")
        return False

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

    return bool(pending)


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
_TNODE_TRANSPORT_TTL_HOT_S = 10.0
_TNODE_TRANSPORT_TTL_IDLE_S = float(
    os.environ.get("TNODE_CHAT_SYNC_TRANSPORT_TTL_IDLE_S", "90.0")
)
_tnode_transport_cache: dict = {"active": False, "ts": 0.0}


def _refresh_tnode_transport_active(
    token: dict, project_id: str, node_id: str, hot: bool = True
) -> None:
    """Refresh `_tnode_transport_cache` from Firestore
    `users/{uid}/nodes/{nodeId}.transportEnabled`. TTL-gated (≈1 GET per
    TTL window; 10s hot / 90s idle — flipping the cutover toggle happens
    from the app, which makes the node hot via presence, so the idle TTL
    is never on the user's critical path). Called from the main loop,
    which owns the token.
    Fail-safe: a 404 (node doc absent) means NOT cut over; transient errors
    keep the last known value so a blip doesn't flip the chat path."""
    now = time.time()
    ttl = _TNODE_TRANSPORT_TTL_HOT_S if hot else _TNODE_TRANSPORT_TTL_IDLE_S
    if now - _tnode_transport_cache["ts"] < ttl:
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


_crons_mirror_state: dict = {"hash": None, "ts": 0.0}


def process_crons_mirror(
    token: dict, project_id: str, force: bool = False
) -> None:
    """Sync `openclaw cron list --json` → Firestore `crons/`.
    Upserts each present job; deletes Firestore docs for jobs no longer
    in the local list. Idempotent — safe to call frequently.

    v1.28.0: change-gated — the Firestore list + writes only run when the
    local snapshot hash changed, on `force` (right after a cron command),
    or every MIRROR_RECONCILE_S as a drift-healing backstop. The local
    CLI fetch still runs each call (no Firestore cost)."""
    jobs = _fetch_local_crons()
    if jobs is None:
        return
    now = time.time()
    snapshot_hash = hashlib.sha256(
        json.dumps(jobs, sort_keys=True, default=str).encode("utf-8")
    ).hexdigest()
    if (
        not force
        and snapshot_hash == _crons_mirror_state["hash"]
        and (now - _crons_mirror_state["ts"]) < MIRROR_RECONCILE_S
    ):
        return
    local_ids = {j.get("id") for j in jobs if j.get("id")}
    remote_ids = _query_existing_cron_ids(token, project_id)
    if remote_ids is None:
        # Couldn't enumerate — only do upserts, skip deletes to avoid
        # nuking docs by accident on a transient error. Don't record the
        # hash so the next tick retries the full reconcile.
        for job in jobs:
            _write_cron_doc(token, project_id, job)
        return
    for job in jobs:
        _write_cron_doc(token, project_id, job)
    for orphan in remote_ids - local_ids:
        _delete_cron_doc(token, project_id, orphan)
    _crons_mirror_state["hash"] = snapshot_hash
    _crons_mirror_state["ts"] = now


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


def process_cron_commands(token: dict, project_id: str) -> bool:
    """Pop pending cron.* commands, execute, mirror state (the mirror loop
    re-runs anyway, but doing it inline keeps the UI responsive).
    Returns True when commands were seen (feeds the hot window)."""
    pending = _query_pending_cron_commands(token, project_id)
    if not pending:
        return False
    for cmd in pending:
        cmd_id = cmd["id"]
        ok, summary = _execute_cron_command(cmd["type"], cmd["params"])
        new_status = "done" if ok else "error"
        _update_cron_command(token, project_id, cmd_id, new_status, summary)
        _log(f"cron cmd {cmd_id} type={cmd['type']} → {new_status}: {summary[:80]}")
    # Refresh mirror so the client sees the post-command state immediately.
    # force=True: bypass the change-gate — the command just mutated crons.
    process_crons_mirror(token, project_id, force=True)
    return True


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


_tasks_mirror_state: dict = {"hash": None, "ts": 0.0}


def process_tasks_mirror(token: dict, project_id: str) -> None:
    """Snapshot SQLite `task_runs` → Firestore `tasks/`. Idempotent.

    v1.28.0: change-gated on the hash of the selected rows, with a
    MIRROR_RECONCILE_S backstop — the SQLite read is local and free, the
    Firestore list + writes only run when something actually changed."""
    all_tasks = _fetch_local_tasks()
    if all_tasks is None:
        return
    to_mirror = _select_tasks_to_mirror(all_tasks)
    now = time.time()
    snapshot_hash = hashlib.sha256(
        json.dumps(to_mirror, sort_keys=True, default=str).encode("utf-8")
    ).hexdigest()
    if (
        snapshot_hash == _tasks_mirror_state["hash"]
        and (now - _tasks_mirror_state["ts"]) < MIRROR_RECONCILE_S
    ):
        return
    local_ids = {t["taskId"] for t in to_mirror if t.get("taskId")}
    remote_ids = _query_existing_task_ids(token, project_id)
    if remote_ids is None:
        # Couldn't enumerate — only upsert, skip deletes to avoid
        # accidental loss on a transient error. Don't record the hash so
        # the next tick retries the full reconcile.
        for task in to_mirror:
            _write_task_doc(token, project_id, task)
        return
    for task in to_mirror:
        _write_task_doc(token, project_id, task)
    for orphan in remote_ids - local_ids:
        _delete_task_doc(token, project_id, orphan)
    _tasks_mirror_state["hash"] = snapshot_hash
    _tasks_mirror_state["ts"] = now


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
) -> bool:
    """Pop pending tasks.* commands and execute them.
    Returns True when commands were seen (feeds the hot window)."""
    pending = _query_pending_task_commands(token, project_id)
    if not pending:
        return False
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
    return True


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


def _outbox_gate(session_key: str, idem_key: str) -> str:
    """Decide what to do with a pending outbox doc BEFORE injecting it —
    dedupe against the gateway's own ground truth (v1.27.0, double-delivery
    fix: device-check +191 saw approval decisions duplicated/aborted when the
    app's pending→ws flip didn't land by sweep time).

    Returns one of:
      "delivered" — the gateway already received this idempotencyKey on that
          session: the user entry lands in the legacy `<sessionId>.jsonl` as
          `"idempotencyKey":"<key>:user"` when the turn completes (the
          gateway also reuses the raw key as the turn's runId). Injecting
          again would START A SECOND TURN — the gateway only dedupes an
          idempotencyKey while its run is in flight, NOT after completion
          (both verified live on the Mini gateway, 2026-07-03). Flip the
          doc, don't send.
      "inflight" — the session has a live `<sessionId>.jsonl.lock` (created
          at accept, removed at turn end — the session jsonl itself is only
          written at completion, so during the turn the lock is the ONLY
          local signal). A turn is running right now: defer to the next
          sweep — by then the key shows up in the jsonl ("delivered") or the
          lock clears ("send"). Deferring also stops an outbox inject from
          aborting an unrelated in-flight turn. Locks older than 10 min are
          treated as orphans (gateway crash) and ignored.
      "send" — no evidence the gateway got it: inject as usual.

    Fail-open: any error → "send" (today's behavior)."""
    try:
        if not idem_key or not session_key:
            return "send"
        routed = _route_session_key(session_key)
        # sessions.json keys carry the agent prefix: raw app keys land in the
        # index as `agent:main:<key>` (observed live on the Mini).
        if routed.startswith("agent:"):
            keys = (routed,)
        else:
            keys = (f"agent:main:{routed}", routed)
        # Prefix-match (no closing quote): the stored value is `<key>:user`.
        needles = tuple(
            f'"idempotencyKey":{sp}"{idem_key}'.encode() for sp in ("", " ")
        )
        for d in resolve_all_sessions_dirs():
            idx = d / "sessions.json"
            if not idx.is_file():
                continue
            try:
                index = json.loads(idx.read_text())
            except (OSError, ValueError):
                continue
            for k in keys:
                sid = (index.get(k) or {}).get("sessionId")
                if not sid:
                    continue
                f = d / f"{sid}.jsonl"
                if f.is_file():
                    try:
                        blob = f.read_bytes()
                    except OSError:
                        blob = b""
                    if any(n in blob for n in needles):
                        return "delivered"
                lock = d / f"{sid}.jsonl.lock"
                if lock.exists():
                    try:
                        age = time.time() - lock.stat().st_mtime
                    except OSError:
                        age = 0.0
                    if age < 600:
                        return "inflight"
        return "send"
    except Exception:  # noqa: BLE001
        return "send"


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
            gate = _outbox_gate(it["sessionKey"], it["idempotencyKey"])
            if gate == "delivered":
                # El gateway ya recibió este key por el WS directo — el flip
                # pending→ws del app no aterrizó. Re-inyectar arrancaría un
                # SEGUNDO turno; solo cerramos el doc.
                _log(
                    f"outbox: {it['id']} already in session jsonl — "
                    "skip inject (double-delivery dedupe)"
                )
                update_chat_outbox_doc(
                    token, project_id, it["uid"], it["id"],
                    fields={
                        "delivery": {"stringValue": "node"},
                        "updatedAt": _now_ts_value(),
                    },
                    mask=["delivery", "updatedAt"],
                )
            elif gate == "inflight":
                # Turno en vuelo en esa sesión: diferir al próximo sweep (no
                # quema attempts). Log una vez por doc para no spamear.
                logged = state.setdefault("outbox_inflight_logged", set())
                if it["id"] not in logged:
                    logged.add(it["id"])
                    _log(
                        f"outbox: {it['id']} session turn in flight — deferred"
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
    # Global hot window (v1.28.0, grew out of the outbox's v1.17.0 clock):
    # trajectory activity, outbox pendings, found commands/uploads, or app
    # presence via the sidecar keep the node hot; every Firestore poll picks
    # its fast or backstop cadence off this single signal.
    last_outbox_check = 0.0
    hot_until = 0.0
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
                now_f = time.time()
                _refresh_tnode_transport_active(
                    token, project_id, cfg["nodeId"],
                    hot=(now_f < hot_until) or _app_present(now_f),
                )

            for line in tailer.read_new_lines():
                # Any trajectory activity means the user is around — keep
                # the outbox poll on the hot clock so a WS-down message
                # lands within a few seconds instead of the idle interval.
                hot_until = max(
                    hot_until, time.time() + OUTBOX_TAIL_HOT_S
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

            # Firestore polls (v1.28.0) — each clock picks its fast cadence
            # while the node is hot, its slow backstop while idle. Any poll
            # that finds work re-arms the hot window so the rest of the
            # user's session runs at the fast cadence.
            now_f = time.time()
            is_hot = (now_f < hot_until) or _app_present(now_f)

            # Chat-attachment poll — slower clock than the JSONL tail.
            uploads_interval = (
                UPLOAD_POLL_INTERVAL_S if is_hot else UPLOAD_POLL_IDLE_S
            )
            if (
                token is not None
                and (now_f - last_uploads_check) >= uploads_interval
            ):
                last_uploads_check = now_f
                try:
                    if process_uploads(token, project_id):
                        hot_until = max(
                            hot_until, time.time() + OUTBOX_HOT_WINDOW_S
                        )
                except urllib.error.HTTPError as e:
                    if e.code == 401:
                        _log("uploads poll: idToken rejected — refreshing")
                        token = None

            # Cron CRUD commands poll — fast clock so the app sees the
            # operation reflected within a few seconds.
            cron_cmd_interval = (
                CRON_COMMAND_POLL_INTERVAL_S if is_hot
                else CRON_COMMAND_POLL_IDLE_S
            )
            if (
                token is not None
                and (now_f - last_cron_command_check) >= cron_cmd_interval
            ):
                last_cron_command_check = now_f
                try:
                    if process_cron_commands(token, project_id):
                        hot_until = max(
                            hot_until, time.time() + OUTBOX_HOT_WINDOW_S
                        )
                except urllib.error.HTTPError as e:
                    if e.code == 401:
                        _log("cron commands poll: idToken rejected — refreshing")
                        token = None

            # Cron mirror — snapshot of `openclaw cron list --json` to
            # Firestore. The scan itself is local; process_crons_mirror only
            # touches Firestore when the snapshot hash changed (or on its
            # reconcile backstop).
            cron_mirror_interval = (
                CRON_MIRROR_INTERVAL_S if is_hot else CRON_MIRROR_IDLE_S
            )
            if (
                token is not None
                and (now_f - last_cron_mirror_check) >= cron_mirror_interval
            ):
                last_cron_mirror_check = now_f
                try:
                    process_crons_mirror(token, project_id)
                except urllib.error.HTTPError as e:
                    if e.code == 401:
                        _log("cron mirror: idToken rejected — refreshing")
                        token = None

            # Tasks mirror — SQLite → Firestore snapshot of TaskFlow runs.
            # Same change-gate as the cron mirror.
            tasks_mirror_interval = (
                TASKS_MIRROR_INTERVAL_S if is_hot else TASKS_MIRROR_IDLE_S
            )
            if (
                token is not None
                and (now_f - last_tasks_mirror_check) >= tasks_mirror_interval
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
            task_cmd_interval = (
                TASK_COMMAND_POLL_INTERVAL_S if is_hot
                else TASK_COMMAND_POLL_IDLE_S
            )
            if (
                token is not None
                and (now_f - last_task_command_check) >= task_cmd_interval
            ):
                last_task_command_check = now_f
                try:
                    if process_task_commands(token, project_id, cfg):
                        hot_until = max(
                            hot_until, time.time() + OUTBOX_HOT_WINDOW_S
                        )
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
            # OUTBOX_POLL_IDLE_S (10s) is the floor for this clock even on a
            # fully idle node — guests message Firestore-first with no WS, so
            # this is their guaranteed inbound latency.
            outbox_interval = (
                OUTBOX_POLL_HOT_S if is_hot else OUTBOX_POLL_IDLE_S
            )
            if (
                token is not None
                and (now_f - last_outbox_check) >= outbox_interval
            ):
                last_outbox_check = now_f
                try:
                    if process_outbox(token, project_id, outbox_state):
                        hot_until = time.time() + OUTBOX_HOT_WINDOW_S
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
# 1.18.0 — App-presence beacon para el fix de reads Firestore (chat-sync
#          1.28.0): mientras haya ≥1 cliente WS conectado (el app entra por
#          este proxy — túnel CF → :18790), se toca ~/.openclaw/app-presence
#          cada PRESENCE_TOUCH_SEC (30s) y al conectar. chat-sync lee el
#          mtime (stat local, gratis) y mantiene sus polls de Firestore en
#          cadencia rápida solo mientras el archivo esté fresco. Sin
#          clientes → sin touch → chat-sync cae a backstops idle.
__VERSION__ = "1.18.0"

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

# App-presence beacon (v1.18.0) — touched on client connect and every
# PRESENCE_TOUCH_SEC while ≥1 WS client is connected. tnode-chat-sync
# 1.28.0+ stats this file to keep its Firestore polls on the fast cadence
# only while the app is actually around.
PRESENCE_FILE = Path(
    os.environ.get(
        "TNODE_TELEMETRY_PRESENCE_FILE", str(OPENCLAW_HOME / "app-presence")
    )
)
PRESENCE_TOUCH_SEC = float(
    os.environ.get("TNODE_TELEMETRY_PRESENCE_TOUCH_SEC", "30")
)


def _touch_presence() -> None:
    """Best-effort mtime bump; never raises into the caller."""
    try:
        PRESENCE_FILE.touch()
    except OSError:
        pass

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
        self._presence_task: Optional[asyncio.Task] = None

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
        self._presence_task = asyncio.create_task(self._presence_loop())

    async def _presence_loop(self) -> None:
        """Keep the app-presence beacon fresh while clients are connected.
        No clients → no touches → chat-sync's polls fall back to their
        idle backstops after APP_PRESENCE_FRESH_S."""
        while True:
            try:
                if self._clients:
                    _touch_presence()
            except asyncio.CancelledError:
                raise
            except Exception as e:  # noqa: BLE001
                logger.exception("presence loop error: %s", e)
            await asyncio.sleep(PRESENCE_TOUCH_SEC)

    async def stop_background(self) -> None:
        for task in (
            self._tail_task,
            self._refresh_task,
            self._refresh_pending,
            self._health_task,
            self._channels_task,
            self._presence_task,
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
        self._presence_task = None

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
        # Presence beacon: flip chat-sync hot as soon as the app connects,
        # without waiting for the next _presence_loop tick.
        _touch_presence()
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
