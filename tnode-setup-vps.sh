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

TNODE_SETUP_VERSION="1.75.0"
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

# ── Environment (pre-prod/beta support) ──────────────────────
# One knob: TNODE_PROJECT_ID selects the Firebase project this node talks
# to. Defaults to prod, so existing installs are untouched. Beta nodes get
# it from /etc/tnode/auto-pair.env (cloud VPS) or the shell env (BYO/Pi).
# TNODE_TUNNEL_API points at the per-env tunnel-provisioner Worker
# (prod: api.tbrain.app, beta: api-beta.tbrain.app).
TNODE_PROJECT_ID="${TNODE_PROJECT_ID:-tbrain-platform-7fc1f}"
TNODE_FUNCTIONS_BASE="https://us-central1-${TNODE_PROJECT_ID}.cloudfunctions.net"

# Tunnel provisioning API (cloud-init exports TNODE_TUNNEL_API as
# ".../v1/tunnel"; accept either base or full /provision form)
TNODE_TUNNEL_API="${TNODE_TUNNEL_API:-https://api.tbrain.app/v1/tunnel}"
TUNNEL_API_URL="${TNODE_TUNNEL_API%/provision}/provision"
# Firebase Function that issues short-lived HMAC tokens. The shared HMAC
# secret never leaves Firebase Secret Manager + Worker env; the installer
# only ever sees a per-request signed token (expires in 300s, single-use
# nonce). Same pattern as `setupKey` for OpenRouter.
PROVISION_TOKEN_URL="${TNODE_FUNCTIONS_BASE}/getProvisionToken"
# Firebase Functions for chat-sync (tnode-chat-sync watcher on this node
# mirrors conversations to Firestore so the mobile app never loses a turn
# when it's closed).
REGISTER_NODE_SYNC_URL="${TNODE_FUNCTIONS_BASE}/registerNodeSync"
MINT_NODE_TOKEN_URL="${TNODE_FUNCTIONS_BASE}/mintNodeToken"
# Firebase Function that hands the per-node OR apiKey to the on-node
# daemon when it receives apply_openrouter_key. HMAC-signed with the same
# per-node secret as mintNodeToken. Key is minted/topped-up from the app.
PULL_LLM_CONFIG_URL="${TNODE_FUNCTIONS_BASE}/pullLLMConfig"

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
ZZnyP9GTXrEAGgsA
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
    # openclaw-web-search rides along: baked into extensions/ like the Path B
    # plugins, it loses its plugins.entries to the same pre-snapshot cleanup.
    for pid in tbrain-context-engine tnode tnode-transport tnode-wake openclaw-web-search; do
        if [[ -d "$ext_dir/$pid" ]]; then
            if run_as_tnode openclaw plugins enable "$pid" </dev/null >/dev/null 2>&1; then
                info "Path B: $pid enabled (SDK)"
            else
                warn "Path B: enable de $pid falló"
            fi
        fi
    done
}

# Install the web-search plugin. @ollama/openclaw-web-search ships raw
# TypeScript on npm (main: index.ts, no build script, no compiled output —
# every published version 0.1.0–0.2.2 does), and OpenClaw >= 2026.6 rejects
# package installs whose TS entry has no compiled JS ("expected
# ./dist/index.js…"; TS fallback only applies to source checkouts). Workaround:
# pack the pinned tarball, transpile index.ts with the typescript module
# bundled inside OpenClaw (no new deps), and install from the staged dir.
# Bump WS_VER after verifying the new tarball still has a bare index.ts entry.
install_websearch_plugin() {
    local ws_pkg="@ollama/openclaw-web-search" ws_ver="0.2.2"
    local stage_dir="$OPENCLAW_HOME/.websearch-stage"
    local ts_mod
    ts_mod="$(npm root -g 2>/dev/null)/openclaw/node_modules/typescript"
    if [[ ! -d "$ts_mod" ]]; then
        warn "web-search: typescript embebido de OpenClaw no encontrado en $ts_mod"
        return 1
    fi
    rm -rf "$stage_dir"; mkdir -p "$stage_dir"
    if ! npm pack "$ws_pkg@$ws_ver" --pack-destination "$stage_dir" >/dev/null 2>&1 \
        || ! tar xzf "$stage_dir"/*.tgz -C "$stage_dir" 2>/dev/null; then
        warn "web-search: no se pudo descargar $ws_pkg@$ws_ver de npm"
        rm -rf "$stage_dir"; return 1
    fi
    node -e '
        const ts = require(process.argv[1]), fs = require("fs");
        const pkg = process.argv[2];
        const src = fs.readFileSync(pkg + "/index.ts", "utf8");
        const out = ts.transpileModule(src, { compilerOptions: {
            module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } });
        fs.mkdirSync(pkg + "/dist", { recursive: true });
        fs.writeFileSync(pkg + "/dist/index.js", out.outputText);
    ' "$ts_mod" "$stage_dir/package" 2>/dev/null || true
    if [[ ! -s "$stage_dir/package/dist/index.js" ]]; then
        warn "web-search: transpilación de index.ts falló"
        rm -rf "$stage_dir"; return 1
    fi
    chown -R "$TNODE_USER":"$TNODE_USER" "$stage_dir" 2>/dev/null || true
    if ! run_as_tnode openclaw plugins install "$stage_dir/package" --force </dev/null; then
        warn "web-search: openclaw plugins install falló"
        rm -rf "$stage_dir"; return 1
    fi
    run_as_tnode openclaw plugins enable openclaw-web-search </dev/null >/dev/null 2>&1 || true
    rm -rf "$stage_dir"
    chown "$TNODE_USER":"$TNODE_USER" "$OPENCLAW_HOME/openclaw.json" 2>/dev/null || true
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
        run_with_progress "Instalando plugin web-search" --estimate 30 install_websearch_plugin || true
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
EnvironmentFile=-/etc/tnode/env
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
# 1.44.0 — Zonas gestionadas SOUL/IDENTITY/USER/TOOLS ON-NODE (Harness Eng. F3a):
#          _md_sync_from_json y _sync_tools_md_from_json dejan de leer
#          {soul,identity,user,tools}Json de la CF y componen LOCAL (_compose_*_doc,
#          plantillas _SOUL_*/_IDENTITY_*/_T_* portadas byte-idénticas de
#          soul_identity_sync.ts + tools_sync.ts; email/mcp/delegate/inventory con
#          la misma lógica de gating). Hash-gate local (sha256 del body). Paridad
#          byte-a-byte verificada en shadow (TNODE_MD_SHADOW_ONLY) para las 4
#          zonas antes del flip. La CF build{Tools,Soul,Identity,User}Json queda
#          no-op hasta retirarse (aún alimenta el toolsJson que TEAM_INDEX lee de
#          cada peer para derivar especialidad — retirar SOLO tras resolver eso).
# 1.45.0 — AGENTS.md gestionado ON-NODE (Harness Eng. F3b Ola 1): 4 zonas P
#          platform-pure (tnode:agents:startup/memory/actions/heartbeats) en
#          _MD_TARGETS, compuestas local (_compose_agents_doc, plantillas _AGENTS_*
#          owner-agnósticas). A diferencia de soul/identity, AGENTS.md se
#          ESTANDARIZA: _agents_standardize resetea el archivo a un canónico limpio
#          (preámbulo neutral) una vez —descartando la capa A (pitch de negocio
#          manual, persona libre, boilerplate stock inglés)— con backup completo
#          reversible (.bak-pre-agents); luego las 4 zonas se appendean por hash.
#          Fixea el gap #1 (AGENTS sin zona gestionada) y el bug de refs vacías
#          (`Leo ** —` con filenames comidos por un strip viejo). Verificado con
#          TNODE_AGENTS_DRYRUN antes del flip; flota Mini/Pi/VPS byte-idéntica.
# 1.46.0 — Core .md estandarizados + security/memory (Harness Eng. F3b Ola 1 cont.):
#          (1) tnode:security — Líneas Rojas CONSOLIDADAS (antes duplicadas 4x en
#          SOUL/IDENTITY/USER/AGENTS, divergentes) en una zona P en AGENTS.md.
#          (2) tnode:memory — protocolo conversation-memory (SOUL), GATED por
#          presencia del skill (_has_conversation_memory: Mini sí, Pi/VPS no).
#          (3) SOUL/IDENTITY/USER ahora se ESTANDARIZAN (patrón de AGENTS 1.45.0,
#          generalizado a _std_reset): reset a canónico limpio descartando la capa
#          A curada (persona TBrain, "Los Clientes", email legacy, dups de
#          seguridad) con backup reversible por archivo (.bak-pre-{soul,identity,
#          user}); las zonas gestionadas se re-appendean. La persona/negocio se
#          recaptura por el Wizard (F3.5, capa D). Retira el _md_migrate (CF strip)
#          de soul/identity. Core entero limpio y consistente en la flota.
# 1.47.0 — Zonas D del Wizard "Especializa tu Agente" (Harness Eng. F3.5 Fase A,
#          backend): 4 zonas data-hot compuestas on-node desde config/specialization
#          (per-Node) + config/specialization (per-Owner), capturadas por la app:
#          `tnode:identity:data` (agentName+role, IDENTITY) · `tnode:persona`
#          (personaStyle sliders→párrafo vía _persona_from_sliders, SOUL) ·
#          `tnode:guardrails` (lista; fuente per-Owner si purpose=business /
#          per-Node si personal, AGENTS) · `tnode:memory:priorities` (lista con
#          framing clientes-vs-dueño según purpose, SOUL). Todas GATED por
#          data-presente (nuevo guard en _md_sync_from_json: body vacío → no crea
#          markers; también limpia el caso user-sin-perfil). Sin data sembrada, el
#          core queda idéntico a 1.46.0. AI-suggest CF + app Flutter = fuera de este
#          backend (se testea sembrando Firestore a mano).
__VERSION__ = "1.50.0"

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

# Per-environment project id (pre-prod/beta). Default = prod; beta nodes get
# TNODE_PROJECT_ID via the installer-written systemd Environment= line.
PROJECT_ID = os.environ.get("TNODE_PROJECT_ID", "tbrain-platform-7fc1f")
SCOPE = "sync_admin"

# Public API key (project-scoped, gates only signInWithCustomToken). Same one
# used by tnode-chat-sync and the iOS app. Non-prod environments ship their
# own key via TNODE_FIREBASE_WEB_API_KEY (legacy per-daemon var wins if set).
FIREBASE_WEB_API_KEY_FALLBACK = os.environ.get(
    "TNODE_CONFIG_SYNC_WEB_API_KEY",
    os.environ.get(
        "TNODE_FIREBASE_WEB_API_KEY",
        "AIzaSyCOybTP4r9J2bWXiJvXY0MQBFvaYDo_iWU",
    ),
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
    applied_at = time.time()

    # Una key recién minteada puede tardar MINUTOS en estar viva en OpenRouter
    # (401 "User not found" mientras propaga; medido ~4.5 min, E2E beta
    # 2026-07-12). El cliente retiene el primer mensaje del usuario hasta que
    # este comando complete — así que `done` debe significar "el agente YA
    # puede responder", no solo "la key quedó escrita". Sondeamos el endpoint
    # de metadata de la key (GET {base_url}/key, costo $0) hasta que OR la
    # acepte, con tope de 5 min. Si el tope vence, completamos igual (la key
    # está aplicada y vivirá sola) reportando keyLive=false para diagnóstico.
    key_live = False
    probe_url = base_url.rstrip("/") + "/key"
    probe_started = time.time()
    probe_deadline = probe_started + 300
    _log("apply_openrouter_key: probing key liveness against OpenRouter")
    while time.time() < probe_deadline:
        try:
            probe_req = urllib.request.Request(
                probe_url, headers={"Authorization": f"Bearer {api_key}"}
            )
            with urllib.request.urlopen(probe_req, timeout=10) as r:
                if 200 <= r.status < 300:
                    key_live = True
                    break
        except urllib.error.HTTPError as e:
            if e.code not in (401, 403, 404):
                # Respuesta inesperada del endpoint de metadata (5xx, rate
                # limit): no retengas el done por un probe roto — la key
                # puede estar perfectamente viva.
                _log(
                    f"key-liveness probe unexpected HTTP {e.code}; "
                    "assuming live"
                )
                key_live = True
                break
        except (urllib.error.URLError, OSError) as e:  # noqa: BLE001
            _log(f"key-liveness probe transient: {e}")
        time.sleep(12)
    waited_s = int(time.time() - probe_started)
    _log(f"apply_openrouter_key: keyLive={key_live} after {waited_s}s")

    # Colchón del hot-reload: el file-watcher del gateway tarda ~10s en
    # aplicar el openclaw.json nuevo (medido en gateway log: write 09:16:33 →
    # `hot reload applied (models)` 09:16:43, E2E beta 2026-07-12). Si el
    # probe de liveness regresó al instante, un `done` inmediato suelta el
    # mensaje retenido DENTRO de esa ventana y el turno arranca con la config
    # vieja ("No API key found for provider openai"). Garantiza ≥15s entre el
    # write y el done.
    reload_cushion = 15 - (time.time() - applied_at)
    if reload_cushion > 0:
        _log(f"apply_openrouter_key: hot-reload cushion {reload_cushion:.0f}s")
        time.sleep(reload_cushion)

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
            "keyLive": key_live,
            "keyLiveWaitS": waited_s,
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
    "https://us-central1-"
    + os.environ.get("TNODE_PROJECT_ID", "tbrain-platform-7fc1f")
    + ".cloudfunctions.net/agendaApi",
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
    "https://us-central1-"
    + os.environ.get("TNODE_PROJECT_ID", "tbrain-platform-7fc1f")
    + ".cloudfunctions.net/driveReadApi",
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
    "https://us-central1-"
    + os.environ.get("TNODE_PROJECT_ID", "tbrain-platform-7fc1f")
    + ".cloudfunctions.net/pollApi",
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

PROJECT_ID = os.environ.get("TNODE_PROJECT_ID", "tbrain-platform-7fc1f")
FIREBASE_WEB_API_KEY = os.environ.get(
    "TNODE_FIREBASE_WEB_API_KEY", "AIzaSyCOybTP4r9J2bWXiJvXY0MQBFvaYDo_iWU"
)
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
    """Render la zona gestionada de TOOLS.md desde el COMPOSITOR ON-NODE (F3a).
    Compone local (`_compose_tools_doc`) en vez de leer toolsJson de la CF.
    Hash-gate local (sha256 del body). Resiliente: cualquier fallo deja el
    TOOLS.md intacto. Nombre conservado por el call-site en _run_declarative_sync."""
    try:
        doc = _compose_tools_doc(token)
        body = _render_tools_zone(doc.get("blocks") or [])
    except Exception as e:  # noqa: BLE001
        _log(f"tools-sync: compose failed: {e}")
        return
    digest = hashlib.sha256(body.encode("utf-8")).hexdigest()
    md = OPENCLAW_DIR / "workspace" / "TOOLS.md"
    if digest == _read_local_tools_hash() and md.is_file():
        return  # sin cambios → no reescribir
    try:
        _apply_tools_zone(body)
        _write_local_tools_hash(digest)
        _log(
            f"tools-sync: rendered LOCAL {len(doc.get('blocks') or [])} blocks "
            f"(hash {digest[:12]})"
        )
    except Exception as e:  # noqa: BLE001
        _log(f"tools-sync: render failed: {e}")


# ── v1.1: compose vía CF + reflejo de canales + migración one-time ──
TOOLS_SYNC_URL = os.environ.get(
    "TNODE_TOOLS_SYNC_URL",
    f"https://us-central1-{PROJECT_ID}.cloudfunctions.net/tnodeConfigSyncTools",
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
    f"https://us-central1-{PROJECT_ID}.cloudfunctions.net/tnodeConfigSyncMd",
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
    # AGENTS.md — F3b Ola 1. CUATRO zonas P (platform-pure) en un mismo archivo,
    # cada una su par de markers + hash independiente. NO usan CF (net-new, sin
    # {target}Json): compone local + render por hash. La limpieza del archivo la
    # hace `_agents_standardize` (reset a canónico) UNA vez, así que aquí
    # legacy_headers va vacío (no hay strip por-header). backup compartido.
    "agents_startup": {
        "md_name": "AGENTS.md",
        "zone_start": "<!-- tnode:agents:startup:start -->",
        "zone_end": "<!-- tnode:agents:startup:end -->",
        "hash_path": OPENCLAW_DIR / ".tnode-agents-startup-hash",
        "sentinel": OPENCLAW_DIR / ".tnode-agents-startup-migrated",
        "backup_name": "AGENTS.md.bak-pre-agents",
        "legacy_headers": (),
    },
    "agents_memory": {
        "md_name": "AGENTS.md",
        "zone_start": "<!-- tnode:agents:memory:start -->",
        "zone_end": "<!-- tnode:agents:memory:end -->",
        "hash_path": OPENCLAW_DIR / ".tnode-agents-memory-hash",
        "sentinel": OPENCLAW_DIR / ".tnode-agents-memory-migrated",
        "backup_name": "AGENTS.md.bak-pre-agents",
        "legacy_headers": (),
    },
    "agents_actions": {
        "md_name": "AGENTS.md",
        "zone_start": "<!-- tnode:agents:actions:start -->",
        "zone_end": "<!-- tnode:agents:actions:end -->",
        "hash_path": OPENCLAW_DIR / ".tnode-agents-actions-hash",
        "sentinel": OPENCLAW_DIR / ".tnode-agents-actions-migrated",
        "backup_name": "AGENTS.md.bak-pre-agents",
        "legacy_headers": (),
    },
    "agents_heartbeats": {
        "md_name": "AGENTS.md",
        "zone_start": "<!-- tnode:agents:heartbeats:start -->",
        "zone_end": "<!-- tnode:agents:heartbeats:end -->",
        "hash_path": OPENCLAW_DIR / ".tnode-agents-heartbeats-hash",
        "sentinel": OPENCLAW_DIR / ".tnode-agents-heartbeats-migrated",
        "backup_name": "AGENTS.md.bak-pre-agents",
        "legacy_headers": (),
    },
    # tnode:security — zona P transversal CONSOLIDADA (F3b). Antes duplicada 4x
    # (SOUL ## Reglas · IDENTITY ## Seguridad de Identidad · USER ### Lo que NUNCA
    # Revelo · AGENTS ## Líneas Rojas), divergente. Vive en AGENTS.md (append tras
    # las 4 zonas agents:*); las copias en SOUL/IDENTITY/USER se van con el
    # standardize de cada archivo.
    "security": {
        "md_name": "AGENTS.md",
        "zone_start": "<!-- tnode:security:start -->",
        "zone_end": "<!-- tnode:security:end -->",
        "hash_path": OPENCLAW_DIR / ".tnode-security-hash",
        "sentinel": OPENCLAW_DIR / ".tnode-security-migrated",
        "backup_name": "AGENTS.md.bak-pre-agents",
        "legacy_headers": (),
    },
    # tnode:memory — protocolo conversation-memory (SOUL). P pero GATED: solo se
    # renderiza si el skill conversation-memory está instalado en el nodo (Mini sí,
    # Pi/VPS no). El gate vive en la orquestación (_has_conversation_memory).
    "memory": {
        "md_name": "SOUL.md",
        "zone_start": "<!-- tnode:memory:start -->",
        "zone_end": "<!-- tnode:memory:end -->",
        "hash_path": OPENCLAW_DIR / ".tnode-memory-hash",
        "sentinel": OPENCLAW_DIR / ".tnode-memory-migrated",
        "backup_name": "SOUL.md.bak-pre-soul",
        "legacy_headers": (),
    },
    # ── Zonas D del Wizard "Especializa tu Agente" (F3.5 Fase A) ──
    # Data-hot desde Firestore (config/specialization per-Node + per-Owner), la
    # captura la app. Gated: sin data → body vacío → _md_sync_from_json no crea
    # markers (ver guard). Se appendean al core ya estandarizado.
    "identity_data": {
        "md_name": "IDENTITY.md",
        "zone_start": "<!-- tnode:identity:data:start -->",
        "zone_end": "<!-- tnode:identity:data:end -->",
        "hash_path": OPENCLAW_DIR / ".tnode-identity-data-hash",
        "legacy_headers": (),
    },
    "persona": {
        "md_name": "SOUL.md",
        "zone_start": "<!-- tnode:persona:start -->",
        "zone_end": "<!-- tnode:persona:end -->",
        "hash_path": OPENCLAW_DIR / ".tnode-persona-hash",
        "legacy_headers": (),
    },
    "memory_priorities": {
        "md_name": "SOUL.md",
        "zone_start": "<!-- tnode:memory:priorities:start -->",
        "zone_end": "<!-- tnode:memory:priorities:end -->",
        "hash_path": OPENCLAW_DIR / ".tnode-memory-priorities-hash",
        "legacy_headers": (),
    },
    "guardrails": {
        "md_name": "AGENTS.md",
        "zone_start": "<!-- tnode:guardrails:start -->",
        "zone_end": "<!-- tnode:guardrails:end -->",
        "hash_path": OPENCLAW_DIR / ".tnode-guardrails-hash",
        "legacy_headers": (),
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


def _md_remove_zone(target: str) -> None:
    """Quita el par de markers de <md> (y su contenido) si existe, y borra el hash
    local. Para zonas D que se quedaron sin data (el dueño las vació en la app):
    la zona debe DESAPARECER, no quedar stale. No-op si no hay markers."""
    desc = _MD_TARGETS[target]
    p = OPENCLAW_DIR / "workspace" / desc["md_name"]
    try:
        desc["hash_path"].unlink()
    except Exception:  # noqa: BLE001
        pass
    if not p.is_file():
        return
    text = p.read_text(encoding="utf-8")
    start, end = desc["zone_start"], desc["zone_end"]
    if start not in text or end not in text:
        return
    pre = text.split(start, 1)[0].rstrip()
    post = text.split(end, 1)[1].lstrip("\n")
    new = pre + ("\n\n" + post if post.strip() else "\n")
    if new != text:
        tmp = p.with_name(p.name + ".tmp")
        tmp.write_text(new, encoding="utf-8")
        os.replace(tmp, p)
        _log(f"md-sync[{target}]: zona removida (data D vacía)")


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


def _compose_md_local(token: dict, target: str):
    """Dispatch al compositor on-node por target (F3). Devuelve doc o None."""
    if target == "soul":
        return _compose_soul_doc()
    if target == "identity":
        return _compose_identity_doc(token)
    if target == "user":
        return _compose_user_doc(token)
    if target == "tools":
        return _compose_tools_doc(token)
    if target in _AGENTS_ZONE_TEXT:
        return _compose_agents_doc(target)
    if target == "security":
        return _compose_security_doc()
    if target == "memory":
        return _compose_memory_doc()
    if target == "identity_data":
        return _compose_identity_data_doc(token)
    if target == "persona":
        return _compose_persona_doc(token)
    if target == "guardrails":
        return _compose_guardrails_doc(token)
    if target == "memory_priorities":
        return _compose_memory_priorities_doc(token)
    return None


def _md_sync_from_json(token: dict, target: str) -> None:
    """Render la zona gestionada de <md> desde el COMPOSITOR ON-NODE (F3a).
    Compone local (soul/identity/user) en vez de leer {target}Json de la CF.
    Hash-gate local (sha256 del body). Resiliente: cualquier fallo deja el
    archivo intacto."""
    desc = _MD_TARGETS[target]
    try:
        doc = _compose_md_local(token, target)
        body = _render_tools_zone((doc or {}).get("blocks") or [])
    except Exception as e:  # noqa: BLE001
        _log(f"md-sync[{target}]: compose failed: {e}")
        return
    if not body.strip():
        _md_remove_zone(target)  # data D vacía → quita la zona si existía (no stale)
        return
    digest = hashlib.sha256(body.encode("utf-8")).hexdigest()
    md = OPENCLAW_DIR / "workspace" / desc["md_name"]
    if digest == _md_read_local_hash(target) and md.is_file():
        return  # sin cambios → no reescribir
    try:
        blocks = (doc or {}).get("blocks") or []
        if _md_apply_zone(target, body):
            _md_write_local_hash(target, digest)
            _log(
                f"md-sync[{target}]: rendered LOCAL {len(blocks)} blocks "
                f"(hash {digest[:12]})"
            )
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


# ── AGENTS.md standardize (F3b Ola 1) ────────────────────────────────────────
# A diferencia de soul/identity/user (zonas inyectadas preservando la persona
# curada), AGENTS.md se ESTANDARIZA: una sola vez reseteamos el archivo a un
# canónico limpio (preámbulo neutral) descartando TODO lo de capa A — pitch de
# negocio manual (TBrain/TVision/precios), persona libre y el boilerplate stock
# en inglés de nodos no-tropicalizados. Decisión de tobal (2026-07-04): dejar la
# flota limpia y estándar; el negocio se recaptura luego por el Wizard (capa D).
# Backup completo reversible en AGENTS.md.bak-pre-agents. Tras el reset, las 4
# zonas P (`agents_*`) se appendean vía _md_sync_from_json (mecánica normal).
_AGENTS_STANDARDIZE_SENTINEL = OPENCLAW_DIR / ".tnode-agents-standardized"
_SOUL_STANDARDIZE_SENTINEL = OPENCLAW_DIR / ".tnode-soul-standardized"
_IDENTITY_STANDARDIZE_SENTINEL = OPENCLAW_DIR / ".tnode-identity-standardized"
_USER_STANDARDIZE_SENTINEL = OPENCLAW_DIR / ".tnode-user-standardized"


def _std_reset(md_name: str, preamble: str, clear_targets, sentinel, backup_name: str) -> None:
    """One-time: backup + reset workspace/<md_name> a un canónico limpio (solo el
    preámbulo neutral), descartando la capa A curada. Tras el reset, las zonas
    gestionadas del archivo se re-appendean vía _md_sync_from_json — por eso se
    borran sus hashes (si no, el body ya no está pero el hash coincidiría y el
    sync lo saltaría). No-op si ya corrió (sentinel) o si el archivo no existe
    aún (nodo fresco antes de que OpenClaw lo siembre → reintenta luego)."""
    if sentinel.exists():
        return
    p = OPENCLAW_DIR / "workspace" / md_name
    if not p.is_file():
        return
    try:
        original = p.read_text(encoding="utf-8")
        bak = p.with_name(backup_name)
        if not bak.exists():
            bak.write_text(original, encoding="utf-8")
        clean = preamble.strip() + "\n"
        if clean != original:
            tmp = p.with_name(p.name + ".tmp")
            tmp.write_text(clean, encoding="utf-8")
            os.replace(tmp, p)
            _log(f"std-reset[{md_name}]: reset a canónico limpio (backup {backup_name})")
        for t in clear_targets:
            try:
                _MD_TARGETS[t]["hash_path"].unlink()
            except Exception:  # noqa: BLE001
                pass
        sentinel.write_text("done", encoding="utf-8")
    except Exception as e:  # noqa: BLE001
        _log(f"std-reset[{md_name}]: {e}")


def _agents_standardize() -> None:
    # AGENTS.md → preámbulo + 4 zonas agents:* + security (5ª, consolidada).
    _std_reset(
        "AGENTS.md", _AGENTS_PREAMBLE, _AGENTS_ORDER + ("security",),
        _AGENTS_STANDARDIZE_SENTINEL, "AGENTS.md.bak-pre-agents",
    )


def _soul_standardize() -> None:
    # SOUL.md → preámbulo + tnode:memory (gated) + tnode:soul. Nukea persona A
    # (Personalidad/Tono), Reglas (→ security) y email legacy (TOOLS R4).
    _std_reset(
        "SOUL.md", _SOUL_PREAMBLE, ("memory", "soul"),
        _SOUL_STANDARDIZE_SENTINEL, "SOUL.md.bak-pre-soul",
    )


def _identity_standardize() -> None:
    # IDENTITY.md → preámbulo + tnode:identity (subagentes + equipo). Nukea Mi
    # Propósito / Mi Posición (A) y Seguridad de Identidad (→ security).
    _std_reset(
        "IDENTITY.md", _IDENTITY_PREAMBLE, ("identity",),
        _IDENTITY_STANDARDIZE_SENTINEL, "IDENTITY.md.bak-pre-identity",
    )


def _user_standardize() -> None:
    # USER.md → preámbulo + tnode:user (perfil del dueño, position=start). Nukea
    # "Mi Dueño" dup, "Los Clientes", industrias, "Lo que NUNCA Revelo" (→ security).
    _std_reset(
        "USER.md", _USER_PREAMBLE, ("user",),
        _USER_STANDARDIZE_SENTINEL, "USER.md.bak-pre-user",
    )


def _agents_dryrun() -> None:
    """MODO DRY-RUN (verificación F3b): compone el AGENTS.md estandarizado que
    RESULTARÍA (preámbulo + 4 zonas P) y lo diffea contra el archivo real, SIN
    escribir nada. Escribe el diff a .tnode-agents-dryrun.diff e imprime el
    resultado a stdout para revisión. Cero side-effects."""
    try:
        p = OPENCLAW_DIR / "workspace" / "AGENTS.md"
        before = p.read_text(encoding="utf-8") if p.is_file() else ""
        parts = [_AGENTS_PREAMBLE.strip()]
        for t in _AGENTS_ORDER:
            desc = _MD_TARGETS[t]
            body = _render_tools_zone(_compose_agents_doc(t).get("blocks") or [])
            parts.append(f'{desc["zone_start"]}\n{body}\n{desc["zone_end"]}')
        after = "\n\n".join(parts) + "\n"
        import difflib
        d = "\n".join(difflib.unified_diff(
            before.splitlines(), after.splitlines(),
            fromfile="AGENTS.md (actual)", tofile="AGENTS.md (estandarizado)",
            lineterm="",
        ))
        (OPENCLAW_DIR / ".tnode-agents-dryrun.diff").write_text(d[:20000], encoding="utf-8")
        _log(f"agents-dryrun: actual={len(before)} → estandarizado={len(after)} chars")
        print("===== AGENTS.md ESTANDARIZADO (dry-run, NO escrito) =====")
        print(after)
        print("===== FIN =====")
    except Exception as e:  # noqa: BLE001
        _log(f"agents-dryrun: {e}")


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


# ── SOUL.md / IDENTITY.md compositor ON-NODE (F3: reemplaza la CF) ──────────
# Plantillas P (platform-plantilla) portadas byte-idénticas de
# tnode_client/functions/src/soul_identity_sync.ts (STATIC_*). Zonas 100%
# estáticas salvo el bloque "equipo" de IDENTITY (condicional a peers, reusa
# _team_read_peers). El renderer/marker no cambia; solo el origen del doc.
_SOUL_SUBAGENTES = """## Sub-agentes disponibles

Lee `~/.openclaw/agency-agents/AGENTS_INDEX.md` al iniciar tu sesión para conocer el roster completo y sus especialidades. Úsalo para decidir cuándo invocar `sessions_spawn(runtime="subagent", agentId=<id>, task=...)`."""

_SOUL_SEND_FILE = """## Envío de archivos al chat

Cuando produzcas un archivo (PDF, imagen, código, etc.) que el usuario quiera abrir desde su app, NO le pases la ruta como texto. Incluye un marker exacto en tu respuesta así:

    [adjunto: /ruta/absoluta/al/archivo.pdf]

El sistema detecta el marker, sube el archivo a un canal seguro y lo reemplaza por un chip descargable en el chat (el usuario lo toca y se abre con su visor nativo).

Reglas:
- El archivo debe vivir bajo `~/.openclaw/workspace/`. Cualquier otra ruta es rechazada por seguridad.
- Tamaño máximo: 50 MB.
- Tipos comunes aceptados: PDF, imágenes, texto, código, ZIP/TAR/GZ, JSON/XML.
- Puedes mezclar varios markers con texto normal: "Aquí tienes el reporte [adjunto: workspace/foo.pdf] y los datos [adjunto: workspace/bar.csv]".
- NO uses `MEDIA:`, `file://`, ni rutas crudas — siempre el formato `[adjunto: <ruta>]`."""

_SOUL_DOWNLOAD = """## Entregables descargables — workspace/download/

Cuando produzcas un archivo que el usuario quiera consultar más tarde (no solo este turno del chat), guárdalo bajo:

    ~/.openclaw/workspace/download/<nombre-descriptivo>.<ext>

El usuario lo verá en la app → Almacenamiento → Local → tab "Descarga", ordenado por fecha de modificación. Desde ahí puede descargarlo a su dispositivo o borrarlo.

Cuando lo anuncies en el chat, sigue usando el marker `[adjunto: workspace/download/<nombre>]` (ver sección "Envío de archivos al chat" para reglas del marker) — el chip clicable aparece en la conversación Y el archivo persiste en la pantalla Almacenamiento.

Reglas adicionales para entregables:
- Usa nombres descriptivos en kebab-case con fecha cuando aplique: `reporte-ventas-q1-2026.pdf`, no `out.pdf`.
- Si reemplazas un archivo (e.g. nueva versión del mismo reporte), mantén el mismo nombre para no acumular duplicados.
- Para archivos efímeros del turno actual (cálculos intermedios, screenshots de debug, etc.), usa `workspace/` raíz, no `workspace/download/`. La pantalla Almacenamiento solo lista `upload/` (lo que el user te mandó) y `download/` (tus entregables formales)."""

_IDENTITY_SUBAGENTES = """## Sub-agentes a tu disposición

Eres el coordinador principal. Cuando una tarea encaja con la especialidad de un sub-agente del roster (ver `~/.openclaw/agency-agents/AGENTS_INDEX.md`), delégala con `sessions_spawn(runtime="subagent", agentId=<id>, task=...)` en lugar de hacerla tú mismo."""

_IDENTITY_EQUIPO = """## Tu equipo de TNodes

Además de tus sub-agentes locales, el dueño enlazó otros de sus TNodes a un EQUIPO: nodos a los que puedes delegar tareas, cada uno con SUS canales, skills y contexto. Lee `~/.openclaw/agency-agents/TEAM_INDEX.md` para conocer el roster: alias, rol y especialidad de cada nodo.

Cuando una tarea encaje con la especialidad de un nodo del equipo (un canal/skill/acceso que ESE nodo tiene y tú no), delégasela en lugar de intentarla aquí, con:

    exec: python3 ~/.openclaw/workspace/skills/tnode-delegate/bin/tnode-delegate.py delegate --alias <alias> --text "<instrucción autocontenida>"

El comando imprime la respuesta del agente de ese nodo; úsala para continuar tu trabajo. La instrucción debe ser CLARA y AUTOCONTENIDA (el otro nodo no ve tu conversación). El detalle del skill está en la Regla de delegación de tu TOOLS.md."""


# ── AGENTS.md — plantillas P (F3b Ola 1) ─────────────────────────────────────
# Protocolo de operación platform-pure, IDÉNTICO para todo agente de la flota
# (owner-agnóstico: sin nombres/negocio hardcodeados). La especialización por
# sector/persona vive en la capa D del Wizard (F3.5), no aquí.
_AGENTS_PREAMBLE = """# AGENTS.md — Protocolo de Operación

> Define cómo opero como agente de la plataforma: arranque de sesión, manejo de memoria, acciones y respuesta a heartbeats. Estándar para todos los agentes de la plataforma."""

_AGENTS_STARTUP = """## Startup de Sesión — Mi Protocolo

Al iniciar cada sesión, ejecuto en este orden:

1. Leo `SOUL.md` — quién soy, cómo pienso, mis límites
2. Leo `IDENTITY.md` — mi nombre, rol y posición
3. Leo `USER.md` — quién es mi interlocutor y su contexto
4. Leo `HEARTBEAT.md` (hoy y ayer) — ¿qué pasó recientemente?
5. Si estoy en sesión MAIN con mi dueño: leo también `MEMORY.md` — mi memoria de largo plazo

No pido permiso. Lo hago y estoy listo."""

_AGENTS_MEMORY = """## Memoria y Continuidad

- **Notas diarias:** `HEARTBEAT.md` — registro de lo que pasó
- **Memoria de largo plazo:** `MEMORY.md` — solo en sesión MAIN con mi dueño
- **Estado de herramientas:** `TOOLS.md` — integraciones activas

**Regla de oro:** Si no lo escribo, lo olvido. Todo lo relevante va al archivo."""

_AGENTS_ACTIONS = """## Acciones que Hago Libremente

- Leer archivos, explorar contexto, investigar
- Responder consultas con mi contexto de negocio
- Actualizar mis archivos de memoria

## Acciones que Requieren Confirmación

- Enviar mensajes externos (WhatsApp, email) en nombre del negocio
- Publicar contenido en canales públicos
- Cualquier acción que comprometa algo irreversible"""

_AGENTS_HEARTBEATS = """## Heartbeats — Proactividad Inteligente

Cuando recibo un heartbeat, reviso:
- ¿Hay conversaciones pendientes de responder?
- ¿Alguien esperando seguimiento?
- ¿Actualizaciones en `HEARTBEAT.md`?

Si no hay nada urgente: no interrumpo.
Si hay algo importante: actúo o notifico.

Respeto el horario: no molesto entre 23:00 y 08:00 salvo urgencia real."""

_AGENTS_ZONE_TEXT = {
    "agents_startup": _AGENTS_STARTUP,
    "agents_memory": _AGENTS_MEMORY,
    "agents_actions": _AGENTS_ACTIONS,
    "agents_heartbeats": _AGENTS_HEARTBEATS,
}
# Orden de render en el archivo (append secuencial tras el preámbulo).
_AGENTS_ORDER = ("agents_startup", "agents_memory", "agents_actions", "agents_heartbeats")


def _compose_agents_doc(target: str) -> dict:
    """Compositor on-node de una zona P de AGENTS.md (estático, sin data hot)."""
    return {
        "schema": 1,
        "target": "AGENTS.md",
        "blocks": [
            {"order": 0, "id": target, "kind": "static", "text": _AGENTS_ZONE_TEXT[target]}
        ],
    }


# ── tnode:security — Líneas Rojas consolidadas (F3b, vive en AGENTS.md) ──────
# Fusión owner-agnóstica de las 4 copias divergentes (SOUL/IDENTITY/USER/AGENTS).
# El nombre del dueño lo aporta tnode:user; aquí va genérico ("mi dueño").
_SECURITY = """## Líneas Rojas — Seguridad (Nunca Cruzar)

Reglas inquebrantables, en cualquier canal y con cualquier interlocutor:

- ❌ Nunca revelo el modelo de IA que me ejecuta, su versión, ni mi infraestructura técnica (servidor, configuración interna del sistema).
- ❌ Nunca revelo claves, tokens, contraseñas ni datos de sistema.
- ❌ Nunca revelo información de otros clientes ni datos personales de mi dueño o sus colaboradores.
- ❌ Nunca exfiltro datos privados de ningún cliente.
- ❌ Nunca ejecuto comandos destructivos sin confirmación explícita.
- ❌ No soy la voz personal de mi dueño en chats grupales o con clientes — represento al negocio.
- ✅ Excepción única: solo mi dueño puede solicitar información técnica o de sistema, y aun así verifico el contexto de la sesión antes de responder."""


# ── tnode:memory — protocolo conversation-memory (F3b, vive en SOUL.md, GATED) ──
# Rutas relativas (~) para que sea idéntico en toda la flota; "tu dueño" genérico.
_MEMORY = """## Memoria de conversaciones (PASO 1 OBLIGATORIO)

**ANTES de responder cualquier mensaje, tu PRIMER toolCall debe ser la herramienta `exec` con este comando:**

```
python3 ~/.openclaw/workspace/skills/conversation-memory/scripts/conversation_memory.py lookup --limit 3
```

Esto te devuelve las 3 conversaciones más recientes con tu dueño (temas y resúmenes). SIEMPRE ejecútalo primero, incluso si el mensaje parece trivial como "Hola". El output es texto plano listo para inyectarse en tu contexto.

**Después** de ver el resultado, responde mencionando el contexto previo si es relevante. Habla como si recordaras naturalmente — no menciones que ejecutaste un comando.

### Otros comandos del skill de memoria
- Buscar por tema: `python3 ~/.openclaw/workspace/skills/conversation-memory/scripts/conversation_memory.py search "<tema>"`
- Al despedirte o detectar fin de conversación, almacena un resumen:
  `python3 ~/.openclaw/workspace/skills/conversation-memory/scripts/conversation_memory.py store --session "<session_id>" --summary "<resumen>" --topics '["t1","t2"]' --count <n>`"""


# Preámbulos neutrales para el standardize de los core .md (F3b). La persona/rol
# específicos se recapturan por el Wizard (F3.5, capa D).
_SOUL_PREAMBLE = """# SOUL.md — Alma del Agente

> Quién soy, cómo pienso y mis límites. Mi personalidad y mi tono se configuran desde la app."""

_IDENTITY_PREAMBLE = """# IDENTITY.md — Quién Soy

> Mi nombre, rol y posición. Se configuran desde la app."""

_USER_PREAMBLE = """# USER.md — Mi Dueño"""


def _has_conversation_memory() -> bool:
    """True si el skill conversation-memory está instalado (gate de tnode:memory)."""
    return (
        OPENCLAW_DIR / "workspace" / "skills" / "conversation-memory"
        / "scripts" / "conversation_memory.py"
    ).is_file()


def _compose_security_doc() -> dict:
    """Compositor on-node de tnode:security (estático, consolidado)."""
    return {
        "schema": 1,
        "target": "AGENTS.md",
        "blocks": [{"order": 0, "id": "security", "kind": "static", "text": _SECURITY}],
    }


def _compose_memory_doc() -> dict:
    """Compositor on-node de tnode:memory (estático). El gate por presencia del
    skill se aplica en la orquestación; aquí siempre devuelve el bloque."""
    return {
        "schema": 1,
        "target": "SOUL.md",
        "blocks": [{"order": 0, "id": "memory", "kind": "static", "text": _MEMORY}],
    }


# ── Zonas D del Wizard "Especializa tu Agente" (F3.5 Fase A) ─────────────────
# Data-hot desde config/specialization (per-Node) + config/specialization
# (per-Owner). Todas gated: sin data → blocks vacío → _md_sync_from_json no crea
# markers. La app captura estos datos (wizard); aquí sólo se componen.
def _read_owner_spec(token: dict) -> dict:
    """GET users/{uid}.specialization (mapa business-wide del Wizard: sector,
    guardrails, memoryPriorities). Se lee como CAMPO del user doc (mismo patrón que
    .profile) — el token del nodo puede leer users/{uid} pero NO subcolecciones
    owner-scoped tipo users/{uid}/config/* (reglas de seguridad). {} si ausente."""
    url = f"{_firestore_base()}/users/{token['uid']}?mask.fieldPaths=specialization"
    try:
        doc = _http_request(
            "GET", url, headers={"Authorization": f"Bearer {token['idToken']}"},
        )
    except Exception:  # noqa: BLE001
        return {}
    fields = (doc or {}).get("fields") or {}
    val = _fs_unwrap(fields["specialization"]) if "specialization" in fields else {}
    return val if isinstance(val, dict) else {}


def _wiz_str(d: dict, k: str) -> str:
    v = d.get(k) if isinstance(d, dict) else None
    return v.strip() if isinstance(v, str) else ""


def _wiz_list(d: dict, k: str) -> list:
    v = d.get(k) if isinstance(d, dict) else None
    return [str(x).strip() for x in v if str(x).strip()] if isinstance(v, list) else []


def _persona_from_sliders(style) -> str:
    """Traduce personaStyle {formalidad,detalle,proactividad} (0-100) a un párrafo.
    Bandas: <34 extremo-bajo · 34-66 medio · >66 extremo-alto."""
    if not isinstance(style, dict):
        return ""
    def band(k: str, lo: str, mid: str, hi: str) -> str:
        try:
            v = int(style.get(k))
        except (TypeError, ValueError):
            return mid
        return lo if v < 34 else (hi if v > 66 else mid)
    f = band("formalidad", "de manera formal y profesional",
             "con un tono equilibrado", "de manera cercana, cálida e informal")
    d = band("detalle", "Respondo breve y al punto",
             "Doy el detalle que convenga", "Doy explicaciones completas con contexto")
    p = band("proactividad", "Espero a que me pidan las cosas",
             "Sugiero cuando es útil", "Soy proactivo y anticipo necesidades")
    return f"Hablo {f}. {d}. {p}."


def _compose_identity_data_doc(token: dict) -> dict:
    spec = _get_node_subdoc(token, "config/specialization")
    name, role = _wiz_str(spec, "agentName"), _wiz_str(spec, "role")
    blocks = []
    if name:
        line = f"Soy **{name}**" + (f", {role}." if role else ".")
        blocks.append({"order": 0, "id": "identity-data", "kind": "static",
                       "text": f"## Quién soy\n\n{line}"})
    return {"schema": 1, "target": "IDENTITY.md", "blocks": blocks}


def _compose_persona_doc(token: dict) -> dict:
    spec = _get_node_subdoc(token, "config/specialization")
    text = _persona_from_sliders(spec.get("personaStyle") if isinstance(spec, dict) else None)
    blocks = []
    if text:
        blocks.append({"order": 0, "id": "persona", "kind": "static",
                       "text": f"## Personalidad y tono\n\n{text}"})
    return {"schema": 1, "target": "SOUL.md", "blocks": blocks}


def _compose_guardrails_doc(token: dict) -> dict:
    node = _get_node_subdoc(token, "config/specialization")
    personal = _wiz_str(node, "purpose") == "personal"
    if personal:
        items = _wiz_list(node, "guardrails")
        title, intro = "## Mis límites", "Reglas que nunca cruzo:"
    else:
        items = _wiz_list(_read_owner_spec(token), "guardrails")
        title, intro = "## Límites del negocio", "Reglas que nunca cruzo, con cualquier cliente:"
    blocks = []
    if items:
        body = f"{title}\n\n{intro}\n" + "\n".join(f"- {x}" for x in items)
        blocks.append({"order": 0, "id": "guardrails", "kind": "static", "text": body})
    return {"schema": 1, "target": "AGENTS.md", "blocks": blocks}


def _compose_memory_priorities_doc(token: dict) -> dict:
    node = _get_node_subdoc(token, "config/specialization")
    personal = _wiz_str(node, "purpose") == "personal"
    if personal:
        items = _wiz_list(node, "memoryPriorities")
        title = "## Qué priorizo recordar de mi dueño"
        intro = "De la persona dueña de este nodo, priorizo recordar:"
    else:
        items = _wiz_list(_read_owner_spec(token), "memoryPriorities")
        title = "## Qué priorizo recordar de clientes"
        intro = "De cada cliente, priorizo recordar:"
    blocks = []
    if items:
        body = f"{title}\n\n{intro}\n" + "\n".join(f"- {x}" for x in items)
        blocks.append({"order": 0, "id": "memory-priorities", "kind": "static", "text": body})
    return {"schema": 1, "target": "SOUL.md", "blocks": blocks}


def _compose_soul_doc() -> dict:
    """Puerto on-node de la CF buildSoulDoc (100% estático)."""
    return {
        "schema": 1,
        "target": "SOUL.md",
        "blocks": [
            {"order": 0, "id": "subagentes", "kind": "static", "text": _SOUL_SUBAGENTES},
            {"order": 10, "id": "envio-archivos", "kind": "static", "text": _SOUL_SEND_FILE},
            {"order": 20, "id": "entregables", "kind": "static", "text": _SOUL_DOWNLOAD},
        ],
    }


def _compose_identity_doc(token: dict) -> dict:
    """Puerto on-node de la CF buildIdentityDoc: sub-agentes (estático) + equipo
    (solo si el nodo tiene peers enabled, igual que la CF)."""
    blocks = [
        {"order": 0, "id": "subagentes", "kind": "static", "text": _IDENTITY_SUBAGENTES},
    ]
    try:
        has_peers = len(_team_read_peers(token)) > 0
    except Exception:  # noqa: BLE001
        has_peers = False
    if has_peers:
        blocks.append(
            {"order": 10, "id": "equipo", "kind": "static", "text": _IDENTITY_EQUIPO}
        )
    return {"schema": 1, "target": "IDENTITY.md", "blocks": blocks}


def _read_user_profile(token: dict):
    """GET users/{uid}.profile (mapa capturado en la app 'Tu perfil')."""
    url = f"{_firestore_base()}/users/{token['uid']}?mask.fieldPaths=profile"
    try:
        doc = _http_request(
            "GET", url,
            headers={"Authorization": f"Bearer {token['idToken']}"},
        )
    except Exception:  # noqa: BLE001
        return None
    fields = (doc or {}).get("fields") or {}
    return _fs_unwrap(fields["profile"]) if "profile" in fields else None


def _compose_user_doc(token: dict) -> dict:
    """Puerto on-node de la CF buildUserDoc, BLOQUE 1 (owner-profile). El bloque 2
    'Sobre el negocio' (config/businessProfile) es F3.5 → aquí se omite; en nodos
    SIN businessProfile el resultado es byte-idéntico a la CF."""
    profile = _read_user_profile(token)
    blocks: list = []
    if isinstance(profile, dict):
        def s(k: str) -> str:
            v = profile.get(k)
            return v.strip() if isinstance(v, str) else ""
        lines: list = []
        full_name = " ".join(x for x in [s("firstName"), s("lastName")] if x)
        nick = s("nickname")
        if full_name:
            lines.append(f"- **Nombre:** {full_name}")
        if nick:
            lines.append(f"- **Cómo le gusta que le digas:** {nick}")
        if s("birthDate"):
            lines.append(f"- **Fecha de nacimiento:** {s('birthDate')}")
        loc = ", ".join(x for x in [s("state"), s("country")] if x)
        tz = s("timezone")
        if loc or tz:
            tzpart = f"{' ' if loc else ''}(zona horaria {tz})" if tz else ""
            lines.append(f"- **Ubicación:** {loc}{tzpart}".strip())
        if s("phone"):
            lines.append(f"- **Teléfono:** {s('phone')}")
        if s("occupation"):
            lines.append(f"- **A qué se dedica:** {s('occupation')}")
        if s("about"):
            lines.append(f"- **Sobre el dueño:** {s('about')}")
        if lines:
            tone = s("tone")
            tone_hint = (
                "Trátalo de manera formal y profesional." if tone == "formal"
                else "Trátalo de manera cercana e informal, con calidez."
                if tone == "cercano"
                else "Mantén un tono equilibrado, ni muy formal ni muy casual."
            )
            addr = f"Dirígete a tu dueño como “{nick}”. " if nick else ""
            text = (
                "## Perfil de tu dueño\n\n"
                "La persona dueña de este nodo configuró estos datos en su app. "
                "Úsalos para personalizar tu trato y tus respuestas.\n\n"
                + "\n".join(lines) + "\n\n"
                + f"{addr}{tone_hint}"
            )
            blocks.append(
                {"order": 0, "id": "owner-profile", "kind": "static", "text": text}
            )
    return {"schema": 1, "target": "USER.md", "blocks": blocks}


# ── TOOLS.md compositor ON-NODE (F3: reemplaza la CF buildToolsJson) ─────────
# Plantillas P portadas byte-idénticas de tools_sync.ts. Estáticos + MCP
# (mcpServers/ + mcpCatalog.rule) + email (variante desde channels/email) +
# inventory (config/inventoryFlow) + delegate (peers/). Orden idéntico a la CF.
_T_REGLA_0 = """## Regla 0 - Herramienta especifica antes que el navegador (CRITICO)

Antes de abrir el navegador (browser) o usar web_search, revisa si tienes una
herramienta ESPECIFICA para la tarea y usala primero. El navegador y web_search
son SOLO el ultimo recurso (fallback), cuando NINGUNA herramienta especifica aplica."""

_T_ANTILOOP = """## Regla anti-loop
Busca UNA sola vez y responde. NUNCA hagas mas de 1 busqueda por pregunta."""

_T_AVISO = """## Regla de aviso previo (IMPORTANTE)
ANTES de ejecutar cualquier herramienta (exec, web_search), SIEMPRE escribe un mensaje breve al usuario avisando que vas a buscar. Ejemplos:
- "Dame un momento, voy a buscar eso..."
- "Dejame consultar los precios..."
- "Buscando informacion..."
Esto es OBLIGATORIO. Primero el aviso, despues el tool."""

_T_AGENDA = """## Regla: agendar citas (skill agenda)

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
infraestructura: procede sin pedir permiso adicional."""

_T_DRIVE = """## Regla: leer archivos del Drive del dueño (skill drive)

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
es operación sensible: procede sin pedir permiso adicional."""

_T_POLL = """## Regla: encuestas (skill poll)

Cuando el DUEÑO te pida CREAR/HACER una encuesta ("haz una encuesta: ¿pizza o
sushi?", "crea una encuesta con opciones A, B y C") o MANDAR/DIFUNDIR de nuevo
la última ("manda la encuesta a todos"), usa el skill poll. La encuesta le
aparece en el chat a TODOS los miembros del nodo (y al dueño) y cada uno puede
votar; el conteo se actualiza en vivo.
Manual completo: ~/.openclaw/workspace/skills/poll/SKILL.md

Crear y repartir una encuesta nueva desde el prompt — la pregunta y de 2 a 12
opciones (agrega --multi si permites varias respuestas):
   exec: python3 ~/.openclaw/workspace/skills/poll/bin/poll.py create --question "¿Snack para el viernes?" --option "Pizza" --option "Sushi" --option "Tacos"

Difundir de nuevo la última encuesta del dueño a todos los invitados:
   exec: python3 ~/.openclaw/workspace/skills/poll/bin/poll.py broadcast

La respuesta trae delivered = a cuántos invitados llegó y question = la
pregunta. Confírmalo en lenguaje natural ("Listo, creé la encuesta '¿...?' y la
mandé a N invitados").

Errores: missing_question o bad_options (necesita de 2 a 12 opciones) → faltó
info, pídesela al dueño; no_open_poll (solo en broadcast) → aún no hay una
encuesta, créala; not_paired → el nodo no está vinculado. Solo el dueño puede
crear o difundir (no los invitados). Crear/difundir una encuesta NO es
operación sensible: procede sin pedir permiso adicional."""

_T_APPROVAL = """## Regla de plataforma: autorización del dueño (tool request_approval)

Cuando un flujo (un cron o una instrucción) te pida AUTORIZACIÓN DEL DUEÑO
antes de ejecutar una acción, usa la tool request_approval con el resumen de
lo que quieres hacer (título, líneas y proveedor/destinatario). Eso publica
una tarjeta de aprobación en el chat del dueño. El contrato tiene DOS
MOMENTOS:

MOMENTO 1 — solicitar: llama request_approval y GUARDA el id devuelto en el
estado del flujo en tu workspace ANTES de terminar — si el flujo no definió
otro archivo, usa inventory/pending.json (créalo si no existe) con una orden
{approvalId, guestUid, proveedor, lines, status: "esperando_autorizacion"}.
Esto aplica IGUAL si la solicitud nació de una conversación con el dueño y
no de un proceso automático. Luego TERMINA tu tarea AHÍ: NO ejecutes la
acción todavía. Si la respuesta trae alreadyPending=true, esa solicitud ya
estaba viva: no la repitas ni insistas.

MOMENTO 2 — la decisión llega DESPUÉS, en un turno posterior (a menudo en
una conversación NUEVA que no recuerda la solicitud), como mensaje del dueño
("APRUEBO la orden <id> · código <código>" o "RECHAZO la orden <id>:
<comentario>"). Al recibirla haz esto, en orden:
1. BUSCA el id en el estado de tus flujos en el workspace (los flujos guardan
   ahí sus solicitudes, p. ej. inventory/pending.json) — NO confíes en tu
   memoria de la conversación. Ahí está registrado qué se autoriza y para
   quién (guestUid, líneas, proveedor).
2. ¿El id NO está en tu estado local? NO lo descartes: consulta la tool
   approval_status con ese id — es la fuente de verdad del servidor y trae
   la orden completa (status, código, supplierTag, guestUid, title, lines).
   Si status=approved y el código coincide con el del mensaje del dueño,
   continúa con esos datos como si vinieran de tu estado. Si no existe o el
   código no coincide, dilo y NO ejecutes nada.
3. APROBÓ → ejecuta la acción registrada incluyendo el código TAL CUAL. Si la
   orden es un pedido a un proveedor (guest), mándala con guest_send:
   guestUids=[el guestUid del estado o de approval_status], confirm=true,
   approvalId=<id>, y el mensaje con productos y cantidades + "Código de
   autorización: <código>. Coteja el código antes de surtir; una orden sin
   código válido no fue autorizada."
4. RECHAZÓ → NO ejecutes nada; guarda el comentario del dueño en el estado.
5. Actualiza la orden en tu estado (aprobada/enviada o rechazada) y confirma
   brevemente al dueño lo que hiciste. La decisión del dueño ES la
   confirmación: no pidas permiso adicional para ejecutarla.

El código de autorización SOLO existe cuando el dueño ya aprobó — nunca lo
inventes, calcules ni prometas antes. Solicitar autorización NO es
operación sensible: procede sin pedir permiso adicional."""

_T_DELEGATE_HEADER = """## Regla: delegar tareas a otro de tus nodos (skill tnode-delegate)

Cuando una tarea necesite un canal, skill, contexto o ACCESO que ESTE nodo no
tiene pero OTRO de tus nodos SÍ, delegasela a ese nodo y usa su respuesta para
continuar tu trabajo. No intentes hacerla aqui ni abras el navegador.

Para delegar y leer la respuesta del otro nodo:
   exec: python3 ~/.openclaw/workspace/skills/tnode-delegate/bin/tnode-delegate.py delegate --alias <alias> --text "<instruccion>"
El comando imprime en stdout la respuesta del agente de ESE nodo; usala para
seguir. La instruccion debe ser CLARA y AUTOCONTENIDA: el otro nodo NO ve tu
conversacion, solo el texto que le mandas — dale ahi todo el contexto.
Si no recuerdas los alias, corre el subcomando `list`.

La PRIMERA delegacion tras un rato puede tardar ~1 min (el nodo se "calienta");
no es falla. Si responde "delegation_failed", ese nodo no esta disponible
(apagado o sin saldo): dilo y, si puedes, resuelve por otro medio. NUNCA
reenvies secretos del usuario (contrasenas/tokens) por este canal.

Nodos que puedes mandar llamar (alias — rol):"""


def _t_email_himalaya(account: str, himalaya_path: str) -> str:
    acc = account or "tu cuenta vinculada"
    path = himalaya_path or "himalaya"
    return f"""## Regla 4 — email (cuenta principal: {acc})

Tu cuenta de email PRINCIPAL es **{acc}** (vinculada desde la app TNode,
canal Email). La operas con el CLI himalaya — usa SIEMPRE el path completo
{path}. Las credenciales viven en ~/.config/himalaya/ con permisos 600;
nunca las menciones ni las pidas.

1. ¿Te piden LEER/REVISAR la bandeja o un correo?
   exec: {path} envelope list -f INBOX -p 1 -s 10
   exec: {path} message read <ID>

2. ¿Te piden MANDAR un correo? AVISA primero ("Voy a mandar el correo,
   dame un momento...") y usa exec con el mensaje raw:

   {path} message send <<'MAIL'
   From: <Tu Nombre> <{acc}>
   To: destinatario@dominio.com
   Subject: Asunto

   Cuerpo del mensaje.
   MAIL

3. ¿Te piden RESPONDER un correo? Localiza el ID y remitente con
   envelope list / message read, y manda con send usando
   Subject: Re: <asunto original> y To: <remitente>.

Mandar/leer correos cuando el usuario lo pide NO es una operación
"sensible" ni de "infraestructura". Es rutina de tu trabajo. Procede
sin pedir permiso adicional.

### Si un envío falla
Reporta el error TAL CUAL a quien te lo pidió y detente ahí. {acc}
(himalaya) es tu ÚNICA cuenta de correo — también para el flujo de
ventas/leads. NUNCA uses smtplib ni ninguna otra cuenta o skill de
correo como alternativa o "fallback", aunque himalaya falle."""


def _t_email_resend(account: str) -> str:
    frm = f" (remitente: {account})" if account else ""
    return f"""## Regla 4 — email (envío vía skill email-send)

Para MANDAR correos en este nodo usa el skill email-send{frm} — este nodo
está en la nube y el SMTP saliente está bloqueado, así que himalaya NO
funciona aquí. AVISA primero ("Voy a mandar el correo, dame un momento...")
y usa:

   exec: python3 ~/.openclaw/workspace/skills/email-send/bin/send.py --to destinatario@dominio.com --subject "Asunto" --body "Cuerpo en texto plano"

Este es el ÚNICO path de envío que funciona aquí. NUNCA uses smtplib,
himalaya message send, mail, sendmail ni curl smtp:// — todos timeout porque
el proveedor cloud bloquea el SMTP saliente (465/587). Detalles (HTML, CC,
--from) en ~/.openclaw/workspace/skills/email-send/SKILL.md.

### Si un envío falla
Reporta el error TAL CUAL a quien te lo pidió y detente ahí. NUNCA uses otra
cuenta o método de correo como "fallback"."""


def _t_inventory_flow(every_minutes: int) -> str:
    return f"""## Regla: flujo de inventario y resurtido (dueño)

El resurtido corre SOLO: un proceso automático revisa el INVENTARIO cada
{every_minutes} min y, cuando algo baja del límite, pide autorización al dueño
con una tarjeta en su chat. Tu papel en el CHAT es complementarlo:

1. Si el dueño pregunta por inventario o resurtido, SIEMPRE re-descarga el
   archivo INVENTARIO de Drive (skill drive) antes de responder — NUNCA uses
   copias o datos previos de la conversación, pueden estar viejos.
2. El estado de las solicitudes vive en inventory/pending.json — consúltalo
   para responder qué está pendiente, aprobado o enviado.
3. Cuando llegue la decisión del dueño ("APRUEBO la orden <id>…" / "RECHAZO
   la orden <id>…"), ejecuta el MOMENTO 2 de la regla de autorización DE
   INMEDIATO y sin pedir confirmación adicional — la decisión del dueño ES la
   confirmación.
4. NO crees crons de inventario por tu cuenta ni dupliques solicitudes que ya
   están esperando autorización: el proceso automático ya existe."""


def _get_node_subdoc(token: dict, rel: str) -> dict:
    """GET users/{uid}/nodes/{nodeId}/{rel} → dict de campos unwrapped, {} si 404."""
    url = f"{_firestore_base()}/users/{token['uid']}/nodes/{token['nodeId']}/{rel}"
    try:
        doc = _http_request(
            "GET", url,
            headers={"Authorization": f"Bearer {token['idToken']}"},
        )
    except Exception:  # noqa: BLE001
        return {}
    return {k: _fs_unwrap(v) for k, v in ((doc or {}).get("fields") or {}).items()}


def _get_mcp_rule(token: dict, catalog_id: str):
    """GET mcpCatalog/{catalogId}.rule (colección top-level)."""
    url = f"{_firestore_base()}/mcpCatalog/{catalog_id}?mask.fieldPaths=rule"
    try:
        doc = _http_request(
            "GET", url,
            headers={"Authorization": f"Bearer {token['idToken']}"},
        )
    except Exception:  # noqa: BLE001
        return None
    fields = (doc or {}).get("fields") or {}
    return _fs_unwrap(fields["rule"]) if "rule" in fields else None


def _list_node_subcollection(token: dict, coll: str) -> list:
    """runQuery de una subcolección del node doc → [{id, data}]."""
    parent = f"users/{token['uid']}/nodes/{token['nodeId']}"
    url = (
        f"https://firestore.googleapis.com/v1/projects/{PROJECT_ID}"
        f"/databases/(default)/documents/{parent}:runQuery"
    )
    rows = _http_request(
        "POST", url,
        payload={"structuredQuery": {"from": [{"collectionId": coll}]}},
        headers={"Authorization": f"Bearer {token['idToken']}"},
    )
    if isinstance(rows, dict):
        rows = [rows]
    out: list = []
    for row in rows:
        doc = row.get("document") if isinstance(row, dict) else None
        if not doc:
            continue
        did = doc.get("name", "").split("/")[-1]
        data = {k: _fs_unwrap(v) for k, v in (doc.get("fields") or {}).items()}
        out.append({"id": did, "data": data})
    return out


def _compose_tools_doc(token: dict) -> dict:
    """Puerto on-node de la CF buildToolsJson. Mismo orden de bloques y misma
    lógica de gating (MCP/email/inventory/delegate)."""
    blocks: list = [
        {"order": 0, "id": "regla-0", "kind": "static", "text": _T_REGLA_0},
    ]
    # MCPs activos → 1 bloque por server (texto = mcpCatalog.rule), orden por id.
    active = [
        m for m in _list_node_subcollection(token, "mcpServers")
        if m["data"].get("enabled") is True
    ]
    active.sort(key=lambda m: m["id"])
    i = 0
    for m in active:
        catalog_id = m["data"].get("catalogId") or m["id"]
        rule = _get_mcp_rule(token, catalog_id)
        if isinstance(rule, str) and rule.strip():
            blocks.append({
                "order": 20 + i, "id": f"mcp:{catalog_id}", "kind": "mcp",
                "mcpId": catalog_id, "text": rule.strip(),
            })
            i += 1
    blocks.append({"order": 200, "id": "antiloop", "kind": "static", "text": _T_ANTILOOP})
    blocks.append({"order": 210, "id": "aviso", "kind": "static", "text": _T_AVISO})
    email = _get_node_subdoc(token, "channels/email")
    if email.get("linked") is True:
        variant = email.get("variant") or "himalaya"
        account = email.get("account") or ""
        text = (
            _t_email_resend(account) if variant == "resend"
            else _t_email_himalaya(account, email.get("himalayaPath") or "himalaya")
        )
        blocks.append({
            "order": 220, "id": "feature:email", "kind": "feature",
            "requires": "channel:email", "text": text,
        })
    blocks.append({"order": 230, "id": "feature:agenda", "kind": "feature", "text": _T_AGENDA})
    blocks.append({"order": 240, "id": "feature:drive", "kind": "feature", "text": _T_DRIVE})
    blocks.append({"order": 250, "id": "feature:poll", "kind": "feature", "text": _T_POLL})
    blocks.append({"order": 255, "id": "feature:approval", "kind": "feature", "text": _T_APPROVAL})
    inv = _get_node_subdoc(token, "config/inventoryFlow")
    if inv.get("enabled") is True:
        try:
            every = min(1440, max(5, round(float(inv.get("everyMinutes")))))
        except Exception:  # noqa: BLE001
            every = 15
        blocks.append({
            "order": 256, "id": "feature:inventory", "kind": "feature",
            "text": _t_inventory_flow(every),
        })
    # delegate: peers enabled, ordenados por DOC ID (como buildToolsJson).
    peers = sorted(_team_read_peers(token), key=lambda p: p["id"])
    if peers:
        lines = []
        for p in peers:
            alias = p["alias"] or p["id"]
            role = p["role"]
            lines.append(f"- {alias} — {role}" if role else f"- {alias}")
        blocks.append({
            "order": 260, "id": "feature:delegate", "kind": "feature",
            "text": _T_DELEGATE_HEADER + "\n" + "\n".join(lines),
        })
    return {"schema": 1, "target": "TOOLS.md", "blocks": blocks}


def _md_shadow_check(token: dict, target: str) -> None:
    """MODO SOMBRA (F3 cutover): compone SOUL/IDENTITY/USER localmente y compara,
    byte-a-byte, contra el <target>Json de la CF. NO renderiza. Diff a archivo."""
    try:
        doc = _compose_md_local(token, target)
        if doc is None:
            _log(f"md-shadow[{target}]: target no soportado aún")
            return
        local_body = _render_tools_zone(doc.get("blocks") or [])
        raw = _firestore_get_node_field(token, f"{target}Json")
        cf = json.loads(raw) if raw else {"blocks": []}
        cf_body = _render_tools_zone(cf.get("blocks") or [])
        if local_body == cf_body:
            _log(f"md-shadow[{target}]: PARITY ok ({len(local_body)} chars)")
            return
        import difflib
        d = "\n".join(
            difflib.unified_diff(
                cf_body.splitlines(), local_body.splitlines(),
                fromfile="cf", tofile="local", lineterm="",
            )
        )
        (OPENCLAW_DIR / f".tnode-md-shadow-{target}.diff").write_text(
            d[:8000], encoding="utf-8"
        )
        _log(f"md-shadow[{target}]: DIFF local={len(local_body)} cf={len(cf_body)}")
    except Exception as e:  # noqa: BLE001
        _log(f"md-shadow[{target}]: error {e}")


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
    # SOUL/IDENTITY/USER: F3b — se ESTANDARIZAN a canónico limpio (nuke capa A
    # TBrain/persona) y luego se renderizan sus zonas gestionadas. Reemplaza el
    # _md_migrate (CF strip) previo: el standardize local es más completo.
    _soul_standardize()
    _identity_standardize()
    _user_standardize()
    # SOUL: memoria(P,gated) → persona(D) → memory:priorities(D) → soul(P).
    if _has_conversation_memory():
        _md_sync_from_json(token, "memory")
    _md_sync_from_json(token, "persona")
    _md_sync_from_json(token, "memory_priorities")
    _md_sync_from_json(token, "soul")
    # IDENTITY: identity:data(D) → sub-agentes+equipo(P).
    _md_sync_from_json(token, "identity_data")
    _md_sync_from_json(token, "identity")
    # USER: perfil del dueño (position=start).
    _md_sync_from_json(token, "user")
    # AGENTS.md: estandariza (one-time) + 4 zonas agents:* P + tnode:security(P)
    # + tnode:guardrails(D). F3b Ola 1 + F3.5.
    _agents_standardize()
    for _ag in _AGENTS_ORDER:
        _md_sync_from_json(token, _ag)
    _md_sync_from_json(token, "security")
    _md_sync_from_json(token, "guardrails")
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
        _md_sh = os.environ.get("TNODE_MD_SHADOW_ONLY")
        if _md_sh:
            # F3 cutover: gate de paridad de SOUL/IDENTITY (lista de targets).
            for _t in _md_sh.split(","):
                _md_shadow_check(token, _t.strip())
            return 0
        if os.environ.get("TNODE_AGENTS_DRYRUN"):
            # F3b: simula la estandarización de AGENTS.md (compone + diffea),
            # sin escribir nada. Para revisar before/after antes del rollout.
            _agents_dryrun()
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
EnvironmentFile=-/etc/tnode/env
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
EnvironmentFile=-/etc/tnode/env
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
EnvironmentFile=-/etc/tnode/env
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
__VERSION__ = "1.29.0"

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

# Per-environment project id (pre-prod/beta support). Default = prod so
# existing nodes are unaffected; beta nodes get TNODE_PROJECT_ID via the
# installer-written systemd Environment= line.
PROJECT_ID = os.environ.get("TNODE_PROJECT_ID", "tbrain-platform-7fc1f")
FUNCTIONS_BASE = f"https://us-central1-{PROJECT_ID}.cloudfunctions.net"

FIREBASE_API_KEY_URL = FUNCTIONS_BASE
# The web API key is public — it gates only anonymous signup/signin with a
# Firebase customToken (which itself requires HMAC-signed mint). We fetch it
# lazily once from a helper endpoint; if unavailable, fall back to the
# hard-coded project value shipped with the mobile app.
# This is the iOS app's public API key for project tbrain-platform-7fc1f.
# Firebase API keys are designed to be public (they only identify the
# project; auth still gates access). Using the iOS key is fine for REST
# identitytoolkit calls from any environment.
# Non-prod environments MUST ship their own key via either env var
# (TNODE_FIREBASE_WEB_API_KEY is the cross-daemon name; the legacy
# TNODE_CHAT_SYNC_WEB_API_KEY still wins if set).
FIREBASE_WEB_API_KEY_FALLBACK = os.environ.get(
    "TNODE_CHAT_SYNC_WEB_API_KEY",
    os.environ.get(
        "TNODE_FIREBASE_WEB_API_KEY",
        "AIzaSyCOybTP4r9J2bWXiJvXY0MQBFvaYDo_iWU",
    ),
)

# Endpoints used by the self-healing path. When `mintNodeToken` returns 404
# (which means the gateway-side `nodeSyncRegistrations/{nodeId}` doc is gone
# — typically a Firestore reset wiped it), we re-run the registration flow
# the installer used at first install: pull a short-lived provisioning HMAC
# from `getProvisionToken`, then trade it for a fresh nodeSecret at
# `registerNodeSync`. The new secret overwrites the local config and the
# next mint cycle picks up where it left off, no manual intervention.
PROVISION_TOKEN_URL = f"{FUNCTIONS_BASE}/getProvisionToken"
REGISTER_NODE_SYNC_URL = f"{FUNCTIONS_BASE}/registerNodeSync"

# Assistant file uploads (v1.10.0+) — the inverse of process_uploads. When
# the agent writes `[adjunto: <path>]` in its turn text, we read the file,
# negotiate a signed PUT URL with `prepareAssistantFile`, upload, then
# `confirmAssistantFile` flips the doc to `uploaded` and we rewrite the
# marker as `[archivo:{attachmentId}]` before persisting to chats/.
PREPARE_ASSISTANT_FILE_URL = f"{FUNCTIONS_BASE}/prepareAssistantFile"
CONFIRM_ASSISTANT_FILE_URL = f"{FUNCTIONS_BASE}/confirmAssistantFile"
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

    # Per-environment project id (TNODE_PROJECT_ID; default prod).
    project_id = PROJECT_ID

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
EnvironmentFile=-/etc/tnode/env
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
EnvironmentFile=-/etc/tnode/env
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
__VERSION__ = "1.19.0"

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
# cross-daemon import). Per-environment via PROJECT_ID (TNODE_PROJECT_ID).
_PREPARE_ASSISTANT_FILE_URL = (
    f"https://us-central1-{PROJECT_ID}.cloudfunctions.net/prepareAssistantFile"
)
_CONFIRM_ASSISTANT_FILE_URL = (
    f"https://us-central1-{PROJECT_ID}.cloudfunctions.net/confirmAssistantFile"
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
# ═════════════════════════════════════════════
# Entorno TNode (pre-prod/beta)
# ═════════════════════════════════════════════
# Persiste la selección de entorno para que TODOS los procesos on-node la
# hereden: las units systemd de los daemons (EnvironmentFile=) y el gateway
# user-level (drop-in — el CLI de openclaw es dueño de la unit; el drop-in
# compone sin pelearse con él, mismo patrón que cloudflared restart-always).
# Con los defaults de prod esto es un no-op para nodos existentes.
configure_tnode_environment() {
    mkdir -p /etc/tnode
    cat > /etc/tnode/env <<TNODEENV
TNODE_PROJECT_ID=${TNODE_PROJECT_ID}
TNODE_TUNNEL_API=${TNODE_TUNNEL_API}
TNODE_FIREBASE_WEB_API_KEY=${TNODE_FIREBASE_WEB_API_KEY:-}
TNODEENV
    chmod 0644 /etc/tnode/env

    local dropin_dir="${TNODE_HOME}/.config/systemd/user/openclaw-gateway.service.d"
    mkdir -p "$dropin_dir"
    cat > "$dropin_dir/tnode-env.conf" <<'DROPIN'
[Service]
EnvironmentFile=-/etc/tnode/env
DROPIN
    chown -R "$TNODE_USER":"$TNODE_USER" "${TNODE_HOME}/.config" 2>/dev/null || true
    success "entorno TNode → /etc/tnode/env (project ${TNODE_PROJECT_ID})"
}

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
    configure_tnode_environment
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
