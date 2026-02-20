#!/usr/bin/env bash
set -euo pipefail

# Deploy OpenClaw as systemd quadlet service
# Run as root on the target host

# Source environment configuration
source "$(dirname "$0")/../.env" 2>/dev/null || source "$(dirname "$0")/.env" 2>/dev/null || true

OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
OPENCLAW_HOME="${OPENCLAW_HOME:-/data/openclaw}"
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-openclaw:local}"
OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
OPENCLAW_BRIDGE_PORT="${OPENCLAW_BRIDGE_PORT:-18790}"
OPENCLAW_DNS_PRIMARY="${OPENCLAW_DNS_PRIMARY:-100.100.100.100}"
OPENCLAW_DNS_FALLBACK="${OPENCLAW_DNS_FALLBACK:-1.1.1.1}"
OPENCLAW_MEMORY_DEFAULT="${OPENCLAW_MEMORY_DEFAULT:-8g}"
OPENCLAW_CPUS_DEFAULT="${OPENCLAW_CPUS_DEFAULT:-4}"

QUADLET_DIR="${OPENCLAW_HOME}/.config/containers/systemd"
OPENCLAW_UID=$(id -u "${OPENCLAW_USER}")
OPENCLAW_GID=$(id -g "${OPENCLAW_USER}")

# Create quadlet directory
sudo -u "${OPENCLAW_USER}" mkdir -p "${QUADLET_DIR}"
chmod 700 "${OPENCLAW_HOME}/.config" "${OPENCLAW_HOME}/.config/containers" "${QUADLET_DIR}"

# Write quadlet file
cat > "${QUADLET_DIR}/openclaw.container" << QUADLETEOF
# OpenClaw gateway - Podman Quadlet (rootless, hardened)
# Security: ports mapped to 127.0.0.1 only on host

[Unit]
Description=OpenClaw gateway (rootless Podman)
After=network-online.target
Wants=network-online.target

[Container]
Image=${OPENCLAW_IMAGE}
ContainerName=openclaw
UserNS=keep-id

# Loopback-only binding on HOST (security: no LAN exposure)
PublishPort=127.0.0.1:${OPENCLAW_GATEWAY_PORT}:${OPENCLAW_GATEWAY_PORT}
PublishPort=127.0.0.1:${OPENCLAW_BRIDGE_PORT}:${OPENCLAW_BRIDGE_PORT}

# Mount config and workspace
Volume=${OPENCLAW_HOME}/.openclaw:/home/node/.openclaw
Volume=${OPENCLAW_HOME}/workspace:/home/node/.openclaw/workspace

# Environment
EnvironmentFile=${OPENCLAW_HOME}/.openclaw/.env
Environment=HOME=/home/node
Environment=TERM=xterm-256color

# DNS (MagicDNS + fallback)
DNS=${OPENCLAW_DNS_PRIMARY}
DNS=${OPENCLAW_DNS_FALLBACK}

# Resource limits + user mapping (must match host uid:gid)
PodmanArgs=--memory=${OPENCLAW_MEMORY_DEFAULT} --cpus=${OPENCLAW_CPUS_DEFAULT} --user ${OPENCLAW_UID}:${OPENCLAW_GID}

Pull=never
# Use --bind lan inside container; host port mapping enforces loopback
Exec=node dist/index.js gateway --bind lan --port ${OPENCLAW_GATEWAY_PORT}

[Service]
TimeoutStartSec=300
Restart=on-failure

[Install]
WantedBy=default.target
QUADLETEOF

chown "${OPENCLAW_USER}:${OPENCLAW_USER}" "${QUADLET_DIR}/openclaw.container"
chmod 600 "${QUADLET_DIR}/openclaw.container"

echo "Quadlet written to ${QUADLET_DIR}/openclaw.container"
echo ""
echo "To start the service:"
echo "  systemctl --machine ${OPENCLAW_USER}@ --user daemon-reload"
echo "  systemctl --machine ${OPENCLAW_USER}@ --user start openclaw.service"
echo "  systemctl --machine ${OPENCLAW_USER}@ --user enable openclaw.service"
