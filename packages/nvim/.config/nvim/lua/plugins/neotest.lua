-- Neotest 调整：修掉窗口较小时 <leader>to 浮窗开不出来的问题。
-- (Neotest tweak: fix the output float failing to open on small windows.)
--
-- 根因在上游 neotest/lib/ui/float.lua 的尺寸计算：
--   height = math.min(content_height, max_height - 2)
-- max_height 来自 floating.max_height（默认 0.6，屏幕比例）。窗口一小，
-- floor(lines * 0.6) - 2 就变成 0 或负数，nvim_open_win 抛
-- "Invalid 'height': expected positive Integer"，浮窗什么都弹不出来。
-- (Upstream computes min(content, max - 2); on a small screen that drops to
--  <= 0 and nvim_open_win throws, so the float never appears.)
--
-- 修法：不自己开窗，只给 float.open 打一层补丁纠正宽高。
-- 自建窗口会出问题——neotest 先写好终端 buffer 再 nvim_win_set_buf 换进来，
-- 而 open_term 按写入时的当前窗口决定截断宽度，自己开的窗会让排版错位，
-- 结果就是「框出来了但没有日志」。走原版路径能避开这一点。
-- (Patch the geometry instead of supplying our own window: neotest renders the
--  terminal buffer before swapping it into the returned window, and open_term
--  sizes its output from the window current at write time, so a hand-rolled
--  window yields an empty-looking float. Patching keeps the original path.)

---@param lines integer
---@param cols integer
---@return integer avail_h, integer avail_w
local function available(lines, cols)
  -- 预留 cmdline、statusline 和边框各自占用的行列。
  -- (Reserve the cmdline, statusline and border.)
  return math.max(lines - vim.o.cmdheight - 3, 1), math.max(cols - 2, 1)
end

local function patch_float()
  local float = require("neotest.lib.ui.float")
  if float.__clamp_patched then
    return
  end
  float.__clamp_patched = true

  local original = float.open

  ---@diagnostic disable-next-line: duplicate-set-field
  float.open = function(opts)
    -- create_opts 在 M.open 内部调用，外层改 settings 管不到 `max - 2`
    -- 那一项（它在极小尺寸下自己就是负数）。所以临时包一层
    -- nvim_open_win，直接钳制上游算完的最终几何值。
    -- (create_opts runs inside M.open, so tweaking settings cannot fix the
    --  `max - 2` term, which itself goes negative on tiny screens. Wrap
    --  nvim_open_win instead and clamp the final geometry.)
    local api_open = vim.api.nvim_open_win
    local avail_h, avail_w = available(vim.o.lines, vim.o.columns)

    ---@diagnostic disable-next-line: duplicate-set-field
    vim.api.nvim_open_win = function(buf, enter, cfg)
      if cfg and cfg.relative and cfg.relative ~= "" then
        cfg.height = math.max(1, math.min(cfg.height or 1, avail_h))
        cfg.width = math.max(1, math.min(cfg.width or 1, avail_w))
        cfg.row = math.max(0, math.min(cfg.row or 0, math.max(0, vim.o.lines - cfg.height - 2)))
        cfg.col = math.max(0, math.min(cfg.col or 0, math.max(0, vim.o.columns - cfg.width)))
      end
      return api_open(buf, enter, cfg)
    end

    local ok, res = pcall(original, opts)
    vim.api.nvim_open_win = api_open

    if not ok then
      error(res, 0)
    end
    return res
  end
end

return {
  {
    "nvim-neotest/neotest",
    optional = true,
    opts = function(_, opts)
      patch_float()

      -- max_height/max_width 提到接近 1，让上游的比例上限不再成为小窗口的瓶颈；
      -- 真正的合法性由上面的补丁保证。
      -- (Raise the ratio caps so they stop being the bottleneck on small
      --  screens; validity is guaranteed by the patch above.)
      opts.floating = vim.tbl_deep_extend("force", opts.floating or {}, {
        border = "rounded",
        max_height = 0.95,
        max_width = 0.95,
      })

      return opts
    end,
  },
}
