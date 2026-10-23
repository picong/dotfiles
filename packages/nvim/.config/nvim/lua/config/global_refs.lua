-- 基于 GNU Global 的查引用 + GTAGS 索引管理 (Global-backed references)
-- ---------------------------------------------------------------------------
-- ctags 只存定义，查"谁调用了某方法"只能 grep(噪声大:注释/字符串/同名都混入)。
-- GNU Global 的 GTAGS 库额外存了引用关系，`global -r` 能准确列出真实调用点。
-- 实测对照:某方法 global -r 给 36 个真实调用点，grep 给 100 行(含噪声)。
--
-- 索引用 new-ctags 后端(让 Universal Ctags 做解析、Global 做数据库)，库放
-- 缓存目录(GTAGSOBJDIRPREFIX)不污染项目，与现有 ctags 的做法一致。
-- (ctags has no reference info; Global's GTAGS does. We build it with the
--  new-ctags backend into the cache dir, and query references via global -r.)
local M = {}

local uv = vim.uv or vim.loop

-- 缓存根:gtags --objdir 会在此下按【项目全路径】建子目录存库。
-- (Cache root; gtags --objdir mirrors the project's absolute path under here.)
local function cache_root()
  return vim.fs.normalize(vim.fn.stdpath("cache") .. "/gtags")
end

-- 某项目根对应的 GTAGS 库目录 (the GTAGS db dir for a project root)
local function dbpath_for(proj)
  return cache_root() .. vim.fs.normalize(proj)
end

-- 项目根探测：直接复用 gutentags 的 finder(优先 git 仓库根)，确保 GTAGS 与
-- ctags 索引【完全同根】——多模块 Maven 仓库都覆盖到顶层，两套索引范围一致。
-- (Reuse gutentags' root finder so GTAGS shares the exact same root as ctags:
--  the git repo top-level, covering all modules in a multi-module Maven repo.)
local function project_root(buf)
  local fname = vim.api.nvim_buf_get_name(buf)
  if fname == "" then
    return nil
  end
  local root = require("config.gutentags_root").find(vim.fs.dirname(fname))
  return (root and root ~= "") and root or nil
end

local function java_xml_file_list(proj)
  local file = vim.fn.tempname()
  local lines = vim.fn.systemlist({
    "find",
    proj,
    "(",
    "-path",
    "*/target/*",
    "-o",
    "-path",
    "*/build/*",
    "-o",
    "-path",
    "*/.git/*",
    "-o",
    "-path",
    "*/.claude/*",
    "-o",
    "-path",
    "*/.superpowers/*",
    "-o",
    "-path",
    "*/.worktrees/*",
    ")",
    "-prune",
    "-o",
    "-type",
    "f",
    "(",
    "-name",
    "*.java",
    "-o",
    "-name",
    "*.xml",
    ")",
    "-print",
  })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  for i, path in ipairs(lines) do
    lines[i] = vim.fs.relpath(proj, path) or path
  end
  vim.fn.writefile(lines, file)
  return file
end

-- 构建 GTAGS：只把 Java/XML 文件列表喂给 new-ctags 后端。
-- (Build GTAGS by feeding only Java/XML files to the new-ctags backend.)
function M.build(proj, on_done)
  if vim.fn.executable("gtags") == 0 then
    vim.notify("gtags not found in PATH; references disabled", vim.log.levels.WARN, { title = "global" })
    return
  end
  local list = java_xml_file_list(proj)
  if not list then
    vim.notify("GTAGS file list failed", vim.log.levels.ERROR, { title = "global" })
    return
  end
  local prefix = cache_root()
  vim.fn.mkdir(prefix, "p")
  vim.notify("GTAGS build started: " .. vim.fs.basename(proj), vim.log.levels.INFO, { title = "global" })

  local start = uv.hrtime()
  vim.system(
    { "gtags", "--gtagslabel=new-ctags", "--objdir", "--skip-unreadable", "--file", list },
    {
      cwd = proj,
      env = { GTAGSLABEL = "new-ctags", GTAGSOBJDIRPREFIX = prefix },
      text = true,
    },
    vim.schedule_wrap(function(res)
      local secs = (uv.hrtime() - start) / 1e9
      if res.code == 0 then
        vim.notify(
          string.format("GTAGS build done: %s in %.0fs", vim.fs.basename(proj), secs),
          vim.log.levels.INFO,
          { title = "global" }
        )
      else
        vim.notify("GTAGS build failed:\n" .. (res.stderr or ""), vim.log.levels.ERROR, { title = "global" })
      end
      if on_done then
        on_done(res.code == 0)
      end
    end)
  )
end

-- gr：查光标下符号的引用，结果包进 Snacks.picker(与 ff/fg/fw 体验一致)。
-- (Find references for the symbol under the cursor; present via Snacks.picker.)
function M.references(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local word = vim.fn.expand("<cword>")
  if word == "" then
    return
  end
  local proj = project_root(buf)
  if not proj then
    vim.notify("No project root found; cannot query references", vim.log.levels.WARN, { title = "global" })
    return
  end
  local dbpath = dbpath_for(proj)
  if not uv.fs_stat(dbpath .. "/GTAGS") then
    vim.notify("No GTAGS index yet — press <leader>gt to build it", vim.log.levels.WARN, { title = "global" })
    return
  end

  -- --result=grep 给 file:line:text；在 proj 下执行让相对路径基于项目根。
  -- (Run under proj so grep-format paths resolve against the project root.)
  local res = vim.system({
    "global",
    "--result=grep",
    "-r",
    word,
  }, {
    cwd = proj,
    env = { GTAGSROOT = proj, GTAGSDBPATH = dbpath },
    text = true,
  }):wait()

  if res.code ~= 0 then
    vim.notify("global -r failed:\n" .. (res.stderr or ""), vim.log.levels.ERROR, { title = "global" })
    return
  end

  local items = {}
  for _, raw in ipairs(vim.split(res.stdout or "", "\n", { plain = true })) do
    -- 解析 file:line:text；file 可能是相对 proj 的，转绝对。
    local file, line, text = raw:match("^(.-):(%d+):(.*)$")
    if file and line then
      local abs = file:match("^/") and file or vim.fs.normalize(proj .. "/" .. file)
      table.insert(items, {
        file = abs,
        pos = { tonumber(line), 0 },
        text = text,
        line = text,
      })
    end
  end

  if #items == 0 then
    vim.notify("global: no references to '" .. word .. "'", vim.log.levels.INFO, { title = "global" })
    return
  end

  Snacks.picker.pick({
    title = "References: " .. word,
    items = items,
    format = "file",
  })
end

return M
