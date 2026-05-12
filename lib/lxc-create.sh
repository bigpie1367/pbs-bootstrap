# shellcheck shell=bash
# Create the PBS LXC via pct.
#
# Uses values exported by config.sh + script-constant defaults from bootstrap.sh.
# IP is taken from config as a bare address (e.g. 10.80.60.200) and combined
# with PBS_IP_CIDR (default /24) since pct net0 needs CIDR notation.

: "${PBS_IP_CIDR:=24}"

lxc_create() {
    if pct status "$PBS_VMID" &>/dev/null; then
        die "LXC $PBS_VMID already exists — bootstrap is one-shot, destroy it first if you really want to recover (pct destroy $PBS_VMID)"
    fi

    local template_path="$PBS_TEMPLATE_STORAGE:vztmpl/$PBS_TEMPLATE"
    if ! pveam list "$PBS_TEMPLATE_STORAGE" 2>/dev/null | awk '{print $1}' | grep -qx "$template_path"; then
        log_info "downloading template $PBS_TEMPLATE"
        pveam update >/dev/null
        pveam download "$PBS_TEMPLATE_STORAGE" "$PBS_TEMPLATE"
    fi

    log_info "creating LXC $PBS_VMID ($PBS_HOSTNAME)"
    pct create "$PBS_VMID" "$template_path" \
        --hostname "$PBS_HOSTNAME" \
        --cores "$PBS_CORES" \
        --memory "$PBS_MEMORY" \
        --rootfs "$PBS_ROOTFS_STORAGE:$PBS_ROOTFS_SIZE" \
        --net0 "name=eth0,bridge=$PBS_BRIDGE,ip=$PBS_IP/$PBS_IP_CIDR,gw=$PBS_GATEWAY" \
        --onboot 1 \
        --unprivileged 1 \
        --features keyctl=1,nesting=0 \
        --ssh-public-keys "$PBS_SSH_PUBKEY_FILE" \
        --start 0

    log_info "starting LXC $PBS_VMID"
    pct start "$PBS_VMID"
}

lxc_wait_network() {
    log_info "waiting for LXC network"
    local i
    for i in {1..30}; do
        if pct exec "$PBS_VMID" -- sh -c 'getent hosts deb.debian.org >/dev/null 2>&1'; then
            log_info "network up after ${i}s"
            return 0
        fi
        sleep 1
    done
    die "LXC network never came up — check pct exec $PBS_VMID -- ip a"
}
