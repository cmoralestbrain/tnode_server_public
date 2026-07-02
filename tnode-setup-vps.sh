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

TNODE_SETUP_VERSION="1.61.0"
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
BAKE_MODE=0           # --bake-mode: install baseline only, skip identity (used by tnode-bake.sh)
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

# Mask the apt auto-upgrade timers (Linux). On a freshly-provisioned droplet
# unattended-upgrades fires within minutes of first boot, upgrades packages
# (incl. systemd → `systemctl daemon-reexec`) and restarts a swath of services
# — systemd-resolved (DNS blips), the tnode daemons, and the gateway — right in
# the pairing window. For a managed appliance we control updates via golden-image
# re-bakes, not per-node auto-upgrades, so mask the triggers. No-op off Linux /
# without systemd+apt. Idempotent.
disable_apt_auto_upgrades() {
    [[ "$OS" != "Linux" ]] && return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    command -v apt-get >/dev/null 2>&1 || return 0
    local units="apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service unattended-upgrades.service"
    systemctl disable --now $units 2>/dev/null || true
    systemctl mask $units 2>/dev/null || true
    success "apt auto-upgrades deshabilitados (updates vía golden re-bake)"
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
            --bake-mode)     BAKE_MODE=1 ;;
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
  --bake-mode         Install baseline (openclaw, daemons, verify scripts)
                      WITHOUT creating identity state (tunnel, tokens).
                      Writes ~/.openclaw/.baked and exits. Used by
                      tnode-bake.sh to produce DO snapshots.
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

    # Quiet apt auto-upgrades so they don't reexec systemd + churn daemons
    # right when the user is pairing the fresh node (see fn comment).
    disable_apt_auto_upgrades

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
ToiBHtt6g78x6uUDOf9G+/Naiy9T78VD5LyJ1wdelX0zl+fbkhD9IXUmeYHR+eCi2faAjhPk9QQf
mfRw0qlEXYi7BcSMayfUzNSfzUioketVHezwEWSOcbmKEgSaItsxJoEqtVFyb+c4WoTwoisB7tpa
sexpSfNt2cp/r7B6S6+83zrwjvaJc++uXDTKHlYCB83Xo3TdjQKE8sY2OB8pkxHc8PFiPJlsQZde
JguR2s9wr2yWwzG/CKDR3MTne/E4MmcsALRRRk9Yl9b9SikhlJI3JPZtQf+Xj3rKM3aikJgnpFu/
Mo7dwt+D7Py4nWfWfnz3gtQebIaCIGCnPAFAge6iEbJTVf+4JDBQ15Qq82dTtII0N28PEL2qW18I
DmNUQDBn0nnadokt0phbrwKUl6VtQq/QWWY1k++r8/P6A79i7v2d+zfq71j6wsgeXd7dkXxRiVMW
93KSVrbOZi0YBR5luoQlAqsqwHA3NXYhYpChv2b9o5tEBYyMMYs6TR0tikLk0YaW2BreAOa8Ksmw
2/6Ah+7nwH2unPP1WPuqAPOtweNBgZyIPsvhHHjXMyF5oQTOkCpmJySGACMR+4aEFZjmay2CjY0h
FvaBkGMLHG30IrXtzYbzqGoYuCCxZ1rjQK1324l+kFLNW60CIl22AL74sgzYj/u+npjgO13/HAc3
1bheitzvzT0d3fS27ZHn/yLI1/kUP45xfcTL8i3pZ9D8ujCA+nlcDhmEiQA52Eh2wufRFt0G0hzy
uzzN8lRj66GtKdnUL1aIC88qVUdmoG1O47HlHlEYENoCmPJm5LpEmYaZxLBrX4OQ709y+NFYeEd/
tc9lNI0oNW722Ef2W17Intn/66Tvnsuwo9YZjWwF7sj7MJ0fhjmzT1aGvmqHmsMsiJXPtmts5YSz
VSd2EbJ1W0AH63ibJvEiDzwBoxPHEA7WjkirXU6iZbr+V/fawI/jrtGLS7XG3l33mtvk08Ze0p/c
aOKz7toTZWfQDM7+uu3ZjnPT/tLYxhmLth6XgyyNOsePol94vDfe9ZzK+rlQyz8uqaz7ANqP7E+L
mz2WNvUX2TOen48HSM98qU2DC15hQ9MpEMTjw3InxzvKmAq1Nh3WO0xHgXQzWTNiQDYA4KL2YQSj
IlHt1kdoJ++M2l7jsrp2YmJs6Yo/nc8T0vC+f8n4v6o0tJNLQJKfOJH+qxrfO2PNiTenJ9HndSX6
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
__VERSION__ = "1.38.0"

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
        expected = _GUEST_SOUL_MD.rstrip() + "\n\n" + zone + "\n"
        _GUEST_WS_DIR.mkdir(parents=True, exist_ok=True)
        p = _GUEST_WS_DIR / "SOUL.md"
        if (not p.exists()) or p.read_text(encoding="utf-8") != expected:
            p.write_text(expected, encoding="utf-8")
            _log(
                "guest workspace: business section "
                f"{'set' if block else 'cleared'} in SOUL.md"
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

# Recover an openclaw-gateway daemon that exited 78/CONFIG at boot because
# `openclaw.json` was missing — typical in droplets booted from the bake
# snapshot (cleanup-pre-snapshot.sh wipes openclaw.json before the snap so
# each droplet gets a fresh identity). Sequence in the wild:
#   1. droplet boots; tnode user lingers → systemd --user starts
#      openclaw-gateway.service automatically.
#   2. gateway can't find openclaw.json → exits 78/CONFIG.
#   3. systemd marks the unit failed.
#   4. phase_tunnel runs later, writes openclaw.json with the right token.
#   5. But nothing restarts the failed daemon → tunnel CF accepts WS
#      handshake but upstream is dead → clients see "no se puede conectar".
# This function detects (failed daemon + openclaw.json present + token
# present), resets the failure and starts the daemon. Linux-only, idempotent.
recover_failed_openclaw_gateway() {
    [[ "$OS" == "Darwin" ]] && return 0
    command_exists systemctl || return 0
    local tnode_uid
    tnode_uid="$(id -u "$TNODE_USER" 2>/dev/null || echo "")"
    [[ -z "$tnode_uid" ]] && return 0

    _gw_systemctl_recover() {
        if [[ "$(id -u)" == "0" ]]; then
            sudo -u "$TNODE_USER" env "XDG_RUNTIME_DIR=/run/user/$tnode_uid" systemctl --user "$@"
        else
            systemctl --user "$@"
        fi
    }

    local unit_state
    unit_state="$(_gw_systemctl_recover is-failed openclaw-gateway 2>/dev/null || true)"
    [[ "$unit_state" != "failed" ]] && return 0

    local oc_json="$OPENCLAW_HOME/openclaw.json"
    if [[ ! -s "$oc_json" ]]; then
        warn "openclaw-gateway en estado failed pero $oc_json no existe — no recupero"
        return 0
    fi
    if ! python3 -c "import json,sys;c=json.load(open('$oc_json'));sys.exit(0 if c.get('gateway',{}).get('auth',{}).get('token') else 1)" 2>/dev/null; then
        warn "openclaw-gateway failed pero gateway.auth.token no está en $oc_json — no recupero"
        return 0
    fi

    info "openclaw-gateway en estado failed con openclaw.json válido — reset-failed + start"
    _gw_systemctl_recover reset-failed openclaw-gateway 2>/dev/null || true
    _gw_systemctl_recover start openclaw-gateway 2>/dev/null || true
    sleep 2
    unit_state="$(_gw_systemctl_recover is-active openclaw-gateway 2>/dev/null || true)"
    if [[ "$unit_state" == "active" ]]; then
        success "openclaw-gateway recuperado (active running)"
    else
        warn "openclaw-gateway sigue $unit_state tras reset-failed + start — investigar"
    fi
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

    # Fast-path detection for cloud-provisioned droplets booted from a baked
    # snapshot. `~/.openclaw/.baked` marker present + TNODE_AUTO_PAIR=1 set
    # by cloud-init = the baseline (openclaw, daemons, verify scripts) is
    # already on disk, skip the heavy phases and only run identity setup.
    BAKED_FAST_PATH=0
    if [[ -f "/home/tnode/.openclaw/.baked" ]] && [[ "${TNODE_AUTO_PAIR:-}" == "1" ]]; then
        info "[fast-path] detected /home/tnode/.openclaw/.baked + TNODE_AUTO_PAIR=1"
        BAKED_FAST_PATH=1
    fi

    phase_validate
    if [[ "$UPDATE_ONLY" == "0" ]]; then
        # Full install path
        if [[ "$BAKED_FAST_PATH" == "0" ]]; then
            phase_ollama
            phase_openclaw
        else
            info "[fast-path] skip phase_ollama + phase_openclaw (baseline pre-installed in snapshot)"
        fi
        if [[ "$BAKE_MODE" == "1" ]]; then
            info "[bake-mode] skip phase_tunnel + phase_tailscale (identity-less bake)"
        else
            phase_tunnel
            phase_tailscale
            # Path B: phase_tunnel just regenerated openclaw.json (snapshot ships
            # none — cleanup-pre-snapshot deletes it); re-enable the plugins now.
            enable_pathb_plugins
        fi
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
    # Recover daemon stuck failed because it auto-started at boot before
    # phase_tunnel wrote openclaw.json. Fast-path-from-snapshot scenario.
    # No-op when the daemon is active or there's no valid config.
    recover_failed_openclaw_gateway

    # Belt-and-suspenders: detect a gateway daemon running stale binary
    # (e.g. `openclaw update` ran outside the installer) and reload it.
    # In a fresh install or after --component=openclaw-gateway this is a
    # no-op; the cost is one stat + one systemctl show per run.
    ensure_openclaw_gateway_fresh
    phase_components_manifest
    [[ "$NO_SMOKE_TEST" == "0" && "$UPDATE_ONLY" == "1" ]] && run_smoke_test_all

    # Bake mode: write marker and exit before phase_summary's user-facing
    # banner runs. The marker is consumed by cleanup-pre-snapshot.sh (which
    # erases identity state) and later by main() itself on subsequent boots
    # to enter the fast-path.
    if [[ "$BAKE_MODE" == "1" ]]; then
        write_bake_marker
        info "[bake-mode] complete — run cleanup-pre-snapshot.sh next, then DO snapshot."
        exit 0
    fi

    phase_summary
}

# write_bake_marker — emit ~/.openclaw/.baked with tag + daemon SHA so the
# fast-path detection in main() can match it against the current installer
# tag. Called only in --bake-mode.
write_bake_marker() {
    local marker="${OPENCLAW_HOME}/.baked"
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local sha
    sha=$(cat "${OPENCLAW_HOME}"/scripts/*.py "${OPENCLAW_HOME}"/verify/*.py 2>/dev/null \
        | sha256sum | awk '{print $1}')
    run_as_tnode bash -c "cat > '${marker}'" <<EOF
{
  "tag": "v${TNODE_SETUP_VERSION}",
  "bakedAt": "${ts}",
  "daemonSha256": "${sha}"
}
EOF
    info "wrote bake marker: ${marker}"
}

main "$@"
