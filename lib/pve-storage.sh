# shellcheck shell=bash
# Register the restored PBS as a backup storage in PVE so the operator can
# browse and restore VMs/CTs from the PVE GUI immediately after bootstrap.
#
# In a full DR the LAN firewall VM is still gone, so the homelab ansible
# automation cannot yet reach the host via WireGuard. The operator has to
# do the *first* restore (typically pfSense) manually from PVE — and to do
# that, PVE needs a working storage entry pointing at PBS. That's what this
# stage sets up.
#
# Order matters: this must run AFTER pbs_auth_setup so PBS_TOKEN_USERNAME
# and PBS_TOKEN_VALUE are populated, and AFTER datastore_init so the PBS
# TLS proxy is reloaded with the final cert.

: "${PBS_PVE_STORAGE_ID:=pbs}"

pve_storage_sync() {
    log_info "extracting PBS TLS fingerprint"
    local fingerprint
    fingerprint="$(pct exec "$PBS_VMID" -- bash -c \
        "proxmox-backup-manager cert info | awk '/Fingerprint \(sha256\)/{print \$NF; exit}'")"
    [[ -n "$fingerprint" ]] || die "could not extract PBS TLS fingerprint"

    log_info "backing up existing /etc/pve/storage.cfg"
    cp /etc/pve/storage.cfg "/var/backups/proxmox-storage.cfg.bak-$(date +%s)"

    if pvesm status -storage "$PBS_PVE_STORAGE_ID" &>/dev/null; then
        log_info "updating existing PVE storage entry $PBS_PVE_STORAGE_ID"
        pvesm set "$PBS_PVE_STORAGE_ID" \
            --fingerprint "$fingerprint" \
            --username "$PBS_TOKEN_USERNAME" \
            --password "$PBS_TOKEN_VALUE"
    else
        log_info "adding PVE storage entry $PBS_PVE_STORAGE_ID"
        pvesm add pbs "$PBS_PVE_STORAGE_ID" \
            --server "$PBS_IP" \
            --datastore "$PBS_DATASTORE_NAME" \
            --username "$PBS_TOKEN_USERNAME" \
            --password "$PBS_TOKEN_VALUE" \
            --fingerprint "$fingerprint" \
            --content backup
    fi

    log_info "PVE storage $PBS_PVE_STORAGE_ID wired to PBS @ $PBS_IP"
}
