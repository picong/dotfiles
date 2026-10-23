#!/bin/bash
# Resize dispatcher for Tencent Meeting (WeMeet) windows under deepin-wine.
# (腾讯会议/企微融合会议窗口的缩放分发器：deepin-wine 下的 WeMeet 窗口)
#
# Why this exists (存在原因):
#   niri's Wayland resize requests are IGNORED by the WeMeet window, but the
#   X11-native XResizeWindow (xdotool windowsize) IS honored. So for meeting
#   windows we resize via xdotool; for any other window we forward the original
#   intent to niri unchanged.
#   (niri 走 Wayland 的 resize 请求被 WeMeet 忽略，但 X11 原生的 windowsize 有效；
#    因此会议窗口用 xdotool 缩放，其它窗口原样转发给 niri。)
#
# Usage (用法): meeting-resize.sh <wider|narrower|taller|shorter|max>

set -euo pipefail

export DISPLAY="${DISPLAY:-:0}"

ACTION="${1:-}"
STEP_PCT=5          # resize step percentage (缩放步进百分比)
MARGIN=20           # screen margin for "max" (满屏时的边距)

# --- niri fallback: forward the equivalent native command (转发给 niri 的等价命令) ---
niri_fallback() {
    case "$ACTION" in
        wider)    niri msg action set-column-width "+${STEP_PCT}%" ;;
        narrower) niri msg action set-column-width "-${STEP_PCT}%" ;;
        taller)   niri msg action set-window-height "+${STEP_PCT}%" ;;
        shorter)  niri msg action set-window-height "-${STEP_PCT}%" ;;
        max)      niri msg action maximize-column ;;
        *) echo "unknown action: $ACTION" >&2; exit 2 ;;
    esac
}

# --- find the focused niri window; bail to niri if we can't read it ---
# (读取 niri 当前焦点窗口；读不到就直接走 niri)
FW_JSON="$(niri msg --json focused-window 2>/dev/null || true)"
[ -z "$FW_JSON" ] && { niri_fallback; exit 0; }

APP_ID="$(printf '%s' "$FW_JSON" | jq -r '.app_id // ""')"

# Only meeting windows (deepin-wine WXWork/WeMeet) go through xdotool.
# (只有会议窗口走 xdotool 分支)
if [ "$APP_ID" != "com.qq.weixin.work.deepin" ]; then
    niri_fallback
    exit 0
fi

TITLE="$(printf '%s' "$FW_JSON" | jq -r '.title // ""')"

# Locate the matching X11 window by title among wwmapp.exe windows.
# (在 wwmapp.exe 的 X 窗口里按标题匹配出对应的 X11 窗口)
XID=""
for id in $(xdotool search --class "com.qq.weixin.work.deepin" 2>/dev/null); do
    name="$(xdotool getwindowname "$id" 2>/dev/null || true)"
    if [ -n "$name" ] && [ "$name" = "$TITLE" ]; then
        XID="$id"
        break
    fi
done

# No X11 handle found -> let niri try (找不到 X 句柄就回退 niri)
[ -z "$XID" ] && { niri_fallback; exit 0; }

# Current geometry (当前几何尺寸)
eval "$(xdotool getwindowgeometry --shell "$XID" 2>/dev/null)"
cur_w="${WIDTH:-0}"
cur_h="${HEIGHT:-0}"
[ "$cur_w" -le 0 ] && { niri_fallback; exit 0; }

new_w="$cur_w"
new_h="$cur_h"

case "$ACTION" in
    wider)    new_w=$(( cur_w + cur_w * STEP_PCT / 100 )) ;;
    narrower) new_w=$(( cur_w - cur_w * STEP_PCT / 100 )) ;;
    taller)   new_h=$(( cur_h + cur_h * STEP_PCT / 100 )) ;;
    shorter)  new_h=$(( cur_h - cur_h * STEP_PCT / 100 )) ;;
    max)
        # Fill the output the window currently sits on (填满窗口所在显示器)
        read -r out_w out_h < <(
            niri msg --json outputs 2>/dev/null | jq -r --argjson x "${X:-0}" --argjson y "${Y:-0}" '
                [ .[] | .logical as $l
                  | select($x >= $l.x and $x < ($l.x + $l.width)
                           and $y >= $l.y and $y < ($l.y + $l.height)) ]
                | (.[0] // {logical:{width:1280,height:800}})
                | "\(.logical.width) \(.logical.height)"'
        )
        new_w=$(( out_w - MARGIN * 2 ))
        new_h=$(( out_h - MARGIN * 2 ))
        ;;
    *) echo "unknown action: $ACTION" >&2; exit 2 ;;
esac

# Clamp to sane minimums (限制最小尺寸)
[ "$new_w" -lt 320 ] && new_w=320
[ "$new_h" -lt 240 ] && new_h=240

xdotool windowsize "$XID" "$new_w" "$new_h"
