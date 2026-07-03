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

TNODE_SETUP_VERSION="1.65.0"
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
KaTe5MREgsAr/Ic2EwtwaPt4t3512GomlYtTud7pfru47CXv1ofD0XlpUu2s6qNzOdGc6OPE9n2+
frM/Kaysti5Wyo9nJ4+9/MHj9f31eb5c0c87zTMjo5RvEqff7n/UPQqLDcuxUo8NhjPdD5n42htO
FdtE8XJu/meMKC0APDhQyxfKemO4e2fcZXpH2ztX1ytK9uio3L3KVC6rK7lRqXw3Km50lbvdi8lg
tL57WmytZ/ebp1dm92D98ei8vL/2cL3bWzl4MNavu6eTfPI1asTpoXffMSfCyuyn0F3HQiZ8vl7k
zq3CHHxTFw8T6/BuhYdJTG4rPNAu57cd3Y1nBIFgKEfPxZdJC1has/dLQk+HTKOBHse3OBul1CKR
B1gYu3UM2qlrk5aqzUImynjweF8zxPwF8OHmfxyjEhYISkjvXx0W1FHv5rpaKettZePIbO8Ubgxr
NZfaVruNq11QYAupbkfT6lWlqO3e36SL66Pieimh7cvrV7tX9XruVOutJ77tX1/myvt7Nzc/Kh58
0bkd7D/ybbjW3nCnoI84573oZGSEX+Z71rwYq7mbyYlR7q4eHLavD7uNdD6xkzzcOTrrb3da9ZV0
oanl1G5WOd1f2y+utLpZvVVOm/lVZVcebx9sywfZy75l5a7GqweNkilPskvbrUKr1KYWw2siGc9m
qZWZN8UtTZNnnPQ9JDiGBbxD6f18P/O4nj9fM+4O1iu9dd04LyQ7iXpDSxTvD3PW+Wlz9yZbThXu
mjsrJfnosHf9sL03+TY8OFzPbijDxulOZ7StPxyZLa11Ul/vggr6msC3SjGWto/Jz2FqR7bG7Rjb
XgWbvd6ibbpkkYnOj0Xv0jPl0mquPxw8dNdGmb3rzOrK3eP2+FpOGgeVSfLb+fp+5eHmdNw+NHIT
M1nefuzsjtR8KlG92N0/7FUu7831QX0j3x+VC99Kw5O9w4Fx/QPQ0HlsBV5W6sM5Dxyrfp/CvF5R
G7MUgbedziGK1Bd4I/2C53K2D8uZqpaqXmVOR1ouqWUm95nrtay6Io8H42/35u729VW3e39k9evf
2sZRcWVylzM6V8nusFR8eNyXr7/t3pWuVvW2PDg4PirB/+7U+ltv4ZjdDaqpPIhOn5dXYIousJlM
lknhyavX4YVWAOI7+zWnY98gtgTCTv+yn9TNC4gqdbt5s5o7L476J+cb+d3tztFherRz08p11ke9
7buOLt/cnxT3QQHcu7QOusXewXBPVjONh9XT9uWR8W31ung8SOfyeuu6nh83rEplZdRZGnLM2JDn
Hj3IvU1A2VSRZ/bfsdxi4un6crd8l+7KvcNK9WG8dmze3OnbD63K2OwnJ42mYvYa2cHKWTrVWH08
Hd6kBtrKcevhsvlwajX3Rr3jy5OztW+V691s/sKaWIkdNVdMrS0fSZGaZFoTTZmhvfoO9GCO1HQO
3wmTN8QjvxE+WzDyNTqy1nU76lXudPxqMHvH+iZpSiT50BlMFt3Xa9nKIFE8NxXd2BgfrpVGl+mV
6vCsv5ZpHnVP724S5mDjW7fdqZbqlxsH2mkl9XBh3mSGuUT57CQ7frAaO9vZentwdnreOM+cFUbK
4+lrfJovTLRZ+tT628x0Y1KgzNj6gia5S3OQXq/niucNtbdzNjLuh+krpZt5TKnXD8XC1f3e9fb6
mdnvJirZ85ZcOHs83T2dbB8PL+/2LzON5tqFemBdWIM18/gol2tfjR4bhT3v4be3GqmTwcN+fuQZ
O/mHBiBn8vmuk27F1mMjWVOb/DrpP7ZWgxFFXw5O8xS2WGzavKosK7ptklqf5V3Cpr5+r4MEYVTh
P6RLLrCpSQ5aO49KWyle7e/tl/O96uH5abo43gO1e9XM3ekb1vDRap495Dvl40JzVFnJ9HfLx/en
zWQyP+jc758nkoed/PFFZS2xkqsU6hvr1yettyoxy7j4yz0gsjx9ndNE1rK/FtXUr9uji2prfD9p
5C6+gTKwvVIp98zL60qvWln/lrAqhtU8vjkq945W+rmVs6qhnn+bfFN7yd62Uf12rNw/Xu4kD652
23unijq5VHd2jOPiKzT1Ged7lnFCZiL3Zm2K0vGNNzG5pxGHe1qMKCywi8yPOsffMr36+mNz7WaS
Kx9XrcpAS+2kVveu1q7693dJ07jSugeHjcG1lmgflY/21clw9z59oJTT1zsPF6d3TW17JXPYSCVN
5ejQOsw23jp4p9RoziF8Ee+9yYKVjb8/4M5xACpKT9HUhXrWaM904LLbQ17ft0CSOhf+jTEiC5z3
vrHuHnqJ/US2WnkYHmZ2jq/vCr3DrrVd7ZfHCeOyd1ApTw6U6/zNoLe/nVbbG5fysFBYfTDl9fTu
8cHlQTF/PzjpZw4uH4+t5GPPuEgu/9RyQ1OHdpy2bxXDG780md+hkvHgGUgMNhSRRxH6TdXcPZoH
ODTo3nd2wUvqBWU17d1089WGHZvzFMF6Rbj2Ls2gF16tyaYXHV1uYYHy423IDyJlZ6yxn7H0grAP
1uXA3L/KFZt3SiOv7gzq5e2Ukrl/KJ+ZpbVj/bSxmlCqTaNeLxeyneThpXnV6etypr3SS+81tO3y
8G7v0Xy4yV7uX+ZXdi+GjXTicPuV1y4tld2P+qzbKLyXPS7KZKAHvIX/xuj7BaBlrNLxzl15f0dL
X4yv21pTSd81OlfpvXEvu7u/c1hUK9+umlVj/2y7fLyx05gMcv1ssfOwX1KvjvP7R5epxPb9Vesq
0e22c6mLYmNvf1J9627wrbKzoWtqvyM3uouETiBzLD12Z+r9mNnoKL1ZhxcyeNri9durafq8R7wP
Y4z8Aq6sxGm71R9UUw8HlaJydl0ptM7Lq7uTTOe0tZHqHVwWh9eHF3s3+0dqcWdgjU6zqaNK/0pv
9dab/UIvmV5duzlu3ZSPcsXK47BylN/p3+29dRWdv2tgoxlFKTZtna6j8t/D/gn/9/zpv32kXzpZ
ZJO0ENCYcGJP5Yc9RUYwmwHMU7mtxHEuvK+MZDK5ls1K+G9ubZX+hWT/m0ymU0kptZpOp1bXkslU
Wkqmk7lk+r9JD8tp4vw0NC3ZgKpYel3W5uQbdxRl3ntvo6Ql1/KHpUxS6llqT9lK5dYzyfRGLgf7
3exadn1tPbP6aTUnHZa38+eFvfJlKf4gW5aBEj0uDwaaEh8Y+kjpy/2GspU/K+d31W5jPFzJH+jd
T9kNqQIfHV7P++h/+V//2/8W+d//n//v337/vz7kzD8o+ef/8ma9m16Y/+lMzjf/U2u5LMz/5LIq
MC/9F5//qBWE+nKPVIi/WXVDVvvsQIgmj2O+0UH6RXD0tnPqhHuf6NnAUEfM1mcrLaDDsLMJnED1
GAqQTmWrI21LTjnSf/7b/5Bkqak0VYxoa0pXFQlUGQKpkqyObEny0Oog4Ae+NuGRIoF0kYawR4lK
ah/viDAlRW50JGto9OGJpVOmE2hYARomsT1BVJL7TYkHkEiyidj+MhTRVDRLNqU6zAWpoRuGolEt
6hPJGPbLzThrnaEMdFPle0mmXYlH7rkyZuvF8GQlyOfQ0w0Z1N0pztPv2EAbQkXNuEDPs4Pl09VM
+HvqE9eqRQ3x4viwXCgdV0pF1gDWE65uGHKOQVtmQ4oNJPhH77fUNkkDu3xsImjGje6sjFIs1tdL
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
# 1.41.0 — Cron declarativo del resurtido (P3 supplier_restock): la CF
#          syncInventoryFlowOnWrite compone inventoryCronJson/inventoryCronHash
#          en el node doc al tocar config/inventoryFlow; _sync_inventory_cron
#          (dentro del pase declarativo, hash-gated con stamp local
#          .tnode-inventory-cron-hash) materializa el job "tnode-inventario"
#          vía CLI del core: rm de los jobs con ese nombre + add fresco si
#          enabled (agent main, sesión isolated, sin --announce — la entrega
#          es la ApprovalCard). Motor 100% agente; el daemon solo declara.
__VERSION__ = "1.41.0"

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


def _find_cron_job_ids(name: str) -> list:
    """Ids de los cron jobs del gateway con ese nombre (incluye disabled)."""
    res = _run_openclaw(
        "cron", "list", "--all", "--json", timeout=30, stdout_limit=0
    )
    if not res.get("ok"):
        raise RuntimeError(
            f"cron list failed: {res.get('stderr') or res.get('error')}"
        )
    try:
        jobs = (json.loads(res.get("stdout") or "{}").get("jobs")) or []
    except ValueError as e:
        raise RuntimeError(f"cron list unparseable: {e}")
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
            res = _run_openclaw("cron", "rm", jid, timeout=30)
            if not res.get("ok"):
                raise RuntimeError(
                    f"cron rm {jid}: {res.get('stderr') or res.get('error')}"
                )
        if doc.get("enabled") is True and doc.get("message"):
            every = int(doc.get("everyMinutes") or 15)
            res = _run_openclaw(
                "cron", "add",
                "--name", name,
                "--every", f"{every}m",
                "--agent", str(doc.get("agent") or "main"),
                "--session", str(doc.get("session") or "isolated"),
                "--thinking", str(doc.get("thinking") or "low"),
                "--timeout-seconds", str(int(doc.get("timeoutSeconds") or 480)),
                "--message", str(doc.get("message")),
                # Entrega explícita al canal del app: "last" truena en nodos
                # multi-canal ("Channel is required…", visto en P2 con
                # telegram+tnode) y best-effort evita que un fallo de entrega
                # marque el job en error (la ApprovalCard va por server-write,
                # no depende de esto; esto solo acarrea reportes del agente).
                "--channel", "tnode",
                "--best-effort-deliver",
                "--json",
                timeout=60,
            )
            if not res.get("ok"):
                raise RuntimeError(
                    f"cron add: {res.get('stderr') or res.get('error')}"
                )
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
__VERSION__ = "1.27.0"

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
