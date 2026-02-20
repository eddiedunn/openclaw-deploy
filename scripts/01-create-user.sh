#!/usr/bin/env bash
set -euo pipefail

# Create system user for OpenClaw AI agent
# Run as root on the target host

# Source environment configuration
source "$(dirname "$0")/../.env" 2>/dev/null || source "$(dirname "$0")/.env" 2>/dev/null || true

OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
OPENCLAW_HOME="${OPENCLAW_HOME:-/data/openclaw}"
OPENCLAW_SUBUID_START="${OPENCLAW_SUBUID_START:-231072}"
OPENCLAW_SUBUID_COUNT="${OPENCLAW_SUBUID_COUNT:-65536}"

if id "${OPENCLAW_USER}" &>/dev/null; then
    echo "User '${OPENCLAW_USER}' already exists, skipping creation"
else
    useradd --system --create-home --home-dir "${OPENCLAW_HOME}" --shell /usr/sbin/nologin "${OPENCLAW_USER}"
    echo "Created user '${OPENCLAW_USER}' with home ${OPENCLAW_HOME}"
fi

# Setup subuid/subgid for rootless podman (skip if already configured)
if ! grep -q "^${OPENCLAW_USER}:" /etc/subuid 2>/dev/null; then
    echo "${OPENCLAW_USER}:${OPENCLAW_SUBUID_START}:${OPENCLAW_SUBUID_COUNT}" >> /etc/subuid
    echo "${OPENCLAW_USER}:${OPENCLAW_SUBUID_START}:${OPENCLAW_SUBUID_COUNT}" >> /etc/subgid
    echo "Added subuid/subgid mappings (${OPENCLAW_SUBUID_START}:${OPENCLAW_SUBUID_COUNT})"
else
    echo "subuid/subgid already configured"
fi

# Enable lingering so user services start at boot
loginctl enable-linger "${OPENCLAW_USER}"
echo "Enabled lingering for ${OPENCLAW_USER}"

# Ensure XDG_RUNTIME_DIR exists
_UID=$(id -u "${OPENCLAW_USER}")
mkdir -p "/run/user/${_UID}"
chown "${OPENCLAW_USER}:${OPENCLAW_USER}" "/run/user/${_UID}"
echo "XDG_RUNTIME_DIR set up at /run/user/${_UID}"

echo "Done - ${OPENCLAW_USER} user ready"
