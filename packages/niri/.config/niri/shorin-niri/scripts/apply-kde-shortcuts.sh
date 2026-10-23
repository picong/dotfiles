#!/bin/bash
# ============================================================
# apply-kde-shortcuts.sh - Apply niri-style shortcuts to KDE Plasma
# 将 niri 风格快捷键应用到 KDE Plasma
# ============================================================

set -e

BACKUP_DIR="$HOME/.config/kde-shortcuts-backup-$(date +%Y%m%d_%H%M%S)"
echo "=== KDE 快捷键迁移工具 (niri → KDE) ==="
echo "备份目录: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

cp "$HOME/.config/kglobalshortcutsrc" "$BACKUP_DIR/" 2>/dev/null || true
cp "$HOME/.config/khotkeysrc" "$BACKUP_DIR/" 2>/dev/null || true
cp "$HOME/.config/kwinrc" "$BACKUP_DIR/" 2>/dev/null || true
echo "✓ 配置已备份"

# ============================================================
# 生成新的 kglobalshortcutsrc
# ============================================================
# 注意: KDE 在 rc 文件中使用字面量 \t (反斜杠+t, 不是真正制表符)
# 所以不能用 kwriteconfig6 (会自动转义), 直接生成新文件
# ============================================================

SRC="$BACKUP_DIR/kglobalshortcutsrc"
DST="$HOME/.config/kglobalshortcutsrc"

# 先基于备份文件修改
cp "$SRC" "$DST.tmp"

# 辅助函数: 按完整键名替换，避免 sed 正则误匹配
replace_line() {
    local pattern="${1#^}"
    pattern="${pattern%\\$}"
    local replacement="$2"
    awk -v key="$pattern" -v value="$replacement" '
        index($0, key "=") == 1 { print key "=" value; next }
        { print }
    ' "$DST.tmp" > "$DST.tmp.new"
    mv "$DST.tmp.new" "$DST.tmp"
}

echo "--- 设置 KWin 窗口管理快捷键 ---"

# 虚拟桌面 1-9 (Niri: Mod+1~9 = focus-workspace 1~9)
for i in 1 2 3 4; do
    replace_line "Switch to Desktop $i" "Meta+F${i}\\\\tCtrl+F${i},Meta+${i},切换到桌面 ${i}"
done
for i in 5 6 7 8 9; do
    replace_line "Switch to Desktop $i" "none,Meta+${i},切换到桌面 ${i}"
done

# 窗口移动到桌面 (Niri: Mod+Ctrl+1~9 = move-column-to-workspace)
for i in $(seq 1 9); do
    replace_line "Window to Desktop $i" "none,Meta+Ctrl+${i},窗口移动到桌面 ${i}"
done

# 桌面上下切换 (Niri: Mod+U/I = focus-workspace down/up)
replace_line "Switch One Desktop Down" "Meta+Ctrl+Down,Meta+U,切换到下方桌面"
replace_line "Switch One Desktop Up" "Meta+Ctrl+Up,Meta+I,切换到上方桌面"

# 窗口上下移动桌面 (Niri: Mod+Ctrl+U/I)
replace_line "Window One Desktop Down" "Meta+Ctrl+Shift+Down,Meta+Ctrl+U,窗口下移一个桌面"
replace_line "Window One Desktop Up" "Meta+Ctrl+Shift+Up,Meta+Ctrl+I,窗口上移一个桌面"

# 关闭窗口 (Niri: Mod+Q = close-window; 保留 Alt+F4)
replace_line "Window Close" "Alt+F4,Alt+F4\\tMeta+Q,关闭窗口"

# 最大化 (Niri: Mod+F = maximize-column; 保留 Meta+PgUp)
replace_line "Window Maximize" "Meta+PgUp,Meta+F\\tMeta+PgUp,最大化窗口"

# 全屏 (Niri: Mod+Alt+F = fullscreen)
replace_line "Window Fullscreen" "none,Meta+Alt+F,全屏显示窗口"

# 总览 / 网格视图
replace_line "Overview" "none,Meta+O,显示/隐藏桌面总览"
replace_line "Grid View" "none,Meta+G,切换网格视图"
# KWin 原生方向动作承担 niri 的 focus-column / focus-window。
replace_line "Switch Window Left" "none,Meta+H,向左聚焦窗口"
replace_line "Switch Window Down" "none,Meta+J,向下聚焦窗口"
replace_line "Switch Window Up" "none,Meta+K,向上聚焦窗口"
replace_line "Switch Window Right" "none,Meta+L,向右聚焦窗口"
replace_line "Window Pack Left" "none,Meta+Ctrl+H,向左移动窗口"
replace_line "Window Pack Down" "none,Meta+Ctrl+J,向下移动窗口"
replace_line "Window Pack Up" "none,Meta+Ctrl+K,向上移动窗口"
replace_line "Window Pack Right" "none,Meta+Ctrl+L,向右移动窗口"

# Mod+方向保留给聚焦；快速铺放改用 Mod+Alt+方向。
replace_line "Window Quick Tile Left" "none,Meta+Alt+Left,快速铺放窗口到左侧"
replace_line "Window Quick Tile Bottom" "none,Meta+Alt+Down,快速铺放窗口到下方"
replace_line "Window Quick Tile Top" "none,Meta+Alt+Up,快速铺放窗口到上方"
replace_line "Window Quick Tile Right" "none,Meta+Alt+Right,快速铺放窗口到右侧"

# 显示器聚焦 / 窗口跨显示器移动。
replace_line "Switch to Screen to the Left" "none,Meta+Shift+Left,聚焦左侧显示器"
replace_line "Switch to Screen Below" "none,Meta+Shift+Down,聚焦下方显示器"
replace_line "Switch to Screen Above" "none,Meta+Shift+Up,聚焦上方显示器"
replace_line "Switch to Screen to the Right" "none,Meta+Shift+Right,聚焦右侧显示器"
replace_line "Window One Screen to the Left" "none,Meta+Ctrl+Shift+Left,移动窗口到左侧显示器"
replace_line "Window One Screen Down" "none,Meta+Ctrl+Shift+Down,移动窗口到下方显示器"
replace_line "Window One Screen Up" "none,Meta+Ctrl+Shift+Up,移动窗口到上方显示器"
replace_line "Window One Screen to the Right" "none,Meta+Ctrl+Shift+Right,移动窗口到右侧显示器"

# --- 方向聚焦与窗口移动 ---
replace_line "Walk Through Windows\$" "Meta+Tab\\\\tAlt+Tab,Meta+Tab\\\\tAlt+Tab,遍历窗口"
replace_line "Walk Through Windows (Reverse)" "Meta+Shift+Tab\\\\tAlt+Shift+Tab,Meta+Shift+Tab\\\\tAlt+Shift+Tab,遍历窗口 (反向)"
replace_line "Walk Through Windows of Current Application\$" "Meta+\`\\\\tAlt+\`,Meta+\`\\\\tAlt+\`,遍历当前应用程序窗口"

# 编辑磁贴 改到 Meta+Shift+T (释放 Meta+T)
replace_line "Edit Tiles" "Meta+T,Meta+Shift+T,磁贴编辑器开关"

# 屏幕切换 (Niri: Mod+Shift+Arrows = focus-monitor)
replace_line "Switch to Next Screen" "none,Meta+Shift+L,切换到下一屏幕"
replace_line "Switch to Previous Screen" "none,Meta+Shift+H,切换到上一屏幕"
replace_line "Window to Next Screen" "Meta+Shift+Right,Meta+Shift+Ctrl+L,移动窗口到下一屏幕"
replace_line "Window to Previous Screen" "Meta+Shift+Left,Meta+Shift+Ctrl+H,移动窗口到上一屏幕"


echo "--- 设置 Plasma Shell 快捷键 ---"

# 应用启动器 (Niri: Mod+Space)
replace_line "activate application launcher" "Meta\\\\tAlt+F1,Meta\\\\tAlt+F1\\\\tMeta+Space,激活应用程序启动器"

# 取消任务管理器 Meta+1~9 (避免与桌面切换冲突)
for i in $(seq 1 9); do
    replace_line "activate task manager entry $i" "Meta+${i},none,激活任务管理器条目 ${i}"
done

# 取消活动快捷键 (释放 Meta+Q, Meta+A)
replace_line "manage activities" "Meta+Q,none,显示活动切换器"
replace_line "next activity" "Meta+A,none,遍历活动"
replace_line "previous activity" "Meta+Shift+A,none,遍历活动 (反向)"

# 剪贴板 (Niri: Mod+Alt+V = clipboard; 保留 Meta+V)
replace_line "show-on-mouse-pos" "Meta+V,Meta+V\\\\tMeta+Alt+V,在鼠标位置显示剪贴板项目"


echo "--- 设置会话管理快捷键 ---"

# 锁屏 (Niri: Mod+Alt+L = lock; Mod+L 保留给向右聚焦)
replace_line "^Lock Session" "Screensaver,Meta+Alt+L,锁定会话"

# 注销 (Niri: Mod+Shift+E; 释放 Ctrl+Alt+Del)
replace_line "^Log Out" "Ctrl+Alt+Del,Meta+Shift+E,显示注销屏幕"


echo "--- 设置输入法快捷键 ---"

# 释放 Meta+Alt+L 和 Meta+Alt+K 用于锁屏和移动工作区
replace_line "Switch to Last-Used Keyboard Layout" "Meta+Alt+L,none,Switch to Last-Used Keyboard Layout"
replace_line "Switch to Next Keyboard Layout" "Meta+Alt+K,none,Switch to Next Keyboard Layout"


echo "--- 设置电源管理快捷键 ---"

replace_line "^Sleep" "Sleep,Sleep\\\\tMeta+Alt+P,挂起"
replace_line "^Turn Off Screen" "none,Meta+Ctrl+P,关闭屏幕"
replace_line "powerProfile" "Battery\\\\tMeta+B,none,切换电源管理方案"


echo "--- 应用 kglobalshortcutsrc ---"
mv "$DST.tmp" "$DST"


# ============================================================
# KWin 其他配置 (使用 kwriteconfig6, 不需要 \t 转义)
# ============================================================
echo "--- 设置 KWin 其他配置 ---"
kwriteconfig6 --file kwinrc --group "Desktops" --key "Number" "9"
kwriteconfig6 --file kwinrc --group "Desktops" --key "Rows" "1"


# ============================================================
# Spectacle 截图快捷键
# ============================================================
echo "--- 设置 Spectacle 截图快捷键 ---"
kwriteconfig6 --file spectaclerc --group "Shortcuts" --key "RectangularRegion" "Print"
kwriteconfig6 --file spectaclerc --group "Shortcuts" --key "ActiveWindow" "Ctrl+Print"
kwriteconfig6 --file spectaclerc --group "Shortcuts" --key "CurrentScreen" "Shift+Print"
kwriteconfig6 --file spectaclerc --group "Shortcuts" --key "FullScreen" "none"


# ============================================================
# 自定义应用快捷键 (khotkeysrc)
# ============================================================
echo "--- 创建自定义应用快捷键 ---"

cat > "$HOME/.config/khotkeysrc" << 'KHOTKEYS_EOF'
[Data]
DataCount=10

[Data_1]
Comment=Browser (浏览器)
Enabled=true
Name=Launch Browser
Type=SIMPLE_ACTION_DATA

[Data_1Actions]
ActionsCount=1

[Data_1Actions0]
CommandURL=/usr/bin/zen-browser
Type=COMMAND_URL

[Data_1Triggers]
TriggersCount=1

[Data_1Triggers0]
Key=Meta+B
Type=SHORTCUT
Uuid={b1a2c3d4-e5f6-7890-abcd-ef1234567890}

[Data_2]
Comment=Terminal (终端)
Enabled=true
Name=Launch Terminal
Type=SIMPLE_ACTION_DATA

[Data_2Actions]
ActionsCount=1

[Data_2Actions0]
CommandURL=/usr/bin/kitty --single-instance
Type=COMMAND_URL

[Data_2Triggers]
TriggersCount=1

[Data_2Triggers0]
Key=Meta+T
Type=SHORTCUT
Uuid={b2a2c3d4-e5f6-7890-abcd-ef1234567891}

[Data_3]
Comment=File Manager (文件管理器)
Enabled=true
Name=Launch File Manager
Type=SIMPLE_ACTION_DATA

[Data_3Actions]
ActionsCount=1

[Data_3Actions0]
CommandURL=/usr/bin/thunar
Type=COMMAND_URL

[Data_3Triggers]
TriggersCount=1

[Data_3Triggers0]
Key=Meta+E
Type=SHORTCUT
Uuid={b3a2c3d4-e5f6-7890-abcd-ef1234567892}

[Data_4]
Comment=System Monitor (任务管理器)
Enabled=true
Name=Launch System Monitor
Type=SIMPLE_ACTION_DATA

[Data_4Actions]
ActionsCount=1

[Data_4Actions0]
CommandURL=/usr/bin/plasma-systemmonitor
Type=COMMAND_URL

[Data_4Triggers]
TriggersCount=2

[Data_4Triggers0]
Key=Meta+M
Type=SHORTCUT
Uuid={b4a2c3d4-e5f6-7890-abcd-ef1234567893}

[Data_4Triggers1]
Key=Ctrl+Alt+Delete
Type=SHORTCUT
Uuid={b4b2c3d4-e5f6-7890-abcd-ef1234567893}

[Data_5]
Comment=Settings (系统设置)
Enabled=true
Name=Launch Settings
Type=SIMPLE_ACTION_DATA

[Data_5Actions]
ActionsCount=1

[Data_5Actions0]
CommandURL=/usr/bin/systemsettings
Type=COMMAND_URL

[Data_5Triggers]
TriggersCount=1

[Data_5Triggers0]
Key=Meta+F2
Type=SHORTCUT
Uuid={b5a2c3d4-e5f6-7890-abcd-ef1234567894}

[Data_6]
Comment=Screen Record (录屏)
Enabled=true
Name=Screen Record
Type=SIMPLE_ACTION_DATA

[Data_6Actions]
ActionsCount=1

[Data_6Actions0]
CommandURL=$HOME/.local/bin/wf-recorder-menu
Type=COMMAND_URL

[Data_6Triggers]
TriggersCount=1

[Data_6Triggers0]
Key=Meta+F3
Type=SHORTCUT
Uuid={b6a2c3d4-e5f6-7890-abcd-ef1234567895}

[Data_7]
Comment=Quick Terminal (浮动终端)
Enabled=true
Name=Quick Terminal
Type=SIMPLE_ACTION_DATA

[Data_7Actions]
ActionsCount=1

[Data_7Actions0]
CommandURL=/usr/bin/kitty --single-instance --class quickterminal
Type=COMMAND_URL

[Data_7Triggers]
TriggersCount=1

[Data_7Triggers0]
Key=Meta+Slash
Type=SHORTCUT
Uuid={b7a2c3d4-e5f6-7890-abcd-ef1234567896}

[Data_8]
Comment=Toggle Fcitx5 (开关输入法)
Enabled=true
Name=Toggle Fcitx5
Type=SIMPLE_ACTION_DATA

[Data_8Actions]
ActionsCount=1

[Data_8Actions0]
CommandURL=/bin/sh -c "pkill fcitx5 || fcitx5"
Type=COMMAND_URL

[Data_8Triggers]
TriggersCount=1

[Data_8Triggers0]
Key=Meta+F1
Type=SHORTCUT
Uuid={b8a2c3d4-e5f6-7890-abcd-ef1234567897}

[Data_9]
Comment=Spectacle Area Screenshot (区域截图)
Enabled=true
Name=Spectacle Area Screenshot
Type=SIMPLE_ACTION_DATA

[Data_9Actions]
ActionsCount=1

[Data_9Actions0]
CommandURL=/usr/bin/spectacle -rb
Type=COMMAND_URL

[Data_9Triggers]
TriggersCount=1

[Data_9Triggers0]
Key=Print
Type=SHORTCUT
Uuid={b9a2c3d4-e5f6-7890-abcd-ef1234567898}

[Data_10]
Comment=Spectacle Fullscreen Screenshot (全屏截图)
Enabled=true
Name=Spectacle Fullscreen Screenshot
Type=SIMPLE_ACTION_DATA

[Data_10Actions]
ActionsCount=1

[Data_10Actions0]
CommandURL=/usr/bin/spectacle -fb
Type=COMMAND_URL

[Data_10Triggers]
TriggersCount=1

[Data_10Triggers0]
Key=Shift+Print
Type=SHORTCUT
Uuid={b10a2c3d4-e5f6-7890-abcd-ef1234567899}

[Main]
Disabled=false
KHOTKEYS_EOF

echo "✓ khotkeysrc 已创建"


echo ""
echo "============================================="
echo "  KDE 快捷键配置完成！"
echo "============================================="
echo ""
echo "备份目录: $BACKUP_DIR"
echo ""
echo "已配置的快捷键概览:"
echo "---------------------------------------------------"
echo "  应用启动:"
echo "    Super+B          → 浏览器 (zen-browser)"
echo "    Super+T          → 终端 (kitty)"
echo "    Super+E          → 文件管理器 (thunar)"
echo "    Super+M          → 任务管理器 (plasma-systemmonitor)"
echo "    Super+F2         → 系统设置 (systemsettings)"
echo "    Super+F3         → 录屏 (wf-recorder-menu)"
echo "    Super+/          → 浮动终端 (kitty quickterminal)"
echo "    Super+Space      → 应用启动器"
echo "    Super+F1         → 开关 Fcitx5 输入法"
echo "    Ctrl+Alt+Delete  → 任务管理器"
echo ""
echo "  窗口管理:"
echo "    Super+Q / Alt+F4      → 关闭窗口"
echo "    Super+F / PgUp        → 最大化"
echo "    Super+Alt+F           → 全屏"
echo "    Super+O/G/W           → 桌面总览"
echo "    Super+D               → 显示桌面"
echo "    Super+←↑↓→           → 快速铺放窗口"
echo "    Super+Shift+Esc       → 禁用输入捕获"
echo "    Super+Ctrl+Esc        → 强制终止窗口"
echo ""
echo "  虚拟桌面:"
echo "    Super+1~9            → 切换到桌面 1~9"
echo "    Super+Ctrl+1~9       → 移动窗口到桌面 1~9"
echo "    Super+U / I          → 下/上切换桌面"
echo "    Super+Ctrl+U / I     → 窗口下/上移动桌面"
echo "    Super+Ctrl+←→       → 左/右切换桌面"
echo "    Super+Ctrl+Shift+←→ → 窗口左/右移动桌面"
echo ""
echo "  显示器切换:"
echo "    Super+Shift+H / L           → 上/下一屏幕"
echo "    Super+Shift+Ctrl+H / L      → 移动窗口到上/下一屏幕"
echo ""
echo "  窗口遍历:"
echo "    Alt+Tab / Super+Tab         → 遍历窗口"
echo "    Alt+Shift+Tab / Super+Shift+Tab → 反向遍历"
echo "    Alt+\` / Super+\`            → 遍历当前应用窗口"
echo ""
echo "  截图:"
echo "    Print        → 区域截图 (Spectacle)"
echo "    Ctrl+Print   → 窗口截图"
echo "    Shift+Print  → 屏幕截图"
echo ""
echo "  会话:"
echo "    Super+L / Alt+L             → 锁屏"
echo "    Super+Alt+P                 → 挂起"
echo "    Super+Shift+E               → 注销"
echo "    Super+Ctrl+P                → 关闭屏幕"
echo ""
echo "  剪贴板:"
echo "    Super+V / Super+Alt+V       → 剪贴板"
echo "---------------------------------------------------"
echo ""
echo "重启 KDE 或运行以下命令使配置生效:"
echo "  systemctl --user restart plasma-plasmashell.service"
echo ""
echo "如要恢复原始配置:"
echo "  cp $BACKUP_DIR/kglobalshortcutsrc ~/.config/"
echo "  cp $BACKUP_DIR/khotkeysrc ~/.config/"
echo "  cp $BACKUP_DIR/kwinrc ~/.config/"
echo "============================================="
