#!/usr/bin/env bash
# pbs-bootstrap — disaster-recover a Proxmox Backup Server LXC from B2 cold storage.
#
# Designed for the worst case: fresh PVE bare-metal install, LAN firewall VM
# (pfSense / OPNsense / …) also gone. Operator needs nothing in the homelab
# except B2 credentials. Bootstrap brings the PBS LXC up and wires it into
# PVE so the operator can do the first restore (typically the LAN firewall)
# from the PVE GUI — after which normal IaC takes over.
#
# Usage (on Proxmox host, web shell or SSH):
#   export B2_PBS_META_KEY_ID=... B2_PBS_META_KEY=...
#   export B2_PBS_KEY_ID=...      B2_PBS_KEY=...
#   curl -sSL https://raw.githubusercontent.com/bigpie1367/pbs-bootstrap/main/bootstrap.sh | bash
#
# Or clone + run locally:
#   git clone https://github.com/bigpie1367/pbs-bootstrap && cd pbs-bootstrap
#   ./bootstrap.sh
#
set -euo pipefail

# --- Script-constant defaults (override via env before running) -------------
: "${PBS_TEMPLATE:=debian-12-standard_12.7-1_amd64.tar.zst}"
: "${PBS_TEMPLATE_STORAGE:=local}"
: "${PBS_MEMORY:=2048}"             # MB
: "${PBS_CORES:=2}"
: "${PBS_REPO_URL:=https://github.com/bigpie1367/pbs-bootstrap}"
: "${PBS_REPO_BRANCH:=main}"
# PBS_ROOTFS_SIZE / PBS_ROOTFS_STORAGE come from bootstrap-config.yml (terraform)
# PBS_SSH_PUBKEY_FILE is an optional fallback when B2 mirror is missing

# --- Locate libs (curl|bash → auto-clone) -----------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
if [[ -z "$SCRIPT_DIR" || ! -d "$SCRIPT_DIR/lib" ]]; then
    command -v git >/dev/null || {
        echo "[bootstrap] git required to bootstrap from curl|bash — install with: apt install -y git" >&2
        exit 1
    }
    echo "[bootstrap] no local lib/ found — cloning $PBS_REPO_URL"
    TMP_CLONE="$(mktemp -d /tmp/pbs-bootstrap.XXXXXX)"
    git clone --depth 1 --branch "$PBS_REPO_BRANCH" "$PBS_REPO_URL" "$TMP_CLONE" >/dev/null
    exec bash "$TMP_CLONE/bootstrap.sh" "$@"
fi

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
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

log_header "Pulling bootstrap-config.yml from B2"
config_pull "$CONFIG_FILE"
config_export "$CONFIG_FILE"

log_header "Configuring host network bridges"
host_network_setup

log_header "Fetching operator SSH keys from B2"
fetch_authorized_keys
install_authorized_keys_on_host

log_header "Applying network shim (host masquerade for LXC)"
network_shim_apply

log_header "Recreating PBS LXC $PBS_VMID"
lxc_create
lxc_wait_network

log_header "Installing Proxmox Backup Server"
pbs_install

log_header "Restoring chunks from B2 (foreground — long-running)"
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
log_info "GUI: https://$PBS_IP:8007  (root password not set — pct exec $PBS_VMID -- passwd root)"
log_info ""
log_info "PVE storage entry '$PBS_PVE_STORAGE_ID' is wired with token '$PBS_TOKEN_USERNAME'."
log_info "Open PVE GUI and restore your LAN firewall VM (pfSense / OPNsense / …) from PBS."
log_info "Once that VM is up, the rest of the homelab can be brought back by GHA + ansible."
