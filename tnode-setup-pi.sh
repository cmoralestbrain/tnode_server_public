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

TNODE_PI_SETUP_VERSION="0.2.3"
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
PI_HOST_EMBEDDED_VERSION="0.4.0"
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
