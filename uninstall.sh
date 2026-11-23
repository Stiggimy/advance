#!/usr/bin/env bash
# Per-user Advance uninstaller. Preserves system packages, snapshots, and user config by default.
set -euo pipefail

main() {
    local purge=false
    local keep_config=false
    local yes=false
    local dry_run=false
    local quiet=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--purge) purge=true; shift ;;
            -k|--keep-config) keep_config=true; shift ;;
            -y|--yes) yes=true; shift ;;
            -n|--dry-run) dry_run=true; shift ;;
            -q|--quiet) quiet=true; shift ;;
            -h|--help)
                cat <<'EOF'
Usage: advance uninstall [OPTIONS]
   or: ./uninstall.sh [OPTIONS]

Remove a per-user Advance installation from ~/.local.
System packages and snapshots are never modified.

Options:
  -p, --purge         Also remove configuration, custom managers, and state (~/.config/advance)
  -k, --keep-config   Keep configuration directory without prompting
  -y, --yes           Skip confirmation prompts (preserves config unless --purge is passed)
  -n, --dry-run       Show what would be removed without making any changes
  -q, --quiet         Suppress informational output
  -h, --help          Display this help and exit
EOF
                return 0
                ;;
            *)
                echo "advance uninstall: unknown option: $1" >&2
                echo "Run 'advance uninstall --help' for usage." >&2
                return 1
                ;;
        esac
    done

    if [[ "$purge" == true && "$keep_config" == true ]]; then
        echo "advance uninstall: --purge and --keep-config cannot be used together." >&2
        return 1
    fi

    local xdg_config="${XDG_CONFIG_HOME:-$HOME/.config}"
    local xdg_data="${XDG_DATA_HOME:-$HOME/.local/share}"
    local xdg_state="${XDG_STATE_HOME:-$HOME/.local/state}"
    local xdg_cache="${XDG_CACHE_HOME:-$HOME/.cache}"

    local bin_path="$HOME/.local/bin/advance"
    local ship_bin_path="$HOME/.local/bin/ship"
    local data_dir="${ADVANCE_DATA_DIR:-$xdg_data/advance}"
    local legacy_lib_dir="$HOME/.local/lib/advance"
    local man_file="$xdg_data/man/man1/advance.1"
    local legacy_man_file="$HOME/.local/share/man/man1/advance.1"
    local config_dir="${ADVANCE_CONFIG_DIR:-$xdg_config/advance}"
    local state_dir="${ADVANCE_STATE_DIR:-$xdg_state/advance}"
    local cache_dir="${ADVANCE_CACHE_DIR:-$xdg_cache/advance}"
    local systemd_dir="$xdg_config/systemd/user"
    local timer_file="$systemd_dir/advance-update.timer"
    local service_file="$systemd_dir/advance-update.service"

    log() {
        [[ "$quiet" == true ]] || echo "$*"
    }

    rm_target() {
        local target="$1"
        local label="$2"
        if [[ -e "$target" || -L "$target" ]]; then
            if [[ "$dry_run" == true ]]; then
                log "  [DRY-RUN] Would remove $label: $target"
            else
                rm -rf -- "$target"
                log "  [REMOVE] $label: $target"
            fi
        fi
    }

    # Refuse to run if only a system-wide package-managed copy is present.
    if [[ ! -e "$bin_path" && ! -L "$bin_path" && ! -e "$data_dir" && ! -L "$data_dir" && ! -e "$legacy_lib_dir" && ! -L "$legacy_lib_dir" ]]; then
        local active=""
        active=$(type -P advance 2>/dev/null || true)
        if [[ -n "$active" && "$active" != "$bin_path" ]]; then
            echo "advance uninstall: found a system-wide installation at $active." >&2
            echo "Remove it with your system package manager instead (for example: sudo pacman -R advance-git)." >&2
            return 1
        fi
        log "Advance does not appear to be installed for user $USER."
        return 0
    fi

    # Resolve linked source checkout before removing the launcher symlink.
    local resolved_bin="" source_dir=""
    if [[ -L "$bin_path" && -e "$bin_path" ]]; then
        resolved_bin=$(readlink -f "$bin_path" 2>/dev/null || true)
        if [[ -n "$resolved_bin" ]]; then
            source_dir=$(dirname "$resolved_bin")
        fi
    fi

    if [[ "$dry_run" != true && "$yes" != true && -t 0 && -t 1 ]]; then
        echo -n "Remove per-user Advance installation from ~/.local? [y/N]: "
        local confirm=""
        read -r -n 1 confirm
        echo ""
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log "Uninstall cancelled."
            return 0
        fi
    fi

    log ">>> Uninstalling Advance..."

    if [[ -f "$timer_file" || -f "$service_file" ]]; then
        if [[ "$dry_run" == true ]]; then
            [[ -f "$timer_file" ]] && log "  [DRY-RUN] Would disable and remove systemd timer: $timer_file"
            [[ -f "$service_file" ]] && log "  [DRY-RUN] Would remove systemd service: $service_file"
        else
            if command -v systemctl >/dev/null 2>&1; then
                systemctl --user disable --now advance-update.timer >/dev/null 2>&1 || true
            fi
            rm_target "$timer_file" "systemd timer"
            rm_target "$service_file" "systemd service"
            if command -v systemctl >/dev/null 2>&1; then
                systemctl --user daemon-reload >/dev/null 2>&1 || true
            fi
        fi
    fi

    if [[ -L "$bin_path" ]]; then
        rm_target "$bin_path" "binary symlink"
    elif [[ -f "$bin_path" ]] && grep -qE 'Advance|do_update' "$bin_path" 2>/dev/null; then
        rm_target "$bin_path" "binary"
    fi

    if [[ -L "$ship_bin_path" ]]; then
        local ship_target=""
        ship_target=$(readlink -f "$ship_bin_path" 2>/dev/null || true)
        if [[ -n "$source_dir" && "$ship_target" == "$source_dir/ship.sh" ]]; then
            rm_target "$ship_bin_path" "ship symlink"
        fi
    fi

    rm_target "$data_dir/lib" "libraries"
    rm_target "$legacy_lib_dir" "legacy library symlink"
    rm_target "$data_dir/catalog" "catalog"
    rm_target "$data_dir/CHANGELOG.md" "changelog"
    rm_target "$data_dir/bootstrap.lock" "bootstrap lock"
    rm_target "$man_file" "manual page"
    if [[ "$legacy_man_file" != "$man_file" ]]; then
        rm_target "$legacy_man_file" "legacy manual page"
    fi
    rm_target "$cache_dir" "cache"

    # Decide configuration disposition.
    local remove_config=false
    if [[ "$purge" == true ]]; then
        if [[ "$dry_run" == true || "$yes" == true || ! -t 0 || ! -t 1 ]]; then
            remove_config=true
        else
            echo -n "Also remove configuration, custom managers, and state in $config_dir? [y/N]: "
            local purge_confirm=""
            read -r -n 1 purge_confirm
            echo ""
            [[ "$purge_confirm" =~ ^[Yy]$ ]] && remove_config=true
        fi
    elif [[ "$keep_config" != true && -d "$config_dir" && "$dry_run" != true && "$yes" != true && -t 0 && -t 1 ]]; then
        echo -n "Also remove configuration, custom managers, and state in $config_dir? [y/N]: "
        local cfg_confirm=""
        read -r -n 1 cfg_confirm
        echo ""
        [[ "$cfg_confirm" =~ ^[Yy]$ ]] && remove_config=true
    fi

    if [[ "$remove_config" == true ]]; then
        rm_target "$config_dir" "configuration"
        rm_target "$state_dir" "state"
    elif [[ -d "$config_dir" ]]; then
        # Clean managed catalog symlinks in managers.d while preserving custom files & overrides.
        local managers_dir="$config_dir/managers.d"
        if [[ -d "$managers_dir" ]]; then
            local entry link_target parent_dir
            while IFS= read -r entry; do
                [[ -L "$entry" ]] || continue
                link_target=$(readlink "$entry" 2>/dev/null || true)
                if [[ "$link_target" == "$data_dir/catalog/"* || ( -n "$source_dir" && "$link_target" == "$source_dir/catalog/"* ) ]]; then
                    rm_target "$entry" "enrolled catalog symlink"
                    if [[ "$dry_run" != true ]]; then
                        parent_dir=$(dirname "$entry")
                        rmdir "$parent_dir" 2>/dev/null || true
                    fi
                fi
            done < <(find "$managers_dir" -type l -name '*.conf' 2>/dev/null)
            if [[ "$dry_run" != true ]]; then
                rmdir "$managers_dir" 2>/dev/null || true
            fi
        fi
        log "  [KEEP] Configuration preserved at $config_dir (pass --purge to remove)."
    fi

    # Remove managed source checkout last so self-invocation stays intact.
    if [[ -e "$data_dir/source" || -L "$data_dir/source" ]]; then
        rm_target "$data_dir/source" "managed source checkout"
    fi

    if [[ "$dry_run" != true && -d "$data_dir" ]]; then
        rmdir "$data_dir" 2>/dev/null || true
    fi

    if [[ -n "$source_dir" && "$source_dir" != "$data_dir/source" && -d "$source_dir" ]]; then
        log "  [KEEP] Source repository at $source_dir was preserved."
    fi

    log "Note: Your system packages and snapshots were NOT modified."
    if command -v checkpoint >/dev/null 2>&1 || [[ -L "$HOME/.local/bin/checkpoint" ]]; then
        log "Checkpoint is still installed separately (run 'checkpoint uninstall' to remove it too)."
    fi
    if [[ "$dry_run" == true ]]; then
        log "[DRY-RUN] No files were modified."
    else
        log "[OK] Advance uninstalled."
    fi
}

main "$@"
