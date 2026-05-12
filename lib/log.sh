# shellcheck shell=bash
# Minimal logging helpers — sourced by bootstrap.sh.

log_info()   { printf '\033[0;36m[INFO]\033[0m  %s\n' "$*" >&2; }
log_warn()   { printf '\033[0;33m[WARN]\033[0m  %s\n' "$*" >&2; }
log_error()  { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; }
log_header() { printf '\n\033[1;35m== %s ==\033[0m\n' "$*" >&2; }

die() { log_error "$*"; exit 1; }
