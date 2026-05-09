#!/usr/bin/env bash
# uninstall.tbrain.app — local-only TNode teardown.
#
# Forwards to the canonical installer with --uninstall, which stops and
# removes every systemd/launchd unit the installer creates (cloudflared,
# tnode-chat-sync, tnode-config-sync, tnode-telemetry, tnode-llm-config-watcher,
# pair-watch, tnode-config-sync-watch) and deletes ~/.openclaw.
#
# Does NOT touch server-side state. Cloudflare tunnel + DNS + Firestore
# docs (`users/{uid}/nodes/{nodeId}` + `nodeSyncRegistrations/{nodeId}`)
# are owned by the `deleteAgent` callable in tnode_client/functions and
# are torn down from the mobile app's "Eliminar nodo" flow. Run that
# BEFORE this script for a clean teardown; otherwise tunnel + Firestore
# residue persists until `cleanupOrphanedTunnels` (admin-only) prunes it.
#
# Usage:
#   curl -fsSL https://uninstall.tbrain.app | bash               # interactive prompt
#   curl -fsSL https://uninstall.tbrain.app | bash -s -- --yes   # non-interactive
#   curl -fsSL https://uninstall.tbrain.app | bash -s -- --yes --purge-binaries
#
# Any extra args are forwarded to tnode-setup.sh after --uninstall.
set -euo pipefail
exec curl -fsSL https://install.tbrain.app | bash -s -- --uninstall "$@"
