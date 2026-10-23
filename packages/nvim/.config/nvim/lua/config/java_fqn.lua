-- Java 全限定名工具 (fully-qualified name helper)
-- ---------------------------------------------------------------------------
-- 复制全限定名(<leader>cy)和 Dao->XML 跳转(gI)共用的地基。
-- 关键约束(实测):ctags 的 class:/interface: 字段【只存简单名,不带包名】,
-- 且同一简单名可能存在于多个包(如两个 KsaUserLoginLogDao)。所以全限定名
-- 不能从 ctags 拿,必须读【当前文件】的 package 声明 + 类/方法名拼接 ——
-- 这也是为何只在【定义处】生效:光标词必须是当前文件里定义的类型/方法。
-- (ctags stores simple type names only, with no package and with cross-package
--  collisions. The FQN must come from the current file's `package` line plus
--  the name — hence definition-site only.)
local M = {}

-- 取简单名:去包名/外类前缀/泛型 (a.b.C<T> -> C)。
-- (Simple name: strip package/outer-class qualifier and generics.)
local function simple_name(s)
  if not s then
    return nil
  end
  s = s:gsub("<.*", "")
  s = s:gsub(".*[%.%$]", "")
  return s
end

-- 读当前 buffer 的 package 声明 (current file's package declaration)
function M.package_of_current_file()
  local lines = vim.api.nvim_buf_get_lines(0, 0, 60, false)
  for _, line in ipairs(lines) do
    local pkg = line:match("^%s*package%s+([%w%.]+)%s*;")
    if pkg then
      return pkg
    end
  end
  return nil
end

-- 解析光标下符号:取 <cword>,在【当前文件】的 tag 里匹配,行号最近优先。
-- 返回 { name, kind, type, filename, line }，kind c/i/e=类型, m=方法。
-- type 是 enclosing 类型简单名(方法用 class/interface 字段;类型自身用其名)。
-- (Resolve the symbol under the cursor against THIS file's tags; nearest line
--  wins. kind c/i/e = type decl, m = method.)
function M.symbol_at_cursor()
  local word = vim.fn.expand("<cword>")
  if word == "" then
    return nil, "no symbol under cursor"
  end
  local cur_file = vim.fn.expand("%:p")
  local cur_line = vim.fn.line(".")
  local tags = vim.fn.taglist("^" .. vim.fn.escape(word, "/.$^*~[]") .. "$")
  local best, best_dist
  for _, t in ipairs(tags) do
    if vim.fn.fnamemodify(t.filename, ":p") == cur_file then
      local ln = tonumber(t.line) or 0
      local dist = math.abs(ln - cur_line)
      if not best_dist or dist < best_dist then
        best, best_dist = t, dist
      end
    end
  end
  if not best then
    return nil, "'" .. word .. "' is not defined in this file (definition-site only)"
  end

  local kind = best.kind
  local typ
  if kind == "m" then
    -- 方法:enclosing 类型取 class/interface 字段;为空(顶层无 scope)时
    -- 回退到本文件离光标最近的类型 tag 名。
    typ = simple_name(best.class or best.interface) or M.enclosing_type(cur_file, cur_line)
  else
    typ = word -- 类型自身 (the type itself)
  end
  return { name = word, kind = kind, type = typ, filename = best.filename, line = tonumber(best.line) }
end

-- 本文件里离 line 最近(且在其上方)的类型声明名 —— 给无 scope 字段的方法兜底。
-- 直接扫 buffer 文本(typedef tag 的 scope 一般已够用,这是安全网)。
-- (Nearest enclosing type decl at/above `line` by scanning buffer text;
--  fallback for methods whose tag carries no class/interface scope.)
function M.enclosing_type(_cur_file, line)
  local lines = vim.api.nvim_buf_get_lines(0, 0, line, false)
  for i = #lines, 1, -1 do
    -- Lua patterns 无交替,逐类型匹配 (Lua patterns lack alternation)
    local name = lines[i]:match("%f[%w]class%s+([%w_]+)")
      or lines[i]:match("%f[%w]interface%s+([%w_]+)")
      or lines[i]:match("%f[%w]enum%s+([%w_]+)")
    if name then
      return name
    end
  end
  return nil
end

-- 拼全限定名:类型 -> pkg.Type;方法 -> pkg.Type#method。
-- (Build FQN: type -> pkg.Type; method -> pkg.Type#method.)
function M.fqn()
  local sym, err = M.symbol_at_cursor()
  if not sym then
    return nil, err
  end
  local pkg = M.package_of_current_file()
  if not pkg then
    return nil, "no package declaration in this file"
  end
  if sym.kind == "m" then
    if not sym.type then
      return nil, "cannot resolve enclosing type for method '" .. sym.name .. "'"
    end
    return pkg .. "." .. sym.type .. "#" .. sym.name, sym
  end
  return pkg .. "." .. sym.name, sym
end

-- 光标是否真在"方法定义处"(而非同文件内的调用点)。判据:本文件存在 name==
-- <cword> 的方法定义 tag,且光标行与其定义行相邻(±tol,默认 2,容忍多行签名)。
-- gI 据此分流:相邻=定义处走老逻辑;否则=调用点走 ctags_callsite。
-- 仅凭"本文件有同名方法定义"不够 —— 同文件第 20 行定义、第 80 行 this.foo()
-- 调用,会被误判为定义处,故必须比对行号。
-- (Is the cursor really on a method DEFINITION (not an in-file call site)? True
--  when this file defines a method named <cword> whose line is within ±tol of
--  the cursor. Line proximity is required to avoid mistaking an in-file call.)
function M.at_method_definition(tol)
  tol = tol or 2
  local word = vim.fn.expand("<cword>")
  if word == "" then
    return false
  end
  -- 光标词左边紧贴 '.'(允许中间空白) -> 一定是【调用点】recv.method(),不是定义。
  -- 关键:委托样板 wrapper 里,定义行(L33 findByParam)与其下一行的 this.d.findByParam()
  -- 调用紧邻,纯靠行号 ±tol 无法区分,会把调用误判成定义。但定义处方法名前【绝不会】
  -- 有点号,调用点(this.d.foo / repo.foo)前必有点号 —— 据此先行排除。
  -- (If a '.' immediately precedes the word under the cursor, it's a call site
  --  recv.method(), never a definition. Delegating wrappers place the def and the
  --  this.d.<same>() call on adjacent lines, so line proximity alone can't tell
  --  them apart; a method definition never has a dot before its name.)
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] -- 0-based byte offset
  local upto = line:sub(1, col + 1):gsub("[%w_$]+$", "") -- 去掉光标所在标识符
  if upto:match("%.%s*$") then
    return false
  end
  local cur_file = vim.fn.expand("%:p")
  local cur_line = vim.fn.line(".")
  local tags = vim.fn.taglist("^" .. vim.fn.escape(word, "/.$^*~[]") .. "$")
  for _, t in ipairs(tags) do
    if t.kind == "m" and vim.fn.fnamemodify(t.filename, ":p") == cur_file then
      local ln = tonumber(t.line) or 0
      if math.abs(ln - cur_line) <= tol then
        return true
      end
    end
  end
  return false
end

-- Java qualified-member jump: prefer an exact `Qualifier.Symbol` tag, then fall back to native tag jumping.
-- (Java 代码里的限定成员跳转：优先尝试 `Qualifier.Symbol` 的精确 tag，再回退原生跳转。)
function M.jump_member(select_mode)
  local word = vim.fn.expand("<cword>")
  if word == "" then
    return false
  end
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local upto = line:sub(1, col + 1):gsub("[%w_$]+$", "")
  local qualifier = upto:match("([%w_$]+)%.%s*$")
  if qualifier then
    local qtag = qualifier .. "." .. word
    local exact = vim.fn.taglist("^" .. vim.fn.escape(qtag, "/.$^*~[]") .. "$")
    if #exact > 0 then
      pcall(vim.cmd, (select_mode and "tselect " or "tjump ") .. qtag)
      return true
    end
  end
  local keys = select_mode and "g<C-]>" or "<C-]>"
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
  return false
end

return M
