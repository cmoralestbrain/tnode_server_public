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

TNODE_SETUP_VERSION="1.62.0"
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
N8r6uBVzv6nD7fWwmrDtvUV8OfUCa3PE5mdfZ1AzFBdbmZy+0i0mjoyVsn2l78/VjdztRTuzXS3o
C73OlnJyUGgcGrvtu3Rif7Pc3t6vLZ5d1G52D5v76cJqf+V872h3N7fdyPTultYTla6++6pmeHFc
pDTh5dgm0t4IHCRfZmCZUmvX+3f5bElZOFwvL105m+ZZZ2Ghkti8Lpczdqc3Z+xUKsl84+g8MVdZ
uG2X9m+U85WTTaXUPsveVfZ61ZNcM61bjq6cbJ+WzL3BlvOrEcJmZplGXHRkn/ui4x8CvxPhpYcn
beS9Z/Yx956Bdgj2B97EeRuTsb7TW0xu3jXXT7NHxtmp03ByS+la62J/d0nLHbTU6om9U6wZym62
vlI6uOgp6UYpt3ZW2LDzufX8US1vZwbrg7NEbnE9aVzsWseDuZN253lvOl8FhSfA4gAD9nLkWmx4
BN0Wi8xAwJvpFbNUXE3dJFPXlYOVgbaQmzvZOenVT1fvdq+3N2tWPn+j3XZuNpLmdT/tJI8XiuZB
by5XXuwlVlPn6VMld7i97Ri5s4Kzencwt93o9F5R+VeFymMMBUajsGA6MDMKj2qQoO6oT3He6mSU
dW4OtnrJ+l12bj/ZOl1vp5TcuXpd270YHLRW1+zE3UY+c2Iaea2mnFQWjOTWTa+9mCNLkrk6stbn
bszj+kGrsLNvVM2jnUrbOD2s6Oe/+LXyPypyjbQlGY1aqUeoU8KbI4gV/iHOW5xClbLRuV48Ny+0
zEC9PbhZVNacVG8vtXlbSN/tbPfszaOF9c7p+UA/S/TU3PVh+zzfv93YK68NEqsZJ610di9SOYsc
8UUzW986ra0ONq8zz6/9++2jlWhqNBqpMo+4hw1rzI9S7us4b20KLtFOWd32cWpnUC2vbSinS/XK
avO6Vdzd2jlR1HrpPL94vV2+O15dPZ+rklMpm2jmFE05Py8kj5dOT5LmTra4VdyyTk7X50oXiRsr
a1r5X8vR+ovdvz6N5ctjEVpKTe9wNooZGYHLfvZkZlz2N0Ow2P8izluYgjXcX8pcHNib6eqtunax
mk03Uombq9V+bq1wcb13Uds+2l/K7mxqlWSmcbffrm0tqQmna9xenVwVUkd6bqmot0+27u4WNzLr
S8X6ttpIJQ9exOz+l7TnFPEz3u7qjhaH5TLda9SlnJx5Zo3t78qmYdyEj9piviWYeYuNbBFcF0Z9
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
uHb3jKMw5RxL8wXQGARynBWbus2dIzmH3cIsidVKPxL1MEWlGF7xKD8LClmeCzMOqkCnEqabydrd
vF/D4F8zG/HZkDhLTAs1D/xxdAMAD+6r+EYDJ3H/OO67xaJmKxC4pc0KN1HXPBA8ES6D+Z4T0Dod
UWtt5UUNvNhYoL2LucMuPuLyVJ2ejEZWmFipt8SEFiky2AryKnQdGU1lvVzckYh23xaK//uc4Fla
oRWd90cECyvS4tIzzrsL1acbJ44+bTX8DYNebqnYa7fvp2xU7Bv0yzODMhn4RRIPitPPjbRnr/w6
bfLBXokvv0G77vx7+slv7r7aY4/Et+j9vP9rh/hxq8/miD02YHw1szp8CM03mjknY5vB4Eq2x3YF
CUpGKj10Z7t0u3ACKU0aq7GOcEcIC5wv9rP1geKmUMkwI5MkJ+P6qGE+m0nz1d6ZLGOKINcKP+pk
85ilR8g7VrjqPxo0fQfGb+xpddmpcPhyHkXz6++oJV9urn26M7jsp1UWT1B8tfv2hZdxOTjvHPdE
/dXe2UaSX989b+318k6eFMWgSLXmItNft922zp3tuonYj9aRGw8MUi0vXmwI+fy5Nj0h5Poz8Bc7
Kf68Oci10jrZupFXPjHj1XM/d6U6b+/7Yi9UP7nK5b+I11ugPevLFx6ZT7RffUganL7gvDN6eBoW
rKff+eojcq0Z6InZvf2Jz/XLd+3SV7e8sUFX/82h+qojwz5vpn2yIl7/hPN26PCHn/KIxrrRZD+l
9csPuvWarYXFvcru6IWhdtJQmqnpXujdTCSHvj20seMbDZx3hP15NrgQ7rHFY8Xjys7FMtqrjzJt
Ccf6MGyL4eSA57SRI2NsSpbeZjNKAonzyP1UHdHVEFGDjVxMfXi1NqyRZy9QI7VLa42mrDwExTsU
3VvD9kfQxPrm8p8Xbg7yAjS0uNZurcE4r5SAoQdk8JL62US+HAyeCH7M+9YJDzSRofsVvkaZ5ezQ
Kio8VUh2ofgpvO6IuNEcijrEZb4B0Ho+6Q6GkO2VDaYey1nUHJGKr48wt3OnILZwdAmvRPaz0z3O
HeykwQ3rldFrIRb4P37L6P3xzpsLcr6PN45XupX+XHu8WqpzfeCyRKdIT3bbaTQCmTy5/BOEXfxr
ez2yUV7KdqDFZp545vM0lJegeeOdXzNX+r7S9n7hZ/lOJ66sU9d37XvffJ71cddbPzM+er72S3pK
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
__VERSION__ = "1.39.0"

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
