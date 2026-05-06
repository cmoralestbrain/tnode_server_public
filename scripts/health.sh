#!/usr/bin/env bash
# health.tbrain.app — node health check + drift detection.
#
# Downloads health-check.py and runs it via python3, piping any extra args
# through. The script reads ~/.openclaw/components-manifest.json (actual
# versions on-disk), optionally fetches updates.tbrain.app/components-manifest-latest.json
# (expected versions for the latest tag), runs every verify_<id>.py it finds
# under ~/.openclaw/verify/, and emits a single JSON document to stdout.
#
# Usage:
#   curl -fsSL https://health.tbrain.app | bash                     # JSON to stdout
#   curl -fsSL https://health.tbrain.app | bash -s -- --no-pretty   # compact
#   curl -fsSL https://health.tbrain.app | bash -s -- --no-fetch-latest
#
# Exit codes (forwarded from health-check.py):
#   0 = all components OK + no blocking drift
#   1 = warn (drift detected or any verify reported warn)
#   2 = fail (any verify reported fail OR fetch latest manifest failed)
set -euo pipefail
# Default goes to raw GitHub because the Free-plan Bulk Redirect on
# install.tbrain.app/* does not preserve $1. Override via env if a path-
# preserving CDN gets configured later.
HEALTH_SCRIPT_URL="${HEALTH_SCRIPT_URL:-https://raw.githubusercontent.com/cmoralestbrain/tnode_server_public/main/scripts/health-check.py}"
exec python3 <(curl -fsSL "$HEALTH_SCRIPT_URL") "$@"
