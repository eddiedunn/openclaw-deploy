# OpenClaw Deploy

Rootless Podman deployment for [OpenClaw](https://github.com/openclaw/openclaw) — an open-source AI agent platform with Telegram integration.

## Setup

**1. Configure your environment**

```bash
cp .env.example .env
vi .env   # Set your host, IPs, ports, and resource limits
```

All scripts source `.env` automatically. See [.env.example](.env.example) for all available options.

**2. Run deployment scripts (as root on target host)**

```bash
bash scripts/01-create-user.sh     # Create dedicated nologin system user
bash scripts/02-setup-podman.sh    # Configure rootless Podman
bash scripts/03-clone-and-build.sh # Clone source and build container image
bash scripts/04-configure.sh       # Generate hardened config + gateway token
bash scripts/05-deploy-quadlet.sh  # Deploy systemd quadlet (auto-starts on boot)
```

**3. Post-deploy (interactive)**

```bash
# Add Telegram bot — get token from @BotFather
podman exec -it openclaw openclaw channels add --channel telegram --token <TOKEN>

# Run configure wizard — set up Anthropic OAuth
podman exec -it openclaw openclaw configure

# Restart after config changes
systemctl --user restart openclaw.service

# Pair your Telegram account — send any message to bot, then approve
podman exec openclaw openclaw devices approve --latest
```

> All `podman` and `systemctl --user` commands run as the service user. See [Operations](#operations) for the full invocation pattern.

## Operations

Commands run as the service user (configured in `.env`):

```bash
# Service lifecycle
systemctl --user status openclaw.service
systemctl --user restart openclaw.service

# Container logs
podman logs --tail 50 openclaw

# Config changes
podman exec openclaw openclaw config set <key> <value>

# Manual backup
bash backup.sh
```

> **SSH access pattern**: `ssh <host> 'sudo -u <user> XDG_RUNTIME_DIR=/run/user/$(id -u <user>) <command>'`

### Dashboard

The gateway UI is loopback-only. Access via SSH tunnel:

```bash
ssh -L 18789:127.0.0.1:18789 your-server
# Open http://localhost:18789
```

Gateway token is in `<OPENCLAW_HOME>/.openclaw/.env`.

### Backups

Automated daily at 3am via systemd timer. 14-day retention, gzip compressed.

```bash
# Check timer
systemctl --user list-timers

# List backups
ls -lh backups/
```

## Multi-Instance

Run multiple isolated OpenClaw instances sharing a common skills library. See [multi-instance/README.md](multi-instance/README.md) for full documentation.

```bash
# Quick start
bash openclaw-instance.sh create research   # New instance with auto-allocated ports
bash openclaw-instance.sh list              # Show all instances
bash openclaw-instance.sh start research    # Start it
bash openclaw-instance.sh destroy research  # Remove it
```

## Architecture

```
<host>
├── Service user (nologin, rootless Podman with subuid/subgid)
├── Container (quadlet-managed, auto-restart)
│   ├── Gateway:  127.0.0.1:<port>  (loopback only)
│   ├── Bridge:   127.0.0.1:<port>  (loopback only)
│   └── Resources: configurable RAM + CPU limits
├── State: .openclaw/
│   ├── openclaw.json         # Config
│   ├── .env                  # Gateway token
│   ├── agents/               # Auth profiles, sessions
│   ├── credentials/          # Telegram pairing
│   └── sandboxes/            # Agent skills + identity
├── Workspace: workspace/
└── Backups: backups/         # Daily, 14-day retention
```

## Security

| Control | Detail |
|---------|--------|
| Dedicated nologin user | No shell access, isolated home directory |
| Rootless Podman | User namespace isolation via subuid/subgid |
| Loopback-only ports | Host binds to 127.0.0.1, access via SSH tunnel only |
| Token auth | Gateway requires token for all connections |
| Exec denied | `tools.exec.security: "deny"` |
| Dangerous tools denied | `gateway`, `sessions_spawn`, `sessions_send` blocked |
| Sandbox off | Container itself is the isolation boundary |
| Filesystem restricted | `tools.fs.workspaceOnly: true` |
| mDNS off | `discovery.mdns.mode: "off"` |
| Log redaction | `logging.redactSensitive: "tools"` |

## Troubleshooting

<details>
<summary><b>subuid/subgid not configured</b></summary>

**Symptom**: `podman build` fails with `potentially insufficient UIDs or GIDs available in user namespace`.

**Fix**: Add non-overlapping range to `/etc/subuid` and `/etc/subgid`, then:
```bash
podman system reset --force
podman system migrate
```
The reset is critical — without it the UID mapping won't update.
</details>

<details>
<summary><b>Container can't read mounted config (permission denied)</b></summary>

**Symptom**: `Permission denied` on `/home/node/.openclaw/` inside container.

**Cause**: `--userns keep-id` with Dockerfile's `USER node` (UID 1000) doesn't match file ownership.

**Fix**: Add `--user <uid>:<gid>` to quadlet PodmanArgs to match the service user's UID/GID.
</details>

<details>
<summary><b>Gateway unreachable (connection reset)</b></summary>

**Symptom**: `curl http://127.0.0.1:<port>/` returns connection reset.

**Cause**: Podman pasta networking forwards via non-loopback `169.254.1.2`. Gateway bound to loopback rejects it.

**Fix**: Use `--bind lan` in the Exec command (container listens on all interfaces). Enforce loopback at the host level with `PublishPort=127.0.0.1:<port>:<port>`.
</details>

<details>
<summary><b>CLI error: "plaintext ws:// to non-loopback"</b></summary>

**Cause**: `gateway.bind` in config controls both the listener AND the CLI connection URL. With `"lan"`, CLI resolves the LAN IP which fails OpenClaw's security check.

**Fix**: Set `gateway.bind: "loopback"` in config. The quadlet Exec flag (`--bind lan`) independently controls the actual listener.
</details>

<details>
<summary><b>Cron/device pairing errors</b></summary>

Internal tools (cron, etc.) are treated as separate "devices" needing one-time pairing:
```bash
podman exec openclaw openclaw devices approve --latest
```

Also ensure `cron` is not in the `tools.deny` array in config.
</details>

<details>
<summary><b>Docker EACCES in agent sandbox</b></summary>

**Cause**: `sandbox.mode: "all"` tries to spawn Docker containers inside Podman. Docker isn't available.

**Fix**: `openclaw config set agents.defaults.sandbox.mode off` — the Podman container is the sandbox.
</details>
