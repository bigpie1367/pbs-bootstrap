# shellcheck shell=bash
# Resolve a "source URI" to a local file. One entry point handles every shape
# of input the operator might supply for bootstrap-config.yml or
# authorized_keys.
#
# Supported shapes (URI scheme determines the fetch path):
#
#   b2://<bucket>/<path>              rclone fetch via meta remote (b2 backend)
#   s3://<bucket>/<path>              rclone fetch via meta remote (s3 backend)
#   github:<owner>/<repo>/<branch>/<path>
#                                     curl raw.githubusercontent.com,
#                                     with optional PBS_*_GITHUB_PAT for private
#   https://<...>  |  http://<...>    curl
#   /abs/path  |  ./rel/path          local cp
#   skip                              empty file (auth_keys only)
#   <single-word>                     GitHub user → github.com/<user>.keys
#                                     (auth_keys only)
#
# Usage:
#   resolve_source "$PBS_CONFIG"    /tmp/config.yml    config
#   resolve_source "$PBS_AUTH_KEYS" /tmp/auth_keys     auth_keys

resolve_source() {
    local input="$1" outfile="$2" kind="$3"
    local pat_var
    pat_var="PBS_$(echo "$kind" | tr '[:lower:]' '[:upper:]')_GITHUB_PAT"

    case "$input" in
        b2://*|s3://*)
            local bucket path
            bucket="${input#*://}"; bucket="${bucket%%/*}"
            path="${input#*://}";   path="${path#*/}"
            _resolve_meta_bucket "$bucket" "$path" "$outfile"
            ;;
        github:*)
            local spec="${input#github:}"
            local pat="${!pat_var:-}"
            local headers=()
            [[ -n "$pat" ]] && headers+=(-H "Authorization: Bearer $pat")
            curl -fsSL "${headers[@]}" \
                "https://raw.githubusercontent.com/$spec" -o "$outfile" \
                || die "github fetch failed: $spec (private repo? set $pat_var)"
            ;;
        http://*|https://*)
            curl -fsSL "$input" -o "$outfile" \
                || die "fetch failed: $input"
            ;;
        /*|./*)
            [[ -f "$input" ]] || die "source file not found: $input"
            cp "$input" "$outfile"
            ;;
        skip)
            [[ "$kind" == "auth_keys" ]] || die "'skip' is only valid for auth_keys"
            : >"$outfile"
            ;;
        "")
            die "$kind source is empty (set PBS_${kind^^})"
            ;;
        *)
            # bare word — only valid as GitHub username for auth_keys
            [[ "$kind" == "auth_keys" ]] \
                || die "ambiguous $kind source: '$input' (expected b2://, s3://, github:, https://, /path, or 'skip')"
            curl -fsSL "https://github.com/${input}.keys" -o "$outfile" \
                || die "GitHub keys fetch failed for user: $input"
            ;;
    esac

    if [[ "$input" != "skip" ]]; then
        [[ -s "$outfile" ]] || die "$kind source resolved to empty file: $input"
    fi
}

# rclone fetch from the meta bucket. Caller has already configured the
# 'meta' remote in /root/.config/rclone/rclone.conf (rclone_setup_host).
_resolve_meta_bucket() {
    local bucket="$1" path="$2" outfile="$3"
    rclone copyto "meta:$bucket/$path" "$outfile" \
        || die "meta bucket fetch failed: $bucket/$path (check PBS_META_KEY_ID / PBS_META_KEY)"
}

# Returns 0 if any source needs a meta remote (b2:// or s3:// scheme).
sources_need_meta_remote() {
    case "${PBS_CONFIG:-}"    in b2://*|s3://*) return 0;; esac
    case "${PBS_AUTH_KEYS:-}" in b2://*|s3://*) return 0;; esac
    return 1
}
