#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# tnode-setup-pi.sh — installer of a TNode running the **Pi agent** harness.
#
# One node = one harness: this installs a Pi node (Node.js + tnode-pi-host +
# cloudflared). It never installs OpenClaw or its daemons; that is
# tnode-setup-vps.sh. The app sees the same contract as any TNode: tunnel
# `tnode-[beta-]<id>.tbrain.app`, node registration (nodeSecret / mintNodeToken),
# Firestore-first chat, live WS on /ws, model key via pullLLMConfig.
#
# Modes
#   Cloud auto-pair (provisionTNode cloud-init): TNODE_AUTO_PAIR=1 plus
#     TNODE_NODE_ID, TNODE_NODE_SECRET, TNODE_OWNER_UID, TNODE_OP_ID,
#     TNODE_PROGRESS_URL, TNODE_TUNNEL_API, TNODE_TUNNEL_PREFIX,
#     TNODE_PROJECT_ID. Progress heartbeats (HMAC) drive the app's
#     provisioning screen; the tunnel is pinned to TNODE_NODE_ID.
#   Own server (BYO): TNODE_PROJECT_ID (+ optional TNODE_TUNNEL_API). The node
#     registers itself (getProvisionToken → registerNodeSync); the owner links
#     it from the app afterwards.
#
#   Bake (--bake-mode): only the heavy, identity-free part (packages, Node.js,
#     user, cloudflared binary, tnode-pi-host + deps) for a golden snapshot
#     (scripts/tnode-bake-pi.sh). No tunnel, registration, token or services.
#
# Idempotent: re-running keeps the tunnel, the registration and the host token,
# and upgrades tnode-pi-host to the embedded version (skipped when the same
# version is already installed, e.g. on a droplet booted from the snapshot).
#
# Usage:  curl -fsSL <url> | sudo bash [-s -- --bake-mode]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TNODE_PI_SETUP_VERSION="0.2.1"
BAKE_MODE=0
for _arg in "$@"; do
  case "$_arg" in
    --bake-mode) BAKE_MODE=1 ;;
    *) echo "[tnode-pi] unknown argument: $_arg" >&2; exit 2 ;;
  esac
done
NODE_MAJOR="${NODE_MAJOR:-26}"
TNODE_USER="tnode"
TNODE_HOME="/home/${TNODE_USER}"
PI_HOST_HOME="${TNODE_HOME}/pi-host"
PI_HOST_APP="${TNODE_HOME}/pi-host-app"
PI_HOST_ENV="/etc/tnode/pi-host.env"
LOG_PREFIX="[tnode-pi]"

info()    { echo "${LOG_PREFIX} $*"; }
warn()    { echo "${LOG_PREFIX} WARN: $*" >&2; }
die()     { echo "${LOG_PREFIX} ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (sudo)"
: "${HOME:=/root}"; export HOME

# ── Environment ──────────────────────────────────────────────────────────────
TNODE_PROJECT_ID="${TNODE_PROJECT_ID:-tbrain-platform-7fc1f}"
FUNCTIONS_BASE="https://us-central1-${TNODE_PROJECT_ID}.cloudfunctions.net"
case "$TNODE_PROJECT_ID" in
  *beta*) DEFAULT_TUNNEL_API="https://api-beta.tbrain.app/v1/tunnel" ;;
  *)      DEFAULT_TUNNEL_API="https://api.tbrain.app/v1/tunnel" ;;
esac
TNODE_TUNNEL_API="${TNODE_TUNNEL_API:-$DEFAULT_TUNNEL_API}"
TUNNEL_API_URL="${TNODE_TUNNEL_API%/provision}/provision"
PROVISION_TOKEN_URL="${FUNCTIONS_BASE}/getProvisionToken"
REGISTER_NODE_SYNC_URL="${FUNCTIONS_BASE}/registerNodeSync"
MINT_NODE_TOKEN_URL="${FUNCTIONS_BASE}/mintNodeToken"
PULL_LLM_CONFIG_URL="${FUNCTIONS_BASE}/pullLLMConfig"
AUTO_PAIR="${TNODE_AUTO_PAIR:-0}"

[[ "$BAKE_MODE" == "1" ]] && AUTO_PAIR=0
if [[ "$AUTO_PAIR" == "1" ]]; then
  for v in TNODE_NODE_ID TNODE_NODE_SECRET TNODE_OWNER_UID TNODE_OP_ID TNODE_PROGRESS_URL; do
    [[ -n "${!v:-}" ]] || die "auto-pair needs $v"
  done
fi

# Same heartbeat contract as tnode-setup-vps.sh (HMAC of the body with the
# provisioning nodeSecret). No-op outside auto-pair. Never fails the install.
report_progress_heartbeat() {
  [[ "$AUTO_PAIR" == "1" ]] || return 0
  local phase="${1:?phase}" extra_json="${2:-}" body sig
  if [[ -n "$extra_json" ]]; then
    body=$(printf '{"nodeId":"%s","phase":"%s","opId":"%s","extra":%s}' "$TNODE_NODE_ID" "$phase" "$TNODE_OP_ID" "$extra_json")
  else
    body=$(printf '{"nodeId":"%s","phase":"%s","opId":"%s"}' "$TNODE_NODE_ID" "$phase" "$TNODE_OP_ID")
  fi
  sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$TNODE_NODE_SECRET" -hex | awk '{print $2}')
  curl -fsS -X POST -H "Content-Type: application/json" -H "X-HMAC-SHA256: $sig" \
    -H "X-TNode-OpId: $TNODE_OP_ID" -d "$body" "$TNODE_PROGRESS_URL" >/dev/null 2>&1 || true
}

report_progress_heartbeat "install_started"
info "tnode-setup-pi ${TNODE_PI_SETUP_VERSION} — project=${TNODE_PROJECT_ID} auto-pair=${AUTO_PAIR} bake=${BAKE_MODE}"

json_field() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]) or "")' "$1"; }

provision_token() {
  # Short-lived HMAC token from Firebase (the shared HMAC key never leaves it).
  curl -fsS "$PROVISION_TOKEN_URL" --max-time 15
}

# ── 1. Base packages + Node.js ───────────────────────────────────────────────
ensure_packages() {
  export DEBIAN_FRONTEND=noninteractive
  for i in $(seq 1 120); do
    fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
    sleep 1
  done
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates openssl python3 >/dev/null
}

ensure_node() {
  local major=0
  if command -v node >/dev/null 2>&1; then
    major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  fi
  if (( major >= NODE_MAJOR )) && command -v npm >/dev/null 2>&1; then
    info "Node.js $(node --version) ok"
    return 0
  fi
  info "installing Node.js ${NODE_MAJOR} (NodeSource)"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
  info "Node.js $(node --version)"
}

# ── 2. Service user ──────────────────────────────────────────────────────────
ensure_user() {
  id "$TNODE_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$TNODE_USER"
  install -d -o "$TNODE_USER" -g "$TNODE_USER" -m 700 "$PI_HOST_HOME"
  install -d -m 755 /etc/tnode
}

# ── 3. Tunnel ────────────────────────────────────────────────────────────────
TUNNEL_JSON="${PI_HOST_HOME}/tunnel.json"
NODE_ID=""
TUNNEL_DOMAIN=""
TUNNEL_ID=""

ensure_tunnel() {
  if [[ -s "$TUNNEL_JSON" ]]; then
    NODE_ID="$(json_field nodeId < "$TUNNEL_JSON")"
    TUNNEL_DOMAIN="$(json_field domain < "$TUNNEL_JSON")"
    TUNNEL_ID="$(json_field tunnelId < "$TUNNEL_JSON")"
    info "tunnel already provisioned: ${TUNNEL_DOMAIN}"
    return 0
  fi
  local tok ts nonce sig body resp
  tok="$(provision_token)" || die "getProvisionToken failed"
  ts="$(json_field timestamp <<<"$tok")"; nonce="$(json_field nonce <<<"$tok")"; sig="$(json_field signature <<<"$tok")"
  if [[ "$AUTO_PAIR" == "1" ]]; then
    # Pin the tunnel to the provisioning id: droplet, node doc, tunnel and
    # domain share ONE id (same as tnode-setup-vps.sh).
    body="$(printf '{"label":"%s","desiredNodeId":"%s"}' "$(hostname -s)" "$TNODE_NODE_ID")"
  else
    body="$(printf '{"label":"%s"}' "$(hostname -s)")"
  fi
  resp="$(curl -fsS -X POST "$TUNNEL_API_URL" -H "Authorization: Bearer $sig" \
    -H "X-Provision-Timestamp: $ts" -H "X-Provision-Nonce: $nonce" \
    -H "Content-Type: application/json" -d "$body" --max-time 30)" || die "tunnel provisioning failed"
  NODE_ID="$(json_field nodeId <<<"$resp")"
  TUNNEL_DOMAIN="$(json_field domain <<<"$resp")"
  TUNNEL_ID="$(json_field tunnelId <<<"$resp")"
  [[ -n "$NODE_ID" && -n "$TUNNEL_DOMAIN" ]] || die "invalid tunnel response"
  (umask 077; printf '%s' "$resp" | python3 -c '
import json, sys
d = json.load(sys.stdin)
json.dump({"mode": "cloudflare", "tunnelId": d.get("tunnelId"), "nodeId": d.get("nodeId"),
           "domain": d.get("domain"), "token": d.get("token")}, open(sys.argv[1], "w"), indent=2)
' "$TUNNEL_JSON")
  chown "$TNODE_USER:$TNODE_USER" "$TUNNEL_JSON"
  info "tunnel provisioned: ${TUNNEL_DOMAIN}"
}

ensure_cloudflared_binary() {
  if [[ ! -x /usr/local/bin/cloudflared ]]; then
    local arch; arch="$(uname -m)"
    local cfd_arch="amd64"
    case "$arch" in aarch64|arm64) cfd_arch="arm64" ;; armv7*|armhf) cfd_arch="arm" ;; esac
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cfd_arch}" \
      -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
  fi
}

ensure_cloudflared() {
  ensure_cloudflared_binary
  if ! systemctl is-enabled cloudflared >/dev/null 2>&1; then
    local token; token="$(json_field token < "$TUNNEL_JSON")"
    [[ -n "$token" ]] || die "tunnel token missing in ${TUNNEL_JSON}"
    /usr/local/bin/cloudflared service install "$token" >/dev/null 2>&1 || true
  fi
  # Restart=always: Cloudflare can end a connector with exit 0, which
  # on-failure does not retry. StartLimitIntervalSec belongs in [Unit].
  mkdir -p /etc/systemd/system/cloudflared.service.d
  cat > /etc/systemd/system/cloudflared.service.d/restart.conf <<'UNIT'
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=5
UNIT
  systemctl daemon-reload
  systemctl restart cloudflared
  info "cloudflared $(/usr/local/bin/cloudflared --version 2>/dev/null | awk '{print $3}') running"
}

# ── 4. Node registration (nodeSecret) ────────────────────────────────────────
SYNC_JSON="${PI_HOST_HOME}/tnode-chat-sync.json"

ensure_registration() {
  if [[ -s "$SYNC_JSON" ]]; then
    info "node already registered (${NODE_ID})"
    return 0
  fi
  local secret
  if [[ "$AUTO_PAIR" == "1" ]]; then
    # provisionTNode already wrote nodeSyncRegistrations/{nodeId} with this
    # secret before the droplet booted.
    secret="$TNODE_NODE_SECRET"
  else
    local tok ts nonce sig resp
    tok="$(provision_token)" || die "getProvisionToken failed"
    ts="$(json_field timestamp <<<"$tok")"; nonce="$(json_field nonce <<<"$tok")"; sig="$(json_field signature <<<"$tok")"
    resp="$(curl -fsS -X POST "$REGISTER_NODE_SYNC_URL" -H "Content-Type: application/json" \
      -d "$(printf '{"nodeId":"%s","timestamp":"%s","nonce":"%s","signature":"%s"}' "$NODE_ID" "$ts" "$nonce" "$sig")" \
      --max-time 30)" || die "registerNodeSync failed"
    secret="$(json_field nodeSecret <<<"$resp")"
    [[ -n "$secret" ]] || die "registerNodeSync returned no nodeSecret"
  fi
  (umask 077; NODE_SECRET="$secret" python3 - "$SYNC_JSON" <<PY
import json, os, sys, datetime
json.dump({
    "nodeId": "${NODE_ID}",
    "nodeSecret": os.environ["NODE_SECRET"],
    "mintUrl": "${MINT_NODE_TOKEN_URL}",
    "pullUrl": "${PULL_LLM_CONFIG_URL}",
    "projectId": "${TNODE_PROJECT_ID}",
    "harness": "pi",
    "autoPair": "${AUTO_PAIR}" == "1",
    "ownerUid": "${TNODE_OWNER_UID:-}",
    "provisioningNodeId": "${TNODE_NODE_ID:-}",
    "registeredAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}, open(sys.argv[1], "w"), indent=2)
PY
  )
  chown "$TNODE_USER:$TNODE_USER" "$SYNC_JSON"
  info "node registered (${NODE_ID})"
}

# ── 5. tnode-pi-host ─────────────────────────────────────────────────────────
# >>> BEGIN EMBEDDED PI-HOST (generated by scripts/embed_pi_host.py — do not edit by hand)
_pi_host_b64() {
cat <<'PI_HOST_B64_EOF'
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
/zzfILsA2gMA
PI_HOST_B64_EOF
}
PI_HOST_EMBEDDED_VERSION="0.2.0"
# <<< END EMBEDDED PI-HOST

PI_HOST_VERSION_FILE="${PI_HOST_APP}/.installed-version"

install_pi_host() {
  [[ -n "$PI_HOST_EMBEDDED_VERSION" ]] || die "no embedded tnode-pi-host (run scripts/embed_pi_host.py)"
  if [[ -s "$PI_HOST_VERSION_FILE" && "$(cat "$PI_HOST_VERSION_FILE")" == "$PI_HOST_EMBEDDED_VERSION" \
        && -d "${PI_HOST_APP}/node_modules/@earendil-works" ]]; then
    info "tnode-pi-host ${PI_HOST_EMBEDDED_VERSION} already installed (snapshot)"
    return 0
  fi
  local stage; stage="$(mktemp -d)"
  _pi_host_b64 | base64 -d | tar xz -C "$stage"
  rm -rf "${PI_HOST_APP}.new"
  mv "$stage/tnode-pi-host" "${PI_HOST_APP}.new"
  rm -rf "$stage"
  chown -R "$TNODE_USER:$TNODE_USER" "${PI_HOST_APP}.new"
  # npm ci: exact versions from the embedded lockfile. TNode packages come
  # vendored (copied after ci, which would prune them).
  sudo -u "$TNODE_USER" -H bash -c "cd '${PI_HOST_APP}.new' && npm ci --omit=dev --no-audit --no-fund >/dev/null && mkdir -p node_modules/@tbrain && cp -R vendor/@tbrain/* node_modules/@tbrain/"
  rm -rf "$PI_HOST_APP"
  mv "${PI_HOST_APP}.new" "$PI_HOST_APP"
  printf '%s' "$PI_HOST_EMBEDDED_VERSION" > "$PI_HOST_VERSION_FILE"
  chown "$TNODE_USER:$TNODE_USER" "$PI_HOST_VERSION_FILE"
  info "tnode-pi-host ${PI_HOST_EMBEDDED_VERSION} installed"
}

HOST_TOKEN=""
configure_pi_host() {
  local token_file="${PI_HOST_HOME}/token"
  if [[ ! -s "$token_file" ]]; then
    (umask 077; head -c 32 /dev/urandom | base64 | tr -d '/+=\n' > "$token_file")
    chown "$TNODE_USER:$TNODE_USER" "$token_file"
  fi
  HOST_TOKEN="$(cat "$token_file")"
  (umask 077; cat > "$PI_HOST_ENV" <<ENV
PI_HOST_TOKEN=${HOST_TOKEN}
PI_HOST_HOME=${PI_HOST_HOME}
NODE_ENV=production
ENV
  )
  cat > /etc/systemd/system/tnode-pi-host.service <<UNIT
[Unit]
Description=TNode Pi host (Pi agent harness)
After=network-online.target
Wants=network-online.target

[Service]
User=${TNODE_USER}
WorkingDirectory=${PI_HOST_HOME}
EnvironmentFile=${PI_HOST_ENV}
ExecStart=$(command -v node) ${PI_HOST_APP}/dist/main.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable tnode-pi-host >/dev/null 2>&1
  systemctl restart tnode-pi-host
  if [[ "$AUTO_PAIR" != "1" ]]; then
    # An own-server node opens its ports once the owner links it from the app
    # (until then mintNodeToken answers 409 and the host retries every 30s).
    info "tnode-pi-host started — it goes live when you link the node from the app"
    return 0
  fi
  local i
  for i in $(seq 1 90); do
    ss -ltn 2>/dev/null | grep -q ':18790 ' && { info "tnode-pi-host listening (${i}s)"; return 0; }
    sleep 1
  done
  warn "tnode-pi-host not listening after 90s — see: journalctl -u tnode-pi-host"
}

# ── Main ─────────────────────────────────────────────────────────────────────
ensure_packages
ensure_node
ensure_user

if [[ "$BAKE_MODE" == "1" ]]; then
  ensure_cloudflared_binary
  install_pi_host
  python3 - "${TNODE_HOME}/.pi-baked" <<PY
import json, sys, datetime, subprocess
json.dump({
    "installer": "${TNODE_PI_SETUP_VERSION}",
    "piHost": "${PI_HOST_EMBEDDED_VERSION}",
    "node": subprocess.run(["node", "--version"], capture_output=True, text=True).stdout.strip(),
    "cloudflared": subprocess.run(["/usr/local/bin/cloudflared", "--version"], capture_output=True, text=True).stdout.split()[2],
    "bakedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}, open(sys.argv[1], "w"), indent=2)
PY
  chown "$TNODE_USER:$TNODE_USER" "${TNODE_HOME}/.pi-baked"
  info "bake done: $(tr -d '\n' < "${TNODE_HOME}/.pi-baked")"
  exit 0
fi

ensure_tunnel
ensure_cloudflared
ensure_registration
install_pi_host
configure_pi_host

report_progress_heartbeat "tunnel_ready" "$(python3 -c '
import json, sys
print(json.dumps({"tunnelDomain": sys.argv[1], "tunnelId": sys.argv[2],
                  "gatewayToken": sys.argv[3], "serverUrl": "wss://" + sys.argv[1] + "/ws"}))
' "$TUNNEL_DOMAIN" "$TUNNEL_ID" "$HOST_TOKEN")"
report_progress_heartbeat "chat_sync_registered"
report_progress_heartbeat "pairing_ready"

info "done — node ${NODE_ID} at wss://${TUNNEL_DOMAIN}/ws (harness: pi)"
if [[ "$AUTO_PAIR" != "1" ]]; then
  info "link it to your account from the TNode app (node id ${NODE_ID})"
fi
