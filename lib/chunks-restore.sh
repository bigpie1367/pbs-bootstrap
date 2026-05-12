# shellcheck shell=bash
# Restore PBS chunks from the chunks bucket into the LXC's datastore path.
#
# - Foreground, with --progress so the user sees throughput.
# - Run rclone inside the LXC so the network traffic is on the LXC's IP
#   (matches steady-state ansible sync behavior).
# - chown to backup:backup after copy — PBS refuses chunks owned by root.

chunks_restore() {
    log_info "installing rclone inside LXC"
    pct exec "$PBS_VMID" -- bash -eu <<'EOF'
apt-get install -y -qq rclone
mkdir -p /root/.config/rclone
chmod 700 /root/.config/rclone
EOF

    log_info "pushing rclone config into LXC (chunks only)"
    local lxc_rclone_conf
    lxc_rclone_conf="$(mktemp /tmp/pbs-bootstrap-rclone.XXXXXX.conf)"
    rclone_render_chunks_only "$lxc_rclone_conf"
    pct push "$PBS_VMID" "$lxc_rclone_conf" /root/.config/rclone/rclone.conf --perms 0600
    rm -f "$lxc_rclone_conf"

    log_info "creating datastore path $PBS_DATASTORE_PATH"
    pct exec "$PBS_VMID" -- mkdir -p "$PBS_DATASTORE_PATH"

    log_info "rclone copy chunks:$PBS_CHUNKS_BUCKET → $PBS_DATASTORE_PATH (long-running, ctrl-c safe to resume)"
    pct exec "$PBS_VMID" -- rclone copy \
        "chunks:$PBS_CHUNKS_BUCKET" "$PBS_DATASTORE_PATH" \
        --progress \
        --transfers 16 \
        --checkers 32 \
        --fast-list

    log_info "chowning datastore to backup:backup"
    pct exec "$PBS_VMID" -- chown -R backup:backup "$PBS_DATASTORE_PATH"
}
