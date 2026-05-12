# shellcheck shell=bash
# Validate environment before doing any work.

preflight_check() {
    log_info "preflight: checking environment"

    local missing=()
    for v in B2_PBS_META_KEY_ID B2_PBS_META_KEY B2_PBS_KEY_ID B2_PBS_KEY; do
        [[ -n "${!v:-}" ]] || missing+=("$v")
    done
    if ((${#missing[@]} > 0)); then
        die "missing required env vars: ${missing[*]}"
    fi

    command -v pveversion >/dev/null \
        || die "pveversion not found — bootstrap.sh must run on a Proxmox VE host"

    for cmd in pct pveam curl git awk; do
        command -v "$cmd" >/dev/null || die "missing command: $cmd"
    done

    [[ -f "$PBS_SSH_PUBKEY_FILE" ]] \
        || die "ssh pubkey file not found: $PBS_SSH_PUBKEY_FILE (set PBS_SSH_PUBKEY_FILE)"

    log_info "preflight: OK"
}
