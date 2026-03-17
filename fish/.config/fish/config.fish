if status is-interactive
    # Commands to run in interactive sessions can go here
    # 只在非 tmux 环境下运行 fastfetch（即 kitty tab 打开时）
    if not set -q TMUX
        fastfetch
    end
end
set fish_greeting ""
set -p PATH ~/.local/bin
set -p PATH ~/.cargo/bin
set -p PATH /home/picong/.opencode/bin
# starship init fish | source
zoxide init fish --cmd cd | source

# pdf-reader项目
abbr --add spr ssh 'root@39.97.226.91'
# pdf-into项目
abbr --add spi ssh 'root@47.103.58.192'
# 公司日志查询
abbr --add sdev ssh 'wftapp@192.168.4.47'
# 公司k8s客户端
abbr --add sk8s ssh 'wftapp@192.168.4.91'
abbr --add sst ssh 'wftapp@192.168.4.43'
# 视频去水印app客户端
abbr --add ssp ssh 'root@115.29.207.127'
# 海外官网
abbr --add sxh ssh 'root@47.253.228.85'
# 本地开关
abbr --add ssw ssh 'root@47.243.52.241'

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

# Added by LM Studio CLI (lms)
set -gx PATH $PATH /home/shorin/.lmstudio/bin
# End of LM Studio CLI section
