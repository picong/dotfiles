if status is-interactive
    # Commands to run in interactive sessions can go here
    # 只在非 tmux 环境下运行 fastfetch（即 kitty tab 打开时）
    if not set -q TMUX
        fastfetch
    end
end
set fish_greeting ""
# fish_add_path is idempotent, so nested fish sessions do not duplicate entries
# (fish_add_path 幂等，嵌套 fish 会话不会重复追加 PATH 条目)
fish_add_path -gP ~/go/bin ~/.opencode/bin ~/.cargo/bin ~/.local/bin ~/.npm-global/bin
set -gx GOTOOLCHAIN auto

# Load private secrets from ~/.secrets/secrets.env (KEY='value' per line, never committed)
# (从 ~/.secrets/secrets.env 加载私密变量，每行 KEY='value'，该文件不入库)
if test -r ~/.secrets/secrets.env
    for _line in (string match -rv '^\s*(#|$)' <~/.secrets/secrets.env)
        set -l _kv (string split -m1 = -- $_line)
        set -gx $_kv[1] (string trim -c "'\"" -- $_kv[2])
    end
    set -e _line
end

# Pi powerline Nerd Fonts support(Pi powerline Nerd字体支持)
set -gx POWERLINE_NERD_FONTS 1
# Skip the terminal color-probe timeout; this terminal uses a dark background.
# (跳过终端配色探测超时；当前终端使用深色背景。)
set -gx PI_SHELL_PROMPT_SCHEME dark
alias go22='~/go/bin/go1.22.12'
# starship init fish | source
zoxide init fish --cmd cd | source

# Machine-private abbrs / ssh hosts live in local.fish (not committed)
# (本机私有的 abbr / ssh 主机写在 local.fish，不入库)
test -r ~/.config/fish/local.fish; and source ~/.config/fish/local.fish

# alias venv="source .venv/bin/activate.fish"
# funcsave venv

function y
    set tmp (mktemp -t "yazi-cwd.XXXXXX")
    yazi $argv --cwd-file="$tmp"
    if read -z cwd <"$tmp"; and [ -n "$cwd" ]; and [ "$cwd" != "$PWD" ]
        builtin cd -- "$cwd"
    end
    rm -f -- "$tmp"
end

function ls
    command eza --icons $argv
end

# grub
abbr grub 'sudo grub-mkconfig -o /boot/grub/grub.cfg'
# 小黄鸭补帧 需要steam安装正版小黄鸭
abbr lsfg 'LSFG_PROCESS="miyu"'
# fa运行fastfetch
abbr fa fastfetch
abbr reboot 'systemctl reboot'
function sl
    command sl | lolcat
end
function 滚
    sysup
end
function raw
    command ~/.config/scripts/random-anime-wallpaper.sh $argv
end

function 安装
    command yay -S $argv
end

function 卸载
    command yay -Rns $argv
end



# Keep the exact gateway host because Node/Undici does not support NO_PROXY CIDR entries.
# (保留精确网关主机，因为 Node/Undici 不支持 NO_PROXY 的 CIDR 条目。)
set -gx NO_PROXY "localhost,127.0.0.1,::1,192.168.1.99,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,*.local"
set -gx no_proxy $NO_PROXY
# Node 26 内置 fetch(undici) 默认忽略 HTTPS_PROXY，需此开关
# (Node 26 built-in fetch ignores HTTPS_PROXY without this flag)
set -gx NODE_USE_ENV_PROXY 1

# The local adaptive proxy uses Clash when healthy and direct access otherwise.
# (本地自适应代理在 Clash 健康时使用代理，否则直接连接。)
set -g __terminal_proxy_url http://127.0.0.1:7898

function __terminal_proxy_enable
    set -gx HTTP_PROXY $__terminal_proxy_url
    set -gx HTTPS_PROXY $__terminal_proxy_url
    set -gx http_proxy $__terminal_proxy_url
    set -gx https_proxy $__terminal_proxy_url
    set -eg ALL_PROXY
    set -eg all_proxy
    return 0
end

function __terminal_proxy_disable
    set -eg HTTP_PROXY
    set -eg HTTPS_PROXY
    set -eg ALL_PROXY
    set -eg http_proxy
    set -eg https_proxy
    set -eg all_proxy
    return 0
end

function __refresh_terminal_proxy
    # This check is local-only; upstream failover happens inside the proxy service.
    # (这里只检查本地端口；上游故障切换由代理服务内部完成。)
    if command curl --noproxy '*' --silent --output /dev/null \
            --connect-timeout 0.1 --max-time 0.2 $__terminal_proxy_url
        __terminal_proxy_enable
    else
        __terminal_proxy_disable
    end
    return 0
end

function __refresh_terminal_proxy_before_command --on-event fish_preexec
    __refresh_terminal_proxy
end

__refresh_terminal_proxy

# GEMINI_API_KEY / OPENAI_API_KEY / LOCAL_API_KEY come from ~/.secrets/secrets.env
# (这几个 key 由 ~/.secrets/secrets.env 提供)

# sudo askpass helper (sudo askpass 助手)
set -gx SUDO_ASKPASS /usr/bin/ksshaskpass


# jiti transpile cache lives at $TMPDIR/jiti, and /tmp is tmpfs here, so every
# reboot wiped it and the next pi start paid ~4.1s of TS transpilation
# (pi-subagents alone 2.5s). JITI_FS_CACHE only takes a boolean, so the only way
# to relocate it is to make /tmp/jiti point at a persistent directory.
# (jiti 转译缓存在 $TMPDIR/jiti，本机 /tmp 是 tmpfs，重启即清空，导致下次启动多花约 4.1s
#  重新转译 TS（仅 pi-subagents 就 2.5s）。JITI_FS_CACHE 只接受布尔值，无法指定路径，
#  只能把 /tmp/jiti 指向持久目录。)
function __pi_link_jiti_cache
    set -l target $HOME/.cache/pi/jiti
    test -d $target; or mkdir -p $target
    # Already the right symlink: nothing to do. (已是正确软链，无需处理。)
    if test -L /tmp/jiti; and test (realpath /tmp/jiti 2>/dev/null) = (realpath $target)
        return 0
    end
    # A real directory means a fresh boot created it; fold its entries into the
    # persistent cache instead of discarding warm entries.
    # (真实目录说明是重启后新建的；把其中条目并入持久缓存，避免丢弃已热的条目。)
    if test -d /tmp/jiti; and not test -L /tmp/jiti
        cp -an /tmp/jiti/. $target/ 2>/dev/null
        rm -rf /tmp/jiti
    end
    ln -sfn $target /tmp/jiti
end

# pi wrapper: 屏蔽 GEMINI/OPENAI env，避免 pi 列出用不了的 google/openai 模型
# (pi wrapper: mask GEMINI/OPENAI env so pi only lists usable gateway models)
# Startup cache: persist V8 compile cache so pi does not re-compile its own module
# graph on every launch (saves ~90ms of pre-main time).
# (启动缓存：持久化 V8 编译缓存，避免每次启动重新编译 pi 自身模块图，约省 90ms)
# Cache retention: the 192 gateway accepts Anthropic `cache_control.ttl: "1h"`,
# and its 5-minute cache slots are evicted within seconds under load, so almost
# every cache miss was the same unchanged prefix being rewritten.
# (缓存保留：192 网关支持 Anthropic `cache_control.ttl: "1h"`，其 5 分钟缓存槽在负载下
#  数秒即被驱逐，导致几乎所有未命中都是同一份未变前缀被反复重写。)
function pi
    __pi_link_jiti_cache
    env -u GEMINI_API_KEY -u OPENAI_API_KEY \
        PI_CACHE_RETENTION=long \
        NODE_COMPILE_CACHE=$HOME/.cache/pi/node-compile \
        pi $argv
    set -l pi_status $status

    return $pi_status
end

# Load image/update extensions only for sessions that need them.
# (仅在需要图片/更新能力的会话中加载低频扩展。)
function pifull
    __pi_link_jiti_cache
    env -u GEMINI_API_KEY -u OPENAI_API_KEY \
        PI_CACHE_RETENTION=long \
        NODE_COMPILE_CACHE=$HOME/.cache/pi/node-compile \
        pi \
        -e $HOME/.pi/agent/extensions/image-auto-compact/index.ts \
        -e $HOME/.pi/agent/extensions/update.ts \
        $argv
end

# Web research session: pi-web-access is off by default (~67ms of startup for
# web_search / fetch_content / source_check), so load it only when the session
# actually needs to hit the network.
# (联网研究会话：pi-web-access 默认关闭（web_search / fetch_content / source_check
#  占启动约 67ms），仅在确实需要联网时加载。)
function piweb
    __pi_link_jiti_cache
    env -u GEMINI_API_KEY -u OPENAI_API_KEY \
        PI_CACHE_RETENTION=long \
        NODE_COMPILE_CACHE=$HOME/.cache/pi/node-compile \
        pi -e $HOME/.pi/agent/npm/node_modules/pi-web-access/index.ts $argv
end

# claude code yolo mode: skip all permission prompts (claude code yolo 模式：跳过所有权限确认)
abbr --add c-d claude --dangerously-skip-permissions
# codex yolo mode
abbr --add c-x codex --dangerously-bypass-approvals-and-sandbox

for _f in $HOME/.config/herdr/plugins/github/herdr-automatic-rename-*/shell/hook.fish
    test -r "$_f"; and source "$_f"; and break
end

# pnpm global bin directory (pnpm's default PNPM_HOME, required by pnpm add -g)
set -gx PNPM_HOME $HOME/.local/share/pnpm
if not contains $PNPM_HOME/bin $PATH
    set -gx PATH $PNPM_HOME/bin $PATH
end
