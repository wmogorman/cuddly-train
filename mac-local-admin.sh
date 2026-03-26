#!/bin/bash

set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# Datto RMM macOS component for local admin provisioning.
# Required site or account variables:
#   varLocalAdmin1 - password for DTXLAdmin
#   varLocalAdmin2 - password for DMXAdmin

log() {
    printf '%s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

trim_cr() {
    printf '%s' "$1" | tr -d '\r'
}

require_root() {
    [ "$(id -u)" -eq 0 ] || fail "This script must run as root."
}

require_macos() {
    [ "$(uname -s)" = "Darwin" ] || fail "This script must run on macOS."
}

user_exists() {
    dscl . -read "/Users/$1" >/dev/null 2>&1
}

user_is_admin() {
    dsmemberutil checkmembership -U "$1" -G admin 2>/dev/null | grep -q "is a member"
}

user_is_hidden() {
    defaults read /Library/Preferences/com.apple.loginwindow HiddenUsersList 2>/dev/null | tr -d '()," ' | grep -Fxq "$1"
}

create_user() {
    local username="$1"
    local full_name="$2"
    local password="$3"

    sysadminctl -addUser "$username" -fullName "$full_name" -password "$password"
}

set_user_password() {
    local username="$1"
    local password="$2"

    dscl . -passwd "/Users/$username" "$password"
}

ensure_home_directory() {
    local username="$1"

    if [ ! -d "/Users/$username" ]; then
        createhomedir -c -u "$username" >/dev/null 2>&1 || true
        [ -d "/Users/$username" ] || fail "Home directory for $username was not created."
    fi
}

ensure_admin_membership() {
    local username="$1"

    if user_is_admin "$username"; then
        log "User $username is already in the admin group."
        return
    fi

    dseditgroup -o edit -a "$username" -t user admin >/dev/null
    log "Added $username to the admin group."
}

hide_user_from_login_window() {
    local username="$1"

    if user_is_hidden "$username"; then
        log "User $username is already hidden from the login window."
        return
    fi

    defaults write /Library/Preferences/com.apple.loginwindow HiddenUsersList -array-add "$username"
    log "Hid $username from the login window."
}

ensure_local_admin() {
    local username="$1"
    local full_name="$2"
    local password="$3"
    local variable_name="$4"

    [ -n "$password" ] || fail "Datto variable $variable_name is required."

    if user_exists "$username"; then
        log "User $username already exists. Updating password."
        set_user_password "$username" "$password"
    else
        log "Creating user $username."
        create_user "$username" "$full_name" "$password"
    fi

    ensure_home_directory "$username"
    ensure_admin_membership "$username"
    hide_user_from_login_window "$username"
}

require_root
require_macos

varLocalAdmin1="$(trim_cr "${varLocalAdmin1:-}")"
varLocalAdmin2="$(trim_cr "${varLocalAdmin2:-}")"

ensure_local_admin "DTXLAdmin" "Datamax Local Admin (DTXL)" "$varLocalAdmin1" "varLocalAdmin1"
ensure_local_admin "DMXAdmin" "Datamax Local Admin (DMX)" "$varLocalAdmin2" "varLocalAdmin2"

log "Local admin provisioning completed successfully."
