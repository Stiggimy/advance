#!/usr/bin/env bash
# ==============================================================================
# lib/core.sh — Fundamental utilities, UI engine, colors, duration parser
# Part of Advance Universal System Update Manager
# ==============================================================================

# Pure-bash trim: strips leading and trailing whitespace without subprocesses
trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

# --- Color Setup ---
setup_colors() {
    if [[ "$USE_COLOR" == true ]]; then
        C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
        C_BLUE='\033[0;34m'; C_PURP='\033[0;35m'; C_CYAN='\033[0;36m'
        C_BOLD='\033[1m'; C_RESET='\033[0m'
        C_DIM='\033[2m'
    else
        C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_PURP=''; C_CYAN=''; C_BOLD=''; C_RESET=''
        C_DIM=''
    fi
}
setup_colors

# --- UI Engine ---
ui_info()  { local i="${C_CYAN}[INFO]${C_RESET} "; [[ "$USE_EMOJI" == true ]] && i="ℹ️ "; echo -e "${i}$1"; }
ui_ok()    { local i="${C_GREEN}[OK]${C_RESET} "; [[ "$USE_EMOJI" == true ]] && i="✅ "; echo -e "${i}$1"; }
ui_warn()  { local i="${C_YELLOW}[WARN]${C_RESET} "; [[ "$USE_EMOJI" == true ]] && i="⚠️ "; echo -e "${i}$1"; }
ui_error() { local i="${C_RED}[ERROR]${C_RESET} "; [[ "$USE_EMOJI" == true ]] && i="❌ "; echo -e "${i}$1"; }
ui_debug() { [[ "$VERBOSE" == true ]] && echo -e "${C_PURP}[DEBUG]${C_RESET} $1"; }


e() {
    [[ "$USE_EMOJI" == true ]] && echo -n "$1 "
}

# --- Duration Parser ---
# Converts human-readable time strings (e.g. 10m, 2h, 1d, 30s) to seconds
parse_duration() {
    local input="$1"
    local num="${input//[!0-9]/}"
    [[ -z "$num" ]] && { echo "0"; return; }
    local suffix="${input//[0-9]/}"
    case "$suffix" in
        s) echo "$num" ;;
        m|"") echo "$((num * 60))" ;;
        h) echo "$((num * 3600))" ;;
        d) echo "$((num * 86400))" ;;
        *) echo "$((num * 60))" ;;
    esac
}

# --- Pre-flight Network Connectivity Check ---
check_connectivity() {
    # 1. Quick check: Is there a default network route configured?
    if command -v ip >/dev/null 2>&1; then
        if ! ip route show default 2>/dev/null | grep -q .; then
            return 1
        fi
    fi

    # 2. Native OS NetworkManager check (instant, detects captive portals)
    if command -v nmcli >/dev/null 2>&1; then
        local nm_state
        nm_state=$(nmcli -t -f CONNECTIVITY general 2>/dev/null)
        if [[ "$nm_state" == "full" ]]; then
            return 0
        fi
    fi

    # 3. DNS resolution check (uses system resolver, no hardcoded IPs or ICMP)
    if command -v getent >/dev/null 2>&1; then
        if getent ahostsv4 archlinux.org >/dev/null 2>&1 || \
           getent ahostsv4 kernel.org >/dev/null 2>&1 || \
           getent ahostsv4 debian.org >/dev/null 2>&1; then
            return 0
        fi
    fi

    # 4. HTTP captive-portal / connectivity fallback (curl / wget)
    if command -v curl >/dev/null 2>&1; then
        if curl -fsI --connect-timeout 2 --max-time 3 http://ping.archlinux.org/nm-check.txt &>/dev/null || \
           curl -fsI --connect-timeout 2 --max-time 3 http://connectivity-check.ubuntu.com/ &>/dev/null; then
            return 0
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q --spider --timeout=3 http://connectivity-check.ubuntu.com/ &>/dev/null; then
            return 0
        fi
    fi

    return 1
}
