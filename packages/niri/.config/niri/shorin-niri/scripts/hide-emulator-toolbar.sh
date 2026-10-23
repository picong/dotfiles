#!/bin/bash
# Hide the Android Emulator's detached side toolbar under niri.
# (隐藏 niri 下安卓模拟器那条独立的侧边工具栏)
#
# Why: the emulator runs via XWayland and spawns its toolbar as an X11
# override-redirect UTILITY window. niri does not manage it, so it floats
# pinned to a fixed screen coordinate and ends up on top of whatever else
# is on that monitor (e.g. WeCom). No niri window-rule can touch it.
# (原因：模拟器跑在 XWayland 上，工具栏是 X11 override-redirect 的 UTILITY
#  窗口，niri 不管理它，它固定在屏幕坐标上漂浮、压住企业微信等窗口，
#  任何 niri window-rule 都碰不到。)
#
# Fix: poll X11; the ONLY Emulator window whose type is _NET_WM_WINDOW_TYPE_UTILITY
# is the toolbar (device + extended-controls windows are NORMAL). Unmap it.
# (做法：轮询 X11，Emulator 窗口里类型为 UTILITY 的就是工具栏，设备窗口和
#  扩展控制窗口都是 NORMAL，直接 unmap 掉。)

set -uo pipefail

# Single-instance guard (单实例保护)
LOCK="/tmp/hide-emulator-toolbar.lock"
exec 9>"$LOCK"
flock -n 9 || { echo "another instance running, exiting" >&2; exit 0; }

export DISPLAY="${DISPLAY:-:0}"
POLL_SEC=2

while true; do
    # All X11 windows of WM_CLASS "Emulator" (所有 class=Emulator 的 X11 窗口)
    for id in $(xdotool search --class "Emulator" 2>/dev/null); do
        # Toolbar = the UTILITY-typed one (工具栏就是 UTILITY 类型那个)
        # unmap is idempotent on an already-hidden window (对已隐藏窗口 unmap 是幂等的)
        if xprop -id "$id" _NET_WM_WINDOW_TYPE 2>/dev/null \
             | grep -q "_NET_WM_WINDOW_TYPE_UTILITY"; then
            xdotool windowunmap "$id" 2>/dev/null
        fi
    done
    sleep "$POLL_SEC"
done
