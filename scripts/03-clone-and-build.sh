#!/usr/bin/env bash
set -euo pipefail

# Clone OpenClaw repo and build container image
# Run as root on the target host

# Source environment configuration
source "$(dirname "$0")/../.env" 2>/dev/null || source "$(dirname "$0")/.env" 2>/dev/null || true

OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
OPENCLAW_HOME="${OPENCLAW_HOME:-/data/openclaw}"
OPENCLAW_SRC="${OPENCLAW_HOME}/openclaw-src"

_UID=$(id -u "${OPENCLAW_USER}")
export XDG_RUNTIME_DIR="/run/user/${_UID}"

if [ -d "${OPENCLAW_SRC}/.git" ]; then
    echo "Repo already cloned, pulling latest..."
    sudo -u "${OPENCLAW_USER}" git -C "${OPENCLAW_SRC}" pull
else
    echo "Cloning OpenClaw..."
    sudo -u "${OPENCLAW_USER}" git clone https://github.com/openclaw/openclaw.git "${OPENCLAW_SRC}"
fi

echo "Building container image (this may take a while)..."
sudo -u "${OPENCLAW_USER}" bash -c "cd ${OPENCLAW_SRC} && XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR} podman build -t openclaw:latest ."

echo "Verifying image..."
sudo -u "${OPENCLAW_USER}" bash -c "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR} podman images openclaw:latest"

echo "Done - OpenClaw image built"
