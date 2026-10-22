#!/usr/bin/env bash
# ==============================================================================
# lib/config.sh — Configuration management, group priorities, dismissed tips
# Part of Advance Universal System Update Manager
# ==============================================================================

# CONFIG_FILE is resolved by lib/xdg.sh

# --- Internal Defaults ---
USE_COLOR=true; USE_EMOJI=true
ALWAYS_PRE_SNAP=true; ALWAYS_POST_SNAP=true; ALWAYS_CLEANUP=true
ALWAYS_KEEP_PRE=false; ALWAYS_KEEP_POST=false; DEFAULTS=""
VERBOSE=false; AUTO_RETRIES=1; INFINITE_RETRIES=false
SNAP_MIN_AGE=10m; EXCLUDE_PACKAGES=""
AUTO_CONFIRM=true; SKIP_CHECKPOINT_WARNING=false
declare -A GROUP_ENABLED
declare -A GROUP_PRIORITY

load_config() {
    [[ ! -f "$CONFIG_FILE" ]] && { mkdir -p "$(dirname "$CONFIG_FILE")"; save_config; return; }
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
        case "$key" in
            USE_COLOR) USE_COLOR="$value" ;;
            USE_EMOJI) USE_EMOJI="$value" ;;
            GROUP_PRIORITY_*) GROUP_PRIORITY[${key#GROUP_PRIORITY_}]="$value" ;;
            GROUP_*) GROUP_ENABLED[${key#GROUP_}]="$value" ;;
            ALWAYS_PRE_SNAP) ALWAYS_PRE_SNAP="$value" ;;
            ALWAYS_POST_SNAP) ALWAYS_POST_SNAP="$value" ;;
            ALWAYS_CLEANUP) ALWAYS_CLEANUP="$value" ;;
            ALWAYS_KEEP_PRE) ALWAYS_KEEP_PRE="$value" ;;
            ALWAYS_KEEP_POST) ALWAYS_KEEP_POST="$value" ;;
            DEFAULTS) DEFAULTS="$value" ;;
            AUTO_RETRIES) AUTO_RETRIES="$value" ;;
            INFINITE_RETRIES) INFINITE_RETRIES="$value" ;;
            SNAP_MIN_AGE) SNAP_MIN_AGE="$value" ;;
            EXCLUDE_PACKAGES) EXCLUDE_PACKAGES="$value" ;;
            AUTO_CONFIRM) AUTO_CONFIRM="$value" ;;
            SKIP_CHECKPOINT_WARNING) SKIP_CHECKPOINT_WARNING="$value" ;;
        esac
    done < "$CONFIG_FILE"
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    {
        echo "USE_COLOR=$USE_COLOR"
        echo "USE_EMOJI=$USE_EMOJI"
        echo "ALWAYS_PRE_SNAP=$ALWAYS_PRE_SNAP"
        echo "ALWAYS_POST_SNAP=$ALWAYS_POST_SNAP"
        echo "ALWAYS_CLEANUP=$ALWAYS_CLEANUP"
        echo "ALWAYS_KEEP_PRE=$ALWAYS_KEEP_PRE"
        echo "ALWAYS_KEEP_POST=$ALWAYS_KEEP_POST"
        echo "DEFAULTS=$DEFAULTS"
        echo "AUTO_RETRIES=$AUTO_RETRIES"
        echo "INFINITE_RETRIES=$INFINITE_RETRIES"
        echo "SNAP_MIN_AGE=$SNAP_MIN_AGE"
        echo "EXCLUDE_PACKAGES=$EXCLUDE_PACKAGES"
        echo "AUTO_CONFIRM=$AUTO_CONFIRM"
        echo "SKIP_CHECKPOINT_WARNING=$SKIP_CHECKPOINT_WARNING"
        # Write group toggles
        local grp
        for grp in "${!GROUP_ENABLED[@]}"; do
            echo "GROUP_${grp}=${GROUP_ENABLED[$grp]}"
        done
        # Write group execution priorities
        for grp in "${!GROUP_PRIORITY[@]}"; do
            echo "GROUP_PRIORITY_${grp}=${GROUP_PRIORITY[$grp]}"
        done
    } > "$CONFIG_FILE"
}

get_group_priority() {
    local grp="$1"
    if [[ -n "${GROUP_PRIORITY[$grp]:-}" ]]; then
        echo "${GROUP_PRIORITY[$grp]}"
    elif [[ "$grp" == "system" ]]; then
        echo "100"
    else
        echo "50"
    fi
}

set_group_priority() {
    local grp="$1"
    local pri="$2"
    GROUP_PRIORITY[$grp]="$pri"
    save_config
}

# --- Dismissable Tips / Notification System ---
show_message() {
    local id="$1" text="$2"
    local dismissed_file="$DISMISSED_FILE"
    [[ -f "$dismissed_file" ]] && grep -qxF "$id" "$dismissed_file" && return
    echo -e "\n${C_BLUE}${C_BOLD}💡 $text${C_RESET}"
    if [[ -t 0 ]]; then
        echo -e "   ${C_CYAN}(Press D to dismiss permanently, Enter to continue)${C_RESET}"
        local response=""
        read -r -n 1 -s response
        echo ""
        if [[ "$response" =~ [Dd] ]]; then
            mkdir -p "$(dirname "$dismissed_file")"
            echo "$id" >> "$dismissed_file"
            ui_ok "Tip dismissed permanently."
        fi
    fi
}
