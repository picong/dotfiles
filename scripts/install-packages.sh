#!/usr/bin/env bash
# Install software from packages-list/*.txt (按清单安装软件)
#
# Usage(用法): scripts/install-packages.sh [step...]
#   steps: repo pacman aur flatpak npm cargo go uv extras hardware
#   default: everything except "hardware" (默认执行除 hardware 外的全部步骤)
#   DRY_RUN=1 只打印命令

set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIST="$DOTFILES/packages-list"
. "$DOTFILES/scripts/lib.sh"

[[ "$(id -u)" != 0 ]] || { err "Run as a normal user, not root (请用普通用户运行)"; exit 1; }

step_repo() {
    # archlinuxcn repo provides paru/yay and several packages. (archlinuxcn 源)
    if ! grep -q '^\[archlinuxcn\]' /etc/pacman.conf; then
        log "Adding [archlinuxcn] repo"
        run sudo tee -a /etc/pacman.conf >/dev/null <<'EOF'

[archlinuxcn]
Server = https://mirrors.ustc.edu.cn/archlinuxcn/$arch
EOF
        run sudo pacman -Sy --noconfirm archlinuxcn-keyring
    fi
    if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
        warn "[multilib] is disabled; enable it in /etc/pacman.conf for lib32-* packages"
    fi
}

step_pacman() {
    log "pacman packages"
    mapfile -t pkgs < <(read_list "$LIST/pacman.txt")
    run sudo pacman -Syu --needed --noconfirm "${pkgs[@]}"
}

step_hardware() {
    # Drivers/kernels/bootloader — review before use on other hardware.
    # (驱动/内核/引导，换机器前请先审阅)
    log "hardware packages"
    mapfile -t pkgs < <(read_list "$LIST/pacman-hardware.txt")
    run sudo pacman -S --needed "${pkgs[@]}"
}

aur_helper() {
    if have paru; then echo paru; elif have yay; then echo yay; fi
}

step_aur() {
    local helper; helper="$(aur_helper)"
    if [[ -z "$helper" ]]; then
        run sudo pacman -S --needed --noconfirm paru || { warn "No AUR helper; skip AUR"; return 0; }
        helper=paru
    fi
    log "AUR packages via $helper"
    mapfile -t pkgs < <(read_list "$LIST/aur.txt")
    # Install one by one so a single broken AUR build does not stop the rest.
    # (逐个安装，避免某个 AUR 包构建失败中断全部)
    local failed=()
    for p in "${pkgs[@]}"; do
        pacman -Qq "$p" >/dev/null 2>&1 && continue
        run "$helper" -S --needed --noconfirm "$p" || failed+=("$p")
    done
    [[ ${#failed[@]} -eq 0 ]] || warn "AUR failed: ${failed[*]}"
}

step_flatpak() {
    have flatpak || run sudo pacman -S --needed --noconfirm flatpak
    log "flatpak apps"
    run flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    mapfile -t apps < <(read_list "$LIST/flatpak.txt")
    [[ ${#apps[@]} -eq 0 ]] || run flatpak install --user -y flathub "${apps[@]}"
}

step_npm() {
    have npm || { warn "npm missing, skip"; return 0; }
    log "npm global packages (prefix ~/.npm-global)"
    # ~/.npmrc is generated here rather than tracked. (~/.npmrc 在此生成，不入库)
    run npm config set prefix "$HOME/.npm-global"
    run npm config set registry https://registry.npmmirror.com
    mapfile -t pkgs < <(read_list "$LIST/npm-global.txt")
    run npm install -g "${pkgs[@]}"
}

step_cargo() {
    have cargo || { warn "cargo missing, skip"; return 0; }
    log "cargo crates"
    while read -r crate rest; do
        # shellcheck disable=SC2086
        run cargo install --locked "$crate" $rest
    done < <(read_list "$LIST/cargo.txt")
}

step_go() {
    have go || { warn "go missing, skip"; return 0; }
    log "go tools"
    while read -r mod; do run go install "$mod"; done < <(read_list "$LIST/go.txt")
}

step_uv() {
    have uv || run sh -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
    log "uv tools"
    while read -r tool; do run "$HOME/.local/bin/uv" tool install "$tool"; done < <(read_list "$LIST/uv-tools.txt")
}

step_extras() {
    "$DOTFILES/scripts/install-extras.sh"
}

main() {
    local steps=("$@")
    [[ ${#steps[@]} -gt 0 ]] || steps=(repo pacman aur flatpak npm cargo go uv extras)
    for s in "${steps[@]}"; do
        if declare -F "step_$s" >/dev/null; then "step_$s"; else err "Unknown step: $s"; exit 1; fi
    done
    ok "Software installation finished"
}

main "$@"
