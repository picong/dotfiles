-- ctags 扫描进度反馈 (ctags scan progress feedback)
-- ---------------------------------------------------------------------------
-- gutentags 调 universal-ctags 生成 tags，ctags 本身【不汇报百分比】，
-- 它只是一个一次性子进程。能拿到的真实信号有两个：
--   1. gutentags#inprogress() —— 二元状态：是否正在扫。
--   2. 临时文件 <tagfile>.temp 的大小 —— 扫描中持续增长，扫完原子重命名。
-- 本模块把这两个信号组合成：开始通知 + 实时大小轮询 + 完成通知。
-- (ctags reports NO percentage; we surface the in-progress flag plus the
--  growing temp-file size, which is the only real progress signal we have.)
local M = {}

-- 把字节数格式化为人类可读 (human-readable byte size)
local function human_size(bytes)
  if not bytes or bytes < 0 then
    return "?"
  end
  local units = { "B", "KB", "MB", "GB" }
  local i = 1
  local n = bytes
  while n >= 1024 and i < #units do
    n = n / 1024
    i = i + 1
  end
  if i == 1 then
    return string.format("%d %s", n, units[i])
  end
  return string.format("%.1f %s", n, units[i])
end

-- 取某 buffer 对应的 ctags tags 文件路径（gutentags attach 后写入 b:gutentags_files）
-- (Resolve the ctags tagfile path for a buffer; set once gutentags attaches.)
local function tagfile_for(buf)
  local ok, files = pcall(vim.api.nvim_buf_get_var, buf, "gutentags_files")
  if ok and type(files) == "table" and files.ctags then
    return files.ctags
  end
  return nil
end

-- gutentags 当前是否正在为该 buffer 扫描 (is a scan running for this buffer?)
local function is_scanning(buf)
  return vim.api.nvim_buf_call(buf, function()
    local mods = vim.fn["gutentags#inprogress"]()
    return type(mods) == "table" and #mods > 0
  end)
end

-- 触发一次 ctags 扫描，并启动进度跟踪。
-- (Trigger a ctags scan and start tracking progress.)
function M.scan(buf)
  buf = buf or vim.api.nvim_get_current_buf()

  -- 1) 向上找 pom.xml，确认是 Maven 项目 (confirm a Maven project upward)
  local fname = vim.api.nvim_buf_get_name(buf)
  local pom = vim.fs.find("pom.xml", { upward = true, path = vim.fs.dirname(fname) })[1]
  if not pom then
    vim.notify(
      "Not a Maven project (no pom.xml found upward); ctags scan skipped",
      vim.log.levels.WARN,
      { title = "gutentags" }
    )
    return
  end
  local proj = vim.fs.dirname(pom)

  -- 2) 确认 gutentags 已 attach（buffer 局部命令 GutentagsUpdate 已定义）
  -- (Ensure gutentags attached: the buffer-local command must exist.)
  local has_cmd = vim.api.nvim_buf_call(buf, function()
    return vim.fn.exists(":GutentagsUpdate") == 2
  end)
  if not has_cmd then
    vim.notify(
      "gutentags not attached to this buffer; cannot scan",
      vim.log.levels.WARN,
      { title = "gutentags" }
    )
    return
  end

  -- 3) 已在扫描中则不重复触发 (don't stack scans)
  if is_scanning(buf) then
    vim.notify("A ctags scan is already running for this project", vim.log.levels.WARN, { title = "gutentags" })
    M.status(buf)
    return
  end

  -- 4) 触发全量重扫。GutentagsUpdate! 是同步登记任务的，返回时已 in-progress。
  -- (Fire a full rescan; the job is registered synchronously on return.)
  local tagfile = tagfile_for(buf)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("GutentagsUpdate!")
  end)
  vim.notify("ctags scan started: " .. proj, vim.log.levels.INFO, { title = "gutentags" })

  -- 4.5) 同步重建 GTAGS 引用库:与 ctags 共用同一项目根(gutentags 的 git 根
  -- 探测)，让"跳定义/补全"(ctags)和"查引用"(global)索引范围一致。gtags 扫
  -- 1 万文件仅数秒，与 ctags 一并触发几乎无感。详见 config/global_refs.lua。
  -- (Rebuild the GTAGS reference db at the SAME root ctags uses, so jump/
  --  complete (ctags) and references (global) stay in sync. ~seconds to scan.)
  local groot = require("config.gutentags_root").find(vim.fs.dirname(fname))
  if groot and groot ~= "" then
    require("config.global_refs").build(groot)
  end

  -- 5) 启动轮询：每 1s 检查状态 + 临时文件大小，扫完后弹完成通知。
  -- (Poll every 1s: report state + temp-file size, notify on completion.)
  M._track(buf, tagfile, proj)
end

-- 轮询跟踪一次扫描的生命周期，用一个浮动进度通知滚动刷新。
-- (Track one scan's lifecycle, refreshing a single rolling notification.)
function M._track(buf, tagfile, proj)
  local start = vim.uv.hrtime()
  local timer = vim.uv.new_timer()
  local notif_id = "ctags_scan_" .. tostring(buf)

  timer:start(
    800,
    1000,
    vim.schedule_wrap(function()
      local elapsed = (vim.uv.hrtime() - start) / 1e9
      local running = vim.api.nvim_buf_is_valid(buf) and is_scanning(buf)

      if running then
        -- 扫描中：显示用时 + 临时文件实时大小 (running: show elapsed + temp size)
        local temp = tagfile and (tagfile .. ".temp") or nil
        local sz = temp and (vim.uv.fs_stat(temp) or {}).size or nil
        vim.notify(
          string.format("ctags scanning… %.0fs, temp=%s", elapsed, human_size(sz)),
          vim.log.levels.INFO,
          { title = "gutentags", id = notif_id, timeout = 1500 }
        )
      else
        -- 扫描结束：停定时器，弹最终结果（用时 + 生成的 tags 大小）。
        -- (Done: stop timer, report elapsed + final tags size.)
        timer:stop()
        timer:close()
        local sz = tagfile and (vim.uv.fs_stat(tagfile) or {}).size or nil
        vim.notify(
          string.format("ctags scan done: %s in %.0fs (%s)", vim.fs.basename(proj), elapsed, human_size(sz)),
          vim.log.levels.INFO,
          { title = "gutentags", id = notif_id, timeout = 4000 }
        )
      end
    end)
  )
end

-- 随时查询当前状态：在扫 / 没在扫 + 临时文件或已有 tags 的大小。
-- (Query current state on demand: scanning or idle, plus file sizes.)
function M.status(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local tagfile = tagfile_for(buf)

  if not tagfile then
    vim.notify("gutentags not attached here (no Maven/ctags context)", vim.log.levels.WARN, { title = "gutentags" })
    return
  end

  if is_scanning(buf) then
    local temp = tagfile .. ".temp"
    local sz = (vim.uv.fs_stat(temp) or {}).size
    vim.notify(
      "ctags: SCANNING now, temp file = " .. human_size(sz),
      vim.log.levels.INFO,
      { title = "gutentags" }
    )
  else
    local st = vim.uv.fs_stat(tagfile)
    if st then
      local age = os.time() - math.floor(st.mtime.sec)
      vim.notify(
        string.format("ctags: idle. tags = %s, updated %ds ago", human_size(st.size), age),
        vim.log.levels.INFO,
        { title = "gutentags" }
      )
    else
      vim.notify("ctags: idle, no tags file yet (press <leader>gt to scan)", vim.log.levels.INFO, { title = "gutentags" })
    end
  end
end

-- lualine 组件用：扫描中返回带 spinner 的文本，空闲返回空串。
-- (lualine component: spinner text while scanning, empty string when idle.)
local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
function M.lualine()
  local buf = vim.api.nvim_get_current_buf()
  local ok = pcall(vim.api.nvim_buf_get_var, buf, "gutentags_files")
  if not ok or not is_scanning(buf) then
    return ""
  end
  local frame = spinner[(math.floor(vim.uv.now() / 100) % #spinner) + 1]
  return frame .. " ctags"
end

return M
