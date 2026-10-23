#
# ~/.bashrc
#

# Load private secrets before the non-interactive guard so agent bash sessions get them
# (在非交互保护前加载私密变量，供 agent 的 bash 会话使用)
if [[ -r "$HOME/.secrets/secrets.env" ]]; then
    set -a
    . "$HOME/.secrets/secrets.env"
    set +a
fi

# Skip Pi's terminal color-probe timeout; this terminal uses a dark background.
# (跳过 Pi 终端配色探测超时；当前终端使用深色背景。)
export PI_SHELL_PROMPT_SCHEME=dark

# Load the Zed Codex provider key before the non-interactive guard.
# (在非交互保护前加载 Zed Codex provider 密钥。)
if [[ -r "$HOME/.config/environment.d/zed-codex.conf" ]]; then
    set -a
    . "$HOME/.config/environment.d/zed-codex.conf"
    set +a
fi

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '

export EDITOR='nvim'
export ANTHROPIC_BASE_URL="${AI_GATEWAY_URL:-}"
# export WINEDEBUG=-all

# Common bin dirs before exec fish, so tools like Zed capturing env via `bash -c` get a full PATH
# (常用二进制目录放在 exec fish 之前，Zed 等工具用 `bash -c` 抓环境时才能拿到完整 PATH)
# Common bin dirs before exec fish, so tools like Zed capturing env via `bash -c` get a full PATH.
# Prepend only what is missing, so nested bash/fish sessions do not duplicate entries.
# (常用二进制目录放在 exec fish 之前，Zed 等工具用 `bash -c` 抓环境时才能拿到完整 PATH；
#  只补缺失项，嵌套 bash/fish 会话不会重复追加)
for _d in "$HOME/.maestro/bin" "$HOME/go/bin" "$HOME/.opencode/bin" "$HOME/.cargo/bin" "$HOME/.local/bin" "$HOME/.npm-global/bin"; do
    case ":$PATH:" in
        *":$_d:"*) ;;
        *) [[ -d $_d ]] && PATH="$_d:$PATH" ;;
    esac
done
unset _d
export PATH
# Node built-in fetch honors HTTPS_PROXY only with this flag (Node 26 undici)
# (Node 26 内置 fetch 需此开关才走代理)
export NODE_USE_ENV_PROXY=1

# Keep the exact gateway host because Node/Undici does not support NO_PROXY CIDR entries.
# (保留精确网关主机，因为 Node/Undici 不支持 NO_PROXY 的 CIDR 条目。)
export NO_PROXY="localhost,127.0.0.1,::1,192.168.1.99,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,*.local"
export no_proxy="$NO_PROXY"

# The local adaptive proxy uses Clash when healthy and direct access otherwise.
# (本地自适应代理在 Clash 健康时使用代理，否则直接连接。)
_terminal_proxy_url=http://127.0.0.1:7898
if [[ -n "$BASH_EXECUTION_STRING" ]]; then
    if command curl --noproxy '*' --silent --output /dev/null \
            --connect-timeout 0.1 --max-time 0.2 "$_terminal_proxy_url"; then
        export HTTP_PROXY="$_terminal_proxy_url"
        export HTTPS_PROXY="$_terminal_proxy_url"
        export http_proxy="$_terminal_proxy_url"
        export https_proxy="$_terminal_proxy_url"
        unset ALL_PROXY all_proxy
    else
        unset HTTP_PROXY HTTPS_PROXY ALL_PROXY
        unset http_proxy https_proxy all_proxy
    fi
fi
unset _terminal_proxy_url

# Only exec fish in a real interactive terminal; skip when invoked via `bash -c`
# (e.g. Zed capturing shell env), where $BASH_EXECUTION_STRING is non-empty.
# (仅在真交互终端切到 fish；被 `bash -c` 调用时[如 Zed 抓环境]$BASH_EXECUTION_STRING 非空，跳过以便正常输出环境)
if [[ -z "$BASH_EXECUTION_STRING" ]]; then
    exec fish
fi

# opencode: PATH already prepended above (line 37), no second export needed
# (opencode：PATH 已在上方统一前置，无需重复 export)

# Language settings(语言设置)
export LANG=zh_CN.UTF-8
export LC_ALL=zh_CN.UTF-8

# Pi powerline Nerd Fonts support(Pi powerline Nerd字体支持)
export POWERLINE_NERD_FONTS=1
# maestro: PATH already prepended above (line 37); keep only the analytics opt-out
# (maestro：PATH 已在上方统一前置，这里只保留关闭遥测)
export MAESTRO_CLI_NO_ANALYTICS=1

# Node 26 内置 fetch(undici) 默认不读 HTTPS_PROXY，需此开关才能走代理（修复 hermes desktop / electron postinstall 的 fetch failed）
export NODE_USE_ENV_PROXY=1
# electron 二进制走国内镜像，下载更稳更快
export ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/

# NOTE: 第 17 行 `exec fish` 之后的内容都是死代码，bash 一进交互就被替换成 fish 了，永远不执行。
# (NOTE: everything after `exec fish` on line 17 is dead code; interactive bash is replaced by fish.)
# 真正生效的 pi wrapper 在 fish 配置里(~/.config/fish/config.fish)。下面这份仅留作 bash fallback 参考。
# (The wrapper that actually runs is in fish config; the one below is just a bash fallback reference.)
# pi wrapper: 屏蔽 GEMINI/OPENAI env，避免 pi 列出用不了的 google/openai 模型
# (pi wrapper: mask GEMINI/OPENAI env so pi only lists usable gateway models)
pi() {
  env -u GEMINI_API_KEY -u OPENAI_API_KEY pi "$@"
}

# pnpm global bin directory (pnpm's default PNPM_HOME, required by pnpm add -g)
export PNPM_HOME="$HOME/.local/share/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME/bin:"*) ;;
  *) export PATH="$PNPM_HOME/bin:$PATH" ;;
esac
