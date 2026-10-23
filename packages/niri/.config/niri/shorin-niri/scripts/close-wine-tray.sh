#!/bin/bash
set -uo pipefail

export DISPLAY="${DISPLAY:-:0}"

readonly HIDDEN_OPACITY=0
readonly VISIBLE_OPACITY=4294967295

# Set X11 opacity without terminating the Wine window. (设置 X11 透明度，不结束 Wine 窗口。)
set_opacity() {
    local xid="$1"
    local opacity="$2"

    xprop -id "$xid" -f _NET_WM_WINDOW_OPACITY 32c \
        -set _NET_WM_WINDOW_OPACITY "$opacity" >/dev/null 2>&1 || true
}

# Return only mapped WeCom main windows. (仅返回已映射的企业微信主窗口。)
list_main_windows() {
    local xid window_class window_state

    while IFS= read -r xid; do
        window_class="$(xprop -id "$xid" WM_CLASS 2>/dev/null || true)"
        [[ "$window_class" == *'"wxwork.exe", "com.qq.weixin.work.deepin"'* ]] || continue
        window_state="$(xprop -id "$xid" WM_STATE 2>/dev/null || true)"
        [[ "$window_state" == *"Normal"* ]] || continue
        printf '%s\n' "$xid"
    done < <(xdotool search --all --name '^企业微信$' 2>/dev/null || true)
}

# Hide titleless Wine explorer tray surfaces without touching app popups. (隐藏无标题 Wine explorer 托盘面，不影响应用弹窗。)
hide_explorer_trays() {
    local xid window_class window_title geometry width height

    while IFS= read -r xid; do
        window_class="$(xprop -id "$xid" WM_CLASS 2>/dev/null || true)"
        [[ "$window_class" == *'"explorer.exe", "com.qq.weixin.work.deepin"'* ]] || continue
        window_title="$(xdotool getwindowname "$xid" 2>/dev/null || true)"
        [[ -z "$window_title" ]] || continue

        geometry="$(xdotool getwindowgeometry --shell "$xid" 2>/dev/null || true)"
        [[ "$geometry" =~ WIDTH=([0-9]+) ]] || continue
        width="${BASH_REMATCH[1]}"
        [[ "$geometry" =~ HEIGHT=([0-9]+) ]] || continue
        height="${BASH_REMATCH[1]}"

        if (( width <= 320 && height <= 64 )); then
            set_opacity "$xid" "$HIDDEN_OPACITY"
        fi
    done < <(xdotool search --all --classname 'explorer.exe' 2>/dev/null || true)
}

# Close the broken layered shadow around the rendered main window. (关闭已渲染主窗周围的异常分层阴影。)
hide_wxwork_shadows() {
    local main_xid main_geometry main_width main_height main_hex
    local xid window_title transient window_type geometry width height width_delta height_delta

    while IFS= read -r main_xid; do
        main_geometry="$(xdotool getwindowgeometry --shell "$main_xid" 2>/dev/null || true)"
        [[ "$main_geometry" =~ WIDTH=([0-9]+) ]] || continue
        main_width="${BASH_REMATCH[1]}"
        [[ "$main_geometry" =~ HEIGHT=([0-9]+) ]] || continue
        main_height="${BASH_REMATCH[1]}"
        printf -v main_hex '0x%x' "$main_xid"

        while IFS= read -r xid; do
            [[ "$xid" != "$main_xid" ]] || continue
            window_title="$(xdotool getwindowname "$xid" 2>/dev/null || true)"
            [[ -z "$window_title" ]] || continue
            transient="$(xprop -id "$xid" WM_TRANSIENT_FOR 2>/dev/null || true)"
            [[ "${transient,,}" == *"${main_hex,,}"* ]] || continue
            window_type="$(xprop -id "$xid" _NET_WM_WINDOW_TYPE 2>/dev/null || true)"
            [[ "$window_type" == *"_NET_WM_WINDOW_TYPE_DIALOG"* ]] || continue

            geometry="$(xdotool getwindowgeometry --shell "$xid" 2>/dev/null || true)"
            [[ "$geometry" =~ WIDTH=([0-9]+) ]] || continue
            width="${BASH_REMATCH[1]}"
            [[ "$geometry" =~ HEIGHT=([0-9]+) ]] || continue
            height="${BASH_REMATCH[1]}"
            width_delta=$((width - main_width))
            height_delta=$((height - main_height))
            (( width_delta >= 34 && width_delta <= 38 )) || continue
            (( height_delta >= 34 && height_delta <= 38 )) || continue

            printf 'Closing WeCom shadow window: xid=%s size=%sx%s\n' "$xid" "$width" "$height"
            xdotool windowclose "$xid" >/dev/null 2>&1 || true
        done < <(xdotool search --all --classname 'wxwork.exe' 2>/dev/null || true)
    done < <(list_main_windows)
}

# Close the known large, titleless CEF startup surface. (关闭已确认的大尺寸、无标题 CEF 启动表面。)
hide_black_wxworkweb() {
    local xid window_class window_title geometry width height

    while IFS= read -r xid; do
        window_class="$(xprop -id "$xid" WM_CLASS 2>/dev/null || true)"
        [[ "$window_class" == *'"wxworkweb.exe", "com.qq.weixin.work.deepin"'* ]] || continue
        window_title="$(xdotool getwindowname "$xid" 2>/dev/null || true)"
        [[ -z "$window_title" ]] || continue

        geometry="$(xdotool getwindowgeometry --shell "$xid" 2>/dev/null || true)"
        [[ "$geometry" =~ WIDTH=([0-9]+) ]] || continue
        width="${BASH_REMATCH[1]}"
        [[ "$geometry" =~ HEIGHT=([0-9]+) ]] || continue
        height="${BASH_REMATCH[1]}"
        (( width >= 1430 && width <= 1434 )) || continue
        (( height >= 774 && height <= 778 )) || continue

        printf 'Closing WeCom CEF startup window: xid=%s size=%sx%s\n' "$xid" "$width" "$height"
        xdotool windowclose "$xid" >/dev/null 2>&1 || true
    done < <(xdotool search --all --classname 'wxworkweb.exe' 2>/dev/null || true)
}

# Remove black startup surfaces until the real UI is ready. (在真实界面就绪前撤销黑色启动表面。)
watch_startup_frame() {
    local deadline=$((SECONDS + 90))
    local scan_count=0

    while (( SECONDS < deadline )); do
        hide_wxwork_shadows
        hide_black_wxworkweb
        if (( scan_count % 5 == 0 )); then
            hide_explorer_trays
        fi
        scan_count=$((scan_count + 1))
        sleep 1
    done
}

# Keep only cheap, infrequent maintenance after startup. (启动后仅保留低频、低开销维护。)
watch_auxiliary_windows() {
    while true; do
        hide_explorer_trays
        hide_wxwork_shadows
        hide_black_wxworkweb
        sleep 10
    done
}

case "${1:-}" in
    --startup)
        watch_startup_frame
        ;;
    *)
        watch_auxiliary_windows
        ;;
esac
