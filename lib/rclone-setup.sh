# shellcheck shell=bash
# Configure rclone remotes on the Proxmox host.
#
# Always writes the 'chunks' remote (every bootstrap downloads chunks).
# Writes the 'meta' remote only if a source URI (config / auth_keys) needs
# it (b2://... or s3://...).
#
# rclone itself is installed by host_apt_setup.

RCLONE_CONF_DIR="/root/.config/rclone"
RCLONE_CONF="$RCLONE_CONF_DIR/rclone.conf"

rclone_setup_host() {
    mkdir -p "$RCLONE_CONF_DIR"
    chmod 700 "$RCLONE_CONF_DIR"

    : >"$RCLONE_CONF"
    chmod 600 "$RCLONE_CONF"

    _rclone_append_remote "$RCLONE_CONF" "chunks" \
        "$PBS_CHUNKS_KEY_ID" "$PBS_CHUNKS_KEY"

    if sources_need_meta_remote; then
        _rclone_append_remote "$RCLONE_CONF" "meta" \
            "$PBS_META_KEY_ID" "$PBS_META_KEY"
        log_info "rclone configured ($PBS_STORAGE_TYPE): chunks + meta remotes"
    else
        log_info "rclone configured ($PBS_STORAGE_TYPE): chunks remote only (no meta needed)"
    fi
}

# Append one [remote] block to $1 using PBS_STORAGE_TYPE.
# $1=destination file, $2=remote-name, $3=key id, $4=secret
_rclone_append_remote() {
    local dest="$1" name="$2" id="$3" key="$4"

    case "$PBS_STORAGE_TYPE" in
        b2)
            cat >>"$dest" <<EOF
[$name]
type = b2
account = $id
key = $key
EOF
            ;;
        s3)
            cat >>"$dest" <<EOF
[$name]
type = s3
provider = Other
access_key_id = $id
secret_access_key = $key
endpoint = $PBS_STORAGE_ENDPOINT
region = $PBS_STORAGE_REGION
EOF
            ;;
        *)
            die "unsupported storage.type: $PBS_STORAGE_TYPE (expected b2 or s3)"
            ;;
    esac

    # rclone hard_delete on b2 chunks matches steady-state sync semantics.
    if [[ "$name" == "chunks" && "$PBS_STORAGE_TYPE" == "b2" ]]; then
        echo "hard_delete = true" >>"$dest"
    fi
    echo "" >>"$dest"
}

# Render a chunks-only rclone.conf into $1 (for `pct push` into the LXC,
# since the LXC only does B2/S3 sync, never meta access).
rclone_render_chunks_only() {
    local dest="$1"
    : >"$dest"
    chmod 600 "$dest"
    _rclone_append_remote "$dest" "chunks" \
        "$PBS_CHUNKS_KEY_ID" "$PBS_CHUNKS_KEY"
}
