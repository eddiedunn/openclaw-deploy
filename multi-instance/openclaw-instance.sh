#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# openclaw-instance.sh — Multi-instance management for OpenClaw
# ============================================================================
# Manages multiple OpenClaw instances running as rootless Podman containers
# under a dedicated service user.
#
# Usage: openclaw-instance.sh <command> [args...]
#
# Commands:
#   create  <name>        Create a new OpenClaw instance
#   list                  List all instances with status and ports
#   start   <name>        Start an instance
#   stop    <name>        Stop an instance
#   restart <name>        Restart an instance
#   destroy <name>        Remove an instance (with confirmation)
#   config  <name>        Show or edit instance config
#   status  <name>        Detailed status of an instance
#   logs    <name> [N]    Show recent logs (default 50 lines)
# ============================================================================

# Source environment configuration
source "${OPENCLAW_HOME:=/data/openclaw}/.env" 2>/dev/null || true

OPENCLAW_HOME="${OPENCLAW_HOME:-/data/openclaw}"
OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
OPENCLAW_UID="${OPENCLAW_UID:-$(id -u)}"
OPENCLAW_GID="${OPENCLAW_GID:-$(id -g)}"
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-openclaw:local}"
OPENCLAW_DNS_PRIMARY="${OPENCLAW_DNS_PRIMARY:-100.100.100.100}"
OPENCLAW_DNS_FALLBACK="${OPENCLAW_DNS_FALLBACK:-1.1.1.1}"
OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
OPENCLAW_BRIDGE_PORT="${OPENCLAW_BRIDGE_PORT:-18790}"
OPENCLAW_MEMORY_DEFAULT="${OPENCLAW_MEMORY_DEFAULT:-8g}"
OPENCLAW_CPUS_DEFAULT="${OPENCLAW_CPUS_DEFAULT:-4}"
OPENCLAW_MEMORY_INSTANCE="${OPENCLAW_MEMORY_INSTANCE:-4g}"
OPENCLAW_CPUS_INSTANCE="${OPENCLAW_CPUS_INSTANCE:-2}"

PORT_REGISTRY="${OPENCLAW_HOME}/.port-registry"
TEMPLATE_DIR="${OPENCLAW_HOME}/templates"
QUADLET_DIR="${OPENCLAW_HOME}/.config/containers/systemd"
SHARED_SKILLS="${OPENCLAW_HOME}/shared/skills"

# Default instance port pair
DEFAULT_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT}"
DEFAULT_BRIDGE_PORT="${OPENCLAW_BRIDGE_PORT}"

# Ensure we're running as the service user
if [ "$(id -u)" -ne "${OPENCLAW_UID}" ]; then
    echo "ERROR: This script must run as the ${OPENCLAW_USER} user (uid ${OPENCLAW_UID})." >&2
    echo "       Use: sudo -u ${OPENCLAW_USER} bash -c '${0} ${*}'" >&2
    exit 1
fi

# Ensure XDG_RUNTIME_DIR is set for podman/systemctl
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${OPENCLAW_UID}}"

# ============================================================================
# Helper functions
# ============================================================================

validate_name() {
    local name="$1"
    if [ -z "${name}" ]; then
        echo "ERROR: Instance name is required." >&2
        return 1
    fi
    if ! echo "${name}" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'; then
        echo "ERROR: Invalid name '${name}'. Must be lowercase alphanumeric + hyphens," >&2
        echo "       no leading/trailing hyphens. Examples: dev, test-01, my-bot" >&2
        return 1
    fi
    if [ "${name}" = "default" ]; then
        echo "ERROR: 'default' is reserved for the existing instance." >&2
        return 1
    fi
}

ensure_port_registry() {
    if [ ! -f "${PORT_REGISTRY}" ]; then
        echo "Initializing port registry with existing default instance..."
        echo "default:${DEFAULT_GATEWAY_PORT}:${DEFAULT_BRIDGE_PORT}" > "${PORT_REGISTRY}"
    fi
    # Ensure default is registered (idempotent)
    if ! grep -q '^default:' "${PORT_REGISTRY}"; then
        echo "default:${DEFAULT_GATEWAY_PORT}:${DEFAULT_BRIDGE_PORT}" >> "${PORT_REGISTRY}"
    fi
}

get_instance_ports() {
    local name="$1"
    ensure_port_registry
    grep "^${name}:" "${PORT_REGISTRY}" | head -1
}

allocate_ports() {
    ensure_port_registry
    # Find the highest gateway port in use
    local max_port
    max_port=$(awk -F: '{print $2}' "${PORT_REGISTRY}" | sort -n | tail -1)
    if [ -z "${max_port}" ]; then
        max_port=${DEFAULT_GATEWAY_PORT}
    fi
    # Next available pair (gateway ports are odd-indexed: 18789, 18791, 18793...)
    local next_gateway=$((max_port + 2))
    local next_bridge=$((next_gateway + 1))
    echo "${next_gateway}:${next_bridge}"
}

instance_exists() {
    local name="$1"
    ensure_port_registry
    grep -q "^${name}:" "${PORT_REGISTRY}"
}

get_state_dir() {
    local name="$1"
    if [ "${name}" = "default" ]; then
        echo "${OPENCLAW_HOME}/.openclaw"
    else
        echo "${OPENCLAW_HOME}/.openclaw-${name}"
    fi
}

get_workspace_dir() {
    local name="$1"
    if [ "${name}" = "default" ]; then
        echo "${OPENCLAW_HOME}/workspace"
    else
        echo "${OPENCLAW_HOME}/workspace-${name}"
    fi
}

get_service_name() {
    local name="$1"
    if [ "${name}" = "default" ]; then
        echo "openclaw"
    else
        echo "openclaw-${name}"
    fi
}

get_quadlet_file() {
    local name="$1"
    echo "${QUADLET_DIR}/$(get_service_name "${name}").container"
}

get_service_status() {
    local service
    service="$(get_service_name "$1")"
    if systemctl --user is-active "${service}.service" &>/dev/null; then
        echo "running"
    elif systemctl --user is-failed "${service}.service" &>/dev/null; then
        echo "failed"
    else
        echo "stopped"
    fi
}

# ============================================================================
# Commands
# ============================================================================

cmd_create() {
    local name="${1:-}"
    validate_name "${name}"

    if instance_exists "${name}"; then
        echo "ERROR: Instance '${name}' already exists." >&2
        exit 1
    fi

    # Check templates exist
    if [ ! -f "${TEMPLATE_DIR}/openclaw-instance.container.tmpl" ]; then
        echo "ERROR: Quadlet template not found at ${TEMPLATE_DIR}/openclaw-instance.container.tmpl" >&2
        exit 1
    fi
    if [ ! -f "${TEMPLATE_DIR}/openclaw-config.json.tmpl" ]; then
        echo "ERROR: Config template not found at ${TEMPLATE_DIR}/openclaw-config.json.tmpl" >&2
        exit 1
    fi

    # Allocate ports
    local ports
    ports=$(allocate_ports)
    local gateway_port="${ports%%:*}"
    local bridge_port="${ports##*:}"

    local state_dir
    state_dir=$(get_state_dir "${name}")
    local workspace_dir
    workspace_dir=$(get_workspace_dir "${name}")
    local quadlet_file
    quadlet_file=$(get_quadlet_file "${name}")

    echo "Creating OpenClaw instance '${name}'..."
    echo "  Gateway port: ${gateway_port}"
    echo "  Bridge port:  ${bridge_port}"
    echo "  State dir:    ${state_dir}"
    echo "  Workspace:    ${workspace_dir}"
    echo ""

    # Create directories
    mkdir -p "${state_dir}"
    mkdir -p "${workspace_dir}"
    mkdir -p "${SHARED_SKILLS}"
    mkdir -p "${QUADLET_DIR}"

    # Generate config from template
    sed -e "s/{{GATEWAY_PORT}}/${gateway_port}/g" \
        -e "s/{{BRIDGE_PORT}}/${bridge_port}/g" \
        "${TEMPLATE_DIR}/openclaw-config.json.tmpl" \
        > "${state_dir}/openclaw.json"
    chmod 600 "${state_dir}/openclaw.json"
    echo "  Created config: ${state_dir}/openclaw.json"

    # Generate .env with new gateway token
    local token
    token=$(openssl rand -hex 16)
    echo "OPENCLAW_GATEWAY_TOKEN=${token}" > "${state_dir}/.env"
    chmod 600 "${state_dir}/.env"
    echo "  Created .env:   ${state_dir}/.env"

    # Generate quadlet from template
    sed -e "s|{{NAME}}|${name}|g" \
        -e "s|{{GATEWAY_PORT}}|${gateway_port}|g" \
        -e "s|{{BRIDGE_PORT}}|${bridge_port}|g" \
        -e "s|{{DNS_PRIMARY}}|${OPENCLAW_DNS_PRIMARY}|g" \
        -e "s|{{DNS_FALLBACK}}|${OPENCLAW_DNS_FALLBACK}|g" \
        -e "s|{{MEMORY}}|${OPENCLAW_MEMORY_INSTANCE}|g" \
        -e "s|{{CPUS}}|${OPENCLAW_CPUS_INSTANCE}|g" \
        -e "s|{{IMAGE}}|${OPENCLAW_IMAGE}|g" \
        -e "s|{{USER_MAPPING}}|${OPENCLAW_UID}:${OPENCLAW_GID}|g" \
        -e "s|{{OPENCLAW_HOME}}|${OPENCLAW_HOME}|g" \
        "${TEMPLATE_DIR}/openclaw-instance.container.tmpl" \
        > "${quadlet_file}"
    chmod 644 "${quadlet_file}"
    echo "  Created quadlet: ${quadlet_file}"

    # Register in port registry
    echo "${name}:${gateway_port}:${bridge_port}" >> "${PORT_REGISTRY}"
    echo "  Registered in port registry"

    # Reload systemd
    systemctl --user daemon-reload
    echo "  Systemd daemon reloaded"

    echo ""
    echo "Instance '${name}' created successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Start the instance:"
    echo "     openclaw-instance.sh start ${name}"
    echo ""
    echo "  2. Configure Telegram bot (if needed):"
    echo "     openclaw-instance.sh config ${name}"
    echo "     Add channels.telegram section with your bot token"
    echo ""
    echo "  3. Configure auth provider:"
    echo "     openclaw-instance.sh config ${name}"
    echo "     Add auth.profiles section with your API key"
    echo ""
    echo "  4. Check status:"
    echo "     openclaw-instance.sh status ${name}"
}

cmd_list() {
    ensure_port_registry

    printf "%-15s %-10s %-8s %-8s %-12s %s\n" \
        "INSTANCE" "STATUS" "GATEWAY" "BRIDGE" "CONTAINER" "STATE DIR"
    printf "%-15s %-10s %-8s %-8s %-12s %s\n" \
        "--------" "------" "-------" "------" "---------" "---------"

    while IFS=: read -r name gw_port br_port; do
        [ -z "${name}" ] && continue
        local status
        status=$(get_service_status "${name}")
        local container_name
        container_name=$(get_service_name "${name}")
        local state_dir
        state_dir=$(get_state_dir "${name}")

        # Color status
        local status_display
        case "${status}" in
            running) status_display="\033[32m${status}\033[0m" ;;
            failed)  status_display="\033[31m${status}\033[0m" ;;
            *)       status_display="\033[33m${status}\033[0m" ;;
        esac

        printf "%-15s %-10b %-8s %-8s %-12s %s\n" \
            "${name}" "${status_display}" "${gw_port}" "${br_port}" \
            "${container_name}" "${state_dir}"
    done < "${PORT_REGISTRY}"
}

cmd_start() {
    local name="${1:-}"
    if [ -z "${name}" ]; then
        echo "ERROR: Instance name is required." >&2
        echo "Usage: openclaw-instance.sh start <name>" >&2
        exit 1
    fi

    if ! instance_exists "${name}"; then
        echo "ERROR: Instance '${name}' not found. Use 'list' to see available instances." >&2
        exit 1
    fi

    local service
    service="$(get_service_name "${name}")"
    echo "Starting ${service}.service..."
    systemctl --user start "${service}.service"
    echo "Started. Check with: openclaw-instance.sh status ${name}"
}

cmd_stop() {
    local name="${1:-}"
    if [ -z "${name}" ]; then
        echo "ERROR: Instance name is required." >&2
        echo "Usage: openclaw-instance.sh stop <name>" >&2
        exit 1
    fi

    if ! instance_exists "${name}"; then
        echo "ERROR: Instance '${name}' not found. Use 'list' to see available instances." >&2
        exit 1
    fi

    local service
    service="$(get_service_name "${name}")"
    echo "Stopping ${service}.service..."
    systemctl --user stop "${service}.service"
    echo "Stopped."
}

cmd_restart() {
    local name="${1:-}"
    if [ -z "${name}" ]; then
        echo "ERROR: Instance name is required." >&2
        echo "Usage: openclaw-instance.sh restart <name>" >&2
        exit 1
    fi

    if ! instance_exists "${name}"; then
        echo "ERROR: Instance '${name}' not found. Use 'list' to see available instances." >&2
        exit 1
    fi

    local service
    service="$(get_service_name "${name}")"
    echo "Restarting ${service}.service..."
    systemctl --user restart "${service}.service"
    echo "Restarted. Check with: openclaw-instance.sh status ${name}"
}

cmd_destroy() {
    local name="${1:-}"
    if [ -z "${name}" ]; then
        echo "ERROR: Instance name is required." >&2
        echo "Usage: openclaw-instance.sh destroy <name>" >&2
        exit 1
    fi

    if [ "${name}" = "default" ]; then
        echo "ERROR: Cannot destroy the default instance." >&2
        exit 1
    fi

    if ! instance_exists "${name}"; then
        echo "ERROR: Instance '${name}' not found. Use 'list' to see available instances." >&2
        exit 1
    fi

    local state_dir
    state_dir=$(get_state_dir "${name}")
    local workspace_dir
    workspace_dir=$(get_workspace_dir "${name}")
    local quadlet_file
    quadlet_file=$(get_quadlet_file "${name}")
    local ports_line
    ports_line=$(get_instance_ports "${name}")

    echo "WARNING: This will destroy instance '${name}'."
    echo "  Quadlet:   ${quadlet_file}"
    echo "  State dir: ${state_dir}"
    echo "  Workspace: ${workspace_dir}"
    echo ""
    read -rp "Are you sure? [y/N] " confirm
    if [ "${confirm}" != "y" ] && [ "${confirm}" != "Y" ]; then
        echo "Aborted."
        exit 0
    fi

    # Stop the service if running
    local service
    service="$(get_service_name "${name}")"
    if systemctl --user is-active "${service}.service" &>/dev/null; then
        echo "Stopping ${service}.service..."
        systemctl --user stop "${service}.service"
    fi

    # Remove quadlet file
    if [ -f "${quadlet_file}" ]; then
        rm -f "${quadlet_file}"
        echo "Removed quadlet: ${quadlet_file}"
    fi

    # Reload systemd
    systemctl --user daemon-reload

    # Ask about data removal
    echo ""
    read -rp "Also remove state dir (${state_dir})? [y/N] " rm_state
    if [ "${rm_state}" = "y" ] || [ "${rm_state}" = "Y" ]; then
        rm -rf "${state_dir}"
        echo "Removed state dir."
    fi

    read -rp "Also remove workspace (${workspace_dir})? [y/N] " rm_workspace
    if [ "${rm_workspace}" = "y" ] || [ "${rm_workspace}" = "Y" ]; then
        rm -rf "${workspace_dir}"
        echo "Removed workspace dir."
    fi

    # Remove from port registry
    local tmp_registry="${PORT_REGISTRY}.tmp"
    grep -v "^${name}:" "${PORT_REGISTRY}" > "${tmp_registry}" || true
    mv "${tmp_registry}" "${PORT_REGISTRY}"
    echo "Removed from port registry."

    echo ""
    echo "Instance '${name}' destroyed."
}

cmd_config() {
    local name="${1:-}"
    if [ -z "${name}" ]; then
        echo "ERROR: Instance name is required." >&2
        echo "Usage: openclaw-instance.sh config <name>" >&2
        exit 1
    fi

    if ! instance_exists "${name}"; then
        echo "ERROR: Instance '${name}' not found. Use 'list' to see available instances." >&2
        exit 1
    fi

    local state_dir
    state_dir=$(get_state_dir "${name}")
    local config_file="${state_dir}/openclaw.json"

    if [ ! -f "${config_file}" ]; then
        echo "ERROR: Config file not found at ${config_file}" >&2
        exit 1
    fi

    echo "Config file: ${config_file}"
    echo ""

    if [ -n "${EDITOR:-}" ] && [ -t 0 ] && [ -t 1 ]; then
        read -rp "Open in ${EDITOR}? [y/N] " open_editor
        if [ "${open_editor}" = "y" ] || [ "${open_editor}" = "Y" ]; then
            "${EDITOR}" "${config_file}"
            exit 0
        fi
    fi

    cat "${config_file}"
}

cmd_status() {
    local name="${1:-}"
    if [ -z "${name}" ]; then
        echo "ERROR: Instance name is required." >&2
        echo "Usage: openclaw-instance.sh status <name>" >&2
        exit 1
    fi

    if ! instance_exists "${name}"; then
        echo "ERROR: Instance '${name}' not found. Use 'list' to see available instances." >&2
        exit 1
    fi

    local service
    service="$(get_service_name "${name}")"
    local container_name="${service}"
    local state_dir
    state_dir=$(get_state_dir "${name}")
    local ports_line
    ports_line=$(get_instance_ports "${name}")
    local gateway_port
    gateway_port=$(echo "${ports_line}" | cut -d: -f2)
    local bridge_port
    bridge_port=$(echo "${ports_line}" | cut -d: -f3)

    echo "=== OpenClaw Instance: ${name} ==="
    echo ""
    echo "Ports:     gateway=${gateway_port}, bridge=${bridge_port}"
    echo "State:     ${state_dir}"
    echo "Workspace: $(get_workspace_dir "${name}")"
    echo "Quadlet:   $(get_quadlet_file "${name}")"
    echo ""
    echo "--- systemctl status ---"
    systemctl --user status "${service}.service" --no-pager 2>&1 || true
    echo ""

    # Container inspect (if running)
    if podman container exists "${container_name}" 2>/dev/null; then
        echo "--- container inspect (summary) ---"
        podman inspect "${container_name}" --format '{{.State.Status}} since {{.State.StartedAt}}' 2>/dev/null || true
        podman inspect "${container_name}" --format 'PID={{.State.Pid}} Memory={{.HostConfig.Memory}} CPUs={{.HostConfig.NanoCpus}}' 2>/dev/null || true
    fi
}

cmd_logs() {
    local name="${1:-}"
    if [ -z "${name}" ]; then
        echo "ERROR: Instance name is required." >&2
        echo "Usage: openclaw-instance.sh logs <name> [lines]" >&2
        exit 1
    fi

    local lines="${2:-50}"

    if ! instance_exists "${name}"; then
        echo "ERROR: Instance '${name}' not found. Use 'list' to see available instances." >&2
        exit 1
    fi

    local service
    service="$(get_service_name "${name}")"
    journalctl --user -u "${service}.service" --no-pager -n "${lines}"
}

cmd_help() {
    echo "Usage: openclaw-instance.sh <command> [args...]"
    echo ""
    echo "Commands:"
    echo "  create  <name>        Create a new OpenClaw instance"
    echo "  list                  List all instances with status and ports"
    echo "  start   <name>        Start an instance"
    echo "  stop    <name>        Stop an instance"
    echo "  restart <name>        Restart an instance"
    echo "  destroy <name>        Remove an instance (with confirmation)"
    echo "  config  <name>        Show or edit instance config"
    echo "  status  <name>        Detailed status of an instance"
    echo "  logs    <name> [N]    Show recent logs (default 50 lines)"
    echo ""
    echo "The 'default' instance refers to the original OpenClaw deployment."
    echo "Instance names must be lowercase alphanumeric with optional hyphens."
    echo ""
    echo "Examples:"
    echo "  openclaw-instance.sh create dev"
    echo "  openclaw-instance.sh start dev"
    echo "  openclaw-instance.sh logs dev 100"
    echo "  openclaw-instance.sh destroy dev"
}

# ============================================================================
# Main dispatch
# ============================================================================

command="${1:-help}"
shift || true

case "${command}" in
    create)  cmd_create "$@" ;;
    list)    cmd_list "$@" ;;
    start)   cmd_start "$@" ;;
    stop)    cmd_stop "$@" ;;
    restart) cmd_restart "$@" ;;
    destroy) cmd_destroy "$@" ;;
    config)  cmd_config "$@" ;;
    status)  cmd_status "$@" ;;
    logs)    cmd_logs "$@" ;;
    help|-h|--help) cmd_help ;;
    *)
        echo "ERROR: Unknown command '${command}'" >&2
        echo "" >&2
        cmd_help >&2
        exit 1
        ;;
esac
