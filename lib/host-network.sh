# shellcheck shell=bash
# Materialize `host.bridges[*]` from bootstrap-config.yml on the Proxmox host.
#
# vmbr0 is created by the PVE installer's network ceremony — bootstrap does
# NOT touch it. This step adds the additional bridges (typically vmbr1, the
# LXC LAN bridge) that PBS LXC sits on, plus any static_routes declared on
# those bridges.
#
# Strategy:
#   - One drop-in file per bridge in /etc/network/interfaces.d/<name>.conf
#   - Idempotent — re-running overwrites the same file with the same content
#   - Ensures /etc/network/interfaces sources interfaces.d/* (PVE default
#     already does, but we guard against minimal installs)
#   - Reloads via `ifreload -a` (Proxmox's ifupdown2)

host_network_setup() {
    local count
    count="$(yq -r '.host.bridges | length' "$PBS_CONFIG_FILE")"
    if [[ -z "$count" || "$count" == "null" || "$count" == "0" ]]; then
        log_info "no host bridges in config — skipping"
        return 0
    fi

    log_info "configuring $count host bridge(s)"
    mkdir -p /etc/network/interfaces.d

    local i=0
    while (( i < count )); do
        local name addr ports
        name="$(yq -r ".host.bridges[$i].name" "$PBS_CONFIG_FILE")"
        addr="$(yq -r ".host.bridges[$i].address" "$PBS_CONFIG_FILE")"
        ports="$(yq -r ".host.bridges[$i].bridge_ports // \"none\"" "$PBS_CONFIG_FILE")"

        local dest="/etc/network/interfaces.d/${name}.conf"
        log_info "  $name → $addr (ports=$ports) → $dest"

        {
            echo "# Managed by pbs-bootstrap — DO NOT EDIT BY HAND"
            echo "auto $name"
            echo "iface $name inet static"
            echo "    address $addr"
            echo "    bridge-ports $ports"
            echo "    bridge-stp off"
            echo "    bridge-fd 0"
            local route_count route_idx subnet gw
            route_count="$(yq -r ".host.bridges[$i].static_routes // [] | length" "$PBS_CONFIG_FILE")"
            route_idx=0
            while (( route_idx < route_count )); do
                subnet="$(yq -r ".host.bridges[$i].static_routes[$route_idx].subnet" "$PBS_CONFIG_FILE")"
                gw="$(yq -r ".host.bridges[$i].static_routes[$route_idx].gateway" "$PBS_CONFIG_FILE")"
                echo "    post-up ip route add $subnet via $gw || true"
                echo "    pre-down ip route del $subnet via $gw || true"
                (( route_idx++ ))
            done
        } > "$dest"
        chmod 0644 "$dest"

        (( i++ ))
    done

    if ! grep -qE '^source\s+/etc/network/interfaces\.d/' /etc/network/interfaces; then
        log_info "appending source-directive to /etc/network/interfaces"
        echo "" >> /etc/network/interfaces
        echo "source /etc/network/interfaces.d/*" >> /etc/network/interfaces
    fi

    log_info "reloading networking via ifreload -a"
    ifreload -a
}
