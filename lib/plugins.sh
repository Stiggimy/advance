#!/usr/bin/env bash
# ==============================================================================
# lib/plugins.sh — Package manager plugin loader, schema parser, persistence
# Part of Advance Universal System Update Manager
# ==============================================================================

# CUSTOM_DIR and OVERRIDES_DIR are resolved by lib/xdg.sh

# Resolves official catalog directory
get_catalog_dir() {
    if [[ -n "${CATALOG_DIR:-}" && -d "${CATALOG_DIR:-}" ]]; then
        echo "$CATALOG_DIR"
    elif [[ -n "${SOURCE_DIR:-}" && -d "${SOURCE_DIR:-}/catalog/managers" ]]; then
        echo "$SOURCE_DIR/catalog/managers"
    elif [[ -d "$ADVANCE_DATA_DIR/catalog/managers" ]]; then
        echo "$ADVANCE_DATA_DIR/catalog/managers"
    elif [[ -d "$HOME/.local/share/advance/catalog/managers" ]]; then
        echo "$HOME/.local/share/advance/catalog/managers"
    elif [[ -d "$HOME/.local/lib/advance/catalog/managers" ]]; then
        echo "$HOME/.local/lib/advance/catalog/managers"
    elif [[ -d "/usr/share/advance/catalog/managers" ]]; then
        echo "/usr/share/advance/catalog/managers"
    elif [[ -d "/usr/lib/advance/catalog/managers" ]]; then
        echo "/usr/lib/advance/catalog/managers"
    else
        echo ""
    fi
}

# Two-stage prober: returns 0=active, 1=binary missing, 2=semantic probe failed
probe_manager() {
    local conf="$1"
    [[ ! -f "$conf" ]] && return 1

    local req="" probe_cmd=""
    while IFS='=' read -r key val || [[ -n "$key" ]]; do
        key="${key#"${key%%[![:space:]]*}"}"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        key="${key%$'\r'}"; val="${val%$'\r'}"
        case "$key" in
            REQUIRES_CMD) req="$val" ;;
            PROBE_ACTIVE_CMD) probe_cmd="$val" ;;
        esac
    done < "$conf"

    # Stage 1: Binary check
    if [[ -n "$req" ]] && ! command -v "$req" >/dev/null 2>&1; then
        return 1
    fi

    # Stage 2: Semantic state check (if defined)
    if [[ -n "$probe_cmd" ]]; then
        if ! eval "$probe_cmd" >/dev/null 2>&1; then
            return 2
        fi
    fi

    return 0
}

# Auto-enroll catalog managers whose binaries and probes succeed
auto_enroll_catalog() {
    local quiet="${1:-false}"
    local cat_dir
    cat_dir=$(get_catalog_dir)
    [[ -z "$cat_dir" || ! -d "$cat_dir" ]] && return 0

    local enrolled=0
    mkdir -p "$CUSTOM_DIR"

    while IFS= read -r conf; do
        [[ ! -f "$conf" ]] && continue
        local fname="${conf##*/}"
        local gname
        gname=$(basename "$(dirname "$conf")")
        [[ "$gname" == "managers" ]] && gname=""

        local target
        if [[ -n "$gname" ]]; then
            target="$CUSTOM_DIR/$gname/$fname"
        else
            target="$CUSTOM_DIR/$fname"
        fi

        if [[ -e "$target" ]]; then
            continue
        fi

        if probe_manager "$conf"; then
            mkdir -p "$(dirname "$target")"
            ln -sf "$conf" "$target"
            local mname
            mname=$(grep '^NAME=' "$conf" 2>/dev/null | head -n 1 | cut -d'=' -f2-)
            [[ "$quiet" != true ]] && ui_ok "Enrolled: ${mname:-$fname} ($gname) [symlinked to catalog]"
            ((enrolled++))
        fi
    done < <(find "$cat_dir" -type f -name "*.conf")

    return 0
}

# Detect newly installed tools from the catalog using the XDG cache probe file
check_catalog_drift() {
    local cat_dir
    cat_dir=$(get_catalog_dir)
    [[ -z "$cat_dir" || ! -d "$cat_dir" ]] && return 0
    local probe_file="$PROBE_CACHE_FILE"
    mkdir -p "$(dirname "$probe_file")"

    # If first run, record all currently active managers so we don't spam
    if [[ ! -f "$probe_file" ]]; then
        local initial_probed=()
        while IFS= read -r conf; do
            [[ ! -f "$conf" ]] && continue
            if probe_manager "$conf"; then
                initial_probed+=("${conf##*/}")
            fi
        done < <(find "$cat_dir" -type f -name "*.conf")
        printf "%s\n" "${initial_probed[@]}" > "$probe_file"
        return 0
    fi

    local newly_enrolled=()
    local current_probed=()
    while IFS= read -r conf; do
        [[ ! -f "$conf" ]] && continue
        local fname="${conf##*/}"
        local gname
        gname=$(basename "$(dirname "$conf")")
        [[ "$gname" == "managers" ]] && gname=""
        local target="$CUSTOM_DIR/$gname/$fname"
        [[ -z "$gname" ]] && target="$CUSTOM_DIR/$fname"

        if probe_manager "$conf"; then
            current_probed+=("$fname")
            # If not yet recorded in probe_file and not already enrolled
            if ! grep -q -x "$fname" "$probe_file" 2>/dev/null && [[ ! -e "$target" ]]; then
                local mname
                mname=$(grep '^NAME=' "$conf" 2>/dev/null | head -1 | cut -d'=' -f2-)

                # Auto-enroll newly detected manager automagically
                mkdir -p "$(dirname "$target")"
                ln -sf "$conf" "$target"
                newly_enrolled+=("${mname:-$fname}${gname:+ ($gname)}")
            fi
        fi
    done < <(find "$cat_dir" -type f -name "*.conf")

    if [[ ${#newly_enrolled[@]} -gt 0 ]]; then
        ui_ok "Auto-enrolled newly detected package manager(s): ${newly_enrolled[*]}"
    fi

    # Persist probe history so tools are never re-enrolled after being seen or unenrolled
    local -A all_seen=()
    if [[ -f "$probe_file" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && all_seen["$line"]=1
        done < "$probe_file"
    fi
    local item
    for item in "${current_probed[@]}"; do
        all_seen["$item"]=1
    done
    printf "%s\n" "${!all_seen[@]}" > "$probe_file"
}

# Plugin schema arrays
CUSTOM_NAMES=()
CUSTOM_EMOJIS=()
CUSTOM_CHECKS=()
CUSTOM_UPDATES=()
CUSTOM_FLAGS=()
CUSTOM_AUTO_CONFIRMS=()
CUSTOM_FLAGS_AUTO_CONFIRMS=()
CUSTOM_FLAGS_INTERACTIVES=()
CUSTOM_FLAGS_OVERRIDES=()
CUSTOM_COLOR_FLAGS=()
CUSTOM_EXCLUDE_FLAGS=()
CUSTOM_EXCLUDE_JOINS=()
CUSTOM_EXCLUDE_HOLD_CMDS=()
CUSTOM_EXCLUDE_UNHOLD_CMDS=()
CUSTOM_CHECK_UPDATES_EXIT_CODES=()
CUSTOM_CHECK_FILTER_PATTERNS=()
CUSTOM_CHECK_TIMEOUT_FALLBACKS=()
CUSTOM_POST_MSG_IDS=()
CUSTOM_POST_MSGS=()
CUSTOM_CHECK_DEP_BINS=()
CUSTOM_CHECK_DEP_INSTALLS=()
CUSTOM_ENABLEDS=()
CUSTOM_FILES=()
CUSTOM_REQUIRES_CMDS=()
CUSTOM_PRIORITIES=()
CUSTOM_GROUPS=()
CUSTOM_PROBE_ACTIVE_CMDS=()

_load_single_conf() {
    local conf="$1"
    local group="$2"
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
            FLAGS) flags="$value" ;;
            AUTO_CONFIRM) auto_confirm="$value" ;;
            FLAGS_AUTO_CONFIRM) flags_auto_confirm="$value" ;;
            FLAGS_INTERACTIVE) flags_interactive="$value" ;;
            FLAGS_OVERRIDE) flags_override="$value" ;;
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

    # Tier 3: Apply drop-in overrides if present ($XDG_CONFIG_HOME/advance/overrides.d/<mgr>.conf)
    local base="${conf##*/}"
    base="${base%.conf}"
    local override_file="$OVERRIDES_DIR/$base.conf"
    [[ ! -f "$override_file" && -n "$group" ]] && override_file="$OVERRIDES_DIR/$group/$base.conf"

    if [[ -f "$override_file" ]]; then
        while IFS='=' read -r okey ovalue || [[ -n "$okey" ]]; do
            [[ -z "$okey" || "$okey" == \#* ]] && continue
            okey="${okey#"${okey%%[![:space:]]*}"}"; okey="${okey%"${okey##*[![:space:]]}"}"
            ovalue="${ovalue#"${ovalue%%[![:space:]]*}"}"; ovalue="${ovalue%"${ovalue##*[![:space:]]}"}"
            okey="${okey%$'\r'}"; ovalue="${ovalue%$'\r'}"
            case "$okey" in
                NAME) name="$ovalue" ;;
                EMOJI) emoji="$ovalue" ;;
                CHECK_CMD) check_cmd="$ovalue" ;;
                UPDATE_CMD) update_cmd="$ovalue" ;;
                FLAGS) flags="$ovalue" ;;
                AUTO_CONFIRM) auto_confirm="$ovalue" ;;
                FLAGS_AUTO_CONFIRM) flags_auto_confirm="$ovalue" ;;
                FLAGS_INTERACTIVE) flags_interactive="$ovalue" ;;
                FLAGS_OVERRIDE) flags_override="$ovalue" ;;
                COLOR_FLAG) color_flag="$ovalue" ;;
                EXCLUDE_FLAG) exclude_flag="$ovalue" ;;
                EXCLUDE_JOIN)
                    if [[ "$ovalue" == "space" ]]; then
                        exclude_join="space"
                    else
                        exclude_join="$ovalue"
                    fi
                    ;;
                EXCLUDE_HOLD_CMD) exclude_hold_cmd="$ovalue" ;;
                EXCLUDE_UNHOLD_CMD) exclude_unhold_cmd="$ovalue" ;;
                CHECK_UPDATES_EXIT_CODE) check_exit_code="$ovalue" ;;
                CHECK_FILTER_PATTERN) check_filter="$ovalue" ;;
                CHECK_TIMEOUT_FALLBACK) check_timeout_fb="$ovalue" ;;
                POST_UPDATE_MSG_ID) post_update_msg_id="$ovalue" ;;
                POST_UPDATE_MSG) post_update_msg="$ovalue" ;;
                CHECK_DEP_BIN) check_dep_bin="$ovalue" ;;
                CHECK_DEP_INSTALL_CMD) check_dep_cmd="$ovalue" ;;
                ENABLED) enabled="$ovalue" ;;
                REQUIRES_CMD) requires_cmd="$ovalue" ;;
                PRIORITY) priority="$ovalue" ;;
                PROBE_ACTIVE_CMD) probe_cmd="$ovalue" ;;
            esac
        done < "$override_file"
    fi

    check_cmd="${check_cmd// --color=always/}"

    if [[ -z "$name" ]]; then
        local bname="${conf##*/}"
        name="${bname%.conf}"
    fi
    [[ -z "$enabled" ]] && enabled="true"

    # Validation: FLAGS_AUTO_CONFIRM and FLAGS_INTERACTIVE mutual exclusivity
    if [[ -n "$flags_auto_confirm" && -n "$flags_interactive" ]]; then
        local bname="${conf##*/}"
        ui_error "Error in $bname: FLAGS_AUTO_CONFIRM and FLAGS_INTERACTIVE cannot both be set. Disabling manager."
        enabled="false"
    fi

    CUSTOM_NAMES+=("$name")
    CUSTOM_EMOJIS+=("$emoji")
    CUSTOM_CHECKS+=("$check_cmd")
    CUSTOM_UPDATES+=("$update_cmd")
    CUSTOM_FLAGS+=("$flags")
    CUSTOM_AUTO_CONFIRMS+=("$auto_confirm")
    CUSTOM_FLAGS_AUTO_CONFIRMS+=("$flags_auto_confirm")
    CUSTOM_FLAGS_INTERACTIVES+=("$flags_interactive")
    CUSTOM_FLAGS_OVERRIDES+=("$flags_override")
    CUSTOM_COLOR_FLAGS+=("$color_flag")
    CUSTOM_EXCLUDE_FLAGS+=("$exclude_flag")
    CUSTOM_EXCLUDE_JOINS+=("${exclude_join:-,}")
    CUSTOM_EXCLUDE_HOLD_CMDS+=("$exclude_hold_cmd")
    CUSTOM_EXCLUDE_UNHOLD_CMDS+=("$exclude_unhold_cmd")
    CUSTOM_CHECK_UPDATES_EXIT_CODES+=("$check_exit_code")
    CUSTOM_CHECK_FILTER_PATTERNS+=("$check_filter")
    CUSTOM_CHECK_TIMEOUT_FALLBACKS+=("$check_timeout_fb")
    CUSTOM_POST_MSG_IDS+=("$post_update_msg_id")
    CUSTOM_POST_MSGS+=("$post_update_msg")
    CUSTOM_CHECK_DEP_BINS+=("$check_dep_bin")
    CUSTOM_CHECK_DEP_INSTALLS+=("$check_dep_cmd")
    CUSTOM_ENABLEDS+=("$enabled")
    CUSTOM_FILES+=("$conf")
    CUSTOM_REQUIRES_CMDS+=("$requires_cmd")
    CUSTOM_PRIORITIES+=("$priority")
    CUSTOM_GROUPS+=("$group")
    CUSTOM_PROBE_ACTIVE_CMDS+=("$probe_cmd")
}

load_custom_managers() {
    CUSTOM_NAMES=()
    CUSTOM_EMOJIS=()
    CUSTOM_CHECKS=()
    CUSTOM_UPDATES=()
    CUSTOM_FLAGS=()
    CUSTOM_AUTO_CONFIRMS=()
    CUSTOM_FLAGS_AUTO_CONFIRMS=()
    CUSTOM_FLAGS_INTERACTIVES=()
    CUSTOM_FLAGS_OVERRIDES=()
    CUSTOM_COLOR_FLAGS=()
    CUSTOM_EXCLUDE_FLAGS=()
    CUSTOM_EXCLUDE_JOINS=()
    CUSTOM_EXCLUDE_HOLD_CMDS=()
    CUSTOM_EXCLUDE_UNHOLD_CMDS=()
    CUSTOM_CHECK_UPDATES_EXIT_CODES=()
    CUSTOM_CHECK_FILTER_PATTERNS=()
    CUSTOM_CHECK_TIMEOUT_FALLBACKS=()
    CUSTOM_POST_MSG_IDS=()
    CUSTOM_POST_MSGS=()
    CUSTOM_CHECK_DEP_BINS=()
    CUSTOM_CHECK_DEP_INSTALLS=()
    CUSTOM_ENABLEDS=()
    CUSTOM_FILES=()
    CUSTOM_REQUIRES_CMDS=()
    CUSTOM_PRIORITIES=()
    CUSTOM_GROUPS=()
    CUSTOM_PROBE_ACTIVE_CMDS=()

    [[ ! -d "$CUSTOM_DIR" ]] && mkdir -p "$CUSTOM_DIR"

    # If managers directory has no configs at all, run auto-enrollment from catalog
    if ! find "$CUSTOM_DIR" -name "*.conf" 2>/dev/null | grep -q .; then
        auto_enroll_catalog true
    elif [[ "${CATALOG_DRIFT_CHECKED:-false}" != true ]]; then
        check_catalog_drift
        CATALOG_DRIFT_CHECKED=true
    fi

    # Discover grouped manager directories and get group execution priority
    local group_dirs=()
    local group_names=()
    local group_priorities=()
    local group_dir
    for group_dir in "$CUSTOM_DIR"/*/; do
        [[ ! -d "$group_dir" ]] && continue
        local group_name="${group_dir%/}"
        group_name="${group_name##*/}"
        local g_pri
        g_pri=$(get_group_priority "$group_name")
        group_dirs+=("$group_dir")
        group_names+=("$group_name")
        group_priorities+=("$g_pri")
    done

    # Sort groups by PRIORITY descending, then group name ascending
    local n_groups=${#group_dirs[@]}
    local gi gj g_tmp
    for ((gi=0; gi<n_groups-1; gi++)); do
        for ((gj=0; gj<n_groups-gi-1; gj++)); do
            if [[ ${group_priorities[$gj]} -lt ${group_priorities[$((gj+1))]} || ( ${group_priorities[$gj]} -eq ${group_priorities[$((gj+1))]} && "${group_names[$gj]}" > "${group_names[$((gj+1))]}" ) ]]; then
                g_tmp=${group_priorities[$gj]}; group_priorities[$gj]=${group_priorities[$((gj+1))]}; group_priorities[$((gj+1))]=$g_tmp
                g_tmp=${group_dirs[$gj]}; group_dirs[$gj]=${group_dirs[$((gj+1))]}; group_dirs[$((gj+1))]=$g_tmp
                g_tmp=${group_names[$gj]}; group_names[$gj]=${group_names[$((gj+1))]}; group_names[$((gj+1))]=$g_tmp
            fi
        done
    done

    # Load from subdirectories in priority order
    for ((gi=0; gi<n_groups; gi++)); do
        local g_dir="${group_dirs[$gi]}"
        local g_name="${group_names[$gi]}"
        local conf
        for conf in "$g_dir"*.conf; do
            [[ ! -f "$conf" ]] && continue
            [[ "${conf##*/}" == "group.conf" ]] && continue
            _load_single_conf "$conf" "$g_name"
        done
    done

    # Load loose files in root (standalone/ungrouped managers)
    local conf
    for conf in "$CUSTOM_DIR"/*.conf; do
        [[ ! -f "$conf" ]] && continue
        [[ "${conf##*/}" == "group.conf" ]] && continue
        _load_single_conf "$conf" ""
    done
}

save_custom_manager() {
    local name="${1:-}"; local emoji="${2:-}"; local check_cmd="${3:-}"; local update_cmd="${4:-}"
    local flags_auto_confirm="${5:-}"; local flags_interactive="${6:-}"; local flags_override="${7:-}"
    local enabled="${8:-true}"; local conf_file="${9:-}"
    local requires_cmd="${10:-}"; local priority="${11:-0}"
    local flags="${12:-}"; local auto_confirm="${13:-}"
    local color_flag="${14:-}"
    local exclude_flag="${15:-}"; local exclude_join="${16:-}"
    local exclude_hold_cmd="${17:-}"; local exclude_unhold_cmd="${18:-}"
    local check_exit_code="${19:-}"; local check_filter="${20:-}"; local check_timeout_fb="${21:-}"
    local post_update_msg_id="${22:-}"; local post_update_msg="${23:-}"
    local check_dep_bin="${24:-}"; local check_dep_cmd="${25:-}"
    local probe_cmd="${26:-}"

    if [[ -z "$conf_file" ]]; then
        conf_file="$CUSTOM_DIR/${name// /_}.conf"
    fi

    # If saving to an existing symlink (e.g. from catalog), replace it with a regular file
    if [[ -L "$conf_file" ]]; then
        rm -f "$conf_file"
    fi

    local safe_exclude_join="${exclude_join:-,}"
    [[ "$safe_exclude_join" == " " ]] && safe_exclude_join="space"

    mkdir -p "$(dirname "$conf_file")"
    cat <<EOF > "$conf_file"
NAME=$name
EMOJI=$emoji
REQUIRES_CMD=$requires_cmd
PRIORITY=$priority
CHECK_CMD=$check_cmd
UPDATE_CMD=$update_cmd
FLAGS=$flags
AUTO_CONFIRM=$auto_confirm
FLAGS_AUTO_CONFIRM=$flags_auto_confirm
FLAGS_INTERACTIVE=$flags_interactive
FLAGS_OVERRIDE=$flags_override
COLOR_FLAG=$color_flag
EXCLUDE_FLAG=$exclude_flag
EXCLUDE_JOIN=$safe_exclude_join
EXCLUDE_HOLD_CMD=$exclude_hold_cmd
EXCLUDE_UNHOLD_CMD=$exclude_unhold_cmd
CHECK_UPDATES_EXIT_CODE=$check_exit_code
CHECK_FILTER_PATTERN=$check_filter
CHECK_TIMEOUT_FALLBACK=$check_timeout_fb
EOF
    [[ -n "$check_dep_bin" ]] && echo "CHECK_DEP_BIN=$check_dep_bin" >> "$conf_file"
    [[ -n "$check_dep_cmd" ]] && echo "CHECK_DEP_INSTALL_CMD=$check_dep_cmd" >> "$conf_file"
    [[ -n "$post_update_msg_id" ]] && echo "POST_UPDATE_MSG_ID=$post_update_msg_id" >> "$conf_file"
    [[ -n "$post_update_msg" ]] && echo "POST_UPDATE_MSG=$post_update_msg" >> "$conf_file"
    echo "ENABLED=$enabled" >> "$conf_file"
    [[ -n "$probe_cmd" ]] && echo "PROBE_ACTIVE_CMD=$probe_cmd" >> "$conf_file"
    return 0
}
