# shellcheck shell=bash
# Pull bootstrap-config.yml from B2 meta bucket and export values as env vars.
#
# The config is rendered by ansible (pbs role) on every apply. Schema:
#
#   pbs:
#     vmid: ...
#     hostname: ...
#     bridge: ...
#     ip: ...
#     gateway: ...
#     datastore_name: ...
#     datastore_path: ...
#   b2:
#     chunks_bucket: ...
#     meta_bucket: ...

: "${PBS_META_BUCKET:=siroh-pbs-meta}"
: "${PBS_CONFIG_OBJECT:=bootstrap-config.yml}"

config_pull() {
    local dest="$1"
    log_info "pulling $PBS_CONFIG_OBJECT from B2 meta:$PBS_META_BUCKET"
    rclone copyto "meta:$PBS_META_BUCKET/$PBS_CONFIG_OBJECT" "$dest"
    [[ -s "$dest" ]] || die "bootstrap-config.yml is empty or missing"
}

# Read a `section.key` pair from a flat 2-level YAML (matches the schema above).
_yaml_get() {
    local file="$1" section="$2" key="$3"
    awk -v sec="${section}:" -v k="${key}:" '
        $0 == sec        { in_sec = 1; next }
        in_sec && /^[a-zA-Z]/ { in_sec = 0 }
        in_sec && $1 == k {
            sub(/^[[:space:]]*[a-zA-Z_]+:[[:space:]]*/, "")
            print
            exit
        }
    ' "$file"
}

config_export() {
    local f="$1"
    PBS_VMID="$(_yaml_get "$f" pbs vmid)"
    PBS_HOSTNAME="$(_yaml_get "$f" pbs hostname)"
    PBS_BRIDGE="$(_yaml_get "$f" pbs bridge)"
    PBS_IP="$(_yaml_get "$f" pbs ip)"
    PBS_GATEWAY="$(_yaml_get "$f" pbs gateway)"
    PBS_DATASTORE_NAME="$(_yaml_get "$f" pbs datastore_name)"
    PBS_DATASTORE_PATH="$(_yaml_get "$f" pbs datastore_path)"
    PBS_B2_CHUNKS_BUCKET="$(_yaml_get "$f" b2 chunks_bucket)"
    PBS_B2_META_BUCKET="$(_yaml_get "$f" b2 meta_bucket)"

    local missing=()
    for v in PBS_VMID PBS_HOSTNAME PBS_BRIDGE PBS_IP PBS_GATEWAY \
             PBS_DATASTORE_NAME PBS_DATASTORE_PATH \
             PBS_B2_CHUNKS_BUCKET PBS_B2_META_BUCKET; do
        [[ -n "${!v:-}" ]] || missing+=("$v")
    done
    ((${#missing[@]} == 0)) || die "config missing fields: ${missing[*]}"

    export PBS_VMID PBS_HOSTNAME PBS_BRIDGE PBS_IP PBS_GATEWAY \
           PBS_DATASTORE_NAME PBS_DATASTORE_PATH \
           PBS_B2_CHUNKS_BUCKET PBS_B2_META_BUCKET

    log_info "config: vmid=$PBS_VMID host=$PBS_HOSTNAME ip=$PBS_IP datastore=$PBS_DATASTORE_NAME"
}
