#!/usr/bin/env bash
# update.tbrain.app — non-destructive update wrapper.
#
# Forwards to the canonical installer with --update-only, which refreshes
# embedded daemons + verify scripts + components-manifest WITHOUT rotating
# any secret (gateway.auth.token, nodeSecret, tunnel credentials all stay).
#
# Usage:
#   curl -fsSL https://update.tbrain.app | bash
#   curl -fsSL https://update.tbrain.app | bash -s -- --component tnode-chat-sync
#   curl -fsSL https://update.tbrain.app | bash -s -- --no-smoke-test
#
# Any extra args are forwarded to tnode-setup.sh after --update-only.
set -euo pipefail
exec curl -fsSL https://install.tbrain.app | bash -s -- --update-only --yes "$@"
