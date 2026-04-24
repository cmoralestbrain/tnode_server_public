# TNode Installer

One command to turn any VPS, Mac Mini, or Raspberry Pi into a private AI node
accessible from the [TNode iOS app](https://tbrain.app).

## Quick Install

```bash
curl -fsSL https://install.tbrain.app | bash
```

No flags required. The installer auto-detects your hardware and configures
everything (LLM runtime, gateway, Cloudflare Tunnel, pairing, telemetry).

## Requirements

| Hardware | Minimum |
|----------|---------|
| **RAM** | 1 GB (VPS) · 8 GB recommended for local LLM |
| **Disk** | 5 GB free |
| **OS** | Ubuntu 22.04+ / Debian 12+ / macOS 13+ / Raspberry Pi OS Bookworm |
| **Network** | Outbound HTTPS to Cloudflare, Firebase, and your LLM provider |

GPU is optional. If detected, the installer provisions a local model via
Ollama; otherwise it falls back to a cloud provider over HTTPS.

## Variants

```bash
# Default (auto-detect, Cloudflare Tunnel, no LAN exposure)
curl -fsSL https://install.tbrain.app | bash

# Bring your own OpenRouter key
curl -fsSL https://install.tbrain.app | bash -s -- --api openrouter --api-key sk-or-v1-...

# Local-network only (no tunnel; pair over Tailscale)
curl -fsSL https://install.tbrain.app | bash -s -- --no-tunnel --with-tailscale
```

Pass `--help` for the full flag list.

## Pairing

At the end of the install a QR code is printed. Scan it with the TNode app to
complete device pairing.

## Support

- App: [tbrain.app](https://tbrain.app)
- Issues with the installer: open one in this repo.

## License

Proprietary — TBrain Platform. All rights reserved.
