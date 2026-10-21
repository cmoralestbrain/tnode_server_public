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

TNODE_PI_SETUP_VERSION="0.2.4"
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
PI_HOST_EMBEDDED_VERSION="0.5.0"
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
