-- 多光标 multi-cursor（独立终端 nvim 专用）
-- 说明：本文件只在终端 nvim 下被 LazyVim 扫描加载（见 init.lua 的 else 分支）。
-- VSCode-Neovim 环境是另一条分支，由 init.lua 内联加载 vscode-multi-cursor.nvim，
-- 不会读到本文件，所以这里无需也不应再声明 vscode 插件。
-- (Terminal-only. VSCode env is handled inline in init.lua's other branch.)
--
-- 用 jake-stewart/multicursor.nvim（纯 Lua，体验最接近 IDEA/VSCode 多光标）。
return {
  {
    "jake-stewart/multicursor.nvim",
    -- 锁定稳定分支 1.0（作者承诺不引入破坏性变更）
    -- (Pin to the stable 1.0 branch as recommended by the author.)
    branch = "1.0",
    -- 进入普通/可视模式即加载，保证首次按键就绪
    -- (Load on entering normal/visual mode so the first keypress works.)
    event = "VeryLazy",
    config = function()
      local mc = require("multicursor-nvim")
      mc.setup()

      local set = vim.keymap.set

      -- ============ 核心：IDEA 风格"选词 + 逐个加选" ============
      -- <C-n>：选中光标下的词，再按则向【下】添加下一个相同匹配的光标
      --        (类似 IDEA Alt+J / VSCode Ctrl+D)
      -- (Select word under cursor, repeat to add a cursor on the next match.)
      set({ "n", "x" }, "<C-n>", function() mc.matchAddCursor(1) end, { desc = "MC: 加选下一个匹配 (Add next match)" })
      -- <C-S-n>：向【上】添加上一个相同匹配（反方向）
      -- (Add a cursor on the previous match, i.e. search backwards.)
      set({ "n", "x" }, "<C-S-n>", function() mc.matchAddCursor(-1) end, { desc = "MC: 加选上一个匹配 (Add prev match)" })

      -- <C-x>：跳过当前匹配，把光标移到下一个匹配（不在当前处留光标）
      --        (类似 IDEA "跳过当前出现" / VSCode Ctrl+K Ctrl+D)
      -- (Skip the current match and jump the cursor to the next one.)
      set({ "n", "x" }, "<C-x>", function() mc.matchSkipCursor(1) end, { desc = "MC: 跳过当前匹配 (Skip match)" })

      -- <leader>mA：一次性选中文件内【所有】相同匹配（Select All Occurrences）
      -- (Add a cursor on every match of the word/selection in the buffer.)
      set({ "n", "x" }, "<leader>mA", mc.matchAllAddCursors, { desc = "MC: 选中所有匹配 (Select all matches)" })

      -- ============ 列编辑：上下方加光标 ============
      -- <A-Down>/<A-Up>：在主光标上/下方逐行添加光标（IDEA Alt+鼠标拖动 / 双击 Ctrl+上下）
      -- 避开 LazyVim 已占用的 <A-j>/<A-k>（那是"移动行"）。
      -- (Add a cursor on the line above/below; avoids LazyVim's <A-j>/<A-k>.)
      set({ "n", "x" }, "<A-Down>", function() mc.lineAddCursor(1) end, { desc = "MC: 下方加光标 (Add cursor below)" })
      set({ "n", "x" }, "<A-Up>", function() mc.lineAddCursor(-1) end, { desc = "MC: 上方加光标 (Add cursor above)" })
      set({ "n", "x" }, "<leader>m<Down>", function() mc.lineSkipCursor(1) end, { desc = "MC: 向下跳过一行 (Skip line down)" })
      set({ "n", "x" }, "<leader>m<Up>", function() mc.lineSkipCursor(-1) end, { desc = "MC: 向上跳过一行 (Skip line up)" })

      -- ============ 鼠标：Ctrl+点击 加/减光标 ============
      -- (Ctrl + click to add/remove cursors, like Alt+click in IDEA.)
      set("n", "<C-LeftMouse>", mc.handleMouse, { desc = "MC: 鼠标加光标 (Mouse add cursor)" })
      set("n", "<C-LeftDrag>", mc.handleMouseDrag, { desc = "MC: 鼠标拖动 (Mouse drag)" })
      set("n", "<C-LeftRelease>", mc.handleMouseRelease, { desc = "MC: 鼠标释放 (Mouse release)" })

      -- 误清光标后找回 (Restore cleared cursors.)
      set("n", "<leader>mr", mc.restoreCursors, { desc = "MC: 恢复光标 (Restore cursors)" })

      -- ============ 仅在"已有多光标"时生效的按键层 ============
      -- 这些映射只在多光标激活期间覆盖原键位，平时完全不影响正常使用。
      -- (Layer keymaps only apply while multiple cursors exist.)
      mc.addKeymapLayer(function(layerSet)
        -- 在多个光标间切换"主光标"
        -- (Rotate which cursor is the main one.)
        layerSet({ "n", "x" }, "<Left>", mc.prevCursor, { desc = "MC: 上一个光标 (Prev cursor)" })
        layerSet({ "n", "x" }, "<Right>", mc.nextCursor, { desc = "MC: 下一个光标 (Next cursor)" })

        -- 删除当前主光标（保留其余）
        -- (Delete the current main cursor, keep the rest.)
        layerSet({ "n", "x" }, "<leader>mx", mc.deleteCursor, { desc = "MC: 删除当前光标 (Delete cursor)" })

        -- <Esc>：先恢复被禁用的光标；否则清除所有额外光标回到单光标
        -- (Esc: re-enable disabled cursors, else collapse back to one cursor.)
        layerSet("n", "<Esc>", function()
          if not mc.cursorsEnabled() then
            mc.enableCursors()
          else
            mc.clearCursors()
          end
        end, { desc = "MC: 退出多光标 (Clear cursors)" })
      end)

      -- ============ 外观：让多光标在 dankcolors 主题下清晰可见 ============
      -- 用 default=false 强制覆盖，避免被主题的默认链接盖掉。
      -- (Make extra cursors clearly visible; force-override theme defaults.)
      local hl = vim.api.nvim_set_hl
      hl(0, "MultiCursorCursor", { reverse = true })
      hl(0, "MultiCursorVisual", { link = "Visual" })
      hl(0, "MultiCursorSign", { link = "SignColumn" })
      hl(0, "MultiCursorMatchPreview", { link = "Search" })
      hl(0, "MultiCursorDisabledCursor", { reverse = true, bold = true })
      hl(0, "MultiCursorDisabledVisual", { link = "Visual" })
      hl(0, "MultiCursorDisabledSign", { link = "SignColumn" })
    end,
  },
}
