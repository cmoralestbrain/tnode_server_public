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

TNODE_PI_SETUP_VERSION="0.2.2"
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
PI_HOST_B64_EOF
}
PI_HOST_EMBEDDED_VERSION="0.3.0"
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
