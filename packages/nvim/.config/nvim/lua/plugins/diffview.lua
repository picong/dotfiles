-- diffview.nvim — 三方合并冲突解决（IDEA 式）
--
-- 与 config/mergetool.lua 的分工：
--   mergetool.lua  → git mergetool nvimdiff，逐文件驱动，lazygit 里按 X
--   本文件          → 一次打开本次合并的全部冲突文件，lazygit 里按 D
--
-- 注意：diffview 不能配成 git mergetool（作者 sindrets 明确说过做不到，
-- 因为 git mergetool 是逐文件循环、diffview 是一次开完全部）。所以这条路
-- 绕开 mergetool：解决 → stage → git merge --continue。

return {
  "sindrets/diffview.nvim",
  cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory", "DiffviewToggleFiles" },
  keys = {
    { "<leader>gvo", "<cmd>DiffviewOpen<cr>", desc = "Diffview: 打开（冲突时自动三方视图）" },
    { "<leader>gvc", "<cmd>DiffviewClose<cr>", desc = "Diffview: 关闭" },
    { "<leader>gvf", "<cmd>DiffviewToggleFiles<cr>", desc = "Diffview: 切换文件面板" },
    { "<leader>gvh", "<cmd>DiffviewFileHistory %<cr>", desc = "Diffview: 当前文件历史" },
    { "<leader>gvH", "<cmd>DiffviewFileHistory<cr>", desc = "Diffview: 仓库历史" },
  },
  opts = function()
    local actions = require("diffview.actions")

    return {
      enhanced_diff_hl = true, -- 冲突区域用更强的高亮
      view = {
        -- 三方合并视图：上排 OURS | 中间可写 | THEIRS，这是最像 IDEA 的布局
        merge_tool = {
          layout = "diff3_mixed",
          disable_diagnostics = true, -- 冲突标记会让 LSP 疯狂报错
          winbar_info = true, -- 窗口上方标注每个 buffer 是谁
        },
        default = { layout = "diff2_horizontal" },
        file_history = { layout = "diff2_horizontal" },
      },
      file_panel = {
        listing_style = "tree",
        win_config = { position = "left", width = 32 },
      },
      keymaps = {
        view = {
          { "n", "<leader>gvq", "<cmd>DiffviewClose<cr>", { desc = "关闭 diffview" } },
          -- ]x / [x 与 config/mergetool.lua 保持一致的导航手感
          { "n", "]x", actions.next_conflict, { desc = "下一个冲突" } },
          { "n", "[x", actions.prev_conflict, { desc = "上一个冲突" } },
        },
        file_panel = {
          { "n", "]x", actions.next_conflict, { desc = "下一个冲突" } },
          { "n", "[x", actions.prev_conflict, { desc = "上一个冲突" } },
          { "n", "<leader>gvq", "<cmd>DiffviewClose<cr>", { desc = "关闭 diffview" } },
        },
      },
    }
  end,
}
