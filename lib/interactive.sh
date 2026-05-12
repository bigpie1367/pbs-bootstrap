# shellcheck shell=bash
# Interactive TUI flow — collects everything bootstrap.sh needs from the
# operator and exports it as env vars. Skipped (no prompts) for any value
# already supplied via env (CI / re-run).
#
# Pipeline that follows is unchanged — it reads the same env vars whether
# they came from `export …` or from this script.

interactive_collect() {
    command -v whiptail >/dev/null || die "whiptail not available — install or set env vars directly"

    tui_msg "pbs-bootstrap" "\
This script bootstraps a PBS LXC from a chunks bucket mirror,
registers it as PVE storage, and stops there.

You'll be asked for:
  - storage backend (b2 or s3-compatible)
  - chunks bucket name + key
  - where your bootstrap-config.yml lives
  - where your authorized_keys come from
  - (if b2://|s3://) meta bucket key

About 5–8 prompts. Press Esc anywhere to abort."

    _i_storage_backend
    _i_chunks_credentials
    _i_config_source
    _i_auth_keys_source
    _i_meta_credentials_if_needed
    _i_summary_and_confirm
}

_i_storage_backend() {
    if [[ -n "${PBS_STORAGE_TYPE:-}" && "$PBS_STORAGE_TYPE" != "b2" ]]; then
        # Already explicitly set to something non-default — accept it.
        :
    elif [[ -n "${_PBS_TYPE_ASKED:-}" ]]; then
        :
    else
        local choice
        choice="$(tui_radio "Storage backend" \
            "Which backend hosts your chunks (and optionally meta)?" \
            "b2" "Backblaze B2 (native API)" \
            "s3" "S3-compatible (AWS / MinIO / R2 / Wasabi / B2 via S3)")" \
            || die "aborted at storage backend"
        export PBS_STORAGE_TYPE="$choice"
    fi

    if [[ "${PBS_STORAGE_TYPE:-b2}" == "s3" ]]; then
        [[ -n "${PBS_STORAGE_ENDPOINT:-}" ]] \
            || PBS_STORAGE_ENDPOINT="$(tui_input "S3 endpoint" \
                "Full URL, e.g. https://s3.us-east-005.backblazeb2.com")" \
            || die "aborted at endpoint"
        [[ -n "${PBS_STORAGE_REGION:-}" ]] \
            || PBS_STORAGE_REGION="$(tui_input "S3 region" \
                "Region string, e.g. us-east-005")" \
            || die "aborted at region"
        export PBS_STORAGE_ENDPOINT PBS_STORAGE_REGION
    fi
    export _PBS_TYPE_ASKED=1
}

_i_chunks_credentials() {
    [[ -n "${PBS_CHUNKS_KEY_ID:-}" ]] \
        || PBS_CHUNKS_KEY_ID="$(tui_input "Chunks bucket — Key ID" \
            "Application key ID with READ access to your chunks bucket:")" \
        || die "aborted at chunks key id"
    [[ -n "${PBS_CHUNKS_KEY:-}" ]] \
        || PBS_CHUNKS_KEY="$(tui_password "Chunks bucket — App Key" \
            "Application key secret (hidden):")" \
        || die "aborted at chunks key"
    export PBS_CHUNKS_KEY_ID PBS_CHUNKS_KEY
}

_i_config_source() {
    [[ -z "${PBS_CONFIG:-}" ]] || return 0

    local choice
    choice="$(tui_radio "bootstrap-config.yml source" \
        "Where is your bootstrap-config.yml?" \
        "github" "GitHub repo" \
        "bucket" "B2 / S3 bucket (meta)" \
        "url"    "HTTPS URL" \
        "file"   "Local file path" \
        "paste"  "Paste contents now")" \
        || die "aborted at config source"

    case "$choice" in
        github) PBS_CONFIG="$(_i_github_spec config)" ;;
        bucket) PBS_CONFIG="$(_i_bucket_uri config bootstrap-config.yml)" ;;
        url)    PBS_CONFIG="$(tui_input "Config URL" "URL to bootstrap-config.yml:")" ;;
        file)   PBS_CONFIG="$(tui_input "Local config path" "Absolute path:")" ;;
        paste)
            local tmp; tmp="$(mktemp /tmp/pbs-config.XXXXXX.yml)"
            tui_paste_capture "Paste bootstrap-config.yml" "$tmp"
            PBS_CONFIG="$tmp"
            ;;
    esac
    [[ -n "$PBS_CONFIG" ]] || die "config source not provided"
    export PBS_CONFIG
}

_i_auth_keys_source() {
    [[ -z "${PBS_AUTH_KEYS:-}" ]] || return 0

    local choice
    choice="$(tui_radio "SSH keys source" \
        "Where are the operator SSH keys (host + LXC seed)?" \
        "github-user" "GitHub user (github.com/<user>.keys)" \
        "github-repo" "GitHub repo" \
        "bucket"      "B2 / S3 bucket (meta)" \
        "url"         "HTTPS URL" \
        "file"        "Local file path" \
        "paste"       "Paste keys now (one per line)" \
        "skip"        "Skip — PVE web shell only")" \
        || die "aborted at auth keys source"

    case "$choice" in
        github-user) PBS_AUTH_KEYS="$(tui_input "GitHub user" "Username (the part before .keys):")" ;;
        github-repo) PBS_AUTH_KEYS="$(_i_github_spec auth_keys)" ;;
        bucket)      PBS_AUTH_KEYS="$(_i_bucket_uri auth_keys authorized_keys)" ;;
        url)         PBS_AUTH_KEYS="$(tui_input "Keys URL" "URL to authorized_keys:")" ;;
        file)        PBS_AUTH_KEYS="$(tui_input "Local keys path" "Absolute path:")" ;;
        paste)
            local tmp; tmp="$(mktemp /tmp/pbs-keys.XXXXXX)"
            tui_paste_capture "Paste SSH public keys (one per line)" "$tmp"
            PBS_AUTH_KEYS="$tmp"
            ;;
        skip) PBS_AUTH_KEYS="skip" ;;
    esac
    [[ -n "$PBS_AUTH_KEYS" ]] || die "auth_keys source not provided"
    export PBS_AUTH_KEYS
}

# Helper: GitHub repo URI prompts. $1=kind (config|auth_keys)
_i_github_spec() {
    local kind="$1"
    local repo branch path pat pat_var
    pat_var="PBS_$(echo "$kind" | tr '[:lower:]' '[:upper:]')_GITHUB_PAT"

    repo="$(tui_input "GitHub repo" "owner/repo (e.g. myuser/homelab):")" \
        || die "aborted at github repo"
    branch="$(tui_input "GitHub branch" "Branch name:" "main")" \
        || die "aborted at github branch"
    path="$(tui_input "GitHub path" "Path inside the repo:" "bootstrap-config.yml")" \
        || die "aborted at github path"
    pat="$(tui_password "GitHub PAT (private repo only)" \
        "Fine-grained Personal Access Token with Contents: read.
Leave empty for public repo.")" || true

    [[ -n "$pat" ]] && export "$pat_var=$pat"
    echo "github:$repo/$branch/$path"
}

# Helper: bucket URI prompts. $1=kind, $2=default-object-name
_i_bucket_uri() {
    local kind="$1" default_obj="$2"
    local bucket obj
    bucket="$(tui_input "$kind — bucket name" \
        "Meta bucket name (the one holding $default_obj):")" \
        || die "aborted at bucket name"
    obj="$(tui_input "$kind — object key" \
        "Object key inside the bucket:" "$default_obj")" \
        || die "aborted at object key"
    echo "${PBS_STORAGE_TYPE:-b2}://$bucket/$obj"
}

_i_meta_credentials_if_needed() {
    sources_need_meta_remote || return 0

    [[ -n "${PBS_META_KEY_ID:-}" ]] \
        || PBS_META_KEY_ID="$(tui_input "Meta bucket — Key ID" \
            "Application key ID with READ access to your meta bucket:")" \
        || die "aborted at meta key id"
    [[ -n "${PBS_META_KEY:-}" ]] \
        || PBS_META_KEY="$(tui_password "Meta bucket — App Key" \
            "Application key secret (hidden):")" \
        || die "aborted at meta key"
    export PBS_META_KEY_ID PBS_META_KEY
}

# Chunks bucket name: ask only if not derivable from config.
# We resolve config later in the pipeline and re-validate then; for the
# summary screen we display "(from config)" when unknown.
_i_summary_and_confirm() {
    local meta_line
    if sources_need_meta_remote; then
        meta_line="  meta key:       ********"
    else
        meta_line="  meta key:       (not needed for this source)"
    fi

    local summary
    summary="$(cat <<EOF
About to bootstrap with:

  storage:        $PBS_STORAGE_TYPE${PBS_STORAGE_ENDPOINT:+ ($PBS_STORAGE_ENDPOINT)}
  chunks key:     ********
$meta_line
  config:         $PBS_CONFIG
  auth_keys:      $PBS_AUTH_KEYS

This will create a new PBS LXC, restore chunks, and register PVE
storage. Pre-existing LXC at the configured VMID will block the run.

Proceed?
EOF
)"

    tui_yesno "Ready" "$summary" default-yes || die "aborted before pipeline start"
    clear
}
