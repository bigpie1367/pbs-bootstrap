# shellcheck shell=bash
# Register the restored datastore with PBS by writing /etc/proxmox-backup/datastore.cfg
# and reloading the proxy.
#
# Why not `proxmox-backup-manager datastore create`?
#   The CLI form initializes a fresh layout (creates .chunks/, locks, etc.) and
#   refuses a non-empty target. We already have the restored layout on disk, so
#   we just declare it via the section config — PBS picks it up on proxy reload.

: "${PBS_GC_SCHEDULE:=4:00}"
: "${PBS_NOTIFICATION_MODE:=notification-system}"

datastore_init() {
    log_info "writing datastore.cfg for $PBS_DATASTORE_NAME"
    pct exec "$PBS_VMID" -- bash -eu <<EOF
cat >/etc/proxmox-backup/datastore.cfg <<CFG
datastore: $PBS_DATASTORE_NAME
	gc-schedule $PBS_GC_SCHEDULE
	notification-mode $PBS_NOTIFICATION_MODE
	path $PBS_DATASTORE_PATH
CFG
chown root:backup /etc/proxmox-backup/datastore.cfg
chmod 0640 /etc/proxmox-backup/datastore.cfg

systemctl reload proxmox-backup-proxy
EOF

    log_info "verifying datastore is visible"
    if pct exec "$PBS_VMID" -- proxmox-backup-manager datastore list --output-format json \
        | grep -q "\"$PBS_DATASTORE_NAME\""; then
        log_info "datastore $PBS_DATASTORE_NAME registered"
    else
        die "datastore did not register — check journalctl -u proxmox-backup-proxy"
    fi
}
