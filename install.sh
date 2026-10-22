#!/usr/bin/env bash
set -e

# --- advance Installer (per-user, XDG-aware) ---
#
# Installs into the XDG base directories when they are set:
#   binaries   -> ~/.local/bin (no XDG equivalent)
#   libraries  -> $XDG_DATA_HOME/advance/lib
#   catalog    -> $XDG_DATA_HOME/advance/catalog
#   man page   -> $XDG_DATA_HOME/man/man1
#   config     -> $XDG_CONFIG_HOME/advance
#
# For a system-wide install use the PKGBUILD (makepkg -si) instead.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_DATA_HOME:=$HOME/.local/share}"

BIN_DIR="$HOME/.local/bin"
MAN_DIR="$XDG_DATA_HOME/man/man1"
DATA_DIR="${ADVANCE_DATA_DIR:-$XDG_DATA_HOME/advance}"
LIB_DIR="$DATA_DIR/lib"
CATALOG_DIR="$DATA_DIR/catalog"
CONFIG_DIR="${ADVANCE_CONFIG_DIR:-$XDG_CONFIG_HOME/advance}"
MANAGERS_DIR="$CONFIG_DIR/managers.d"

QUIET=false
for arg in "$@"; do
    case "$arg" in
        -q|--quiet) QUIET=true ;;
    esac
done

# Ensure standard user tool directories are in PATH during installation
for _p in "$HOME/.local/bin" "${CARGO_HOME:-$HOME/.cargo}/bin" "${PNPM_HOME:-$HOME/.local/share/pnpm}"; do
    [[ -d "$_p" && ":$PATH:" != *":$_p:"* ]] && PATH="$_p:$PATH"
done
unset _p

# Color Setup (with compatibility check)
RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
if [ -t 1 ]; then
    ncolors=$(tput colors 2>/dev/null || echo 0)
    if [ -n "$ncolors" ] && [ "$ncolors" -ge 8 ]; then
        RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
        BLUE="$(tput setaf 4)"; BOLD="$(tput bold)"; RESET="$(tput sgr0)"
    fi
fi

[ "$QUIET" != true ] && echo "${BLUE}>>> [Phase: Installation] Setting up Advance...${RESET}"

# Replace a real file/directory with a symlink, keeping a backup of user data.
link_path() {
    local src="$1" dest="$2"
    if [[ -e "$dest" && ! -L "$dest" ]]; then
        local backup="${dest}.bak.$(date +%Y%m%d%H%M%S)"
        mv "$dest" "$backup"
        echo "  ${YELLOW}[BACKUP]${RESET} $dest -> $backup"
    fi
    mkdir -p "$(dirname "$dest")"
    ln -sfn "$src" "$dest"
}

# Ensure directories exist
mkdir -p "$BIN_DIR" "$MAN_DIR" "$DATA_DIR" "$CONFIG_DIR"

# Copy / link files
link_path "$(pwd)/advance" "$BIN_DIR/advance"
link_path "$(pwd)/lib" "$LIB_DIR"
link_path "$(pwd)/catalog" "$CATALOG_DIR"
[ -f "$SCRIPT_DIR/CHANGELOG.md" ] && link_path "$SCRIPT_DIR/CHANGELOG.md" "$DATA_DIR/CHANGELOG.md"
cp ./advance.1 "$MAN_DIR/advance.1"
if [ -f "./ship.sh" ]; then
    link_path "$(pwd)/ship.sh" "$BIN_DIR/ship"
    chmod +x "./ship.sh"
fi

# --- Auto-Discovery & Catalog Enrollment ---
[ "$QUIET" != true ] && echo "${BLUE}>>> [Phase: Auto-Discovery] Enrolling installed package managers from catalog...${RESET}"

# Auto-enroll installed catalog managers as symlinks
for cat_conf in ./catalog/managers/*/*.conf; do
    [ -f "$cat_conf" ] || continue
    gname=$(basename "$(dirname "$cat_conf")")
    fname=$(basename "$cat_conf")
    dest="$MANAGERS_DIR/$gname/$fname"
    mkdir -p "$MANAGERS_DIR/$gname"

    req=$(grep '^REQUIRES_CMD=' "$cat_conf" 2>/dev/null | head -1 | cut -d'=' -f2-)
    [ -z "$req" ] && req=$(grep '^REQUIRES_BIN=' "$cat_conf" 2>/dev/null | head -1 | cut -d'=' -f2-)
    probe_cmd=$(grep '^PROBE_ACTIVE_CMD=' "$cat_conf" 2>/dev/null | head -1 | cut -d'=' -f2-)

    if [ -n "$req" ] && command -v "$req" >/dev/null 2>&1; then
        if [ -z "$probe_cmd" ] || eval "$probe_cmd" >/dev/null 2>&1; then
            if [ ! -e "$dest" ]; then
                ln -sf "$(pwd)/catalog/managers/$gname/$fname" "$dest"
                [ "$QUIET" != true ] && echo "  ${GREEN}[ENROLL]${RESET} $gname/$fname (active, symlinked to catalog)"
            fi
        fi
    fi
done

# Set permissions
chmod +x "$BIN_DIR/advance"

if [ "$QUIET" != true ]; then
    echo "${GREEN}[OK] Advance installed successfully!${RESET}"
    echo "   - Binary: $BIN_DIR/advance"
    [ -f "./ship.sh" ] && echo "   - Ship Tool: $BIN_DIR/ship"
    echo "   - Libraries: $LIB_DIR"
    echo "   - Catalog: $CATALOG_DIR"
    echo "   - Changelog: $DATA_DIR/CHANGELOG.md"
    echo "   - Manual: $MAN_DIR/advance.1"
    echo "   - Configuration: $CONFIG_DIR"
    echo "   - Managers: $MANAGERS_DIR/"
    echo ""

    # Conditional Checkpoint Check
    if ! command -v checkpoint >/dev/null 2>&1; then
        echo "${YELLOW}[WARN] Note: It is highly recommended to install 'checkpoint' for full safety features.${RESET}"
        echo "       Without it, Advance cannot create system backups before updating."
        echo ""
        echo "${BLUE}Quick Tip:${RESET} To install it easily, go to your checkpoint repository and run:"
        echo "           ${BOLD}./install.sh${RESET}"
        echo ""
    fi
fi

# Auto-install fzf if missing
if ! command -v fzf >/dev/null 2>&1 && [ ! -x "$BIN_DIR/fzf" ] && [ ! -x "$HOME/.local/bin/fzf" ] && [ ! -x "$HOME/.fzf/bin/fzf" ]; then
    [ "$QUIET" != true ] && echo "${BLUE}>>> [Phase: Dependencies] Installing fzf...${RESET}"
    for cat_conf in ./catalog/managers/system/*.conf ./catalog/managers/brew/*.conf; do
        [ -f "$cat_conf" ] || continue
        req=$(grep '^REQUIRES_CMD=' "$cat_conf" 2>/dev/null | head -1 | cut -d'=' -f2-)
        probe_cmd=$(grep '^PROBE_ACTIVE_CMD=' "$cat_conf" 2>/dev/null | head -1 | cut -d'=' -f2-)
        inst_cmd=$(grep '^INSTALL_CMD=' "$cat_conf" 2>/dev/null | head -1 | cut -d'=' -f2-)

        if [ -n "$inst_cmd" ] && [ -n "$req" ] && command -v "$req" >/dev/null 2>&1; then
            if [ -z "$probe_cmd" ] || eval "$probe_cmd" >/dev/null 2>&1; then
                # Avoid non-interactive password prompt hangs
                if [[ "$inst_cmd" == *sudo* ]] && ! sudo -n true 2>/dev/null && [ ! -t 0 ]; then
                    continue
                fi
                [ "$QUIET" != true ] && echo "  ${GREEN}[INSTALL]${RESET} Installing fzf via $req ($inst_cmd fzf)..."
                if eval "$inst_cmd fzf"; then
                    break
                fi
            fi
        fi
    done

    # Fallback: official fzf binary via git installer if package manager fails
    if ! command -v fzf >/dev/null 2>&1 && [ ! -x "$BIN_DIR/fzf" ]; then
        [ "$QUIET" != true ] && echo "  ${YELLOW}[INFO]${RESET} Attempting user-level fallback installation of fzf..."
        fzf_dir="$HOME/.fzf"
        if command -v git >/dev/null 2>&1; then
            if [ ! -d "$fzf_dir" ]; then
                git clone --depth 1 https://github.com/junegunn/fzf.git "$fzf_dir" >/dev/null 2>&1 || true
            fi
            if [ -x "$fzf_dir/install" ]; then
                "$fzf_dir/install" --bin >/dev/null 2>&1 || true
                if [ -x "$fzf_dir/bin/fzf" ]; then
                    mkdir -p "$BIN_DIR"
                    ln -sf "$fzf_dir/bin/fzf" "$BIN_DIR/fzf"
                fi
            fi
        fi
    fi

    if [ "$QUIET" != true ]; then
        if command -v fzf >/dev/null 2>&1; then
            echo "  ${GREEN}[OK]${RESET} fzf installed successfully: $(fzf --version 2>/dev/null | head -1)"
        else
            echo "${YELLOW}[WARN] Could not install 'fzf' automatically. 'advance config' and 'advance schedule' need it.${RESET}"
        fi
        echo ""
    fi
fi

# Ensure ~/.local/bin is in ~/.bashrc for login and non-login shells (essential for WSL)
if [[ -f "$HOME/.bashrc" ]] && ! grep -q '\.local/bin' "$HOME/.bashrc" 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
    [ "$QUIET" != true ] && echo "  ${GREEN}[CONFIG]${RESET} Added ~/.local/bin to ~/.bashrc for WSL non-login shells."
fi

if [ "$QUIET" != true ]; then
    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        echo "${YELLOW}[WARN] $BIN_DIR is not in your current PATH. Add this to your shell profile:${RESET}"
        echo "       export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo ""
    fi

    echo "[INFO] Usage: Type 'advance --help' or 'man advance' to get started."
fi
