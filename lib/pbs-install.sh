# shellcheck shell=bash
# Install proxmox-backup-server inside the LXC.
#
# - Force IPv4 (Debian 12 LXCs on many networks have broken IPv6 default routes).
# - Use the no-subscription repo (free).
# - Remove the enterprise repo to avoid 401 on subsequent apt updates.
#
# Why this is in scope: chunks restored from B2 are only readable by PBS once
# the proxmox-backup-server package is installed (creates the `backup` user
# whose ownership chunks-restore.sh restores). Without PBS installed the
# datastore directory is just files on disk — not usable as backup storage.
# Registering the datastore (writing datastore.cfg) is left to ansible.

pbs_install() {
    log_info "configuring apt inside LXC (ForceIPv4, no-subscription repo)"
    pct exec "$PBS_VMID" -- bash -eu <<'EOF'
echo 'Acquire::ForceIPv4 "true";' >/etc/apt/apt.conf.d/99force-ipv4
apt-get update -qq
apt-get install -y -qq curl gnupg ca-certificates

# Modern keyring location (/etc/apt/trusted.gpg.d/ is deprecated in trixie+).
# Pin the repo to this specific key via Signed-By so other keyrings can't
# vouch for the same repo.
mkdir -p /etc/apt/keyrings
curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg \
    -o /etc/apt/keyrings/proxmox-release-bookworm.gpg
chmod 0644 /etc/apt/keyrings/proxmox-release-bookworm.gpg

cat >/etc/apt/sources.list.d/pbs-no-subscription.list <<'SRC'
deb [signed-by=/etc/apt/keyrings/proxmox-release-bookworm.gpg] http://download.proxmox.com/debian/pbs bookworm pbs-no-subscription
SRC

# Migrate from the legacy keyring path if a previous bootstrap left it.
rm -f /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg \
      /etc/apt/sources.list.d/pbs-enterprise.list

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq proxmox-backup-server
EOF

    log_info "PBS installed (services started by package post-install)"
}
