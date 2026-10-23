#!/usr/bin/env bash
# Tools installed by their official installers, not by pacman/AUR.
# (通过官方安装脚本安装、不走 pacman/AUR 的工具)
#
# Usage(用法): scripts/install-extras.sh [name...]   # default: all (默认全部)
# Already-installed tools are skipped. (已安装的会跳过)

set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$DOTFILES/scripts/lib.sh"

# name | check command | install command (名称 | 检测命令 | 安装命令)
EXTRAS=(
    "claude|claude|curl -fsSL https://claude.ai/install.sh | bash"
    "zed|zed|curl -f https://zed.dev/install.sh | sh"
    "uv|uv|curl -LsSf https://astral.sh/uv/install.sh | sh"
    "opencode|opencode|curl -fsSL https://opencode.ai/install | bash"
    "pi|pi|curl -fsSL https://pi.dev/install.sh | sh"
    "herdr|herdr|curl -fsSL https://herdr.dev/install.sh | sh"
    "rtk|rtk|curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh"
    "codegraph|codegraph|curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh"
    "tuicr|tuicr|curl -fsSL https://tuicr.dev/install.sh | sh"
    "fff-mcp|fff-mcp|curl -L https://dmtrkovalenko.dev/install-fff-mcp.sh | bash"
    "moshi-hook|moshi-hook|curl -fsSL https://getmoshi.app/install.sh | sh"
    "hermes|hermes|curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
    "maestro|maestro|curl -fsSL https://get.maestro.mobile.dev | bash"
)

main() {
    local want=("$@") failed=()
    for entry in "${EXTRAS[@]}"; do
        IFS='|' read -r name check cmd <<<"$entry"
        if [[ ${#want[@]} -gt 0 ]] && [[ ! " ${want[*]} " =~ " $name " ]]; then continue; fi
        if have "$check" || [[ -x "$HOME/.local/bin/$check" ]]; then
            ok "$name already installed"
            continue
        fi
        log "Installing $name"
        run bash -c "$cmd" || failed+=("$name")
    done
    [[ ${#failed[@]} -eq 0 ]] || { warn "Failed: ${failed[*]}"; return 1; }
    ok "Extras done"
}

main "$@"
