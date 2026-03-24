#!/bin/bash

set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# Datto RMM macOS component for Duo Authentication for macOS.
# Required site or account variables:
#   mIntKey  - Duo integration key
#   mSecKey  - Duo secret key
#   APIHost  - Duo API hostname
#
# Optional component or site variables:
#   FailOpen         - true/false, default false
#   SmartcardBypass  - true/false, default false
#   AutoPush         - true/false, default true
#   DuoDownloadUrl   - default https://dl.duosecurity.com/MacLogon-latest.zip
#
# Do not define mIntKey/mSecKey/APIHost at the component level if you want
# Datto site variables with the same names to flow into the script.

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

normalize_bool() {
    local name="$1"
    local value
    value="$(trim_cr "$2" | tr '[:upper:]' '[:lower:]')"

    case "$value" in
        true|false)
            printf '%s' "$value"
            ;;
        *)
            fail "$name must be true or false."
            ;;
    esac
}

require_file() {
    local path="$1"
    local description="$2"

    [ -e "$path" ] || fail "Missing $description at $path."
}

require_root() {
    [ "$(id -u)" -eq 0 ] || fail "This script must run as root."
}

check_macos_support() {
    local version major minor
    version="$(sw_vers -productVersion 2>/dev/null || true)"
    [ -n "$version" ] || fail "Unable to determine the macOS version."

    major="$(printf '%s' "$version" | awk -F. '{print $1}')"
    minor="$(printf '%s' "$version" | awk -F. '{print $2}')"
    minor="${minor:-0}"

    if [ "$major" -lt 10 ]; then
        fail "Unsupported macOS version: $version."
    fi

    if [ "$major" -eq 10 ] && [ "$minor" -lt 15 ]; then
        fail "Duo Authentication for macOS requires macOS 10.15 or later. Detected $version."
    fi

    log "Detected macOS $version."
}

find_first_dir() {
    local candidate

    for candidate in "$@"; do
        [ -d "$candidate" ] || continue
        printf '%s' "$candidate"
        return 0
    done

    return 1
}

find_first_file() {
    local candidate

    for candidate in "$@"; do
        [ -f "$candidate" ] || continue
        printf '%s' "$candidate"
        return 0
    done

    return 1
}

read_plist_value() {
    local plist_path="$1"
    local key="$2"

    /usr/libexec/PlistBuddy -c "Print :$key" "$plist_path" 2>/dev/null || true
}

normalize_installed_bool() {
    local value
    value="$(trim_cr "$1" | tr '[:upper:]' '[:lower:]')"

    case "$value" in
        1|true)
            printf '%s' "true"
            ;;
        0|false)
            printf '%s' "false"
            ;;
        *)
            printf '%s' "$value"
            ;;
    esac
}

require_root
check_macos_support

mIntKey="$(trim_cr "${mIntKey:-}")"
mSecKey="$(trim_cr "${mSecKey:-}")"
APIHost="$(trim_cr "${APIHost:-}")"

[ -n "$mIntKey" ] || fail "Datto variable mIntKey is required."
[ -n "$mSecKey" ] || fail "Datto variable mSecKey is required."
[ -n "$APIHost" ] || fail "Datto variable APIHost is required."

FailOpen="$(normalize_bool "FailOpen" "${FailOpen:-false}")"
SmartcardBypass="$(normalize_bool "SmartcardBypass" "${SmartcardBypass:-false}")"
AutoPush="$(normalize_bool "AutoPush" "${AutoPush:-true}")"
DuoDownloadUrl="$(trim_cr "${DuoDownloadUrl:-https://dl.duosecurity.com/MacLogon-latest.zip}")"

work_dir="$(mktemp -d /private/tmp/duo-maclogon.XXXXXX)"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

zip_path="$work_dir/duo-maclogon.zip"
extract_root="$work_dir/extracted"
plist_path="/private/var/root/Library/Preferences/com.duosecurity.maclogon.plist"

log "Downloading Duo Authentication for macOS..."
curl --fail --location --silent --show-error --retry 3 --connect-timeout 30 "$DuoDownloadUrl" -o "$zip_path"
require_file "$zip_path" "Duo archive"

mkdir -p "$extract_root"
ditto -x -k "$zip_path" "$extract_root"

payload_dir="$(find_first_dir "$extract_root"/MacLogon-*)" || fail "Unable to locate the extracted Duo payload directory."
configure_script="$payload_dir/configure_maclogon.sh"
source_pkg="$(find_first_file "$payload_dir"/MacLogon-NotConfigured-*.pkg)" || fail "Unable to locate the Duo unconfigured package."

require_file "$configure_script" "Duo configuration script"
chmod +x "$configure_script"

log "Configuring the Duo installer package..."
printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$mIntKey" \
    "$mSecKey" \
    "$APIHost" \
    "$FailOpen" \
    "$SmartcardBypass" \
    "$AutoPush" | "$configure_script" "$source_pkg"

configured_pkg=""
for candidate in "$payload_dir"/MacLogon-*.pkg; do
    [ -f "$candidate" ] || continue

    case "$(basename "$candidate")" in
        MacLogon-NotConfigured-*.pkg|MacLogon-Restore-*.pkg|MacLogon-Uninstaller-*.pkg)
            continue
            ;;
        *)
            configured_pkg="$candidate"
            break
            ;;
    esac
done

[ -n "$configured_pkg" ] || fail "Unable to locate the configured Duo package after running configure_maclogon.sh."

log "Installing $(basename "$configured_pkg")..."
installer -pkg "$configured_pkg" -target /

require_file "$plist_path" "Duo configuration plist"

installed_ikey="$(read_plist_value "$plist_path" "ikey")"
installed_skey="$(read_plist_value "$plist_path" "skey")"
installed_api_host="$(read_plist_value "$plist_path" "api_hostname")"
installed_fail_open="$(normalize_installed_bool "$(read_plist_value "$plist_path" "fail_open")")"
installed_smartcard_bypass="$(normalize_installed_bool "$(read_plist_value "$plist_path" "smartcard_bypass")")"
installed_auto_push="$(normalize_installed_bool "$(read_plist_value "$plist_path" "auto_push")")"

[ "$installed_ikey" = "$mIntKey" ] || fail "Verification failed: installed ikey does not match mIntKey."
[ "$installed_skey" = "$mSecKey" ] || fail "Verification failed: installed secret key does not match mSecKey."
[ "$installed_api_host" = "$APIHost" ] || fail "Verification failed: installed API hostname does not match APIHost."
[ "$installed_fail_open" = "$FailOpen" ] || fail "Verification failed: fail_open does not match FailOpen."
[ "$installed_smartcard_bypass" = "$SmartcardBypass" ] || fail "Verification failed: smartcard_bypass does not match SmartcardBypass."
[ "$installed_auto_push" = "$AutoPush" ] || fail "Verification failed: auto_push does not match AutoPush."

log "Duo install verification succeeded."
log "Configured API host: $installed_api_host"
log "Fail open: $installed_fail_open"
log "Smartcard bypass: $installed_smartcard_bypass"
log "Auto push: $installed_auto_push"
log "Reboot or log out and back in before testing macOS console login with Duo."
