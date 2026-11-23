#!/usr/bin/env bash
# Standalone public installer. Keep this usable without a working Advance CLI, git, or gh.
set -eu

die() {
    echo "advance: $*" >&2
    exit 1
}

parse_timeout_secs() {
    local raw="${1:-${SELF_UPDATE_TIMEOUT:-30s}}"
    if [[ "$raw" =~ ^([0-9]+)(\.[0-9]+)?([smh]?)$ ]]; then
        local num="${BASH_REMATCH[1]}" frac="${BASH_REMATCH[2]}" unit="${BASH_REMATCH[3]}"
        case "$unit" in
            m) num=$((num * 60)) ;;
            h) num=$((num * 3600)) ;;
        esac
        if [[ "$num" -lt 1 && -n "$frac" ]]; then num=1; fi
        [[ "$num" -lt 1 ]] && num=30
        echo "$num"
    else
        echo 30
    fi
}

download_file() {
    local url="$1" dest="$2"
    local secs
    secs=$(parse_timeout_secs "${SELF_UPDATE_TIMEOUT:-30s}")
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 --max-time "$secs" "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        if [[ "$url" == file://* ]]; then
            local src_path="${url#file://}"
            [[ -f "$src_path" ]] || die "Archive not found: $src_path"
            cp -f -- "$src_path" "$dest"
        else
            wget -q --timeout="$secs" -O "$dest" "$url"
        fi
    else
        die "Either curl or wget is required to install Advance."
    fi
}

network_git() {
    local -a cmd=(
        env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true SSH_ASKPASS=/bin/true
        SSH_ASKPASS_REQUIRE=never
        "GIT_SSH_COMMAND=${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15}"
    )
    if command -v timeout >/dev/null 2>&1; then
        cmd+=(timeout -k 2s "${SELF_UPDATE_TIMEOUT:-30s}")
    fi
    "${cmd[@]}" git -c credential.helper= "$@"
}

install_tarball() {
    local archive_url="$1" raw_url="$2" checkout="$3" data_dir="$4"
    command -v tar >/dev/null 2>&1 || die "tar is required to install Advance."
    (
        local staging extracted
        staging=$(mktemp -d "$data_dir/.install.XXXXXXXX")
        trap 'rm -rf -- "$staging"' EXIT
        download_file "$archive_url" "$staging/archive.tar.gz"
        mkdir -p "$staging/extract"
        tar -xzf "$staging/archive.tar.gz" -C "$staging/extract"
        extracted=$(find "$staging/extract" -mindepth 1 -maxdepth 1 -type d | head -n 1)
        [[ -n "$extracted" && -f "$extracted/advance" && -f "$extracted/install.sh" ]] ||
            die "Downloaded archive does not contain a valid Advance distribution."
        {
            echo "CHANNEL=public"
            echo "METHOD=tarball"
            echo "ARCHIVE_URL=$archive_url"
            echo "RAW_SCRIPT_URL=$raw_url"
        } > "$extracted/.install-channel"
        chmod +x "$extracted/advance" "$extracted/install.sh"
        [[ -f "$extracted/uninstall.sh" ]] && chmod +x "$extracted/uninstall.sh"
        [[ -f "$extracted/bootstrap.sh" ]] && chmod +x "$extracted/bootstrap.sh"

        if [[ -e "$checkout" || -L "$checkout" ]]; then
            mv -- "$checkout" "$staging/prev"
            if ! mv -T -- "$extracted" "$checkout"; then
                mv -- "$staging/prev" "$checkout" 2>/dev/null || true
                die "Failed to update $checkout; previous files were restored."
            fi
        else
            mv -T -- "$extracted" "$checkout"
        fi
    )
}

usage() {
    cat <<'EOF'
Usage: bootstrap.sh [OPTIONS]

Install, update, or repair a per-user Advance installation from the public repository.
Requires only bash, tar, and curl or wget (no git or gh required).

Options:
  -c, --with-checkpoint   Also install or repair companion Checkpoint automatically
  -C, --no-checkpoint     Skip interactive prompt to install companion Checkpoint
  -q, --quiet             Pass --quiet to install.sh
  -h, --help              Display this help and exit
EOF
}

install_checkpoint() (
    local quiet="$1"
    local cp_url="${CHECKPOINT_BOOTSTRAP_URL:-https://raw.githubusercontent.com/Stiggimy/checkpoint/master/bootstrap.sh}"
    local tmp_script
    tmp_script=$(mktemp "${TMPDIR:-/tmp}/checkpoint-bootstrap.XXXXXXXX.sh")
    trap 'rm -f -- "$tmp_script"' EXIT

    download_file "$cp_url" "$tmp_script" || die "Failed to download Checkpoint installer from $cp_url."

    if [[ "$quiet" == true ]]; then
        bash "$tmp_script" --quiet
    else
        bash "$tmp_script"
    fi
)

main() {
    local quiet=false
    local with_checkpoint=false
    local no_checkpoint=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--with-checkpoint) with_checkpoint=true; shift ;;
            -C|--no-checkpoint) no_checkpoint=true; shift ;;
            -q|--quiet) quiet=true; shift ;;
            -h|--help) usage; return 0 ;;
            *) die "Unknown option: $1 (run with --help for usage)" ;;
        esac
    done

    local git_url=https://github.com/Stiggimy/advance.git
    local archive_url="${ADVANCE_ARCHIVE_URL:-https://github.com/Stiggimy/advance/archive/refs/heads/master.tar.gz}"
    local raw_url="${ADVANCE_RAW_SCRIPT_URL:-https://raw.githubusercontent.com/Stiggimy/advance/master/advance}"
    local data_dir="${ADVANCE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/advance}"
    local checkout="$data_dir/source" launcher="$HOME/.local/bin/advance"
    local active target origin revision mode=""

    if [[ -L "$launcher" && ! -e "$launcher" ]]; then
        [[ "$quiet" == true ]] || echo "advance: replacing broken launcher symlink at $launcher..."
        rm -f -- "$launcher"
    fi

    if [[ -L "$launcher" && -e "$launcher" ]]; then
        target=$(readlink -f "$launcher")
        checkout=$(dirname "$target")
        if [[ "$target" == "$checkout/advance" && -e "$checkout/.git" ]]; then
            mode="git"
        elif [[ "$target" == "$checkout/advance" && -f "$checkout/.install-channel" ]]; then
            mode="tarball"
        else
            die "Existing launcher at $launcher points outside an Advance installation."
        fi
    elif [[ -e "$launcher" ]] || active=$(type -P advance 2>/dev/null || true); then
        if [[ -e "$launcher" || -n "${active:-}" ]]; then
            die "Found an existing installation at ${active:-$launcher}. Use its original installation method."
        fi
    fi

    mkdir -p "$data_dir"
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$data_dir/bootstrap.lock"
        flock -n 9 || die "Another Advance installation is in progress."
    fi

    if [[ -z "$mode" ]]; then
        if [[ -e "$checkout/.git" ]]; then
            mode="git"
        else
            mode="tarball"
        fi
    fi

    if [[ "$mode" == "tarball" ]]; then
        if [[ -f "$checkout/.install-channel" ]] && ! grep -qx 'CHANNEL=public' "$checkout/.install-channel" 2>/dev/null; then
            die "Channel in $checkout/.install-channel is outside the public Advance repository."
        fi
        install_tarball "$archive_url" "$raw_url" "$checkout" "$data_dir"
    else
        command -v git >/dev/null 2>&1 || die "Git is required to update the existing Git checkout at $checkout."
        [[ -e "$checkout/.git" ]] || die "Expected a Git checkout at $checkout."
        origin=$(git -C "$checkout" config --get remote.origin.url) || die "Missing origin in $checkout."
        case "${origin%.git}" in
            https://github.com/Stiggimy/advance|git@github.com:Stiggimy/advance|ssh://git@github.com/Stiggimy/advance) ;;
            *) die "Origin in $checkout is outside the public Advance repository. Check your update channel." ;;
        esac
        [[ "$(git -C "$checkout" branch --show-current)" == master ]] ||
            die "Switch $checkout to master before running the public installer (git -C \"$checkout\" checkout master)."
        git -C "$checkout" diff --quiet HEAD -- ||
            die "Save tracked changes in $checkout before updating (git -C \"$checkout\" stash push -m \"before update\")."
        network_git -C "$checkout" fetch --progress "$git_url" refs/heads/master:refs/remotes/origin/master
        revision=$(git -C "$checkout" rev-parse refs/remotes/origin/master)
        git -C "$checkout" merge-base --is-ancestor HEAD "$revision" ||
            die "Local commits in $checkout need review before updating (git -C \"$checkout\" log --oneline origin/master..HEAD)."
        git -C "$checkout" merge --ff-only --no-overwrite-ignore "$revision"
    fi

    if [[ "$quiet" == true ]]; then
        "$checkout/install.sh" --quiet
    else
        "$checkout/install.sh"
    fi
    "$launcher" --version >/dev/null

    if [[ "$with_checkpoint" == true ]]; then
        install_checkpoint "$quiet"
    elif [[ "$no_checkpoint" != true && -t 0 && -t 1 ]] && ! command -v checkpoint >/dev/null 2>&1 && [[ ! -x "$HOME/.local/bin/checkpoint" ]]; then
        echo ""
        echo -n "Install companion tool 'checkpoint' for automated pre/post update snapshots? [Y/n]: "
        local cp_choice=""
        read -r -n 1 cp_choice
        echo ""
        if [[ -z "$cp_choice" || "$cp_choice" =~ ^[Yy]$ ]]; then
            install_checkpoint "$quiet"
        fi
    fi
}

main "$@"
