#!/bin/bash
# Tame Tencent Meeting (WeMeet, deepin-wine) windows under niri.
# (驯服 niri 下的腾讯会议 WeMeet 窗口)
#
# Does two things on a poll loop (轮询做两件事):
#   1) The voice bar — a 242x72 window titled "企业微信-会议" with min==max size
#      hints (cannot be resized) — is shoved off-screen so it stops blocking.
#      (语音悬浮条「企业微信-会议」无法缩放，挪到屏幕外。)
#   2) The meeting main window opens FLOATING and gets dumped on the far left;
#      we auto-tile it once so it joins the niri layout. We tile each window id
#      only once, so manually floating it again afterwards is respected.
#      (会议主窗口默认浮动并被丢到最左边，自动转平铺一次；每个 id 只处理一次，
#       之后你手动再浮动会被尊重。)

set -uo pipefail

# Single-instance guard via flock (用 flock 保证单实例)
LOCK="/tmp/meeting-voicebar-hide.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
    echo "another instance is already running, exiting" >&2
    exit 0
fi

APP_ID="com.qq.weixin.work.deepin"
BAR_TITLE="企业微信-会议"   # voice bar title (语音条标题，需排除在平铺之外)
OFFSCREEN_DX=-5000          # large negative X shove (挪出屏外的负向偏移)
POLL_SEC=1

declare -A TILED            # window ids we've already auto-tiled (已平铺过的窗口 id)

while true; do
    SNAP="$(niri msg --json windows 2>/dev/null || true)"

    if [ -n "$SNAP" ]; then
        # --- 1) shove the voice bar off-screen (把语音条挪出屏外) ---
        read -r WID PX < <(
            printf '%s' "$SNAP" | jq -r --arg t "$BAR_TITLE" --arg a "$APP_ID" '
                .[]
                | select(.app_id == $a and .title == $t and .is_floating == true)
                | "\(.id) \(.layout.tile_pos_in_workspace_view[0] // 0)"' | head -n1
        )
        if [ -n "${WID:-}" ]; then
            px_int="${PX%.*}"
            if [ "${px_int:-0}" -gt -2000 ] 2>/dev/null; then
                niri msg action move-floating-window --id "$WID" -x="$OFFSCREEN_DX" >/dev/null 2>&1
            fi
        fi

        # --- 2) auto-tile floating meeting main windows (自动平铺浮动的会议主窗) ---
        # Match app-id + title ending in 会议, excluding the voice bar.
        # (匹配 app-id + 标题以「会议」结尾，排除语音条。)
        while read -r MID; do
            [ -z "$MID" ] && continue
            [ -n "${TILED[$MID]:-}" ] && continue        # already handled (已处理过)
            niri msg action move-window-to-tiling --id "$MID" >/dev/null 2>&1
            TILED[$MID]=1
        done < <(
            printf '%s' "$SNAP" | jq -r --arg a "$APP_ID" --arg bar "$BAR_TITLE" '
                .[]
                | select(.app_id == $a
                         and .is_floating == true
                         and (.title | test("会议$"))
                         and .title != $bar)
                | .id'
        )
    fi

    sleep "$POLL_SEC"
done
