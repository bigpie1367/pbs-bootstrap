# shellcheck shell=bash
# Pull bootstrap-config.yml from B2 meta bucket and export the scalar fields
# as env vars. Complex (list-valued) sections like host.bridges are left in
# the file and read directly by the consumers (host-network.sh) via yq.
#
# Schema (rendered by the homelab ansible pbs role):
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
#   host:
#     bridges:
#       - name: vmbr1
#         address: 10.80.60.254/24
#         bridge_ports: none
#         static_routes:
#           - { subnet: 10.80.80.0/24, gateway: 10.80.60.1 }
#   b2:
#     chunks_bucket: siroh-pbs
#     meta_bucket:   siroh-pbs-meta

: "${PBS_META_BUCKET:=siroh-pbs-meta}"
: "${PBS_CONFIG_OBJECT:=bootstrap-config.yml}"

PBS_CONFIG_FILE=""

config_pull() {
    local dest="$1"
    log_info "pulling $PBS_CONFIG_OBJECT from meta:$PBS_META_BUCKET"
    rclone copyto "meta:$PBS_META_BUCKET/$PBS_CONFIG_OBJECT" "$dest"
    [[ -s "$dest" ]] || die "bootstrap-config.yml is empty or missing"
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
    PBS_B2_CHUNKS_BUCKET="$(yq -r '.b2.chunks_bucket // ""' "$f")"
    PBS_B2_META_BUCKET="$(yq -r '.b2.meta_bucket // ""' "$f")"

    local missing=()
    for v in PBS_VMID PBS_HOSTNAME PBS_BRIDGE PBS_IP PBS_GATEWAY \
             PBS_DATASTORE_NAME PBS_DATASTORE_PATH \
             PBS_ROOTFS_SIZE PBS_ROOTFS_STORAGE \
             PBS_CORES PBS_MEMORY_DEDICATED PBS_MEMORY_SWAP \
             PBS_B2_CHUNKS_BUCKET PBS_B2_META_BUCKET; do
        [[ -n "${!v:-}" ]] || missing+=("$v")
    done
    ((${#missing[@]} == 0)) || die "config missing fields: ${missing[*]}"

    export PBS_VMID PBS_HOSTNAME PBS_BRIDGE PBS_IP PBS_GATEWAY \
           PBS_DATASTORE_NAME PBS_DATASTORE_PATH \
           PBS_ROOTFS_SIZE PBS_ROOTFS_STORAGE \
           PBS_CORES PBS_MEMORY_DEDICATED PBS_MEMORY_SWAP \
           PBS_B2_CHUNKS_BUCKET PBS_B2_META_BUCKET

    log_info "config: vmid=$PBS_VMID host=$PBS_HOSTNAME ip=$PBS_IP ${PBS_CORES}C/${PBS_MEMORY_DEDICATED}M+${PBS_MEMORY_SWAP}swap rootfs=${PBS_ROOTFS_SIZE}GB@${PBS_ROOTFS_STORAGE} datastore=$PBS_DATASTORE_NAME"
}
