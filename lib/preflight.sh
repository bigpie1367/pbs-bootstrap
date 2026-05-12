# shellcheck shell=bash
# Validate environment before doing any work.
#
# Only checks what's required *before* host_apt_setup can run — anything else
# (rclone, yq, iptables, whiptail) is installed/verified in host_apt_setup.

preflight_check() {
    log_info "preflight: checking environment"

    # Chunks credentials are always required (the meta bucket access is
    # conditional, validated later once the source URIs are known).
    local missing=()
    for v in PBS_CHUNKS_KEY_ID PBS_CHUNKS_KEY PBS_CONFIG PBS_AUTH_KEYS; do
        [[ -n "${!v:-}" ]] || missing+=("$v")
    done
    if ((${#missing[@]} > 0)); then
        die "missing required env vars: ${missing[*]}"
    fi

    # When config or authorized_keys live in b2://... / s3://..., we also
    # need meta credentials.
    if sources_need_meta_remote; then
        for v in PBS_META_KEY_ID PBS_META_KEY; do
            [[ -n "${!v:-}" ]] \
                || die "PBS_CONFIG or PBS_AUTH_KEYS uses b2://|s3://, but $v is unset"
        done
    fi

    # s3 backend needs explicit endpoint + region
    if [[ "${PBS_STORAGE_TYPE:-b2}" == "s3" ]]; then
        [[ -n "${PBS_STORAGE_ENDPOINT:-}" ]] \
            || die "PBS_STORAGE_TYPE=s3 but PBS_STORAGE_ENDPOINT is unset"
        [[ -n "${PBS_STORAGE_REGION:-}" ]] \
            || die "PBS_STORAGE_TYPE=s3 but PBS_STORAGE_REGION is unset"
    fi

    command -v pveversion >/dev/null \
        || die "pveversion not found — bootstrap.sh must run on a Proxmox VE host"

    for cmd in pct pveam curl git awk; do
        command -v "$cmd" >/dev/null || die "missing command: $cmd"
    done

    log_info "preflight: OK"
}
