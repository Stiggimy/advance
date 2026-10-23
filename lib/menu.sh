#!/usr/bin/env bash
# ==============================================================================
# lib/menu.sh — Interactive FZF configuration hub, wizards, export/import
# Part of Advance Universal System Update Manager
# Lazy-loaded on-demand when "advance config" or "advance schedule" is called
# ==============================================================================

config_export() {
    local target="$1"
    load_custom_managers

    if [[ -z "$target" ]]; then
        if [[ ${#CUSTOM_NAMES[@]} -eq 0 ]]; then
            ui_info "No package managers configured to export."
            return 0
        fi
        echo -e "${C_BOLD}Package Managers available for export:${C_RESET}"
        local i
        for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
            local name="${CUSTOM_NAMES[$i]}"
            local emoji="${CUSTOM_EMOJIS[$i]}"
            local group="${CUSTOM_GROUPS[$i]}"
            [[ -z "$emoji" ]] && emoji="📦"
            local grp_label=""
            [[ -n "$group" ]] && grp_label=" (group: $group)"
            echo -e "  $(e $emoji)$name$grp_label"
        done
        echo ""
        show_message "config_export_hint" "Run 'advance config export [name]' to print a manager config.\n   Run 'advance config export --all' to bundle all managers."
        return 0
    fi

    if [[ "$target" == "--all" ]]; then
        if [[ ${#CUSTOM_NAMES[@]} -eq 0 ]]; then
            ui_error "No package managers configured."
            return 1
        fi
        local tar_file="advance-managers.tar.gz"
        tar -czf "$tar_file" -C "$CUSTOM_DIR" .
        ui_ok "All package managers exported to $tar_file"
        return 0
    fi

    local i found=-1
    for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
        if [[ "${CUSTOM_NAMES[$i],,}" == "${target,,}" ]]; then
            found=$i
            break
        fi
    done

    if [[ $found -eq -1 ]]; then
        ui_error "Package manager '$target' not found."
        return 1
    fi

    cat "${CUSTOM_FILES[$found]}"
    return 0
}

config_import() {
    local source="$1"
    if [[ -z "$source" ]]; then
        ui_error "Please specify a file path or URL to import."
        return 1
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' EXIT INT TERM

    _cleanup_import() {
        rm -rf "$tmp_dir"
        trap - EXIT INT TERM
    }

    if [[ "$source" =~ ^https?:// ]]; then
        if ! command -v curl >/dev/null 2>&1; then
            ui_error "curl is required to download configs from URLs."
            _cleanup_import
            return 1
        fi
        ui_info "Downloading configuration..."
        local downloaded="$tmp_dir/downloaded"
        if ! curl -fsSL -o "$downloaded" "$source"; then
            ui_error "Failed to download from URL: $source"
            _cleanup_import
            return 1
        fi
        source="$downloaded"
    fi

    if [[ ! -f "$source" ]]; then
        ui_error "Source file does not exist: $source"
        _cleanup_import
        return 1
    fi

    if file "$source" | grep -q "gzip compressed data"; then
        ui_info "Extracting package managers bundle..."
        tar -xzf "$source" -C "$tmp_dir"
        # Handle directory structure in tarball without piping into while to protect stdin
        local conf_files=()
        while IFS= read -r c; do
            [[ -f "$c" ]] && conf_files+=("$c")
        done < <(find "$tmp_dir" -name "*.conf" -type f)
        for conf in "${conf_files[@]}"; do
            process_imported_conf "$conf"
        done
    else
        process_imported_conf "$source"
    fi

    _cleanup_import
}

process_imported_conf() {
    local conf="$1"
    local name="" emoji="" check_cmd="" update_cmd="" flags="" auto_confirm="" flags_auto_confirm="" flags_interactive="" flags_override=""
    local color_flag="" exclude_flag="" exclude_join="," exclude_hold_cmd="" exclude_unhold_cmd=""
    local check_exit_code="" check_filter="" check_timeout_fb=""
    local enabled="true" requires_cmd="" priority="0"
    local post_update_msg_id="" post_update_msg=""
    local check_dep_bin="" check_dep_cmd="" probe_cmd=""
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
        key="${key%$'\r'}"; value="${value%$'\r'}"
        case "$key" in
            NAME) name="$value" ;;
            EMOJI) emoji="$value" ;;
            CHECK_CMD) check_cmd="$value" ;;
            UPDATE_CMD) update_cmd="$value" ;;
            FLAGS|EXTRA_FLAGS) flags="$value" ;;
            AUTO_CONFIRM) auto_confirm="$value" ;;
            FLAGS_AUTO_CONFIRM|NO_INTERACTIVE_FLAG) flags_auto_confirm="$value" ;;
            FLAGS_INTERACTIVE|INTERACTIVE_FLAG) flags_interactive="$value" ;;
            FLAGS_OVERRIDE|OVERRIDE_FLAG) flags_override="$value" ;;
            COLOR_FLAG) color_flag="$value" ;;
            EXCLUDE_FLAG) exclude_flag="$value" ;;
            EXCLUDE_JOIN) exclude_join="$value" ;;
            EXCLUDE_HOLD_CMD) exclude_hold_cmd="$value" ;;
            EXCLUDE_UNHOLD_CMD) exclude_unhold_cmd="$value" ;;
            CHECK_UPDATES_EXIT_CODE) check_exit_code="$value" ;;
            CHECK_FILTER_PATTERN) check_filter="$value" ;;
            CHECK_TIMEOUT_FALLBACK) check_timeout_fb="$value" ;;
            POST_UPDATE_MSG_ID) post_update_msg_id="$value" ;;
            POST_UPDATE_MSG) post_update_msg="$value" ;;
            CHECK_DEP_BIN) check_dep_bin="$value" ;;
            CHECK_DEP_INSTALL_CMD) check_dep_cmd="$value" ;;
            ENABLED) enabled="$value" ;;
            REQUIRES_CMD) requires_cmd="$value" ;;
            PRIORITY) priority="$value" ;;
            PROBE_ACTIVE_CMD) probe_cmd="$value" ;;
        esac
    done < "$conf"

    if [[ -z "$name" ]]; then
        local bname="${conf##*/}"
        name="${bname%.conf}"
    fi

    if [[ -z "$update_cmd" ]]; then
        local bname="${conf##*/}"
        ui_error "Skipping $bname: UPDATE_CMD is missing."
        return 1
    fi

    load_custom_managers
    local i found=-1
    for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
        if [[ "${CUSTOM_NAMES[$i],,}" == "${name,,}" ]]; then
            found=$i
            break
        fi
    done

    # Ask which group to place into
    local target_group=""
    local groups
    mapfile -t groups < <(get_all_groups)
    if [[ ${#groups[@]} -gt 0 ]]; then
        local grp_opts=("${groups[@]}" "(standalone)" "(cancel)")
        echo -e "\nWhich group should '$name' be placed in?"
        local grp_choice
        grp_choice=$(printf "%s\n" "${grp_opts[@]}" | fzf --height 10 --reverse --header "Select group for '$name'")
        [[ -z "$grp_choice" || "$grp_choice" == "(cancel)" ]] && { ui_info "Cancelled."; return 0; }
        [[ "$grp_choice" != "(standalone)" ]] && target_group="$grp_choice"
    fi

    local target_dir="$CUSTOM_DIR"
    [[ -n "$target_group" ]] && target_dir="$CUSTOM_DIR/$target_group"
    local target_file="$target_dir/${name// /_}.conf"

    if [[ $found -ne -1 ]]; then
        local incoming_hash existing_hash
        incoming_hash=$(cat "$conf" | md5sum | cut -d' ' -f1)
        existing_hash=$(cat "${CUSTOM_FILES[$found]}" | md5sum | cut -d' ' -f1)
        if [[ "$incoming_hash" == "$existing_hash" ]]; then
            ui_info "Manager '$name' is already installed and matches this config. Skipping."
            return 0
        fi

        ui_warn "Conflict: Package manager '$name' already exists but has different settings."
        echo "What would you like to do?"
        echo "  1) Overwrite the existing config"
        echo "  2) Keep both (rename the imported manager)"
        echo "  3) Skip/Cancel import"
        echo -n "Choice [3]: "
        read -r choice
        case "$choice" in
            1) ui_info "Overwriting '$name' config."
               target_file="${CUSTOM_FILES[$found]}" ;;
            2)
               while true; do
                   echo -n "Enter new name for the imported manager (e.g. ${name}-custom): "
                   read -r new_name
                   new_name=$(echo "$new_name" | xargs)
                   [[ -z "$new_name" ]] && continue

                   local j dup=false
                   for ((j=0; j<${#CUSTOM_NAMES[@]}; j++)); do
                       if [[ "${CUSTOM_NAMES[$j],,}" == "${new_name,,}" ]]; then
                           dup=true
                           break
                       fi
                   done
                   if [[ "$dup" == true ]]; then
                       ui_error "Manager '$new_name' also exists. Try another name."
                   else
                       name="$new_name"
                       target_file="$target_dir/${name// /_}.conf"
                       ui_warn "Note: Renaming the manager creates a separate entry, which might cause duplicates if they manage the same packages."
                       break
                   fi
               done ;;
            *) ui_info "Skipping '$name' import."
               return 0 ;;
        esac
    fi

    local show_emoji="$emoji"; [[ -z "$show_emoji" ]] && show_emoji="📦"
    local show_ac="Follow global"
    [[ "$auto_confirm" == "true" ]] && show_ac="ON unless forced"
    [[ "$auto_confirm" == "false" ]] && show_ac="OFF unless forced"

    echo -e "\n📋 Importing package manager:"
    echo -e "   Name:           $name"
    echo -e "   Emoji:          $(e $show_emoji)"
    echo -e "   Requires:       ${requires_cmd:-(none)}"
    echo -e "   Priority:       $priority"
    echo -e "   Group:          ${target_group:-(standalone)}"
    echo -e "   Check:          ${check_cmd:-(none - always runs)}"
    echo -e "   Update:         $update_cmd"
    echo -e "   Flags:          ${flags:-(none)}"
    echo -e "   Auto-Confirm:   $show_ac"
    local show_confirm_flag="${flags_auto_confirm:-(none)}"
    [[ "$flags_auto_confirm" == "none" ]] && show_confirm_flag="none (non-interactive)"
    echo -e "   Confirm Flag:   $show_confirm_flag"
    echo -e "   Interactive:    ${flags_interactive:-(none)}"
    echo -e "   Override:       ${flags_override:-(none)}"
    echo -e "   Color Flag:     ${color_flag:-(none)}"
    echo -e "   Exclude Flag:   ${exclude_flag:-(none)}"
    echo ""

    read -p "Install this manager? [Y/n]: " p
    if [[ "$p" =~ ^[Nn]$ ]]; then
        ui_info "Cancelled."
        return 0
    fi

    save_custom_manager "$name" "$emoji" "$check_cmd" "$update_cmd" \
        "$flags_auto_confirm" "$flags_interactive" "$flags_override" \
        "$enabled" "$target_file" "$requires_cmd" "$priority" \
        "$flags" "$auto_confirm" "$color_flag" \
        "$exclude_flag" "$exclude_join" "$exclude_hold_cmd" "$exclude_unhold_cmd" \
        "$check_exit_code" "$check_filter" "$check_timeout_fb" \
        "$post_update_msg_id" "$post_update_msg" \
        "$check_dep_bin" "$check_dep_cmd" \
        "$probe_cmd"
    ui_ok "Package manager '$name' imported successfully!"
}

get_active_managers_summary() {
    load_custom_managers
    local groups
    mapfile -t groups < <(get_all_groups)
    local out=""
    local g i rank=0
    for g in "${groups[@]}"; do
        ((++rank))
        local grp_enabled="${GROUP_ENABLED[$g]:-true}"
        local grp_pri
        grp_pri=$(get_group_priority "$g")
        local g_indices=()
        mapfile -t g_indices < <(_get_group_manager_indices "$g")
        local best_name="" best_pri=""
        local standbys=()
        for i in "${g_indices[@]}"; do
            [[ -z "$i" ]] && continue
            [[ "${CUSTOM_ENABLEDS[$i]}" != "true" ]] && continue
            _is_mgr_available "$i" || continue
            local pri="${CUSTOM_PRIORITIES[$i]:-0}"
            if [[ -z "$best_name" ]]; then
                best_name="${CUSTOM_NAMES[$i]}"
                best_pri="$pri"
            else
                standbys+=("${CUSTOM_NAMES[$i]} [P:$pri]")
            fi
        done
        local grp_col
        grp_col=$(printf "#%-2d %-12s (P:%-3s)" "$rank" "[$g]" "$grp_pri")
        local sym_pause="||" sym_star="*" sym_none="x"
        [[ "$USE_EMOJI" == true ]] && sym_pause="⏸" sym_star="★" sym_none="✖"
        if [[ "$grp_enabled" != "true" ]]; then
            out+="  $grp_col → $sym_pause [Group Disabled]\n"
        elif [[ -n "$best_name" ]]; then
            local sb_str=""
            if [[ ${#standbys[@]} -gt 0 ]]; then
                local sb_joined
                printf -v sb_joined "%s, " "${standbys[@]}"
                sb_str="  (standby: ${sb_joined%, })"
            fi
            out+="  $grp_col → $sym_star $best_name [P:$best_pri]$sb_str\n"
        else
            out+="  $grp_col → $sym_none [No available manager]\n"
        fi
    done

    local solo_active=()
    for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
        [[ -n "${CUSTOM_GROUPS[$i]}" ]] && continue
        [[ "${CUSTOM_ENABLEDS[$i]}" != "true" ]] && continue
        _is_mgr_available "$i" || continue
        solo_active+=("${CUSTOM_NAMES[$i]}")
    done
    if [[ ${#solo_active[@]} -gt 0 ]]; then
        local solo_joined sym_star="*"
        [[ "$USE_EMOJI" == true ]] && sym_star="★"
        printf -v solo_joined "%s, " "${solo_active[@]}"
        out+="  •   [standalone]         → $sym_star ${solo_joined%, }\n"
    fi
    printf "%b" "$out"
}

browse_catalog_menu() {
    local cat_dir
    cat_dir=$(get_catalog_dir)
    if [[ -z "$cat_dir" || ! -d "$cat_dir" ]]; then
        ui_error "Catalog directory not found."
        return 1
    fi

    while true; do
        local menu_items=()
        while IFS= read -r conf; do
            [[ ! -f "$conf" ]] && continue
            local fname="${conf##*/}"
            local gdir="${conf%/*}"
            local gname="${gdir##*/}"
            [[ "$gname" == "managers" ]] && gname=""
            local mname="" req="" probe_cmd="" key val
            while IFS='=' read -r key val || [[ -n "$key" ]]; do
                [[ -z "$key" || "$key" == \#* ]] && continue
                key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
                val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
                key="${key%$'\r'}"; val="${val%$'\r'}"
                case "$key" in
                    NAME) mname="$val" ;;
                    REQUIRES_CMD) req="$val" ;;
                    REQUIRES_BIN) [[ -z "$req" ]] && req="$val" ;;
                    PROBE_ACTIVE_CMD) probe_cmd="$val" ;;
                esac
            done < "$conf"

            local status_tag="[Not installed]"
            local enrolled_file="$CUSTOM_DIR/$gname/$fname"
            [[ -z "$gname" ]] && enrolled_file="$CUSTOM_DIR/$fname"

            if [[ -e "$enrolled_file" ]]; then
                if [[ -L "$enrolled_file" ]]; then
                    status_tag="[Active - Enrolled]"
                else
                    status_tag="[Active - Custom]"
                fi
            elif [[ -z "$req" ]] || command -v "$req" >/dev/null 2>&1; then
                if [[ -z "$probe_cmd" ]] || eval "$probe_cmd" >/dev/null 2>&1; then
                    status_tag="[Available on system]"
                fi
            fi

            menu_items+=("$(e 📦)${mname:-$fname} ($gname) $status_tag"$'\t'"$conf")
        done < <(find "$cat_dir" -type f -name "*.conf" | sort)

        menu_items+=("---"$'\t'"sep")
        menu_items+=("$(e 🔙)Back"$'\t'"back")

        local sel
        sel=$(printf "%s\n" "${menu_items[@]}" | fzf --height 20 --reverse \
            --delimiter=$'\t' --with-nth=1 \
            --header "--- Official Manager Catalog ---" \
            --preview 'case "{2}" in
                back) echo "Return to previous menu." ;;
                sep) echo "Select a recipe above." ;;
                *)
                    if [ -f "{2}" ]; then
                        echo "Recipe Details:"
                        echo "──────────────────────────────"
                        cat "{2}"
                    fi
                    ;;
            esac' --preview-window=right:55%:wrap)

        [[ -z "$sel" || "$sel" == *$'\t'back ]] && return 0

        local chosen_conf="${sel#*$'\t'}"
        [[ -z "$chosen_conf" || "$chosen_conf" == "sep" || ! -f "$chosen_conf" ]] && continue

        local fname="${chosen_conf##*/}"
        local gname
        gname=$(basename "$(dirname "$chosen_conf")")
        [[ "$gname" == "managers" ]] && gname=""
        local dest="$CUSTOM_DIR/$gname/$fname"
        [[ -z "$gname" ]] && dest="$CUSTOM_DIR/$fname"

        if [[ -e "$dest" ]]; then
            local act
            act=$(printf "%s\n" "$(e ❌)Remove / Un-enroll from Advance" "$(e 🔙)Back" | fzf --height 8 --reverse --header "Manager '$fname' is currently active")
            if [[ "$act" == *Remove* ]]; then
                rm -f "$dest"
                ui_ok "Un-enrolled $fname."
            fi
        else
            local act
            act=$(printf "%s\n" "$(e ➕)Enroll into Advance (symlink to catalog)" "$(e 🔙)Back" | fzf --height 8 --reverse --header "Catalog Manager: $fname")
            if [[ "$act" == *Enroll* ]]; then
                mkdir -p "$(dirname "$dest")"
                ln -sf "$chosen_conf" "$dest"
                ui_ok "Enrolled $fname successfully!"
            fi
        fi
    done
}

# Helper: Infer required binary from an update command
# Strips leading wrappers (sudo, doas, pkexec, env, nice), environment variables, and flags
_infer_required_binary() {
    local cmd="$1"
    local -a words
    read -r -a words <<< "$cmd"
    local bin=""
    local i
    for ((i=0; i<${#words[@]}; i++)); do
        local w="${words[$i]}"
        # Skip yes | prefix if present (including args like yes y | or yes "y" |)
        if [[ "$w" == "yes" ]]; then
            local p_idx=-1
            local j
            for ((j=i+1; j<${#words[@]} && j<=i+4; j++)); do
                if [[ "${words[$j]}" == "|" ]]; then
                    p_idx=$j
                    break
                fi
            done
            if [[ $p_idx -ge 0 ]]; then
                i=$p_idx
                continue
            fi
        fi
        # Strip path and quotes to identify wrapper basename
        local base_w="${w##*/}"
        base_w="${base_w%.exe}"
        base_w="${base_w//[\"\'\`]/}"
        # Skip privilege escalation, environment, and process wrappers
        if [[ "$base_w" =~ ^(sudo|doas|pkexec|env|nice|ionice|nohup|eatmydata)$ ]]; then
            continue
        fi
        # Skip environment variable assignments (e.g. FOO=bar)
        if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; then
            continue
        fi
        # Skip standalone option terminator --
        if [[ "$w" == "--" ]]; then
            continue
        fi
        # Skip wrapper flags (both short and long, e.g. -E, -u root, --user=root, --preserve-env)
        if [[ "$w" =~ ^--?[a-zA-Z0-9_-]+(=.*)?$ ]]; then
            if [[ "$w" =~ ^(-[ugphaCnc]|--(user|group|prompt|directory|class|priority))$ && $((i+1)) -lt ${#words[@]} ]]; then
                ((i++))
            fi
            continue
        fi
        # Strip path, optional .exe suffix, and any residual quotes
        bin="${w##*/}"
        bin="${bin%.exe}"
        bin="${bin//[\"\'\`]/}"
        break
    done
    echo "$bin"
}

# Helper: Interactive preset selector for confirmation mode
# Sets SEL_AUTO_CONFIRM, SEL_INTERACTIVE, and SEL_AUTO_CONFIRM_MODE
_select_confirm_mode() {
    local cur_ac="$1"
    local cur_int="$2"

    local cur_label="none"
    if [[ "$cur_ac" == "none" ]]; then
        cur_label="none (already non-interactive)"
    elif [[ -n "$cur_ac" ]]; then
        cur_label="$cur_ac"
    elif [[ -n "$cur_int" ]]; then
        cur_label="interactive ($cur_int)"
    fi

    local preset_opts=(
        "-y                                    — Standard yes flag (apt, dnf, flatpak)"
        "--yes                                 — Long-form yes flag (conda, etc.)"
        "--noconfirm                           — Arch Linux flag (pacman, yay, paru)"
        "yes |                                 — Pipe 'yes' to stdin (tools without CLI flag)"
        "Already non-interactive (no flag)    — Tool never prompts (brew, snap, cargo)"
        "Custom auto-confirm flag...           — Enter a custom confirmation flag"
        "Always interactive / manual prompt    — Never auto-confirm, always prompt user"
        "Clear confirmation setting           — No flag configured (warns during run)"
    )

    local p_choice
    p_choice=$(printf "%s\n" "${preset_opts[@]}" | fzf --height 16 --reverse \
        --header "--- Confirmation Mode (Current: $cur_label) ---" \
        --preview 'case "{}" in
            *"-y "*)
                echo -e "Auto-Confirm Flag: -y\n─────────────────────\nUsed by apt, dnf, flatpak, and many other tools.\nAdvance appends '\''-y'\'' to automatically accept update prompts during unattended or automatic runs." ;;
            *"--yes "*)
                echo -e "Auto-Confirm Flag: --yes\n────────────────────────\nUsed by tools that accept long-form confirmation (e.g. conda, certain CLI utilities).\nAdvance appends '\''--yes'\'' during automatic runs." ;;
            *"--noconfirm"*)
                echo -e "Auto-Confirm Flag: --noconfirm\n──────────────────────────────\nStandard for Arch Linux package managers (pacman, yay, paru).\nAdvance appends '\''--noconfirm'\'' during automatic runs." ;;
            *"yes |"*)
                echo -e "Pipe Confirmation: yes |\n────────────────────────\nPipes '\''yes'\'' into standard input for tools that do not support a CLI confirmation flag.\nAdvance executes: yes | <update_cmd>." ;;
            *Already*non-interactive*)
                echo -e "Non-Interactive: none\n─────────────────────\nFor tools that run without prompting for confirmation (e.g. Homebrew, Snap, Cargo).\nAdvance will not append any confirmation flag and will not warn about missing flags." ;;
            *Custom*auto-confirm*)
                echo -e "Custom Confirmation Flag\n────────────────────────\nSpecify any other auto-confirm flag or prefix required by your package manager." ;;
            *Always*interactive*)
                echo -e "Interactive / Manual Confirmation\n─────────────────────────────────\nDisables auto-confirm for this manager so you are always prompted manually before packages are installed.\nOptionally sets an interactive flag (e.g. --interactive) for manual mode." ;;
            *Clear*)
                echo -e "Clear Confirmation Setting\n──────────────────────────\nRemoves any auto-confirm or interactive flag.\nAdvance will warn that no auto-confirm flag is configured during automatic runs." ;;
        esac' --preview-window=right:50%:wrap)

    [[ -z "$p_choice" ]] && return 1

    if [[ "$p_choice" == "-y"* ]]; then
        SEL_AUTO_CONFIRM="-y"
        SEL_INTERACTIVE=""
        SEL_AUTO_CONFIRM_MODE=""
    elif [[ "$p_choice" == "--yes"* ]]; then
        SEL_AUTO_CONFIRM="--yes"
        SEL_INTERACTIVE=""
        SEL_AUTO_CONFIRM_MODE=""
    elif [[ "$p_choice" == *"--noconfirm"* ]]; then
        SEL_AUTO_CONFIRM="--noconfirm"
        SEL_INTERACTIVE=""
        SEL_AUTO_CONFIRM_MODE=""
    elif [[ "$p_choice" == *"yes |"* ]]; then
        SEL_AUTO_CONFIRM="yes |"
        SEL_INTERACTIVE=""
        SEL_AUTO_CONFIRM_MODE=""
    elif [[ "$p_choice" == *"Already non-interactive"* ]]; then
        SEL_AUTO_CONFIRM="none"
        SEL_INTERACTIVE=""
        SEL_AUTO_CONFIRM_MODE=""
    elif [[ "$p_choice" == *"Custom auto-confirm"* ]]; then
        echo -n "Enter custom auto-confirm flag or prefix: "
        local cust
        read -r cust
        cust=$(trim "$cust")
        if [[ "$cust" == "none" || "$cust" == "clear" || "$cust" == "-" ]]; then
            SEL_AUTO_CONFIRM=""
            SEL_INTERACTIVE=""
            SEL_AUTO_CONFIRM_MODE=""
        elif [[ -n "$cust" ]]; then
            SEL_AUTO_CONFIRM="$cust"
            SEL_INTERACTIVE=""
            SEL_AUTO_CONFIRM_MODE=""
        elif [[ -n "$cur_ac" ]]; then
            SEL_AUTO_CONFIRM="$cur_ac"
            SEL_INTERACTIVE=""
            SEL_AUTO_CONFIRM_MODE=""
        else
            SEL_AUTO_CONFIRM=""
            SEL_INTERACTIVE=""
            SEL_AUTO_CONFIRM_MODE=""
        fi
    elif [[ "$p_choice" == *"Always interactive"* ]]; then
        echo -n "Enter manual interactive flag (leave empty if tool prompts by default, 'none' to clear) [current: ${cur_int:-(none)}]: "
        local int_flag
        read -r int_flag
        int_flag=$(trim "$int_flag")
        if [[ "$int_flag" == "none" || "$int_flag" == "clear" || "$int_flag" == "-" ]]; then
            SEL_INTERACTIVE=""
        elif [[ -n "$int_flag" ]]; then
            SEL_INTERACTIVE="$int_flag"
        elif [[ -n "$cur_int" ]]; then
            SEL_INTERACTIVE="$cur_int"
        else
            SEL_INTERACTIVE=""
        fi
        SEL_AUTO_CONFIRM=""
        SEL_AUTO_CONFIRM_MODE="false"
    elif [[ "$p_choice" == *"Clear"* ]]; then
        SEL_AUTO_CONFIRM=""
        SEL_INTERACTIVE=""
        SEL_AUTO_CONFIRM_MODE=""
    fi
    return 0
}

# Helper: Guided FZF selector for Check Updates mode
# Sets SEL_CHECK_CMD, SEL_CHECK_EXIT_CODE, SEL_CHECK_FILTER in caller scope
_select_check_mode() {
    local cur_check="$1"
    local cur_exit="$2"
    local cur_filter="$3"

    local check_presets=(
        "⚡ Always Run (No Check Command)    — Always execute update command directly"
        "📋 Output-Based Check Command       — Updates available when command prints output lines"
        "🔢 Exit-Code Check Command          — Updates available when command returns a specific exit code (e.g. 100)"
    )

    local c_choice
    c_choice=$(printf "%s\n" "${check_presets[@]}" | fzf --height 12 --reverse \
        --header "--- Select Update Check Mode ---" \
        --preview 'case "{}" in
            *Always*Run*)
                echo -e "Mode: Always Run (No Pre-Check)\n───────────────────────────────\n• Advance skips the pre-update check for this manager and always executes its Update Command.\n• Best for: self-updating binaries (e.g. rustup update), custom git-pull scripts, or fast idempotent commands.\n• Saves: CHECK_CMD=(empty)" ;;
            *Output-Based*)
                echo -e "Mode: Output-Based Check Command\n────────────────────────────────\n• Advance runs the Check Command with a 15s timeout before updating.\n• If the command prints any lines to stdout (after optional noise filtering), updates are marked as available.\n• If stdout is empty, the manager is skipped as Up to Date.\n\nCommon Examples:\n  • Arch / Pacman:   checkupdates\n  • Flatpak:         flatpak remote-ls --updates\n  • NPM:             npm outdated -g\n  • Homebrew:        brew outdated\n  • Snap:            snap refresh --list" ;;
            *Exit-Code*)
                echo -e "Mode: Exit-Code Check Command\n─────────────────────────────\n• Some package managers signal available updates via a specific non-zero exit code (such as 100 in DNF).\n• Advance runs the Check Command and treats either that exit code or non-empty output as updates available.\n\nCommon Example:\n  • Fedora DNF:      dnf check-update  (Exit Code: 100)" ;;
        esac' --preview-window=right:58%:wrap)

    [[ -z "$c_choice" ]] && return 1

    if [[ "$c_choice" == *"Always Run"* ]]; then
        SEL_CHECK_CMD=""
        SEL_CHECK_EXIT_CODE=""
        SEL_CHECK_FILTER=""
    elif [[ "$c_choice" == *"Output-Based"* ]]; then
        echo "Enter command that lists available updates to stdout (e.g. 'flatpak remote-ls --updates', 'npm outdated -g'):"
        echo -n "Check Command [current: ${cur_check:-(none)}]: "
        local r_chk
        read -r r_chk
        r_chk=$(trim "$r_chk")
        if [[ "$r_chk" == "none" || "$r_chk" == "clear" || "$r_chk" == "-" ]]; then
            SEL_CHECK_CMD=""
        elif [[ -n "$r_chk" ]]; then
            SEL_CHECK_CMD="$r_chk"
        else
            SEL_CHECK_CMD="$cur_check"
        fi
        SEL_CHECK_EXIT_CODE=""
        SEL_CHECK_FILTER="$cur_filter"
    elif [[ "$c_choice" == *"Exit-Code"* ]]; then
        echo "Enter check command (e.g. 'dnf check-update'):"
        echo -n "Check Command [current: ${cur_check:-(none)}]: "
        local r_chk
        read -r r_chk
        r_chk=$(trim "$r_chk")
        if [[ -n "$r_chk" && "$r_chk" != "none" && "$r_chk" != "clear" && "$r_chk" != "-" ]]; then
            SEL_CHECK_CMD="$r_chk"
        else
            SEL_CHECK_CMD="$cur_check"
        fi
        echo -n "Enter exit code that signals updates are available [default: ${cur_exit:-100}]: "
        local r_code
        read -r r_code
        r_code=$(trim "$r_code")
        if [[ -z "$r_code" ]]; then
            SEL_CHECK_EXIT_CODE="${cur_exit:-100}"
        elif [[ "$r_code" =~ ^[0-9]+$ ]]; then
            SEL_CHECK_EXIT_CODE="$r_code"
        else
            ui_warn "Invalid exit code; using 100."
            SEL_CHECK_EXIT_CODE="100"
        fi
        SEL_CHECK_FILTER="$cur_filter"
    fi
    return 0
}

# Helper: Live test of a manager's check command and survey filters
_test_check_cmd_live() {
    local m_name="$1"
    local c_cmd="$2"
    local c_exit="$3"
    local c_filter="$4"
    local c_fb="$5"
    local req_bin="$6"

    echo ""
    echo -e "${C_BOLD}=== Testing Check Command for '$m_name' ===${C_RESET}"
    if [[ -z "$c_cmd" ]]; then
        ui_info "Mode is set to 'Always Run' (no check command configured)."
        ui_ok "Verdict: Manager will always execute during updates."
        echo -e "\nPress Enter to return..."
        read -r
        return 0
    fi

    echo -e "  Command:       ${C_CYAN}$c_cmd${C_RESET}"
    [[ -n "$c_exit" ]] && echo -e "  Updates Code:  $c_exit"
    [[ -n "$c_filter" ]] && echo -e "  Noise Filter:  $c_filter"
    echo "Running check (15s timeout)..."

    local out exit_code
    out=$(timeout 15s bash -c "$c_cmd" 2>/dev/null)
    exit_code=$?
    echo -e "  Raw Exit Code: $exit_code"

    if [[ -n "$c_exit" && $exit_code -eq "$c_exit" ]]; then
        [[ -z "$out" ]] && out="updates available (matched exit code $c_exit)"
        exit_code=0
    fi

    if [[ -n "$c_filter" && -n "$out" ]]; then
        out=$(echo "$out" | grep -vE "$c_filter")
    fi

    if [[ $exit_code -eq 124 ]]; then
        ui_warn "Check command timed out after 15s."
        if [[ -n "$c_fb" ]]; then
            local fb_cmd="${c_fb//\$REQUIRES_CMD/$req_bin}"
            echo -e "  Running Fallback: ${C_CYAN}$fb_cmd${C_RESET}"
            out=$(eval "$fb_cmd" 2>/dev/null)
            exit_code=$?
        fi
    fi

    if [[ -n "$out" ]]; then
        local line_cnt
        line_cnt=$(printf "%s\n" "$out" | grep -c .)
        ui_ok "Verdict: Update available ($line_cnt line(s) detected)"
        echo "── Filtered Output Preview (up to 10 lines) ──"
        printf "%s\n" "$out" | head -n 10
    elif [[ $exit_code -ne 124 ]]; then
        ui_ok "Verdict: Up to date (no updates detected)"
    fi
    echo -e "\nPress Enter to return..."
    read -r
}

# Interactive submenu for Check Updates & Survey configuration
# Uses caller variables: name, check_cmd, check_exit_code, check_filter, check_timeout_fb, check_dep_bin, check_dep_cmd, requires_cmd
# If $1 == "live", persists changes immediately via _save_current_mgr & _refresh_found
_edit_check_settings_menu() {
    local mode="${1:-wizard}"
    while true; do
        local chk_disp="${check_cmd:-(Always Runs — no check command)}"
        local code_disp="${check_exit_code:-(standard: non-empty output)}"
        local filt_disp="${check_filter:-(none)}"
        local fb_disp="${check_timeout_fb:-(none)}"
        local dep_disp="${check_dep_bin:-(none)}"
        [[ -n "$check_dep_bin" && -n "$check_dep_cmd" ]] && dep_disp="$check_dep_bin ($check_dep_cmd)"

        local chk_menu=(
            "$(e 🧭)Select Check Mode Preset      (Guided Wizard)"
            "$(e 🔎)Check Updates Command         (Currently: $chk_disp)"
            "$(e 🔢)Updates Exit Code Quirk       (Currently: $code_disp)"
            "$(e 🧹)Output Noise Filter Regex     (Currently: $filt_disp)"
            "$(e ⏱️)Timeout Fallback Command      (Currently: $fb_disp)"
            "$(e 📦)Helper Dependency Binary      (Currently: $dep_disp)"
            "$(e 🧪)Test Check Command Now        (Run live & preview result)"
            "---"
            "$(e 🔙)Back"
        )

        local c_pick
        c_pick=$(printf "%s\n" "${chk_menu[@]}" | fzf --height 18 --reverse \
            --header "--- Check Updates & Survey Settings: $name ---" \
            --preview 'case "{}" in
                *Check*Mode*Preset*)
                    echo -e "🧭 Select Check Mode Preset\n───────────────────────────\nChoose between:\n• Always Run (no check command)\n• Output-Based Check Command (e.g. checkupdates, flatpak remote-ls --updates)\n• Exit-Code Check Command (e.g. dnf check-update with exit code 100)" ;;
                *Check*Updates*Command*)
                    echo -e "🔎 Check Updates Command (CHECK_CMD)\n────────────────────────────────────\nCommand executed during the survey phase (advance --check or before updates).\n\n• If empty, Advance always runs the update command.\n• If set, Advance runs this command (15s timeout) and checks whether it produces output." ;;
                *Exit*Code*Quirk*)
                    echo -e "🔢 Updates Exit Code Quirk (CHECK_UPDATES_EXIT_CODE)\n────────────────────────────────────────────────────\nOptional non-zero exit code that signals updates are available even if output is empty.\n\n• Example: DNF returns exit code 100 when updates are available." ;;
                *Noise*Filter*)
                    echo -e "🧹 Output Noise Filter Regex (CHECK_FILTER_PATTERN)\n───────────────────────────────────────────────────\nExtended regular expression (grep -vE) used to strip header lines or status banners from CHECK_CMD output so they are not mistaken for available package updates.\n\n• Example (APT): ^Listing\n• Example (Cargo): Polling registry|^Package|^[[:space:]]*$|[[:space:]]No[[:space:]]*$" ;;
                *Timeout*Fallback*)
                    echo -e "⏱️ Timeout Fallback Command (CHECK_TIMEOUT_FALLBACK)\n────────────────────────────────────────────────────\nOptional fast offline fallback command executed if CHECK_CMD times out after 15 seconds.\n\n• Example (Arch): \$REQUIRES_CMD -Qu" ;;
                *Helper*Dependency*)
                    echo -e "📦 Helper Dependency (CHECK_DEP_BIN / CHECK_DEP_INSTALL_CMD)\n────────────────────────────────────────────────────────────\nOptional helper binary required by CHECK_CMD (e.g. checkupdates from pacman-contrib) and the command to auto-install it if missing." ;;
                *Test*Check*Command*)
                    echo -e "🧪 Test Check Command Now\n─────────────────────────\nExecutes your configured Check Command right now with a 15s timeout, applies your Exit Code and Noise Filter settings, and shows whether Advance detects available updates." ;;
                *)
                    echo "Select an option to configure how Advance checks for updates." ;;
            esac' --preview-window=right:55%:wrap)

        [[ -z "$c_pick" || "$c_pick" == *Back* ]] && break

        if [[ "$c_pick" == *"Check Mode Preset"* ]]; then
            if _select_check_mode "$check_cmd" "$check_exit_code" "$check_filter"; then
                check_cmd="$SEL_CHECK_CMD"
                check_exit_code="$SEL_CHECK_EXIT_CODE"
                check_filter="$SEL_CHECK_FILTER"
                if [[ "$mode" == "live" ]]; then
                    _save_current_mgr
                    _refresh_found
                fi
                ui_ok "Check mode updated."
            fi
        elif [[ "$c_pick" == *"Check Updates Command"* ]]; then
            echo "Enter check command to detect available updates ('none' or 'clear' for Always Run, press Enter to keep):"
            echo -n "Check Command [current: ${check_cmd:-(always runs)}]: "
            local r_chk
            read -r r_chk
            r_chk=$(trim "$r_chk")
            if [[ "$r_chk" == "none" || "$r_chk" == "-" || "$r_chk" == "clear" ]]; then
                check_cmd=""
                if [[ "$mode" == "live" ]]; then _save_current_mgr; _refresh_found; fi
                ui_ok "Check command cleared (manager will always run)."
            elif [[ -n "$r_chk" ]]; then
                check_cmd="$r_chk"
                if [[ "$mode" == "live" ]]; then _save_current_mgr; _refresh_found; fi
                ui_ok "Check command updated."
            fi
        elif [[ "$c_pick" == *"Exit Code Quirk"* ]]; then
            echo "Enter exit code that indicates updates are available (e.g. 100 for DNF, 'none' to clear):"
            echo -n "Updates Exit Code [current: ${check_exit_code:-(none)}]: "
            local r_code
            read -r r_code
            r_code=$(trim "$r_code")
            if [[ "$r_code" == "none" || "$r_code" == "-" || "$r_code" == "clear" ]]; then
                check_exit_code=""
                if [[ "$mode" == "live" ]]; then _save_current_mgr; _refresh_found; fi
                ui_ok "Updates exit code cleared."
            elif [[ "$r_code" =~ ^[0-9]+$ ]]; then
                check_exit_code="$r_code"
                if [[ "$mode" == "live" ]]; then _save_current_mgr; _refresh_found; fi
                ui_ok "Updates exit code set to $check_exit_code."
            elif [[ -n "$r_code" ]]; then
                ui_warn "Exit code must be a non-negative integer."
            fi
        elif [[ "$c_pick" == *"Noise Filter"* ]]; then
            echo "Enter extended regex of lines to ignore in check output (e.g. '^Listing', 'none' to clear):"
            echo -n "Filter Regex [current: ${check_filter:-(none)}]: "
            local r_filt
            read -r r_filt
            r_filt=$(trim "$r_filt")
            if [[ "$r_filt" == "none" || "$r_filt" == "-" || "$r_filt" == "clear" ]]; then
                check_filter=""
                if [[ "$mode" == "live" ]]; then _save_current_mgr; _refresh_found; fi
                ui_ok "Output noise filter cleared."
            elif [[ -n "$r_filt" ]]; then
                check_filter="$r_filt"
                if [[ "$mode" == "live" ]]; then _save_current_mgr; _refresh_found; fi
                ui_ok "Output noise filter updated."
            fi
        elif [[ "$c_pick" == *"Timeout Fallback"* ]]; then
            echo "Enter fallback command if check exceeds 15s (e.g. '\$REQUIRES_CMD -Qu', 'none' to clear):"
            echo -n "Timeout Fallback [current: ${check_timeout_fb:-(none)}]: "
            local r_fb
            read -r r_fb
            r_fb=$(trim "$r_fb")
            if [[ "$r_fb" == "none" || "$r_fb" == "-" || "$r_fb" == "clear" ]]; then
                check_timeout_fb=""
                if [[ "$mode" == "live" ]]; then _save_current_mgr; _refresh_found; fi
                ui_ok "Timeout fallback cleared."
            elif [[ -n "$r_fb" ]]; then
                check_timeout_fb="$r_fb"
                if [[ "$mode" == "live" ]]; then _save_current_mgr; _refresh_found; fi
                ui_ok "Timeout fallback updated."
            fi
        elif [[ "$c_pick" == *"Helper Dependency"* ]]; then
            echo "Enter helper binary required by check command (e.g. 'checkupdates', 'none' to clear):"
            echo -n "Helper Binary [current: ${check_dep_bin:-(none)}]: "
            local r_dbin
            read -r r_dbin
            r_dbin=$(trim "$r_dbin")
            if [[ "$r_dbin" == "none" || "$r_dbin" == "-" || "$r_dbin" == "clear" ]]; then
                check_dep_bin=""
                check_dep_cmd=""
                if [[ "$mode" == "live" ]]; then _save_current_mgr; _refresh_found; fi
                ui_ok "Helper dependency cleared."
            elif [[ -n "$r_dbin" ]]; then
                check_dep_bin="$r_dbin"
                echo -n "Enter install command for '$check_dep_bin' [current: ${check_dep_cmd:-(none)}]: "
                local r_dcmd
                read -r r_dcmd
                r_dcmd=$(trim "$r_dcmd")
                [[ -n "$r_dcmd" ]] && check_dep_cmd="$r_dcmd"
                if [[ "$mode" == "live" ]]; then _save_current_mgr; _refresh_found; fi
                ui_ok "Helper dependency updated."
            fi
        elif [[ "$c_pick" == *"Test Check Command"* ]]; then
            _test_check_cmd_live "$name" "$check_cmd" "$check_exit_code" "$check_filter" "$check_timeout_fb" "$requires_cmd"
        fi
    done
}

# Interactive submenu for Advanced Manager Settings (Daemon probe, package hold/unhold, post-update messages)
# Uses caller variables: name, probe_cmd, exclude_hold_cmd, exclude_unhold_cmd, post_update_msg, post_update_msg_id
# If $1 == "live", persists changes immediately via _save_current_mgr & _refresh_found
_edit_advanced_settings_menu() {
    local mode="${1:-wizard}"
    while true; do
        local probe_disp="${probe_cmd:-(none)}"
        local hold_disp="${exclude_hold_cmd:-(none)}"
        local unhold_disp="${exclude_unhold_cmd:-(none)}"
        local msg_disp="${post_update_msg:-(none)}"
        local msg_id_disp="${post_update_msg_id:-(none)}"

        local adv_menu=(
            "$(e 🔌)Runtime Service / Daemon Probe  (Currently: $probe_disp)"
            "$(e 🔒)Package Hold Command            (Currently: $hold_disp)"
            "$(e 🔓)Package Unhold Command          (Currently: $unhold_disp)"
            "$(e 📢)Post-Update Notification Msg    (Currently: $msg_disp)"
            "$(e 🆔)Post-Update Message ID          (Currently: $msg_id_disp)"
            "---"
            "$(e 🔙)Back"
        )

        local a_pick
        a_pick=$(printf "%s\n" "${adv_menu[@]}" | fzf --height 16 --reverse \
            --header "--- Advanced Engine Settings: $name ---" \
            --preview 'case "{}" in
                *Runtime*Service*|*Daemon*Probe*)
                    echo -e "🔌 Runtime Daemon / Service Probe (PROBE_ACTIVE_CMD)\n────────────────────────────────────────────────\nCommand executed by Advance before checking or scheduling updates to verify that a background service or daemon is running.\n\n• If exit code is 0, Advance proceeds with the manager.\n• If non-zero, Advance considers the manager inactive and skips it.\n• Examples:\n    systemctl is-active --quiet docker\n    pgrep -x snapd\n    docker info" ;;
                *Package*Hold*Command*)
                    echo -e "🔒 Package Hold Command (EXCLUDE_HOLD_CMD)\n──────────────────────────────────────────\nCommand template used to temporarily lock or hold packages from updates.\n\n• Package name is appended to the command.\n• Examples:\n    sudo apt-mark hold\n    pacman -D --asdeps" ;;
                *Package*Unhold*Command*)
                    echo -e "🔓 Package Unhold Command (EXCLUDE_UNHOLD_CMD)\n────────────────────────────────────────────\nCommand template used to release previously held packages.\n\n• Package name is appended to the command.\n• Examples:\n    sudo apt-mark unhold\n    pacman -D --asexplicit" ;;
                *Post-Update*Notification*)
                    echo -e "📢 Post-Update Notification Message (POST_UPDATE_MSG)\n────────────────────────────────────────────────────\nNotice displayed to the user after this package manager completes an update.\n\n• Useful to advise restarting a service, logging out, or rebooting.\n• Example: A new kernel or display driver was updated; reboot recommended." ;;
                *Post-Update*Message*ID*)
                    echo -e "🆔 Post-Update Message ID (POST_UPDATE_MSG_ID)\n─────────────────────────────────────────────\nUnique identifier for this post-update notification message to allow dismissing or tracking." ;;
                *) echo "Select an advanced setting to configure." ;;
            esac' --preview-window=right:55%:wrap)

        [[ -z "$a_pick" || "$a_pick" == *Back* ]] && break

        if [[ "$a_pick" == *"Runtime Service"* ]]; then
            echo "Enter daemon / service check command (e.g. 'systemctl is-active --quiet docker', 'none' to clear):"
            echo -n "Probe Command [current: ${probe_cmd:-(none)}]: "
            local r_pr
            read -r r_pr
            r_pr=$(trim "$r_pr")
            if [[ "$r_pr" == "none" || "$r_pr" == "-" || "$r_pr" == "clear" ]]; then
                probe_cmd=""
                if [[ "$mode" == "live" ]]; then _save_current_mgr; _refresh_found; fi
                ui_ok "Service probe command cleared."
            elif [[ -n "$r_pr" ]]; then
                probe_cmd="$r_pr"
                if [[ "$mode" == "live" ]]; then _save_current_mgr; _refresh_found; fi
                ui_ok "Service probe command updated."
            fi
        elif [[ "$a_pick" == *"Package Hold Command"* ]]; then
            echo "Enter package hold command (e.g. 'sudo apt-mark hold', 'none' to clear):"
            echo -n "Hold Command [current: ${exclude_hold_cmd:-(none)}]: "
            local r_hold
            read -r r_hold
            r_hold=$(trim "$r_hold")
            if [[ "$r_hold" == "none" || "$r_hold" == "-" || "$r_hold" == "clear" ]]; then
                exclude_hold_cmd=""
                if [[ "$mode" == "live" ]]; then _save_current_mgr; _refresh_found; fi
                ui_ok "Package hold command cleared."
            elif [[ -n "$r_hold" ]]; then
                exclude_hold_cmd="$r_hold"
                if [[ "$mode" == "live" ]]; then _save_current_mgr; _refresh_found; fi
                ui_ok "Package hold command updated."
            fi
        elif [[ "$a_pick" == *"Package Unhold Command"* ]]; then
            echo "Enter package unhold command (e.g. 'sudo apt-mark unhold', 'none' to clear):"
            echo -n "Unhold Command [current: ${exclude_unhold_cmd:-(none)}]: "
            local r_unhold
            read -r r_unhold
            r_unhold=$(trim "$r_unhold")
            if [[ "$r_unhold" == "none" || "$r_unhold" == "-" || "$r_unhold" == "clear" ]]; then
                exclude_unhold_cmd=""
                if [[ "$mode" == "live" ]]; then _save_current_mgr; _refresh_found; fi
                ui_ok "Package unhold command cleared."
            elif [[ -n "$r_unhold" ]]; then
                exclude_unhold_cmd="$r_unhold"
                if [[ "$mode" == "live" ]]; then _save_current_mgr; _refresh_found; fi
                ui_ok "Package unhold command updated."
            fi
        elif [[ "$a_pick" == *"Post-Update Notification"* ]]; then
            echo "Enter message displayed after updates run ('none' to clear):"
            echo -n "Post-Update Message [current: ${post_update_msg:-(none)}]: "
            local r_msg
            read -r r_msg
            r_msg=$(trim "$r_msg")
            if [[ "$r_msg" == "none" || "$r_msg" == "-" || "$r_msg" == "clear" ]]; then
                post_update_msg=""
                if [[ "$mode" == "live" ]]; then _save_current_mgr; _refresh_found; fi
                ui_ok "Post-update message cleared."
            elif [[ -n "$r_msg" ]]; then
                post_update_msg="$r_msg"
                if [[ -z "$post_update_msg_id" ]]; then
                    post_update_msg_id="${name,,}_reboot_notice"
                fi
                if [[ "$mode" == "live" ]]; then _save_current_mgr; _refresh_found; fi
                ui_ok "Post-update message updated."
            fi
        elif [[ "$a_pick" == *"Post-Update Message ID"* ]]; then
            echo "Enter message ID string (e.g. 'docker_restart_notice', 'none' to clear):"
            echo -n "Message ID [current: ${post_update_msg_id:-(none)}]: "
            local r_mid
            read -r r_mid
            r_mid=$(trim "$r_mid")
            if [[ "$r_mid" == "none" || "$r_mid" == "-" || "$r_mid" == "clear" ]]; then
                post_update_msg_id=""
                if [[ "$mode" == "live" ]]; then _save_current_mgr; _refresh_found; fi
                ui_ok "Post-update message ID cleared."
            elif [[ -n "$r_mid" ]]; then
                post_update_msg_id="$r_mid"
                if [[ "$mode" == "live" ]]; then _save_current_mgr; _refresh_found; fi
                ui_ok "Post-update message ID updated."
            fi
        fi
    done
}

# --- PRIORITY & EXECUTION ORDER HELPERS ---

_is_mgr_available() {
    local idx="$1"
    local req="${CUSTOM_REQUIRES_CMDS[$idx]}"
    if [[ -n "$req" ]] && ! command -v "$req" >/dev/null 2>&1; then
        return 1
    fi
    local probe="${CUSTOM_PROBE_ACTIVE_CMDS[$idx]}"
    if [[ -n "$probe" ]] && ! eval "$probe" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# Returns manager indices in a group sorted by PRIORITY descending, then NAME ascending
_get_group_manager_indices() {
    local grp="$1"
    local indices=()
    local priorities=()
    local names=()
    local i
    for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
        [[ "${CUSTOM_GROUPS[$i]}" != "$grp" ]] && continue
        indices+=("$i")
        priorities+=("${CUSTOM_PRIORITIES[$i]:-0}")
        names+=("${CUSTOM_NAMES[$i]}")
    done

    local n=${#indices[@]}
    local j tmp
    for ((i=0; i<n-1; i++)); do
        for ((j=0; j<n-i-1; j++)); do
            local p1="${priorities[$j]}"
            local p2="${priorities[$((j+1))]}"
            if [[ $p1 -lt $p2 || ( $p1 -eq $p2 && "${names[$gj]:-${names[$j]}}" > "${names[$((j+1))]}" ) ]]; then
                tmp="${indices[$j]}"; indices[$j]="${indices[$((j+1))]}"; indices[$((j+1))]="$tmp"
                tmp="${priorities[$j]}"; priorities[$j]="${priorities[$((j+1))]}"; priorities[$((j+1))]="$tmp"
                tmp="${names[$j]}"; names[$j]="${names[$((j+1))]}"; names[$((j+1))]="$tmp"
            fi
        done
    done
    [[ ${#indices[@]} -gt 0 ]] && printf "%s\n" "${indices[@]}"
}

# Compute next conflict-free priority in a group ("highest" or "lowest")
_get_next_free_group_priority() {
    local grp="$1"
    local mode="${2:-highest}"
    [[ -z "$grp" ]] && { echo "0"; return 0; }

    local g_indices=()
    mapfile -t g_indices < <(_get_group_manager_indices "$grp")
    if [[ ${#g_indices[@]} -eq 0 ]]; then
        echo "10"
        return 0
    fi

    if [[ "$mode" == "lowest" ]]; then
        local last_idx="${g_indices[$((${#g_indices[@]} - 1))]}"
        local min_p="${CUSTOM_PRIORITIES[$last_idx]:-10}"
        local cand=$((min_p - 10))
        [[ $cand -lt 1 && $min_p -gt 1 ]] && cand=1
        [[ $cand -eq $min_p ]] && cand=$((min_p - 1))
        echo "$cand"
    else
        local first_idx="${g_indices[0]}"
        local max_p="${CUSTOM_PRIORITIES[$first_idx]:-0}"
        local cand=$((max_p + 10))
        [[ $cand -le 0 ]] && cand=10
        echo "$cand"
    fi
}

_save_mgr_by_idx() {
    local idx="$1"
    local new_pri="${2:-${CUSTOM_PRIORITIES[$idx]}}"
    CUSTOM_PRIORITIES[$idx]="$new_pri"
    save_custom_manager \
        "${CUSTOM_NAMES[$idx]}" \
        "${CUSTOM_EMOJIS[$idx]}" \
        "${CUSTOM_CHECKS[$idx]}" \
        "${CUSTOM_UPDATES[$idx]}" \
        "${CUSTOM_FLAGS_AUTO_CONFIRMS[$idx]}" \
        "${CUSTOM_FLAGS_INTERACTIVES[$idx]}" \
        "${CUSTOM_FLAGS_OVERRIDES[$idx]}" \
        "${CUSTOM_ENABLEDS[$idx]}" \
        "${CUSTOM_FILES[$idx]}" \
        "${CUSTOM_REQUIRES_CMDS[$idx]}" \
        "$new_pri" \
        "${CUSTOM_FLAGS[$idx]}" \
        "${CUSTOM_AUTO_CONFIRMS[$idx]}" \
        "${CUSTOM_COLOR_FLAGS[$idx]}" \
        "${CUSTOM_EXCLUDE_FLAGS[$idx]}" \
        "${CUSTOM_EXCLUDE_JOINS[$idx]}" \
        "${CUSTOM_EXCLUDE_HOLD_CMDS[$idx]}" \
        "${CUSTOM_EXCLUDE_UNHOLD_CMDS[$idx]}" \
        "${CUSTOM_CHECK_UPDATES_EXIT_CODES[$idx]}" \
        "${CUSTOM_CHECK_FILTER_PATTERNS[$idx]}" \
        "${CUSTOM_CHECK_TIMEOUT_FALLBACKS[$idx]}" \
        "${CUSTOM_POST_MSG_IDS[$idx]}" \
        "${CUSTOM_POST_MSGS[$idx]}" \
        "${CUSTOM_CHECK_DEP_BINS[$idx]}" \
        "${CUSTOM_CHECK_DEP_INSTALLS[$idx]}" \
        "${CUSTOM_PROBE_ACTIVE_CMDS[$idx]}"
}

# Renumbers an ordered list of manager indices in clean descending multiples of 10 (N*10 ... 20, 10)
_renumber_group_managers() {
    local grp="$1"
    shift
    local ordered=("$@")
    local total=${#ordered[@]}
    local pos idx target_p
    for ((pos=0; pos<total; pos++)); do
        idx="${ordered[$pos]}"
        [[ -z "$idx" ]] && continue
        target_p=$(( (total - pos) * 10 ))
        if [[ "${CUSTOM_PRIORITIES[$idx]}" != "$target_p" ]]; then
            _save_mgr_by_idx "$idx" "$target_p"
        fi
    done
}

# Moves a manager up, down, top, or bottom within its group and renumbers conflict-free
_move_manager_in_group() {
    local mgr_idx="$1"
    local dir="$2"
    local grp="${CUSTOM_GROUPS[$mgr_idx]}"
    [[ -z "$grp" ]] && return 1

    local g_indices=()
    mapfile -t g_indices < <(_get_group_manager_indices "$grp")
    local n=${#g_indices[@]}
    [[ $n -le 1 ]] && return 0

    local pos=-1 i
    for ((i=0; i<n; i++)); do
        if [[ "${g_indices[$i]}" -eq "$mgr_idx" ]]; then
            pos=$i
            break
        fi
    done
    [[ $pos -eq -1 ]] && return 1

    local new_order=()
    case "$dir" in
        up)
            [[ $pos -eq 0 ]] && return 0
            local tmp="${g_indices[$((pos-1))]}"
            g_indices[$((pos-1))]="${g_indices[$pos]}"
            g_indices[$pos]="$tmp"
            new_order=("${g_indices[@]}")
            ;;
        down)
            [[ $pos -ge $((n-1)) ]] && return 0
            local tmp="${g_indices[$((pos+1))]}"
            g_indices[$((pos+1))]="${g_indices[$pos]}"
            g_indices[$pos]="$tmp"
            new_order=("${g_indices[@]}")
            ;;
        top)
            new_order+=("$mgr_idx")
            for ((i=0; i<n; i++)); do
                [[ $i -ne $pos ]] && new_order+=("${g_indices[$i]}")
            done
            ;;
        bottom)
            for ((i=0; i<n; i++)); do
                [[ $i -ne $pos ]] && new_order+=("${g_indices[$i]}")
            done
            new_order+=("$mgr_idx")
            ;;
    esac

    _renumber_group_managers "$grp" "${new_order[@]}"
    load_custom_managers
    return 0
}

# Sets a custom priority on a manager, automatically shifting colliding managers in the same group
_set_manager_priority_conflict_free() {
    local mgr_idx="$1"
    local target_pri="$2"
    local grp="${CUSTOM_GROUPS[$mgr_idx]}"

    _save_mgr_by_idx "$mgr_idx" "$target_pri"
    if [[ -n "$grp" ]]; then
        # Check and resolve any priority collisions in the group
        local g_indices=()
        mapfile -t g_indices < <(_get_group_manager_indices "$grp")
        # Ensure mgr_idx precedes any manager it collided with at target_pri
        local ordered=()
        local i
        for i in "${g_indices[@]}"; do
            [[ "$i" -eq "$mgr_idx" ]] && continue
            if [[ "${CUSTOM_PRIORITIES[$i]}" -eq "$target_pri" && ! " ${ordered[*]} " =~ " $mgr_idx " ]]; then
                ordered+=("$mgr_idx")
            fi
            ordered+=("$i")
        done
        if [[ ! " ${ordered[*]} " =~ " $mgr_idx " ]]; then
            # Insert in sorted position
            ordered=()
            local inserted=false
            for i in "${g_indices[@]}"; do
                [[ "$i" -eq "$mgr_idx" ]] && continue
                if [[ "$inserted" == false && "$target_pri" -gt "${CUSTOM_PRIORITIES[$i]:-0}" ]]; then
                    ordered+=("$mgr_idx")
                    inserted=true
                fi
                ordered+=("$i")
            done
            [[ "$inserted" == false ]] && ordered+=("$mgr_idx")
        fi

        # Shift down any colliding priorities so order is strictly descending
        local prev_p="" idx cur_p
        for idx in "${ordered[@]}"; do
            cur_p="${CUSTOM_PRIORITIES[$idx]:-0}"
            if [[ -n "$prev_p" && "$cur_p" -ge "$prev_p" ]]; then
                cur_p=$((prev_p - 1))
                _save_mgr_by_idx "$idx" "$cur_p"
            fi
            prev_p="$cur_p"
        done
    fi
    load_custom_managers
}

# Moves a group up, down, or top in execution order and renumbers group priorities cleanly
_move_group_order() {
    local target_grp="$1"
    local dir="$2"
    local all_grps=()
    mapfile -t all_grps < <(get_all_groups)
    local n=${#all_grps[@]}
    [[ $n -le 1 ]] && return 0

    local pos=-1 i
    for ((i=0; i<n; i++)); do
        if [[ "${all_grps[$i]}" == "$target_grp" ]]; then
            pos=$i
            break
        fi
    done
    [[ $pos -eq -1 ]] && return 1

    local new_grps=()
    case "$dir" in
        up)
            [[ $pos -eq 0 ]] && return 0
            local tmp="${all_grps[$((pos-1))]}"
            all_grps[$((pos-1))]="${all_grps[$pos]}"
            all_grps[$pos]="$tmp"
            new_grps=("${all_grps[@]}")
            ;;
        down)
            [[ $pos -ge $((n-1)) ]] && return 0
            local tmp="${all_grps[$((pos+1))]}"
            all_grps[$((pos+1))]="${all_grps[$pos]}"
            all_grps[$pos]="$tmp"
            new_grps=("${all_grps[@]}")
            ;;
        top)
            new_grps+=("$target_grp")
            for ((i=0; i<n; i++)); do
                [[ $i -ne $pos ]] && new_grps+=("${all_grps[$i]}")
            done
            ;;
    esac

    for ((i=0; i<n; i++)); do
        local gp=$(( (n - i) * 10 ))
        GROUP_PRIORITY[${new_grps[$i]}]="$gp"
    done
    save_config
    return 0
}

_format_group_order_preview() {
    local grp="$1"
    local grp_enabled="${GROUP_ENABLED[$grp]:-true}"
    local grp_pri
    grp_pri=$(get_group_priority "$grp")
    echo -e "📁 Group: $grp  (Execution Priority: $grp_pri)"
    echo -e "──────────────────────────────────────────────"
    local g_indices=()
    mapfile -t g_indices < <(_get_group_manager_indices "$grp")
    local has_winner=false sb_rank=0 idx
    for idx in "${g_indices[@]}"; do
        [[ -z "$idx" ]] && continue
        local m_name="${CUSTOM_NAMES[$idx]}"
        local m_pri="${CUSTOM_PRIORITIES[$idx]:-0}"
        local m_en="${CUSTOM_ENABLEDS[$idx]}"
        local badge=""
        if [[ "$m_en" != "true" ]]; then
            badge="[○ Disabled]"; [[ "$USE_EMOJI" != true ]] && badge="[OFF Disabled]"
        elif ! _is_mgr_available "$idx"; then
            badge="[✖ Missing Binary]"; [[ "$USE_EMOJI" != true ]] && badge="[x Missing Binary]"
        elif [[ "$grp_enabled" != "true" ]]; then
            badge="[⏸ Group Disabled]"; [[ "$USE_EMOJI" != true ]] && badge="[-- Group Disabled]"
        elif [[ "$has_winner" == false ]]; then
            has_winner=true
            badge="[★ Active Winner]"; [[ "$USE_EMOJI" != true ]] && badge="[* Active Winner]"
        else
            ((++sb_rank))
            badge="[↳ Standby #$sb_rank]"; [[ "$USE_EMOJI" != true ]] && badge="[> Standby #$sb_rank]"
        fi
        printf "  • %-16s  [P:%-3s]  %s\n" "$m_name" "$m_pri" "$badge"
    done
}

manage_custom_managers_menu() {
    local last_idx=0
    local target_meta=""
    while true; do
        load_custom_managers
        local groups
        mapfile -t groups < <(get_all_groups)

        local opt=()
        local opt_meta=()
        opt+=("--- ACTIONS ---"$'\t'"sep")
        opt_meta+=("sep")
        opt+=("$(e 🔍)Scan System for Tools (Auto-Enroll)"$'\t'"action:scan")
        opt_meta+=("action:scan")
        opt+=("$(e 📚)Browse Official Catalog..."$'\t'"action:catalog")
        opt_meta+=("action:catalog")
        opt+=("$(e ➕)Add Custom Package Manager..."$'\t'"action:add")
        opt_meta+=("action:add")

        # Show groups in execution order with their managers sorted by priority descending
        local i g g_rank=0
        for g in "${groups[@]}"; do
            ((++g_rank))
            local grp_enabled="${GROUP_ENABLED[$g]:-true}"
            local grp_status="Enabled"
            [[ "$grp_enabled" != "true" ]] && grp_status="Disabled"
            local grp_pri
            grp_pri=$(get_group_priority "$g")
            opt+=("--- [#$g_rank] $g ($grp_status) [Order P:$grp_pri] ---"$'\t'"group:$g")
            opt_meta+=("group:$g")

            local g_indices=()
            mapfile -t g_indices < <(_get_group_manager_indices "$g")
            local has_winner=false sb_rank=0
            for i in "${g_indices[@]}"; do
                [[ -z "$i" ]] && continue
                local name="${CUSTOM_NAMES[$i]}"
                local m_emoji="${CUSTOM_EMOJIS[$i]:-📦}"
                local enabled="${CUSTOM_ENABLEDS[$i]}"
                local pri="${CUSTOM_PRIORITIES[$i]:-0}"
                local role_badge=""
                if [[ "$enabled" != "true" ]]; then
                    role_badge="[○ Disabled]"; [[ "$USE_EMOJI" != true ]] && role_badge="[OFF Disabled]"
                elif ! _is_mgr_available "$i"; then
                    role_badge="[✖ Missing]"; [[ "$USE_EMOJI" != true ]] && role_badge="[x Missing]"
                elif [[ "$grp_enabled" != "true" ]]; then
                    role_badge="[⏸ Group Off]"; [[ "$USE_EMOJI" != true ]] && role_badge="[-- Group Off]"
                elif [[ "$has_winner" == false ]]; then
                    has_winner=true
                    role_badge="[★ Active Winner]"; [[ "$USE_EMOJI" != true ]] && role_badge="[* Active Winner]"
                else
                    ((++sb_rank))
                    role_badge="[↳ Standby #$sb_rank]"; [[ "$USE_EMOJI" != true ]] && role_badge="[> Standby #$sb_rank]"
                fi
                local row_str
                row_str=$(printf "  %s%-18s [P:%-3s]  %s" "$(e "$m_emoji")" "$name" "$pri" "$role_badge")
                opt+=("$row_str"$'\t'"${CUSTOM_FILES[$i]}"$'\t'"$g")
                opt_meta+=("mgr:$name")
            done
        done

        # Show standalone managers
        local has_standalone=false
        for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
            [[ -n "${CUSTOM_GROUPS[$i]}" ]] && continue
            has_standalone=true
            break
        done
        if [[ "$has_standalone" == true ]]; then
            opt+=("--- standalone (run independently) ---"$'\t'"sep_standalone")
            opt_meta+=("sep")
            for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
                [[ -n "${CUSTOM_GROUPS[$i]}" ]] && continue
                local name="${CUSTOM_NAMES[$i]}"
                local m_emoji="${CUSTOM_EMOJIS[$i]:-📦}"
                local enabled="${CUSTOM_ENABLEDS[$i]}"
                local role_badge="[★ Active]"; [[ "$USE_EMOJI" != true ]] && role_badge="[* Active]"
                if [[ "$enabled" != "true" ]]; then
                    role_badge="[○ Disabled]"; [[ "$USE_EMOJI" != true ]] && role_badge="[OFF Disabled]"
                elif ! _is_mgr_available "$i"; then
                    role_badge="[✖ Missing]"; [[ "$USE_EMOJI" != true ]] && role_badge="[x Missing]"
                fi
                local row_str
                row_str=$(printf "  %s%-18s [Solo]   %s" "$(e "$m_emoji")" "$name" "$role_badge")
                opt+=("$row_str"$'\t'"${CUSTOM_FILES[$i]}"$'\t'"(standalone)")
                opt_meta+=("mgr:$name")
            done
        fi

        opt+=("---"$'\t'"sep")
        opt_meta+=("sep")
        opt+=("$(e 🔙)Back"$'\t'"back")
        opt_meta+=("back")

        # Restore cursor position by target_meta if set, otherwise last_idx
        if [[ -n "$target_meta" ]]; then
            local m_idx
            for ((m_idx=0; m_idx<${#opt_meta[@]}; m_idx++)); do
                if [[ "${opt_meta[$m_idx]}" == "$target_meta" ]]; then
                    last_idx=$m_idx
                    break
                fi
            done
            target_meta=""
        fi

        local bind_args=()
        [[ $last_idx -gt 0 ]] && bind_args=(--bind "start:pos($((last_idx + 1)))")
        local fzf_out
        fzf_out=$(printf "%s\n" "${opt[@]}" | fzf --height 22 --reverse "${bind_args[@]}" \
            --delimiter=$'\t' --with-nth=1 \
            --expect=alt-up,alt-down,ctrl-up,ctrl-down \
            --header "--- Package Managers & Execution Order (Alt+Up/Down: Reorder | Enter: Configure) ---" \
            --preview 'case "{2}" in
                action:scan)
                    echo -e "🔍 Scan System for Tools\n────────────────────────\nProbes your system and automatically enrolls any installed package managers from the official catalog into Advance as clean symlinks." ;;
                action:catalog)
                    echo -e "📚 Browse Official Catalog\n──────────────────────────\nView all official recipes (system, containers, language runtimes, firmware) and easily enroll or un-enroll them." ;;
                action:add)
                    echo -e "➕ Add Package Manager\n──────────────────────\nRegister a new package manager or custom update script.\n\nYou can configure custom update commands, group priorities, auto-confirm flags, and required binaries." ;;
                sep_standalone)
                    echo -e "📦 Standalone Managers\n──────────────────────\nThese managers run independently and do not compete with any group." ;;
                sep)
                    echo -e "⚡ Actions\n──────────\nCommon management options." ;;
                group:*)
                    echo -e "📁 Group Execution Header\n─────────────────────────\n• Press Enter to toggle this group ON/OFF or adjust its execution order.\n• Press Alt+Up / Alt+Down directly in the list to move this group earlier or later!\n\nPriority Rule:\n• Groups run in descending order (#1 runs first, #2 second, etc.).\n• Inside each group, only the ★ Active Winner runs; ↳ Standby managers act as automatic fallbacks." ;;
                back)
                    echo -e "🔙 Back\n───────\nReturn to the configuration menu." ;;
                *)
                    f="{2}"
                    grp="{3}"
                    if [ -f "$f" ]; then
                        awk -v grp="$grp" '\''
                            function val(line) { sub(/^[^=]*=/, "", line); return (line != "" ? line : "(none)") }
                            /^NAME=/            { name=val($0) }
                            /^EMOJI=/           { emoji=val($0) }
                            /^ENABLED=/         { enabled=val($0) }
                            /^REQUIRES_CMD=/    { req=val($0) }
                            /^PRIORITY=/        { pri=val($0) }
                            /^CHECK_CMD=/       { check=val($0) }
                            /^UPDATE_CMD=/      { update=val($0) }
                            /^FLAGS=/           { flags=val($0) }
                            /^AUTO_CONFIRM=/    { ac=val($0) }
                            /^FLAGS_AUTO_CONFIRM=/ { fac=val($0) }
                            /^FLAGS_INTERACTIVE=/  { fi_f=val($0) }
                            /^FLAGS_OVERRIDE=/  { fo=val($0) }
                            /^COLOR_FLAG=/      { cf=val($0) }
                            /^EXCLUDE_FLAG=/    { ef=val($0) }
                            /^EXCLUDE_JOIN=/    { ej=val($0) }
                            /^EXCLUDE_HOLD_CMD=/   { eh=val($0) }
                            /^EXCLUDE_UNHOLD_CMD=/ { eu=val($0) }
                            END {
                                printf "=== %s %s ===\n\n", emoji, name
                                printf "  Status:        %s\n", enabled
                                printf "  Requires:      %s\n", req
                                printf "  Priority:      %s  (Tip: Alt+Up/Down to reorder)\n", pri
                                printf "  Group:         %s\n\n", grp
                                print "── Commands ──"
                                printf "  Check:         %s\n", (check ? check : "(always runs)")
                                printf "  Update:        %s\n\n", update
                                print "── Flags ──"
                                printf "  Persistent:    %s\n", flags
                                ac_str = (ac == "(none)" ? "(follow global)" : (ac == "true" ? "ON unless forced" : "OFF unless forced"))
                                printf "  Auto-Confirm:  %s\n", ac_str
                                printf "  Confirm Flag:  %s\n", fac
                                printf "  Interactive:   %s\n", fi_f
                                printf "  Override:      %s\n", fo
                                printf "  Color:         %s\n\n", cf
                                print "── Exclusions ──"
                                printf "  Flag:          %s\n", ef
                                printf "  Join:          %s\n", ej
                                printf "  Hold Cmd:      %s\n", eh
                                printf "  Unhold Cmd:    %s\n", eu
                            }
                        '\'' "$f"
                    else
                        echo -e "Select a manager to inspect its configuration."
                    fi
                    ;;
            esac' --preview-window=right:55%:wrap)

        local key choice
        { IFS= read -r key; IFS= read -r choice; } <<< "$fzf_out"
        [[ -z "$choice" || "$choice" == *$'\t'back ]] && return 0

        # Resolve selected index and metadata
        local idx=0 sel_meta=""
        for item in "${opt[@]}"; do
            if [[ "$item" == "$choice" ]]; then
                last_idx=$idx
                sel_meta="${opt_meta[$idx]}"
                break
            fi
            ((idx++))
        done

        # Handle direct Alt+Up/Down or Ctrl+Up/Down hotkeys for instant reordering
        if [[ "$key" == "alt-up" || "$key" == "ctrl-up" || "$key" == "alt-down" || "$key" == "ctrl-down" ]]; then
            local move_dir="up"
            [[ "$key" == *"down" ]] && move_dir="down"
            if [[ "$sel_meta" == group:* ]]; then
                local g_to_move="${sel_meta#group:}"
                _move_group_order "$g_to_move" "$move_dir"
                target_meta="group:$g_to_move"
            elif [[ "$sel_meta" == mgr:* ]]; then
                local m_to_move="${sel_meta#mgr:}"
                local m_i
                for ((m_i=0; m_i<${#CUSTOM_NAMES[@]}; m_i++)); do
                    if [[ "${CUSTOM_NAMES[$m_i]}" == "$m_to_move" ]]; then
                        _move_manager_in_group "$m_i" "$move_dir"
                        target_meta="mgr:$m_to_move"
                        break
                    fi
                done
            fi
            continue
        fi

        # Handle group header action (toggle, move up/down/top, or set priority)
        if [[ "$sel_meta" == group:* ]]; then
            local grp_name="${sel_meta#group:}"
            local cur="${GROUP_ENABLED[$grp_name]:-true}"
            local cur_pri
            cur_pri=$(get_group_priority "$grp_name")
            local toggle_label="Disable Group"
            [[ "$cur" != "true" ]] && toggle_label="Enable Group"

            local grp_prev
            grp_prev=$(_format_group_order_preview "$grp_name")

            local grp_actions=(
                "$(e 🔄)$toggle_label (currently: $([[ "$cur" == "true" ]] && echo "Enabled" || echo "Disabled"))"
                "$(e 🥇)Promote Group to #1 (Run First)"
                "$(e ⬆️)Move Group Up (Run Earlier)"
                "$(e ⬇️)Move Group Down (Run Later)"
                "$(e 🔧)Auto-Renumber Managers in '$grp_name' (Clean 10, 20, 30...)"
                "$(e 🔢)Set Custom Group Priority Number... (currently: $cur_pri)"
                "$(e 🔙)Back"
            )
            local gact
            gact=$(export GRP_PREV="$grp_prev"; printf "%s\n" "${grp_actions[@]}" | fzf --height 14 --reverse \
                --header "--- Group: $grp_name ---" \
                --preview 'printf "%s\n" "$GRP_PREV"' --preview-window=right:55%:wrap)
            unset GRP_PREV
            target_meta="group:$grp_name"
            case "$gact" in
                *Toggle*|*Enable*|*Disable*)
                    if [[ "$cur" == "true" ]]; then
                        GROUP_ENABLED[$grp_name]="false"
                    else
                        GROUP_ENABLED[$grp_name]="true"
                    fi
                    save_config
                    ;;
                *Promote*Group*)
                    _move_group_order "$grp_name" "top"
                    ui_ok "Group '$grp_name' promoted to #1 execution priority."
                    ;;
                *Move*Group*Up*)
                    _move_group_order "$grp_name" "up"
                    ui_ok "Moved group '$grp_name' earlier in execution order."
                    ;;
                *Move*Group*Down*)
                    _move_group_order "$grp_name" "down"
                    ui_ok "Moved group '$grp_name' later in execution order."
                    ;;
                *Auto-Renumber*)
                    local g_inds=()
                    mapfile -t g_inds < <(_get_group_manager_indices "$grp_name")
                    _renumber_group_managers "$grp_name" "${g_inds[@]}"
                    load_custom_managers
                    ui_ok "Renumbered managers in '$grp_name' cleanly without conflicts."
                    ;;
                *Custom*Group*Priority*)
                    echo -n "Enter new execution priority for group '$grp_name' (integer, higher runs first, currently $cur_pri): "
                    read -r new_pri
                    new_pri=$(trim "$new_pri")
                    if [[ -z "$new_pri" ]]; then
                        : # Keep current priority
                    elif [[ "$new_pri" =~ ^-?[0-9]+$ ]]; then
                        set_group_priority "$grp_name" "$new_pri"
                        ui_ok "Group '$grp_name' priority set to $new_pri."
                    else
                        ui_warn "Invalid priority. Must be an integer."
                    fi
                    ;;
                *) ;;
            esac
            continue
        fi

        [[ "$sel_meta" == "sep" || "$choice" == ---* ]] && continue

        if [[ "$choice" == *Scan*System* || "$choice" == *Auto-Enroll* ]]; then
            ui_info "Probing system for installed catalog managers..."
            auto_enroll_catalog false
            echo -e "\nPress Enter to continue..."
            read -r
            continue
        fi

        if [[ "$choice" == *Browse*Official*Catalog* ]]; then
            browse_catalog_menu
            continue
        fi

        if [[ "$choice" == *Add* ]]; then
            ui_info "Add New Package Manager Wizard"
            echo -e "${C_DIM}Follow the guided steps below to configure your custom package manager.${C_RESET}"
            echo -e "${C_DIM}Press Enter on empty prompts to cancel at any time.${C_RESET}\n"

            # Step 1: Manager Name
            local name=""
            while true; do
                echo -e "${C_BOLD}Step 1: Manager Name${C_RESET}"
                echo "Enter a unique display name (e.g. 'Flatpak', 'Cargo', 'My Tools')."
                echo -n "Manager Name: "
                read -r name
                name=$(trim "$name")
                if [[ -z "$name" ]]; then
                    ui_info "Wizard cancelled."
                    break
                fi

                if [[ "$name" =~ [/\\:] ]]; then
                    ui_error "Manager name cannot contain slashes or colons. Choose another name."
                    continue
                fi

                local dup=false
                local j
                for ((j=0; j<${#CUSTOM_NAMES[@]}; j++)); do
                    if [[ "${CUSTOM_NAMES[$j],,}" == "${name,,}" ]]; then
                        dup=true
                        break
                    fi
                done
                if [[ "$dup" == true ]]; then
                    ui_error "Manager name '$name' already exists. Choose another name."
                    continue
                fi
                break
            done
            [[ -z "$name" ]] && continue

            # Step 2: Update Command (Mandatory)
            echo -e "\n${C_BOLD}Step 2: Update Command (Mandatory)${C_RESET}"
            echo "Enter the command Advance executes to update packages (e.g. 'sudo apt full-upgrade', 'flatpak update')."
            local update_cmd=""
            echo -n "Update Command: "
            read -r update_cmd
            update_cmd=$(trim "$update_cmd")
            if [[ -z "$update_cmd" ]]; then
                ui_info "Update command is required. Wizard cancelled."
                continue
            fi

            local auto_bin
            auto_bin=$(_infer_required_binary "$update_cmd")
            local requires_cmd="$auto_bin"
            local target_group=""
            local priority="0"
            local check_cmd="" check_exit_code="" check_filter=""
            local flags_auto_confirm="" flags_interactive="" auto_confirm=""
            local skip_wizard=false

            local wiz_modes=(
                "$(e 🧙)Guided Walkthrough            — Configure binary check, category, check updates, and flags step-by-step"
                "$(e ⚡)Quick Setup (Skip to Review)    — Use smart defaults & jump straight to Review & Save"
            )
            local w_choice
            w_choice=$(printf "%s\n" "${wiz_modes[@]}" | fzf --height 8 --reverse \
                --header "Select Setup Mode for '$name'" \
                --preview 'case "{}" in
                    *Guided*)
                        echo -e "Guided Walkthrough\n──────────────────\nStep-by-step interactive setup:\n• Step 3: Required binary check\n• Step 4: Category / priority group\n• Step 5: Check updates mode & command\n• Step 6: Confirmation handling & flags" ;;
                    *Quick*)
                        echo -e "Quick Setup with Smart Defaults\n────────────────────────────────\nSkips directly to the Review & Save screen using:\n• Inferred Binary: ${auto_bin:-(none)}\n• Category: standalone (runs alongside all other managers)\n• Check Updates: Always Run\n• Confirmation: Follow Global Settings\n\nYou can still customize or add advanced settings (probe, hold/unhold, flags) in Review & Save before saving." ;;
                esac' --preview-window=right:55%:wrap)

            [[ -z "$w_choice" ]] && { ui_info "Wizard cancelled."; continue; }

            if [[ "$w_choice" == *"Quick Setup"* ]]; then
                skip_wizard=true
            fi

            if [[ "$skip_wizard" == false ]]; then
                # Step 3: Smart Binary Check (REQUIRES_CMD)
                echo -e "\n${C_BOLD}Step 3: Smart Binary Check (REQUIRES_CMD)${C_RESET}"
                echo "Advance checks for this binary in PATH before running to verify the tool is installed."
                if [[ -n "$auto_bin" ]]; then
                    local path_status="not found in PATH"
                    if command -v "$auto_bin" >/dev/null 2>&1; then
                        path_status="found in PATH"
                    fi
                    echo -e "Inferred binary: ${C_GREEN}${auto_bin}${C_RESET} (${path_status})"
                    echo -n "Enter required binary [Enter for '$auto_bin', 'none' to clear, 'skip' to skip to Review]: "
                    read -r requires_cmd
                    requires_cmd=$(trim "$requires_cmd")
                    if [[ -z "$requires_cmd" ]]; then
                        requires_cmd="$auto_bin"
                    elif [[ "$requires_cmd" == "none" || "$requires_cmd" == "-" || "$requires_cmd" == "clear" ]]; then
                        requires_cmd=""
                    elif [[ "$requires_cmd" == "skip" || "$requires_cmd" == "s" ]]; then
                        requires_cmd="$auto_bin"
                        skip_wizard=true
                    fi
                else
                    echo -n "Enter required binary (command in PATH, leave empty for none, 'skip' to skip to Review): "
                    read -r requires_cmd
                    requires_cmd=$(trim "$requires_cmd")
                    if [[ "$requires_cmd" == "skip" || "$requires_cmd" == "s" ]]; then
                        requires_cmd=""
                        skip_wizard=true
                    fi
                fi
            fi

            if [[ "$skip_wizard" == false ]]; then
                # Step 4: Group & Category Selection
                local grp_opts=()
                for g in "${groups[@]}"; do
                    [[ -n "$g" ]] && grp_opts+=("$g")
                done
                grp_opts+=("(standalone — runs independently alongside all other managers)")
                grp_opts+=("(new group — create a new mutually-exclusive category)")
                grp_opts+=("$(e ⏭️)(skip — standalone & jump straight to Review & Save)")

                echo -e "\n${C_BOLD}Step 4: Group & Category Selection${C_RESET}"
                echo "Choose whether '$name' runs independently or belongs to a mutually-exclusive group."

                local grp_choice
                grp_choice=$(printf "%s\n" "${grp_opts[@]}" | fzf --height 14 --reverse \
                    --header "Select Group / Category for '$name'" \
                    --preview 'case "{}" in
                        *skip*)
                            echo -e "Skip to Review\n──────────────\nKeeps '$name' as standalone and skips remaining steps directly to Review & Save." ;;
                        "(standalone"*)
                            echo -e "Standalone Manager\n──────────────────\n• Runs independently alongside all other managers.\n• No mutual exclusion: Advance executes every enabled standalone manager during system update.\n• Recommended for standalone tools (e.g. Flatpak, Snap, Homebrew, pipx)." ;;
                        "(new group"*)
                            echo -e "Create New Category / Group\n───────────────────────────\n• Creates a new mutually-exclusive category.\n• Advance executes only the single highest-priority enabled manager in this group.\n• Use when you have multiple alternatives for the same role (e.g. pacman vs yay vs paru)." ;;
                        *)
                            echo -e "Existing Group: {}\n──────────────────\n• Belongs to the '\''{}'\'' mutually-exclusive category.\n• Advance executes only the single highest-priority manager in this group.\n• If this manager has higher priority than existing members, it will run instead of them." ;;
                    esac' --preview-window=right:55%:wrap)

                [[ -z "$grp_choice" ]] && { ui_info "Wizard cancelled."; continue; }

                if [[ "$grp_choice" == *skip* ]]; then
                    target_group=""
                    skip_wizard=true
                elif [[ "$grp_choice" == "(new group"* ]]; then
                    echo -n "Enter new group name (e.g. rust, system, python): "
                    read -r target_group
                    target_group=$(trim "$target_group")
                    [[ -z "$target_group" ]] && { ui_info "Wizard cancelled."; continue; }
                    target_group="${target_group//[\/\\\:]/}"
                    target_group=$(echo "$target_group" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
                    [[ -z "$target_group" ]] && { ui_info "Wizard cancelled."; continue; }
                elif [[ "$grp_choice" != "(standalone"* ]]; then
                    target_group="$grp_choice"
                fi
            fi

            if [[ "$skip_wizard" == false ]]; then
                # Step 5: Check Updates Mode (Optional)
                echo -e "\n${C_BOLD}Step 5: Check Updates Mode${C_RESET}"
                echo "Choose how Advance detects whether '$name' has updates available before running."
                if ! _select_check_mode "" "" ""; then
                    ui_info "Wizard cancelled."
                    continue
                fi
                check_cmd="$SEL_CHECK_CMD"
                check_exit_code="$SEL_CHECK_EXIT_CODE"
                check_filter="$SEL_CHECK_FILTER"

                # Step 6: Confirmation Mode Preset
                echo -e "\n${C_BOLD}Step 6: Confirmation Mode Preset${C_RESET}"
                echo "Choose how '$name' handles confirmation prompts during automatic vs manual runs."
                if ! _select_confirm_mode "" ""; then
                    ui_info "Wizard cancelled."
                    continue
                fi
                flags_auto_confirm="$SEL_AUTO_CONFIRM"
                flags_interactive="$SEL_INTERACTIVE"
                auto_confirm="$SEL_AUTO_CONFIRM_MODE"
            fi

            # Review & Save with Live Preview
            local emoji="📦"
            local priority
            priority=$(_get_next_free_group_priority "$target_group" "highest")
            local flags_override=""
            local extra_flags=""
            local color_flag=""
            local exclude_flag=""
            local exclude_join=","
            local exclude_hold_cmd=""
            local exclude_unhold_cmd=""
            local check_timeout_fb=""
            local post_update_msg_id=""
            local post_update_msg=""
            local check_dep_bin=""
            local check_dep_cmd=""
            local probe_cmd=""

            while true; do
                local cf_summary="${flags_auto_confirm:-(none)}"
                [[ "$flags_auto_confirm" == "none" ]] && cf_summary="none (already non-interactive)"
                [[ -n "$flags_interactive" ]] && cf_summary="interactive ($flags_interactive)"
                [[ "$auto_confirm" == "false" && -z "$flags_interactive" ]] && cf_summary="manual prompt (always interactive)"

                local chk_summary="${check_cmd:-(Always Runs)}"
                [[ -n "$check_cmd" && -n "$check_exit_code" ]] && chk_summary="$check_cmd [exit:$check_exit_code]"

                local rev_opts=(
                    "$(e ✅)Save & Enable Manager"
                    "$(e 🔍)Required Binary:          ${requires_cmd:-(none)}"
                    "$(e 🚀)Update Command:           $update_cmd"
                    "$(e 🔎)Check Updates & Survey:   $chk_summary"
                    "$(e 📁)Group / Category:         ${target_group:-(standalone)}"
                    "$(e 🤖)Confirmation Mode:        $cf_summary"
                    "$(e 🎨)Emoji Icon:               $emoji"
                    "$(e 🔢)Group Priority:           $priority"
                    "$(e 🚩)Persistent Flags:         ${extra_flags:-(none)}"
                    "$(e 🌈)Color Flag:               ${color_flag:-(none)}"
                    "$(e 💥)File Conflict Override:   ${flags_override:-(none)}"
                    "$(e 🚫)Package Exclude Flag:     ${exclude_flag:-(none)} [join: ${exclude_join:-,}]"
                    "$(e ⚙️)Advanced Engine Settings... (Probe, Hold/Unhold, Post-Msg)"
                    "---"
                    "$(e ❌)Cancel"
                )

                local preview_text
                preview_text=$(cat <<PREV_EOF
=== $(e "$emoji") $name ===

  Status:        Enabled
  Required Cmd:  ${requires_cmd:-(none)}
  Probe Cmd:     ${probe_cmd:-(none)}
  Group:         ${target_group:-(standalone)}
  Priority:      $priority

── Commands & Survey ──
  Update Cmd:    $update_cmd
  Check Cmd:     ${check_cmd:-(always runs)}
  Exit Code:     ${check_exit_code:-(standard)}
  Noise Filter:  ${check_filter:-(none)}
  Fallback Cmd:  ${check_timeout_fb:-(none)}
  Dep Binary:    ${check_dep_bin:-(none)}

── Confirmation & Flags ──
  Confirm Mode:  $cf_summary
  Auto-Confirm:  ${flags_auto_confirm:-(none)}
  Interactive:   ${flags_interactive:-(none)}
  Override Flag: ${flags_override:-(none)}
  Color Flag:    ${color_flag:-(none)}
  Extra Flags:   ${extra_flags:-(none)}

── Exclusions & Engine ──
  Exclude Flag:  ${exclude_flag:-(none)}
  Join Mode:     ${exclude_join:-,}
  Hold Cmd:      ${exclude_hold_cmd:-(none)}
  Unhold Cmd:    ${exclude_unhold_cmd:-(none)}
  Post-Msg:      ${post_update_msg:-(none)}
PREV_EOF
)
                local rev_choice
                rev_choice=$(export MGR_PREV="$preview_text"; printf "%s\n" "${rev_opts[@]}" | fzf --height 20 --reverse \
                    --header "=== Review & Save Manager: $name ===" \
                    --preview 'printf "%s\n" "$MGR_PREV"' --preview-window=right:55%:wrap)

                [[ -z "$rev_choice" || "$rev_choice" == *Cancel* ]] && { unset MGR_PREV; ui_info "Wizard cancelled."; break; }

                if [[ "$rev_choice" == *"Save & Enable"* ]]; then
                    local target_dir="$CUSTOM_DIR"
                    [[ -n "$target_group" ]] && target_dir="$CUSTOM_DIR/$target_group"
                    local conf_file="$target_dir/${name// /_}.conf"

                    save_custom_manager "$name" "$emoji" "$check_cmd" "$update_cmd" \
                        "$flags_auto_confirm" "$flags_interactive" "$flags_override" "true" "$conf_file" \
                        "$requires_cmd" "$priority" "$extra_flags" "$auto_confirm" "$color_flag" \
                        "$exclude_flag" "$exclude_join" "$exclude_hold_cmd" "$exclude_unhold_cmd" \
                        "$check_exit_code" "$check_filter" "$check_timeout_fb" \
                        "$post_update_msg_id" "$post_update_msg" \
                        "$check_dep_bin" "$check_dep_cmd" "$probe_cmd"

                    load_custom_managers
                    if [[ -n "$target_group" ]]; then
                        local new_k
                        for ((new_k=0; new_k<${#CUSTOM_FILES[@]}; new_k++)); do
                            if [[ "${CUSTOM_FILES[$new_k]}" == "$conf_file" ]]; then
                                _set_manager_priority_conflict_free "$new_k" "$priority"
                                break
                            fi
                        done
                    fi

                    ui_ok "Package manager '$name' added and enabled successfully!"
                    unset MGR_PREV
                    target_meta="mgr:$name"
                    break
                elif [[ "$rev_choice" == *"Advanced Engine Settings"* ]]; then
                    _edit_advanced_settings_menu "wizard"
                elif [[ "$rev_choice" == *"Required Binary"* ]]; then
                    echo -n "Enter required binary (command in PATH, 'none' to clear) [current: ${requires_cmd:-(none)}]: "
                    read -r r_val
                    r_val=$(trim "$r_val")
                    [[ "$r_val" == "none" || "$r_val" == "-" || "$r_val" == "clear" ]] && requires_cmd=""
                    [[ -n "$r_val" && "$r_val" != "none" && "$r_val" != "-" && "$r_val" != "clear" ]] && requires_cmd="$r_val"
                elif [[ "$rev_choice" == *"Update Command"* ]]; then
                    echo -n "Enter update command [current: $update_cmd]: "
                    read -r r_val
                    r_val=$(trim "$r_val")
                    [[ -n "$r_val" ]] && update_cmd="$r_val"
                elif [[ "$rev_choice" == *"Group / Category"* ]]; then
                    local mv_groups
                    mapfile -t mv_groups < <(get_all_groups)
                    local mv_opts=()
                    for g in "${mv_groups[@]}"; do
                        [[ -n "$g" ]] && mv_opts+=("$g")
                    done
                    mv_opts+=("(standalone — runs independently alongside all other managers)")
                    mv_opts+=("(new group — create a new mutually-exclusive category)")
                    local g_pick
                    g_pick=$(printf "%s\n" "${mv_opts[@]}" | fzf --height 14 --reverse \
                        --header "Select group for '$name'" \
                        --preview 'case "{}" in
                            "(standalone"*)
                                echo -e "Standalone Manager\n──────────────────\n• Runs independently alongside all other managers.\n• No mutual exclusion: Advance executes every enabled standalone manager during system update." ;;
                            "(new group"*)
                                echo -e "Create New Category / Group\n───────────────────────────\n• Creates a new mutually-exclusive category.\n• Advance executes only the single highest-priority enabled manager in this group." ;;
                            *)
                                echo -e "Existing Group: {}\n──────────────────\n• Belongs to the '\''{}'\'' mutually-exclusive category.\n• Advance executes only the single highest-priority manager in this group." ;;
                        esac' --preview-window=right:55%:wrap)
                    if [[ "$g_pick" == "(new group"* ]]; then
                        echo -n "Enter new group name: "
                        read -r new_g
                        new_g=$(trim "$new_g")
                        if [[ -n "$new_g" ]]; then
                            new_g="${new_g//[\/\\\:]/}"
                            new_g=$(echo "$new_g" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
                            if [[ -n "$new_g" ]]; then
                                target_group="$new_g"
                                priority=$(_get_next_free_group_priority "$target_group" "highest")
                            fi
                        fi
                    elif [[ "$g_pick" == "(standalone"* ]]; then
                        target_group=""
                        priority="0"
                    elif [[ -n "$g_pick" ]]; then
                        target_group="$g_pick"
                        priority=$(_get_next_free_group_priority "$target_group" "highest")
                    fi
                elif [[ "$rev_choice" == *"Confirmation Mode"* ]]; then
                    if _select_confirm_mode "$flags_auto_confirm" "$flags_interactive"; then
                        flags_auto_confirm="$SEL_AUTO_CONFIRM"
                        flags_interactive="$SEL_INTERACTIVE"
                        auto_confirm="$SEL_AUTO_CONFIRM_MODE"
                    fi
                elif [[ "$rev_choice" == *"Emoji Icon"* ]]; then
                    echo -n "Enter emoji icon [current: $emoji]: "
                    read -r r_val
                    r_val=$(trim "$r_val")
                    [[ -n "$r_val" ]] && emoji="$r_val"
                elif [[ "$rev_choice" == *"Check Updates"* ]]; then
                    _edit_check_settings_menu "wizard"
                elif [[ "$rev_choice" == *"Group Priority"* ]]; then
                    if [[ -n "$target_group" ]]; then
                        local p_high p_low
                        p_high=$(_get_next_free_group_priority "$target_group" "highest")
                        p_low=$(_get_next_free_group_priority "$target_group" "lowest")
                        local p_opts=(
                            "$(e 🥇)Highest Priority (P:$p_high) — Run as ★ Active Winner in '$target_group'"
                            "$(e ⬇️)Fallback Priority (P:$p_low) — Run as ↳ Standby if others are missing"
                            "$(e 🔢)Custom Priority Number...    — Enter integer manually"
                        )
                        local g_prev
                        g_prev=$(_format_group_order_preview "$target_group")
                        local p_pick
                        p_pick=$(export GRP_PREV="$g_prev"; printf "%s\n" "${p_opts[@]}" | fzf --height 12 --reverse \
                            --header "--- Select Priority in Group '$target_group' ---" \
                            --preview 'printf "%s\n" "$GRP_PREV"' --preview-window=right:55%:wrap)
                        unset GRP_PREV
                        if [[ "$p_pick" == *"Highest Priority"* ]]; then
                            priority="$p_high"
                        elif [[ "$p_pick" == *"Fallback Priority"* ]]; then
                            priority="$p_low"
                        elif [[ "$p_pick" == *"Custom Priority"* ]]; then
                            echo -n "Enter priority within group (integer, higher = preferred) [current: $priority]: "
                            read -r r_val
                            r_val=$(trim "$r_val")
                            [[ "$r_val" =~ ^-?[0-9]+$ ]] && priority="$r_val"
                        fi
                    else
                        echo -n "Enter priority (integer, higher = preferred) [current: $priority]: "
                        read -r r_val
                        r_val=$(trim "$r_val")
                        if [[ -z "$r_val" ]]; then
                            : # Keep current priority
                        elif [[ "$r_val" =~ ^-?[0-9]+$ ]]; then
                            priority="$r_val"
                        else
                            ui_warn "Priority must be an integer."
                        fi
                    fi
                elif [[ "$rev_choice" == *"Persistent Flags"* ]]; then
                    echo -n "Enter persistent flags (e.g. --needed, 'none' to clear) [current: ${extra_flags:-(none)}]: "
                    read -r r_val
                    r_val=$(trim "$r_val")
                    [[ "$r_val" == "none" || "$r_val" == "-" || "$r_val" == "clear" ]] && extra_flags=""
                    [[ -n "$r_val" && "$r_val" != "none" && "$r_val" != "-" && "$r_val" != "clear" ]] && extra_flags="$r_val"
                elif [[ "$rev_choice" == *"Color Flag"* ]]; then
                    echo -n "Enter color output flag (e.g. --color=always, 'none' to clear) [current: ${color_flag:-(none)}]: "
                    read -r r_val
                    r_val=$(trim "$r_val")
                    [[ "$r_val" == "none" || "$r_val" == "-" || "$r_val" == "clear" ]] && color_flag=""
                    [[ -n "$r_val" && "$r_val" != "none" && "$r_val" != "-" && "$r_val" != "clear" ]] && color_flag="$r_val"
                elif [[ "$rev_choice" == *"File Conflict Override"* ]]; then
                    echo -n "Enter file conflict override flag (e.g. --overwrite '*', 'none' to clear) [current: ${flags_override:-(none)}]: "
                    read -r r_val
                    r_val=$(trim "$r_val")
                    [[ "$r_val" == "none" || "$r_val" == "-" || "$r_val" == "clear" ]] && flags_override=""
                    [[ -n "$r_val" && "$r_val" != "none" && "$r_val" != "-" && "$r_val" != "clear" ]] && flags_override="$r_val"
                elif [[ "$rev_choice" == *"Package Exclude Flag"* ]]; then
                    echo -n "Enter package exclude flag (e.g. --ignore, 'none' to clear, press Enter to keep) [current: ${exclude_flag:-(none)}]: "
                    read -r r_val
                    r_val=$(trim "$r_val")
                    if [[ "$r_val" == "none" || "$r_val" == "-" || "$r_val" == "clear" ]]; then
                        exclude_flag=""
                    else
                        [[ -n "$r_val" ]] && exclude_flag="$r_val"
                        if [[ -n "$exclude_flag" ]]; then
                            echo -n "Enter join mode (comma, space, or repeat) [current: ${exclude_join:-,}]: "
                            read -r r_join
                            r_join=$(trim "$r_join")
                            case "$r_join" in
                                repeat|--repeat) exclude_join="repeat" ;;
                                space|" ") exclude_join="space" ;;
                                comma|",") exclude_join="," ;;
                                *) [[ -n "$r_join" ]] && exclude_join="$r_join" ;;
                            esac
                        fi
                    fi
                fi
            done
            continue
        fi

        # Parse selected manager using metadata or pure-bash array lookup
        local found=-1
        local i
        if [[ "$sel_meta" == mgr:* ]]; then
            local target_mname="${sel_meta#mgr:}"
            for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
                if [[ "${CUSTOM_NAMES[$i]}" == "$target_mname" ]]; then
                    found=$i
                    break
                fi
            done
        fi
        if [[ $found -eq -1 ]]; then
            local raw_choice="${choice#"$(e 📦)"}"
            raw_choice="${raw_choice#"📦 "}"
            raw_choice="${raw_choice#"📦"}"
            for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
                local mname="${CUSTOM_NAMES[$i]}"
                if [[ "$raw_choice" == *"$mname ["* || "$raw_choice" == *"$mname ("* ]]; then
                    found=$i
                    break
                fi
            done
        fi
        [[ $found -eq -1 ]] && { ui_error "Manager not found."; continue; }

        local conf_file="${CUSTOM_FILES[$found]}"
        local probe_cmd=""
        if [[ -f "$conf_file" ]]; then
            probe_cmd=$(grep '^PROBE_ACTIVE_CMD=' "$conf_file" 2>/dev/null | head -1 | cut -d'=' -f2-)
        fi

        while true; do
            local name="${CUSTOM_NAMES[$found]}"
            target_meta="mgr:$name"
            local emoji="${CUSTOM_EMOJIS[$found]}"
            [[ -z "$emoji" ]] && emoji="📦"
            local check_cmd="${CUSTOM_CHECKS[$found]}"
            local update_cmd="${CUSTOM_UPDATES[$found]}"
            local flags="${CUSTOM_FLAGS[$found]}"
            local auto_confirm="${CUSTOM_AUTO_CONFIRMS[$found]}"
            local flags_auto_confirm="${CUSTOM_FLAGS_AUTO_CONFIRMS[$found]}"
            local flags_interactive="${CUSTOM_FLAGS_INTERACTIVES[$found]}"
            local flags_override="${CUSTOM_FLAGS_OVERRIDES[$found]}"
            local color_flag="${CUSTOM_COLOR_FLAGS[$found]}"
            local exclude_flag="${CUSTOM_EXCLUDE_FLAGS[$found]}"
            local exclude_join="${CUSTOM_EXCLUDE_JOINS[$found]:-,}"
            local exclude_hold_cmd="${CUSTOM_EXCLUDE_HOLD_CMDS[$found]}"
            local exclude_unhold_cmd="${CUSTOM_EXCLUDE_UNHOLD_CMDS[$found]}"
            local check_exit_code="${CUSTOM_CHECK_UPDATES_EXIT_CODES[$found]}"
            local check_filter="${CUSTOM_CHECK_FILTER_PATTERNS[$found]}"
            local check_timeout_fb="${CUSTOM_CHECK_TIMEOUT_FALLBACKS[$found]}"
            local post_update_msg_id="${CUSTOM_POST_MSG_IDS[$found]}"
            local post_update_msg="${CUSTOM_POST_MSGS[$found]}"
            local check_dep_bin="${CUSTOM_CHECK_DEP_BINS[$found]}"
            local check_dep_cmd="${CUSTOM_CHECK_DEP_INSTALLS[$found]}"
            local enabled="${CUSTOM_ENABLEDS[$found]}"
            local conf_file="${CUSTOM_FILES[$found]}"
            local requires_cmd="${CUSTOM_REQUIRES_CMDS[$found]}"
            local priority="${CUSTOM_PRIORITIES[$found]}"
            local group="${CUSTOM_GROUPS[$found]}"

            local status_str="Enabled"
            [[ "$enabled" != "true" ]] && status_str="Disabled"

            local ac_display=""
            local global_ac_str="ON"
            [[ "$AUTO_CONFIRM" == false ]] && global_ac_str="OFF"
            if [[ "$auto_confirm" == "true" ]]; then
                ac_display="ON unless forced"
            elif [[ "$auto_confirm" == "false" ]]; then
                ac_display="OFF unless forced"
            else
                ac_display="Follow global ($global_ac_str)"
            fi

            _save_current_mgr() {
                save_custom_manager "$name" "$emoji" "$check_cmd" "$update_cmd" \
                    "$flags_auto_confirm" "$flags_interactive" "$flags_override" \
                    "$enabled" "$conf_file" "$requires_cmd" "$priority" \
                    "$flags" "$auto_confirm" "$color_flag" \
                    "$exclude_flag" "$exclude_join" "$exclude_hold_cmd" "$exclude_unhold_cmd" \
                    "$check_exit_code" "$check_filter" "$check_timeout_fb" \
                    "$post_update_msg_id" "$post_update_msg" \
                    "$check_dep_bin" "$check_dep_cmd" \
                    "$probe_cmd"
            }

            _refresh_found() {
                load_custom_managers
                local k
                for ((k=0; k<${#CUSTOM_FILES[@]}; k++)); do
                    if [[ "${CUSTOM_FILES[$k]}" == "$conf_file" ]]; then
                        found=$k
                        break
                    fi
                done
            }

            local sub_opt=(
                "$(e 🔄)Toggle Status (Currently: $status_str)"
                "$(e 🤖)Auto-Confirm (Currently: $ac_display)"
                "$(e 🔢)Set Priority / Order (Currently: P:$priority)"
                "$(e 📁)Move to Group (Currently: ${group:-(standalone)})"
                "$(e 🎨)Set Emoji (Currently: $emoji)"
                "$(e 🔍)Set Required Binary (Currently: ${requires_cmd:-(none)})"
                "$(e 🔎)Configure Check Updates (Currently: ${check_cmd:-(Always Runs)})"
                "$(e 🚀)Set Update Command"
                "$(e 🚩)Set Flags & Extras"
                "$(e ⚙️)Advanced Engine Settings (Daemon Probe, Hold/Unhold, Post-Msg)"
                "$(e 🏷️)Rename Manager"
                "$(e 🗑️)Delete Manager"
                "---"
                "$(e 🔙)Back to Manager List"
            )
            local cf_display="${flags_auto_confirm:-(none)}"
            [[ "$flags_auto_confirm" == "none" ]] && cf_display="none (non-interactive)"
            local sub_prev_text
            sub_prev_text=$(cat <<SUB_PREV_EOF
=== $(e "$emoji") $name ===

  Status:        $status_str
  Requires:      ${requires_cmd:-(none)}
  Probe Cmd:     ${probe_cmd:-(none)}
  Priority:      $priority
  Group:         ${group:-(standalone)}

── Commands & Survey ──
  Check:         ${check_cmd:-(always runs)}
  Exit Code:     ${check_exit_code:-(standard)}
  Noise Filter:  ${check_filter:-(none)}
  Fallback Cmd:  ${check_timeout_fb:-(none)}
  Update:        $update_cmd

── Flags ──
  Persistent:    ${flags:-(none)}
  Auto-Confirm:  $ac_display
  Confirm Flag:  $cf_display
  Interactive:   ${flags_interactive:-(none)}
  Override:      ${flags_override:-(none)}
  Color:         ${color_flag:-(none)}

── Exclusions & Engine ──
  Flag:          ${exclude_flag:-(none)}
  Join:          ${exclude_join:-(none)}
  Hold Cmd:      ${exclude_hold_cmd:-(none)}
  Unhold Cmd:    ${exclude_unhold_cmd:-(none)}
  Post-Msg:      ${post_update_msg:-(none)}
SUB_PREV_EOF
)
            local sub_choice
            sub_choice=$(export MGR_SUB_PREV="$sub_prev_text"; printf "%s\n" "${sub_opt[@]}" | fzf --height 22 --reverse \
                --header "--- Manager: $name ---" \
                --preview 'printf "%s\n" "$MGR_SUB_PREV"' --preview-window=right:55%:wrap)
            unset MGR_SUB_PREV

            [[ -z "$sub_choice" || "$sub_choice" == *Back* ]] && break

            if [[ "$sub_choice" == *"Toggle Status"* ]]; then
                if [[ "$enabled" == "true" ]]; then enabled="false"; else enabled="true"; fi
                _save_current_mgr
                load_custom_managers

            elif [[ "$sub_choice" == *"Auto-Confirm"* ]]; then
                local ac_opts=(
                    "$(e 🌐)Follow global     — Inherit global setting (currently: $global_ac_str)"
                    "$(e 🟢)ON unless forced  — Always auto-confirm with FLAGS_AUTO_CONFIRM"
                    "$(e 🔴)OFF unless forced — Always prompt for manual confirmation"
                )
                local ac_pick
                ac_pick=$(printf "%s\n" "${ac_opts[@]}" | fzf --height 10 --reverse \
                    --header "--- Select Auto-Confirm Mode for $name ---")
                if [[ "$ac_pick" == *"Follow global"* ]]; then
                    auto_confirm=""
                    _save_current_mgr
                    load_custom_managers
                    ui_ok "Auto-confirm mode set to: Follow global."
                elif [[ "$ac_pick" == *"ON unless forced"* ]]; then
                    auto_confirm="true"
                    _save_current_mgr
                    load_custom_managers
                    ui_ok "Auto-confirm mode set to: ON unless forced."
                elif [[ "$ac_pick" == *"OFF unless forced"* ]]; then
                    auto_confirm="false"
                    _save_current_mgr
                    load_custom_managers
                    ui_ok "Auto-confirm mode set to: OFF unless forced."
                fi

            elif [[ "$sub_choice" == *"Set Priority"* ]]; then
                if [[ -n "$group" ]]; then
                    local grp_prev_p
                    grp_prev_p=$(_format_group_order_preview "$group")
                    local pri_actions=(
                        "$(e 🥇)Promote to Active Winner (Top of '$group')"
                        "$(e ⬆️)Move Up One Position (Higher Priority)"
                        "$(e ⬇️)Move Down One Position (Lower Priority)"
                        "$(e ⏬)Demote to Last Fallback (Bottom of '$group')"
                        "$(e 🔢)Enter Custom Priority Number... (auto-resolves conflicts)"
                        "$(e 🔙)Back"
                    )
                    local p_act
                    p_act=$(export GRP_PREV="$grp_prev_p"; printf "%s\n" "${pri_actions[@]}" | fzf --height 14 --reverse \
                        --header "--- Priority & Execution Order for $name (Group: $group) ---" \
                        --preview 'printf "%s\n" "$GRP_PREV"' --preview-window=right:55%:wrap)
                    unset GRP_PREV

                    case "$p_act" in
                        *Promote*)
                            _move_manager_in_group "$found" "top"
                            _refresh_found
                            priority="${CUSTOM_PRIORITIES[$found]}"
                            ui_ok "Promoted '$name' to top of group '$group' (P:$priority)."
                            ;;
                        *Move*Up*)
                            _move_manager_in_group "$found" "up"
                            _refresh_found
                            priority="${CUSTOM_PRIORITIES[$found]}"
                            ui_ok "Moved '$name' up in group '$group' (P:$priority)."
                            ;;
                        *Move*Down*)
                            _move_manager_in_group "$found" "down"
                            _refresh_found
                            priority="${CUSTOM_PRIORITIES[$found]}"
                            ui_ok "Moved '$name' down in group '$group' (P:$priority)."
                            ;;
                        *Demote*)
                            _move_manager_in_group "$found" "bottom"
                            _refresh_found
                            priority="${CUSTOM_PRIORITIES[$found]}"
                            ui_ok "Moved '$name' to bottom of group '$group' (P:$priority)."
                            ;;
                        *Custom*Priority*)
                            echo -n "Enter priority within group '$group' (integer, higher = preferred, current: $priority): "
                            read -r r_pri
                            r_pri=$(trim "$r_pri")
                            if [[ -z "$r_pri" ]]; then
                                : # Keep current priority
                            elif [[ "$r_pri" =~ ^-?[0-9]+$ ]]; then
                                _set_manager_priority_conflict_free "$found" "$r_pri"
                                _refresh_found
                                priority="${CUSTOM_PRIORITIES[$found]}"
                                ui_ok "Priority updated to $priority (group order kept conflict-free)."
                            else
                                ui_error "Invalid priority number."
                            fi
                            ;;
                        *) ;;
                    esac
                else
                    echo -n "Enter priority (integer, current: $priority): "
                    read -r r_pri
                    r_pri=$(trim "$r_pri")
                    if [[ -z "$r_pri" ]]; then
                        : # Keep current priority
                    elif [[ "$r_pri" =~ ^-?[0-9]+$ ]]; then
                        priority="$r_pri"
                        _save_current_mgr
                        load_custom_managers
                        ui_ok "Priority updated to $priority."
                    else
                        ui_error "Invalid priority number."
                    fi
                fi

            elif [[ "$sub_choice" == *"Set Emoji"* ]]; then
                echo -n "Enter emoji icon (current: $emoji): "
                read -r r_emoji
                r_emoji=$(trim "$r_emoji")
                if [[ -n "$r_emoji" ]]; then
                    emoji="$r_emoji"
                    _save_current_mgr
                    load_custom_managers
                    ui_ok "Emoji updated."
                fi

            elif [[ "$sub_choice" == *"Set Required Binary"* ]]; then
                echo "Enter binary name that must exist in PATH ('none' or 'clear' to remove, press Enter to keep):"
                echo -n "Required Binary [current: ${requires_cmd:-(none)}]: "
                read -r r_req
                r_req=$(trim "$r_req")
                if [[ "$r_req" == "none" || "$r_req" == "-" || "$r_req" == "clear" ]]; then
                    requires_cmd=""
                    _save_current_mgr
                    _refresh_found
                    ui_ok "Required binary check cleared."
                elif [[ -n "$r_req" ]]; then
                    requires_cmd="$r_req"
                    _save_current_mgr
                    _refresh_found
                    ui_ok "Required binary check updated to: $requires_cmd."
                fi

            elif [[ "$sub_choice" == *"Configure Check Updates"* || "$sub_choice" == *"Set Check Command"* ]]; then
                _edit_check_settings_menu "live"

            elif [[ "$sub_choice" == *"Set Update Command"* ]]; then
                echo "Enter command to apply package updates (mandatory):"
                echo -n "Update Command (current: $update_cmd): "
                read -r r_update
                r_update=$(trim "$r_update")
                if [[ -n "$r_update" ]]; then
                    update_cmd="$r_update"
                    _save_current_mgr
                    load_custom_managers
                    ui_ok "Update command updated."
                else
                    ui_error "Update command cannot be empty."
                fi

            elif [[ "$sub_choice" == *"Set Flags"* ]]; then
                while true; do
                    local cf_disp="${flags_auto_confirm:-(none)}"
                    [[ "$flags_auto_confirm" == "none" ]] && cf_disp="none (non-interactive)"
                    local int_disp="${flags_interactive:-(none)}"
                    local ov_disp="${flags_override:-(none)}"
                    local fl_disp="${flags:-(none)}"
                    local col_disp="${color_flag:-(none)}"
                    local exc_disp="${exclude_flag:-(none)} [join: ${exclude_join:-,}]"

                    local flag_menu=(
                        "$(e 🤖)Auto-Confirm Flag / Preset    (Currently: $cf_disp)"
                        "$(e 💬)Manual Interactive Flag      (Currently: $int_disp)"
                        "$(e 💥)File Conflict Override Flag  (Currently: $ov_disp)"
                        "$(e 🚩)Persistent Extra Flags       (Currently: $fl_disp)"
                        "$(e 🌈)Color Output Flag            (Currently: $col_disp)"
                        "$(e 🚫)Package Exclude Flag & Join  (Currently: $exc_disp)"
                        "---"
                        "$(e 🔙)Back to Manager Menu"
                    )

                    local f_choice
                    f_choice=$(printf "%s\n" "${flag_menu[@]}" | fzf --height 16 --reverse \
                        --header "--- Flags & Extras for $name ---" \
                        --preview 'case "{}" in
                            *Auto-Confirm*)
                                echo -e "Auto-Confirm Flag / Preset\n──────────────────────────\nFlag passed during automatic/unattended runs (e.g. -y, --noconfirm, none, or yes |).\nMutually exclusive with Manual Interactive Flag." ;;
                            *Manual*Interactive*)
                                echo -e "Manual Interactive Flag\n───────────────────────\nFlag passed during manual runs when interactive confirmation is requested (e.g. --interactive).\nMutually exclusive with Auto-Confirm Flag." ;;
                            *Conflict*Override*)
                                echo -e "File Conflict Override Flag\n───────────────────────────\nFlag used during automatic retry when a file conflict is detected (e.g. --overwrite \"*\", --force-overwrite)." ;;
                            *Persistent*Extra*)
                                echo -e "Persistent Extra Flags\n──────────────────────\nFlags always passed to the update command on every run (e.g. --needed --devel)." ;;
                            *Color*Output*)
                                echo -e "Color Output Flag\n─────────────────\nFlag to force colored output when Advance color output is enabled (e.g. --color=always)." ;;
                            *Package*Exclude*)
                                echo -e "Package Exclude Flag & Join\n───────────────────────────\nFlag to exclude packages held from updates (e.g. --ignore, --exclude=).\nJoin mode specifies how multiple packages are joined (comma, space, or repeat)." ;;
                            *)
                                echo "Select a flag to edit." ;;
                        esac' --preview-window=right:50%:wrap)

                    [[ -z "$f_choice" || "$f_choice" == *Back* ]] && break

                    if [[ "$f_choice" == *"Auto-Confirm"* ]]; then
                        if _select_confirm_mode "$flags_auto_confirm" "$flags_interactive"; then
                            flags_auto_confirm="$SEL_AUTO_CONFIRM"
                            flags_interactive="$SEL_INTERACTIVE"
                            auto_confirm="$SEL_AUTO_CONFIRM_MODE"
                            _save_current_mgr
                            _refresh_found
                            ui_ok "Auto-confirm flag updated."
                        fi
                    elif [[ "$f_choice" == *"Manual Interactive"* ]]; then
                        echo "Enter manual interactive flag (e.g. --interactive, 'clear' to remove, press Enter to keep):"
                        echo -n "Interactive Flag [current: ${flags_interactive:-(none)}]: "
                        read -r r_int
                        r_int=$(trim "$r_int")
                        if [[ "$r_int" == "clear" || "$r_int" == "none" || "$r_int" == "-" ]]; then
                            flags_interactive=""
                            auto_confirm=""
                            _save_current_mgr
                            _refresh_found
                            ui_ok "Manual interactive flag cleared."
                        elif [[ -n "$r_int" ]]; then
                            flags_interactive="$r_int"
                            flags_auto_confirm=""  # Mutual exclusivity!
                            auto_confirm="false"
                            _save_current_mgr
                            _refresh_found
                            ui_ok "Manual interactive flag set (auto-confirm flag cleared)."
                        fi
                    elif [[ "$f_choice" == *"Conflict Override"* ]]; then
                        echo "Enter file conflict override flag (e.g. --overwrite '*', 'clear' to remove, press Enter to keep):"
                        echo -n "Override Flag [current: ${flags_override:-(none)}]: "
                        read -r r_over
                        r_over=$(trim "$r_over")
                        if [[ "$r_over" == "clear" || "$r_over" == "none" || "$r_over" == "-" ]]; then
                            flags_override=""
                            _save_current_mgr
                            _refresh_found
                            ui_ok "Override flag cleared."
                        elif [[ -n "$r_over" ]]; then
                            flags_override="$r_over"
                            _save_current_mgr
                            _refresh_found
                            ui_ok "File conflict override flag updated."
                        fi
                    elif [[ "$f_choice" == *"Persistent Extra"* ]]; then
                        echo "Enter persistent extra flags (e.g. --needed --devel, 'clear' to remove, press Enter to keep):"
                        echo -n "Persistent Flags [current: ${flags:-(none)}]: "
                        read -r r_flags
                        r_flags=$(trim "$r_flags")
                        if [[ "$r_flags" == "clear" || "$r_flags" == "none" || "$r_flags" == "-" ]]; then
                            flags=""
                            _save_current_mgr
                            _refresh_found
                            ui_ok "Persistent flags cleared."
                        elif [[ -n "$r_flags" ]]; then
                            flags="$r_flags"
                            _save_current_mgr
                            _refresh_found
                            ui_ok "Persistent flags updated."
                        fi
                    elif [[ "$f_choice" == *"Color Output"* ]]; then
                        echo "Enter color output flag (e.g. --color=always, 'clear' to remove, press Enter to keep):"
                        echo -n "Color Flag [current: ${color_flag:-(none)}]: "
                        read -r r_color
                        r_color=$(trim "$r_color")
                        if [[ "$r_color" == "clear" || "$r_color" == "none" || "$r_color" == "-" ]]; then
                            color_flag=""
                            _save_current_mgr
                            _refresh_found
                            ui_ok "Color flag cleared."
                        elif [[ -n "$r_color" ]]; then
                            color_flag="$r_color"
                            _save_current_mgr
                            _refresh_found
                            ui_ok "Color output flag updated."
                        fi
                    elif [[ "$f_choice" == *"Package Exclude"* ]]; then
                        echo "Enter package exclude flag (e.g. --ignore, --exclude=, 'clear' to remove, press Enter to keep):"
                        echo -n "Exclude Flag [current: ${exclude_flag:-(none)}]: "
                        read -r r_excl
                        r_excl=$(trim "$r_excl")
                        if [[ "$r_excl" == "clear" || "$r_excl" == "none" || "$r_excl" == "-" ]]; then
                            exclude_flag=""
                            _save_current_mgr
                            _refresh_found
                            ui_ok "Package exclude flag cleared."
                        elif [[ -z "$r_excl" && -z "$exclude_flag" ]]; then
                            : # Nothing changed, keep empty
                        else
                            [[ -n "$r_excl" ]] && exclude_flag="$r_excl"
                            if [[ -n "$exclude_flag" ]]; then
                                echo -n "Enter exclude join mode (comma, space, or repeat) [current: ${exclude_join:-,}]: "
                                read -r r_join
                                r_join=$(trim "$r_join")
                                case "$r_join" in
                                    repeat|--repeat) exclude_join="repeat" ;;
                                    space|" ") exclude_join="space" ;;
                                    comma|",") exclude_join="," ;;
                                    *) [[ -n "$r_join" ]] && exclude_join="$r_join" ;;
                                esac
                            fi
                            _save_current_mgr
                            _refresh_found
                            ui_ok "Package exclude configuration updated."
                        fi
                    fi
                done

            elif [[ "$sub_choice" == *"Advanced Engine Settings"* ]]; then
                _edit_advanced_settings_menu "live"

            elif [[ "$sub_choice" == *"Rename Manager"* ]]; then
                while true; do
                    echo -n "Enter new name: "
                    read -r new_name
                    new_name=$(trim "$new_name")
                    [[ -z "$new_name" || "$new_name" == "$name" ]] && break

                    if [[ "$new_name" == "." || "$new_name" == ".." || "$new_name" =~ [/\\:] ]]; then
                        ui_error "Manager name cannot contain slashes or colons. Choose another name."
                        continue
                    fi

                    local dup=false
                    local j
                    for ((j=0; j<${#CUSTOM_NAMES[@]}; j++)); do
                        if [[ "${CUSTOM_NAMES[$j],,}" == "${new_name,,}" ]]; then
                            dup=true
                            break
                        fi
                    done

                    if [[ "$dup" == true ]]; then
                        ui_error "Manager name '$new_name' already exists. Choose another name."
                    else
                        local old_file="$conf_file"
                        local new_dir="${conf_file%/*}"
                        local new_file="$new_dir/${new_name// /_}.conf"

                        name="$new_name"
                        conf_file="$new_file"
                        _save_current_mgr
                        if [[ "$old_file" != "$new_file" ]]; then
                            rm -f "$old_file"
                        fi

                        ui_ok "Renamed manager to '$new_name'."
                        break
                    fi
                done
                load_custom_managers
                break

            elif [[ "$sub_choice" == *"Move to Group"* ]]; then
                local mv_groups
                mapfile -t mv_groups < <(get_all_groups)
                local mv_opts=("${mv_groups[@]}" "(standalone)" "(new group)")
                local mv_choice
                mv_choice=$(printf "%s\n" "${mv_opts[@]}" | fzf --height 10 --reverse --header "Move '$name' to which group?")
                [[ -z "$mv_choice" ]] && continue

                local new_group=""
                if [[ "$mv_choice" == "(new group)" ]]; then
                    echo -n "Enter new group name: "
                    read -r new_group
                    new_group=$(trim "$new_group")
                    new_group="${new_group//[\/\\\:]/}"
                    new_group=$(echo "$new_group" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
                    [[ -z "$new_group" ]] && continue
                elif [[ "$mv_choice" != "(standalone)" ]]; then
                    new_group="$mv_choice"
                fi

                if [[ "$new_group" == "$group" ]]; then
                    ui_info "Manager '$name' is already in ${group:-(standalone)}."
                    continue
                fi

                local new_dir="$CUSTOM_DIR"
                if [[ -n "$new_group" ]]; then
                    # Auto-resolve priority collision in target group
                    local conflict_mgr=""
                    local k
                    for ((k=0; k<${#CUSTOM_NAMES[@]}; k++)); do
                        [[ $k -eq $found ]] && continue
                        if [[ "${CUSTOM_GROUPS[$k]}" == "$new_group" && "${CUSTOM_PRIORITIES[$k]}" == "$priority" ]]; then
                            conflict_mgr="${CUSTOM_NAMES[$k]}"
                            break
                        fi
                    done
                    if [[ -n "$conflict_mgr" ]]; then
                        priority=$(_get_next_free_group_priority "$new_group" "highest")
                        ui_info "Auto-assigned conflict-free priority P:$priority in group '$new_group' (avoiding '$conflict_mgr')."
                    elif [[ "$priority" == "0" ]]; then
                        priority=$(_get_next_free_group_priority "$new_group" "highest")
                    fi
                    new_dir="$CUSTOM_DIR/$new_group"
                fi
                local new_file="$new_dir/${name// /_}.conf"

                local old_file="$conf_file"
                conf_file="$new_file"
                group="$new_group"
                _save_current_mgr
                if [[ "$old_file" != "$new_file" ]]; then
                    rm -f "$old_file"
                    local old_dir="${old_file%/*}"
                    [[ "$old_dir" != "$CUSTOM_DIR" && -d "$old_dir" ]] && rmdir "$old_dir" 2>/dev/null || true
                fi

                ui_ok "Moved '$name' to ${new_group:-(standalone)}."
                load_custom_managers
                break

            elif [[ "$sub_choice" == *"Delete Manager"* ]]; then
                echo -n "Are you sure you want to delete manager '$name'? [y/N]: "
                read -r del_confirm
                if [[ "$del_confirm" =~ ^[Yy]$ ]]; then
                    local del_dir="${conf_file%/*}"
                    rm -f "$conf_file"
                    [[ "$del_dir" != "$CUSTOM_DIR" && -d "$del_dir" ]] && rmdir "$del_dir" 2>/dev/null || true
                    ui_ok "Deleted manager '$name'."
                    load_custom_managers
                    break
                fi
            fi
        done
    done
}

# --- CONFIG MANAGER SUBMENUS ---

_menu_snapshots() {
    local last_idx=0
    while true; do
        local s_pre="[OFF]"; [[ "$ALWAYS_PRE_SNAP" == true ]] && s_pre="[ON ]"
        local s_post="[OFF]"; [[ "$ALWAYS_POST_SNAP" == true ]] && s_post="[ON ]"
        local s_kpre="[OFF]"; [[ "$ALWAYS_KEEP_PRE" == true ]] && s_kpre="[ON ]"
        local s_kpost="[OFF]"; [[ "$ALWAYS_KEEP_POST" == true ]] && s_kpost="[ON ]"
        local s_clean="[OFF]"; [[ "$ALWAYS_CLEANUP" == true ]] && s_clean="[ON ]"
        local s_age="[${SNAP_MIN_AGE:-none}]"

        local has_cp=true
        local req_cp=""
        if ! command -v checkpoint >/dev/null 2>&1; then
            has_cp=false
            local cp_warn="[!] "; [[ "$USE_EMOJI" == true ]] && cp_warn="⚠️ "
            req_cp="  ${cp_warn}requires Checkpoint"
        fi

        local opt=(
            "$(e 📸)Pre-Update Snapshot        $s_pre$req_cp"
            "$(e 📸)Post-Update Snapshot       $s_post$req_cp"
            "$(e 🔒)Mark Pre-Snap as [KEEP]    $s_kpre$req_cp"
            "$(e 🔒)Mark Post-Snap as [KEEP]   $s_kpost$req_cp"
            "$(e 🧹)Auto-Cleanup Old Snaps     $s_clean$req_cp"
            "$(e ⏱️)Snapshot Minimum Age       $s_age$req_cp"
        )

        if [[ "$has_cp" == false ]]; then
            local s_skip="[OFF]"; [[ "$SKIP_CHECKPOINT_WARNING" == true ]] && s_skip="[ON ]"
            opt+=(
                "---"
                "$(e 🔕)Skip Checkpoint Warning    $s_skip"
            )
        fi

        opt+=(
            "---"
            "$(e 🔙)Back to Main Menu"
        )

        local bind_args=()
        [[ $last_idx -gt 0 ]] && bind_args=(--bind "start:pos($((last_idx + 1)))")

        local choice
        choice=$(printf "%s\n" "${opt[@]}" | fzf --height 20 --reverse "${bind_args[@]}" \
            --header "--- Snapshots & Safety Settings ---" \
            --preview 'case "{}" in
                *Pre-Update*Snapshot*)
                    echo -e "📸 Pre-Update Snapshot\n──────────────────────\nCreates an automatic system backup right BEFORE any packages are downloaded or updated.\n\nWhy use this?\nIf an update fails halfway or corrupts your display drivers, you can revert back to your exact previous state in seconds.\n\nExample:\nA kernel update causes a black screen on boot. Reboot into your GRUB or systemd-boot menu, select the pre-update snapshot, and your computer works again.\n\nDefault: true" ;;
                *Post-Update*Snapshot*)
                    echo -e "📸 Post-Update Snapshot\n───────────────────────\nCreates an automatic system backup immediately AFTER all updates finish successfully.\n\nWhy use this?\nMarks a verified \"known-good\" checkpoint with all your newest package updates in place.\n\nDefault: true" ;;
                *Mark*Pre*KEEP*)
                    echo -e "🔒 Protect Pre-Snap [KEEP]\n──────────────────────────\nLocks pre-update backups so automated cleanup tools will NEVER delete them.\n\nWhy use this?\nNormal snapshots are deleted when the snapshot limit is reached. A [KEEP] snapshot is permanent until you manually delete it.\n\nExample:\nBefore doing a massive distribution upgrade, keeping the backup guarantees you can restore it weeks later.\n\nDefault: false" ;;
                *Mark*Post*KEEP*)
                    echo -e "🔒 Protect Post-Snap [KEEP]\n───────────────────────────\nLocks post-update backups with the [KEEP] tag so they are never deleted by auto-cleanup.\n\nDefault: false" ;;
                *Auto-Cleanup*)
                    echo -e "🧹 Auto-Cleanup Old Snapshots\n─────────────────────────────\nAutomatically prunes older unkept backups when you exceed the retention limit configured in Checkpoint (default: 6).\n\nWhy use this?\nPrevents your hard drive or SSD from filling up with old backups over time. Protected [KEEP] backups are never deleted.\n\nDefault: true" ;;
                *Minimum*Age*)
                    echo -e "⏱️ Snapshot Minimum Age\n───────────────────────\nSkips creating a new pre-snapshot if a recent backup was already created within this time window.\n\nWhy use this?\nIf you run Advance multiple times in a row, this prevents wasting disk space on redundant snapshots.\n\nSupported Formats:\n  • 30s (30 seconds)\n  • 10m (10 minutes)\n  • 2h  (2 hours)\n  • 1d  (1 day)\n\nLeave empty to always create snapshots." ;;
                *Skip*Checkpoint*Warning*)
                    echo -e "🔕 Skip Checkpoint Warning\n──────────────────────────\nWhen Checkpoint is not installed, Advance asks whether to proceed without snapshots.\n\nTurning this ON permanently suppresses the prompt and always proceeds directly with snapshots disabled, showing a reminder instead.\n\nDefault: false" ;;
                *) echo -e "Select an option to view details and examples." ;;
            esac' --preview-window=right:55%:wrap)

        [[ -z "$choice" || "$choice" == *Back* ]] && return 0

        # Save cursor position
        local idx=0
        for item in "${opt[@]}"; do
            if [[ "$item" == "$choice" ]]; then last_idx=$idx; break; fi
            ((idx++))
        done

        case "$choice" in
            *"Pre-Update Snapshot"*) [[ "$ALWAYS_PRE_SNAP" == true ]] && ALWAYS_PRE_SNAP=false || ALWAYS_PRE_SNAP=true ;;
            *"Post-Update Snapshot"*) [[ "$ALWAYS_POST_SNAP" == true ]] && ALWAYS_POST_SNAP=false || ALWAYS_POST_SNAP=true ;;
            *"Mark Pre-Snap as [KEEP]"*) [[ "$ALWAYS_KEEP_PRE" == true ]] && ALWAYS_KEEP_PRE=false || ALWAYS_KEEP_PRE=true ;;
            *"Mark Post-Snap as [KEEP]"*) [[ "$ALWAYS_KEEP_POST" == true ]] && ALWAYS_KEEP_POST=false || ALWAYS_KEEP_POST=true ;;
            *"Auto-Cleanup Old Snaps"*) [[ "$ALWAYS_CLEANUP" == true ]] && ALWAYS_CLEANUP=false || ALWAYS_CLEANUP=true ;;
            *"Snapshot Minimum Age"*)
                local input_age
                read -p "Enter minimum age (e.g. 10m, 2h, 1d, current: ${SNAP_MIN_AGE:-none}): " input_age
                input_age=$(trim "$input_age")
                SNAP_MIN_AGE="$input_age" ;;
            *"Skip Checkpoint Warning"*) [[ "$SKIP_CHECKPOINT_WARNING" == true ]] && SKIP_CHECKPOINT_WARNING=false || SKIP_CHECKPOINT_WARNING=true ;;
        esac
    done
}

_menu_execution() {
    local last_idx=0
    while true; do
        local s_ac="[OFF]"; [[ "$AUTO_CONFIRM" != false ]] && s_ac="[ON ]"
        local s_inf="[OFF]"; [[ "$INFINITE_RETRIES" == true ]] && s_inf="[ON ]"
        local s_ret="[$AUTO_RETRIES]"
        local s_upd="[${SELF_UPDATE_CHECK^^}]"

        local opt=(
            "$(e 🤖)Global Auto-Confirm        $s_ac"
            "$(e 🔟)Auto-Retries Limit         $s_ret"
            "$(e ♾️)Infinite Retries Mode      $s_inf"
            "$(e 🔄)Self-Update Check          $s_upd"
            "---"
            "$(e 🔙)Back to Main Menu"
        )

        local bind_args=()
        [[ $last_idx -gt 0 ]] && bind_args=(--bind "start:pos($((last_idx + 1)))")

        local choice
        choice=$(printf "%s\n" "${opt[@]}" | fzf --height 20 --reverse "${bind_args[@]}" \
            --header "--- Execution & Error Handling ---" \
            --preview 'case "{}" in
                *Global*Auto-Confirm*)
                    echo -e "🤖 Global Auto-Confirm\n──────────────────────\nWhen enabled, Advance automatically appends auto-confirm flags (e.g. --noconfirm, -y) to update commands for all managers set to \"Follow global\".\n\nWhen disabled, managers will prompt you interactively unless their per-manager setting is \"ON unless forced\".\n\nDefault: true (seamless updates)" ;;
                *Auto-Retries*)
                    echo -e "🔟 Auto-Retries Limit\n─────────────────────\nHow many times Advance silently retries a failed command before stopping to ask you what to do.\n\nWhy use this?\nGreat for handling brief network glitches or mirror timeouts during package downloads without stopping.\n\nValues:\n• 0: Stop and ask immediately on error\n• 1, 2, 3...: Retry up to N times before asking\n\nDefault: 1" ;;
                *Infinite*)
                    echo -e "♾️ Infinite Retries Mode\n────────────────────────\nContinuously retries failed commands until they succeed.\n\nWhy use this?\nIdeal for unattended background updates or very flaky, slow, or rural internet connections.\n\nCaution:\nIf a package has a broken dependency or conflict, this will loop until manually cancelled with Ctrl+C.\n\nDefault: false" ;;
                *Self-Update*)
                    echo -e "🔄 Self-Update Check\n────────────────────\nControls how Advance checks for new versions and commits from GitHub.\n\nModes:\n• prompt: Interactive banner asking [Y/n/a/d] when updates are found (Default)\n• notify: Non-intrusive notification banner only (never pauses CLI)\n• auto: Silently and automatically update Advance before running tasks\n• off: Disable automatic update checks entirely\n\nDefault: prompt" ;;
                *) echo -e "Select an option to view details and examples." ;;
            esac' --preview-window=right:55%:wrap)

        [[ -z "$choice" || "$choice" == *Back* ]] && return 0

        local idx=0
        for item in "${opt[@]}"; do
            if [[ "$item" == "$choice" ]]; then last_idx=$idx; break; fi
            ((idx++))
        done

        case "$choice" in
            *"Global Auto-Confirm"*)
                [[ "$AUTO_CONFIRM" != false ]] && AUTO_CONFIRM=false || AUTO_CONFIRM=true ;;
            *"Auto-Retries Limit"*)
                local input_retries
                read -p "Enter retry limit (0 for always ask, current: $AUTO_RETRIES): " input_retries
                input_retries=$(trim "$input_retries")
                [[ "$input_retries" =~ ^[0-9]+$ ]] && AUTO_RETRIES="$input_retries" ;;
            *"Infinite Retries Mode"*)
                [[ "$INFINITE_RETRIES" == true ]] && INFINITE_RETRIES=false || INFINITE_RETRIES=true ;;
            *"Self-Update Check"*)
                local modes=(
                    "$(e 💬)prompt  — Interactive banner: ask [Y/n/a/d] when update is available (Default)"
                    "$(e 🔔)notify  — Notification banner only (never pauses execution)"
                    "$(e ⚡)auto    — Automatically update before running tasks"
                    "$(e 🚫)off     — Disable automatic self-update checks"
                )
                local m_choice
                m_choice=$(printf "%s\n" "${modes[@]}" | fzf --height 10 --reverse \
                    --header "Select Self-Update Check Mode (Current: $SELF_UPDATE_CHECK)")
                case "$m_choice" in
                    *prompt*) SELF_UPDATE_CHECK="prompt" ;;
                    *notify*) SELF_UPDATE_CHECK="notify" ;;
                    *auto*)   SELF_UPDATE_CHECK="auto" ;;
                    *off*)    SELF_UPDATE_CHECK="off" ;;
                esac
                ;;
        esac
    done
}

_menu_appearance() {
    local last_idx=0
    while true; do
        local s_em="[OFF]"; [[ "$USE_EMOJI" == true ]] && s_em="[ON ]"
        local s_col="[OFF]"; [[ "$USE_COLOR" == true ]] && s_col="[ON ]"

        local opt=(
            "$(e 🎨)Terminal Icons / Emojis    $s_em"
            "$(e 🌈)ANSI Syntax Colors         $s_col"
            "$(e 🔄)Reset Dismissed Messages"
            "---"
            "$(e 🔙)Back to Main Menu"
        )

        local bind_args=()
        [[ $last_idx -gt 0 ]] && bind_args=(--bind "start:pos($((last_idx + 1)))")

        local choice
        choice=$(printf "%s\n" "${opt[@]}" | fzf --height 20 --reverse "${bind_args[@]}" \
            --header "--- Interface & Appearance ---" \
            --preview 'case "{}" in
                *Icons*|*Emojis*)
                    echo -e "🎨 Terminal Icons / Emojis\n──────────────────────────\nDisplays friendly graphical icons (📦, 🖥️, ✅, ⚠️, ❌) next to tasks and headers.\n\nWhen to turn off:\nIf your terminal font does not support emojis and shows them as empty rectangles [▯] or question marks [?].\n\nDefault: true" ;;
                *Colors*)
                    echo -e "🌈 ANSI Syntax Colors\n─────────────────────\nColor-codes commands, statuses, and headers (green for success, red for errors, cyan for info).\n\nWhen to turn off:\nIf using a monochrome terminal or piping output to plain text files.\n\nDefault: true" ;;
                *Dismissed*|*Reset*)
                    echo -e "🔄 Reset Dismissed Messages\n──────────────────────────\nAdvance displays helpful tips and suggestions that can be permanently dismissed by pressing '\''D'\''.\n\nSelecting this option clears the list of dismissed messages so they can appear again if triggered." ;;
                *) echo -e "Select an option to view details and examples." ;;
            esac' --preview-window=right:55%:wrap)

        [[ -z "$choice" || "$choice" == *Back* ]] && return 0

        local idx=0
        for item in "${opt[@]}"; do
            if [[ "$item" == "$choice" ]]; then last_idx=$idx; break; fi
            ((idx++))
        done

        case "$choice" in
            *"Terminal Icons / Emojis"*) [[ "$USE_EMOJI" == true ]] && USE_EMOJI=false || USE_EMOJI=true ;;
            *"ANSI Syntax Colors"*) [[ "$USE_COLOR" == true ]] && USE_COLOR=false || USE_COLOR=true; setup_colors ;;
            *"Reset Dismissed Messages"*)
                local d_file="$DISMISSED_FILE"
                if [[ -f "$d_file" ]]; then
                    rm -f "$d_file"
                    ui_ok "Dismissed messages have been reset."
                else
                    ui_info "No dismissed messages to reset."
                fi
                sleep 1 ;;
        esac
    done
}

# --- CONFIG MANAGER (CATEGORIZED HUB) ---
manage_config() {
    if ! ensure_fzf; then return 1; fi
    local init_emoji=$USE_EMOJI; local init_color=$USE_COLOR
    local init_pre=$ALWAYS_PRE_SNAP; local init_post=$ALWAYS_POST_SNAP; local init_cleanup=$ALWAYS_CLEANUP
    local init_kpre=$ALWAYS_KEEP_PRE; local init_kpost=$ALWAYS_KEEP_POST
    local init_retries=$AUTO_RETRIES; local init_inf=$INFINITE_RETRIES
    local init_snap_age=$SNAP_MIN_AGE
    local init_auto_confirm=$AUTO_CONFIRM
    local init_skip_checkpoint_warning=$SKIP_CHECKPOINT_WARNING
    local init_self_update_check=$SELF_UPDATE_CHECK
    local last_idx=0
    local mgr_summary
    mgr_summary=$(get_active_managers_summary)
    local prev_changelog prev_dev prev_save prev_discard
    prev_changelog=$(cat <<EOF
$(e 📜)View Changelog / What's New
──────────────────────────────
Browse version release notes and update history.

Select this item to open the interactive version browser.

$(display_changelog "latest" 2>/dev/null || true)
EOF
)
    prev_dev=$(cat <<EOF
$(e 🚧)Features in Development (Upcoming)
──────────────────────────────────────
Upcoming user-facing features planned for future releases.

$(display_changelog "Unreleased" 2>/dev/null || true)
EOF
)
    prev_save=$(cat <<EOF
$(e 💾)Save and Return
──────────────────
Permanently write all changes made during this session to your configuration file ($(tilde_path "$CONFIG_FILE")).
EOF
)
    prev_discard=$(cat <<EOF
$(e ❌)Discard and Exit
───────────────────
Revert all settings back to their original values from when this menu was opened and exit.
EOF
)

    while true; do
        local opt=(
            "$(e 📦)Package Managers"
            "$(e 📸)Snapshots & Safety (Checkpoint)"
            "$(e ⚡)Execution & Error Handling"
            "$(e 🎨)Interface & Appearance"
            "$(e 📜)View Changelog / What's New"
            "$(e 🚧)Features in Development     [Preview]"
            "---"
            "$(e ✅)Save and Return"
            "$(e ❌)Discard and Exit"
        )

        local prev_pkgs prev_snaps prev_exec prev_ui
        prev_pkgs=$(cat <<EOF
$(e 📦)Package Managers
───────────────────
Linux uses package managers to install and update apps and system tools.

Here you can:
• Enable or disable specific managers
• Reorder group & manager priorities (Alt+Up / Alt+Down)
• Add new community or custom updater scripts

Active Execution Plan:
$mgr_summary
EOF
)
        prev_snaps=$(cat <<EOF
$(e 📸)Snapshots & Safety
─────────────────────
Snapshots are instant system savepoints. If an update breaks your display drivers or Wi-Fi, you can revert back to how your system was before the update in seconds.

Requires Checkpoint utility.

Current Settings:
• Pre-Update Backup:  $ALWAYS_PRE_SNAP
• Post-Update Backup: $ALWAYS_POST_SNAP
• Protect Pre-Snap:   $ALWAYS_KEEP_PRE
• Protect Post-Snap:  $ALWAYS_KEEP_POST
• Auto-Cleanup Old:   $ALWAYS_CLEANUP
• Snapshot Min Age:   ${SNAP_MIN_AGE:-(none)}
EOF
)
        prev_exec=$(cat <<EOF
$(e ⚡)Execution & Error Handling
─────────────────────────────
Controls how Advance handles network drops, download errors, and auto-confirmation.

Current Settings:
• Global Auto-Confirm: $AUTO_CONFIRM
• Auto-Retries Limit:  $AUTO_RETRIES
• Infinite Retries:    $INFINITE_RETRIES
• Self-Update Check:   $SELF_UPDATE_CHECK
EOF
)
        prev_ui=$(cat <<EOF
$(e 🎨)Interface & Appearance
──────────────────────────
Customize visual styling in your terminal window.

Current Settings:
• Icons / Emojis:     $USE_EMOJI
• Syntax Colors:      $USE_COLOR
EOF
)

        local bind_args=()
        [[ $last_idx -gt 0 ]] && bind_args=(--bind "start:pos($((last_idx + 1)))")

        local choice
        choice=$(
            export CFG_PREV_PKGS="$prev_pkgs"
            export CFG_PREV_SNAPS="$prev_snaps"
            export CFG_PREV_EXEC="$prev_exec"
            export CFG_PREV_UI="$prev_ui"
            export CFG_PREV_CHANGELOG="$prev_changelog"
            export CFG_PREV_DEV="$prev_dev"
            export CFG_PREV_SAVE="$prev_save"
            export CFG_PREV_DISCARD="$prev_discard"
            printf "%s\n" "${opt[@]}" | fzf --height 20 --reverse "${bind_args[@]}" \
                --header "--- Advance Configuration Hub ---" \
                --preview 'case "{}" in
                    *Package*Managers*) printf "%s\n" "$CFG_PREV_PKGS" ;;
                    *Snapshots*)        printf "%s\n" "$CFG_PREV_SNAPS" ;;
                    *Execution*)        printf "%s\n" "$CFG_PREV_EXEC" ;;
                    *Interface*)        printf "%s\n" "$CFG_PREV_UI" ;;
                    *Changelog*|*What*New*) printf "%s\n" "$CFG_PREV_CHANGELOG" ;;
                    *Features*in*Development*) printf "%s\n" "$CFG_PREV_DEV" ;;
                    *Save*)             printf "%s\n" "$CFG_PREV_SAVE" ;;
                    *Discard*)          printf "%s\n" "$CFG_PREV_DISCARD" ;;
                    *) echo "Select a category to view details and options." ;;
                esac' --preview-window=right:55%:wrap
        )

        [[ -z "$choice" ]] && choice="Discard and Exit"

        local idx=0
        for item in "${opt[@]}"; do
            if [[ "$item" == "$choice" ]]; then last_idx=$idx; break; fi
            ((++idx))
        done

        case "$choice" in
            *"Package Managers"*)
                manage_custom_managers_menu
                mgr_summary=$(get_active_managers_summary)
                ;;
            *"Snapshots & Safety"*) _menu_snapshots ;;
            *"Execution & Error Handling"*) _menu_execution ;;
            *"Interface & Appearance"*) _menu_appearance ;;
            *"View Changelog"*|*"What's New"*)
                browse_changelog_interactive
                local r=$?
                if [[ $r -eq 2 ]]; then
                    echo ""
                    read -rp "Press Enter to return to configuration menu..." _dummy
                fi
                ;;
            *"Features in Development"*)
                echo ""
                display_changelog "Unreleased"
                echo ""
                read -rp "Press Enter to return to configuration menu..." _dummy
                ;;
            *"Save and Return"*) save_config; ui_ok "Configuration saved successfully."; break ;;
            *"Discard and Exit"*)
                USE_EMOJI=$init_emoji; USE_COLOR=$init_color
                ALWAYS_PRE_SNAP=$init_pre; ALWAYS_POST_SNAP=$init_post; ALWAYS_CLEANUP=$init_cleanup
                ALWAYS_KEEP_PRE=$init_kpre; ALWAYS_KEEP_POST=$init_kpost; AUTO_RETRIES=$init_retries; INFINITE_RETRIES=$init_inf
                SNAP_MIN_AGE=$init_snap_age; AUTO_CONFIRM=$init_auto_confirm; SKIP_CHECKPOINT_WARNING=$init_skip_checkpoint_warning
                SELF_UPDATE_CHECK=$init_self_update_check
                ui_info "Changes discarded."; break ;;
            *) continue ;;
        esac
    done
}

self_update() {
    detect_source_dir
    if [[ ! -d "$SOURCE_DIR" ]]; then ui_error "Source repo not found."; return 1; fi
    if [[ ! -x "$SOURCE_DIR/install.sh" ]]; then
        ui_error "No installer found in $SOURCE_DIR."
        ui_info "This copy of Advance was installed by a package manager; update it with your system package manager instead."
        return 1
    fi
    if declare -f check_connectivity >/dev/null 2>&1; then
        if ! check_connectivity; then
            ui_error "No active internet connection. Cannot perform self-update."
            return 1
        fi
    fi

    local old_ver="$VERSION"
    local old_commit
    old_commit=$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || true)

    (
        cd "$SOURCE_DIR" || exit 1
        if git remote | grep -qx 'origin'; then
            local orig_url
            orig_url=$(git remote get-url origin 2>/dev/null || true)
            if [[ (-d ".agents" || -d ".gemini") && "$orig_url" =~ ^(.*github\.com[:/][^/]+/advance)(\.git)?$ ]]; then
                local base_url="${BASH_REMATCH[1]}"
                git remote get-url public >/dev/null 2>&1 || git remote add public "${base_url}.git" 2>/dev/null || true
                git remote set-url origin "${base_url}-dev.git"
                git fetch origin --prune >/dev/null 2>&1 || true
            fi
            ui_info "Checking for updates..."
            local branch
            branch=$(git branch --show-current 2>/dev/null)
            branch=${branch:-master}
            local pull_out
            if ! pull_out=$(git -c advice.diverging=false pull --ff-only origin "$branch" 2>&1); then
                local clean_err
                clean_err=$(echo "$pull_out" | grep -vE '^[[:space:]]*hint:' | tail -n 2 | paste -sd '; ' -)
                ui_error "Pull failed: ${clean_err:-unknown git error}. Aborting self-update."
                exit 1
            fi
            if ! git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1; then
                git branch --set-upstream-to="origin/$branch" "$branch" >/dev/null 2>&1 || true
            fi
        else
            ui_info "Local source only."
        fi
        local cur_commit
        cur_commit=$(git rev-parse HEAD 2>/dev/null || true)
        if [[ -n "$old_commit" && "$old_commit" == "$cur_commit" ]]; then
            exit 10
        fi
        ./install.sh --quiet
    )
    local sub_code=$?
    if [[ $sub_code -eq 10 ]]; then
        ui_ok "Advance is already up to date (v$VERSION)."
        rm -f "${ADVANCE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/advance}/self_update.cache"
        if command -v checkpoint >/dev/null 2>&1; then
            echo ""
            checkpoint self-update || true
        fi
        return 0
    elif [[ $sub_code -ne 0 ]]; then
        return 1
    fi

    local new_commit
    new_commit=$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || true)
    local new_ver
    new_ver=$(grep '^VERSION=' "$SOURCE_DIR/advance" 2>/dev/null | head -n 1 | cut -d'"' -f2)
    new_ver="${new_ver:-$VERSION}"

    if [[ "$old_ver" != "$new_ver" || ("$old_commit" != "$new_commit" && -n "$old_commit") ]]; then
        echo ""
        ui_ok "Advance updated successfully to v$new_ver!"
        echo ""
        ui_info "${C_BOLD}What's New in v$new_ver:${C_RESET}"
        display_changelog "$new_ver" || display_changelog "latest"
        echo ""
    fi
    rm -f "${ADVANCE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/advance}/self_update.cache"

    if command -v checkpoint >/dev/null 2>&1; then
        echo ""
        ui_info "Updating companion tool (checkpoint)..."
        checkpoint self-update || ui_warn "Checkpoint self-update failed."
    fi
}

manage_schedule() {
    if ! ensure_fzf; then return 1; fi

    local presets=(
        "$(e 🌅)Morning: Daily at 09:00"
        "$(e 🌆)Evening: Daily at 18:00"
        "$(e 📅)Daily: Every night at 00:00"
        "$(e 📆)Weekly: Every Sunday at 00:00"
        "$(e ⚡)Startup: 5 minutes after boot"
        "$(e ⚙️)Custom Calendar/Interval..."
        "---"
        "$(e ❌)Disable/Remove active schedule"
        "$(e 🔙)Back"
    )

    local choice=$(printf "%s\n" "${presets[@]}" | fzf --height 15 --reverse --header "--- Auto-Update Scheduler ---")
    [[ -z "$choice" || "$choice" == *Back* ]] && return 0
    [[ "$choice" == ---* ]] && return 0

    local timer_setting=""

    if [[ "$choice" == *Disable* ]]; then
        systemctl --user disable --now advance-update.timer >/dev/null 2>&1
        rm -f "$XDG_CONFIG_HOME/systemd/user/advance-update.timer"
        rm -f "$XDG_CONFIG_HOME/systemd/user/advance-update.service"
        systemctl --user daemon-reload >/dev/null 2>&1
        ui_ok "Auto-update schedule disabled and removed."
        return 0
    fi

    if [[ "$choice" == *Morning* ]]; then
        timer_setting="OnCalendar=*-*-* 09:00:00"
    elif [[ "$choice" == *Evening* ]]; then
        timer_setting="OnCalendar=*-*-* 18:00:00"
    elif [[ "$choice" == *Daily* ]]; then
        timer_setting="OnCalendar=daily"
    elif [[ "$choice" == *Weekly* ]]; then
        timer_setting="OnCalendar=weekly"
    elif [[ "$choice" == *Startup* ]]; then
        timer_setting="OnBootSec=5min"
    elif [[ "$choice" == *Custom* ]]; then
        local custom_opts=(
            "Days of Week"
            "Days of Month"
            "Repeating Interval (Hourly, Daily, Monthly, Yearly)"
            "Raw Systemd Timer Expression"
        )
        local custom_choice=$(printf "%s\n" "${custom_opts[@]}" | fzf --height 12 --reverse --header "--- Custom Schedule Builder ---")
        [[ -z "$custom_choice" ]] && return 0

        if [[ "$custom_choice" == "Days of Week" ]]; then
            local days=( "Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday" "Sunday" )
            local sel_days=$(printf "%s\n" "${days[@]}" | fzf -m --height 12 --reverse --header "Select days of the week (TAB to multi-select, ENTER to confirm)")
            [[ -z "$sel_days" ]] && return 0
            local day_abbrs=()
            for d in $sel_days; do
                day_abbrs+=("${d:0:3}")
            done
            local days_str=$(echo "${day_abbrs[@]}" | tr ' ' ',')

            echo -n "Enter hour of execution (0-23) [4]: "
            read -r hour
            [[ -z "$hour" ]] && hour="4"
            timer_setting="OnCalendar=${days_str} ${hour}:00:00"

        elif [[ "$custom_choice" == "Days of Month" ]]; then
            echo -n "Enter days of month (comma-separated, e.g. 1,15) [1]: "
            read -r dom
            [[ -z "$dom" ]] && dom="1"
            echo -n "Enter hour of execution (0-23) [4]: "
            read -r hour
            [[ -z "$hour" ]] && hour="4"
            timer_setting="OnCalendar=*-*-${dom} ${hour}:00:00"

        elif [[ "$custom_choice" == *Repeating* ]]; then
            local units=( "Hours" "Days" "Months" "Years" )
            local unit=$(printf "%s\n" "${units[@]}" | fzf --height 8 --reverse --header "Select repeating unit")
            [[ -z "$unit" ]] && return 0

            if [[ "$unit" == "Hours" ]]; then
                local hrs=( "Every 2 hours" "Every 4 hours" "Every 6 hours" "Every 12 hours" )
                local hr_sel=$(printf "%s\n" "${hrs[@]}" | fzf --height 8 --reverse --header "Select interval")
                [[ -z "$hr_sel" ]] && return 0
                local num=$(echo "$hr_sel" | awk '{print $2}')
                timer_setting="OnCalendar=*-*-* 00/${num}:00:00"
            elif [[ "$unit" == "Days" ]]; then
                echo -n "Enter repeating interval in days (e.g. 3 for every 3 days) [1]: "
                read -r num
                [[ -z "$num" ]] && num="1"
                echo -n "Enter hour of execution (0-23) [4]: "
                read -r hour
                [[ -z "$hour" ]] && hour="4"
                timer_setting="OnCalendar=*-*-01/${num} ${hour}:00:00"
            elif [[ "$unit" == "Months" ]]; then
                echo -n "Enter repeating interval in months (e.g. 2 for every 2 months) [1]: "
                read -r num
                [[ -z "$num" ]] && num="1"
                echo -n "Enter hour of execution (0-23) [4]: "
                read -r hour
                [[ -z "$hour" ]] && hour="4"
                timer_setting="OnCalendar=*-01/${num}-* ${hour}:00:00"
            elif [[ "$unit" == "Years" ]]; then
                echo -n "Enter repeating interval in years (e.g. 1 for every year) [1]: "
                read -r num
                [[ -z "$num" ]] && num="1"
                echo -n "Enter hour of execution (0-23) [4]: "
                read -r hour
                [[ -z "$hour" ]] && hour="4"
                timer_setting="OnCalendar=*-01-01 ${hour}:00:00"
            fi

        elif [[ "$custom_choice" == *Raw* ]]; then
            echo "Enter a systemd timer trigger expression."
            echo "Examples: OnCalendar=*-*-* 04:00:00, OnBootSec=15min"
            echo -n "Expression: "
            read -r raw_exp
            raw_exp=$(echo "$raw_exp" | xargs)
            [[ -z "$raw_exp" ]] && return 0
            if [[ "$raw_exp" != OnCalendar=* && "$raw_exp" != OnBootSec=* && "$raw_exp" != OnActiveSec=* ]]; then
                ui_error "Expression must start with OnCalendar=, OnBootSec=, or OnActiveSec="
                return 1
            fi
            timer_setting="$raw_exp"
        fi
    fi

    [[ -z "$timer_setting" ]] && { ui_error "Invalid schedule settings."; return 1; }

    local service_file="$XDG_CONFIG_HOME/systemd/user/advance-update.service"
    local timer_file="$XDG_CONFIG_HOME/systemd/user/advance-update.timer"
    local advance_bin
    advance_bin=$(command -v advance 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")

    mkdir -p "$XDG_CONFIG_HOME/systemd/user"

    cat <<EOF > "$service_file"
[Unit]
Description=Universal System Update Manager (Advance)
Documentation=man:advance(1)

[Service]
Type=oneshot
ExecStart=$advance_bin
EOF

    cat <<EOF > "$timer_file"
[Unit]
Description=Universal System Update Manager Timer (Advance)

[Timer]
$timer_setting
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl --user daemon-reload
    if systemctl --user enable --now advance-update.timer >/dev/null 2>&1; then
        ui_ok "Auto-update schedule configured successfully!"
        ui_info "Timer Details:"
        systemctl --user status advance-update.timer | grep -E "Trigger:|Active:" || true
    else
        ui_error "Failed to enable systemd timer. Check systemd logs."
    fi
}

