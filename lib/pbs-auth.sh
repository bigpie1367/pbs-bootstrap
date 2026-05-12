# shellcheck shell=bash
# Create a PBS API user + token + ACL so PVE can authenticate against the
# restored datastore.
#
# Idempotency:
#   - User: created if missing, skipped otherwise.
#   - ACL grants: idempotent (`acl update` overwrites).
#   - Token: always deleted + recreated. PBS shows the token value exactly
#     once at creation time — we need it for the PVE storage entry, so a
#     fresh value is required on every run.
#
# Token value is captured from `proxmox-backup-manager user generate-token`
# output (a "Result: {json}" prefix the CLI doesn't let us strip via flags).
#
# Sets PBS_TOKEN_USERNAME and PBS_TOKEN_VALUE for the next stage.

: "${PBS_PVE_USER:=pve}"
: "${PBS_PVE_TOKEN_NAME:=pve-backup}"
: "${PBS_PVE_ROLE:=DatastoreAdmin}"

pbs_auth_setup() {
    log_info "ensuring PBS user $PBS_PVE_USER@pbs exists"
    local user_exists
    user_exists="$(pct exec "$PBS_VMID" -- proxmox-backup-manager user list --output-format json \
        | grep -c "\"userid\":\"$PBS_PVE_USER@pbs\"" || true)"
    if [[ "$user_exists" == "0" ]]; then
        pct exec "$PBS_VMID" -- proxmox-backup-manager user create "$PBS_PVE_USER@pbs" \
            --comment "PVE backup push (managed by pbs-bootstrap)"
    fi

    log_info "granting $PBS_PVE_ROLE on /datastore/$PBS_DATASTORE_NAME to user"
    pct exec "$PBS_VMID" -- proxmox-backup-manager acl update \
        "/datastore/$PBS_DATASTORE_NAME" "$PBS_PVE_ROLE" \
        --auth-id "$PBS_PVE_USER@pbs"

    log_info "rotating API token $PBS_PVE_TOKEN_NAME"
    pct exec "$PBS_VMID" -- proxmox-backup-manager user delete-token \
        "$PBS_PVE_USER@pbs" "$PBS_PVE_TOKEN_NAME" 2>/dev/null || true

    local token_raw
    token_raw="$(pct exec "$PBS_VMID" -- proxmox-backup-manager user generate-token \
        "$PBS_PVE_USER@pbs" "$PBS_PVE_TOKEN_NAME")"

    # Strip "Result: " prefix → JSON → .value (jq comes installed via yq dep)
    PBS_TOKEN_USERNAME="$PBS_PVE_USER@pbs!$PBS_PVE_TOKEN_NAME"
    PBS_TOKEN_VALUE="$(echo "$token_raw" | sed -E 's/^Result:[[:space:]]*//' | jq -r '.value')"
    export PBS_TOKEN_USERNAME PBS_TOKEN_VALUE

    [[ -n "$PBS_TOKEN_VALUE" && "$PBS_TOKEN_VALUE" != "null" ]] \
        || die "failed to parse token value from PBS CLI output"

    log_info "granting $PBS_PVE_ROLE on /datastore/$PBS_DATASTORE_NAME to token"
    pct exec "$PBS_VMID" -- proxmox-backup-manager acl update \
        "/datastore/$PBS_DATASTORE_NAME" "$PBS_PVE_ROLE" \
        --auth-id "$PBS_TOKEN_USERNAME"
}
