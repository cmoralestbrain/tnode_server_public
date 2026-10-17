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

TNODE_PI_SETUP_VERSION="0.2.0"
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
vPJyY3Nt62VVr6tfH252n/cOd3pIDfyqbVJJv2qzYuFVu77/XfvgduMV23Ds7/CtzL/falu6o1EG
lzrce/BSJe+VvrYU5n6Fx1zyJphGGdsNz5bb6uWsfeud6eeijYqYIO9Zu67waiOfc8Fdb5aivKQz
8hnooQ5nVA5c36I+oBva+LjwUCe2yWu7JutZ3jlHtHAPsYpbk2+GzpQ0Y++4JXcuMdeabpXDLY8E
z9Uq+lCPVDdni/uI51AGlbvY5N+Jj9ggMD0Oeb8eU8eRfFUdK69EenbhgeOVUtVXj1pKIWUmbu2t
1UP1Y2t05wjC39TZiawpBSGLgVhSQnudaUVHfzV/bAezk478SXybl0whJP7yRfdZTXXnXRSHmyaD
k61RfugmlQfk57PHvvF3FJAhqkY/WiuxIjo/QWax4q4UY6bBYbMDqdKG0SvONpmz2ww26zOcG8MR
MVZem1AArrjJxCTcmVEtPmGSpdcxOlb5BbiAj4q3TtSPKuKpZm6qYqNFvcj6HjNvxHl2abfORKel
MgfP2LHdbgdbybSYRTidx7EuL8AbkM6hnBMnN5kahJVjJ37+BOhiBKWRWYX5Xd5B+kRrXeapqJrM
Mi807+MZXFO3R1J7rgf0TStbx2Ry+/z5f/17+p/3dG9vW/391/g/Xo2IKuxuKK60TW+ejkWNXlGo
E1ttFFTWMXAxjFLO5QpnXu7clUfUuM5vlvtud06PEZYhEnf/CTwUUmQRxsh+NNzDvxf95g0dffER
Y4GkSLbxOV22/O+SNzDvTbUw6MjPpaIYJa02UCGcOjvSSr40mS+XiiQ0EUtjjl8anktQLqxjpDv2
S0j9SInACeHllpEUM+TfyweqJyBjElJ0zpbBQnlWw5Neur3o6HH6TUHm9hilMjUyAAc8riwtuYL+
7ARp4aFR7rHWt697puOV9zgotLD/mKpV6BO9OiFwlXWT+CXaTl5nsU6SbN8UztmrxPXUOS0ZsR3w
c1eezKWtmwQZdLVbrE7ykXShrp2eWaw5FY2I+Oc/p8a+oUzZw1vvTnMNyM9qJQiiayJJKRSnxceR
s1sXwrwR6wSzkHBu9MWgLxUGICxcmxNc09fHt95h0hc/U6UN1xRf5YtNh13ArRQ9kviI3s9d/aXa
wsbuliLhGbwN0vM37I9Qz01bXHYl42wLSA7E4ZKNYhGkUbbO+5VvItjsnqqrrX7SZbadrd0/JSou
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
PI_HOST_B64_EOF
}
PI_HOST_EMBEDDED_VERSION="0.1.0"
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
