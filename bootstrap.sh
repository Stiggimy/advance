#!/usr/bin/env bash
# Standalone public installer. Keep this usable without a working Advance CLI.
set -eu

die() {
    echo "advance: $*" >&2
    exit 1
}

network_git() {
    GIT_TERMINAL_PROMPT=0 timeout -k 2s "${SELF_UPDATE_TIMEOUT:-30s}" git -c credential.helper= "$@"
}

main() {
    local url=https://github.com/Stiggimy/advance.git
    local data_dir="${ADVANCE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/advance}"
    local checkout="$data_dir/source" launcher="$HOME/.local/bin/advance"
    local active target origin revision

    if [[ -L "$launcher" && -e "$launcher" ]]; then
        target=$(readlink -f "$launcher")
        checkout=$(dirname "$target")
        [[ "$target" == "$checkout/advance" && -e "$checkout/.git" ]] ||
            die "Existing launcher at $launcher points outside an Advance checkout."
    elif [[ -e "$launcher" ]] || active=$(type -P advance); then
        die "Found an existing installation at ${active:-$launcher}. Use its original installation method."
    fi

    mkdir -p "$data_dir"
    exec 9>"$data_dir/bootstrap.lock"
    flock -n 9 || die "Another Advance installation is in progress."
    if [[ ! -e "$checkout" && ! -L "$checkout" ]]; then
        (
            staging=$(mktemp -d "$data_dir/.clone.XXXXXXXX")
            trap 'rm -rf -- "$staging"' EXIT
            network_git clone --branch master --single-branch "$url" "$staging"
            mv -T "$staging" "$checkout"
        )
    else
        [[ -e "$checkout/.git" ]] || die "Expected a Git checkout at $checkout."
        origin=$(git -C "$checkout" config --get remote.origin.url) || die "Missing origin in $checkout."
        case "${origin%.git}" in
            https://github.com/Stiggimy/advance|git@github.com:Stiggimy/advance|ssh://git@github.com/Stiggimy/advance) ;;
            *) die "Origin in $checkout is outside the public Advance repository. Check your update channel." ;;
        esac
        [[ "$(git -C "$checkout" branch --show-current)" == master ]] ||
            die "Switch $checkout to master before running the public installer."
        git -C "$checkout" diff --quiet HEAD -- || die "Save tracked changes in $checkout before updating."
        network_git -C "$checkout" fetch --progress "$url" refs/heads/master:refs/remotes/origin/master
        revision=$(git -C "$checkout" rev-parse refs/remotes/origin/master)
        git -C "$checkout" merge-base --is-ancestor HEAD "$revision" ||
            die "Local commits in $checkout need review before updating."
        git -C "$checkout" merge --ff-only --no-overwrite-ignore "$revision"
    fi
    "$checkout/install.sh"
}

main "$@"
