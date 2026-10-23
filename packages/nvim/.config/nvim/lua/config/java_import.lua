-- Java code action: Alt+Enter 快速修复 (IDEA-style quick fixes without LSP)
-- ---------------------------------------------------------------------------
-- 无 LSP 时模拟 IDEA 的 Alt+Enter。读光标行的 javac 诊断(java_diag 命名空间),
-- 按 message 里的 "symbol: class/method" 分流到不同修复:
--   1) 自动导包 (cannot find symbol - class XXX): 从类名索引找全限定名候选,
--      多维启发式排序,vim.ui.select 选择,按字母序插入 import 块。
--   2) 创建方法骨架 (cannot find symbol - method foo(types), location: 当前
--      文件可编辑类): 参数类型用 javac 给的签名,参数名 argN,返回 Object+TODO。
-- 另含独立命令: unused import 清理(纯文本分析,javac 不报 unused import)。
-- (Mimics IDEA Alt+Enter without LSP, driven by javac diagnostics. Auto-import
--  resolves simple names against a cached class-name index; method-skeleton
--  uses javac-provided param types. Unused-import cleanup is text-based since
--  javac never reports unused imports.)
local M = {}

local uv = vim.uv or vim.loop
local diag = require("config.java_diag")

-- 类名索引缓存根:按模块绝对路径镜像存 .idx(JSON)。与 classpath 缓存同级。
-- (Class-name index cache root, mirrored by module path; sibling of .cp cache.)
local function idx_cache_root()
  return vim.fs.normalize(vim.fn.stdpath("cache") .. "/java-import-index")
end

local function idx_file_for(mod)
  return idx_cache_root() .. vim.fs.normalize(mod) .. ".idx.json"
end

-- 内存索引: simple name -> { fqn1, fqn2, ... }。按模块缓存,避免重复读盘。
-- (In-memory index: simple name -> list of FQNs, keyed by module path.)
local mem_index = {}

-- ---------------------------------------------------------------------------
-- 索引构建 (index building)
-- ---------------------------------------------------------------------------

-- 判断一个类全限定名是否该被索引。过滤噪声:含 $ 的内部/匿名类、package-info、
-- module-info、明显的 shaded/relocated 包。保留可 import 的顶层公开类。
-- (Whether an FQN should be indexed. Drops $-nested/anonymous classes,
--  package-info, module-info, and obvious shaded/relocated packages.)
local function should_index(fqn)
  if fqn:find("%$") then
    return false -- 内部类/匿名类 (nested/anonymous)
  end
  if fqn:match("package%-info$") or fqn:match("module%-info$") then
    return false
  end
  -- 明显的重打包/内部实现包 (obvious shaded/relocated/internal packages)
  if fqn:match("%.shade%.") or fqn:match("%.shaded%.") or fqn:match("%.repackaged%.") or fqn:match("%.relocated%.") then
    return false
  end
  return true
end

-- 把 "java/util/List.class" 这类条目转成 FQN "java.util.List"。非法返回 nil。
-- (Convert a zip/jimage entry path to an FQN, or nil if not a top-level class.)
local function entry_to_fqn(entry, strip_prefix)
  local path = entry
  if strip_prefix and path:sub(1, #strip_prefix) == strip_prefix then
    path = path:sub(#strip_prefix + 1)
  end
  -- 跳过非类路径: META-INF/(含多版本 jar 的 versions/N/...)、以及任何
  -- 含连字符的目录段——它们不是合法包名。多版本类的“真身”在
  -- jar 根路径还会被扫到,不会漏。
  -- (Skip non-class paths: META-INF/ (multi-release versions/N/...) and any
  --  segment with a hyphen — not a valid package. The real class still appears
  --  at the jar root path, so nothing is lost.)
  if path:match("^META%-INF/") or path:match("^WEB%-INF/") then
    return nil
  end
  local cls = path:match("([%w_/%$]+)%.class$")
  if not cls then
    return nil
  end
  local fqn = cls:gsub("/", ".")
  return fqn
end

-- 往索引表插入一个 FQN (insert one FQN into the index table)
local function add_fqn(index, fqn)
  if not should_index(fqn) then
    return
  end
  local simple = fqn:match("([%w_]+)$")
  if not simple then
    return
  end
  local list = index[simple]
  if not list then
    list = {}
    index[simple] = list
  end
  -- 去重 (dedupe)
  for _, v in ipairs(list) do
    if v == fqn then
      return
    end
  end
  table.insert(list, fqn)
end

-- 扫描所有依赖 jar(从 .cp 读),列出全部 .class 转 FQN。用一条 shell 管线批量
-- unzip -l,比逐个 spawn 快得多(实测 382 jar ~1.6s)。
-- (Scan all dependency jars from the .cp file, listing every .class as an FQN.)
local function scan_jars(index, cpfile)
  local fd = io.open(cpfile, "r")
  if not fd then
    return
  end
  local cp = (fd:read("*a") or ""):gsub("%s+$", "")
  fd:close()
  if cp == "" then
    return
  end
  -- 用 zipinfo -1(只列文件名,无表头)对每个 jar 列出条目;不可用则回退 unzip -l。
  -- (zipinfo -1 prints bare entry names; fall back to unzip -l otherwise.)
  local jars = {}
  for jar in (cp .. ":"):gmatch("([^:]+):") do
    if jar ~= "" and uv.fs_stat(jar) then
      table.insert(jars, jar)
    end
  end
  if #jars == 0 then
    return
  end
  local lister = (vim.fn.executable("zipinfo") == 1)
  for _, jar in ipairs(jars) do
    local res
    if lister then
      res = vim.system({ "zipinfo", "-1", jar }, { text = true }):wait()
    else
      res = vim.system({ "unzip", "-Z1", jar }, { text = true }):wait()
    end
    if res.code == 0 then
      for line in (res.stdout or ""):gmatch("[^\n]+") do
        if line:match("%.class$") then
          local fqn = entry_to_fqn(line)
          if fqn then
            add_fqn(index, fqn)
          end
        end
      end
    end
  end
end

-- 扫描 JDK 类(jimage list lib/modules),路径形如 "java/util/List.class"。
-- (Scan JDK classes via jimage; entries look like "java/util/List.class".)
local function scan_jdk(index)
  local javac = vim.fn.exepath("javac")
  if javac == "" then
    return
  end
  -- /usr/lib/jvm/.../bin/javac -> JAVA_HOME
  local jh = vim.fs.dirname(vim.fs.dirname(uv.fs_realpath(javac) or javac))
  local modules = jh .. "/lib/modules"
  local jimage = jh .. "/bin/jimage"
  if not (uv.fs_stat(modules) and uv.fs_stat(jimage)) then
    return
  end
  local res = vim.system({ jimage, "list", modules }, { text = true }):wait()
  if res.code ~= 0 then
    return
  end
  -- jimage list 行首有缩进,且只取 java/ javax/ 这类标准包(过滤 jdk.internal 等)。
  -- (jimage entries are indented; keep only standard java/javax packages.)
  for line in (res.stdout or ""):gmatch("[^\n]+") do
    local entry = line:match("^%s+([%w_/%$]+%.class)$")
    if entry and (entry:match("^java/") or entry:match("^javax/")) then
      local fqn = entry_to_fqn(entry)
      if fqn then
        add_fqn(index, fqn)
      end
    end
  end
end

-- 扫描项目源码:仓库根下所有 .java,用 package 声明 + 文件名拼 FQN。这样项目
-- 自有类(尤其同包/兄弟模块)也能被导入,且应排在依赖之前(项目优先)。
-- (Scan project sources: FQN = package decl + file basename for every .java
--  under the repo root, so project classes are importable and ranked first.)
local function scan_sources(index, repo)
  if not repo or repo == "" then
    return
  end
  local res = vim.system({ "find", repo, "-name", "*.java", "-not", "-path", "*/target/*" }, { text = true }):wait()
  if res.code ~= 0 then
    return
  end
  for file in (res.stdout or ""):gmatch("[^\n]+") do
    local base = file:match("([%w_]+)%.java$")
    if base and base ~= "package-info" and base ~= "module-info" then
      local fd = io.open(file, "r")
      if fd then
        -- 只读前 ~50 行找 package(声明一定在文件开头) (package is near the top)
        local pkg = nil
        for _ = 1, 50 do
          local l = fd:read("*l")
          if not l then
            break
          end
          local p = l:match("^%s*package%s+([%w_%.]+)%s*;")
          if p then
            pkg = p
            break
          end
        end
        fd:close()
        local fqn = pkg and (pkg .. "." .. base) or base
        add_fqn(index, fqn)
        -- 记录项目包根(取前两段,如 com.example)到保留键 __roots__,
        -- 供排序阶段区分“项目自有类”与“第三方库”。
        -- (Record project package roots (first two segments) so ranking can
        --  tell project-owned classes from third-party libs.)
        if pkg then
          local root = pkg:match("^([%w_]+%.[%w_]+)") or pkg
          -- 排除两类污染:① test 源(/src/test/)里的怪包(如单段 mch);
          -- ② 项目里“覆盖/增强第三方”的包(org.apache/com.alibaba/
          -- org.slf4j 等)——这些误标为项目根会让第三方同名类虚高。
          -- (Exclude test-source packages and packages that shadow well-known
          --  third-party roots, so ranking isn't polluted.)
          local is_test = file:match("/src/test/")
          local THIRD_PARTY_ROOTS = {
            ["org.apache"] = true, ["org.slf4j"] = true, ["org.springframework"] = true,
            ["com.alibaba"] = true, ["com.google"] = true, ["org.bouncycastle"] = true,
            ["org.aspectj"] = true, ["io.netty"] = true, ["com.fasterxml"] = true,
          }
          if not is_test and root:match("%.") and not THIRD_PARTY_ROOTS[root] then
            index.__roots__ = index.__roots__ or {}
            index.__roots__[root] = true
          end
        end
      end
    end
  end
end

-- 构建并缓存类名索引(随 <leader>cp 调用)。异步:用 vim.schedule 包住重活,但
-- 这些 vim.system 是 :wait() 同步的,放在 defer 里跑避免卡 UI。
-- (Build and cache the class-name index; called after <leader>cp's mvn export.)
function M.build_index(buf, on_done)
  buf = buf or vim.api.nvim_get_current_buf()
  local mod = diag.module_root(buf)
  if not mod then
    vim.notify("Not a Maven module (no pom.xml upward)", vim.log.levels.WARN, { title = "java-import" })
    if on_done then
      on_done(false)
    end
    return
  end
  local repo = diag.repo_root(buf) or mod
  local cpfile = diag.cp_file_for(mod)

  vim.notify("Building import index...", vim.log.levels.INFO, { title = "java-import" })
  local start = uv.hrtime()
  -- defer 让通知先渲染,再跑同步扫描 (let the notice render before sync scan)
  vim.defer_fn(function()
    local index = {}
    scan_sources(index, repo) -- 项目源码先扫(优先级在排序阶段体现)
    scan_jars(index, cpfile)
    scan_jdk(index)

    -- 写盘缓存 (persist to disk)
    local idxfile = idx_file_for(mod)
    vim.fn.mkdir(vim.fs.dirname(idxfile), "p")
    local ok, encoded = pcall(vim.json.encode, index)
    if ok then
      local fd = io.open(idxfile, "w")
      if fd then
        fd:write(encoded)
        fd:close()
      end
    end
    mem_index[mod] = index

    local n = vim.tbl_count(index)
    local secs = (uv.hrtime() - start) / 1e9
    vim.notify(
      string.format("Import index built: %d names in %.1fs", n, secs),
      vim.log.levels.INFO,
      { title = "java-import" }
    )
    if on_done then
      on_done(true)
    end
  end, 50)
end

-- 取某模块的索引:内存 -> 磁盘缓存 -> nil(提示构建)。
-- (Get a module's index: memory -> disk cache -> nil.)
local function get_index(mod)
  if mem_index[mod] then
    return mem_index[mod]
  end
  local idxfile = idx_file_for(mod)
  local fd = io.open(idxfile, "r")
  if not fd then
    return nil
  end
  local data = fd:read("*a")
  fd:close()
  local ok, decoded = pcall(vim.json.decode, data)
  if ok and type(decoded) == "table" then
    mem_index[mod] = decoded
    return decoded
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- 候选排序 (candidate ranking)
-- ---------------------------------------------------------------------------

-- 取当前文件的 package(用于"同包优先"打分) (current file's package for ranking)
local function current_package(buf)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, 50, false)) do
    local p = l:match("^%s*package%s+([%w_%.]+)%s*;")
    if p then
      return p
    end
  end
  return nil
end

-- 常用 JDK 包前缀:打分时给它们加权,让 java.util.List 排在 java.awt.List 前。
-- (Common JDK package prefixes, weighted so e.g. java.util.List ranks first.)
local COMMON_JDK = {
  "java.util.",
  "java.io.",
  "java.lang.",
  "java.time.",
  "java.nio.",
  "java.math.",
  "java.net.",
  "java.util.concurrent.",
}

-- 多维启发式打分:同包 > 项目自有包(根据 __roots__) > 常用 JDK 标准库
-- > 其余 JDK(java./javax.) > 第三方库。分数越大越靠前;同分按 FQN 字典序。
-- 关键修正:不能笼统给“非标准库”加分(那会让第三方库压过 java.util.List),
-- 项目包要靠 __roots__ 精确识别。
-- (Score: same-package > project-owned (via __roots__) > common JDK > other
--  JDK > third-party. Project packages are matched precisely via __roots__ so
--  third-party libs no longer outrank java.util.List.)
local function rank_candidates(cands, buf, pkg, roots)
  local function is_project(fqn)
    if not roots then
      return false
    end
    local r = fqn:match("^([%w_]+%.[%w_]+)")
    return r ~= nil and roots[r] == true
  end
  local function score(fqn)
    local s = 0
    local fpkg = fqn:match("^(.*)%.[%w_]+$") or ""
    if pkg and fpkg == pkg then
      s = s + 10000 -- 同包最优 (same package wins)
    end
    if is_project(fqn) then
      s = s + 1000 -- 项目自有类 (project-owned class)
    end
    for i, prefix in ipairs(COMMON_JDK) do
      if fqn:sub(1, #prefix) == prefix then
        s = s + (500 - i) -- 常用 JDK 包,越靠前权重略高 (common JDK)
        return s
      end
    end
    if fqn:match("^java%.") or fqn:match("^javax%.") then
      s = s + 200 -- 其余标准库 (other stdlib)
    end
    return s
  end
  table.sort(cands, function(a, b)
    local sa, sb = score(a), score(b)
    if sa ~= sb then
      return sa > sb
    end
    return a < b
  end)
  return cands
end

-- ---------------------------------------------------------------------------
-- import 插入 (import insertion)
-- ---------------------------------------------------------------------------

-- 把一条 import 按字母序插入 import 块。无 import 块时插在 package 行后(隔空行)。
-- 已存在则不重复插。返回 true 表示插入成功/已存在。
-- (Insert an import alphabetically into the import block; create one after the
--  package line if absent. No-op if already present.)
local function insert_import(buf, fqn)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local import_line = "import " .. fqn .. ";"

  local first_import, last_import, package_line = nil, nil, nil
  for i, l in ipairs(lines) do
    if not package_line and l:match("^%s*package%s+") then
      package_line = i
    end
    if l:match("^%s*import%s+") then
      if l:gsub("%s+", " "):match("^%s*import%s+" .. vim.pesc(fqn) .. "%s*;") then
        return true -- 已存在 (already imported)
      end
      first_import = first_import or i
      last_import = i
    end
  end

  if first_import then
    -- 在 import 块内找字母序插入点 (find alphabetical slot within the block)
    local insert_at = last_import + 1 -- 默认块末(0-based 用 nvim_buf_set_lines 时换算)
    for i = first_import, last_import do
      local existing = lines[i]:match("^%s*import%s+([%w_%.%*]+)%s*;")
      if existing and existing > fqn then
        insert_at = i
        break
      end
    end
    vim.api.nvim_buf_set_lines(buf, insert_at - 1, insert_at - 1, false, { import_line })
  elseif package_line then
    -- 无 import 块:package 行后插空行 + import (after package, with a blank line)
    vim.api.nvim_buf_set_lines(buf, package_line, package_line, false, { "", import_line })
  else
    -- 既无 import 也无 package(默认包):插到文件最顶 (top of file)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { import_line, "" })
  end
  return true
end

-- ---------------------------------------------------------------------------
-- 修复动作 (fix actions)
-- ---------------------------------------------------------------------------

-- 自动导包:simple 是 javac 报的缺失类名 (auto-import for a missing class name)
local function action_import(buf, mod, simple)
  local index = get_index(mod)
  if not index then
    vim.notify(
      "No import index — press <leader>cp to build it",
      vim.log.levels.WARN,
      { title = "java-import" }
    )
    return
  end
  local cands = index[simple]
  if not cands or #cands == 0 then
    vim.notify("No import candidate for '" .. simple .. "'", vim.log.levels.WARN, { title = "java-import" })
    return
  end
  -- 单候选: 直接确认插入(仍走 select 让用户看清要导什么);多候选: 排序后选。
  local pkg = current_package(buf)
  local ordered = rank_candidates(vim.deepcopy(cands), buf, pkg, index.__roots__)
  vim.ui.select(ordered, {
    prompt = "Import " .. simple .. ":",
    format_item = function(fqn)
      return fqn
    end,
  }, function(choice)
    if choice then
      insert_import(buf, choice)
      vim.notify("Imported " .. choice, vim.log.levels.INFO, { title = "java-import" })
    end
  end)
end

-- 创建方法骨架:从诊断 message 解析 method 名/参数类型/location,在当前文件
-- 对应类里插入方法。返回 Object + TODO 占位。
-- message 形如:
--   cannot find symbol  symbol: method compute(int,String)  location: class T
-- (Create a method skeleton parsed from the diagnostic message.)
local function action_create_method(buf, message)
  local name, params = message:match("symbol:%s*method%s+([%w_]+)%(([^)]*)%)")
  if not name then
    vim.notify("Could not parse method signature", vim.log.levels.WARN, { title = "java-import" })
    return
  end
  -- location 必须是 "class X" 且 X 在当前文件(可编辑)。variable...of type 这种
  -- 目标多为 JDK/依赖类,不处理(设计:只给当前文件可编辑类创建)。
  -- (location must be "class X" defined in THIS file; skip variable-of-type.)
  local loc_class = message:match("location:%s*class%s+([%w_%.]+)")
  if not loc_class then
    vim.notify("Target is not an editable class in this file", vim.log.levels.WARN, { title = "java-import" })
    return
  end
  local simple_target = loc_class:match("([%w_]+)$")

  -- 在当前文件找目标类声明行 + 其右花括号配对(简单括号计数)。
  -- (Find the target class declaration and its closing brace via brace counting.)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local class_line = nil
  for i, l in ipairs(lines) do
    if l:match("%f[%w]class%s+" .. vim.pesc(simple_target) .. "%f[^%w]") then
      class_line = i
      break
    end
  end
  if not class_line then
    vim.notify("Class '" .. simple_target .. "' not found in this file", vim.log.levels.WARN, { title = "java-import" })
    return
  end
  -- 从 class_line 起做花括号计数,找类体结束的 } (find matching closing brace)
  local depth, open_seen, close_line = 0, false, nil
  for i = class_line, #lines do
    for ch in lines[i]:gmatch("[{}]") do
      if ch == "{" then
        depth = depth + 1
        open_seen = true
      else
        depth = depth - 1
      end
    end
    if open_seen and depth == 0 then
      close_line = i
      break
    end
  end
  if not close_line then
    vim.notify("Could not locate class body end", vim.log.levels.WARN, { title = "java-import" })
    return
  end

  -- 组装参数列表:类型用 javac 给的,名字 argN (param types from javac, names argN)
  local plist = {}
  if params ~= "" then
    local idx = 0
    for t in params:gmatch("[^,]+") do
      local ty = vim.trim(t)
      table.insert(plist, ty .. " arg" .. idx)
      idx = idx + 1
    end
  end
  local sig = string.format("    private Object %s(%s) {", name, table.concat(plist, ", "))
  -- 缩进沿用 4 空格(与上面 sig 一致);返回 Object + TODO,避免猜返回类型。
  local body = {
    "",
    sig,
    "        // TODO: auto-generated method stub — adjust return type & body",
    "        return null;",
    "    }",
  }
  vim.api.nvim_buf_set_lines(buf, close_line - 1, close_line - 1, false, body)
  vim.notify("Created method '" .. name .. "' (returns Object, adjust as needed)", vim.log.levels.INFO, { title = "java-import" })
end

-- ---------------------------------------------------------------------------
-- Alt+Enter 入口 (code action entry)
-- ---------------------------------------------------------------------------

-- 光标行有 javac 诊断时,按 symbol 类型给出可选修复,vim.ui.select 选择执行。
-- (On the cursor line's javac diagnostics, offer applicable fixes.)
function M.code_action(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local mod = diag.module_root(buf)
  if not mod then
    vim.notify("Not a Maven module", vim.log.levels.WARN, { title = "java-import" })
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1
  local diags = diag.diags_on_line(buf, lnum)
  if #diags == 0 then
    vim.notify("No diagnostic on this line", vim.log.levels.INFO, { title = "java-import" })
    return
  end

  -- 收集本行所有诊断能提供的修复动作 (collect applicable actions)
  local actions = {}
  for _, d in ipairs(diags) do
    local msg = d.message or ""
    -- 缺失类 -> 导包 (missing class -> import)
    local cls = msg:match("symbol:%s*class%s+([%w_]+)")
    if cls then
      table.insert(actions, {
        label = "Import class '" .. cls .. "'",
        run = function()
          action_import(buf, mod, cls)
        end,
      })
    end
    -- 缺失方法 -> 创建方法骨架 (missing method -> create skeleton)
    if msg:match("symbol:%s*method%s+[%w_]+%(") then
      local mname = msg:match("symbol:%s*method%s+([%w_]+)%(")
      table.insert(actions, {
        label = "Create method '" .. (mname or "?") .. "' in this file",
        run = function()
          action_create_method(buf, msg)
        end,
      })
    end
  end

  if #actions == 0 then
    vim.notify("No quick fix available for this diagnostic", vim.log.levels.INFO, { title = "java-import" })
    return
  end
  if #actions == 1 then
    actions[1].run() -- 唯一动作仍要用户在子选择里确认(导包候选/方法生成)
    return
  end
  vim.ui.select(actions, {
    prompt = "Code action:",
    format_item = function(a)
      return a.label
    end,
  }, function(choice)
    if choice then
      choice.run()
    end
  end)
end

-- ---------------------------------------------------------------------------
-- 独立命令: unused import 清理 (standalone: remove unused imports)
-- ---------------------------------------------------------------------------

-- javac 不报 unused import,故纯文本分析:对每条非通配 import,取其简单类名,
-- 看是否在【import 行以外】的正文里作为标识符出现过。没出现即视为未使用。
-- 保守起见: 跳过 static import 和 .* 通配(无法可靠判断使用)。
-- (Text-based: an import is unused if its simple name never appears as an
--  identifier outside import lines. Skips static and wildcard imports.)
function M.remove_unused_imports(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  -- 正文(去掉所有 import 行 + package 行)拼成一坨,供出现性检查。
  -- (Body text without import/package lines, for occurrence checks.)
  local body_parts = {}
  local import_rows = {} -- { row = 1-based, simple = name }
  for i, l in ipairs(lines) do
    if l:match("^%s*import%s+static%s+") or l:match("^%s*import%s+[%w_%.]+%.%*%s*;") then
      -- 跳过 static / 通配 import (keep static & wildcard imports as-is)
    elseif l:match("^%s*import%s+") then
      local fqn = l:match("^%s*import%s+([%w_%.]+)%s*;")
      if fqn then
        local simple = fqn:match("([%w_]+)$")
        table.insert(import_rows, { row = i, simple = simple })
      end
    elseif not l:match("^%s*package%s+") then
      table.insert(body_parts, l)
    end
  end
  local body = table.concat(body_parts, "\n")

  -- 找出未使用的行 (collect unused import rows)
  local unused = {}
  for _, imp in ipairs(import_rows) do
    -- 作为完整标识符出现?用 %f[%w] 边界避免 List 命中 ListNode。
    -- (Whole-identifier match via frontier pattern to avoid substring hits.)
    if not body:find("%f[%w_]" .. vim.pesc(imp.simple) .. "%f[^%w_]") then
      table.insert(unused, imp)
    end
  end

  if #unused == 0 then
    vim.notify("No unused imports", vim.log.levels.INFO, { title = "java-import" })
    return
  end
  -- 从后往前删,避免行号位移 (delete bottom-up to keep row numbers stable)
  table.sort(unused, function(a, b)
    return a.row > b.row
  end)
  for _, imp in ipairs(unused) do
    vim.api.nvim_buf_set_lines(buf, imp.row - 1, imp.row, false, {})
  end
  vim.notify(string.format("Removed %d unused import(s)", #unused), vim.log.levels.INFO, { title = "java-import" })
end

return M
