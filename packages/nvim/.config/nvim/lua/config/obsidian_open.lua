-- 在 Obsidian 里预览当前 Markdown 文件。
--
-- 为什么不直接打开文件所在的 vault:本机注册的 vault 里有一个就是 $HOME
-- 本身,覆盖 16000+ 个 md 文件且没有任何排除规则,每次跳进去 Obsidian 都要
-- 重建索引。所以改成"影子 vault":把当前文件(连同它引用的本地图片)复制到
-- 一个 /tmp 下的专用 vault,再让 Obsidian 打开那个只有几个文件的目录。
--
-- 代价:这是【只读预览副本】。在 Obsidian 里的编辑落在 /tmp,不会回写原文件。
--
-- (Preview the current Markdown file in a throwaway "shadow vault" under /tmp
--  instead of its real vault. One registered vault here is $HOME itself — 16k+
--  md files, no ignore filters — so opening it triggers a full re-index every
--  time. Note the copy is READ-ONLY in spirit: edits made in Obsidian land in
--  /tmp and are never written back.)

local M = {}

-- 影子 vault 的位置与它在 obsidian.json 里的 key。
-- ID 用固定的 16 位 hex,和 Obsidian 自己生成的格式一致,便于人工辨认。
-- (Shadow vault location and its key in obsidian.json; a fixed 16-hex ID
--  matching Obsidian's own format.)
local function tmp_base()
  local t = vim.env.TMPDIR
  return (t and t ~= "") and (t:gsub("/+$", "")) or "/tmp"
end

local SCRATCH_DIR = tmp_base() .. "/nvim-obsidian"
local SCRATCH_VAULT_ID = "1d0e5c2a7c4f0b91"
local MAX_ASSET_BYTES = 64 * 1024 * 1024

M.scratch_dir = SCRATCH_DIR

-- obsidian.json 的位置。Linux 走 XDG,mac 走 Application Support。
-- (Location of obsidian.json: XDG on Linux, Application Support on macOS.)
local function registry_path()
  if vim.fn.has("mac") == 1 then
    return vim.env.HOME .. "/Library/Application Support/obsidian/obsidian.json"
  end
  local xdg = vim.env.XDG_CONFIG_HOME
  local base = (xdg and xdg ~= "") and xdg or (vim.env.HOME .. "/.config")
  return base .. "/obsidian/obsidian.json"
end

-- URL 编码。允许字符集写死成 RFC 3986 的 unreserved 再加 "/",不用 %w:
-- Lua 的 %w 走 C 的 isalnum,对 UTF-8 多字节字符的行为依赖 locale,靠不住;
-- 中文文件名必须逐字节编码成 %XX,否则 Obsidian 收到乱码。
-- (Percent-encode. The allowed set is spelled out rather than using %w, whose
--  behaviour on multi-byte UTF-8 depends on locale; CJK names must be encoded
--  byte by byte.)
local function encode(s)
  return (s:gsub("[^A-Za-z0-9%-%._~/]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

--- 把影子 vault 注册进 obsidian.json(幂等)。
--- Obsidian 只认注册过的 vault —— 实测 obsidian://open?path=... 对未注册目录
--- 完全无效(既不打开也不自动注册),所以这一步省不掉。
--- 注意必须在 Obsidian 未运行时写,否则它退出时会用内存里的旧副本覆盖回去。
--- (Register the shadow vault in obsidian.json, idempotently. Verified: the
---  `path=` form of obsidian:// does nothing for unregistered directories, so
---  registration is mandatory. Must be written while Obsidian is NOT running,
---  or it will overwrite the file from its in-memory copy on exit.)
---@return boolean ok, string|nil err, boolean newly_registered
local function ensure_registered()
  local file = registry_path()
  if vim.fn.filereadable(file) == 0 then
    return false, "读不到 " .. file .. "(Obsidian 还没启动过?)", false
  end

  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
  end)
  if not ok or type(data) ~= "table" or type(data.vaults) ~= "table" then
    return false, "解析失败:" .. file, false
  end

  local existing = data.vaults[SCRATCH_VAULT_ID]
  if type(existing) == "table" and existing.path == SCRATCH_DIR then
    return true, nil, false
  end

  -- 只增不删:其余 vault 条目原样保留。
  -- (Additive only — every other vault entry is preserved verbatim.)
  data.vaults[SCRATCH_VAULT_ID] = {
    path = SCRATCH_DIR,
    ts = math.floor(vim.uv.now() > 0 and (os.time() * 1000) or os.time() * 1000),
  }

  -- 先写临时文件再 rename,避免写一半被 Obsidian 读到半个 JSON。
  -- (Write-then-rename so Obsidian can never observe a half-written JSON.)
  local encoded = vim.json.encode(data)
  local tmp = file .. ".nvim-tmp"
  local fd, open_err = io.open(tmp, "w")
  if not fd then
    return false, "无法写入 " .. tmp .. ": " .. tostring(open_err), false
  end
  fd:write(encoded)
  fd:close()
  local rename_ok, rename_err = os.rename(tmp, file)
  if not rename_ok then
    os.remove(tmp)
    return false, "替换 obsidian.json 失败: " .. tostring(rename_err), false
  end

  return true, nil, true
end

--- Obsidian 是否正在运行。用于决定"新注册 vault 后要不要提示重启"。
--- 匹配 app.asar 而不是进程名 obsidian:Arch 包是一层 bash 脚本 exec electron39,
--- 真正的进程名是 electron。
--- (Is Obsidian running? Matched via app.asar rather than the process name —
---  the Arch package is a shell wrapper that execs electron39.)
local function obsidian_running()
  if vim.fn.executable("pgrep") == 0 then
    return false
  end
  -- 正则是 POSIX ERE,不是 Lua 模式:这里的 "." 就让它当通配符,写成 Lua 的
  -- "%." 反而会被 pgrep 理解成字面的 % 加任意字符,永远匹配不上。
  -- (pgrep takes POSIX ERE, not Lua patterns: a Lua-style "%." would be read
  --  as a literal '%' plus any char and never match.)
  return vim.system({ "pgrep", "-f", "obsidian/app.asar" }):wait().code == 0
end

-- Markdown 链接里的路径是 URL 编码过的(img-clip 写出的中文/空格文件名尤其如此),
-- 复制前要先解码回真实文件名。
-- (Paths inside markdown links are percent-encoded; decode before touching disk.)
local function url_decode(s)
  return (s:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function is_external(target)
  -- 协议开头(http/https/data/mailto...)或协议相对 // 的,都不是本地文件。
  -- (Anything with a scheme, or protocol-relative //, is not a local file.)
  return target:match("^%a[%w+.-]*:") ~= nil or target:match("^//") ~= nil
end

--- 从 markdown 正文里抽出本地附件的相对路径。
--- 覆盖三种写法:标准 ![](path)、尖括号 ![](<path with space>)、wiki 嵌入 ![[path]]。
--- 只认相对路径:绝对路径复制进 vault 后无处安放,反正 Obsidian 也渲染不出来。
--- (Extract local attachment paths: standard, angle-bracket, and wiki embeds.
---  Relative paths only — absolutes have nowhere to live inside the vault.)
---@param lines string[]
---@return string[] relative paths, deduped
local function collect_assets(lines)
  local seen, out = {}, {}

  local function add(raw)
    if not raw or raw == "" then
      return
    end
    -- 砍掉 markdown 的 title 部分和 Obsidian 的 |size 后缀。
    -- (Strip a markdown title and Obsidian's |size suffix.)
    local target = raw:gsub('%s+["\'].*$', ""):gsub("|.*$", "")
    target = vim.trim(target):gsub("#.*$", "")
    if target == "" or is_external(target) then
      return
    end
    target = url_decode(target)
    -- 绝对路径、以及试图爬出 vault 的 ../ 一律跳过。
    -- (Skip absolutes and anything escaping the vault via ../)
    if target:sub(1, 1) == "/" or target:sub(1, 1) == "~" or target:match("%.%.") then
      return
    end
    target = target:gsub("^%./", "")
    if target ~= "" and not seen[target] then
      seen[target] = true
      table.insert(out, target)
    end
  end

  for _, line in ipairs(lines) do
    for inner in line:gmatch("!%[%[([^%]]+)%]%]") do
      add(inner)
    end
    for inner in line:gmatch("!%[[^%]]*%]%(%s*<([^>]+)>") do
      add(inner)
    end
    for inner in line:gmatch("!%[[^%]]*%]%(%s*([^<)%s][^)]*)%)") do
      add(inner)
    end
  end

  return out
end

--- 复制单个文件,目标目录不存在就建。已存在则直接覆盖(这是本功能的既定语义)。
--- (Copy one file, creating parent dirs; overwrite if present — that is the
---  intended semantics here.)
---@return boolean ok, string|nil err
local function copy_file(src, dst)
  local dir = vim.fn.fnamemodify(dst, ":h")
  if vim.fn.isdirectory(dir) == 0 and vim.fn.mkdir(dir, "p") == 0 then
    return false, "无法创建目录 " .. dir
  end
  local ok, err = vim.uv.fs_copyfile(src, dst)
  if not ok then
    return false, tostring(err)
  end
  return true
end

--- 建好影子 vault 骨架:目录 + .obsidian/app.json。
--- app.json 里预置 alwaysUpdateLinks 之类无关紧要,关键是有 .obsidian 目录,
--- Obsidian 才认它是个 vault 而不是在打开时弹"这不是 vault"。
--- (Create the shadow vault skeleton. The .obsidian directory is what makes
---  Obsidian treat the folder as a vault rather than prompting.)
---@return boolean ok, string|nil err
local function ensure_scratch_dir()
  if vim.fn.isdirectory(SCRATCH_DIR) == 0 and vim.fn.mkdir(SCRATCH_DIR, "p") == 0 then
    return false, "无法创建 " .. SCRATCH_DIR
  end
  local conf_dir = SCRATCH_DIR .. "/.obsidian"
  if vim.fn.isdirectory(conf_dir) == 0 and vim.fn.mkdir(conf_dir, "p") == 0 then
    return false, "无法创建 " .. conf_dir
  end
  local app_json = conf_dir .. "/app.json"
  if vim.fn.filereadable(app_json) == 0 then
    local fd = io.open(app_json, "w")
    if not fd then
      return false, "无法写入 " .. app_json
    end
    fd:write("{}")
    fd:close()
  end
  return true
end

--- 清空影子 vault 里上一次留下的 md 和附件,但保留 .obsidian 配置。
--- 不清的话 /tmp 里会攒一堆历史文件,Obsidian 侧边栏越来越脏,也违背"只看当前
--- 这一个文件"的初衷。
--- (Wipe the previous payload while keeping .obsidian, so the sidebar always
---  shows just the file at hand instead of accumulating history.)
local function clear_scratch()
  local handle = vim.uv.fs_scandir(SCRATCH_DIR)
  if not handle then
    return
  end
  while true do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if name ~= ".obsidian" then
      -- 用 vim.fn.delete 的 "rf",省得自己写递归。
      -- (Delegate recursion to vim.fn.delete's "rf".)
      vim.fn.delete(SCRATCH_DIR .. "/" .. name, "rf")
    end
  end
end

--- 把 buffer 对应的文件(+本地附件)投影到影子 vault。
---@param bufnr integer
---@return string|nil vault_relative_path, string|nil err, integer asset_count
local function stage(bufnr)
  -- 判空必须在 fnamemodify(":p") 之前:无名 buffer 的名字是 "",而 ":p" 会把
  -- 空串展开成当前工作目录,于是错报成"某个目录不存在"。
  -- (Check for empty BEFORE ":p": an unnamed buffer's name is "", which ":p"
  --  expands to the cwd, producing a misleading "file not found" for a dir.)
  local raw = vim.api.nvim_buf_get_name(bufnr)
  if raw == "" then
    return nil, "当前 buffer 还没有对应的文件(先保存)", 0
  end
  local src = vim.fn.resolve(vim.fn.fnamemodify(raw, ":p"))
  if vim.fn.filereadable(src) == 0 then
    return nil, "文件不存在于磁盘:" .. src, 0
  end

  local ok, err = ensure_scratch_dir()
  if not ok then
    return nil, err, 0
  end
  clear_scratch()

  -- 文件名原样保留 —— Obsidian 的标题、[[wiki 链接]]、图谱都以文件名为准,
  -- 改名会让预览看起来不是同一篇东西。
  -- (Keep the original filename: Obsidian derives the note title and wiki
  --  links from it, so renaming would make the preview look like another note.)
  local name = vim.fn.fnamemodify(src, ":t")
  ok, err = copy_file(src, SCRATCH_DIR .. "/" .. name)
  if not ok then
    return nil, "复制失败:" .. tostring(err), 0
  end

  -- 附件按原相对结构复制,这样文中的 ![](attachments/x.png) 不用改写就能渲染。
  -- (Mirror attachments at their original relative paths so existing links
  --  resolve without rewriting the markdown.)
  local src_dir = vim.fn.fnamemodify(src, ":h")
  local copied = 0
  for _, rel in ipairs(collect_assets(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))) do
    local asset = src_dir .. "/" .. rel
    local st = vim.uv.fs_stat(asset)
    if st and st.type == "file" and st.size <= MAX_ASSET_BYTES then
      if copy_file(asset, SCRATCH_DIR .. "/" .. rel) then
        copied = copied + 1
      end
    end
  end

  return name, nil, copied
end

--- 在 Obsidian 里预览当前文件。
--- 会先落盘未保存的改动 —— 否则复制过去的是旧内容,预览和编辑器不一致,
--- 这种静默的不一致比直接报错更难发现。
--- (Preview the current file in Obsidian. Unsaved changes are written first;
---  otherwise the copy would carry stale content — a silent mismatch that is
---  harder to notice than an outright error.)
---@param bufnr integer|nil
function M.open(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if vim.bo[bufnr].modified and vim.bo[bufnr].modifiable and vim.api.nvim_buf_get_name(bufnr) ~= "" then
    local written, write_err = pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd("silent write")
    end)
    if not written then
      vim.notify("保存失败,已中止:" .. tostring(write_err), vim.log.levels.ERROR)
      return
    end
  end

  local reg_ok, reg_err, newly = ensure_registered()
  if not reg_ok then
    vim.notify("Obsidian: " .. reg_err, vim.log.levels.ERROR)
    return
  end
  -- 首次注册时 Obsidian 若已在运行,它内存里没有这个 vault,URI 会打不开;
  -- 且它退出时还会把 obsidian.json 覆盖回去。只能让用户重启一次。
  -- (On first registration, a running Obsidian has no knowledge of the new
  --  vault and will also overwrite obsidian.json on exit — a restart is
  --  unavoidable exactly once.)
  if newly and obsidian_running() then
    vim.notify(
      "Obsidian: 已注册预览库 " .. SCRATCH_DIR .. "\n请先完全退出 Obsidian 再按一次(仅首次需要)",
      vim.log.levels.WARN
    )
    return
  end

  local rel, err, assets = stage(bufnr)
  if not rel then
    vim.notify("Obsidian: " .. err, vim.log.levels.WARN)
    return
  end

  local uri = ("obsidian://open?vault=%s&file=%s"):format(encode(SCRATCH_VAULT_ID), encode(rel))

  -- vim.ui.open 会走 xdg-open(Linux)/open(mac) 并 detach 子进程,
  -- 所以 nvim 退出不会顺手带走刚拉起来的 Obsidian。
  -- (vim.ui.open dispatches to xdg-open/open and detaches, so quitting nvim
  --  won't take a freshly launched Obsidian down with it.)
  -- pcall 会多包一层:vim.ui.open 本身返回 (job, err),所以是三个返回值。
  -- 把 job 当 err 判断会导致成功时误报失败。
  -- (pcall adds a layer: vim.ui.open returns (job, err), hence three values.
  --  Treating the job handle as the error makes success look like failure.)
  local ok, job_or_err, open_err = pcall(vim.ui.open, uri)
  if not ok then
    vim.notify("Obsidian: 打开失败 " .. tostring(job_or_err) .. "\n" .. uri, vim.log.levels.ERROR)
    return
  end
  if open_err then
    vim.notify("Obsidian: 打开失败 " .. tostring(open_err) .. "\n" .. uri, vim.log.levels.ERROR)
    return
  end

  local msg = "Obsidian 预览: " .. rel
  if assets > 0 then
    msg = msg .. ("  (+%d 个附件)"):format(assets)
  end
  vim.notify(msg, vim.log.levels.INFO)
end

--- 暴露给排查用:打印影子 vault 状态和将要生成的 URI。
--- (Diagnostics: dump the shadow vault state and the URI that would be used.)
function M.info()
  local lines = {
    "预览库目录: " .. SCRATCH_DIR,
    "vault ID  : " .. SCRATCH_VAULT_ID,
    "已注册    : " .. tostring(select(1, ensure_registered()) and true or false),
    "Obsidian 运行中: " .. tostring(obsidian_running()),
  }
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" then
    lines[#lines + 1] = "当前文件  : " .. name
    lines[#lines + 1] = "附件      : "
      .. vim.inspect(collect_assets(vim.api.nvim_buf_get_lines(0, 0, -1, false)))
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
