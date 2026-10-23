-- 三方合并（git mergetool nvimdiff）专用键位
--
-- git 调起时的窗口结构（由 gitconfig 的 mergetool.nvimdiff.layout 决定）：
--   tab1: 上排 LOCAL | BASE | REMOTE，下排 MERGED（唯一要写的 buffer）
--   tab2: BASE <-> LOCAL      tab3: BASE <-> REMOTE
--
-- 键位只在检测到 LOCAL/REMOTE 临时 buffer 时才挂，平时编辑代码不受影响。
-- 采用 co/ct/cb 这套社区惯例命名（与 git-conflict.nvim 一致）。

local M = {}

-- git mergetool 生成的临时文件名形如 f_LOCAL_12345.txt
function M.in_mergetool()
  local has_local, has_remote = false, false
  for _, buf in ipairs(vim.api.nvim_list_bufs() or {}) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:match("_LOCAL_%d+") then
      has_local = true
    elseif name:match("_REMOTE_%d+") then
      has_remote = true
    end
  end
  return has_local and has_remote
end

-- MERGED 在 layout 中是最后一个窗口
local function goto_merged()
  vim.cmd("wincmd b")
end

local function take(range, which)
  return function()
    goto_merged()
    vim.cmd(range .. "diffget " .. which)
    vim.cmd("diffupdate")
  end
end

-- 残留冲突标记时拒绝保存，避免把 <<<<<<< 写进提交
local function save_if_clean()
  goto_merged()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:match("^<<<<<<<") or line:match("^>>>>>>>") or line:match("^|||||||") then
      vim.notify(("第 %d 行仍有冲突标记，未保存"):format(i), vim.log.levels.WARN)
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
  vim.cmd("wqa")
end

function M.setup()
  if not M.in_mergetool() then
    return
  end

  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { desc = desc, silent = true })
  end

  -- 单个 hunk 取舍（光标先停在 MERGED 的冲突块上）
  map("co", take("", "LOCAL"), "取本 hunk 的 ours（LOCAL/HEAD）")
  map("ct", take("", "REMOTE"), "取本 hunk 的 theirs（REMOTE）")
  map("cb", take("", "BASE"), "取本 hunk 的 base（共同祖先）")

  -- 整文件取舍
  map("cO", take("%", "LOCAL"), "整文件都要 ours")
  map("cT", take("%", "REMOTE"), "整文件都要 theirs")
  map("cB", take("%", "BASE"), "整文件都要 base")

  -- 导航
  map("]x", "]c", "下一个冲突 hunk")
  map("[x", "[c", "上一个冲突 hunk")

  -- 收尾
  map("<leader>gw", save_if_clean, "保存退出（git 随即自动 add）")
  map("<leader>gq", "<cmd>cquit<cr>", "放弃本文件（返回非零退出码）")

  vim.notify("三方合并：co/ct/cb 取 hunk，cO/cT 整文件，]x/[x 导航，<leader>gw 保存", vim.log.levels.INFO)
end

-- 加载时机：LazyVim 在 VeryLazy 才 require 本文件，那时 VimEnter 可能已经过去，
-- 单挂 VimEnter 会漏。所以两头都覆盖——已进入则立刻执行，否则等 VimEnter。
if vim.v.vim_did_enter == 1 then
  M.setup()
else
  vim.api.nvim_create_autocmd("VimEnter", {
    group = vim.api.nvim_create_augroup("mergetool_keys", { clear = true }),
    callback = M.setup,
  })
end

return M
