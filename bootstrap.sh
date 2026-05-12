#!/usr/bin/env bash
# pbs-bootstrap — disaster-recover a Proxmox Backup Server LXC from B2 cold storage.
#
# Designed for the worst case: fresh PVE bare-metal install, LAN firewall VM
# also gone. Operator needs nothing in the homelab except B2 credentials.
# Bootstrap brings the PBS LXC up and wires it into PVE so the operator can
# browse and restore backups from the PVE GUI. Anything past that point is
# the operator's playbook, out of scope here.
#
# Usage (on Proxmox host, web shell or SSH):
#
#   # Source URIs — each accepts:
#   #   b2://bucket/path | s3://bucket/path | github:owner/repo/branch/path
#   #   | https://... | /abs/path | (auth_keys only) <github-user> | skip
#   export PBS_CONFIG=b2://my-pbs-meta/bootstrap-config.yml
#   export PBS_AUTH_KEYS=myuser
#
#   # Chunks credentials (always required)
#   export PBS_CHUNKS_KEY_ID=... PBS_CHUNKS_KEY=...
#
#   # Meta credentials (only if PBS_CONFIG or PBS_AUTH_KEYS uses b2:// / s3://)
#   export PBS_META_KEY_ID=...   PBS_META_KEY=...
#
#   bash <(curl -sSL https://raw.githubusercontent.com/bigpie1367/pbs-bootstrap/main/bootstrap.sh)
#
set -euo pipefail

# --- Script-constant defaults (override via env before running) -------------
: "${PBS_TEMPLATE:=debian-12-standard_12.12-1_amd64.tar.zst}"
: "${PBS_TEMPLATE_STORAGE:=local}"
: "${PBS_REPO_URL:=https://github.com/bigpie1367/pbs-bootstrap}"
: "${PBS_REPO_BRANCH:=main}"
: "${PBS_STORAGE_TYPE:=b2}"          # b2 | s3 — env wins; mismatch with config caught at config_export
# PBS_STORAGE_ENDPOINT / PBS_STORAGE_REGION required when type=s3
# PBS_ROOTFS_SIZE / PBS_ROOTFS_STORAGE / PBS_CORES / PBS_MEMORY_DEDICATED /
# PBS_MEMORY_SWAP all come from bootstrap-config.yml (terraform outputs).

# --- Locate libs (curl|bash → auto-clone) -----------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
if [[ -z "$SCRIPT_DIR" || ! -d "$SCRIPT_DIR/lib" ]]; then
    # Download tarball — uses curl + tar (always present on PVE). Avoids
    # making git a hard prereq just for the curl|bash bootstrap flow.
    TMP_CLONE="$(mktemp -d /tmp/pbs-bootstrap.XXXXXX)"
    echo "[bootstrap] fetching $PBS_REPO_URL @ $PBS_REPO_BRANCH"
    curl -fsSL "${PBS_REPO_URL}/archive/refs/heads/${PBS_REPO_BRANCH}.tar.gz" \
        | tar xz -C "$TMP_CLONE" --strip-components=1
    exec bash "$TMP_CLONE/bootstrap.sh" "$@"
fi

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/tui.sh
source "$SCRIPT_DIR/lib/tui.sh"
# shellcheck source=lib/source-resolver.sh
source "$SCRIPT_DIR/lib/source-resolver.sh"
# shellcheck source=lib/interactive.sh
source "$SCRIPT_DIR/lib/interactive.sh"
# shellcheck source=lib/preflight.sh
source "$SCRIPT_DIR/lib/preflight.sh"
# shellcheck source=lib/host-apt.sh
source "$SCRIPT_DIR/lib/host-apt.sh"
# shellcheck source=lib/rclone-setup.sh
source "$SCRIPT_DIR/lib/rclone-setup.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/host-network.sh
source "$SCRIPT_DIR/lib/host-network.sh"
# shellcheck source=lib/host-ssh.sh
source "$SCRIPT_DIR/lib/host-ssh.sh"
# shellcheck source=lib/network-bridge.sh
source "$SCRIPT_DIR/lib/network-bridge.sh"
# shellcheck source=lib/lxc-create.sh
source "$SCRIPT_DIR/lib/lxc-create.sh"
# shellcheck source=lib/pbs-install.sh
source "$SCRIPT_DIR/lib/pbs-install.sh"
# shellcheck source=lib/chunks-restore.sh
source "$SCRIPT_DIR/lib/chunks-restore.sh"
# shellcheck source=lib/datastore-init.sh
source "$SCRIPT_DIR/lib/datastore-init.sh"
# shellcheck source=lib/pbs-auth.sh
source "$SCRIPT_DIR/lib/pbs-auth.sh"
# shellcheck source=lib/pve-storage.sh
source "$SCRIPT_DIR/lib/pve-storage.sh"

# --- Pipeline ----------------------------------------------------------------

# Interactive collection (TTY + whiptail) OR env-only validation.
if [[ -t 0 ]] && command -v whiptail >/dev/null 2>&1; then
    interactive_collect
fi

log_header "PBS bootstrap"
preflight_check

CONFIG_FILE="$(mktemp /tmp/pbs-bootstrap-config.XXXXXX.yml)"
cleanup() {
    rm -f "$CONFIG_FILE" 2>/dev/null || true
    rm -f "${AUTH_KEYS_FILE:-}" 2>/dev/null || true
    network_shim_teardown
}
trap cleanup EXIT

log_header "Fixing host apt repos + installing bootstrap deps"
host_apt_setup

log_header "Configuring rclone on host"
rclone_setup_host

log_header "Pulling bootstrap-config.yml"
config_pull "$CONFIG_FILE"
config_export "$CONFIG_FILE"

log_header "Configuring host network bridges"
host_network_setup

log_header "Fetching operator SSH keys"
fetch_authorized_keys
install_authorized_keys_on_host

log_header "Applying network shim (host masquerade for LXC)"
network_shim_apply

log_header "Recreating PBS LXC $PBS_VMID"
lxc_create
lxc_wait_network

log_header "Installing Proxmox Backup Server"
pbs_install

log_header "Restoring chunks (foreground — long-running)"
chunks_restore

log_header "Registering datastore $PBS_DATASTORE_NAME with PBS"
datastore_init

log_header "Setting up PBS API user / token / ACL"
pbs_auth_setup

log_header "Wiring PVE storage entry to PBS"
pve_storage_sync

log_header "Restoring LXC network to declared state"
network_shim_restore_lxc

log_header "Done"
log_info "PBS LXC $PBS_VMID is up at $PBS_IP, datastore $PBS_DATASTORE_NAME registered"
log_info "PVE storage entry '$PBS_PVE_STORAGE_ID' wired with token '$PBS_TOKEN_USERNAME'"
log_info ""
log_info "Verify in PVE GUI: Datacenter → Storage → $PBS_PVE_STORAGE_ID should list backup groups."
log_info "Bootstrap is finished. Anything beyond this point is your operator playbook."
