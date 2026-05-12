# shellcheck shell=bash
# Pull the operator's authorized_keys from B2 meta bucket and install it on
# the Proxmox host + prepare it for injection into the new PBS LXC.
#
# Source of truth: the steady-state host's /root/.ssh/authorized_keys.
# Ansible (pbs role) mirrors that file to B2 on every apply, so bootstrap
# can re-seed both the new host and the new LXC during DR.
#
# Fallback: if the B2 mirror is missing or empty (e.g. very first bootstrap
# before ansible has ever run), PBS_SSH_PUBKEY_FILE can point at a local
# file the operator staged manually.

: "${PBS_AUTH_KEYS_OBJECT:=authorized_keys}"
AUTH_KEYS_FILE=""

fetch_authorized_keys() {
    AUTH_KEYS_FILE="$(mktemp /tmp/pbs-bootstrap-keys.XXXXXX)"
    log_info "fetching $PBS_AUTH_KEYS_OBJECT from meta:$PBS_META_BUCKET"

    if rclone copyto "meta:$PBS_META_BUCKET/$PBS_AUTH_KEYS_OBJECT" "$AUTH_KEYS_FILE" 2>/dev/null \
        && [[ -s "$AUTH_KEYS_FILE" ]]; then
        export AUTH_KEYS_FILE
        return 0
    fi

    log_warn "authorized_keys missing/empty in B2 — falling back to PBS_SSH_PUBKEY_FILE"
    if [[ -n "${PBS_SSH_PUBKEY_FILE:-}" && -s "$PBS_SSH_PUBKEY_FILE" ]]; then
        cp "$PBS_SSH_PUBKEY_FILE" "$AUTH_KEYS_FILE"
        export AUTH_KEYS_FILE
        return 0
    fi

    die "no SSH keys available — set PBS_SSH_PUBKEY_FILE or push authorized_keys to meta bucket first"
}

install_authorized_keys_on_host() {
    log_info "installing operator keys → /root/.ssh/authorized_keys (host)"
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    install -m 0600 -o root -g root "$AUTH_KEYS_FILE" /root/.ssh/authorized_keys
}
