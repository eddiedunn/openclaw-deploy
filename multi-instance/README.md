# Multi-Instance Management

Run multiple OpenClaw instances on a single host. Each instance gets its own config, credentials, workspace, and ports while sharing a common skills library and container image.

## Architecture

```
<OPENCLAW_HOME>/
├── .openclaw/                          # default instance
├── .openclaw-<name>/                   # additional instances
├── workspace/                          # default workspace
├── workspace-<name>/                   # per-instance workspaces
├── shared/skills/                      # shared skill library
├── templates/                          # quadlet + config templates
├── openclaw-instance.sh                # management script
├── .port-registry                      # port allocation
└── .config/containers/systemd/
    ├── openclaw.container              # default quadlet
    └── openclaw-<name>.container       # per-instance quadlets
```

## Usage

```bash
# Set up the alias (or add to .bashrc)
OC="sudo -u openclaw XDG_RUNTIME_DIR=/run/user/$(id -u openclaw) bash /data/openclaw/openclaw-instance.sh"

$OC list                    # Show all instances with status + ports
$OC create research         # New instance (auto-allocates ports, generates config)
$OC start research          # Start it
$OC stop research           # Stop it
$OC restart research        # Restart it
$OC status research         # Detailed status
$OC logs research 100       # Last 100 log lines
$OC config research         # View config
$OC destroy research        # Remove (with confirmation)
```

> Paths and user are configured in `.env`. The script sources it automatically.

## Port Allocation

Ports are allocated as sequential pairs from the base port in `.env`:

| Instance | Gateway | Bridge |
|----------|---------|--------|
| default  | base    | base+1 |
| 1st new  | base+2  | base+3 |
| 2nd new  | base+4  | base+5 |

All ports bind to `127.0.0.1` only. Access via SSH tunnel:
```bash
ssh -L <port>:127.0.0.1:<port> <host>
```

Allocation is tracked in `.port-registry` (format: `name:gateway:bridge`).

## Shared Skills

Instances share skills through OpenClaw's `skills.load.extraDirs` config mechanism.

**How it works:**

1. Host directory (`shared/skills/`) contains skill folders, each with a `SKILL.md`
2. Mounted read-only at `/home/node/shared-skills` inside each container
3. Config key `skills.load.extraDirs: ["/home/node/shared-skills"]` tells OpenClaw to scan it

**Loading precedence** (highest wins):

| Priority | Source |
|----------|--------|
| 6 | Workspace `skills/` |
| 5 | Project `.agents/skills/` |
| 4 | Personal `~/.agents/skills/` |
| 3 | Managed `~/.openclaw/skills/` (per-instance) |
| 2 | Bundled (built-in) |
| **1** | **Shared (`extraDirs`)** |

Any instance can override a shared skill by placing one with the same name at a higher precedence level. The file watcher monitors `extraDirs` — changes are picked up without restart.

**To designate an authoring instance**, change its quadlet mount from `:ro` to `:rw`.

## Post-Create Setup

Each new instance needs:

**1. Telegram bot** — Create via @BotFather, add token to config:
```bash
podman exec -it openclaw-<name> openclaw channels add --channel telegram --token <TOKEN>
```

**2. LLM auth** — Run the configure wizard:
```bash
podman exec -it openclaw-<name> openclaw configure
```

**3. Device pairing** — Message the bot, then approve:
```bash
podman exec openclaw-<name> openclaw devices approve --latest
```

## Resource Limits

Default and instance limits are set in `.env`:
- **Default instance**: `OPENCLAW_MEMORY_DEFAULT` / `OPENCLAW_CPUS_DEFAULT`
- **New instances**: `OPENCLAW_MEMORY_INSTANCE` / `OPENCLAW_CPUS_INSTANCE`

Override per-instance by editing the quadlet file directly.

## Networking

Each instance uses Podman pasta networking:
- `--bind lan` inside container (pasta forwards via non-loopback `169.254.1.2`)
- `PublishPort=127.0.0.1:PORT:PORT` on host (enforces loopback)
- `gateway.bind: "loopback"` in config (CLI connection URL)

## Troubleshooting

**Instance won't start** — Check status and logs:
```bash
$OC status <name>
$OC logs <name> 100
```

**Skills not loading:**
1. Verify mount: `podman inspect openclaw-<name> | grep shared-skills`
2. Check config: `grep extraDirs <OPENCLAW_HOME>/.openclaw-<name>/openclaw.json`
3. Verify structure: each skill needs `SKILL.md` in its root

**Port conflict** — Check registry vs actual listeners:
```bash
cat .port-registry
ss -tlnp | grep 1878
```
