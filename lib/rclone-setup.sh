# shellcheck shell=bash
# Configure B2 remotes for rclone on the Proxmox host.
#
# Two remotes:
#   meta   — bootstrap-config.yml + authorized_keys live here
#   chunks — PBS datastore chunks
#
# rclone itself is installed by host_apt_setup (runs before this).

RCLONE_CONF_DIR="/root/.config/rclone"
RCLONE_CONF="$RCLONE_CONF_DIR/rclone.conf"

rclone_setup_host() {
    mkdir -p "$RCLONE_CONF_DIR"
    chmod 700 "$RCLONE_CONF_DIR"

    cat >"$RCLONE_CONF" <<EOF
[meta]
type = b2
account = $B2_PBS_META_KEY_ID
key = $B2_PBS_META_KEY

[chunks]
type = b2
account = $B2_PBS_KEY_ID
key = $B2_PBS_KEY
hard_delete = true
EOF
    chmod 600 "$RCLONE_CONF"
    log_info "rclone configured: meta + chunks remotes"
}
