# shellcheck shell=bash
# Thin wrappers over whiptail for consistent dialogs.
#
# Each wrapper returns the user's input via stdout (whiptail writes input
# to stderr by default; the 3>&1 1>&2 2>&3 dance swaps fds so $(...) capture
# works naturally) and exits non-zero on Cancel/Esc — callers must check.

TUI_BACKTITLE="pbs-bootstrap"

tui_msg() {
    whiptail --backtitle "$TUI_BACKTITLE" --title "$1" --msgbox "$2" 14 78
}

tui_input() {
    # $1=title, $2=prompt, $3=default
    whiptail --backtitle "$TUI_BACKTITLE" --title "$1" \
        --inputbox "$2" 12 78 "${3:-}" 3>&1 1>&2 2>&3
}

tui_password() {
    whiptail --backtitle "$TUI_BACKTITLE" --title "$1" \
        --passwordbox "$2" 12 78 3>&1 1>&2 2>&3
}

# Same as tui_input but re-prompts on empty input until the user enters
# something or cancels.
tui_input_nonempty() {
    local val
    while :; do
        val="$(tui_input "$@")" || return 1
        [[ -n "$val" ]] && { echo "$val"; return 0; }
        tui_msg "Empty input" "Value can't be empty. Press OK to try again."
    done
}

tui_password_nonempty() {
    local val
    while :; do
        val="$(tui_password "$@")" || return 1
        [[ -n "$val" ]] && { echo "$val"; return 0; }
        tui_msg "Empty input" "Value can't be empty. Press OK to try again."
    done
}

# tui_radio TITLE PROMPT TAG1 LABEL1 TAG2 LABEL2 ... — first option is default-on.
tui_radio() {
    local title="$1" prompt="$2"; shift 2
    local args=() first=1
    while (( $# >= 2 )); do
        local state="OFF"
        (( first == 1 )) && { state="ON"; first=0; }
        args+=("$1" "$2" "$state")
        shift 2
    done
    whiptail --backtitle "$TUI_BACKTITLE" --title "$title" \
        --radiolist "$prompt" 18 78 8 "${args[@]}" 3>&1 1>&2 2>&3
}

tui_yesno() {
    # $1=title, $2=prompt, $3=default-yes (optional flag)
    local default_arg=()
    [[ "${3:-}" == "default-yes" ]] || default_arg=(--defaultno)
    whiptail --backtitle "$TUI_BACKTITLE" --title "$1" \
        "${default_arg[@]}" --yesno "$2" 14 78
}

# Multi-line paste capture: break out of whiptail, use plain `cat` heredoc,
# then resume. Works in any terminal whiptail does (xterm.js, ssh, console).
tui_paste_capture() {
    local title="$1" outfile="$2"
    clear
    cat <<MSG

─────────────────────────────────────────────────────────────
  $title
─────────────────────────────────────────────────────────────
  Paste your content below.
  When done, press Ctrl-D on a new line.
─────────────────────────────────────────────────────────────
MSG
    cat >"$outfile"
    echo "─────────────────────────────────────────────────────────────"
    echo "  Captured $(wc -l <"$outfile" | tr -d ' ') line(s)."
    echo "─────────────────────────────────────────────────────────────"
    read -r -p "Press Enter to continue..." _
}
