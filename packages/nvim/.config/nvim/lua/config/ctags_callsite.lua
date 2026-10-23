-- 调用点跳实现：在方法【调用点】上按 gI，跳到接收者类型对应的实现体。
-- ---------------------------------------------------------------------------
-- 原 gI 只在【定义处】生效(光标须停在本文件定义的方法 tag 上)。本模块补上
-- 调用点：userService.findById(id) 这种位置,推断接收者类型,再走继承图跳实现。
-- 无 LSP,类型推断全靠文本启发式:
--   * 标识符接收者 userService.foo()  -> 全 buffer 扫"大写类型名 + 变量名"声明
--   * 类型名/new   Foo.bar() / new Foo().bar() -> 接收者本身即类型名
--   * 隐式 this    foo()             -> 当前文件 enclosing 类型
--   * 链式/复杂    getFoo().bar()    -> 推不出,回退按方法名 picker 模糊过滤
-- Dao/Mapper 接收者 -> 先靠当前文件 import 解析全限定名,优先跳 MyBatis XML,
-- 跳不到再回落 Java 实现(与定义处 gI 的 Mapper 语义统一)。
-- (Call-site gI: infer the receiver type via text heuristics (no LSP), then jump
--  to implementations via ctags_oop's inheritance graph. Mapper receivers route
--  to XML first, falling back to the Java impl.)
local M = {}

-- 取简单名:去包名/外类前缀/泛型 (a.b.C<T> -> C)，与其它模块约定一致。
-- (Simple name: strip package/outer-class qualifier and generics.)
local function simple_name(s)
  if not s then
    return nil
  end
  s = s:gsub("<.*", "")
  s = s:gsub(".*[%.%$]", "")
  return s
end

-- 光标所在方法名 + 其左侧"接收者前缀"文本。cursor col 是 0-based 字节偏移;
-- 取到光标处为止的左半行,剥掉行尾标识符(即方法名被光标切开的左半段),余下
-- 就是方法名左边的全部文本,据此判断有无接收者。
-- (Method name under cursor + the text to its left. We strip the trailing
--  identifier chars from the line up-to-cursor to get everything left of the
--  method name, regardless of where in the word the cursor sits.)
local function callsite_context()
  local word = vim.fn.expand("<cword>")
  if word == "" then
    return nil
  end
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] -- 0-based byte offset of cursor
  local upto = line:sub(1, col + 1) -- 含光标下字符 (through the char under cursor)
  local prefix = upto:gsub("[%w_$]+$", "") -- 去掉方法名左半段 (drop the method ident)
  prefix = prefix:gsub("%s+$", "") -- 去尾随空白 (trim trailing space)
  return { name = word, prefix = prefix }
end

-- 从调用点上下文推断接收者形态。返回 { kind=...}:
--   this  -> 无接收者或 this.,用 enclosing 类型
--   type  -> 接收者是类型名(大写开头)或 new X(),name=简单类型名
--   var   -> 接收者是小写变量,var=变量名,需扫 buffer 解析其声明类型
--   chain -> 链式/数组/返回值接收者(以 ) 或 ] 结尾),推不出 -> 回退
-- (Classify the receiver from the call-site prefix text.)
local function receiver_type(ctx)
  local p = ctx.prefix
  -- 前缀不以 . 结尾 -> 裸调用 foo(),隐式 this (bare call -> implicit this)
  if p == "" or not p:match("%.$") then
    return { kind = "this" }
  end
  p = p:gsub("%.$", ""):gsub("%s+$", "") -- 去掉点与尾空白,p 现在是接收者表达式
  -- new X() / new X(args) -> 类型名 X。【锚定表达式开头】很关键:否则
  -- factory.create(new Foo()).bar() 会从里层误捕 Foo,但其真实接收者是
  -- create() 的返回值(应判 chain)。锚定后只认整体就是 new X(...) 的情形。
  -- (Anchor `new` at the start, else a nested `new` inside a chained call(e.g.
  --  factory.create(new Foo())) is wrongly captured; that receiver is a chain.)
  local newt = p:match("^%s*new%s+([%w_$.]+)%s*%(")
  if newt then
    return { kind = "type", name = simple_name(newt) }
  end
  -- 以 ) 或 ] 结尾 -> 链式调用 getFoo().bar() / 数组 arr[i].bar(),放弃推断
  -- (Trailing ) or ] means a chained/array receiver: give up, fall back.)
  if p:match("[%)%]]$") then
    return { kind = "chain" }
  end
  -- 取接收者表达式最后一个标识符 token (last identifier of the receiver expr)
  local recv = p:match("([%w_$]+)$")
  if not recv then
    return { kind = "chain" }
  end
  if recv == "this" or recv == "super" then
    return { kind = "this" }
  end
  -- 大写开头 -> 类型名(静态调用 Foo.bar() / 类引用);小写 -> 变量
  -- (Uppercase first letter -> type name(static/type ref); lowercase -> var.)
  if recv:sub(1, 1):match("%u") then
    return { kind = "type", name = recv }
  end
  return { kind = "var", var = recv }
end

-- 深度感知地按【顶层逗号】(尖括号深度=0)切分,泛型实参里的逗号不切。
-- 例 "Map<String,User>, Foo" -> {"Map<String,User>", "Foo"}。
-- (Split on top-level commas only; commas inside <...> are ignored.)
local function split_top_commas(s)
  local out, depth, buf = {}, 0, {}
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == "<" then
      depth = depth + 1
      buf[#buf + 1] = c
    elseif c == ">" then
      depth = depth - 1
      buf[#buf + 1] = c
    elseif c == "," and depth == 0 then
      out[#out + 1] = table.concat(buf)
      buf = {}
    else
      buf[#buf + 1] = c
    end
  end
  if #buf > 0 then
    out[#out + 1] = table.concat(buf)
  end
  for i, v in ipairs(out) do
    out[i] = (v:gsub("^%s+", ""):gsub("%s+$", ""))
  end
  return out
end

-- 从 text[pos] 起跳过空白,若遇 '<' 返回其配对 '>' 内的内容(深度匹配,支持嵌套)。
-- (From pos, skip spaces; if a '<' follows, return the balanced <...> content.)
local function extract_angle(text, pos)
  while pos <= #text and text:sub(pos, pos):match("%s") do
    pos = pos + 1
  end
  if text:sub(pos, pos) ~= "<" then
    return nil
  end
  local depth, i = 0, pos
  while i <= #text do
    local c = text:sub(i, i)
    if c == "<" then
      depth = depth + 1
    elseif c == ">" then
      depth = depth - 1
      if depth == 0 then
        return text:sub(pos + 1, i - 1)
      end
    end
    i = i + 1
  end
  return nil
end

-- 取类声明区:从 `class Name` 到第一个 '{'(含 extends/implements 子句)。
-- (Class declaration region: from `class Name` up to the first '{'.)
local function class_region(text, name)
  local s = text:find("%f[%w]class%s+" .. name .. "%f[^%w]")
  if not s then
    return nil
  end
  local e = text:find("{", s, true)
  return text:sub(s, e and e - 1 or #text)
end

-- 解析类的类型参数名列表:class Foo<D extends X, T> -> {"D","T"}。
-- (Type parameter names of a class declaration.)
local function type_params(text, name)
  local region = class_region(text, name)
  if not region then
    return {}
  end
  local after = region:find(name, 1, true) + #name
  local inner = extract_angle(region, after)
  if not inner then
    return {}
  end
  local params = {}
  for _, p in ipairs(split_top_commas(inner)) do
    params[#params + 1] = p:match("^([%w_$]+)") -- "D extends CrudDao<T>" -> "D"
  end
  return params
end

-- 解析 extends 子句:返回 基类简单名 + 其泛型实参列表。
-- class Sub extends Base<KycAuthFlowDao, Dto> -> "Base", {"KycAuthFlowDao","Dto"}
-- (Parse the extends clause: base simple name + its generic argument list.)
local function parse_extends(text, name)
  local region = class_region(text, name)
  if not region then
    return nil
  end
  local e, base = region:match("()extends%s+([%w_$.]+)")
  if not base then
    return nil
  end
  -- e 指向 'extends' 起点,从 base 名之后找泛型实参 (args after the base name)
  local after = region:find(base, e, true) + #base
  local inner = extract_angle(region, after)
  local args = inner and split_top_commas(inner) or {}
  return (base:gsub(".*[%.%$]", "")), args
end

-- 读文件全文(失败返回 nil)。基类源码需整文件读 —— 字段声明与 class 头不在
-- 同一行,逐行 buffer API 不便,直接 io 读取最省事。
-- (Read an entire file; base-class source is read whole via io.)
local function read_file(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local s = fd:read("*a")
  fd:close()
  return s
end

-- 把 ctags 记录的文件名解析成可读的绝对路径并读取内容。
-- ctags 路径可能是【相对路径】(相对生成 tags 时的目录,即 tags 文件所在目录,
-- 这是 Vim 'tagrelative' 的语义),:p 按 cwd 解析会失败。故依次尝试:
-- 原样 -> 相对各 tags 文件目录。命中可读即读取。
-- (Resolve a ctags filename to a readable absolute path: ctags paths may be
--  relative to the tag file's directory (Vim 'tagrelative'); :p resolves against
--  cwd and can miss. Try as-is, then relative to each active tag file's dir.)
local function read_tag_file(filename)
  local cands = { vim.fn.fnamemodify(filename, ":p") }
  if not filename:match("^/") then
    for _, tf in ipairs(vim.fn.tagfiles()) do
      local dir = vim.fn.fnamemodify(vim.fn.fnamemodify(tf, ":p"), ":h")
      cands[#cands + 1] = vim.fs.normalize(dir .. "/" .. filename)
    end
  end
  for _, p in ipairs(cands) do
    if vim.fn.filereadable(p) == 1 then
      return read_file(p)
    end
  end
  return nil
end

-- 在 text 里找字段 `<UpperType> var;` 的类型 token(可能是泛型参数名如 D)。
-- 复用与 resolve_var_type 同款 pattern,但允许首字母大写的【单字母泛型参数】。
-- (Find the declared type token of field `var` in text — may be a type param.)
local function field_type_token(text, var)
  local pat = "%f[%w_]([%u][%w_$.]*)[%w_$.,<>%[%]%s]-%s+" .. var .. "%f[^%w_]"
  for line in text:gmatch("[^\n]+") do
    if not line:match("^%s*//") and not line:match("^%s*%*") then
      local t = line:match(pat)
      if t then
        return t
      end
    end
  end
  return nil
end

-- 继承字段类型解析(本文件解析不到变量时的兜底)。
-- 场景:Service 继承自带 dao 字段的泛型基类,如
--   class XxxServiceImpl extends CrudServiceImpl<XxxDao, XxxDto>
--   class CrudServiceImpl<D extends CrudDao<T>, T...> { protected D d; }
-- 调用点 this.d.foo() 里的 d 不在本文件声明。解法:沿 extends 链向上,在基类
-- 源码里找字段 var 的类型 token;若该 token 是基类的【泛型参数名】(如 D),按它
-- 在基类参数表里的位置,取【子类 extends 实参】同位置的具体类型(XxxDao)。
-- token 若本就是具体类型则直接用。最多向上追 5 层防环。
-- (Resolve a field inherited from a generic base class: walk the extends chain,
--  find the field's declared type token in the base source; if it's a type
--  parameter, map it by position to the subclass's extends argument.)
local function resolve_inherited_field_type(var)
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  -- 当前类名:本文件 enclosing 类型 (the class declared in this file)
  local cur_class = require("config.java_fqn").enclosing_type(nil, vim.fn.line("$"))
  local guard = 0
  while cur_class and guard < 5 do
    guard = guard + 1
    local base, args = parse_extends(text, cur_class)
    if not base then
      return nil
    end
    -- 定位基类源文件:taglist 找类型 tag(c/i),取其文件 (locate base via tags)
    local base_file
    for _, t in ipairs(vim.fn.taglist("^" .. vim.fn.escape(base, "/.$^*~[]") .. "$")) do
      if t.kind == "c" or t.kind == "i" then
        base_file = t.filename
        break
      end
    end
    if not base_file then
      return nil
    end
    local base_text = read_tag_file(base_file)
    if not base_text then
      return nil
    end
    -- 基类里找字段 var 的类型 token (field's type token in the base)
    local token = field_type_token(base_text, var)
    if token then
      local params = type_params(base_text, base)
      for i, p in ipairs(params) do
        if p == token then
          -- token 是泛型参数 -> 取子类 extends 同位置实参 (map by position)
          return simple_name(args[i])
        end
      end
      -- token 是具体类型(非泛型参数) -> 直接用 (concrete field type)
      return simple_name(token)
    end
    -- 本层基类没这个字段 -> 继续往它的基类找 (recurse up the extends chain)
    text, cur_class = base_text, base
  end
  return nil
end

-- 解析变量声明类型:全 buffer 扫"大写类型名 + 空格 + 变量名",取光标行之上、
-- 行号最近的那个声明。覆盖字段(private UserService userService;)、参数
-- (m(UserService userService))、局部变量(UserService u = ...)三种形态——它们
-- 都是"类型名 + 变量名"的文本模式。类型名首字母大写,可带泛型/数组,匹配后剥掉。
-- 取"光标之上最近"能让局部变量正确遮盖同名字段。
-- (Resolve a variable's declared type: scan the whole buffer for `UpperType var`,
--  pick the declaration nearest above the cursor so a local shadows a field.)
local function resolve_var_type(var)
  local cur_line = vim.fn.line(".")
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  -- 模式:词边界 + 大写开头的【前导类型标识符】(只捕这一段) + 可选泛型/数组段
  -- (<...> 或 []，惰性吞掉,不进捕获) + 空白 + 目标变量名 + 词边界。
  -- 只捕前导标识符可避免泛型把内层类型名(List<User> -> 误captureUser>)抓错;
  -- 中间段的字符类含 < > [ ] , 空白以容纳 Map<String, User> / User[]。
  -- 赋值 RHS(String n = userService.x()) 因 = 不在字符类内而不会误配。
  -- (Capture only the leading type identifier; a lazy generic/array run before
  --  the var name absorbs <...>/[]. The middle class excludes `=`, so assignment
  --  RHS never matches by accident.)
  local pat = "%f[%w_]([%u][%w_$.]*)[%w_$.,<>%[%]%s]-%s+" .. var .. "%f[^%w_]"
  local best, best_dist
  for i, line in ipairs(lines) do
    -- 跳过注释行的粗略防护 (skip obvious comment lines)
    if not line:match("^%s*//") and not line:match("^%s*%*") then
      local t = line:match(pat)
      if t then
        local dist = (i <= cur_line) and (cur_line - i) or (i - cur_line + 100000)
        -- 光标之上优先(dist 小);其下方加大惩罚,仅在上方无声明时兜底。
        if not best_dist or dist < best_dist then
          best, best_dist = t, dist
        end
      end
    end
  end
  return simple_name(best)
end

-- 读当前文件 import,把简单类型名解析成全限定名(供 Mapper namespace)。
-- import a.b.UserDao; -> com...UserDao;没有匹配 import 时按【同包】处理,用当前
-- 文件 package 拼接(Java 同包无需 import)。通配 import a.b.*; 也按该包兜底。
-- (Resolve a simple type name to its FQN via the current file's imports; falls
--  back to the file's own package(same-package types need no import).)
local function resolve_fqn(simple, fqn_mod)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local star_pkg
  for _, line in ipairs(lines) do
    -- 精确 import:import a.b.UserDao;
    local imp = line:match("^%s*import%s+([%w_$.]+)%s*;")
    if imp and simple_name(imp) == simple then
      return imp
    end
    -- 通配 import:import a.b.*;  记下包名做兜底
    local star = line:match("^%s*import%s+([%w_$.]+)%.%*%s*;")
    if star then
      star_pkg = star
    end
    -- 到类声明就停,import 不会更靠后 (stop at the type declaration)
    if line:match("%f[%w]class%s") or line:match("%f[%w]interface%s") or line:match("%f[%w]enum%s") then
      break
    end
  end
  if star_pkg then
    return star_pkg .. "." .. simple
  end
  -- 同包兜底:用当前文件 package (same-package fallback)
  local pkg = fqn_mod.package_of_current_file()
  if pkg then
    return pkg .. "." .. simple
  end
  return nil
end

-- 回退候选只认 Java 方法 tag,避免 markdown/log 同名文本污染 gI。
-- (Fallback candidates are Java method tags only, avoiding markdown/log noise.)
local function is_java_method_tag(t)
  return t.kind == "m" and type(t.filename) == "string" and t.filename:match("%.java$") ~= nil
end

function M._test_only_java_method_tags(tags)
  local out = {}
  for _, t in ipairs(tags) do
    if is_java_method_tag(t) then
      out[#out + 1] = t
    end
  end
  return out
end

-- 回退:推不出接收者类型时,按方法名选择 Java 方法定义。
-- (Fallback: when receiver inference fails, select Java method definitions.)
local function fallback_picker(method)
  local tags = M._test_only_java_method_tags(vim.fn.taglist("^" .. vim.fn.escape(method, "/.$^*~[]") .. "$"))
  if #tags == 0 then
    vim.notify("no Java method tag for '" .. method .. "'", vim.log.levels.INFO, { title = "ctags-callsite" })
    return
  end

  local function jump(t)
    vim.cmd("normal! m'")
    vim.cmd("edit " .. vim.fn.fnameescape(t.filename))
    local ln = tonumber(t.line)
    if ln then
      vim.api.nvim_win_set_cursor(0, { ln, 0 })
      vim.cmd("normal! zz")
    end
  end

  if #tags == 1 then
    jump(tags[1])
    return
  end

  vim.ui.select(tags, {
    prompt = "Select Java method:",
    format_item = function(t)
      local scope = t.class or t.interface or "?"
      return string.format("%s.%s  (%s:%s)", scope, t.name, vim.fn.fnamemodify(t.filename, ":~:."), t.line)
    end,
  }, function(choice)
    if choice then
      jump(choice)
    end
  end)
end

-- 调用点 gI 入口:推断接收者类型 -> 解析出类型简单名 T -> 分流。
-- 由 java.lua 在"判定光标不在定义处"时调用。
-- (Call-site gI entry: infer receiver type, resolve simple name T, then route.)
function M.goto_impl(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local ctx = callsite_context()
  if not ctx then
    vim.notify("no symbol under cursor", vim.log.levels.WARN, { title = "ctags-callsite" })
    return
  end

  local fqn_mod = require("config.java_fqn")
  local recv = receiver_type(ctx)
  local tname -- 接收者的简单类型名 (receiver's simple type name)

  if recv.kind == "this" then
    -- 隐式 this / 裸调用:用当前文件 enclosing 类型 (implicit this)
    tname = fqn_mod.enclosing_type(vim.fn.expand("%:p"), vim.fn.line("."))
  elseif recv.kind == "type" then
    tname = recv.name
  elseif recv.kind == "var" then
    tname = resolve_var_type(recv.var)
    -- 本文件解析不到 -> 可能是继承自泛型基类的字段(如 CrudServiceImpl 的 d),
    -- 沿 extends 链解析泛型绑定。 (fall back to inherited generic field type)
    if not tname or tname == "" then
      tname = resolve_inherited_field_type(recv.var)
    end
  end
  -- chain / 解析失败 -> 回退按方法名 picker (chain or unresolved -> fallback)
  if not tname or tname == "" then
    fallback_picker(ctx.name)
    return
  end

  -- Dao/Mapper 接收者:优先跳 XML(靠 import 解析全限定名),XML 没命中(无 XML
  -- 或方法不在 XML 里,如 *DaoImpl / MyBatis-Plus BaseMapper / @Select mapper)
  -- 则【回落到 Java 实现】,不在此 return。
  -- (Mapper receiver: XML first via import-resolved FQN; if the XML jump misses,
  --  fall through to the Java implementation instead of returning here.)
  local mybatis = require("config.mybatis_jump")
  if mybatis.suffix_is_mapper(tname) then
    local namespace = resolve_fqn(tname, fqn_mod)
    if namespace and mybatis.jump_to_xml(namespace, ctx.name) then
      return
    end
  end

  -- 普通类型 / Mapper 但无 XML:T 自身 + 所有子类型里,取 scope=class 的方法体跳实现。
  -- (Plain type, or Mapper without XML: jump to class-scoped bodies in T + subtypes.)
  local oop = require("config.ctags_oop")
  local jumped = oop.implementations_of(tname, ctx.name, { include_self = true, only_class = true })
  if not jumped then
    -- T 下无该方法的实现体(可能类型推断偏差/方法名拼写) -> 回退 picker。
    -- (No class body found under T -> fall back to the method-name picker.)
    fallback_picker(ctx.name)
  end
end

return M
