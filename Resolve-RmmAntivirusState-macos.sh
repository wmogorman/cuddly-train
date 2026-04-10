#!/bin/bash

set -uo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"

# Datto RMM macOS component for antivirus state remediation.
# Supported target modes:
#   DattoAV
#   WindowsDefender (alias for Microsoft Defender on macOS)
#   MicrosoftDefender

# region Globals
SCRIPT_NAME="$(basename "$0")"
MINIMUM_BASH_MAJOR=3
MINIMUM_BASH_MINOR=2
DEFAULT_LOG_ROOT="/Library/Application Support/DattoRMM/AVRemediation"
DEFAULT_UNINSTALL_TIMEOUT_MINUTES=15

TARGET_MODE_RAW="${TargetMode:-}"
TARGET_MODE=""
APPROVED_PATTERNS_RAW="${ApprovedProductPatterns:-}"
DRY_RUN_RAW="${DryRun:-false}"
UNINSTALL_TIMEOUT_MINUTES="${UninstallTimeoutMinutes:-$DEFAULT_UNINSTALL_TIMEOUT_MINUTES}"
LOG_ROOT="${LogRoot:-$DEFAULT_LOG_ROOT}"

DRY_RUN="false"
UNINSTALL_TIMEOUT_SECONDS=0

COMPUTER_NAME=""
MACOS_VERSION=""
RUN_STAMP=""
LOG_PATH=""
SUMMARY_PATH=""

CURRENT_PRODUCTS=()
CURRENT_PRODUCT_SOURCES=()

BEFORE_PRODUCTS=()
BEFORE_PRODUCT_SOURCES=()
AFTER_PRODUCTS=()
AFTER_PRODUCT_SOURCES=()

ATTEMPT_NAMES=()
ATTEMPT_STATUSES=()
ATTEMPT_EXIT_CODES=()
ATTEMPT_REBOOT_REQUIRED=()
ATTEMPT_REASONS=()
ATTEMPT_COMMANDS=()

DEFENDER_CLI_AVAILABLE="false"
DEFENDER_INSTALLED="false"
DEFENDER_ACTIVE="false"
DEFENDER_HEALTH_SUMMARY="Unavailable"

BEFORE_DEFENDER_CLI_AVAILABLE="false"
BEFORE_DEFENDER_INSTALLED="false"
BEFORE_DEFENDER_ACTIVE="false"
BEFORE_DEFENDER_HEALTH_SUMMARY="Unavailable"

AFTER_DEFENDER_CLI_AVAILABLE="false"
AFTER_DEFENDER_INSTALLED="false"
AFTER_DEFENDER_ACTIVE="false"
AFTER_DEFENDER_HEALTH_SUMMARY="Unavailable"

OUTCOME=""
REBOOT_REQUIRED="false"
NEXT_ACTION=""
FATAL_ERROR=""

APPROVED_PATTERNS=()
ALLOWED_NON_TARGET_PATTERNS=()

DEFAULT_DATTO_PATTERNS=(
    '^Datto AV$'
    '^Datto Antivirus$'
    '^Endpoint Protection SDK$'
)
DEFAULT_DEFENDER_PATTERNS=(
    '^Microsoft Defender$'
    '^Defender for Endpoint$'
    '^Microsoft Defender for Endpoint$'
)
ALWAYS_ALLOWED_NON_TARGET_PATTERNS=(
    '^Datto EDR Agent$'
)
DATTO_ALLOWED_NON_TARGET_PATTERNS=(
    '^Microsoft Defender$'
    '^Defender for Endpoint$'
    '^Microsoft Defender for Endpoint$'
    '^Endpoint Protection SDK$'
)

KNOWN_PRODUCTS=(
    "Datto AV"
    "Endpoint Protection SDK"
    "Datto EDR Agent"
    "Microsoft Defender"
    "Webroot SecureAnywhere"
    "AVG AntiVirus"
    "Avast Security"
    "Avira Security"
    "Bitdefender"
    "CrowdStrike Falcon"
    "Cylance"
    "ESET"
    "Kaspersky"
    "Malwarebytes"
    "McAfee"
    "Norton"
    "SentinelOne"
    "Sophos"
    "Trend Micro"
)

ACTION_SUPPORTED="false"
ACTION_COMMAND=""
ACTION_REASON=""
# endregion Globals

# region GeneralHelpers
log_info() {
    printf '%s [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_PATH"
}

log_warn() {
    printf '%s [WARN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_PATH"
}

log_error() {
    printf '%s [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_PATH"
}

fail_now() {
    FATAL_ERROR="$*"
    log_error "$FATAL_ERROR"
    OUTCOME="Failed"
    NEXT_ACTION="Review the log and summary JSON."
}

trim_cr() {
    printf '%s' "$1" | tr -d '\r'
}

normalize_bool() {
    local value
    value="$(trim_cr "${1:-false}" | tr '[:upper:]' '[:lower:]')"

    case "$value" in
        true|1|yes) printf '%s' "true" ;;
        false|0|no|'') printf '%s' "false" ;;
        *) return 1 ;;
    esac
}

require_root() {
    [ "$(id -u)" -eq 0 ] || return 1
}

require_macos() {
    [ "$(uname -s)" = "Darwin" ] || return 1
}

assert_bash_version() {
    local major minor
    major="${BASH_VERSINFO[0]:-0}"
    minor="${BASH_VERSINFO[1]:-0}"

    if [ "$major" -lt "$MINIMUM_BASH_MAJOR" ]; then
        return 1
    fi

    if [ "$major" -eq "$MINIMUM_BASH_MAJOR" ] && [ "$minor" -lt "$MINIMUM_BASH_MINOR" ]; then
        return 1
    fi

    return 0
}

ensure_directory() {
    [ -d "$1" ] || mkdir -p "$1"
}

array_contains() {
    local needle="$1"
    shift || true
    local item

    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done

    return 1
}

join_by() {
    local separator="$1"
    shift || true
    local first="true"
    local item

    for item in "$@"; do
        [ -n "$item" ] || continue
        if [ "$first" = "true" ]; then
            printf '%s' "$item"
            first="false"
        else
            printf '%s%s' "$separator" "$item"
        fi
    done
}

display_list() {
    if [ "$#" -eq 0 ]; then
        printf '%s' "(none)"
        return
    fi

    join_by "; " "$@"
}

regex_list_contains() {
    local value="$1"
    shift || true
    local pattern

    for pattern in "$@"; do
        printf '%s\n' "$value" | grep -Eiq "$pattern" && return 0
    done

    return 1
}

split_semicolon_list() {
    local raw="$1"
    local -a pieces=()
    local old_ifs="$IFS"
    IFS=';'
    # shellcheck disable=SC2206
    pieces=($raw)
    IFS="$old_ifs"

    local piece trimmed
    for piece in "${pieces[@]}"; do
        trimmed="$(printf '%s' "$piece" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$trimmed" ] && printf '%s\n' "$trimmed"
    done
}

json_escape() {
    printf '%s' "$1" | awk 'BEGIN { RS="^$"; ORS="" } { gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\r/,"\\r"); gsub(/\n/,"\\n"); gsub(/\t/,"\\t"); print }'
}

json_bool() {
    if [ "$1" = "true" ]; then
        printf 'true'
    else
        printf 'false'
    fi
}
# endregion GeneralHelpers

# region InventoryHelpers
PKGUTIL_LIST=""
PROCESS_LIST=""
LAUNCHCTL_LIST=""

reset_current_inventory() {
    CURRENT_PRODUCTS=()
    CURRENT_PRODUCT_SOURCES=()
    DEFENDER_CLI_AVAILABLE="false"
    DEFENDER_INSTALLED="false"
    DEFENDER_ACTIVE="false"
    DEFENDER_HEALTH_SUMMARY="Unavailable"
}

add_current_product() {
    local name="$1"
    local source="$2"
    local i

    for i in "${!CURRENT_PRODUCTS[@]}"; do
        if [ "${CURRENT_PRODUCTS[$i]}" = "$name" ]; then
            case ";${CURRENT_PRODUCT_SOURCES[$i]};" in
                *";$source;"*) ;;
                *) CURRENT_PRODUCT_SOURCES[$i]="${CURRENT_PRODUCT_SOURCES[$i]};$source" ;;
            esac
            return
        fi
    done

    CURRENT_PRODUCTS+=("$name")
    CURRENT_PRODUCT_SOURCES+=("$source")
}

path_exists_any() {
    local candidate
    for candidate in "$@"; do
        [ -e "$candidate" ] && return 0
    done
    return 1
}

receipt_matches() {
    local pattern="$1"
    [ -n "$PKGUTIL_LIST" ] || return 1
    printf '%s\n' "$PKGUTIL_LIST" | grep -Eiq "$pattern"
}

process_matches() {
    local pattern="$1"
    [ -n "$PROCESS_LIST" ] || return 1
    printf '%s\n' "$PROCESS_LIST" | grep -Eiq "$pattern"
}

launchctl_matches() {
    local pattern="$1"
    [ -n "$LAUNCHCTL_LIST" ] || return 1
    printf '%s\n' "$LAUNCHCTL_LIST" | grep -Eiq "$pattern"
}

add_from_paths() {
    local name="$1"
    local source="$2"
    shift 2 || true
    if path_exists_any "$@"; then
        add_current_product "$name" "$source"
    fi
}

add_from_receipts() {
    local name="$1"
    local pattern="$2"
    if receipt_matches "$pattern"; then
        add_current_product "$name" "Receipt"
    fi
}

add_from_processes() {
    local name="$1"
    local pattern="$2"
    if process_matches "$pattern"; then
        add_current_product "$name" "Process"
    fi
}

add_from_launchctl() {
    local name="$1"
    local pattern="$2"
    if launchctl_matches "$pattern"; then
        add_current_product "$name" "Launch"
    fi
}

collect_runtime_context() {
    PKGUTIL_LIST="$(pkgutil --pkgs 2>/dev/null || true)"
    PROCESS_LIST="$(ps axo command= 2>/dev/null || true)"
    LAUNCHCTL_LIST="$(launchctl list 2>/dev/null || true)"
}

collect_defender_status() {
    local output=""

    if command -v mdatp >/dev/null 2>&1; then
        DEFENDER_CLI_AVAILABLE="true"
        DEFENDER_INSTALLED="true"
        add_current_product "Microsoft Defender" "CLI"

        output="$(mdatp health --output json 2>/dev/null || mdatp health 2>/dev/null || true)"
        [ -n "$output" ] || output="Health unavailable"

        if printf '%s\n' "$output" | grep -Eiq '"real_time_protection_enabled"[[:space:]]*:[[:space:]]*true|real_time_protection_enabled[[:space:]]*[:=][[:space:]]*true'; then
            DEFENDER_ACTIVE="true"
        elif printf '%s\n' "$output" | grep -Eiq '"healthy"[[:space:]]*:[[:space:]]*true|healthy[[:space:]]*[:=][[:space:]]*true'; then
            DEFENDER_ACTIVE="true"
        fi

        DEFENDER_HEALTH_SUMMARY="$(printf '%s\n' "$output" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
        return
    fi

    add_from_paths "Microsoft Defender" "App" \
        "/Applications/Microsoft Defender.app" \
        "/Applications/Microsoft Defender for Endpoint.app"
    add_from_receipts "Microsoft Defender" 'microsoft\.(wdav|defender)'
    add_from_launchctl "Microsoft Defender" 'com\.microsoft\.(wdav|mdatp)'
    add_from_processes "Microsoft Defender" 'microsoft defender|wdav|mdatp'

    if array_contains "Microsoft Defender" "${CURRENT_PRODUCTS[@]}"; then
        DEFENDER_INSTALLED="true"
        if launchctl_matches 'com\.microsoft\.(wdav|mdatp)' || process_matches 'microsoft defender|wdav|mdatp'; then
            DEFENDER_ACTIVE="true"
        fi
        DEFENDER_HEALTH_SUMMARY="CLI unavailable"
    fi
}

collect_known_products() {
    add_from_paths "Datto AV" "App" \
        "/Applications/Datto AV.app" \
        "/Applications/Datto Antivirus.app"
    add_from_paths "Datto AV" "Support" \
        "/Library/Application Support/Datto AV" \
        "/Library/Application Support/Datto Antivirus" \
        "/Library/Application Support/Infocyte/agent/dattoav"
    add_from_receipts "Datto AV" 'datto.*av|infocyte.*dattoav'
    add_from_processes "Datto AV" 'dattoav|wsc_agent'

    add_from_paths "Endpoint Protection SDK" "Support" \
        "/Library/Application Support/Infocyte/agent/dattoav/Endpoint Protection SDK" \
        "/Library/Application Support/Datto AV/Endpoint Protection SDK"
    add_from_receipts "Endpoint Protection SDK" 'endpoint.*protection.*sdk|avira.*endpoint'

    add_from_paths "Datto EDR Agent" "App" "/Applications/Datto EDR Agent.app"
    add_from_paths "Datto EDR Agent" "Support" \
        "/Library/Application Support/Infocyte" \
        "/Library/Application Support/Datto EDR"
    add_from_receipts "Datto EDR Agent" 'datto.*edr|infocyte'
    add_from_launchctl "Datto EDR Agent" 'infocyte|datto.*edr'
    add_from_processes "Datto EDR Agent" 'infocyte|datto edr'

    collect_defender_status

    add_from_paths "Webroot SecureAnywhere" "App" "/Applications/Webroot SecureAnywhere.app"
    add_from_paths "Webroot SecureAnywhere" "Support" "/Library/Application Support/Webroot"
    add_from_receipts "Webroot SecureAnywhere" 'webroot'
    add_from_processes "Webroot SecureAnywhere" 'webroot|wsdaemon'

    add_from_paths "AVG AntiVirus" "App" "/Applications/AVG AntiVirus.app"
    add_from_paths "AVG AntiVirus" "Support" "/Library/Application Support/AVG"
    add_from_receipts "AVG AntiVirus" 'avg'
    add_from_processes "AVG AntiVirus" '\bavg\b'

    add_from_paths "Avast Security" "App" "/Applications/Avast Security.app"
    add_from_paths "Avast Security" "Support" "/Library/Application Support/Avast"
    add_from_receipts "Avast Security" 'avast'
    add_from_processes "Avast Security" 'avast'

    add_from_paths "Avira Security" "App" \
        "/Applications/Avira Security.app" \
        "/Applications/Avira Antivirus.app"
    add_from_paths "Avira Security" "Support" "/Library/Application Support/Avira"
    add_from_receipts "Avira Security" 'avira'
    add_from_processes "Avira Security" 'avira'

    add_from_paths "Bitdefender" "App" \
        "/Applications/Bitdefender Antivirus for Mac.app" \
        "/Applications/Bitdefender.app"
    add_from_paths "Bitdefender" "Support" "/Library/Bitdefender"
    add_from_receipts "Bitdefender" 'bitdefender'
    add_from_processes "Bitdefender" 'bitdefender'

    add_from_paths "CrowdStrike Falcon" "App" "/Applications/Falcon.app"
    add_from_paths "CrowdStrike Falcon" "Support" "/Library/CS"
    add_from_receipts "CrowdStrike Falcon" 'crowdstrike|falcon'
    add_from_launchctl "CrowdStrike Falcon" 'falcon'
    add_from_processes "CrowdStrike Falcon" 'falcon'

    add_from_paths "Cylance" "App" "/Applications/CylancePROTECT.app"
    add_from_paths "Cylance" "Support" "/Library/Application Support/Cylance"
    add_from_receipts "Cylance" 'cylance'
    add_from_processes "Cylance" 'cylance'

    add_from_paths "ESET" "App" \
        "/Applications/ESET Endpoint Antivirus.app" \
        "/Applications/ESET Cyber Security.app"
    add_from_paths "ESET" "Support" "/Library/Application Support/ESET"
    add_from_receipts "ESET" 'eset'
    add_from_processes "ESET" 'eset'

    add_from_paths "Kaspersky" "App" "/Applications/Kaspersky.app"
    add_from_paths "Kaspersky" "Support" "/Library/Application Support/Kaspersky Lab"
    add_from_receipts "Kaspersky" 'kaspersky'
    add_from_processes "Kaspersky" 'kaspersky'

    add_from_paths "Malwarebytes" "App" "/Applications/Malwarebytes.app"
    add_from_paths "Malwarebytes" "Support" "/Library/Application Support/Malwarebytes"
    add_from_receipts "Malwarebytes" 'malwarebytes'
    add_from_processes "Malwarebytes" 'malwarebytes'

    add_from_paths "McAfee" "App" "/Applications/McAfee Endpoint Security for Mac.app"
    add_from_paths "McAfee" "Support" "/usr/local/McAfee"
    add_from_receipts "McAfee" 'mcafee'
    add_from_processes "McAfee" 'mcafee'

    add_from_paths "Norton" "App" \
        "/Applications/Norton.app" \
        "/Applications/Norton 360.app"
    add_from_paths "Norton" "Support" "/Library/Application Support/Norton"
    add_from_receipts "Norton" 'norton|symantec'
    add_from_processes "Norton" 'norton|symantec'

    add_from_paths "SentinelOne" "App" "/Applications/SentinelOne.app"
    add_from_paths "SentinelOne" "Support" "/Library/Sentinel"
    add_from_receipts "SentinelOne" 'sentinelone|sentinel'
    add_from_launchctl "SentinelOne" 'sentinel'
    add_from_processes "SentinelOne" 'sentinel'

    add_from_paths "Sophos" "App" \
        "/Applications/Sophos/Sophos Endpoint.app" \
        "/Applications/Sophos Anti-Virus.app"
    add_from_paths "Sophos" "Support" "/Library/Sophos Anti-Virus"
    add_from_receipts "Sophos" 'sophos'
    add_from_processes "Sophos" 'sophos'

    add_from_paths "Trend Micro" "App" \
        "/Applications/Trend Micro Security.app" \
        "/Applications/Trend Micro Apex One Security Agent.app"
    add_from_paths "Trend Micro" "Support" "/Library/Application Support/Trend Micro"
    add_from_receipts "Trend Micro" 'trend[._ -]?micro'
    add_from_processes "Trend Micro" 'trend[._ -]?micro'
}

collect_inventory() {
    reset_current_inventory
    collect_runtime_context
    collect_known_products
}

copy_inventory_snapshot() {
    local prefix="$1"

    case "$prefix" in
        before)
            BEFORE_PRODUCTS=("${CURRENT_PRODUCTS[@]}")
            BEFORE_PRODUCT_SOURCES=("${CURRENT_PRODUCT_SOURCES[@]}")
            BEFORE_DEFENDER_CLI_AVAILABLE="$DEFENDER_CLI_AVAILABLE"
            BEFORE_DEFENDER_INSTALLED="$DEFENDER_INSTALLED"
            BEFORE_DEFENDER_ACTIVE="$DEFENDER_ACTIVE"
            BEFORE_DEFENDER_HEALTH_SUMMARY="$DEFENDER_HEALTH_SUMMARY"
            ;;
        after)
            AFTER_PRODUCTS=("${CURRENT_PRODUCTS[@]}")
            AFTER_PRODUCT_SOURCES=("${CURRENT_PRODUCT_SOURCES[@]}")
            AFTER_DEFENDER_CLI_AVAILABLE="$DEFENDER_CLI_AVAILABLE"
            AFTER_DEFENDER_INSTALLED="$DEFENDER_INSTALLED"
            AFTER_DEFENDER_ACTIVE="$DEFENDER_ACTIVE"
            AFTER_DEFENDER_HEALTH_SUMMARY="$DEFENDER_HEALTH_SUMMARY"
            ;;
    esac
}
# endregion InventoryHelpers

# region UninstallHelpers
record_attempt() {
    ATTEMPT_NAMES+=("$1")
    ATTEMPT_STATUSES+=("$2")
    ATTEMPT_EXIT_CODES+=("$3")
    ATTEMPT_REBOOT_REQUIRED+=("$4")
    ATTEMPT_REASONS+=("$5")
    ATTEMPT_COMMANDS+=("$6")
}

find_first_executable() {
    local candidate
    for candidate in "$@"; do
        [ -x "$candidate" ] && {
            printf '%s' "$candidate"
            return 0
        }
    done
    return 1
}

set_action_if_script_found() {
    local reason="$1"
    shift || true
    local candidate

    ACTION_SUPPORTED="false"
    ACTION_COMMAND=""
    ACTION_REASON=""

    for candidate in "$@"; do
        if [ -x "$candidate" ]; then
            ACTION_SUPPORTED="true"
            ACTION_COMMAND="$candidate"
            ACTION_REASON="$reason"
            return 0
        fi
    done

    return 1
}

resolve_uninstall_action() {
    local product_name="$1"

    ACTION_SUPPORTED="false"
    ACTION_COMMAND=""
    ACTION_REASON="No safe silent uninstall definition was found for this product on macOS."

    case "$product_name" in
        "AVG AntiVirus")
            set_action_if_script_found \
                "Using discovered AVG uninstall script." \
                "/Applications/AVG AntiVirus.app/Contents/Backend/hub/uninstall.sh" \
                "/Applications/AVG AntiVirus.app/Contents/Resources/uninstall.sh" \
                "/Library/Application Support/AVG/uninstall.sh"
            ;;
        "Avast Security")
            set_action_if_script_found \
                "Using discovered Avast uninstall script." \
                "/Applications/Avast Security.app/Contents/Backend/hub/uninstall.sh" \
                "/Applications/Avast Security.app/Contents/Resources/uninstall.sh" \
                "/Library/Application Support/Avast/uninstall.sh"
            ;;
        "Avira Security")
            set_action_if_script_found \
                "Using discovered Avira uninstall script." \
                "/Applications/Avira Security.app/Contents/Resources/uninstall.sh" \
                "/Applications/Avira Antivirus.app/Contents/Resources/uninstall.sh" \
                "/Library/Application Support/Avira/uninstall.sh"
            ;;
        "Bitdefender")
            set_action_if_script_found \
                "Using discovered Bitdefender uninstall script." \
                "/Library/Bitdefender/Uninstaller/UninstallBitdefender.sh" \
                "/Applications/Bitdefender Antivirus for Mac.app/Contents/Resources/uninstall.sh"
            ;;
        "Kaspersky")
            set_action_if_script_found \
                "Using discovered Kaspersky uninstall script." \
                "/Library/Application Support/Kaspersky Lab/uninstall.sh"
            ;;
        "McAfee")
            set_action_if_script_found \
                "Using discovered McAfee uninstall script." \
                "/usr/local/McAfee/uninstall.sh" \
                "/Library/McAfee/cma/uninstall.sh"
            ;;
        "Sophos")
            set_action_if_script_found \
                "Using discovered Sophos uninstall script." \
                "/Library/Application Support/Sophos/Remove Sophos Endpoint.sh" \
                "/Library/Sophos Anti-Virus/remove_sophos.sh"
            ;;
        "Trend Micro")
            set_action_if_script_found \
                "Using discovered Trend Micro uninstall script." \
                "/Applications/Trend Micro Security.app/Contents/Resources/uninstall.sh" \
                "/Library/Application Support/Trend Micro/uninstall.sh"
            ;;
    esac
}

kill_process_tree() {
    local pid="$1"
    local child

    while read -r child; do
        [ -n "$child" ] || continue
        kill_process_tree "$child"
    done < <(pgrep -P "$pid" 2>/dev/null || true)

    kill -TERM "$pid" 2>/dev/null || true
}

force_kill_process_tree() {
    local pid="$1"
    local child

    while read -r child; do
        [ -n "$child" ] || continue
        force_kill_process_tree "$child"
    done < <(pgrep -P "$pid" 2>/dev/null || true)

    kill -KILL "$pid" 2>/dev/null || true
}

run_command_with_timeout() {
    local command_path="$1"
    local stdout_file="$2"
    local stderr_file="$3"
    shift 3 || true

    local pid exit_code now deadline
    local timed_out="false"

    "$command_path" "$@" >"$stdout_file" 2>"$stderr_file" &
    pid=$!
    deadline=$(( $(date '+%s') + UNINSTALL_TIMEOUT_SECONDS ))

    while kill -0 "$pid" 2>/dev/null; do
        now="$(date '+%s')"
        if [ "$now" -ge "$deadline" ]; then
            timed_out="true"
            kill_process_tree "$pid"
            sleep 2
            force_kill_process_tree "$pid"
            break
        fi
        sleep 1
    done

    if [ "$timed_out" = "true" ]; then
        wait "$pid" 2>/dev/null || true
        printf 'TIMEOUT|%s\n' "$pid"
        return 0
    fi

    wait "$pid"
    exit_code=$?
    printf 'EXIT|%s|%s\n' "$pid" "$exit_code"
}

invoke_uninstall_action() {
    local product_name="$1"
    local stdout_file stderr_file result_line result_type result_pid result_exit_code
    local attempt_reason status reboot_required combined_output

    resolve_uninstall_action "$product_name"
    if [ "$ACTION_SUPPORTED" != "true" ]; then
        log_warn "Manual cleanup required for [$product_name]: $ACTION_REASON"
        record_attempt "$product_name" "ManualCleanupRequired" "" "false" "$ACTION_REASON" ""
        return
    fi

    if [ "$DRY_RUN" = "true" ]; then
        log_info "DryRun: would uninstall [$product_name] with [$ACTION_COMMAND]."
        record_attempt "$product_name" "DryRun" "" "false" "DryRun enabled. Would run: $ACTION_COMMAND" "$ACTION_COMMAND"
        return
    fi

    stdout_file="$(mktemp "/private/tmp/${SCRIPT_NAME}.stdout.XXXXXX")"
    stderr_file="$(mktemp "/private/tmp/${SCRIPT_NAME}.stderr.XXXXXX")"
    log_info "Starting uninstall for [$product_name] using [$ACTION_COMMAND]."
    result_line="$(run_command_with_timeout "$ACTION_COMMAND" "$stdout_file" "$stderr_file")"

    result_type="$(printf '%s' "$result_line" | awk -F'|' '{print $1}')"
    result_pid="$(printf '%s' "$result_line" | awk -F'|' '{print $2}')"
    result_exit_code="$(printf '%s' "$result_line" | awk -F'|' '{print $3}')"
    attempt_reason="$ACTION_REASON"
    reboot_required="false"

    combined_output="$( { cat "$stdout_file" 2>/dev/null; cat "$stderr_file" 2>/dev/null; } | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' )"
    rm -f "$stdout_file" "$stderr_file"

    if [ "$result_type" = "TIMEOUT" ]; then
        status="Failed"
        attempt_reason="Process timed out after ${UNINSTALL_TIMEOUT_MINUTES} minute(s) and was terminated."
        log_error "Uninstall for [$product_name] timed out (PID $result_pid)."
        record_attempt "$product_name" "$status" "" "$reboot_required" "$attempt_reason" "$ACTION_COMMAND"
        return
    fi

    if [ "${result_exit_code:-}" = "0" ]; then
        status="Removed"
        if printf '%s\n' "$combined_output" | grep -Eiq '\breboot\b|\brestart\b'; then
            status="PendingReboot"
            reboot_required="true"
            attempt_reason="Uninstall completed and indicated a restart may be required."
        else
            attempt_reason="Uninstall completed with exit code 0."
        fi
        log_info "Uninstall for [$product_name] completed with exit code 0."
        record_attempt "$product_name" "$status" "$result_exit_code" "$reboot_required" "$attempt_reason" "$ACTION_COMMAND"
        return
    fi

    status="Failed"
    attempt_reason="Uninstall failed with exit code ${result_exit_code:-unknown}."
    [ -n "$combined_output" ] && attempt_reason="$attempt_reason Output: $combined_output"
    log_error "Uninstall for [$product_name] failed with exit code ${result_exit_code:-unknown}."
    record_attempt "$product_name" "$status" "$result_exit_code" "$reboot_required" "$attempt_reason" "$ACTION_COMMAND"
}
# endregion UninstallHelpers

# region EvaluationHelpers
get_blocking_products() {
    local -a blocking=()
    local product

    for product in "${CURRENT_PRODUCTS[@]}"; do
        if regex_list_contains "$product" "${APPROVED_PATTERNS[@]}"; then
            continue
        fi
        if regex_list_contains "$product" "${ALLOWED_NON_TARGET_PATTERNS[@]}"; then
            continue
        fi
        blocking+=("$product")
    done

    printf '%s\n' "${blocking[@]}"
}

get_target_presence() {
    local datto_present="false"
    local defender_present="false"
    local defender_satisfied="false"
    local product

    for product in "${CURRENT_PRODUCTS[@]}"; do
        if regex_list_contains "$product" "${DEFAULT_DATTO_PATTERNS[@]}"; then
            datto_present="true"
        fi
        if regex_list_contains "$product" "${DEFAULT_DEFENDER_PATTERNS[@]}"; then
            defender_present="true"
        fi
    done

    if [ "$DEFENDER_INSTALLED" = "true" ] || [ "$defender_present" = "true" ]; then
        defender_present="true"
    fi

    if [ "$defender_present" = "true" ] && { [ "$DEFENDER_ACTIVE" = "true" ] || [ "$DEFENDER_CLI_AVAILABLE" = "false" ]; }; then
        defender_satisfied="true"
    fi

    printf '%s|%s|%s\n' "$datto_present" "$defender_present" "$defender_satisfied"
}

determine_outcome() {
    local -a before_blocking=()
    local -a after_blocking=()
    local result datto_present defender_present defender_satisfied
    local i successful_removal="false" failed_attempts="false" manual_cleanup="false" dry_run_only="false"
    local before_datto_present before_defender_present before_defender_satisfied already_satisfied="false"

    while read -r result; do
        [ -n "$result" ] && before_blocking+=("$result")
    done < <(
        CURRENT_PRODUCTS=("${BEFORE_PRODUCTS[@]}")
        CURRENT_PRODUCT_SOURCES=("${BEFORE_PRODUCT_SOURCES[@]}")
        DEFENDER_CLI_AVAILABLE="$BEFORE_DEFENDER_CLI_AVAILABLE"
        DEFENDER_INSTALLED="$BEFORE_DEFENDER_INSTALLED"
        DEFENDER_ACTIVE="$BEFORE_DEFENDER_ACTIVE"
        get_blocking_products
    )

    while read -r result; do
        [ -n "$result" ] && after_blocking+=("$result")
    done < <(get_blocking_products)

    result="$(get_target_presence)"
    datto_present="$(printf '%s' "$result" | awk -F'|' '{print $1}')"
    defender_present="$(printf '%s' "$result" | awk -F'|' '{print $2}')"
    defender_satisfied="$(printf '%s' "$result" | awk -F'|' '{print $3}')"

    result="$(
        CURRENT_PRODUCTS=("${BEFORE_PRODUCTS[@]}")
        CURRENT_PRODUCT_SOURCES=("${BEFORE_PRODUCT_SOURCES[@]}")
        DEFENDER_CLI_AVAILABLE="$BEFORE_DEFENDER_CLI_AVAILABLE"
        DEFENDER_INSTALLED="$BEFORE_DEFENDER_INSTALLED"
        DEFENDER_ACTIVE="$BEFORE_DEFENDER_ACTIVE"
        get_target_presence
    )"
    before_datto_present="$(printf '%s' "$result" | awk -F'|' '{print $1}')"
    before_defender_present="$(printf '%s' "$result" | awk -F'|' '{print $2}')"
    before_defender_satisfied="$(printf '%s' "$result" | awk -F'|' '{print $3}')"

    if [ "${#before_blocking[@]}" -eq 0 ]; then
        if [ "$TARGET_MODE" = "DattoAV" ] && [ "$before_datto_present" = "true" ]; then
            already_satisfied="true"
        fi
        if [ "$TARGET_MODE" = "MicrosoftDefender" ] && [ "$before_defender_satisfied" = "true" ]; then
            already_satisfied="true"
        fi
    fi

    for i in "${!ATTEMPT_STATUSES[@]}"; do
        case "${ATTEMPT_STATUSES[$i]}" in
            Removed|PendingReboot) successful_removal="true" ;;
            Failed) failed_attempts="true" ;;
            ManualCleanupRequired) manual_cleanup="true" ;;
            DryRun) dry_run_only="true" ;;
        esac
        [ "${ATTEMPT_REBOOT_REQUIRED[$i]}" = "true" ] && REBOOT_REQUIRED="true"
    done

    if [ "${#after_blocking[@]}" -eq 0 ]; then
        if [ "$TARGET_MODE" = "DattoAV" ] && [ "$datto_present" != "true" ]; then
            OUTCOME="NeedsDattoPolicy"
            NEXT_ACTION="Check Datto AV policy/install."
            return
        fi

        if [ "$TARGET_MODE" = "MicrosoftDefender" ] && [ "$defender_satisfied" != "true" ]; then
            OUTCOME="Failed"
            NEXT_ACTION="Install or repair Microsoft Defender, then rerun."
            return
        fi

        if [ "$already_satisfied" = "true" ] && [ "$successful_removal" != "true" ]; then
            OUTCOME="NoActionNeeded"
            NEXT_ACTION="No further action."
            return
        fi

        if [ "$successful_removal" = "true" ] && [ "$REBOOT_REQUIRED" = "true" ]; then
            OUTCOME="RemediatedPendingReboot"
            NEXT_ACTION="Reboot and rerun."
            return
        fi

        if [ "$successful_removal" = "true" ]; then
            OUTCOME="Remediated"
            NEXT_ACTION="No further action."
            return
        fi

        OUTCOME="NoActionNeeded"
        NEXT_ACTION="No further action."
        return
    fi

    if [ "$failed_attempts" = "true" ]; then
        OUTCOME="Failed"
        NEXT_ACTION="Review failed uninstall attempts and the log output."
        return
    fi

    if [ "$DRY_RUN" = "true" ] && [ "$manual_cleanup" != "true" ]; then
        OUTCOME="Failed"
        NEXT_ACTION="Run again without --dry-run after validating the uninstall plan."
        return
    fi

    OUTCOME="NeedsManualCleanup"
    NEXT_ACTION="Manual vendor cleanup tool required or investigate stale AV registration."
}

write_console_summary() {
    local i

    printf 'Resolve RMM Antivirus State - %s\n' "$COMPUTER_NAME"
    printf 'Target Mode: %s\n' "$TARGET_MODE"
    printf 'Approved Patterns: %s\n' "$(display_list "${APPROVED_PATTERNS[@]}")"
    printf 'Products Before: %s\n' "$(display_list "${BEFORE_PRODUCTS[@]}")"
    printf 'Products After: %s\n' "$(display_list "${AFTER_PRODUCTS[@]}")"
    printf 'Defender Status: CLI Available=%s; Installed=%s; Active=%s\n' "$AFTER_DEFENDER_CLI_AVAILABLE" "$AFTER_DEFENDER_INSTALLED" "$AFTER_DEFENDER_ACTIVE"

    if [ "${#ATTEMPT_NAMES[@]}" -gt 0 ]; then
        printf 'Uninstall Attempts:\n'
        for i in "${!ATTEMPT_NAMES[@]}"; do
            printf -- '- %s: %s' "${ATTEMPT_NAMES[$i]}" "${ATTEMPT_STATUSES[$i]}"
            [ -n "${ATTEMPT_EXIT_CODES[$i]}" ] && printf ' (exit %s)' "${ATTEMPT_EXIT_CODES[$i]}"
            [ -n "${ATTEMPT_REASONS[$i]}" ] && printf ' - %s' "${ATTEMPT_REASONS[$i]}"
            printf '\n'
        done
    else
        printf 'Uninstall Attempts: (none)\n'
    fi

    printf 'Outcome: %s\n' "$OUTCOME"
    printf 'Reboot Required: %s\n' "$( [ "$REBOOT_REQUIRED" = "true" ] && printf 'Yes' || printf 'No' )"
    printf 'Next Action: %s\n' "$NEXT_ACTION"
    printf 'Log Path: %s\n' "$LOG_PATH"
    printf 'Summary JSON: %s\n' "$SUMMARY_PATH"
}

write_summary_json() {
    local i

    {
        printf '{\n'
        printf '  "ComputerName": "%s",\n' "$(json_escape "$COMPUTER_NAME")"
        printf '  "Timestamp": "%s",\n' "$(json_escape "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")"
        printf '  "macOSVersion": "%s",\n' "$(json_escape "$MACOS_VERSION")"
        printf '  "TargetMode": "%s",\n' "$(json_escape "$TARGET_MODE")"
        printf '  "BashVersion": "%s",\n' "$(json_escape "$BASH_VERSION")"
        printf '  "DryRun": %s,\n' "$(json_bool "$DRY_RUN")"
        printf '  "UninstallTimeoutMinutes": %s,\n' "$UNINSTALL_TIMEOUT_MINUTES"
        printf '  "ApprovedProductPatterns": ['
        for i in "${!APPROVED_PATTERNS[@]}"; do
            [ "$i" -gt 0 ] && printf ', '
            printf '"%s"' "$(json_escape "${APPROVED_PATTERNS[$i]}")"
        done
        printf '],\n'
        printf '  "BeforeProducts": ['
        for i in "${!BEFORE_PRODUCTS[@]}"; do
            [ "$i" -gt 0 ] && printf ', '
            printf '{"Name":"%s","Sources":"%s"}' "$(json_escape "${BEFORE_PRODUCTS[$i]}")" "$(json_escape "${BEFORE_PRODUCT_SOURCES[$i]}")"
        done
        printf '],\n'
        printf '  "AfterProducts": ['
        for i in "${!AFTER_PRODUCTS[@]}"; do
            [ "$i" -gt 0 ] && printf ', '
            printf '{"Name":"%s","Sources":"%s"}' "$(json_escape "${AFTER_PRODUCTS[$i]}")" "$(json_escape "${AFTER_PRODUCT_SOURCES[$i]}")"
        done
        printf '],\n'
        printf '  "DefenderStatus": {"CliAvailable": %s, "Installed": %s, "Active": %s, "Summary": "%s"},\n' \
            "$(json_bool "$AFTER_DEFENDER_CLI_AVAILABLE")" \
            "$(json_bool "$AFTER_DEFENDER_INSTALLED")" \
            "$(json_bool "$AFTER_DEFENDER_ACTIVE")" \
            "$(json_escape "$AFTER_DEFENDER_HEALTH_SUMMARY")"
        printf '  "UninstallAttempts": ['
        for i in "${!ATTEMPT_NAMES[@]}"; do
            [ "$i" -gt 0 ] && printf ', '
            printf '{"Name":"%s","Status":"%s","ExitCode":"%s","RebootRequired":%s,"Reason":"%s","Command":"%s"}' \
                "$(json_escape "${ATTEMPT_NAMES[$i]}")" \
                "$(json_escape "${ATTEMPT_STATUSES[$i]}")" \
                "$(json_escape "${ATTEMPT_EXIT_CODES[$i]}")" \
                "$(json_bool "${ATTEMPT_REBOOT_REQUIRED[$i]}")" \
                "$(json_escape "${ATTEMPT_REASONS[$i]}")" \
                "$(json_escape "${ATTEMPT_COMMANDS[$i]}")"
        done
        printf '],\n'
        printf '  "Outcome": "%s",\n' "$(json_escape "$OUTCOME")"
        printf '  "RebootRequired": %s,\n' "$(json_bool "$REBOOT_REQUIRED")"
        printf '  "NextAction": "%s",\n' "$(json_escape "$NEXT_ACTION")"
        printf '  "LogPath": "%s",\n' "$(json_escape "$LOG_PATH")"
        printf '  "SummaryPath": "%s",\n' "$(json_escape "$SUMMARY_PATH")"
        printf '  "FatalError": "%s"\n' "$(json_escape "$FATAL_ERROR")"
        printf '}\n'
    } >"$SUMMARY_PATH"
}
# endregion EvaluationHelpers

# region Main
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --target-mode)
                [ "$#" -ge 2 ] || return 1
                TARGET_MODE_RAW="$2"
                shift 2
                ;;
            --approved-product-patterns)
                [ "$#" -ge 2 ] || return 1
                APPROVED_PATTERNS_RAW="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN_RAW="true"
                shift
                ;;
            --uninstall-timeout-minutes)
                [ "$#" -ge 2 ] || return 1
                UNINSTALL_TIMEOUT_MINUTES="$2"
                shift 2
                ;;
            --log-root)
                [ "$#" -ge 2 ] || return 1
                LOG_ROOT="$2"
                shift 2
                ;;
            --help|-h)
                printf 'Usage: %s --target-mode DattoAV|WindowsDefender|MicrosoftDefender [--approved-product-patterns "regex;regex"] [--dry-run] [--uninstall-timeout-minutes 15] [--log-root "/Library/Application Support/DattoRMM/AVRemediation"]\n' "$SCRIPT_NAME"
                exit 0
                ;;
            *)
                return 1
                ;;
        esac
    done

    return 0
}

normalize_target_mode() {
    case "$(trim_cr "$TARGET_MODE_RAW")" in
        DattoAV) TARGET_MODE="DattoAV" ;;
        WindowsDefender|MicrosoftDefender) TARGET_MODE="MicrosoftDefender" ;;
        *)
            return 1
            ;;
    esac
}

initialize_settings() {
    local pattern

    DRY_RUN="$(normalize_bool "$DRY_RUN_RAW")" || return 1

    case "$UNINSTALL_TIMEOUT_MINUTES" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    [ "$UNINSTALL_TIMEOUT_MINUTES" -ge 1 ] && [ "$UNINSTALL_TIMEOUT_MINUTES" -le 60 ] || return 1
    UNINSTALL_TIMEOUT_SECONDS=$(( UNINSTALL_TIMEOUT_MINUTES * 60 ))

    if [ -n "$APPROVED_PATTERNS_RAW" ]; then
        while read -r pattern; do
            [ -n "$pattern" ] && APPROVED_PATTERNS+=("$pattern")
        done < <(split_semicolon_list "$APPROVED_PATTERNS_RAW")
    fi

    if [ "${#APPROVED_PATTERNS[@]}" -eq 0 ]; then
        if [ "$TARGET_MODE" = "DattoAV" ]; then
            APPROVED_PATTERNS=("${DEFAULT_DATTO_PATTERNS[@]}")
        else
            APPROVED_PATTERNS=("${DEFAULT_DEFENDER_PATTERNS[@]}")
        fi
    fi

    ALLOWED_NON_TARGET_PATTERNS=("${ALWAYS_ALLOWED_NON_TARGET_PATTERNS[@]}")
    if [ "$TARGET_MODE" = "DattoAV" ]; then
        ALLOWED_NON_TARGET_PATTERNS+=("${DATTO_ALLOWED_NON_TARGET_PATTERNS[@]}")
    fi

    COMPUTER_NAME="$(scutil --get ComputerName 2>/dev/null || hostname -s 2>/dev/null || hostname)"
    MACOS_VERSION="$(sw_vers -productVersion 2>/dev/null || printf 'Unknown')"
    RUN_STAMP="$(date '+%Y%m%d-%H%M%S')-$$"
    LOG_PATH="$LOG_ROOT/${COMPUTER_NAME}-${RUN_STAMP}.log"
    SUMMARY_PATH="$LOG_ROOT/${COMPUTER_NAME}-${RUN_STAMP}.json"

    ensure_directory "$LOG_ROOT"
    : >"$LOG_PATH"
}

main() {
    local -a before_blocking=()
    local product

    if ! parse_args "$@"; then
        printf 'ERROR: Invalid arguments.\n' >&2
        return 1
    fi

    if ! normalize_target_mode; then
        printf 'ERROR: TargetMode must be DattoAV, WindowsDefender, or MicrosoftDefender.\n' >&2
        return 1
    fi

    if ! initialize_settings; then
        printf 'ERROR: Invalid component configuration.\n' >&2
        return 1
    fi

    if ! require_macos; then
        fail_now "This script must run on macOS."
    elif ! require_root; then
        fail_now "This script must run as root."
    elif ! assert_bash_version; then
        fail_now "Bash ${MINIMUM_BASH_MAJOR}.${MINIMUM_BASH_MINOR}+ is required. Current version: ${BASH_VERSION}"
    fi

    if [ -z "$FATAL_ERROR" ]; then
        log_info "=== Starting macOS antivirus remediation. TargetMode=$TARGET_MODE DryRun=$DRY_RUN TimeoutMinutes=$UNINSTALL_TIMEOUT_MINUTES ==="

        collect_inventory
        copy_inventory_snapshot "before"
        log_info "Products before remediation: $(display_list "${BEFORE_PRODUCTS[@]}")"

        while read -r product; do
            [ -n "$product" ] && before_blocking+=("$product")
        done < <(get_blocking_products)

        for product in "${before_blocking[@]}"; do
            invoke_uninstall_action "$product"
        done

        collect_inventory
        copy_inventory_snapshot "after"
        log_info "Products after remediation: $(display_list "${AFTER_PRODUCTS[@]}")"

        determine_outcome
        log_info "Final outcome: $OUTCOME. NextAction=$NEXT_ACTION"
    fi

    if [ -n "$FATAL_ERROR" ] && [ -z "$OUTCOME" ]; then
        OUTCOME="Failed"
        NEXT_ACTION="Review the log and summary JSON."
    fi

    write_summary_json
    write_console_summary

    if [ "$OUTCOME" = "NeedsDattoPolicy" ] || [ "$OUTCOME" = "NeedsManualCleanup" ] || [ "$OUTCOME" = "Failed" ]; then
        printf 'Resolve-RmmAntivirusState-macos completed with outcome [%s]. Review %s and %s.\n' "$OUTCOME" "$SUMMARY_PATH" "$LOG_PATH" >&2
        return 1
    fi

    return 0
}

main "$@"
# endregion Main
