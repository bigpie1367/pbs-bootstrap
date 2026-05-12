# shellcheck shell=bash
# Resolve the operator's authorized_keys via the source resolver and install
# them on the Proxmox host + stage for LXC --ssh-public-keys injection.

AUTH_KEYS_FILE=""

fetch_authorized_keys() {
    AUTH_KEYS_FILE="$(mktemp /tmp/pbs-bootstrap-keys.XXXXXX)"
    log_info "resolving authorized_keys from: $PBS_AUTH_KEYS"
    resolve_source "$PBS_AUTH_KEYS" "$AUTH_KEYS_FILE" auth_keys
    export AUTH_KEYS_FILE
}

install_authorized_keys_on_host() {
    if [[ ! -s "$AUTH_KEYS_FILE" ]]; then
        log_warn "no keys to install on host (auth_keys source resolved to empty)"
        return 0
    fi
    log_info "installing operator keys → /root/.ssh/authorized_keys (host)"
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    install -m 0600 -o root -g root "$AUTH_KEYS_FILE" /root/.ssh/authorized_keys
}
