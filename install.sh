#!/bin/bash
# Dotfiles installation script
# Usage: ./install.sh [package...]

set -e

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$HOME/.config-backup-$(date +%Y%m%d%H%M%S)"

# All available packages
ALL_PACKAGES=(fish starship nvim vim kitty tmux niri ideavim)

# Parse arguments
if [ $# -eq 0 ]; then
    PACKAGES=("${ALL_PACKAGES[@]}")
else
    PACKAGES=("$@")
fi

echo "Packages to install: ${PACKAGES[*]}"
echo ""

# Backup function
backup_file() {
    local file="$1"
    if [ -e "$file" ] && [ ! -L "$file" ]; then
        echo "Backing up: $file"
        mkdir -p "$BACKUP_DIR"
        mv "$file" "$BACKUP_DIR/"
    fi
}

# Install packages
cd "$DOTFILES_DIR"

for pkg in "${PACKAGES[@]}"; do
    if [ -d "$pkg" ]; then
        echo "Installing $pkg..."

        # Backup existing configs before stow
        case $pkg in
            fish)
                backup_file "$HOME/.config/fish"
                ;;
            starship)
                backup_file "$HOME/.config/starship.toml"
                ;;
            nvim)
                backup_file "$HOME/.config/nvim"
                ;;
            vim)
                backup_file "$HOME/.vimrc"
                ;;
            kitty)
                backup_file "$HOME/.config/kitty"
                ;;
            tmux)
                backup_file "$HOME/.tmux.conf"
                backup_file "$HOME/.tmux"
                backup_file "$HOME/.config/tmux"
                ;;
            niri)
                backup_file "$HOME/.config/niri"
                ;;
            ideavim)
                backup_file "$HOME/.ideavimrc"
                ;;
        esac

        stow "$pkg"
        echo "  ✓ $pkg installed"
    else
        echo "  ✗ Package '$pkg' not found"
    fi
done

echo ""
if [ -d "$BACKUP_DIR" ]; then
    echo "Backups saved to: $BACKUP_DIR"
fi
echo "Done!"