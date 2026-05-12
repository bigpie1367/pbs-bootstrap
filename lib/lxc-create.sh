# shellcheck shell=bash
# Create the PBS LXC via pct.
#
# Values from bootstrap-config.yml drive:
#   - vmid, hostname, bridge, ip, gateway (network)
#   - rootfs_size, rootfs_storage (disk)
#
# Values from script-constants / env (memory, cores) cover anything not in
# the steady-state config.
#
# IP is taken from config as a bare address; it's combined with PBS_IP_CIDR
# (default /24) since pct net0 needs CIDR notation.
#
# The SSH pubkey source is $AUTH_KEYS_FILE, prepared by host-ssh.sh.
# network-bridge.sh may override PBS_GATEWAY_OVERRIDE / PBS_DNS_OVERRIDE to
# route the LXC through the host while the real LAN gateway is dead.

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

    local gateway="${PBS_GATEWAY_OVERRIDE:-$PBS_GATEWAY}"
    local extra_args=()
    if [[ -n "${PBS_DNS_OVERRIDE:-}" ]]; then
        extra_args+=(--nameserver "$PBS_DNS_OVERRIDE")
    fi
    # PBS_AUTH_KEYS=skip resolves to an empty file. pct create rejects an
    # empty --ssh-public-keys, so only pass it when we actually have keys.
    if [[ -s "$AUTH_KEYS_FILE" ]]; then
        extra_args+=(--ssh-public-keys "$AUTH_KEYS_FILE")
    fi

    log_info "creating LXC $PBS_VMID ($PBS_HOSTNAME) ${PBS_CORES}C/${PBS_MEMORY_DEDICATED}M+${PBS_MEMORY_SWAP}swap rootfs=${PBS_ROOTFS_SIZE}GB@${PBS_ROOTFS_STORAGE} gw=$gateway"
    pct create "$PBS_VMID" "$template_path" \
        --hostname "$PBS_HOSTNAME" \
        --cores "$PBS_CORES" \
        --memory "$PBS_MEMORY_DEDICATED" \
        --swap "$PBS_MEMORY_SWAP" \
        --rootfs "${PBS_ROOTFS_STORAGE}:${PBS_ROOTFS_SIZE}" \
        --net0 "name=eth0,bridge=$PBS_BRIDGE,ip=$PBS_IP/$PBS_IP_CIDR,gw=$gateway" \
        --onboot 1 \
        --unprivileged 1 \
        --features keyctl=1,nesting=0 \
        "${extra_args[@]}" \
        --start 0

    log_info "starting LXC $PBS_VMID"
    pct start "$PBS_VMID"
}

lxc_wait_network() {
    log_info "waiting for LXC $PBS_VMID network"
    local i

    # Stage 1: pct exec working (container init ready)
    for i in {1..60}; do
        if pct exec "$PBS_VMID" -- true 2>/dev/null; then
            log_info "  pct exec ready after ${i}s"
            break
        fi
        sleep 1
        (( i == 60 )) && die "pct exec never succeeded — check pct status $PBS_VMID + pct enter $PBS_VMID"
    done

    # Stage 2: IPv4 default route present
    for i in {1..30}; do
        if pct exec "$PBS_VMID" -- ip -4 route show default 2>/dev/null | grep -q .; then
            log_info "  IPv4 default route present after ${i}s"
            break
        fi
        sleep 1
        (( i == 30 )) && die "LXC has no IPv4 default route — check pct exec $PBS_VMID -- ip -4 route"
    done

    # Stage 3: DNS resolution working
    for i in {1..30}; do
        if pct exec "$PBS_VMID" -- getent hosts deb.debian.org >/dev/null 2>&1; then
            log_info "  DNS resolving after ${i}s"
            return 0
        fi
        sleep 1
    done
    die "LXC DNS never resolved — check pct exec $PBS_VMID -- cat /etc/resolv.conf"
}
