# shellcheck shell=bash
# Install rclone on the Proxmox host and configure B2 remotes.
#
# Two remotes:
#   meta   — bootstrap-config.yml lives here
#   chunks — PBS datastore chunks (copied into LXC later)

RCLONE_CONF_DIR="/root/.config/rclone"
RCLONE_CONF="$RCLONE_CONF_DIR/rclone.conf"

rclone_setup_host() {
    if ! command -v rclone >/dev/null; then
        log_info "installing rclone via apt"
        apt-get update -qq
        apt-get install -y -qq rclone
    fi

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
