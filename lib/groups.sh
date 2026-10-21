#!/usr/bin/env bash
# ==============================================================================
# lib/groups.sh — Group resolution, priority sorting, fallback chain logic
# Part of Advance Universal System Update Manager
# ==============================================================================

# Populates run_custom[] and standby_custom[] based on REQUIRES_CMD, GROUP, PRIORITY
# Explicitly targeted managers (via -o/--only) bypass group winner-takes-all exclusion
resolve_groups() {
    local i group priority

    # Step 1: Filter by REQUIRES_CMD and PROBE_ACTIVE_CMD — skip managers whose binary isn't installed or probe fails
    for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
        [[ "${run_custom[$i]}" != true ]] && continue
        local req="${CUSTOM_REQUIRES_CMDS[$i]}"
        if [[ -n "$req" ]] && ! command -v "$req" >/dev/null 2>&1; then
            run_custom[$i]=false
            mgr_status[$i]="missing"
            continue
        fi
        local probe="${CUSTOM_PROBE_ACTIVE_CMDS[$i]}"
        if [[ -n "$probe" ]]; then
            if ! eval "$probe" >/dev/null 2>&1; then
                run_custom[$i]=false
                mgr_status[$i]="missing"
            fi
        fi
    done

    # Step 2: Apply group-level toggles from config (explicit -o overrides config)
    for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
        [[ "${run_custom[$i]}" != true ]] && continue
        [[ "${is_explicit_only[$i]}" == true ]] && continue
        group="${CUSTOM_GROUPS[$i]}"
        [[ -z "$group" ]] && continue
        local grp_enabled="${GROUP_ENABLED[$group]}"
        # Groups default to true if not explicitly set
        if [[ "$grp_enabled" == "false" ]]; then
            run_custom[$i]=false
            mgr_status[$i]="group_disabled"
        fi
    done

    # Step 3: Validate unique priorities per group (skipping explicit overrides)
    declare -A _seen_priorities
    for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
        [[ "${run_custom[$i]}" != true ]] && continue
        [[ "${is_explicit_only[$i]}" == true ]] && continue
        group="${CUSTOM_GROUPS[$i]}"
        [[ -z "$group" ]] && continue
        priority="${CUSTOM_PRIORITIES[$i]}"
        local key="${group}:${priority}"
        if [[ -n "${_seen_priorities[$key]}" ]]; then
            ui_error "Priority conflict in group '$group': '${CUSTOM_NAMES[$i]}' and '${_seen_priorities[$key]}' both have priority $priority."
            ui_error "Fix this in ~/.config/advance/managers.d/$group/ before running."
            exit 1
        fi
        _seen_priorities[$key]="${CUSTOM_NAMES[$i]}"
    done

    # Step 4: For each group, determine winner among non-explicit managers
    declare -A _group_best_priority
    declare -A _group_best_index
    for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
        [[ "${run_custom[$i]}" != true ]] && continue
        [[ "${is_explicit_only[$i]}" == true ]] && continue
        group="${CUSTOM_GROUPS[$i]}"
        [[ -z "$group" ]] && continue
        priority="${CUSTOM_PRIORITIES[$i]}"

        if [[ -z "${_group_best_priority[$group]}" ]] || [[ $priority -gt ${_group_best_priority[$group]} ]]; then
            _group_best_priority[$group]=$priority
            _group_best_index[$group]=$i
        fi
    done

    # Mark non-winners as standby (explicit -o managers always stay active)
    for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
        [[ "${run_custom[$i]}" != true ]] && continue
        if [[ "${is_explicit_only[$i]}" == true ]]; then
            mgr_status[$i]="active"
            continue
        fi
        group="${CUSTOM_GROUPS[$i]}"
        [[ -z "$group" ]] && continue

        if [[ -n "${_group_best_index[$group]}" && $i -ne ${_group_best_index[$group]} ]]; then
            run_custom[$i]=false
            standby_custom[$i]=true
            mgr_status[$i]="standby"
        else
            mgr_status[$i]="active"
        fi
    done

    # Standalone (ungrouped) managers that are enabled → active
    for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
        [[ "${run_custom[$i]}" != true ]] && continue
        [[ -z "${CUSTOM_GROUPS[$i]}" ]] && mgr_status[$i]="active"
    done
}

# Get sorted fallback chain for a group (descending priority, excluding a given index)
get_fallback_chain() {
    local exclude_idx="$1"
    local group="${CUSTOM_GROUPS[$exclude_idx]}"
    local result=()

    [[ -z "$group" ]] && return

    # Collect all standby + available managers in this group
    local indices=()
    local priorities=()
    local i
    for ((i=0; i<${#CUSTOM_NAMES[@]}; i++)); do
        [[ $i -eq $exclude_idx ]] && continue
        [[ "${CUSTOM_GROUPS[$i]}" != "$group" ]] && continue
        [[ "${standby_custom[$i]}" != true ]] && continue
        indices+=("$i")
        priorities+=("${CUSTOM_PRIORITIES[$i]}")
    done

    # Sort by priority descending (simple bubble sort for small arrays)
    local n=${#indices[@]}
    local j tmp
    for ((i=0; i<n-1; i++)); do
        for ((j=0; j<n-i-1; j++)); do
            if [[ ${priorities[$j]} -lt ${priorities[$((j+1))]} ]]; then
                tmp=${indices[$j]}; indices[$j]=${indices[$((j+1))]}; indices[$((j+1))]=$tmp
                tmp=${priorities[$j]}; priorities[$j]=${priorities[$((j+1))]}; priorities[$((j+1))]=$tmp
            fi
        done
    done

    echo "${indices[@]}"
}

# Get all discovered group names (sorted by group priority descending, then name ascending)
get_all_groups() {
    local -A _seen=()
    local i g
    for ((i=0; i<${#CUSTOM_GROUPS[@]}; i++)); do
        g="${CUSTOM_GROUPS[$i]}"
        [[ -n "$g" ]] && _seen["$g"]=1
    done
    local grps=("${!_seen[@]}")
    local n=${#grps[@]}
    local gi gj g_tmp
    for ((gi=0; gi<n-1; gi++)); do
        for ((gj=0; gj<n-gi-1; gj++)); do
            local p1 p2
            p1=$(get_group_priority "${grps[$gj]}")
            p2=$(get_group_priority "${grps[$((gj+1))]}")
            if [[ $p1 -lt $p2 || ( $p1 -eq $p2 && "${grps[$gj]}" > "${grps[$((gj+1))]}" ) ]]; then
                g_tmp=${grps[$gj]}; grps[$gj]=${grps[$((gj+1))]}; grps[$((gj+1))]=$g_tmp
            fi
        done
    done
    [[ ${#grps[@]} -gt 0 ]] && printf "%s\n" "${grps[@]}"
}
