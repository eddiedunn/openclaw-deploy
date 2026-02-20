#!/usr/bin/env bash
set -euo pipefail

# Configure rootless podman for the OpenClaw service user
# Run as root on the target host

# Source environment configuration
source "$(dirname "$0")/../.env" 2>/dev/null || source "$(dirname "$0")/.env" 2>/dev/null || true

OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
OPENCLAW_HOME="${OPENCLAW_HOME:-/data/openclaw}"

# Create podman config directories
sudo -u "${OPENCLAW_USER}" mkdir -p "${OPENCLAW_HOME}/.config/containers"
sudo -u "${OPENCLAW_USER}" mkdir -p "${OPENCLAW_HOME}/.local/share/containers"

# Verify rootless podman works
echo "Testing rootless podman..."
sudo -u "${OPENCLAW_USER}" bash -c "XDG_RUNTIME_DIR=/run/user/\$(id -u) podman info --format '{{.Host.Security.Rootless}}'" | grep -q true
echo "Rootless podman verified"

echo "Done - podman configured for ${OPENCLAW_USER}"
