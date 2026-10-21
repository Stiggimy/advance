#!/bin/bash
set -e

# --- advance Installer ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BIN_DIR="$HOME/.local/bin"
MAN_DIR="$HOME/.local/share/man/man1"
MANAGERS_DIR="$HOME/.config/advance/managers.d"

# Color Setup (with compatibility check)
RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
if [ -t 1 ]; then
    ncolors=$(tput colors 2>/dev/null || echo 0)
    if [ -n "$ncolors" ] && [ "$ncolors" -ge 8 ]; then
        RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
        BLUE="$(tput setaf 4)"; BOLD="$(tput bold)"; RESET="$(tput sgr0)"
    fi
fi

echo "${BLUE}>>> [Phase: Installation] Setting up Advance...${RESET}"

# Ensure directories exist
mkdir -p "$BIN_DIR"
mkdir -p "$MAN_DIR"
mkdir -p "$HOME/.local/lib"
mkdir -p "$HOME/.local/share/advance"

# Copy / link files
ln -sf "$(pwd)/advance" "$BIN_DIR/advance"
ln -sfn "$(pwd)/lib" "$HOME/.local/lib/advance"
ln -sfn "$(pwd)/catalog" "$HOME/.local/share/advance/catalog"
cp ./advance.1 "$MAN_DIR/advance.1"
if [ -f "./ship.sh" ]; then
    ln -sf "$(pwd)/ship.sh" "$BIN_DIR/ship"
    chmod +x "./ship.sh"
fi

# --- Auto-Discovery & Catalog Enrollment ---
echo "${BLUE}>>> [Phase: Auto-Discovery] Enrolling installed package managers from catalog...${RESET}"

# Ensure standard user tool directories are in PATH during installation
for _p in "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/.local/share/pnpm"; do
    [[ -d "$_p" && ":$PATH:" != *":$_p:"* ]] && PATH="$_p:$PATH"
done
unset _p

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
                echo "  ${GREEN}[ENROLL]${RESET} $gname/$fname (active, symlinked to catalog)"
            fi
        fi
    fi
done

# Set permissions
chmod +x "$BIN_DIR/advance"

echo "${GREEN}[OK] Advance installed successfully!${RESET}"
echo "   - Binary: $BIN_DIR/advance"
[ -f "./ship.sh" ] && echo "   - Ship Tool: $BIN_DIR/ship"
echo "   - Libraries: $HOME/.local/lib/advance"
echo "   - Catalog: $HOME/.local/share/advance/catalog"
echo "   - Manual: $MAN_DIR/advance.1"
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

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo "${YELLOW}[WARN] $BIN_DIR is not in your PATH. Add this to your shell profile:${RESET}"
    echo "       export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
fi

echo "[INFO] Usage: Type 'advance --help' or 'man advance' to get started."
