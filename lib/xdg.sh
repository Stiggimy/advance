#!/usr/bin/env bash
# ==============================================================================
# lib/xdg.sh — XDG Base Directory resolution and Advance path definitions
# Part of Advance Universal System Update Manager
# ==============================================================================

# XDG Base Directory defaults (https://specifications.freedesktop.org/basedir-spec/)
: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_DATA_HOME:=$HOME/.local/share}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"
: "${XDG_CACHE_HOME:=$HOME/.cache}"
export XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME

# Advance-specific directories. Every location can be overridden independently
# with the corresponding ADVANCE_* environment variable.
_migrate_config=true
_migrate_data=true
_migrate_cache=true
_migrate_state=true
if [[ -n "${ADVANCE_CONFIG_DIR:-}" ]]; then _migrate_config=false; fi
if [[ -n "${ADVANCE_DATA_DIR:-}" ]]; then _migrate_data=false; fi
if [[ -n "${ADVANCE_CACHE_DIR:-}" ]]; then _migrate_cache=false; fi
if [[ -n "${ADVANCE_STATE_DIR:-}" ]]; then _migrate_state=false; fi

ADVANCE_CONFIG_DIR="${ADVANCE_CONFIG_DIR:-$XDG_CONFIG_HOME/advance}"
ADVANCE_DATA_DIR="${ADVANCE_DATA_DIR:-$XDG_DATA_HOME/advance}"
ADVANCE_STATE_DIR="${ADVANCE_STATE_DIR:-$XDG_STATE_HOME/advance}"
ADVANCE_CACHE_DIR="${ADVANCE_CACHE_DIR:-$XDG_CACHE_HOME/advance}"

# One-time migration for users who set XDG_CONFIG_HOME/XDG_DATA_HOME/
# XDG_CACHE_HOME after using the old hardcoded paths. We never overwrite an
# existing destination directory, and explicit ADVANCE_* overrides opt out.
_migrate_legacy_dir() {
    local legacy="$1" new="$2" label="$3"
    if [[ "$legacy" == "$new" || -e "$new" || ! -e "$legacy" ]]; then
        return 0
    fi
    mkdir -p "$(dirname "$new")" 2>/dev/null || return 0
    if mv "$legacy" "$new" 2>/dev/null; then
        printf 'advance: migrated %s from %s to %s\n' "$label" "$legacy" "$new" >&2
    fi
}

if [[ "$_migrate_config" == true ]]; then _migrate_legacy_dir "$HOME/.config/advance" "$ADVANCE_CONFIG_DIR" "configuration"; fi
if [[ "$_migrate_data" == true ]]; then _migrate_legacy_dir "$HOME/.local/share/advance" "$ADVANCE_DATA_DIR" "data"; fi
if [[ "$_migrate_cache" == true ]]; then _migrate_legacy_dir "$HOME/.cache/advance" "$ADVANCE_CACHE_DIR" "cache"; fi

# Migrate the old dismissed-messages state file out of the config directory.
if [[ "$_migrate_state" == true && ! -f "$ADVANCE_STATE_DIR/dismissed_messages" && -f "$ADVANCE_CONFIG_DIR/.dismissed_messages" ]]; then
    mkdir -p "$ADVANCE_STATE_DIR" 2>/dev/null || true
    mv "$ADVANCE_CONFIG_DIR/.dismissed_messages" "$ADVANCE_STATE_DIR/dismissed_messages" 2>/dev/null || true
fi
unset _migrate_config _migrate_data _migrate_cache _migrate_state

CONFIG_FILE="$ADVANCE_CONFIG_DIR/config"
EXCLUDES_FILE="$ADVANCE_CONFIG_DIR/excludes"
CUSTOM_DIR="$ADVANCE_CONFIG_DIR/managers.d"
OVERRIDES_DIR="$ADVANCE_CONFIG_DIR/overrides.d"
DISMISSED_FILE="$ADVANCE_STATE_DIR/dismissed_messages"
PROBE_CACHE_FILE="$ADVANCE_CACHE_DIR/catalog.probed"

# Print a path with $HOME shortened to ~ for user-facing messages.
tilde_path() {
    local p="$1"
    printf '%s\n' "${p/#$HOME/~}"
}
