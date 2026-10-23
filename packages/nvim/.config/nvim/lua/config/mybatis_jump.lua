-- Dao/Mapper 方法 -> MyBatis XML 跳转 (jump from Dao method to its XML)
-- ---------------------------------------------------------------------------
-- gI 的智能分流分支:光标停在 Dao/Mapper 接口方法上时,跳到对应 Mapper XML
-- 里那个 <select|insert|update|delete id="方法名"> 标签。
--
-- 定位机制(实测):每个 XML 有 <mapper namespace="全限定Dao名">,方法是
-- id="方法名"。所以拿【当前文件 package + 接口名】拼出全限定名,grep 出含该
-- namespace 的 XML(可能多个,如 OrderMapper 分文件写),再在其中 grep 方法 id。
-- namespace+id 实测 ~50ms,实时查不建索引。
--
-- Dao 判定(OR):接口名后缀命中 Dao/DAO/Mapper/Repository,【或】类声明带
-- @Mapper 注解,满足其一即走 XML 分支。
-- (Smart gI branch: on a Dao/Mapper interface method, jump to its XML statement
--  tag. We build the FQN from the file's package + interface name, grep XML for
--  that namespace, then for the method id. Live grep, ~50ms, no index.)
local M = {}

-- 接口名是否带 Dao/Mapper 后缀(大小写不敏感) (suffix test, case-insensitive)
-- 导出供调用点(ctags_callsite)复用:调用点只能拿到接收者简单类型名,用后缀
-- 判定是否走 XML 分支(@Mapper 注解判定需读定义文件,调用点从简,只用后缀)。
-- (Exported so the call-site can route by simple type name; the call-site uses
--  the suffix test only, since the @Mapper annotation check needs the def file.)
function M.suffix_is_mapper(type_name)
  if not type_name then
    return false
  end
  local lower = type_name:lower()
  return lower:match("dao$") ~= nil
    or lower:match("mapper$") ~= nil
    or lower:match("repository$") ~= nil
end

-- 接口名是否带 Dao/Mapper 后缀(大小写不敏感) (suffix test, case-insensitive)
local function suffix_is_mapper(type_name)
  return M.suffix_is_mapper(type_name)
end

-- 类声明前是否有 @Mapper 注解:读类定义文件,扫到 interface/class 声明行为止。
-- (Does the type carry @Mapper? Scan the def file up to its declaration line.)
local function has_mapper_annotation(filename, type_name)
  if not filename or not type_name then
    return false
  end
  local fd = io.open(filename, "r")
  if not fd then
    return false
  end
  local found = false
  local seen_mapper = false
  for line in fd:lines() do
    if line:match("@Mapper%f[^%w]") then
      seen_mapper = true
    end
    -- 撞到该类型的声明行:此前是否见过 @Mapper 即为结论。
    if line:match("%f[%w]interface%s+" .. type_name .. "%f[^%w]") or line:match("%f[%w]class%s+" .. type_name .. "%f[^%w]") then
      found = seen_mapper
      break
    end
    -- 注解与声明间不应隔着空行重置;简单起见遇到下一个类型声明也停。
  end
  fd:close()
  return found
end

-- 判定光标方法是否属于 Mapper(OR:后缀 或 @Mapper 注解)。
-- (Is the method's enclosing type a Mapper? suffix OR @Mapper annotation.)
local function is_mapper_method(sym)
  if suffix_is_mapper(sym.type) then
    return true
  end
  return has_mapper_annotation(sym.filename, sym.type)
end

-- 项目根:复用 gutentags 的 finder(git 根优先),与 ctags/global 同根。
-- (Project root via gutentags finder; same root as ctags/global.)
local function project_root()
  local fname = vim.api.nvim_buf_get_name(0)
  if fname == "" then
    return nil
  end
  local root = require("config.gutentags_root").find(vim.fs.dirname(fname))
  return (root and root ~= "") and root or nil
end

-- 跳转到 file 的 lnum 行 (jump to file:lnum, push jumplist)
local function jump_to(file, lnum)
  vim.cmd("normal! m'")
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.cmd("normal! zz")
end

-- gI 分流入口:处理了(无论成功跳转/提示)返回 true,非 Mapper 方法返回 false
-- 让调用方回退到 ctags_oop.implementations()。
-- (Entry: returns true when handled, false to let caller fall back.)
function M.jump(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local fqn = require("config.java_fqn")
  local sym, err = fqn.symbol_at_cursor()
  if not sym then
    return false -- 取不到符号,交回退分支处理 (let fallback report)
  end
  if sym.kind ~= "m" then
    return false -- 不是方法,gI 跳实现更合理 (not a method)
  end
  if not is_mapper_method(sym) then
    return false -- 非 Mapper 方法,回退跳实现 (not a mapper method)
  end

  local pkg = fqn.package_of_current_file()
  if not pkg then
    return false -- 无包名拼不出 namespace,交回落到跳实现 (no pkg -> fall back)
  end
  local namespace = pkg .. "." .. sym.type
  -- XML 命中则 true(已处理);未命中 jump_to_xml 返回 false,这里一并透传,
  -- 让定义处也回落到 ctags_oop.implementations()(XML-first, impl-fallback)。
  -- (Propagate the XML result; on miss return false so the def-site also falls
  --  back to implementations(), matching the call-site behaviour.)
  return M.jump_to_xml(namespace, sym.name)
end

-- 给定 namespace(全限定 Dao 名) + 方法名,定位并跳转到对应 Mapper XML 语句。
-- 从 M.jump 抽出供调用点(ctags_callsite)复用:调用点能拿到接收者类型,再靠
-- 当前文件 import 解析出全限定名,即可走这里,与定义处统一。
-- 返回值:真正跳转(单命中)或弹出选择器(多命中)返回 true;未找到 XML/方法 id
-- 一律【静默返回 false】,让调用方回落到 Java 实现(XML-first, impl-fallback)。
-- 之所以静默:Dao 可能只有 Java 实现而无 XML(如 *DaoImpl、MyBatis-Plus
-- BaseMapper、@Select 注解 mapper),此时不应弹"无 XML"噪音,直接交回落。
-- (Locate + jump to the XML statement for namespace + method. Returns true if it
--  jumped/opened a picker, false (silently) when nothing matched so the caller
--  can fall back to the Java implementation.)
function M.jump_to_xml(namespace, method_name)
  local root = project_root()
  if not root then
    return false
  end

  -- 1) grep 出含该 namespace 的 XML 文件(可能多个) (find XML by namespace)
  -- 用 -F 固定串匹配 namespace="<FQN>",避免正则元字符与误配其它属性。
  -- 排除 target/build 等构建产物目录,否则会命中 resources 的编译期拷贝(重复)。
  local ns_res = vim.system({
    "grep", "-rlF", 'namespace="' .. namespace .. '"',
    "--include=*.xml",
    "--exclude-dir=target",
    "--exclude-dir=build",
    "--exclude-dir=out",
    root,
  }, { text = true }):wait()
  local xmls = {}
  for _, f in ipairs(vim.split(ns_res.stdout or "", "\n", { plain = true })) do
    if f ~= "" then
      table.insert(xmls, f)
    end
  end
  if #xmls == 0 then
    return false -- 无该 namespace 的 XML,交回落 (no XML -> let caller fall back)
  end

  -- 2) 在这些 XML 里定位方法 id(排除 <sql>) (locate the method id; skip <sql>)
  local pat = "<(select|insert|update|delete)[^>]* id=\"" .. method_name .. "\""
  local hits = {}
  for _, xml in ipairs(xmls) do
    local res = vim.system({ "grep", "-nE", pat, xml }, { text = true }):wait()
    for _, line in ipairs(vim.split(res.stdout or "", "\n", { plain = true })) do
      local lnum, text = line:match("^(%d+):(.*)$")
      if lnum then
        table.insert(hits, { file = xml, lnum = tonumber(lnum), text = text })
      end
    end
  end

  if #hits == 0 then
    return false -- XML 里无此方法 id,交回落 (method not in XML -> fall back)
  end
  if #hits == 1 then
    jump_to(hits[1].file, hits[1].lnum)
    return true
  end

  -- 3) 多命中:Snacks.picker 选择 (multiple hits -> picker)
  local items = {}
  for _, h in ipairs(hits) do
    table.insert(items, {
      file = h.file,
      pos = { h.lnum, 0 },
      text = vim.fn.fnamemodify(h.file, ":t") .. ":" .. h.lnum,
      line = (h.text or ""):gsub("^%s+", ""),
    })
  end
  Snacks.picker.pick({ title = "Mapper XML: " .. method_name, items = items, format = "file" })
  return true
end

return M
