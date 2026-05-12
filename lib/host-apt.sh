# shellcheck shell=bash
# Fix Proxmox host apt repos and install bootstrap-time dependencies.
#
# Fresh PVE ships with /etc/apt/sources.list.d/pve-enterprise.list pointing at
# the paid subscription repo — `apt update` returns 401 without a sub. We swap
# it for `pve-no-subscription` so the rest of bootstrap (apt installs, pveam
# downloads) can work.
#
# Also installs the deps bootstrap.sh leans on later — kept here (not in
# preflight) because preflight runs before apt is usable.

host_apt_setup() {
    log_info "fixing Proxmox host apt repos (pve-enterprise → pve-no-subscription)"
    rm -f /etc/apt/sources.list.d/pve-enterprise.list \
          /etc/apt/sources.list.d/ceph.list

    if ! grep -rq pve-no-subscription /etc/apt/sources.list.d/ 2>/dev/null; then
        cat >/etc/apt/sources.list.d/pve-no-subscription.list <<'EOF'
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF
    fi

    log_info "apt update + installing bootstrap deps (rclone yq iptables ifupdown2)"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        rclone yq iptables ifupdown2
}
