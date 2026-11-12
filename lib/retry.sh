#!/usr/bin/env bash
# ==============================================================================
# lib/retry.sh — Attention notification system and interactive retry engine
# Part of Advance Universal System Update Manager
# ==============================================================================

# --- Attention System ---
NOTIFICATION_ID=""

request_attention() {
    local msg="$1"
    echo -e "\n\e[5;31;43m ######################################################## \e[0m"
    echo -e "\e[1;31;43m # ATTENTION: USER INPUT REQUIRED! # \e[0m"
    echo -e "\e[5;31;43m ######################################################## \e[0m\n"
    if [[ "$USE_EMOJI" == true ]]; then
        echo -e "\e[1;33m"
        echo "  █████  ████████ ████████ ███████ ███    ██ ████████ ██  ██████  ███    ██ "
        echo " ██   ██    ██       ██    ██      ████   ██    ██    ██ ██    ██ ████   ██ "
        echo " ███████    ██       ██    █████   ██ ██  ██    ██    ██ ██    ██ ██ ██  ██ "
        echo " ██   ██    ██       ██    ██      ██  ██ ██    ██    ██ ██    ██ ██  ██ ██ "
        echo " ██   ██    ██       ██    ███████ ██   ████    ██    ██  ██████  ██   ████ "
        echo -e "\e[0m"
    else
        echo -e "${C_BOLD}${C_YELLOW}!!! ATTENTION REQUIRED !!!${C_RESET}"
    fi
    echo -e "\e[1;31m>>> REQUIRED ACTION: $msg <<<\e[0m\n"
    command -v notify-send >/dev/null 2>&1 && \
        NOTIFICATION_ID=$(notify-send -p "UPDATE REQUIRED" "$msg" -u critical -i dialog-warning -a "advance" 2>/dev/null || true)
    echo -e "\a"
}

close_attention() {
    if [[ -n "$NOTIFICATION_ID" ]] && command -v gdbus >/dev/null 2>&1; then
        gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications --method org.freedesktop.Notifications.CloseNotification "$NOTIFICATION_ID" >/dev/null 2>&1
        NOTIFICATION_ID=""
    fi
}

# --- Retry Engine ---
LAST_CMD_OUTPUT=""

# Dynamically formats and renders the error escalation box with uniform borders,
# exact emoji display-width calculations, and responsive terminal auto-wrapping.
_render_retry_box() {
    local phase="$1"
    local attempts="$2"
    local retry_word="$3"
    local exit_code="$4"
    local cmd="$5"

    local term_cols="${COLUMNS:-}"
    [[ -z "$term_cols" ]] && term_cols=$(tput cols 2>/dev/null || echo 80)
    [[ ! "$term_cols" =~ ^[0-9]+$ || $term_cols -lt 40 ]] && term_cols=80

    local icon="[FAIL]"
    local icon_w=6
    local title_text="$phase failed after $attempts $retry_word."
    if [[ $exit_code -eq 130 ]]; then
        icon="[WARN]"
        icon_w=6
        title_text="$phase was interrupted (Ctrl+C)."
        if [[ "$USE_EMOJI" == true ]]; then
            icon="⚠️"
            icon_w=2
        fi
    elif [[ $exit_code -eq 124 ]]; then
        icon="[STALL]"
        icon_w=7
        title_text="$phase stalled and was terminated (inactivity timeout)."
        if [[ "$USE_EMOJI" == true ]]; then
            icon="⏱️"
            icon_w=2
        fi
    elif [[ "$USE_EMOJI" == true ]]; then
        icon="❌"
        icon_w=2
    fi

    local clean_title
    clean_title=$(printf '%b' "$title_text" | sed 's/\x1b\[[0-9;]*m//g')
    local title_vis_len=$((icon_w + 1 + ${#clean_title}))
    local cmd_prefix="Command: "

    local max_cmd_line_len=0
    local cmd_l
    while IFS= read -r cmd_l; do
        local clean_cmd_l
        clean_cmd_l=$(printf '%b' "$cmd_l" | sed 's/\x1b\[[0-9;]*m//g')
        [[ ${#clean_cmd_l} -gt $max_cmd_line_len ]] && max_cmd_line_len=${#clean_cmd_l}
    done <<< "$cmd"
    local cmd_vis_len=$((${#cmd_prefix} + max_cmd_line_len))

    local max_content_w=$cmd_vis_len
    [[ $title_vis_len -gt $max_content_w ]] && max_content_w=$title_vis_len

    # Box margins: 2 interior spaces left + 2 interior spaces right + 2 vertical borders = 6 columns overhead
    local max_allowed_w=$((term_cols - 6))
    [[ $max_allowed_w -lt 24 ]] && max_allowed_w=24

    local avail_w=$max_content_w
    [[ $max_content_w -gt $max_allowed_w ]] && avail_w=$max_allowed_w

    local box_w=$((avail_w + 4))
    local box_top="┌"
    local box_bot="└"
    local i
    for ((i=0; i<box_w; i++)); do
        box_top+="─"
        box_bot+="─"
    done
    box_top+="┐"
    box_bot+="┘"

    printf "\n%b\n" "${C_RED}${box_top}${C_RESET}"

    local avail_title_w=$((avail_w - icon_w - 1))
    if command -v fold >/dev/null 2>&1 && [[ ${#clean_title} -gt $avail_title_w && $avail_title_w -gt 10 ]]; then
        local wrapped_title first_t=true t_line t_pad t_padding
        local t_indent
        t_indent=$(printf '%*s' "$((icon_w + 1))" "")
        wrapped_title=$(echo "$title_text" | fold -s -w "$avail_title_w")
        while IFS= read -r t_line; do
            local clean_t_line
            clean_t_line=$(printf '%b' "$t_line" | sed 's/\x1b\[[0-9;]*m//g')
            t_pad=$((avail_title_w - ${#clean_t_line}))
            [[ $t_pad -lt 0 ]] && t_pad=0
            t_padding=$(printf '%*s' "$t_pad" "")
            if [[ "$first_t" == true ]]; then
                printf "%b  %s %s%s  %b\n" "${C_RED}│${C_RESET}" "$icon" "$t_line" "$t_padding" "${C_RED}│${C_RESET}"
                first_t=false
            else
                printf "%b  %s%s%s  %b\n" "${C_RED}│${C_RESET}" "$t_indent" "$t_line" "$t_padding" "${C_RED}│${C_RESET}"
            fi
        done <<< "$wrapped_title"
    else
        local title_pad=$((avail_w - title_vis_len))
        [[ $title_pad -lt 0 ]] && title_pad=0
        local title_padding
        title_padding=$(printf '%*s' "$title_pad" "")
        printf "%b  %s %s%s  %b\n" "${C_RED}│${C_RESET}" "$icon" "$title_text" "$title_padding" "${C_RED}│${C_RESET}"
    fi

    local avail_cmd_w=$((avail_w - ${#cmd_prefix}))
    if command -v fold >/dev/null 2>&1 && [[ "$cmd" == *$'\n'* || ${#cmd} -gt $avail_cmd_w ]] && [[ $avail_cmd_w -gt 15 ]]; then
        local wrapped_cmd first_c=true c_line c_pad c_padding
        local c_indent
        c_indent=$(printf '%*s' "${#cmd_prefix}" "")
        wrapped_cmd=$(echo "$cmd" | fold -s -w "$avail_cmd_w")
        while IFS= read -r c_line; do
            local clean_c_line
            clean_c_line=$(printf '%b' "$c_line" | sed 's/\x1b\[[0-9;]*m//g')
            c_pad=$((avail_cmd_w - ${#clean_c_line}))
            [[ $c_pad -lt 0 ]] && c_pad=0
            c_padding=$(printf '%*s' "$c_pad" "")
            if [[ "$first_c" == true ]]; then
                printf "%b  %s%s%s  %b\n" "${C_RED}│${C_RESET}" "$cmd_prefix" "$c_line" "$c_padding" "${C_RED}│${C_RESET}"
                first_c=false
            else
                printf "%b  %s%s%s  %b\n" "${C_RED}│${C_RESET}" "$c_indent" "$c_line" "$c_padding" "${C_RED}│${C_RESET}"
            fi
        done <<< "$wrapped_cmd"
    else
        local cmd_pad=$((avail_w - cmd_vis_len))
        [[ $cmd_pad -lt 0 ]] && cmd_pad=0
        local cmd_padding
        cmd_padding=$(printf '%*s' "$cmd_pad" "")
        printf "%b  %s%s%s  %b\n" "${C_RED}│${C_RESET}" "$cmd_prefix" "$cmd" "$cmd_padding" "${C_RED}│${C_RESET}"
    fi

    printf "%b\n\n" "${C_RED}${box_bot}${C_RESET}"
}

# Evaluates whether a configured lock file exists and whether it is orphaned or actively held.
# Returns:
#   0 = Orphaned lock verified (lock file exists, no active process holds it)
#   1 = No lock file configured or lock file does not exist on disk
#   2 = Active lock contention (lock file exists and a process is actively using it)
_check_lock_status() {
    local lock_file="${1:-}"
    local req_cmd="${2:-}"
    [[ -z "$lock_file" || ! -e "$lock_file" ]] && return 1

    # 1. Check open file descriptors via fuser or lsof
    if command -v fuser >/dev/null 2>&1 && fuser "$lock_file" >/dev/null 2>&1; then
        return 2
    fi
    if command -v lsof >/dev/null 2>&1 && lsof "$lock_file" >/dev/null 2>&1; then
        return 2
    fi

    # 2. Check running processes via pgrep (handles existence-based locks where FD is closed)
    if command -v pgrep >/dev/null 2>&1; then
        if [[ -n "$req_cmd" ]] && pgrep -x "$req_cmd" >/dev/null 2>&1; then
            return 2
        fi
        local lock_owner
        lock_owner=$(basename "$(dirname "$lock_file")")
        case "$lock_owner" in
            ""|.|/|var|lib|run|tmp|lock|cache|etc|opt|usr|local|state|share) ;;
            *)
                if pgrep -x "$lock_owner" >/dev/null 2>&1; then
                    return 2
                fi
                ;;
        esac
    fi

    return 0
}

# Recursively terminates a process and all its descendants
_terminate_proc_tree() {
    local pid="$1"
    local sig="${2:-TERM}"
    [[ -z "$pid" ]] && return 0
    local child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        _terminate_proc_tree "$child" "$sig"
    done
    kill "-$sig" "$pid" 2>/dev/null || true
}

run_with_retry() {
    local phase="$1"; local type="$2"; local cmd="$3"; local no_interactive_flag="$4"; local interactive_flag="$5"; local override_flag="$6"
    local fallback_label="${7:-}"; local lock_file="${8:-}"; local req_cmd="${9:-}"; local stall_timeout="${10:-${STALL_TIMEOUT:-0}}"
    local original_cmd="$cmd"
    local attempts=0 max_retries=$AUTO_RETRIES force_applied=false i tmp_log="" exit_code=0 action=""
    local prev_pipefail=false
    [[ -o pipefail ]] && prev_pipefail=true
    [[ "$INFINITE_RETRIES" == true ]] && max_retries=9999

    [[ -n "$stall_timeout" && "$stall_timeout" != "0" ]] && stall_timeout=$(parse_duration "$stall_timeout")
    [[ ! "$stall_timeout" =~ ^[0-9]+$ ]] && stall_timeout=0

    local tmp_pipe="" cmd_pid="" tee_pid=""
    _cleanup_retry_proc() {
        if [[ -n "$cmd_pid" ]]; then
            _terminate_proc_tree "$cmd_pid" TERM 2>/dev/null || true
        fi
        if [[ -n "$tee_pid" ]]; then
            kill -TERM "$tee_pid" 2>/dev/null || true
        fi
        [[ -n "$tmp_pipe" && -p "$tmp_pipe" ]] && rm -f "$tmp_pipe"
        [[ -n "$tmp_log" && -f "$tmp_log" ]] && rm -f "$tmp_log"
        close_attention
    }
    trap '_cleanup_retry_proc' INT TERM RETURN

    while true; do
        ui_debug "Attempt $((attempts + 1)): $cmd"
        local was_stalled=false

        if [[ $stall_timeout -gt 0 ]]; then
            tmp_pipe=$(mktemp -u)
            mkfifo "$tmp_pipe"
            tmp_log=$(mktemp)

            tee "$tmp_log" < "$tmp_pipe" &
            tee_pid=$!

            eval "$cmd" > "$tmp_pipe" 2>&1 &
            cmd_pid=$!

            local last_size=0
            local last_time
            last_time=$(date +%s)

            while kill -0 "$cmd_pid" 2>/dev/null; do
                sleep 0.5
                local now
                now=$(date +%s)
                local cur_size
                cur_size=$(wc -c < "$tmp_log" 2>/dev/null || echo 0)
                if [[ "$cur_size" -ne "$last_size" ]]; then
                    last_size="$cur_size"
                    last_time="$now"
                else
                    local elapsed=$((now - last_time))
                    if [[ $elapsed -ge $stall_timeout ]]; then
                        request_attention "$phase appears stalled (no output for ${stall_timeout}s)."
                        if [[ ! -t 0 ]]; then
                            ui_warn "Stalled command detected in non-interactive environment (${stall_timeout}s without output). Terminating..."
                            _terminate_proc_tree "$cmd_pid" TERM
                            local k
                            for ((k=0; k<30; k++)); do
                                kill -0 "$cmd_pid" 2>/dev/null || break
                                sleep 0.1
                            done
                            if kill -0 "$cmd_pid" 2>/dev/null; then
                                _terminate_proc_tree "$cmd_pid" KILL
                            fi
                            was_stalled=true
                            exit_code=124
                            break
                        fi

                        echo -e "\n${C_BOLD}${C_YELLOW}⚠️  Command appears stalled${C_RESET}${C_YELLOW} (no output produced for ${stall_timeout}s).${C_RESET}"
                        echo -e "   ${C_CYAN}Command:${C_RESET} $cmd"
                        echo -e "\nWhat would you like to do?"
                        echo -e "  [${C_GREEN}W${C_RESET}] Wait       — Give it more time (extend timeout by ${stall_timeout}s)"
                        echo -e "  [${C_YELLOW}T${C_RESET}] Terminate  — Stop this stalled command and open the error recovery menu"
                        echo -e "  [${C_RED}A${C_RESET}] Abort      — Stop everything and exit right now\n"

                        local s_act=""
                        while true; do
                            echo -e -n "${C_BOLD}Choice [W/t/a]:${C_RESET} "
                            read -r -n 1 s_act
                            echo ""
                            case "$s_act" in
                                [Ww]|"")
                                    close_attention
                                    last_time=$(date +%s)
                                    ui_info "Extending timeout by ${stall_timeout}s..."
                                    break
                                    ;;
                                [Tt])
                                    close_attention
                                    ui_warn "Terminating stalled command..."
                                    _terminate_proc_tree "$cmd_pid" TERM
                                    local k
                                    for ((k=0; k<30; k++)); do
                                        kill -0 "$cmd_pid" 2>/dev/null || break
                                        sleep 0.1
                                    done
                                    if kill -0 "$cmd_pid" 2>/dev/null; then
                                        _terminate_proc_tree "$cmd_pid" KILL
                                    fi
                                    was_stalled=true
                                    exit_code=124
                                    break 2
                                    ;;
                                [Aa])
                                    close_attention
                                    _terminate_proc_tree "$cmd_pid" TERM
                                    sleep 0.5
                                    _terminate_proc_tree "$cmd_pid" KILL
                                    kill -TERM "$tee_pid" 2>/dev/null || true
                                    rm -f "$tmp_pipe" "$tmp_log"
                                    exit 1
                                    ;;
                                *)
                                    ui_warn "Invalid selection. Enter W (Wait), T (Terminate), or A (Abort)."
                                    ;;
                            esac
                        done
                    fi
                fi
            done

            if [[ "$was_stalled" == false ]]; then
                wait "$cmd_pid" 2>/dev/null
                exit_code=$?
            fi

            cmd_pid=""

            local tw
            for ((tw=0; tw<10; tw++)); do
                kill -0 "$tee_pid" 2>/dev/null || break
                sleep 0.05
            done
            kill -TERM "$tee_pid" 2>/dev/null || true
            wait "$tee_pid" 2>/dev/null || true
            tee_pid=""

            rm -f "$tmp_pipe"
            tmp_pipe=""
            LAST_CMD_OUTPUT=$(<"$tmp_log")
            rm -f "$tmp_log"
            tmp_log=""
        else
            set -o pipefail
            tmp_log=$(mktemp)
            eval "$cmd" 2>&1 | tee "$tmp_log"
            exit_code=$?
            LAST_CMD_OUTPUT=$(<"$tmp_log")
            rm -f "$tmp_log"
            tmp_log=""
            [[ "$prev_pipefail" == false ]] && set +o pipefail
        fi

        [[ $exit_code -eq 0 ]] && return 0

        # Evaluate lock file state (0=orphaned, 1=none, 2=active contention)
        local lock_status=1
        if _check_lock_status "$lock_file" "$req_cmd"; then
            lock_status=0
        else
            lock_status=$?
        fi

        # If interrupted by user (SIGINT/Ctrl+C), stalled, or blocked by a verified orphaned lock, skip futile auto-retries
        if [[ $exit_code -eq 130 || $exit_code -eq 124 || $lock_status -eq 0 ]]; then
            attempts=$max_retries
        fi

        # Failure Analysis
        local force_ready=false; local force_payload=""
        local override_pattern="exists in filesystem|conflicting files|trying to overwrite|dpkg: error processing|file conflicts|already exists"
        if [[ -n "$override_flag" ]]; then
            if echo "$LAST_CMD_OUTPUT" | grep -qiE "$override_pattern"; then
                force_ready=true; force_payload="$override_flag"
            fi
        fi

        # Auto-Retry Logic
        if [[ $attempts -lt $max_retries ]]; then
            ((attempts++))
            if [[ "$force_ready" == true && "$force_applied" == false ]]; then
                ui_warn "Detected conflict in $phase. Auto-applying override..."
                local op="$override_flag"
                [[ -z "$op" ]] && op="$force_payload"
                cmd="$original_cmd $op"
                force_applied=true
            else
                ui_warn "$phase failed. Retrying in 3s ($attempts/$max_retries)..."
                sleep 3
            fi
            continue
        fi

        # Escalation
        local retry_word="retries"
        [[ $attempts -eq 1 ]] && retry_word="retry"
        if [[ $exit_code -eq 130 ]]; then
            request_attention "$phase was interrupted (Ctrl+C)."
        elif [[ $exit_code -eq 124 ]]; then
            request_attention "$phase stalled (inactivity timeout)."
        else
            request_attention "$phase failed after $attempts $retry_word."
        fi

        # Escalation Box
        _render_retry_box "$phase" "$attempts" "$retry_word" "$exit_code" "$cmd"

        if [[ $lock_status -eq 0 ]]; then
            local lock_icon="[LOCK] "; [[ "$USE_EMOJI" == true ]] && lock_icon="🔓 "
            echo -e "${C_YELLOW}${lock_icon}${C_BOLD}Orphaned Lock Detected:${C_RESET}${C_YELLOW} $lock_file${C_RESET}"
            echo -e "${C_YELLOW}    Verified via process check (fuser/lsof/pgrep): no active process is holding this lock.${C_RESET}\n"
        elif [[ $lock_status -eq 2 ]]; then
            local busy_icon="[BUSY] "; [[ "$USE_EMOJI" == true ]] && busy_icon="🔒 "
            echo -e "${C_YELLOW}${busy_icon}${C_BOLD}Active Lock Contention:${C_RESET}${C_YELLOW} $lock_file is currently held by a running process.${C_RESET}"
            echo -e "${C_YELLOW}    Wait for the other package manager process to finish before choosing [R] Retry.${C_RESET}\n"
        fi

        if [[ "$type" != "checkpoint" && "$phase" != *Snapshot* && -z "$no_interactive_flag" && -z "$interactive_flag" ]]; then
            local note_icon="[!] "; [[ "$USE_EMOJI" == true ]] && note_icon="⚠️  "
            echo -e "${C_YELLOW}${note_icon}Note: No auto-confirm flag is configured for this manager.${C_RESET}"
            echo -e "${C_YELLOW}    If it stalled or failed unexpectedly, manual interaction may have been required.${C_RESET}\n"
        fi

        echo -e "What would you like to do?\n"
        if [[ $lock_status -eq 0 ]]; then
            echo -e "  [${C_GREEN}U${C_RESET}] Unlock       — Remove orphaned lock file ($lock_file) and retry."
            echo -e "                     Verified safe: no active package manager process is running."
        fi
        echo -e "  [${C_GREEN}R${C_RESET}] Retry        — Run the exact same command again."
        echo -e "                     Use this if you think it was a temporary glitch."

        local has_override=false
        local op_payload=""
        if [[ -n "$override_flag" ]]; then
            has_override=true; op_payload="$override_flag"
        elif [[ -n "$force_payload" ]]; then
            has_override=true; op_payload="$force_payload"
        fi

        if [[ "$has_override" == true ]]; then
            echo -e "  [${C_PURP}O${C_RESET}] Override     — Retry with a flag to force past file conflicts."
            echo -e "                     Use this if the error mentions \"file exists\" or \"conflicts\"."
        fi

        local has_yes_pipe=false
        if echo "$cmd" | grep -qE '^yes([[:space:]]+[^|]+)? *\|'; then
            has_yes_pipe=true
        fi

        local has_interactive=false
        if [[ -n "$no_interactive_flag" && "$no_interactive_flag" != "none" && "$cmd" == *"$no_interactive_flag"* ]]; then
            has_interactive=true
        elif [[ -n "$interactive_flag" ]]; then
            has_interactive=true
        elif [[ "$has_yes_pipe" == true ]]; then
            has_interactive=true
        fi

        if [[ "$has_interactive" == true ]]; then
            echo -e "  [${C_CYAN}I${C_RESET}] Interactive  — Retry in manual mode (you'll see every prompt)."
            echo -e "                     Use this when you want to review each change yourself."
        fi

        local has_fallback=false
        if [[ -n "$fallback_label" ]]; then
            has_fallback=true
            echo -e "  [${C_BLUE}F${C_RESET}] Fallback     — Try next available: ${C_BOLD}$fallback_label${C_RESET}."
            echo -e "                     Use this if this manager is broken and another can do the job."
        fi

        echo -e "  [${C_CYAN}E${C_RESET}] Edit         — Edit the command string before retrying."
        echo -e "                     Use this to add custom flags or modify options on the fly."
        echo -e "  [${C_YELLOW}S${C_RESET}] Skip         — Skip this phase and continue with the rest."
        echo -e "                     The update won't be applied, but nothing else is affected."
        echo -e "  [${C_RED}A${C_RESET}] Abort        — Stop everything and exit right now."
        echo -e "                     Nothing further will run.\n"

        if [[ ! -t 0 ]]; then
            close_attention
            if command -v notify-send >/dev/null 2>&1; then
                notify-send -u critical -a "advance" -i dialog-error "Advance Update Failed" "Update phase '$phase' failed in unattended mode." 2>/dev/null || true
            fi
            ui_error "Non-interactive environment: $phase failed after $attempts retries. Aborting."
            return 1
        fi

        while true; do
            echo -e -n "${C_BOLD}Choice:${C_RESET} "
            read -r -n 1 action
            echo ""
            case "$action" in
                [Uu])
                    if [[ $lock_status -eq 0 && -n "$lock_file" ]]; then
                        local recheck_status=1
                        if _check_lock_status "$lock_file" "$req_cmd"; then
                            recheck_status=0
                        else
                            recheck_status=$?
                        fi
                        if [[ $recheck_status -eq 2 ]]; then
                            ui_warn "Lock file $lock_file is now in use by an active process. Cannot remove while active."
                        elif [[ $recheck_status -eq 1 ]]; then
                            ui_info "Lock file $lock_file was already removed. Retrying..."
                            close_attention
                            attempts=0
                            break
                        else
                            ui_info "Removing orphaned lock file: $lock_file..."
                            if rm -f "$lock_file" 2>/dev/null || sudo rm -f "$lock_file"; then
                                ui_ok "Orphaned lock file removed: $lock_file"
                                close_attention
                                attempts=0
                                break
                            else
                                ui_error "Failed to remove lock file: $lock_file"
                            fi
                        fi
                    else
                        echo "Invalid choice."
                    fi ;;
                [Rr]) close_attention; attempts=0; break ;;
                [Oo])
                    if [[ "$has_override" == true ]]; then
                        cmd="$original_cmd $op_payload"
                        force_applied=true
                        close_attention
                        attempts=0
                        break
                    else
                        echo "Invalid choice."
                    fi ;;
                [Ii])
                    if [[ "$has_interactive" == true ]]; then
                        local new_cmd="$original_cmd"
                        # Strip yes pipes
                        new_cmd=$(echo "$new_cmd" | sed -E 's/^yes([[:space:]]+[^|]+)? *\| *//')
                        # Strip no_interactive_flag
                        if [[ -n "$no_interactive_flag" && "$no_interactive_flag" != "none" && "$no_interactive_flag" != *"|"* ]]; then
                            new_cmd="${new_cmd//$no_interactive_flag/}"
                        fi
                        # Add interactive_flag
                        if [[ -n "$interactive_flag" ]]; then
                            new_cmd="$new_cmd $interactive_flag"
                        fi
                        cmd=$(echo "$new_cmd" | tr -s ' ')
                        close_attention
                        attempts=0
                        break
                    else
                        echo "Invalid choice."
                    fi ;;
                [Ff])
                    if [[ "$has_fallback" == true ]]; then
                        close_attention
                        return 2  # Special: fallback requested
                    else
                        echo "Invalid choice."
                    fi ;;
                [Ee])
                    echo -e "\n${C_BOLD}Edit command below (Enter to run, Ctrl+C to cancel):${C_RESET}"
                    local custom_cmd=""
                    if read -e -r -i "$cmd" -p "> " custom_cmd; then
                        custom_cmd=$(trim "$custom_cmd")
                        if [[ -n "$custom_cmd" ]]; then
                            cmd="$custom_cmd"
                            close_attention
                            attempts=0
                            break
                        else
                            ui_warn "Command cannot be empty. Please enter a valid command or select another option."
                        fi
                    else
                        echo ""
                        ui_info "Edit cancelled."
                    fi ;;
                [Ss]) close_attention; return 1 ;;
                [Aa]) close_attention; exit 1 ;;
                *) echo "Invalid choice." ;;
            esac
        done
    done
}
