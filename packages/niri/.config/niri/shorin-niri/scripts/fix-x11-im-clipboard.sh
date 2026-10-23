#!/bin/bash
# Repair X11(Xwayland) input-method and clipboard bridge after xwayland-satellite restarts
# (xwayland-satellite 重启后修复 X11 应用的输入法与剪贴板，例如 wine 企业微信/微信)
#
# Why(为什么需要): niri lazily spawns xwayland-satellite, and every respawn creates a NEW
# Xwayland instance. fcitx5's xcb addon does not reconnect, so its XIM server registration on
# the X root window disappears and X11/wine apps lose IM. The satellite clipboard bridge can
# also get stuck in the Wayland->X11 direction until an X11 client re-claims the selection.

set -u
export DISPLAY="${DISPLAY:-:0}"

log() { printf '%s\n' "$*"; }

# 1) Input method(输入法): re-register the XIM server if it is missing
if ! xprop -root XIM_SERVERS 2>/dev/null | grep -q '@server=fcitx'; then
    log "XIM server missing on $DISPLAY, restarting fcitx5..."
    pkill -x fcitx5
    sleep 1
    setsid env DISPLAY="$DISPLAY" \
        XMODIFIERS='@im=fcitx' GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx \
        fcitx5 -d >/dev/null 2>&1
    sleep 2
    if xprop -root XIM_SERVERS 2>/dev/null | grep -q '@server=fcitx'; then
        log "  -> XIM server registered"
    else
        log "  -> still missing, check: fcitx5-diagnose"
    fi
else
    log "XIM server OK"
fi

# 2) Clipboard(剪贴板): verify Wayland -> X11, unstick by letting an X11 client own CLIPBOARD
probe_x_clipboard() { timeout 4 xclip -selection clipboard -t TARGETS -o >/dev/null 2>&1; }

if probe_x_clipboard; then
    log "Clipboard bridge OK"
else
    log "Wayland->X11 clipboard stuck, resetting selection owner..."
    saved=$(timeout 3 wl-paste -n 2>/dev/null)
    printf 'x11-clipboard-reset' | timeout 3 xclip -selection clipboard -i
    sleep 1
    # Restore the previous clipboard content(恢复原有剪贴板内容)
    if [ -n "$saved" ]; then
        printf '%s' "$saved" | timeout 3 wl-copy
    else
        wl-copy --clear 2>/dev/null
    fi
    sleep 1
    if probe_x_clipboard; then
        log "  -> clipboard bridge restored"
    else
        log "  -> still broken; restart the X bridge: pkill -f xwayland-satellite"
        log "     (WARNING: this kills all running X11/wine apps)"
    fi
fi
