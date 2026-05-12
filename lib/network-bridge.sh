# shellcheck shell=bash
# Network shim for bootstrap — gives the new LXC internet during chunk restore
# even when the LAN gateway (pfSense / OPNsense / etc.) is dead.
#
# This is unconditional: bootstrap.sh is for disaster recovery, and in a real
# disaster you can't trust the LAN gateway. The shim:
#   - Auto-detects the Proxmox host's IPv4 on $PBS_BRIDGE and uses it as the
#     LXC's gateway *during* bootstrap (overrides the value from config).
#   - Sets PBS_DNS_OVERRIDE so pct create --nameserver injects a working
#     resolver into the LXC (default 1.1.1.1).
#   - Enables ip_forward + iptables MASQUERADE on the host so the host NATs
#     LAN traffic out via PBS_NAT_OUT_IFACE.
#   - On bootstrap success, restores the LXC's gateway to the value from
#     bootstrap-config.yml so the LXC matches the declared steady state.
#   - On exit (success or failure), removes the iptables rule and restores
#     ip_forward to its pre-bootstrap value.
#
# Tunables (rarely needed — defaults work for the standard "ISP-router gateway
# at vmbr0, dead LAN firewall at the configured PBS gateway" topology):
#   PBS_NAT_OUT_IFACE    — host's upstream iface (default vmbr0)
#   PBS_NAT_DNS          — temp resolver for LXC (default 1.1.1.1)
#   PBS_GATEWAY_OVERRIDE — explicit gateway (auto-detected from $PBS_BRIDGE)
#   PBS_DNS_OVERRIDE     — explicit DNS for LXC (defaults to $PBS_NAT_DNS)

: "${PBS_NAT_OUT_IFACE:=vmbr0}"
: "${PBS_NAT_DNS:=1.1.1.1}"

NAT_PREV_FORWARD=""
NAT_LAN_SUBNET=""

network_shim_apply() {
    command -v iptables >/dev/null || die "iptables not found on host"

    ip -o link show "$PBS_NAT_OUT_IFACE" >/dev/null 2>&1 \
        || die "out-iface $PBS_NAT_OUT_IFACE not present on host (set PBS_NAT_OUT_IFACE)"

    NAT_LAN_SUBNET="$(_subnet_v4 "$PBS_IP" "$PBS_IP_CIDR")"
    [[ -n "$NAT_LAN_SUBNET" ]] || die "cannot compute LAN subnet from $PBS_IP/$PBS_IP_CIDR"

    if [[ -z "${PBS_GATEWAY_OVERRIDE:-}" ]]; then
        PBS_GATEWAY_OVERRIDE="$(ip -4 -o addr show "$PBS_BRIDGE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
        [[ -n "$PBS_GATEWAY_OVERRIDE" ]] \
            || die "$PBS_BRIDGE has no IPv4 on host — set PBS_GATEWAY_OVERRIDE manually"
    fi
    PBS_DNS_OVERRIDE="${PBS_DNS_OVERRIDE:-$PBS_NAT_DNS}"

    export PBS_GATEWAY_OVERRIDE PBS_DNS_OVERRIDE NAT_LAN_SUBNET

    log_info "network shim: gw=$PBS_GATEWAY_OVERRIDE  dns=$PBS_DNS_OVERRIDE  masq $NAT_LAN_SUBNET → $PBS_NAT_OUT_IFACE"

    NAT_PREV_FORWARD="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
    export NAT_PREV_FORWARD
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    # -C checks if the rule already exists (idempotent re-run after a crash).
    iptables -t nat -C POSTROUTING -s "$NAT_LAN_SUBNET" -o "$PBS_NAT_OUT_IFACE" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s "$NAT_LAN_SUBNET" -o "$PBS_NAT_OUT_IFACE" -j MASQUERADE
}

# Called at end of successful bootstrap — restores the LXC's gateway to the
# value declared in bootstrap-config.yml so the running container matches
# the source of truth, then reboots the LXC so the change actually applies
# to the running kernel (pct set --net0 only edits config, not live state).
# DNS stays at PBS_NAT_DNS until the real LAN gateway is back and ansible
# / DHCP refreshes resolv.conf.
network_shim_restore_lxc() {
    log_info "restoring LXC net0 → gw=$PBS_GATEWAY (declared)"
    pct set "$PBS_VMID" --net0 "name=eth0,bridge=$PBS_BRIDGE,ip=$PBS_IP/$PBS_IP_CIDR,gw=$PBS_GATEWAY"

    # pct set on a running container only updates the on-disk config — the
    # live network namespace keeps its boot-time gw (= our masquerade target).
    # Once the masquerade is torn down by the EXIT trap, the live state
    # silently loses connectivity. Cycle the container explicitly with
    # shutdown→start (pct reboot is async and races with our wait loop —
    # it can match the old container right before shutdown begins).
    log_info "cycling LXC $PBS_VMID to apply declared net0"
    pct shutdown "$PBS_VMID" --timeout 30 2>/dev/null \
        || pct stop "$PBS_VMID" --force
    pct start "$PBS_VMID"

    local i
    for i in {1..30}; do
        if pct exec "$PBS_VMID" -- true 2>/dev/null; then
            log_info "  LXC back up after ${i}s"
            return 0
        fi
        sleep 1
    done
    log_warn "LXC not responsive after restart — verify with: pct status $PBS_VMID"
}

network_shim_teardown() {
    if [[ -n "$NAT_LAN_SUBNET" ]]; then
        log_info "tearing down host-side masquerade"
        iptables -t nat -D POSTROUTING -s "$NAT_LAN_SUBNET" -o "$PBS_NAT_OUT_IFACE" -j MASQUERADE 2>/dev/null || true
    fi
    if [[ -n "$NAT_PREV_FORWARD" ]]; then
        sysctl -w "net.ipv4.ip_forward=$NAT_PREV_FORWARD" >/dev/null || true
    fi
}

# Compute the network-portion of IP/CIDR (e.g. 10.80.60.200/24 → 10.80.60.0/24).
# Pure bash, any CIDR in /0..32. No external deps (ipcalc-ng etc).
_subnet_v4() {
    local ip="$1" cidr="$2"
    local IFS=.
    local -a o
    read -r -a o <<<"$ip"
    (( ${#o[@]} == 4 )) || { echo ""; return 1; }
    (( cidr >= 0 && cidr <= 32 )) || { echo ""; return 1; }

    local ip_int=$(( (o[0]<<24) | (o[1]<<16) | (o[2]<<8) | o[3] ))
    local mask
    if (( cidr == 0 )); then
        mask=0
    else
        mask=$(( 0xFFFFFFFF << (32 - cidr) & 0xFFFFFFFF ))
    fi
    local net=$(( ip_int & mask ))

    printf "%d.%d.%d.%d/%d\n" \
        $(( (net>>24) & 0xFF )) \
        $(( (net>>16) & 0xFF )) \
        $(( (net>>8)  & 0xFF )) \
        $((  net      & 0xFF )) \
        "$cidr"
}
