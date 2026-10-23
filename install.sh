#!/usr/bin/env bash
# One-shot dotfiles installer (一键安装配置)
#
# Usage(用法):
#   ./install.sh                  # link all packages + render templates (链接全部配置 + 渲染模板)
#   ./install.sh --all            # install software first, then the above (先装软件再做上面的事)
#   ./install.sh --packages       # only install software (只装软件)
#   ./install.sh --link [pkg..]   # only link given / all stow packages (只链接指定或全部配置包)
#   ./install.sh --render [-f]    # only render secret templates, -f overwrites (只渲染模板，-f 覆盖)
#   ./install.sh --unlink [pkg..] # remove stow links (取消链接)
#   ./install.sh -n ...           # dry run: show what would happen (只演示不执行)

set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$DOTFILES/packages"
BACKUP_DIR="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"
SECRETS_FILE="${SECRETS_FILE:-$HOME/.secrets/secrets.env}"
DRY_RUN=0
FORCE=0

# shellcheck source=scripts/lib.sh
. "$DOTFILES/scripts/lib.sh"

all_packages() {
    find "$PKG_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
}

# Move whatever blocks a stow link out of the way.
# (把会阻挡 stow 链接的文件挪开)
backup_conflict() {
    local target="$1" rel="$2"
    # A symlinked parent dir (old folded stow layout) must go first, otherwise the
    # file checks below would follow it. (先处理被软链的父目录，例如旧 stow 折叠的目录)
    local parent="" part parts
    IFS='/' read -ra parts <<<"$(dirname "$rel")"
    for part in "${parts[@]}"; do
        [[ "$part" == . ]] && continue
        parent="${parent:+$parent/}$part"
        if [[ -L "$HOME/$parent" ]]; then
            run mkdir -p "$BACKUP_DIR/$(dirname "$parent")"
            run mv "$HOME/$parent" "$BACKUP_DIR/$parent"
            log "Backed up symlinked dir ~/$parent"
            break
        fi
    done
    if [[ -L "$target" ]]; then
        # Already ours: nothing to do. Foreign symlink (old layout): back it up.
        # (已指向本仓库则跳过；其他符号链接（旧布局）也备份)
        [[ "$(readlink -f "$target" 2>/dev/null)" == "$PKG_DIR"/* ]] && return 0
    elif [[ ! -e "$target" ]]; then
        return 0
    fi
    run mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    run mv "$target" "$BACKUP_DIR/$rel"
    log "Backed up ~/$rel"
}

link_package() {
    local pkg="$1"
    [[ -d "$PKG_DIR/$pkg" ]] || { warn "Package '$pkg' not found, skipped"; return 0; }
    # Back up every file the package wants to own. (备份该包要接管的所有文件)
    while IFS= read -r -d '' f; do
        local rel="${f#"$PKG_DIR/$pkg/"}"
        backup_conflict "$HOME/$rel" "$rel"
    done < <(find "$PKG_DIR/$pkg" \( -type f -o -type l \) -print0)
    # --no-folding: link files, never whole dirs, so apps can keep writing state next to them.
    # (--no-folding：只链接文件、不折叠目录，程序仍可在同目录写运行时文件)
    run stow --no-folding --dir "$PKG_DIR" --target "$HOME" --restow "$pkg"
    ok "Linked $pkg"
}

unlink_package() {
    run stow --dir "$PKG_DIR" --target "$HOME" --delete "$1"
    ok "Unlinked $1"
}

ensure_secrets_file() {
    if [[ ! -f "$SECRETS_FILE" ]]; then
        run mkdir -p "$(dirname "$SECRETS_FILE")"
        run cp "$DOTFILES/secrets/secrets.env.example" "$SECRETS_FILE"
        warn "Created $SECRETS_FILE from example — fill in real values, then run: ./install.sh --render -f"
    fi
    run chmod 700 "$(dirname "$SECRETS_FILE")"
    run chmod 600 "$SECRETS_FILE"
}

ensure_local_files() {
    # Private per-machine files referenced by tracked configs. (被入库配置引用的本机私有文件)
    if [[ ! -f "$HOME/.gitconfig.local" ]]; then
        run cp "$DOTFILES/secrets/gitconfig.local.example" "$HOME/.gitconfig.local"
        warn "Created ~/.gitconfig.local — set your git name/email"
    fi
    if [[ ! -f "$HOME/.config/fish/local.fish" ]]; then
        run mkdir -p "$HOME/.config/fish"
        run cp "$DOTFILES/secrets/local.fish.example" "$HOME/.config/fish/local.fish"
    fi
}

post_link() {
    # fish plugins via fisher; plugin files themselves are not tracked.
    # (fish 插件由 fisher 安装，插件文件本身不入库)
    if have fish && ! fish -c 'type -q fisher' 2>/dev/null; then
        log "Installing fisher + plugins from fish_plugins"
        run fish -c 'curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher update' \
            || warn "fisher install failed"
    fi
    # tmux plugin manager. (tmux 插件管理器)
    if have tmux && [[ ! -d "$HOME/.tmux/plugins/tpm" ]]; then
        run git clone --depth 1 https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm" \
            && log "In tmux press prefix + I to install plugins" || warn "tpm clone failed"
    fi
    if have systemctl; then run systemctl --user daemon-reload || true; fi
}

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
    local mode=default args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) mode=all ;;
            --packages) mode=packages ;;
            --link) mode=link ;;
            --render) mode=render ;;
            --unlink) mode=unlink ;;
            -n|--dry-run) DRY_RUN=1 ;;
            -f|--force) FORCE=1 ;;
            -h|--help) usage; exit 0 ;;
            -*) err "Unknown option: $1"; usage; exit 1 ;;
            *) args+=("$1") ;;
        esac
        shift
    done
    export DRY_RUN FORCE SECRETS_FILE

    local pkgs=()
    if [[ ${#args[@]} -gt 0 ]]; then pkgs=("${args[@]}"); else mapfile -t pkgs < <(all_packages); fi

    case "$mode" in
        packages) exec "$DOTFILES/scripts/install-packages.sh" ;;
        render) ensure_secrets_file; exec "$DOTFILES/scripts/render-templates.sh" ;;
        unlink) for p in "${pkgs[@]}"; do unlink_package "$p"; done; exit 0 ;;
        all) "$DOTFILES/scripts/install-packages.sh" ;;
    esac

    have stow || { err "GNU stow is required: sudo pacman -S stow"; exit 1; }
    for p in "${pkgs[@]}"; do link_package "$p"; done

    if [[ "$mode" != link ]]; then
        ensure_local_files
        ensure_secrets_file
        "$DOTFILES/scripts/render-templates.sh"
        post_link
    fi

    if [[ -d "$BACKUP_DIR" ]]; then log "Backups saved to $BACKUP_DIR"; fi
    ok "Done. Open a new shell to load the config."
}

main "$@"
