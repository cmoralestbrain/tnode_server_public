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

TNODE_SETUP_VERSION="1.56.0"
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
xjYcZ0RsKoe7YE3FdpPbsm2CYvcc8KneE42TZGsmXze66RX2yzYp+qv04Rt9yDwC6dKN4BOeWJdS
iYTrhyAaW/nFAwH8BT/01Hpk+1gTNvnnmIPBSxUefY6Rm514O8Nf49D0GMSRrZBrKYF2eS2J31BC
bkkjm/I6w9DBJ/THOl3+1uTJCcGUjmLCT4aA+o9eK3+Pac75j4jv/V1lvPr8J5XI5xMr/e9d0ur8
5w+dFjj/+W458OL8n4r/lsqmVva/d0kz4r9tbGxm0qvjn99/mjn/l7b6vzT/U8lUPulf/7PZ1fnP
uyR+/uOga0dx9x+lMx923jDrIIgHO7HPgyo6IePQ2UFAFA0ea4uf16gWRvYil2BTqrMh6IDg1iMU
YouOIpxzlCbsfXHXiOGChLMIxZDGho434wj5XNhzN6FfsSq0cePBqfaPC8UwkqsqQM+KwA7kEUNj
dAiElUUSMbt4KxLxpFqSs0GmmGuy1vPgkCNFim6GceXotAg2xDFpx4l9BKxU6AafE6CHo75vtU34
i8Me0OaYDpoi4tma6/PPQyupJuuJMR7GwNbU5IHIor7DJjqHCvMu8J3p4akVtBqPTFxgdwYAzrHY
GUUbVH2dwdVGCGaGbjQRWT80uwNfb6PSNHXoGjpy8IVvYsDK+325uc7hB7cneJD2QjAjHAu7qqag
XzV2GhRj4t/e79qeKERdva+0VMObRfdkuYNWet/jBUHIwU9P2E65cn56UCrWbss7eBoUeESHZz8L
nO4x5H48qMGIODic2yo/RbSf4zj4SJ2FFCneGLqvd+xIFnT9FYZxFM86Mf4BDXPqzEhMOlZxZy4A
SnuP/ZBk0Mnfm4/9kGDgyd/bj/2WfyrHCB6XT2q31eJppYRfI29uKVaDk2G3eosFIpAI74wyu/Po
nFu5K+L0iRX/xIx/+OZ8/RzHAxYcCmY8zMO2ROItvUlHkmadHRies/NjYjWOVzxIx6nmF4sUqa3O
4q7xOxVAX+nrA5QQOHOhbSfFo8LV7f7pcQk7nAsBvCQBlNelxoidTBePyhLetKDzQjvjUMawGBgl
kwJbDlGKgXCO2RHK6jC+KobeUKSGbnXX2TF4/X+LuxnEg0d/zCs7XOCOaoS9p4wwfFp0YopO+l9/
E8+ocBB+EodkzNNE97wKXnkc/x2SseHI7NLrjzPfohTALOtSyGlLyO/RHfAJFzAIWhrwoYAVhL2K
oKAOEbGuVH1HoDHK1FmhoP4H8oF3DuALsb78qVviV6EFHLUiKuEVheepDvPdX8HKfwrsRW83DlnE
GrGzaienO6Xb4n4BJt71SfG2eHqyW97DY+QXWykcRQrMoegocw9RfdrsFl0UsucACScKHgZLFcxT
WcBIFU9PWYwf4fBUXH6oElDvkdWObgT1dg/7+muIIeyH1tnCwhSOEN0NHlgXhhb6zT8IfoZiv/Z8
V0pe10D73vGHbz1fw+wBgSFrhHsPXViI95XHsEnVWycDGhBgl9x80cTcpTscMrtyKpsLIZQFKVIx
FrQx7P0+1lI7IDDDoa7yiF36/JPPHIH31iHDAXR5eGRoiNep4lH6t2fv2AowJlB2l4GxWAy/faMJ
YB2/DyMB+2oSv99s2waWceDPRZph8CvuvEM/fKNymSmD7rrvlWohvBQDTXx+tRUAE5TBc7OZa3/7
0TdvIF/AGAkzpNMp44G0xSJcsXB8x0zdZvGYgpXuMOopkqBukxo9pXEzKxfTtIM0GJwwt9yAPNOw
hZmYUWsqqCJd/uLXNl0kTU+HDjBSlAOITRppOJnDmBX8O3sEu5+4puZPzizCaF1uc9cxno39CJH2
oN9M/C+Vhn+4KonTfRwOEJnrDjB3kiA5LkAWsYMFm7M8AoZVbktyK+qFhUClj2LcbAEj132fQju8
jxyu+B43dcTBcdsrXiYNmmEyMziyAGhvM0A64yyIj28xRWLbygO8Dll0dW5umWT1JeOkvzNm2RR5
SBbszZigxK/zaQhjCNhY43FbWBANvxiyEC2DZmh5YIXtBseYpdgsU9C1UDqXSEAtkgmfMc5de1q8
FIeAve11spDdjmo6EuOw2GOH3vgHD69FAZaoY1gxY21NB3EnQNnGoU4guTC2CjQkKuUSQqxDiviJ
Ic/QWQHpO5ZvZkInuaOQ+tpQ2njFjjl7iCIC1DHYa7j7XFsq2GHbbHAQ9/atOmhrGLfc85CYbYya
QEIULkShi+Ok7QkGx2QpE0+4sYbKkWxhwf+m1gPgBbycyyHvndSfGcF/+RdWOmuE51fMYb30K9IP
VBjd7F7y9Nzmw+wv7RwfvbwQGOhKZJtLXmoc9jUIaFBo2CfJh/9lV0JAAPLR5QCi4SAwGn8l3V5m
lNy/Zzf2OUBnvjNr+q55KWsjJezsRJCdD3R1GIvBa7Tsl4OTHfGX9o1yEhkWftgOfCDchH7w4uJN
k2BvOJGH2RQaIPIUeRBEgr96mcZg1G+gnX/6UvgJvYmpIIYspaMYyJbPGE2W/eSk+fIK755RvZBa
+qihKf5yn53SveGPHyIBdZfxFafwDR3MQOgDLbrtLXQTljizWXoDN/Ch6dnaVhWNgiuLGI4iKmxv
HYskVNhTIhLD0OMq6BMPvo0bIwUKP1DzDB9Zmx6G3zC4k9MoXotnL3+CB4DA4aDNHmsplr5LRMPC
5ecZTfY3N6ixdCX6pxeb6l2SWDaS/g7sW1E8VbSBoVFZc8I+8pzv9j+sXBUWpr7MvKlUxfX62z6t
7dNZyq42siyCSMTdBH4SZsF92ZF6XFMbdDYU/4Yuj6DHm+7h0i1/FGvJhrWOcdI0M84BlekZCDz0
/Buw03Hf/pkBghsY7wf9euLfEDknjnngb66JYoB5C3629CYiaq+TX91AEU5t1zGitabU0SMHz31H
Kq22SDLuAMli0OQWoX40JlKdbQ9bBaseQ3o7YhxMikgero9u/+Ig8TUnoDD9Woc1ri7f/gX7v9z6
tR6Bcd5jR2HUDjoDdUNooiMkouZFCXGSjuthIPKArpKPB9QceYiH5zqPH0zHlehNZJ/B0dkmnn0i
8ChH2YPmxkj/uKDYdGgSYHHf6ISbd4Snl9ENFnuahx6WTXvExqRKoVbcl1STjtQGYltY5DsXx5eO
/zxMw0CUGINUYG28zjba+DeRNBijLFSM0JJia+s0wepSeMAAUWv28wg/1J2wvmNh9jCSHFETnFdZ
yHIENKw7H8fwhJjC+cF2OVJnbDbn7MoCYhMS/oXpFTFcGQ4ITehEI1zn4QYD4wyCJPzEgDVMUT92
zmGdtzH3EajG7rm++BVNCvgCg5FCDdiCQN5ssH6FRrchDNMj34aeP3xjVXqufwwUl4KCveWXyqwQ
T5RzTZnKReV7I66zyIy+fPy5mJVt+Kdyhmzbjcfr0RlfFBbdM4S2XB4L2wF7DC6Y39RHoLIGN8/L
XiYeicVu7HKRlBCmvWjHtPe3kUnEvt5QNW873aEz9ZEQe+t5eoPjy8zj4j47+xVbi/C1yL8CxrzS
jwJi+YcF1YBRRIxePwUmKF/6kmPX4Ij3xNGcqpDn7TTVIBp2GR78ocUO2QoiMBGsUNsMVOjDN7Zt
4dtODJ8kFoFi/IKAIWFKciONYKF5jrOF7sM3YCtijZ2XizDIYT2DPTFGl7JXv8AMrCsjfEmsT7Gv
TzCc2KM8JKyoE6LJD/b4fP7s8DVlS8okNmGdkPl1AxTjtps+O8tm1lk3oC6KWVOkqlrsQgIo4Q8K
M9FEVdNjsUPDs22URfuzHZGXY9H59NYgb2xE3yHOPn+2l0OKCxHAJRJXEa/vNaZZ506YnANYHCLe
VzNORGy1NhIMNSaeq+KGVzjYJPRC4Lofz23q9Hx6QeKdF/7AtaFI8IlreOqwN+IewCZzvgNYF21N
hOETTQzzOyR4rAb1gtsDqGgEucB72b8Y659f67sesNAvjaHCfvubY6QFCfGPdpz5naTYLVsvx6B4
/6gyEq/Bf0rnpUQyTf6fK/+vd0gr/+8/dHLdvH+cHHhx/ov3/2n+Z1PZ1Mr/+z2S//5/KpWO5VOJ
ZDKdS2dWDuC/++TO+mUiPnnTS/M/kfDP/3Q6l1rhP71HEvo/dovHvT+gjNfrf5lMbuX//z5ppf/9
oZMw/11VcMly4PX6Xy6VXOE/vUsK1P+SmXQyuZnPrfS/330S5j9d/fsRZbxe/8ukU9mV/vceyaP/
2bcYeKwicsZfQhmJ1+A/UP/ns/kV/vv7pJX+94dOgfrfkuXAi/NfxH/A+Z9KptOr8793SX78B6b/
ZVPZRGKF//AHSML8/0Gr/4vzPwnJv/6nsyv737sktOqH1FbIcZzCoUCOBCG5aakPLIrYFrf+h/RB
FcOCjYYhdi3lJx4aLjSQ++T3w1AirhwiLcUJA42vTxGiIOoFPhTCOYfJoSYuD1W8e0MVimOFIuj1
Ykn4p2m7vNKdR+bwaelSC6/l2/gEffSOvR8pIwwQ3VRi0rkYYpndmv6zKaktTXHxHKShrmluAK6h
3mMXTHiI6R3Z7DZ02Wj9/d//g9ySyUNNJZAD1lRWI+Yc7HLM4g5R3KmceViE5FZLZXiVFQPmnWGp
igm56JYIzzIUX9jOFyGQnQ1NaQmPhDJsn37X4cPP/2OZomibY9VqdmPSFV7ipkLF4NMmjzNph/VD
UAu6vU5dHgv9JLq54H//WYNbrdKLybP/G8rNHrqZL03ys/T6/V8OPljJ/3dJq/3fHzoF7v+WLAde
nP9T5//5XHK1/3uXFHz+n81lYQeeX20Af/dJmP8/aPV/cf6nkrmc3/8rh/FfVuv/j0/fxM3bXxm6
mXMSEPVvCR/Q0ZvtJBKxZCzBntrbj77eGmk859DAvaPCt4lBW0F3p0iXHfT5O8Pv2f9JYUPc/wVs
+yJ8Cwf5dNjT6cZkegPXUZ3d28jQ+JM1G0kC/u6OGoQa0ezrhqwBdT8zbeg4PF0xYwK9loq38Fip
IT4NTcEhM+Rss9FFfmBSfS5OjsrF0km1tMPqzpjrbhZDjZGqsY292ZSiQwn+IZ4xjKV1t3UUPmNW
RikaHeilvltZVv8tO3YHfjcY9jGYu0Ql4uUMu80c99F0In0ANbwkPJFizNyoDlrKI5TjtrCtarTj
/WqzxnRKDjqgst+dlwo7x6VYv4WUfmNDUFEMB41R3EY7hLDuv35CuRPLxZIJtxL+T48VSw783NmX
2+En3HMRvjXmQ99bDfvpQ3D9/oq9YtLFJazif02lYgk+2XiXsc6ml9nYZkyo+lTlQsqjBWMGauey
FZ4GdABnnMTuCcqW2D7G8sJQ9fPMPmtAZKs9hkt36UoJD29XhwX/fMmz//dM/OWV8Yb9fzqxWv/f
J632/3/oFLj/X7IcePX+P5VIpNOr/f97pOD9fy6RTqXzKwPw7z8J8/8Hrf4vz/98Nu9f/5OJ1Gr9
f4/07Seu7sO2yzilTYywEQHWdBTaZpSq0D0pewvCd/rwHDfxJ7DD8L4hUOuRvdP358Gr501LOBqg
vRBsWgzb2izaQWH7v6MaSEfcC5o9dXikNop86ypQQiTSC7ZBjzl7Vtnqesyof7W3SXG2sYmaLSTz
NRSLxb2hC2gXdsuaZTqbebZ5cr/l+6hWDDbgv63PKyX+y3eV8wsvw7fBVCH3iHaLX0OsKpBpHdhk
NOO//AJf0TcBGy+P/m9/ueQx9nr9P5tanf+9U1rp/3/oFKj/L1kOvMH+BxuAlf7/HmmG/p9JZVPJ
1Er//90nYf7/oNX/pfmfhLU+61//E9nkav1/j8Tjf/mMcXagDztuF9ls7PBU59wx0HSxMV8w3nEX
Sh62ZovTwTTD35Pe+fDiOFzcX1iUKyfmAIeN+5UTPR1ArcjaRPHa0YGT4VR6YtXEY1hKfV1i8cig
HRNoUb8l1WO4VahLowGLgzOWLUIh//u//4dEEK1OXB7X/FjHsOtkf4zqA8Xs6pZEuHFhHgCFwp6w
ECg754Xyyack4mz9wj4RomoJVsvTk2IJQ/0g6pttuhRKnPJdRXJox9zyua9S2DBPH8xxY8XobIoB
n2saxTYjPvPQIgwa3nQAGDGMmKnbtTaxSG2CkJv9oQV/UGCnJ8XQqZ52ODeTRS9KJxImd8IlxFRo
wRBx6yamHYsIQ9dbE4wMhRhkMtl90S0VA5woLXsc4vggTkOz6zj2tmwzVahOo1gYcwhbPIZWm5JC
MHk8GgBajvWRgdSggS2MJ4edMEbYPnxBCKhIOiZdKQSy11Bgk6pAE1ksdSqDnJqhT+wxieScmO8s
FJsTvs7pIBsTEOM9mVQqBXqj6lE/RDjgH1IjzL+mPoIFFKssO81qKYgVHGVFUZwFyRwZbRgw9tju
yjSGCOKT4bw2ZSipxXJHgaV9HONSA6pD7h/UR24oORqCFP2nxYzpM4Lp8Qh8A5x3MGU8vaQbAkoy
MqBysX1Uru6XdqTqziEBmBoyRkWrB++Y62zCDNUBRg3D8HV1xxbMTJV1KSwYJan3bf/lfcsantMU
0GioWsTcmB1or6szPD5sIRt9WCWYGBgIiYKefZTqU7Tqtpc0czpAYlR6NpbclNBACwN61DDX7SBq
jAA73+CCCb6XDUMfw1hqymwo0tjvykOiNwUvjW/dJuLBgC+6HsOVrxDjSmRlt4PbBbKV/0myXQyL
R/LSjnc0L8TezPh5PAfx4ZtUHkAfgZzj0IDrUlUxoHHnijnUB6bipYD+FEIZP0kBsafwxMMbpgqf
4PijmXjBglSwCVq2g1nYpcQouinN6TtsDQ//dn56USvdVgq1fYwPN70isRB/RY4pzSRSY2SYFmIs
osA3LQLRhm7pcQDquO2UAjKzA7NpiNEqQcnSx3aUu6vCYem2tn9+WqsdlW6Pq1A0qD4JVhTOIklA
GecLHchtnJYwrgyoZAsG0YPaoXEFQlUf/NmCGd/voyCzI5dout4bDe0ya6eHpZPbYqG4D0XXjlip
WRhvuQT8ByNOAE+o51AboMFeITBUDmqMXbzFcWIRodEreKW/SSEum0L4lmTLFvogwPymt0MDRukj
veRLW+mRoYx/3rIjD+BLLo+3pDAddYHA3poaSfwNdIF3SOELCv9QgS5XTeUvnC6U/6CrrV/hX++T
jz89Q6sd4GrEF6dAMUG0HXBlFv3AjvAyGvQGIDUjPFwLH7kc87JIOLKSG4eJXikW22+HQxzCOUq+
RusB6LkR+yOoWdiH34nlR3gGFrUCKoA4+m6DGqQ7hYOYGLE7E1hBMSew5myodCl+1L0dFOtrSBY1
shDF6uN4pjKGMfGGZ+hixIfu18Rv0pbUdbP2KdDSGN7F/ytX6cKxtciHeEx5VJpheBWD6vQxvtyW
E6CDN6wPX/W/Jn/7mWdxckBbOUYoj7M4LQsp8BFicfvvOaHz2/TFJcFZbYudIb9wdUlwUFvQNc31
SiNlTvBDs5ebMMxwL1a6pmO0mTA/YIbXqDJ9w8cgYT5vUYSNtg5/hPt2v9JEoEEO1TMGwe8wmgQR
jcQYLZgObqksxk047JTHZjuTvVQqv5bkTmEkGImJ+aTPn3m1MbIakQn4ykWexdhPPANBMPsi6EA1
P8eosbFw6Kvbp7+hCGZfoaLA+uIj7yTvvaaQg9nrxekVWo4UKyy0IQUtDAqEiPEfaTRxchqorTpf
iPyTS4w5g/k0WPlxzBUwHE3CE94JhT1bBFjAuGN5+BdGDMNMjVzaH2EBsqWR9PwrBqLzQg1TjXmF
EHWYBmYYJr4tHhmdX8WAOYT9a7ci4rTHAS0WV9uwL2ZkxMdX52vOYE/9bL3bqZfz6SyBP1Pkw+jd
8ot8T6NQJfJGXUTxxmPvIYg0Q7L24kjzNohrwrqUSWSxFxTEP0bPVyJxC8PrFnQ7fQxjywNe7SJC
C50LTXblsh/pmnJEZhWe9BTOwj7eMmKsYIcYaBKXbKfSZPGyw6SesxpwXaJhqEob1FDcWZAwYPsF
iSkOZsQPJ86CVrmRqtyq45Bm6j+GbnJGMIWYZi3yNZNn/tvfiGjU3jvIGLtqWlPxdgyrzMgZkh6F
b6o4ya0Ynz0jCmfGJg8U/izmFepu2nVf5xTm9CvbNgmxIcWpF/Y1nrcVewDHHn3rbaEo4+peGacM
QCfcsjv1wzeX2DNQY8TqnubPGEppcSjhAKZP/cNXHE+1rqFblkaRJ7g6zDRh2vbzpY4puhjvSWd6
MS6CMc9A4XoxdQkJdy972IAQBOSvU/qyl1uefUvYltzrUp2UdQy8OH7+14GXKR75Cxk8Y0CoH1Op
prs9kKmpRAKZqve4XVqg5HL1GfoO991h4P10pKm+iSsuRgul8Nuw79bbDG0dVCAM8GkHonFCPCEZ
YSLiyKHl3j9y7JOPtgycaiEWO5Tlga9fROagGnTLSIhD5dkj4F19YWr/DErIcMu/wxC0kUhs6hMn
ciXbgbgbNntV8O5E7KfeHYi7gni2HqIDgbP18ILhz56LrkLBjjM/fHPrxhn7DPvPyD8lZr0f/8t2
ArhbohngDf6/qcQK/+l90sr+/4dO/vnvdwJYhhx4g/0/n86s7P/vkWbgfybTmxuJ1f3f33/yz//l
r/4v2/+TU/if2fwK/+N90sr+v7L/r+z/K/v/yv6/sv8v2/7/Lch277fce+32Pqu9NMtqvzLaTxnt
A63XtrWaWantc8Y5huk3mqYXME5PmacDrNNeY+ci9udXWaC/ywY9ZYWeNkIvZIMOtkLPskN7LdHv
aoUOtkO7XGS2aHjlmIy977nVGDME24FZ+uaP8vqC4Vc44F6W+Vc8955t3HmLLZiqKtiDPQZg+2WQ
EdgtNsgQLJqSXjLzigZQl8mubdfzCtMbbb0iE30WX+Kmv8ZThl+Y6uvYjoAaew23YjsWMOBOVe67
TLlOe6aeLGDa9fQAs1C+pqIvmn39dJZr/fU2dLYV2E6vsQZ7OPM9VmF/NRe3DwtfvsJS7KYFbcZ2
mjWAFrYhiyx72ZYsdMsyrcpu+g778myWLMnc7DR9vtlZ5Oirzc9ueoshWqjjHJO0m2Ybp2cz8+3G
6iCKweZr5+1SzNgOT77DnD239YuZtf3NFwQAajezTdUszTJYcwqBZmuWgo3XdnvmmLBZ8hiyqeJ+
F4G3GrT/mU3aq/SKNG3/h432kstIvDr+ZzaVXdn/3yet7P9/6DTb/r88OfDi/A+6/7+y/79LmmH/
z2XTidTq/v/vP/nnPx6zL7uMl+Z/Ytr+n0xmVvE/3yMF9X/slhtallTGG/w/c6lV/Pf3SSv97w+d
gua/qwMuRw682v8zlUhnV/Hf3yXN0P82Usl8eoX/+vtPQfN/uav/i/M/n87747/kMunEav1/j8T9
P8mXrqtoQ3TrbOsGGVUEp1Cyn9suXeg2NXaeoicT8//UB9rE9UDEo2MMoOn6xTlOcevoYcfMcUhP
tSSTLvNGTRX9JlXylbMmlq5rPXhZ93nF1NclU+0MZGtkKNKapDwOVWMSQd8zpIaucdznirutoVXM
dqKq7ZerEo75P5uuk5vYMI/nGzoMkIMl+r4xN6Ew9//syhb5VrAgKcyLDxmAdDBHuRV3vePiaEK/
MDTmNQmNJ2c5251u2pfO9l405T7z7SShKbU1fSw5JUtxyQshix6E9KnjhUdEsC28SzmtpmKakqa2
FZT8wG9LGqDfoePlibllaSir2HCsV8TmkBOvZBJtG4qyRW+3msZkaOnQFdxJDP7qaDifJCii2SW+
xKSKbqC3Cjl08bqYakNDD1g7TAwQ6SnKkPmt8kA4MDa0NvrbWtCDzK9Q8HkDfkF/7/fl5rpkQLv1
/vYEvX09bmmsfl7HNLllW+jWYQSB6DNfcnfr6n2lpRreLPpiHnHxuFQZQVub7mQYKw2pUClDgyes
e+zwQLIFP/vRfLuZbDsjoamp6IVFEwS+QIK2B6nZVYdD9DUb2HNvnTxokZtKv4HxW8sDDXmHVk2L
1Y6PgpgyeIjAmER6FBsJzXSaRn6PUgtHA8xxE7gPxZpNeYBzo6UrbGa0NbkjAYG1gWKNdaNne6vt
ls9L24Vq6faqtH0LTbw9LF2jg16h/CRXJ8XTSaNWyRibB6nG1Rf14OHLdeL4bHv3Qb7e0W/VqwvG
LneY41xhxl42LshxlQXqpWnkyoL+CN2OdBzKqmXX5rh8UrutFk8rJawDUryVW/AhFvMLerOTlGCR
gaF3cSbjkKwHzfM68461vW/RY5ecziulk+JR4ep2//S4ZDsxc89poMnqWjwqSxaOVooqzDMNZQO6
FZ2kcF4RsbrjpV6PxBDOoKFIDR3tx+jz5XFjh+rAXOBeZ447XZBfksevDvqxRdGYENPnq8eNDnoT
ngmDI+Zpm4vOQeNG8AhzSMaGI7NLrz/OfEvuU5AFvaWceEW2JxEzswZ+wmcgc7Oa+hAnUZg1AztS
bwtEIj7cB3fGM8ot9EwNBXU5kI/47K5kR8Z+FerLn7olfhVaoIF8htEblZK/CW6CTof5XKqw8p8C
e9HbjUPBF21e/d1O+1loNn4dEdlidQ1YXdDBjAz04bqrGm5JNBH5iKapD+txC31oP3xDQq5VWBxm
5P9H/qAwzE0lLApdKh+qPLLa0Y2gLuxhB34NsaUUHU/d9RF/8QU19Ju/Z3+GYr/2fvP22cJt405V
0Kyer012B7c72IXMZc3pwaFuWuRUMDI0r6ut4503dFx6aE1kOd2qM7ezLe7A5lrsue8rYuyEitwV
t8Yj0k254jIweJYYKlWQN673Xjv3WgMtQvQ5GsbwSVgcO/RU780dMtxdANr2LEV/hb/oI+Zd/IzO
GUg1ZmIUu3CCfE8iwWwOU4U+i6MHn6CzLfmLPpPsPkbxH6hAoQZkuxt3SZHzaXyC4PT1pcfbEbrb
25MWykzuq+L6vnl4OSC97pOojoSTuUjM0vl3oa7yGPJ84i5hnwSNJhwyu3Iqm4Pxjj6xQvucHoiN
hihiwvUP3+ws5dbzFjDaxP9SVfAPdxEEfrtft1RQ96yACtHCao8HZ3RjEXziiWOXlboluTVwhyEq
EtD//SFsDMx14ROomPvTab/wCFf5LWH19g5bGpJYF3ROi8wckSFxolOj2KggvRYHguu+zny7OUV7
hF3acQvl6V2Md5ApktcpG3QDI0bOa2PcGEBm2uoM6G5anPYskIvfEfJtcIDqndIkRSEyZ6R6HRr5
VQPvcIW6y9P9WLejVvp2WrGOrnc0RR6qJkWyfEjGfTX7DLrnpw/fgjS85zp6UvFa+MQLOmFiVWLI
FfNz7GviN6EbR59jmt6UtfK8jpxmkdCPQNXXkY7nJqcMSn5fVjV8Qn+gD9cqDuEqrdIq/ZHT/wf6
ieQCAKANAA==
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
__VERSION__ = "1.35.0"

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

_GUEST_WS_FILES = {
    "IDENTITY.md": _GUEST_IDENTITY_MD,
    "SOUL.md": _GUEST_SOUL_MD,
    "USER.md": _GUEST_USER_MD,
    "AGENTS.md": _GUEST_AGENTS_MD,
}


def _ensure_guest_workspace_files() -> None:
    """Materialize the neutral guest workspace (write if absent or changed)."""
    try:
        _GUEST_WS_DIR.mkdir(parents=True, exist_ok=True)
        for name, content in _GUEST_WS_FILES.items():
            p = _GUEST_WS_DIR / name
            if (not p.exists()) or p.read_text(encoding="utf-8") != content:
                p.write_text(content, encoding="utf-8")
                _log(f"guest workspace: wrote {name}")
    except Exception as e:  # noqa: BLE001
        _log(f"guest workspace materialize failed: {e}")


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

    try:
        entry = _build_mcp_remote_entry(fields, secrets)
    except ValueError as e:
        return {"status": "error", "result": {"error": str(e)}}

    try:
        cfg = read_openclaw_json() or {}
        mcp = cfg.get("mcp")
        if not isinstance(mcp, dict):
            mcp = {}
            cfg["mcp"] = mcp
        servers = mcp.get("servers")
        if not isinstance(servers, dict):
            servers = {}
            mcp["servers"] = servers
        servers[server_id] = entry
        _write_openclaw_json(cfg)

        # Mirror WITHOUT secrets: drop headers before persisting config.
        safe_config = {k: v for k, v in entry.items() if k != "headers"}
        _firestore_upsert_mcp_server(
            token,
            server_id,
            {
                "catalogId": server_id,
                "enabled": True,
                "status": "enabled",
                "config": json.dumps(safe_config),
                "error": None,
            },
        )
    except Exception as e:  # noqa: BLE001
        _log(f"mcp_install {server_id} failed: {e}")
        try:
            _firestore_upsert_mcp_server(
                token, server_id, {"status": "error", "error": str(e)[:500]}
            )
        except Exception:  # noqa: BLE001
            pass
        return {"status": "error", "result": {"error": str(e)[:500]}}

    # Goes live on the next restart_gateway_for_mcp (the client coalesces a
    # batch of toggles into one restart on screen close). Connect health /
    # toolCount reconciliation is F4 (telemetry via `openclaw mcp list`).
    return {"status": "done", "result": {"serverId": server_id, "transport": transport}}


def handle_mcp_remove(token: dict, params: dict) -> dict:
    server_id = (params.get("serverId") or params.get("catalogId") or "").strip()
    if not server_id:
        return {"status": "error", "result": {"error": "missing_serverId"}}
    try:
        cfg = read_openclaw_json() or {}
        mcp = cfg.get("mcp")
        servers = mcp.get("servers") if isinstance(mcp, dict) else None
        removed = isinstance(servers, dict) and server_id in servers
        if removed:
            del servers[server_id]
            _write_openclaw_json(cfg)
        # Keep `config` (omit from the mask) so re-enabling only needs the
        # secret again; flip enabled/status and clear any prior error.
        _firestore_upsert_mcp_server(
            token,
            server_id,
            {"enabled": False, "status": "disabled", "error": None},
        )
    except Exception as e:  # noqa: BLE001
        _log(f"mcp_remove {server_id} failed: {e}")
        return {"status": "error", "result": {"error": str(e)[:500]}}
    return {"status": "done", "result": {"serverId": server_id, "removed": removed}}


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
