# shellcheck shell=bash
# Pull bootstrap-config.yml via the source resolver and export scalar fields
# as env vars. The source is whatever PBS_CONFIG points at — URL, GitHub
# repo, b2://, s3://, local path, or paste-staged temp file. List-valued
# sections (host.bridges) are read directly by consumers (host-network.sh)
# via yq.
#
# Schema:
#
#   pbs:
#     vmid: 200
#     hostname: pbs
#     bridge: vmbr1
#     ip: 10.80.60.200
#     gateway: 10.80.60.1
#     datastore_name: system-backup
#     datastore_path: /mnt/pbs_backup
#     rootfs_size: 100
#     rootfs_storage: local
#     cores: 2
#     memory_dedicated: 2048
#     memory_swap: 1024
#   host:
#     bridges:
#       - name: vmbr1
#         address: 10.80.60.254/24
#         bridge_ports: none
#         static_routes:
#           - { subnet: 10.80.80.0/24, gateway: 10.80.60.1 }
#   storage:
#     type:          b2          # or s3
#     endpoint:      https://... # required when type=s3
#     region:        us-east-005 # required when type=s3
#     chunks_bucket: my-pbs-chunks

PBS_CONFIG_FILE=""

config_pull() {
    local dest="$1"
    log_info "resolving bootstrap-config from: $PBS_CONFIG"
    resolve_source "$PBS_CONFIG" "$dest" config
    PBS_CONFIG_FILE="$dest"
    export PBS_CONFIG_FILE
}

config_export() {
    local f="$1"
    PBS_VMID="$(yq -r '.pbs.vmid // ""' "$f")"
    PBS_HOSTNAME="$(yq -r '.pbs.hostname // ""' "$f")"
    PBS_BRIDGE="$(yq -r '.pbs.bridge // ""' "$f")"
    PBS_IP="$(yq -r '.pbs.ip // ""' "$f")"
    PBS_GATEWAY="$(yq -r '.pbs.gateway // ""' "$f")"
    PBS_DATASTORE_NAME="$(yq -r '.pbs.datastore_name // ""' "$f")"
    PBS_DATASTORE_PATH="$(yq -r '.pbs.datastore_path // ""' "$f")"
    PBS_ROOTFS_SIZE="$(yq -r '.pbs.rootfs_size // ""' "$f")"
    PBS_ROOTFS_STORAGE="$(yq -r '.pbs.rootfs_storage // ""' "$f")"
    PBS_CORES="$(yq -r '.pbs.cores // ""' "$f")"
    PBS_MEMORY_DEDICATED="$(yq -r '.pbs.memory_dedicated // ""' "$f")"
    PBS_MEMORY_SWAP="$(yq -r '.pbs.memory_swap // ""' "$f")"

    # storage.* in the config and the live PBS_STORAGE_TYPE env must agree —
    # rclone_setup_host already ran with the env value, so a mismatch means
    # rclone is configured for the wrong backend and would silently fail.
    local cfg_type cfg_endpoint cfg_region
    cfg_type="$(yq -r '.storage.type // "b2"' "$f")"
    cfg_endpoint="$(yq -r '.storage.endpoint // ""' "$f")"
    cfg_region="$(yq -r '.storage.region // ""' "$f")"

    if [[ "$cfg_type" != "$PBS_STORAGE_TYPE" ]]; then
        die "storage.type mismatch: config says '$cfg_type' but env/default is '$PBS_STORAGE_TYPE' — set PBS_STORAGE_TYPE=$cfg_type before running bootstrap"
    fi

    : "${PBS_STORAGE_ENDPOINT:=$cfg_endpoint}"
    : "${PBS_STORAGE_REGION:=$cfg_region}"
    : "${PBS_CHUNKS_BUCKET:=$(yq -r '.storage.chunks_bucket // .b2.chunks_bucket // ""' "$f")}"

    local missing=()
    for v in PBS_VMID PBS_HOSTNAME PBS_BRIDGE PBS_IP PBS_GATEWAY \
             PBS_DATASTORE_NAME PBS_DATASTORE_PATH \
             PBS_ROOTFS_SIZE PBS_ROOTFS_STORAGE \
             PBS_CORES PBS_MEMORY_DEDICATED PBS_MEMORY_SWAP \
             PBS_STORAGE_TYPE PBS_CHUNKS_BUCKET; do
        [[ -n "${!v:-}" ]] || missing+=("$v")
    done

    if [[ "$PBS_STORAGE_TYPE" == "s3" ]]; then
        [[ -n "$PBS_STORAGE_ENDPOINT" ]] || missing+=(storage.endpoint)
        [[ -n "$PBS_STORAGE_REGION" ]]   || missing+=(storage.region)
    fi

    ((${#missing[@]} == 0)) || die "config missing fields: ${missing[*]}"

    export PBS_VMID PBS_HOSTNAME PBS_BRIDGE PBS_IP PBS_GATEWAY \
           PBS_DATASTORE_NAME PBS_DATASTORE_PATH \
           PBS_ROOTFS_SIZE PBS_ROOTFS_STORAGE \
           PBS_CORES PBS_MEMORY_DEDICATED PBS_MEMORY_SWAP \
           PBS_STORAGE_TYPE PBS_STORAGE_ENDPOINT PBS_STORAGE_REGION \
           PBS_CHUNKS_BUCKET

    log_info "config: vmid=$PBS_VMID host=$PBS_HOSTNAME ip=$PBS_IP storage=$PBS_STORAGE_TYPE chunks=$PBS_CHUNKS_BUCKET"
}
