#!/usr/bin/env bash
set -euo pipefail

# Multi-instance aware backup for OpenClaw
# Auto-discovers all .openclaw* state dirs and workspace* dirs
# Backs up each profile separately for individual restores

# Source environment configuration
source "${OPENCLAW_HOME:=/data/openclaw}/.env" 2>/dev/null || true

OPENCLAW_HOME="${OPENCLAW_HOME:-/data/openclaw}"
BACKUP_DIR="${OPENCLAW_HOME}/backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

mkdir -p "${BACKUP_DIR}"

backup_count=0

# Discover and back up each instance
# Default instance: .openclaw + workspace
# Named instances: .openclaw-<name> + workspace-<name>

for state_dir in "${OPENCLAW_HOME}"/.openclaw "${OPENCLAW_HOME}"/.openclaw-*; do
    [ -d "${state_dir}" ] || continue

    dir_basename=$(basename "${state_dir}")

    if [ "${dir_basename}" = ".openclaw" ]; then
        instance_name="default"
        workspace_dir="${OPENCLAW_HOME}/workspace"
    else
        instance_name="${dir_basename#.openclaw-}"
        workspace_dir="${OPENCLAW_HOME}/workspace-${instance_name}"
    fi

    BACKUP_FILE="${BACKUP_DIR}/openclaw-${instance_name}-${TIMESTAMP}.tar.gz"

    # Build tar arguments
    tar_args=()
    tar_args+=(-C "${OPENCLAW_HOME}")
    tar_args+=(--exclude='*/logs/*')
    tar_args+=(--exclude='*/*.bak*')
    tar_args+=("${dir_basename}/")

    # Include workspace if it exists
    if [ -d "${workspace_dir}" ]; then
        tar_args+=("$(basename "${workspace_dir}")/")
    fi

    tar czf "${BACKUP_FILE}" "${tar_args[@]}"
    size=$(du -h "${BACKUP_FILE}" | cut -f1)
    echo "Backed up ${instance_name}: ${BACKUP_FILE} (${size})"
    backup_count=$((backup_count + 1))
done

# Also back up port registry and templates
if [ -f "${OPENCLAW_HOME}/.port-registry" ] || [ -d "${OPENCLAW_HOME}/templates" ]; then
    META_BACKUP="${BACKUP_DIR}/openclaw-meta-${TIMESTAMP}.tar.gz"
    meta_args=(-C "${OPENCLAW_HOME}")
    [ -f "${OPENCLAW_HOME}/.port-registry" ] && meta_args+=(".port-registry")
    [ -d "${OPENCLAW_HOME}/templates" ] && meta_args+=("templates/")
    tar czf "${META_BACKUP}" "${meta_args[@]}"
    echo "Backed up meta: ${META_BACKUP} ($(du -h "${META_BACKUP}" | cut -f1))"
fi

# Keep last 14 days of backups
find "${BACKUP_DIR}" -name 'openclaw-*.tar.gz' -mtime +14 -delete

echo "Backup complete: ${backup_count} instance(s) backed up"
