#!/usr/bin/env bash
set -euo pipefail

# Generate security-hardened OpenClaw configuration
# Run as root on the target host

# Source environment configuration
source "$(dirname "$0")/../.env" 2>/dev/null || source "$(dirname "$0")/.env" 2>/dev/null || true

OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
OPENCLAW_HOME="${OPENCLAW_HOME:-/data/openclaw}"
CONFIG_DIR="${OPENCLAW_HOME}/.openclaw"
WORKSPACE_DIR="${OPENCLAW_HOME}/workspace"

# Create directories
sudo -u "${OPENCLAW_USER}" mkdir -p "${CONFIG_DIR}"
sudo -u "${OPENCLAW_USER}" mkdir -p "${WORKSPACE_DIR}"

# Generate gateway token
GATEWAY_TOKEN=$(openssl rand -hex 32)

# Write openclaw.json
cat > "${CONFIG_DIR}/openclaw.json" << 'CONFIGEOF'
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "auth": {
      "mode": "token"
    },
    "controlUi": {
      "allowInsecureAuth": false,
      "dangerouslyDisableDeviceAuth": false
    }
  },
  "channels": {
    "telegram": {
      "dmPolicy": "pairing",
      "groups": {
        "*": {
          "requireMention": true
        }
      }
    }
  },
  "agents": {
    "defaults": {
      "sandbox": {
        "mode": "all",
        "scope": "agent",
        "workspaceAccess": "ro"
      }
    }
  },
  "tools": {
    "deny": ["gateway", "cron", "sessions_spawn", "sessions_send"],
    "fs": {
      "workspaceOnly": true
    },
    "exec": {
      "security": "deny"
    },
    "elevated": {
      "enabled": false
    }
  },
  "session": {
    "dmScope": "per-channel-peer"
  },
  "discovery": {
    "mdns": {
      "mode": "off"
    }
  },
  "logging": {
    "redactSensitive": "tools"
  }
}
CONFIGEOF

# Write .env
cat > "${CONFIG_DIR}/.env" << ENVEOF
OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}
ANTHROPIC_API_KEY=
ENVEOF

# Set ownership
chown -R "${OPENCLAW_USER}:${OPENCLAW_USER}" "${CONFIG_DIR}"
chown -R "${OPENCLAW_USER}:${OPENCLAW_USER}" "${WORKSPACE_DIR}"

echo "Configuration written to ${CONFIG_DIR}/openclaw.json"
echo "Environment file written to ${CONFIG_DIR}/.env"
echo "Gateway token generated (saved in .env)"
echo ""
echo "NEXT: Add Telegram bot token to ${CONFIG_DIR}/.env"
echo "NEXT: Run OAuth login after container starts"
