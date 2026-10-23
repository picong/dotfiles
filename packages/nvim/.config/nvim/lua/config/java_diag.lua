-- 基于 javac 的按需诊断 (on-demand javac diagnostics)
-- ---------------------------------------------------------------------------
-- 无 LSP 时唯一能拿到"编译级真红波浪线"的途径:保存当前 .java 时,异步起一个
-- 一次性的 javac 子进程,只编译这一个文件,把 javac 的 error 解析进 vim.diagnostic。
-- JVM 起来→检查→打印错误→退出,内存瞬态、无后台索引,这正是 jdtls 一直常驻
-- 才贵的那部分被我们绕开了。
-- (The only way to get compiler-accurate red squiggles without LSP: on save,
--  spawn a transient javac that compiles just this file and parse its errors
--  into vim.diagnostic. No daemon, no whole-repo indexing — that's the costly
--  part of jdtls we deliberately skip.)
--
-- classpath 来自 mvn dependency:build-classpath 的导出结果(缓存复用,手动
-- <leader>cp 生成),并补上本模块与兄弟模块的 target/classes;同模块未编译的
-- 引用靠 -sourcepath 现编译兜底。Lombok 等注解处理器走 classpath 自动发现,
-- 故【不】传 -proc:none。只显示【当前文件】的 error,warning 与其它文件全忽略。
-- (Classpath comes from a cached mvn dependency:build-classpath export plus
--  module/sibling target/classes; -sourcepath resolves uncompiled same-module
--  refs. Annotation processors (Lombok) are auto-discovered via classpath, so
--  we do NOT pass -proc:none. Only current-file errors are surfaced.)
local M = {}

local uv = vim.uv or vim.loop

-- 诊断命名空间:与 LSP/treesitter 隔离,便于单独 set/clear。
-- (Dedicated diagnostic namespace, isolated from LSP/treesitter.)
local NS = vim.api.nvim_create_namespace("java_javac_diag")

-- 正在编译的 buffer 标记:防止连续保存叠起多个 javac。
-- (Per-buffer guard: avoid stacking javac runs on rapid saves.)
local running = {}

-- classpath 缓存根:按模块绝对路径镜像存 .cp 文件。
-- (Cache root for exported classpaths, mirrored by module absolute path.)
local function cp_cache_root()
  return vim.fs.normalize(vim.fn.stdpath("cache") .. "/java-classpath")
end

-- javac 输出目录根:按模块复用同一目录做增量,加速后续编译,不污染项目。
-- (Output dir root; reused per module as an incremental cache, off-project.)
local function out_cache_root()
  return vim.fs.normalize(vim.fn.stdpath("cache") .. "/java-diag-out")
end

-- 模块根:向上找【最近的】pom.xml。classpath 是按模块的,所以这里要叶子模块
-- 而非 git 根(与 ctags/global 用 git 根不同)。
-- (Module root = nearest pom.xml upward. Classpath is per-module, so we want
--  the leaf module here, NOT the git root used by ctags/global.)
local function module_root(buf)
  local fname = vim.api.nvim_buf_get_name(buf)
  if fname == "" then
    return nil
  end
  local pom = vim.fs.find("pom.xml", { upward = true, path = vim.fs.dirname(fname) })[1]
  return pom and vim.fs.dirname(pom) or nil
end

-- 仓库根(git 根优先),用于扫兄弟模块的 target/classes。
-- (Repo root for discovering sibling modules' target/classes.)
local function repo_root(buf)
  local fname = vim.api.nvim_buf_get_name(buf)
  if fname == "" then
    return nil
  end
  local root = require("config.gutentags_root").find(vim.fs.dirname(fname))
  return (root and root ~= "") and root or nil
end

-- 某模块对应的 classpath 缓存文件路径。
-- (Cache file path holding the exported classpath for a module.)
local function cp_file_for(mod)
  return cp_cache_root() .. vim.fs.normalize(mod) .. ".cp"
end

-- 收集从模块根向上到仓库根的所有 pom.xml(子模块在前)。
-- (All pom.xml from module root up to repo root, nearest first.)
local function poms_upward(mod, repo)
  local poms = {}
  local dir = mod
  while dir and dir ~= "" do
    local p = dir .. "/pom.xml"
    if uv.fs_stat(p) then
      table.insert(poms, p)
    end
    if dir == repo then
      break
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
  return poms
end

-- 解析编译级别:沿 pom 链找 release > source > java.version(含 compiler 插件
-- 的 <release>/<source>)。拿到数字字符串(如 "8"/"17"),拿不到返回 nil。
-- (Resolve compiler level along the pom chain: release > source > java.version.
--  Returns a numeric string like "8"/"17", or nil if undeterminable.)
local function compiler_level(mod, repo)
  for _, pom in ipairs(poms_upward(mod, repo)) do
    local fd = io.open(pom, "r")
    if fd then
      local text = fd:read("*a")
      fd:close()
      local lvl = text:match("<maven%.compiler%.release>%s*(%d+)")
        or text:match("<release>%s*(%d+)")
        or text:match("<maven%.compiler%.source>%s*(%d+)")
        or text:match("<source>%s*(%d+)")
        or text:match("<java%.version>%s*(%d+)")
      if lvl then
        return lvl
      end
    end
  end
  return nil
end

-- 扫仓库根下的兄弟模块 target/classes(限深度,避免遍历整个仓库)。
-- (Discover sibling modules' target/classes under repo root, depth-bounded.)
local function sibling_classes(repo)
  if not repo or repo == "" then
    return {}
  end
  local res = vim
    .system({
      "find",
      repo,
      "-maxdepth",
      "5",
      "-type",
      "d",
      "-path",
      "*/target/classes",
    }, { text = true })
    :wait()
  local dirs = {}
  for _, d in ipairs(vim.split(res.stdout or "", "\n", { plain = true })) do
    if d ~= "" then
      table.insert(dirs, d)
    end
  end
  return dirs
end

-- 组装完整 classpath:导出的依赖 cp + 本模块 + 兄弟模块 target/classes。
-- (Assemble full classpath: exported deps + this/sibling target/classes.)
local function full_classpath(mod, repo)
  local cpfile = cp_file_for(mod)
  local fd = io.open(cpfile, "r")
  if not fd then
    return nil
  end
  local deps = (fd:read("*a") or ""):gsub("%s+$", "")
  fd:close()

  local parts = {}
  if deps ~= "" then
    table.insert(parts, deps)
  end
  for _, d in ipairs(sibling_classes(repo)) do
    table.insert(parts, d)
  end
  return table.concat(parts, ":")
end

-- 当前文件所在的源码根(src/main|test/java)+ 生成源目录,组成 -sourcepath。
-- (Source roots for -sourcepath: src/main|test/java + generated-sources.)
local function source_path(mod, fname)
  local cands = {
    mod .. "/src/main/java",
    mod .. "/src/test/java",
    mod .. "/target/generated-sources/annotations",
    mod .. "/target/generated-test-sources/test-annotations",
  }
  local existing = {}
  for _, d in ipairs(cands) do
    if uv.fs_stat(d) then
      table.insert(existing, d)
    end
  end
  return table.concat(existing, ":")
end

-- 导出 classpath:在模块目录跑 mvn dependency:build-classpath,写到缓存文件。
-- includeScope=test 覆盖 compile/provided/runtime/test —— Lombok 多为 provided
-- scope,必须含 provided 才能让注解处理生效。异步执行 + 通知。
-- (Export classpath via mvn into the cache file. includeScope=test pulls in
--  provided-scope deps like Lombok, required for annotation processing.)
function M.build_classpath(buf, on_done)
  buf = buf or vim.api.nvim_get_current_buf()
  if vim.fn.executable("mvn") == 0 then
    vim.notify("mvn not found in PATH; classpath export disabled", vim.log.levels.WARN, { title = "java-diag" })
    return
  end
  local mod = module_root(buf)
  if not mod then
    vim.notify("Not a Maven module (no pom.xml upward)", vim.log.levels.WARN, { title = "java-diag" })
    return
  end
  local cpfile = cp_file_for(mod)
  vim.fn.mkdir(vim.fs.dirname(cpfile), "p")

  vim.notify("Exporting classpath via mvn: " .. vim.fs.basename(mod), vim.log.levels.INFO, { title = "java-diag" })
  local start = uv.hrtime()
  vim.system({
    "mvn",
    "-q",
    "dependency:build-classpath",
    "-Dmdep.outputFile=" .. cpfile,
    "-Dmdep.pathSeparator=:",
    "-DincludeScope=test",
  }, {
    cwd = mod,
    text = true,
  }, vim.schedule_wrap(function(res)
    local secs = (uv.hrtime() - start) / 1e9
    if res.code == 0 and uv.fs_stat(cpfile) then
      vim.notify(
        string.format("Classpath exported: %s in %.0fs", vim.fs.basename(mod), secs),
        vim.log.levels.INFO,
        { title = "java-diag" }
      )
      if on_done then
        on_done(true)
      end
    else
      vim.notify(
        "mvn build-classpath failed:\n" .. (res.stderr or res.stdout or ""),
        vim.log.levels.ERROR,
        { title = "java-diag" }
      )
      if on_done then
        on_done(false)
      end
    end
  end))
end

-- 解析 javac stderr,只产出【当前文件】的 error 诊断。javac 错误块形如:
--   File.java:12: error: cannot find symbol
--           foo.bar();
--              ^
--     symbol:   method bar()
--     location: class Foo
-- 首行给 file:line:error:msg;脱字符行(^)给列;symbol/location 行补进 message。
-- warning 块整块丢弃(方案只显示 error)。
-- (Parse javac stderr into current-file error diagnostics. The caret line gives
--  the column; symbol/location lines enrich the message; warnings are dropped.)
local function parse_diagnostics(stderr, target_file)
  local diags = {}
  local cur = nil

  local function flush()
    if cur and cur.severity == vim.diagnostic.severity.ERROR and cur.file == target_file then
      table.insert(diags, {
        lnum = cur.lnum,
        col = cur.col,
        end_lnum = cur.lnum,
        message = cur.msg,
        severity = cur.severity,
        source = "javac",
      })
    end
    cur = nil
  end

  for _, line in ipairs(vim.split(stderr or "", "\n", { plain = true })) do
    -- 新错误/警告块的首行 (start of a new error/warning block)
    local file, lnum, kind, msg = line:match("^(.-%.java):(%d+):%s*(%a+):%s*(.*)$")
    if file then
      flush()
      cur = {
        file = vim.fs.normalize(file),
        lnum = tonumber(lnum) - 1,
        col = 0,
        msg = msg,
        severity = (kind == "error") and vim.diagnostic.severity.ERROR or vim.diagnostic.severity.WARN,
      }
    elseif cur then
      -- 脱字符行:列 = ^ 前的空白数 (caret line -> column)
      local caret = line:match("^(%s*)%^%s*$")
      if caret then
        cur.col = #caret
      else
        -- symbol:/location: 等补充行拼进 message (enrich message)
        local extra = line:match("^%s+(symbol:.*)$") or line:match("^%s+(location:.*)$")
        if extra then
          cur.msg = cur.msg .. "  " .. extra:gsub("%s+", " ")
        elseif line:match("^%d+ error") or line:match("^%d+ warning") then
          flush()
        end
      end
    end
  end
  flush()
  return diags
end

-- 保存时触发:异步编译当前文件,把 error 渲染成 vim.diagnostic 红波浪线。
-- (On save: async-compile this file, render errors as diagnostics.)
function M.diagnose(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if running[buf] then
    return -- 已在编译,下次保存会再触发 (already running; next save retries)
  end
  if vim.fn.executable("javac") == 0 then
    return
  end
  local fname = vim.api.nvim_buf_get_name(buf)
  if fname == "" or not fname:match("%.java$") then
    return
  end
  local mod = module_root(buf)
  if not mod then
    return -- 非 Maven 模块,静默跳过 (not a Maven module; stay silent)
  end
  local repo = repo_root(buf) or mod

  -- classpath 缓存不存在:不自动跑 mvn,提示手动 <leader>cp(贴合 <leader>gt 哲学)。
  -- (No cached classpath: don't auto-run mvn; prompt manual <leader>cp.)
  local cp = full_classpath(mod, repo)
  if not cp then
    vim.notify(
      "No classpath cache — press <leader>cp to export it (mvn)",
      vim.log.levels.WARN,
      { title = "java-diag" }
    )
    return
  end

  local out = out_cache_root() .. vim.fs.normalize(mod)
  vim.fn.mkdir(out, "p")
  local sp = source_path(mod, fname)
  local target = vim.fs.normalize(fname)

  local cmd = {
    "javac",
    -- 强制英文输出:中文 locale 下 javac 会把 error/warning 本地化成
    -- "错误:/警告:",使下面的英文正则解析全部失配。
    -- (Force English diagnostics; a localized JVM emits "错误:" etc. and breaks
    --  the English-based parser below.)
    "-J-Duser.language=en",
    "-J-Duser.country=US",
    -- 源码优先:target/classes 可能比源码新但内容是旧的 Lombok 产物。
    -- (Prefer source: target/classes may be newer yet contain stale Lombok output.)
    "-Xprefer:source",
    "-d",
    out, -- class 输出目录(临时,做增量缓存) (output dir, incremental cache)
    "-s",
    out, -- 注解处理生成源输出 (generated-source output)
    "-encoding",
    "UTF-8",
    "-cp",
    cp,
  }
  if sp ~= "" then
    table.insert(cmd, "-sourcepath")
    table.insert(cmd, sp)
  end
  local lvl = compiler_level(mod, repo)
  if lvl then
    table.insert(cmd, "--release")
    table.insert(cmd, lvl)
  end
  table.insert(cmd, target)

  running[buf] = true
  vim.system(cmd, { cwd = mod, text = true }, vim.schedule_wrap(function(res)
    running[buf] = nil
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local diags = parse_diagnostics(res.stderr, target)
    vim.diagnostic.set(NS, buf, diags)
  end))
end

-- 清掉当前 buffer 的 javac 诊断(切走/关闭时用)。
-- (Clear javac diagnostics for a buffer.)
function M.clear(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(buf) then
    vim.diagnostic.reset(NS, buf)
  end
end

-- 诊断显示:关掉本命名空间的行尾 virtual_text(避免挤在最右端看不全),改为
-- 光标停在错误行时在【屏幕中心】弹一个浮框显示完整信息。仅作用于 java buffer,
-- Go/Python 的 LSP 诊断仍走 LazyVim 默认的行尾 virtual_text。
-- (Display: disable end-of-line virtual_text for OUR namespace — it gets
--  squeezed off-screen on long lines — and instead pop a centered float when
--  the cursor rests on an error line. java-only; LSP langs keep their default.)
local display_done = false
function M.setup_display(buf)
  -- 1) namespace 级配置:本 javac 诊断【只】保留波浪线下划线 + 行号标记,
  --    关掉 virtual_text。namespace 级只需设一次,全局生效于该 NS。
  --    (Namespace-scoped: underline + signs only, no virtual_text. Set once.)
  if not display_done then
    display_done = true
    vim.diagnostic.config({
      virtual_text = false,
      underline = true,
      signs = true,
      severity_sort = true,
    }, NS)
  end

  -- 2) 光标停留时,若当前行有【本命名空间】的诊断,在中心弹浮框。用 scope="line"
  --    抓整行诊断;浮框默认锚在光标,这里 reltime=false+居中由 open_float 的
  --    relative="editor" 不直接支持,改用自定义 nvim_open_win 居中渲染。
  --    (On CursorHold: if the current line has a diagnostic from our NS, show a
  --     centered float.)
  local grp = vim.api.nvim_create_augroup("java_diag_float_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "CursorHold" }, {
    group = grp,
    buffer = buf,
    callback = function()
      M.show_float_centered(buf)
    end,
  })
end

-- 在屏幕中心弹一个浮框,显示光标所在行的 javac 诊断(本命名空间)。无则不弹。
-- (Centered float showing this NS's diagnostics on the cursor line; no-op if none.)
function M.show_float_centered(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1
  local diags = vim.diagnostic.get(buf, { namespace = NS, lnum = lnum })
  if #diags == 0 then
    return
  end

  -- 拼诊断文本(可能多条),按列排序 (compose lines; multiple diags possible)
  table.sort(diags, function(a, b)
    return (a.col or 0) < (b.col or 0)
  end)
  local lines = {}
  for _, d in ipairs(diags) do
    -- 每条按 80 宽软折行,保证长 message 在中心框里完整可读。
    -- (Wrap each message so long ones stay fully readable in the float.)
    local msg = string.format("● %s", (d.message or ""):gsub("%s+", " "))
    for _, seg in ipairs(M._wrap(msg, 76)) do
      table.insert(lines, seg)
    end
  end
  if #lines == 0 then
    return
  end

  -- 框尺寸:宽取最长行(上限 80),高取行数(上限编辑区一半)。
  -- (Float size: width = longest line capped at 80, height capped at half.)
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(math.max(width, 20), 80)
  local height = math.min(#lines, math.floor(vim.o.lines / 2))

  -- 居中坐标:相对整个编辑器 (centered relative to the whole editor)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.bo[fbuf].modifiable = false
  vim.bo[fbuf].bufhidden = "wipe"

  local fwin = vim.api.nvim_open_win(fbuf, false, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " javac error ",
    title_pos = "center",
    focusable = false,
    noautocmd = true,
    zindex = 200,
  })
  vim.wo[fwin].winhighlight = "Normal:NormalFloat,FloatBorder:DiagnosticError"

  -- 关框:光标一移动/进入插入/切 buffer 就关,避免浮框赖着不走。
  -- (Auto-close the float on any cursor move / insert / buffer switch.)
  local close = function()
    if vim.api.nvim_win_is_valid(fwin) then
      pcall(vim.api.nvim_win_close, fwin, true)
    end
  end
  vim.api.nvim_create_autocmd(
    { "CursorMoved", "CursorMovedI", "InsertEnter", "BufLeave", "WinScrolled" },
    { once = true, callback = close }
  )
end

-- 公开访问器:供 java_import.lua 复用(命名空间 + 路径解析,避免重复实现)。
-- (Public accessors reused by java_import.lua: namespace + path helpers.)
M.namespace = NS
function M.module_root(buf)
  return module_root(buf)
end
function M.repo_root(buf)
  return repo_root(buf)
end
function M.cp_file_for(mod)
  return cp_file_for(mod)
end
-- 取某 buffer 某行(0-based)上本命名空间的诊断 (this NS's diagnostics on a line)
function M.diags_on_line(buf, lnum)
  return vim.diagnostic.get(buf, { namespace = NS, lnum = lnum })
end

-- 简易按显示宽度软折行 (naive width-based soft wrap)
function M._wrap(s, w)
  local out = {}
  while vim.fn.strdisplaywidth(s) > w do
    -- 在 w 宽度附近找空格断行 (break near width w at a space)
    local cut = w
    while cut > 1 and s:sub(cut, cut) ~= " " do
      cut = cut - 1
    end
    if cut <= 1 then
      cut = w -- 没空格就硬断 (hard break if no space)
    end
    table.insert(out, s:sub(1, cut))
    s = s:sub(cut + 1):gsub("^%s+", "")
  end
  if s ~= "" then
    table.insert(out, s)
  end
  return out
end

return M
