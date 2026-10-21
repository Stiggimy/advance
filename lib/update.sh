#!/usr/bin/env bash
# ==============================================================================
# lib/update.sh — Main update workflow, survey phase, snapshots, execution loop
# Part of Advance Universal System Update Manager
# ==============================================================================

# Helper to lazy-load interactive menus on-demand
ensure_menu_loaded() {
    if [[ -z "$_ADVANCE_MENU_LOADED" ]]; then
        local lib_dir="${LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
        source "$lib_dir/menu.sh"
        _ADVANCE_MENU_LOADED=true
    fi
}

# --- SYSTEM AWARENESS (minimal) ---
if [[ -f /etc/os-release ]]; then
    _adv_orig_version="${VERSION:-}"
    . /etc/os-release
    DISTRO="${PRETTY_NAME:-${NAME:-$ID}}"
    [[ -n "$_adv_orig_version" ]] && VERSION="$_adv_orig_version"
    unset _adv_orig_version
else
    DISTRO="Linux"
fi

# --- MAIN UPDATE FUNCTION ---
do_update() {
    local pid_keepalive=""
    local -a held_pkgs=()
    local current_unhold_cmd=""

    cleanup_held_packages() {
        if [[ ${#held_pkgs[@]} -gt 0 && -n "$current_unhold_cmd" ]]; then
            ui_warn "Releasing package holds..."
            for pkg in "${held_pkgs[@]}"; do
                local cur_unhold="${current_unhold_cmd//\$PKG/$pkg}"
                eval "$cur_unhold" >/dev/null 2>&1 || true
            done
            held_pkgs=()
        fi
    }

    start_sudo_keepalive() { (while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done) >/dev/null 2>&1 & pid_keepalive=$!; }

    get_excluded_packages() {
        local merged=()
        if [[ -n "$EXCLUDE_PACKAGES" ]]; then
            IFS=', ' read -r -a config_arr <<< "$EXCLUDE_PACKAGES"
            merged+=("${config_arr[@]}")
        fi
        local excludes_file="$HOME/.config/advance/excludes"
        if [[ -f "$excludes_file" ]]; then
            while IFS= read -r line || [[ -n "$line" ]]; do
                line="${line%%#*}"
                line="${line#"${line%%[![:space:]]*}"}"
                line="${line%"${line##*[![:space:]]}"}"
                [[ -n "$line" ]] && merged+=("$line")
            done < "$excludes_file"
        fi
        merged+=("${cli_excludes[@]}")
        local uniq=()
        if [[ ${#merged[@]} -gt 0 ]]; then
            mapfile -t uniq <<< "$(printf "%s\n" "${merged[@]}" | sort -u)"
        fi
        echo "${uniq[@]}"
    }

    catalog_cli() {
        local action="${1:-list}"
        local target="$2"
        local cat_dir
        cat_dir=$(get_catalog_dir)

        if [[ -z "$cat_dir" || ! -d "$cat_dir" ]]; then
            ui_error "Catalog directory not found."
            return 1
        fi

        case "$action" in
            list)
                echo -e "${C_BOLD}Advance Official Catalog:${C_RESET}"
                echo -e "Catalog directory: ${C_CYAN}$cat_dir${C_RESET}\n"
                printf "%-18s %-12s %-8s %s\n" "MANAGER" "GROUP" "PRIORITY" "STATUS"
                echo "───────────────────────────────────────────────────────────────────────────"
                while IFS= read -r conf; do
                    [[ ! -f "$conf" ]] && continue
                    local fname="${conf##*/}"
                    local gname
                    gname=$(basename "$(dirname "$conf")")
                    [[ "$gname" == "managers" ]] && gname=""
                    local mname pri req
                    mname=$(grep '^NAME=' "$conf" 2>/dev/null | head -n 1 | cut -d'=' -f2-)
                    pri=$(grep '^PRIORITY=' "$conf" 2>/dev/null | head -n 1 | cut -d'=' -f2-)
                    req=$(grep '^REQUIRES_CMD=' "$conf" 2>/dev/null | head -n 1 | cut -d'=' -f2-)
                    [[ -z "$req" ]] && req=$(grep '^REQUIRES_BIN=' "$conf" 2>/dev/null | head -n 1 | cut -d'=' -f2-)

                    local status_str
                    local enrolled_file="$CUSTOM_DIR/$gname/$fname"
                    [[ -z "$gname" ]] && enrolled_file="$CUSTOM_DIR/$fname"

                    if [[ -e "$enrolled_file" ]]; then
                        if [[ -L "$enrolled_file" ]]; then
                            status_str="${C_GREEN}Active (Enrolled via catalog)${C_RESET}"
                        else
                            status_str="${C_GREEN}Active (Custom / User modified)${C_RESET}"
                        fi
                    elif probe_manager "$conf"; then
                        status_str="${C_CYAN}Available on system (Not enrolled)${C_RESET}"
                    else
                        status_str="${C_DIM}Not installed on system${C_RESET}"
                    fi

                    printf "%-18s %-12s %-8s %b\n" "${mname:-$fname}" "${gname:-standalone}" "${pri:-0}" "$status_str"
                done < <(find "$cat_dir" -type f -name "*.conf" | sort)
                echo ""
                echo "Tip: Run 'advance catalog scan' to auto-enroll all available managers."
                ;;
            scan)
                ui_info "Probing system for catalog tools..."
                local before_count
                before_count=$(find "$CUSTOM_DIR" -type l 2>/dev/null | wc -l)
                auto_enroll_catalog false
                local after_count
                after_count=$(find "$CUSTOM_DIR" -type l 2>/dev/null | wc -l)
                local diff=$((after_count - before_count))
                if [[ $diff -gt 0 ]]; then
                    ui_ok "Successfully enrolled $diff new manager(s)."
                else
                    ui_info "No new available catalog tools detected."
                fi
                ;;
            enroll|add)
                if [[ -z "$target" ]]; then
                    ui_error "Usage: advance catalog enroll <manager_name_or_file>"
                    return 1
                fi
                local match
                match=$(find "$cat_dir" -iname "${target}*.conf" 2>/dev/null | head -n 1)
                if [[ -z "$match" ]]; then
                    ui_error "Manager '$target' not found in catalog."
                    return 1
                fi
                local fname="${match##*/}"
                local gname
                gname=$(basename "$(dirname "$match")")
                [[ "$gname" == "managers" ]] && gname=""
                local dest="$CUSTOM_DIR/$gname/$fname"
                [[ -z "$gname" ]] && dest="$CUSTOM_DIR/$fname"
                mkdir -p "$(dirname "$dest")"
                ln -sf "$match" "$dest"
                ui_ok "Enrolled: $fname -> $dest"
                ;;
            remove|disable)
                if [[ -z "$target" ]]; then
                    ui_error "Usage: advance catalog remove <manager_name_or_file>"
                    return 1
                fi
                local match
                match=$(find "$CUSTOM_DIR" -iname "${target}*.conf" 2>/dev/null | head -n 1)
                if [[ -z "$match" ]]; then
                    ui_error "Manager '$target' not found in active managers ($CUSTOM_DIR)."
                    return 1
                fi
                rm -f "$match"
                ui_ok "Removed from active managers: $match"
                ;;
            *)
                echo "Usage: advance catalog [list | scan | enroll <mgr> | remove <mgr>]"
                ;;
        esac
    }

    load_config; setup_colors; load_custom_managers
    if [[ "$1" == "catalog" ]]; then catalog_cli "$2" "$3"; return $?; fi
    if [[ "$1" == "config" ]]; then
        ensure_menu_loaded
        if [[ "$2" == "export" ]]; then config_export "$3"; return 0;
        elif [[ "$2" == "import" ]]; then config_import "$3"; return 0;
        else manage_config; return 0; fi
    fi
    if [[ "$1" == "self-update" ]]; then ensure_menu_loaded; self_update; return $?; fi
    if [[ "$1" == "schedule" ]]; then ensure_menu_loaded; manage_schedule; return 0; fi
    set -- $DEFAULTS "$@"

    local do_pre=${ALWAYS_PRE_SNAP:-true}; local do_post=${ALWAYS_POST_SNAP:-true}; local do_clean=${ALWAYS_CLEANUP:-true}
    local keep_pre=${ALWAYS_KEEP_PRE:-false}; local keep_post=${ALWAYS_KEEP_POST:-false}
    local force_pre=false; local force_post=false; local force_del=false; local limit=""
    local only=false; local is_interactive=false
    local only_pre=false; local only_post=false
    local check_only=false
    local cli_excludes=()
    local only_managers=()
    local skip_managers=()
    local only_groups=()
    local skip_groups=()
    declare -A cli_extra_flags=()
    declare -A cli_clear_extra_flags=()

    # Scan for only-mode triggers
    for arg in "$@"; do
        case "$arg" in -o|-og|-oprs|-ops|--only|--only-group|--only-pre-snapshot|--only-post-snapshot) only=true; break ;; esac
    done

    while [[ $# -gt 0 ]]; do
        case "$1" in
            # Targeting flags
            -o|--only)
                if [[ -n "$2" && "$2" != -* ]]; then
                    only_managers+=("$2"); only=true; shift 2
                else ui_error "Flag --only requires a manager name."; exit 1; fi ;;
            -og|--only-group)
                if [[ -n "$2" && "$2" != -* ]]; then
                    only_groups+=("$2"); only=true; shift 2
                else ui_error "Flag --only-group requires a group name."; exit 1; fi ;;
            -n|--no)
                if [[ -n "$2" && "$2" != -* ]]; then
                    skip_managers+=("$2"); shift 2
                else ui_error "Flag --no requires a manager name."; exit 1; fi ;;
            -ng|--no-group)
                if [[ -n "$2" && "$2" != -* ]]; then
                    skip_groups+=("$2"); shift 2
                else ui_error "Flag --no-group requires a group name."; exit 1; fi ;;
            # Phase controls
            -ch|--check) check_only=true; shift ;;
            -oprs|--only-pre-snapshot) only_pre=true; do_pre=true; shift ;;
            -ops|--only-post-snapshot) only_post=true; do_post=true; shift ;;
            -nprs|--no-pre-snapshot) do_pre=false; shift ;;
            -ns|--no-snapshot) do_post=false; shift ;;
            -nc|--no-cleanup) do_clean=false; shift ;;
            # Modifiers
            -fprs|--force-pre-snapshot) force_pre=true; shift ;;
            -fs|--force-snapshot) force_post=true; shift ;;
            -kprs|--keep-pre-snapshot) keep_pre=true; shift ;;
            -ks|--keep-snapshot) keep_post=true; shift ;;
            -fd|--force-delete) force_del=true; shift ;;
            -k|--keep) if [[ "$2" =~ ^[0-9]+$ ]]; then limit="$2"; shift 2; else ui_error "Flag -k requires a number."; exit 1; fi ;;
            -ex|--exclude)
                if [[ -n "$2" && "$2" != -* ]]; then
                    cli_excludes+=("$2"); shift 2
                else ui_error "Flag --exclude requires a package name."; exit 1; fi ;;
            -ef|--extra-flag)
                if [[ -n "$2" && "$2" != -* ]]; then
                    if [[ "$2" != *:* ]]; then
                        ui_error "Flag $1 requires format <manager:flag> (e.g. yay:--devel)."
                        exit 1
                    fi
                    local ef_mgr="${2%%:*}"
                    local ef_flag="${2#*:}"
                    local ef_key="${ef_mgr,,}"
                    if [[ -n "${cli_extra_flags[$ef_key]}" ]]; then
                        cli_extra_flags[$ef_key]="${cli_extra_flags[$ef_key]} $ef_flag"
                    else
                        cli_extra_flags[$ef_key]="$ef_flag"
                    fi
                    shift 2
                else
                    ui_error "Flag $1 requires an argument <manager:flag>."
                    exit 1
                fi ;;
            -nef|--no-extra-flags)
                if [[ -n "$2" && "$2" != -* ]]; then
                    local nef_key="${2,,}"
                    cli_clear_extra_flags[$nef_key]=true
                    cli_extra_flags[$nef_key]=""
                    shift 2
                else
                    ui_error "Flag $1 requires a manager name."
                    exit 1
                fi ;;
            -i|--interactive) is_interactive=true; shift ;;
            -v|--verbose|--debug) VERBOSE=true; shift ;;
            -V|--version) echo "Advance v$VERSION${BUILD:+ (build $BUILD)}"; exit 0 ;;
            -h|--help)
                echo -e "${C_YELLOW}${C_BOLD}Advance v$VERSION${BUILD:+ (build $BUILD)}${C_RESET}"
                echo -e "Usage: ${C_GREEN}advance [OPTIONS] [SUBCOMMAND]${C_RESET}"
                echo ""
                echo -e "${C_BOLD}Modes:${C_RESET}"
                echo -e " $(e 🔍)${C_CYAN}-ch,   --check${C_RESET}                  Check for updates only. Add -v to list packages. No sudo required."
                echo ""
                echo -e "${C_BOLD}Target Selection:${C_RESET}"
                echo -e " $(e 🎯)${C_CYAN}-o,    --only \e[3m<manager>\e[0m${C_RESET}          Only run this manager (repeatable)."
                echo -e " $(e 🎯)${C_CYAN}-og,   --only-group \e[3m<group>\e[0m${C_RESET}      Only run this group (repeatable)."
                echo -e " $(e 🚫)${C_RED}-n,    --no \e[3m<manager>\e[0m${C_RESET}            Skip this manager (repeatable)."
                echo -e " $(e 🚫)${C_RED}-ng,   --no-group \e[3m<group>\e[0m${C_RESET}        Skip this group (repeatable)."
                echo ""
                echo -e "${C_BOLD}Phase Control:${C_RESET}"
                echo -e " $(e 📸)${C_CYAN}-oprs, --only-pre-snapshot${C_RESET}         Create pre-snapshot only."
                echo -e " $(e 📸)${C_CYAN}-ops,  --only-post-snapshot${C_RESET}        Create post-snapshot only."
                echo -e " $(e 🚫)${C_RED}-nprs, --no-pre-snapshot${C_RESET}           Skip pre-snapshot."
                echo -e " $(e 🚫)${C_RED}-ns,   --no-snapshot${C_RESET}               Skip post-snapshot."
                echo -e " $(e 🚫)${C_RED}-nc,   --no-cleanup${C_RESET}                Skip snapshot cleanup."
                echo ""
                echo -e "${C_BOLD}Snapshot Modifiers:${C_RESET}"
                echo -e " $(e ⚡)${C_PURP}-fprs, --force-pre-snapshot${C_RESET}        Force pre-snapshot (ignore age)."
                echo -e " $(e ⚡)${C_PURP}-fs,   --force-snapshot${C_RESET}            Force post-snapshot."
                echo -e " $(e 🔒)${C_PURP}-kprs, --keep-pre-snapshot${C_RESET}         Mark pre-snap as [KEEP]."
                echo -e " $(e 🔒)${C_PURP}-ks,   --keep-snapshot${C_RESET}             Mark post-snap as [KEEP]."
                echo -e " $(e 🔥)${C_PURP}-fd,   --force-delete${C_RESET}              Delete [KEEP] snaps during cleanup."
                echo -e " $(e 🔟)${C_PURP}-k,    --keep \e[3m<N>\e[0m${C_RESET}                  Override snapshot limit."
                echo ""
                echo -e "${C_BOLD}Update Modifiers:${C_RESET}"
                echo -e " $(e 🚩)${C_PURP}-ef,   --extra-flag \e[3m<mgr:flag>\e[0m${C_RESET}     Append extra flag to manager for this run (repeatable)."
                echo -e " $(e 🚫)${C_RED}-nef,  --no-extra-flags \e[3m<mgr>\e[0m${C_RESET}      Clear extra flags for manager for this run (repeatable)."
                echo -e " $(e 🚫)${C_PURP}-ex,   --exclude \e[3m<pkg>\e[0m${C_RESET}             Exclude package from system updates (repeatable)."
                echo -e " $(e 🙋)${C_PURP}-i,    --interactive${C_RESET}               Force manual confirmation mode for all managers."
                echo ""
                echo -e "${C_BOLD}General:${C_RESET}"
                echo -e " $(e ℹ️)${C_PURP}-V,    --version${C_RESET}                   Print version and exit."
                echo -e " $(e 🔍)${C_PURP}-v,    --verbose, --debug${C_RESET}          Enable debug logs."
                echo -e " $(e ❓)${C_PURP}-h,    --help${C_RESET}                      Display this help and exit."
                echo ""
                echo -e "${C_BOLD}Subcommands:${C_RESET}"
                echo -e " $(e ⚙️)${C_GREEN}config${C_RESET}                              Interactive settings menu."
                echo -e "        ${C_GREEN}config export [mgr|--all]${C_RESET}       Export package manager configuration."
                echo -e "        ${C_GREEN}config import \e[3m<file|url>\e[0m${C_RESET}        Import package manager configuration."
                echo -e " $(e 📚)${C_GREEN}catalog${C_RESET}                             Official manager recipes catalog."
                echo -e "        ${C_GREEN}catalog list${C_RESET}                    List catalog managers and enrollment status."
                echo -e "        ${C_GREEN}catalog scan${C_RESET}                    Scan system and auto-enroll available tools."
                echo -e "        ${C_GREEN}catalog enroll \e[3m<mgr>\e[0m${C_RESET}            Enroll a manager from the catalog."
                echo -e "        ${C_GREEN}catalog remove \e[3m<mgr>\e[0m${C_RESET}            Remove an enrolled manager."
                echo -e " $(e 📅)${C_GREEN}schedule${C_RESET}                            Configure background auto-updates."
                echo -e " $(e 🔄)${C_GREEN}self-update${C_RESET}                         Update the tool suite."
                echo ""
                echo -e "${C_BOLD}Groups:${C_RESET}"
                echo -e "  Managers are organized in directories under ~/.config/advance/managers.d/."
                echo -e "  Each subdirectory is a group. Groups execute in order of group priority"
                echo -e "  (default: system 100, others 50; configurable in 'advance config')."
                echo -e "  Within each group, only the highest-priority available manager runs."
                echo -e "  Loose .conf files are standalone (always run if enabled)."
                return 0 ;;
            *) ui_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    # --- Build run_custom[] based on enabled state, then apply targeting ---
    local run_custom=()
    local standby_custom=()
    local mgr_status=()
    local is_explicit_only=()
    local i
    for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
        if [[ "${CUSTOM_ENABLEDS[$i]}" == "true" ]]; then
            run_custom[$i]=true
        else
            run_custom[$i]=false
            mgr_status[$i]="disabled"
        fi
        standby_custom[$i]=false
        is_explicit_only[$i]=false
        [[ -z "${mgr_status[$i]}" ]] && mgr_status[$i]=""
    done

    # Apply only-mode: start from nothing, enable what's specified
    if [[ "$only" == true ]]; then
        for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
            run_custom[$i]=false
        done
        do_pre=false; do_post=false
        if [[ "$only_pre" == true ]]; then do_pre=true; fi
        if [[ "$only_post" == true ]]; then do_post=true; fi

        # Enable by group
        for grp in "${only_groups[@]}"; do
            for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
                if [[ "${CUSTOM_GROUPS[$i],,}" == "${grp,,}" && "${CUSTOM_ENABLEDS[$i]}" == "true" ]]; then
                    run_custom[$i]=true
                fi
            done
        done

        # Enable by manager name (marks is_explicit_only to bypass group exclusion)
        for target in "${only_managers[@]}"; do
            for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
                if [[ "${CUSTOM_NAMES[$i],,}" == "${target,,}" && "${CUSTOM_ENABLEDS[$i]}" == "true" ]]; then
                    run_custom[$i]=true
                    is_explicit_only[$i]=true
                fi
            done
        done
    fi

    # Apply skip-groups
    for grp in "${skip_groups[@]}"; do
        for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
            if [[ "${CUSTOM_GROUPS[$i],,}" == "${grp,,}" ]]; then
                run_custom[$i]=false
                mgr_status[$i]="skipped"
            fi
        done
    done

    # Apply skip-managers
    for skip in "${skip_managers[@]}"; do
        for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
            if [[ "${CUSTOM_NAMES[$i],,}" == "${skip,,}" ]]; then
                run_custom[$i]=false
                mgr_status[$i]="skipped"
            fi
        done
    done

    # --- Group resolution ---
    resolve_groups

    # --- Pre-flight checks ---
    local needs_network=false
    for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
        if [[ "${run_custom[$i]}" == true ]]; then
            if [[ -n "${CUSTOM_UPDATES[$i]}" || -n "${CUSTOM_CHECKS[$i]}" ]]; then
                needs_network=true
                break
            fi
        fi
    done

    if [[ "$needs_network" == true ]]; then
        if ! check_connectivity; then
            if [[ "$check_only" == true ]]; then
                ui_error "Offline — cannot check for remote updates."
                exit 1
            else
                ui_error "No internet connection detected.\n         Cannot check for or download updates.\n         Verify your network and try again."
                exit 1
            fi
        fi
    fi

    ui_info "System: $DISTRO"
    [[ "$VERBOSE" == true ]] && ui_debug "Verbose mode enabled. Version: $VERSION"

    if [[ "$check_only" == false && ("$do_pre" == true || "$do_post" == true) ]]; then
        if ! command -v checkpoint >/dev/null 2>&1; then
            if [[ "$SKIP_CHECKPOINT_WARNING" == true ]]; then
                do_pre=false; do_post=false
                ui_info "Snapshots disabled (Checkpoint not installed). Run 'advance config' to change."
            else
                request_attention "Checkpoint not installed."
                ui_warn "Checkpoint is not installed — snapshots are disabled."
                echo -e "   Snapshots let you roll back if an update breaks your system.\n"
                echo -e "  [${C_GREEN}Y${C_RESET}] Yes, proceed without snapshots (this time only)"
                echo -e "  [${C_CYAN}D${C_RESET}] Don't ask again (always proceed without asking)"
                echo -e "  [${C_RED}N${C_RESET}] No, abort update\n"
                echo -n -e "${C_BOLD}Choice [y/d/N]: ${C_RESET}"
                read -r -n 1 cp_choice
                echo ""
                case "$cp_choice" in
                    [Yy])
                        close_attention
                        do_pre=false; do_post=false
                        ui_info "Proceeding without snapshots." ;;
                    [Dd])
                        close_attention
                        SKIP_CHECKPOINT_WARNING=true
                        save_config
                        do_pre=false; do_post=false
                        ui_ok "Saved preference: will not ask again. Run 'advance config' to change." ;;
                    *)
                        close_attention
                        ui_error "Update aborted. Install Checkpoint to enable snapshots or choose to proceed without."
                        exit 1 ;;
                esac
            fi
        fi
    fi

    # Auto-install helper dependencies for active managers if specified in plugin
    if [[ "$check_only" == false ]]; then
        declare -A _installed_dep_bins
        for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
            if [[ "${run_custom[$i]}" == true ]]; then
                local dep_bin="${CUSTOM_CHECK_DEP_BINS[$i]}"
                local dep_cmd="${CUSTOM_CHECK_DEP_INSTALLS[$i]}"
                if [[ -n "$dep_bin" && -n "$dep_cmd" && -z "${_installed_dep_bins[$dep_bin]}" ]]; then
                    if ! command -v "$dep_bin" >/dev/null 2>&1; then
                        ui_info "Installing helper dependency '$dep_bin' for ${CUSTOM_NAMES[$i]}..."
                        sudo -n true 2>/dev/null || request_attention "Sudo required."
                        eval "$dep_cmd"
                        close_attention
                    fi
                    _installed_dep_bins[$dep_bin]=1
                fi
            fi
        done
    fi

    local has_managers_to_run=false
    for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
        if [[ "${run_custom[$i]}" == true ]]; then
            has_managers_to_run=true
            break
        fi
    done

    # --- Survey phase ---
    local any=false
    local custom_has_updates=()
    local custom_check_output=()
    for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
        custom_has_updates[$i]=false
        custom_check_output[$i]=""
    done

    if [[ "$has_managers_to_run" == true ]]; then
        echo ">>> Surveying sources..."
        for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
            [[ "${run_custom[$i]}" != true ]] && continue
            local name="${CUSTOM_NAMES[$i]}"
            local check_cmd="${CUSTOM_CHECKS[$i]}"
            local check_exit_code="${CUSTOM_CHECK_UPDATES_EXIT_CODES[$i]}"
            local check_filter="${CUSTOM_CHECK_FILTER_PATTERNS[$i]}"
            local check_timeout_fb="${CUSTOM_CHECK_TIMEOUT_FALLBACKS[$i]}"

            echo -n " - $name... "
            if [[ -z "$check_cmd" ]]; then
                echo "Always runs."
                custom_has_updates[$i]=true
                any=true
            else
                local out exit_code
                out=$(timeout 15s bash -c "$check_cmd" 2>/dev/null)
                exit_code=$?

                # Quirks handling via .conf fields
                if [[ -n "$check_exit_code" && $exit_code -eq "$check_exit_code" ]]; then
                    [[ -z "$out" ]] && out="updates available"
                    exit_code=0
                fi

                if [[ -n "$check_filter" && -n "$out" ]]; then
                    out=$(echo "$out" | grep -vE "$check_filter")
                fi

                if [[ $exit_code -eq 124 ]]; then
                    if [[ -n "$check_timeout_fb" ]]; then
                        echo -n "Timeout. Fallback... "
                        local mgr_bin="${CUSTOM_REQUIRES_CMDS[$i]}"
                        local fb_cmd="${check_timeout_fb//\$REQUIRES_CMD/$mgr_bin}"
                        out=$(eval "$fb_cmd" 2>/dev/null)
                        exit_code=$?
                    else
                        echo "Timeout."
                    fi
                fi

                if [[ -n "$out" ]]; then
                    echo "Update available."
                    custom_has_updates[$i]=true
                    custom_check_output[$i]="$out"
                    any=true
                elif [[ $exit_code -ne 124 ]]; then
                    echo "Up to date."
                fi
            fi
        done
    fi

    # --check mode: formatted summary and exit
    if [[ "$check_only" == true ]]; then
        echo ""
        echo -e "${C_BOLD}>>> Update Check Summary:${C_RESET}"
        echo "──────────────────────────────────"
        local total_pkgs=0
        local managers_with_updates=0
        for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
            [[ "${run_custom[$i]}" != true ]] && continue
            local name="${CUSTOM_NAMES[$i]}"
            local emoji="${CUSTOM_EMOJIS[$i]}"
            [[ -z "$emoji" ]] && emoji="📦"
            local out="${custom_check_output[$i]}"
            if [[ "${custom_has_updates[$i]}" == true ]]; then
                ((managers_with_updates++))
                if [[ -z "${CUSTOM_CHECKS[$i]}" ]]; then
                    printf "  $(e $emoji)%-12s %b\n" "$name:" "${C_YELLOW}Always runs${C_RESET}"
                else
                    local pkg_count=0
                    if [[ -n "$out" ]]; then
                        pkg_count=$(grep -c '[^[:space:]]' <<< "$out" || true)
                        total_pkgs=$((total_pkgs + pkg_count))
                    fi
                    printf "  $(e $emoji)%-12s %b\n" "$name:" "${C_YELLOW}${pkg_count} update(s) available${C_RESET}"
                    if [[ "$VERBOSE" == true && -n "$out" ]]; then
                        echo "$out" | sed 's/^/        /'
                        echo ""
                    fi
                fi
            else
                printf "  $(e $emoji)%-12s %b\n" "$name:" "${C_GREEN}Up to date${C_RESET}"
            fi
        done
        echo "──────────────────────────────────"
        if [[ "$any" == true ]]; then
            local summary="${C_YELLOW}${C_BOLD}${managers_with_updates} source(s) with updates"
            [[ $total_pkgs -gt 0 ]] && summary+=", ${total_pkgs} package(s) total"
            summary+=".${C_RESET}"
            echo -e "  $summary"
            echo -e "  Run ${C_GREEN}advance${C_RESET} to apply."
            if [[ "$VERBOSE" != true && $total_pkgs -gt 0 ]]; then
                echo -e "  ${C_DIM}Use ${C_CYAN}advance --check --verbose${C_RESET}${C_DIM} to see package lists.${C_RESET}"
            fi
        else
            echo -e "  ${C_GREEN}${C_BOLD}Everything is up to date!${C_RESET}"
        fi
        return 0
    fi

    if [[ "$any" == false && "$force_pre" == false && "$force_post" == false && "$only_pre" == false && "$only_post" == false ]]; then ui_ok "System is up to date!"; return 0; fi

    # Sudo acquisition
    if ! sudo -n true 2>/dev/null; then
        if [[ -t 0 ]]; then
            request_attention "Sudo required."
            sudo -v || { close_attention; exit 1; }
            close_attention
        else
            if command -v notify-send >/dev/null 2>&1; then
                notify-send -u critical -a "advance" -i dialog-warning "Advance Update Required" "Background update requires sudo authentication. Please run 'advance' manually in a terminal to apply updates."
            fi
            echo "ERROR: Background update requires sudo authentication. Run 'advance' manually." >&2
            exit 1
        fi
    else
        sudo -v || exit 1
    fi
    start_sudo_keepalive
    local dt=$(date +'%d/%m/%Y %H:%M:%S')
    trap 'cleanup_held_packages; [[ -n "$pid_keepalive" ]] && kill "$pid_keepalive" 2>/dev/null' EXIT TERM INT

    # Age check for pre-snapshot (schema-driven via checkpoint porcelain query)
    if [[ "$do_pre" == true && "$force_pre" == false && "$only_pre" == false ]]; then
        local min_age_secs
        min_age_secs=$(parse_duration "$SNAP_MIN_AGE")
        local newest_snap_id=""
        if command -v checkpoint >/dev/null 2>&1; then
            local all_snaps
            all_snaps=$(checkpoint -l --porcelain 2>/dev/null || true)
            newest_snap_id=$(echo "$all_snaps" | head -n 1 | cut -d'|' -f1 | tr -d ' ')
        fi
        local snap_epoch=""
        if [[ "$newest_snap_id" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
            local newest_snap_ts
            newest_snap_ts=$(echo "$newest_snap_id" | sed 's/_/ /; s/-/:/3; s/-/:/3')
            snap_epoch=$(date -d "$newest_snap_ts" +%s 2>/dev/null)
        elif [[ "$newest_snap_id" =~ ^[0-9]+$ ]]; then
            if [[ -d "/.snapshots/$newest_snap_id" ]]; then
                snap_epoch=$(stat -c %Y "/.snapshots/$newest_snap_id" 2>/dev/null)
            fi
        fi

        if [[ -n "$snap_epoch" ]]; then
            local now_epoch age_secs
            now_epoch=$(date +%s)
            age_secs=$((now_epoch - snap_epoch))
            if [[ $age_secs -lt $min_age_secs ]]; then
                local human_age=$((age_secs / 60))
                ui_info "Recent snapshot found (${human_age}m ago). Skipping pre-snapshot."
                do_pre=false
            fi
        fi
        # Prevent mount/device lock contention between list query and subsequent snapshot creation
        [[ "$do_pre" == true && -n "$newest_snap_id" ]] && sleep 1
    fi

    local PRE_SNAPSHOT_ID=""
    # Execute Pre-Snapshot
    if [[ "$do_pre" == true && ("$any" == true || "$force_pre" == true || "$only_pre" == true) ]]; then
        ui_info "[Phase: Pre-Update Snapshot]"
        local snap_cmd="checkpoint create --type pre --porcelain -m \"Before $dt update\""
        [[ "$keep_pre" == true ]] && snap_cmd+=" -ks"
        if [[ "$do_post" == true && "$do_clean" == true ]]; then
            snap_cmd+=" -nc"
        elif [[ "$do_clean" == false ]]; then
            snap_cmd+=" -nc"
        else
            [[ -n "$limit" ]] && snap_cmd+=" -k $limit"
            [[ "$force_del" == true ]] && snap_cmd+=" -f"
        fi
        [[ "$VERBOSE" == true ]] && snap_cmd+=" -v"
        if run_with_retry "Pre-Snapshot" "checkpoint" "$snap_cmd"; then
            local c_status="" c_driver="" c_format="" c_id=""
            while IFS='=' read -r pk pv || [[ -n "$pk" ]]; do
                [[ -z "$pk" ]] && continue
                pv="${pv%\"}"; pv="${pv#\"}"
                case "$pk" in
                    CHECKPOINT_STATUS) c_status="$pv" ;;
                    CHECKPOINT_DRIVER) c_driver="$pv" ;;
                    CHECKPOINT_FORMAT) c_format="$pv" ;;
                    CHECKPOINT_ID) c_id="$pv" ;;
                esac
            done <<< "$LAST_CMD_OUTPUT"
            PRE_SNAPSHOT_ID="$c_id"
            ui_ok "Pre-snapshot created: ${c_id:-done} (${c_driver:-checkpoint})"
        fi
    fi

    build_manager_update_cmd() {
        local idx="$1"
        local name="${CUSTOM_NAMES[$idx]}"
        local update_cmd="${CUSTOM_UPDATES[$idx]}"
        local flags_auto_confirm="${CUSTOM_FLAGS_AUTO_CONFIRMS[$idx]}"
        local flags_interactive="${CUSTOM_FLAGS_INTERACTIVES[$idx]}"
        local color_flag="${CUSTOM_COLOR_FLAGS[$idx]}"
        local group="${CUSTOM_GROUPS[$idx]}"
        local mgr_key="${name,,}"

        local cmd="$update_cmd"

        # 1. Color Flag Injection (based on USE_COLOR)
        if [[ "$USE_COLOR" == true && -n "$color_flag" ]]; then
            cmd="$cmd $color_flag"
        fi

        # 2. Resolve FLAGS (persistent + CLI -ef / -nef overrides)
        local extra="${CUSTOM_FLAGS[$idx]}"
        if [[ "${cli_clear_extra_flags[$mgr_key]}" == true ]]; then
            extra=""
        fi
        if [[ -n "${cli_extra_flags[$mgr_key]}" ]]; then
            if [[ -n "$extra" ]]; then
                extra="$extra ${cli_extra_flags[$mgr_key]}"
            else
                extra="${cli_extra_flags[$mgr_key]}"
            fi
        fi
        extra=$(trim "$extra")
        [[ -n "$extra" ]] && cmd="$cmd $extra"

        # 3. Resolve AUTO_CONFIRM / Interactive mode
        if [[ "$is_interactive" == true ]]; then
            # CLI -i forces interactive mode for all managers with confirm flags
            if [[ -n "$flags_interactive" ]]; then
                cmd="$cmd $flags_interactive"
            fi
            # Do not append flags_auto_confirm
        else
            local mgr_ac="${CUSTOM_AUTO_CONFIRMS[$idx]}"
            local effective_ac=true
            if [[ "$mgr_ac" == "true" ]]; then
                effective_ac=true
            elif [[ "$mgr_ac" == "false" ]]; then
                effective_ac=false
            else
                if [[ "$AUTO_CONFIRM" == false ]]; then
                    effective_ac=false
                else
                    effective_ac=true
                fi
            fi

            if [[ "$effective_ac" == true ]]; then
                if [[ "$flags_auto_confirm" == "none" ]]; then
                    : # Inherently non-interactive manager; no flag needed and no warning
                elif [[ -n "$flags_auto_confirm" ]]; then
                    if [[ "$flags_auto_confirm" == *"|"* ]]; then
                        cmd="$flags_auto_confirm $cmd"
                    else
                        cmd="$cmd $flags_auto_confirm"
                    fi
                else
                    ui_warn "$name has no auto-confirm flag configured — manual prompts may appear." >&2
                    ui_warn "Configure one via 'advance config' -> Package Managers -> $name -> Set Flags & Extras." >&2
                fi
            else
                if [[ -n "$flags_interactive" ]]; then
                    cmd="$cmd $flags_interactive"
                fi
            fi
        fi

        # 4. Apply package exclusions based on EXCLUDE_FLAG
        local excludes
        excludes=$(get_excluded_packages)
        if [[ -n "$excludes" ]]; then
            local excl_flag="${CUSTOM_EXCLUDE_FLAGS[$idx]}"
            local excl_join="${CUSTOM_EXCLUDE_JOINS[$idx]:-,}"
            if [[ -n "$excl_flag" ]]; then
                if [[ "$excl_join" == "repeat" ]]; then
                    for pkg in $excludes; do
                        cmd="$cmd $excl_flag $pkg"
                    done
                else
                    local flat_excludes
                    if [[ "$excl_join" == " " || "$excl_join" == "space" ]]; then
                        flat_excludes="$excludes"
                    else
                        flat_excludes=$(echo "$excludes" | tr ' ' "$excl_join")
                    fi
                    if [[ "$excl_flag" == *= ]]; then
                        cmd="$cmd ${excl_flag}${flat_excludes}"
                    else
                        cmd="$cmd $excl_flag $flat_excludes"
                    fi
                fi
            fi
        fi

        echo "$cmd"
    }

    # --- Execute Updates (unified loop) ---
    local mgr_idx
    for ((mgr_idx=0; mgr_idx<${#CUSTOM_NAMES[@]}; mgr_idx++)); do
        [[ "${run_custom[$mgr_idx]}" != true ]] && continue
        [[ "${custom_has_updates[$mgr_idx]}" != true ]] && continue

        local name="${CUSTOM_NAMES[$mgr_idx]}"
        local emoji="${CUSTOM_EMOJIS[$mgr_idx]}"
        [[ -z "$emoji" ]] && emoji="📦"
        local flags_auto_confirm="${CUSTOM_FLAGS_AUTO_CONFIRMS[$mgr_idx]}"
        local flags_interactive="${CUSTOM_FLAGS_INTERACTIVES[$mgr_idx]}"
        local flags_override="${CUSTOM_FLAGS_OVERRIDES[$mgr_idx]}"
        local group="${CUSTOM_GROUPS[$mgr_idx]}"

        # Apply package exclusions for lock-based managers (e.g. apt, zypper)
        local excludes
        excludes=$(get_excluded_packages)
        held_pkgs=()
        local hold_cmd="${CUSTOM_EXCLUDE_HOLD_CMDS[$mgr_idx]}"
        local unhold_cmd="${CUSTOM_EXCLUDE_UNHOLD_CMDS[$mgr_idx]}"
        current_unhold_cmd="$unhold_cmd"
        if [[ -n "$excludes" && -n "$hold_cmd" ]]; then
            ui_info "Holding packages for $name: $excludes"
            for pkg in $excludes; do
                local cur_hold_cmd="${hold_cmd//\$PKG/$pkg}"
                eval "$cur_hold_cmd" >/dev/null 2>&1 && held_pkgs+=("$pkg")
            done
        fi

        local cmd
        cmd=$(build_manager_update_cmd "$mgr_idx")

        # Determine fallback label for grouped managers
        local fallback_label=""
        if [[ -n "$group" ]]; then
            local fb_chain
            fb_chain=($(get_fallback_chain "$mgr_idx"))
            if [[ ${#fb_chain[@]} -gt 0 ]]; then
                local fb_idx="${fb_chain[0]}"
                fallback_label="${CUSTOM_NAMES[$fb_idx]} (priority ${CUSTOM_PRIORITIES[$fb_idx]})"
            fi
        fi

        ui_info "[Phase: $name Update]"

        # Run with fallback support
        local current_idx=$mgr_idx
        local fb_pos=0
        local fb_chain
        fb_chain=($(get_fallback_chain "$mgr_idx"))

        while true; do
            # Recalculate fallback label for current position
            fallback_label=""
            if [[ $fb_pos -lt ${#fb_chain[@]} ]]; then
                local fb_idx="${fb_chain[$fb_pos]}"
                fallback_label="${CUSTOM_NAMES[$fb_idx]} (priority ${CUSTOM_PRIORITIES[$fb_idx]})"
            fi

            run_with_retry "$name Update" "$name" "$cmd" "$flags_auto_confirm" "$flags_interactive" "$flags_override" "$fallback_label"
            local ret=$?

            if [[ $ret -eq 0 ]]; then
                break
            elif [[ $ret -eq 2 ]]; then
                # Fallback requested
                if [[ $fb_pos -lt ${#fb_chain[@]} ]]; then
                    current_idx="${fb_chain[$fb_pos]}"
                    ((fb_pos++))
                    name="${CUSTOM_NAMES[$current_idx]}"
                    flags_auto_confirm="${CUSTOM_FLAGS_AUTO_CONFIRMS[$current_idx]}"
                    flags_interactive="${CUSTOM_FLAGS_INTERACTIVES[$current_idx]}"
                    flags_override="${CUSTOM_FLAGS_OVERRIDES[$current_idx]}"

                    # Rebuild command for fallback manager
                    cmd=$(build_manager_update_cmd "$current_idx")

                    ui_info "[Fallback: $name Update]"
                    continue
                else
                    break
                fi
            else
                # Skip/failure
                break
            fi
        done

        # Clean up holds
        cleanup_held_packages
    done

    # Execute Post-Snapshot
    if [[ "$do_post" == true && ("$any" == true || "$force_post" == true || "$only_post" == true) ]]; then
        ui_info "[Phase: Post-Update Snapshot]"
        local snap_cmd="checkpoint create --type post -m \"After $dt update\""
        [[ -n "$limit" ]] && snap_cmd+=" -k $limit"
        [[ -n "$PRE_SNAPSHOT_ID" ]] && snap_cmd+=" --pre-id \"$PRE_SNAPSHOT_ID\""
        [[ "$do_clean" == false ]] && snap_cmd+=" -nc"
        [[ "$keep_post" == true ]] && snap_cmd+=" -ks"; [[ "$force_del" == true ]] && snap_cmd+=" -f"
        [[ "$VERBOSE" == true ]] && snap_cmd+=" -v"
        run_with_retry "Post-Snapshot" "checkpoint" "$snap_cmd"
    fi

    # Post-update messages configured per manager plugin
    for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
        local msg_id="${CUSTOM_POST_MSG_IDS[$i]}"
        local msg_text="${CUSTOM_POST_MSGS[$i]}"
        if [[ -n "$msg_id" && -n "$msg_text" && "${custom_has_updates[$i]}" == true ]]; then
            show_message "$msg_id" "$(echo -e "$msg_text")"
        fi
    done

    ui_ok "All tasks completed!"
}
