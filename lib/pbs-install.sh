# shellcheck shell=bash
# Install proxmox-backup-server inside the LXC.
#
# - Force IPv4 (Debian 12 LXCs on many networks have broken IPv6 default routes).
# - Use the no-subscription repo (free).
# - Remove the enterprise repo to avoid 401 on subsequent apt updates.

pbs_install() {
    log_info "configuring apt inside LXC (ForceIPv4, no-subscription repo)"
    pct exec "$PBS_VMID" -- bash -eu <<'EOF'
echo 'Acquire::ForceIPv4 "true";' >/etc/apt/apt.conf.d/99force-ipv4
apt-get update -qq
apt-get install -y -qq curl gnupg ca-certificates

curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg \
    -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
echo "deb http://download.proxmox.com/debian/pbs bookworm pbs-no-subscription" \
    >/etc/apt/sources.list.d/pbs-no-subscription.list
rm -f /etc/apt/sources.list.d/pbs-enterprise.list

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq proxmox-backup-server
EOF

    log_info "PBS installed (services started by package post-install)"
}
