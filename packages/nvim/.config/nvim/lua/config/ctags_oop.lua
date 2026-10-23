-- 基于 ctags 的 OOP 跳转：跳实现 (gI) / 跳父方法 (gs)
-- ---------------------------------------------------------------------------
-- ctags 本身【不记录】实现/父子方法关系，它只有定义。但 browse.lua 里开了
-- `--fields=+ailmnS`，于是 tags 里多出两组关系字段，本模块就靠它们重建继承图：
--   * 类型定义(kind c/i)带 `inherits:Base,IFoo` —— 它 extends/implements 了谁
--   * 方法定义(kind m)带 `class:Impl` 或 `interface:IFoo` —— 它属于哪个类型
-- 有了这两组，就能在内存里模拟 LSP 的 goto-implementation / goto-super。
--
-- 关键约定：继承全部按【简单名】(去掉包/外类前缀) 处理，因为 `inherits` 字段
-- 写的就是源码里裸名 (e.g. `extends QueryEntity` -> inherits:QueryEntity)。
-- (ctags records definitions only, never impl/override links. We rebuild an
--  inheritance graph from the `inherits:` and `class:/interface:` fields that
--  browse.lua enables, keyed by simple type names, to emulate LSP jumps.)
local M = {}

-- 继承图缓存：按 tags 文件路径 + mtime 失效 (cache, invalidated on mtime change)
-- graph = { fwd = { Type -> {parents} }, rev = { Type -> {children} } }
local cache = { key = nil, graph = nil }

-- 取简单名：去掉包名 (a.b.C -> C) 和外类前缀 (Outer.Inner -> Inner)，
-- 同时剥掉泛型参数 (Foo<Bar> -> Foo)。
-- (Simple name: strip package / outer-class qualifier and generics.)
local function simple_name(s)
  if not s then
    return nil
  end
  s = s:gsub("<.*", "") -- 去泛型 (drop generics)
  s = s:gsub(".*[%.%$]", "") -- 取最后一段 (last component after . or $)
  return s
end

-- 当前 buffer 生效的 tags 文件路径列表 (active tag files for this buffer)
local function tagfiles()
  return vim.fn.tagfiles()
end

-- 构建/取继承图：用系统 grep 只抽出带 inherits 的行(几千行、几十毫秒)，
-- 避免把上百 MB 的 tags 整个读进 Lua。
-- (Build/get the inheritance graph; grep only the `inherits:` lines instead of
--  loading the whole multi-hundred-MB tags file.)
local function get_graph()
  local files = tagfiles()
  if #files == 0 then
    return nil, "no tags file active for this buffer"
  end
  -- 用第一个 tags 文件(gutentags 项目级单文件) (use the project tagfile)
  local tf = files[1]
  local st = vim.loop.fs_stat(tf)
  if not st then
    return nil, "tags file not found: " .. tf
  end
  local key = tf .. ":" .. tostring(st.mtime.sec)
  if cache.key == key and cache.graph then
    return cache.graph
  end

  local fwd, rev = {}, {}
  -- 只抓 inherits 行；\t 用 $'...' 不便跨平台，这里用 grep -P 的 \t。
  local out = vim.fn.systemlist({ "grep", "-P", "\\tinherits:", tf })
  if vim.v.shell_error ~= 0 and #out == 0 then
    return nil, "no inheritance info in tags (need --fields=+i)"
  end
  for _, line in ipairs(out) do
    local cols = vim.split(line, "\t", { plain = true })
    local name = simple_name(cols[1])
    local parents
    for _, c in ipairs(cols) do
      local p = c:match("^inherits:(.+)$")
      if p then
        parents = p
        break
      end
    end
    if name and parents then
      fwd[name] = fwd[name] or {}
      for _, raw in ipairs(vim.split(parents, ",", { plain = true })) do
        local par = simple_name(raw)
        if par and par ~= "" then
          fwd[name][par] = true
          rev[par] = rev[par] or {}
          rev[par][name] = true
        end
      end
    end
  end

  cache.key = key
  cache.graph = { fwd = fwd, rev = rev }
  return cache.graph
end

-- 在图上做传递闭包：从 start 出发沿 map 收集所有可达类型(不含 start 自身)。
-- (Transitive closure over the graph, excluding the start node.)
local function closure(map, start)
  local seen, stack, result = { [start] = true }, { start }, {}
  while #stack > 0 do
    local cur = table.remove(stack)
    for nxt in pairs(map[cur] or {}) do
      if not seen[nxt] then
        seen[nxt] = true
        result[nxt] = true
        table.insert(stack, nxt)
      end
    end
  end
  return result
end

-- 解析光标处的"方法名 + 所属类型"：取当前文件里 name==cword 的方法 tag 中
-- 行号离光标最近的那个，用它的 class/interface scope 作为当前类型。
-- 这样拿到的 scope 字符串与其它方法 tag 完全同源同格式，最可靠。
-- (Resolve the method name under the cursor and its enclosing type by picking
--  the same-named method tag in THIS file nearest the cursor line.)
local function method_at_cursor()
  local word = vim.fn.expand("<cword>")
  if word == "" then
    return nil, "no symbol under cursor"
  end
  local cur_file = vim.fn.expand("%:p")
  local cur_line = vim.fn.line(".")
  local tags = vim.fn.taglist("^" .. vim.fn.escape(word, "/.$^*~[]") .. "$")
  local best, best_dist
  for _, t in ipairs(tags) do
    if t.kind == "m" and vim.fn.fnamemodify(t.filename, ":p") == cur_file then
      local ln = tonumber(t.line) or 0
      local dist = math.abs(ln - cur_line)
      if not best_dist or dist < best_dist then
        best, best_dist = t, dist
      end
    end
  end
  if not best then
    return nil, "no method named '" .. word .. "' defined in this file"
  end
  local scope = simple_name(best.class or best.interface)
  if not scope then
    return nil, "method '" .. word .. "' has no class/interface scope in tags"
  end
  return { name = word, type = scope }
end

-- 把候选方法 tag 列表呈现出来：1 个直接跳，多个用 vim.ui.select 选。
-- (Present matches: jump directly on a single hit, vim.ui.select otherwise.)
local function present(items, empty_msg)
  if #items == 0 then
    vim.notify(empty_msg, vim.log.levels.INFO, { title = "ctags-oop" })
    return
  end
  local function jump(t)
    vim.cmd("normal! m'") -- 入跳转列表 (push jumplist)
    vim.cmd("edit " .. vim.fn.fnameescape(t.filename))
    local ln = tonumber(t.line)
    if ln then
      vim.api.nvim_win_set_cursor(0, { ln, 0 })
      vim.cmd("normal! zz")
    end
  end
  if #items == 1 then
    jump(items[1])
    return
  end
  vim.ui.select(items, {
    prompt = "Select target:",
    format_item = function(t)
      return string.format("%s.%s  (%s:%s)", t._scope, t.name, vim.fn.fnamemodify(t.filename, ":~:."), t.line)
    end,
  }, function(choice)
    if choice then
      jump(choice)
    end
  end)
end

-- 在给定类型集合里收集 name==method 的方法 tag (collect same-named methods
-- whose scope falls in the wanted type set; skip the cursor's own location).
-- only_class=true 时只保留 scope 来自 `class:` 字段的方法(真实现体),滤掉
-- 来自 `interface:` 的方法声明 —— 调用点跳实现用,接口声明本身不是实现。
-- 不传该参数时行为与旧版完全一致,implementations()/super() 零回归。
-- (only_class keeps methods scoped by `class:` only — real bodies — dropping
--  `interface:` declarations; used by the call-site jump. Omitting it preserves
--  the old behaviour for implementations()/super().)
local function methods_in_types(method, type_set, skip_type, only_class)
  local tags = vim.fn.taglist("^" .. vim.fn.escape(method, "/.$^*~[]") .. "$")
  local hits = {}
  for _, t in ipairs(tags) do
    if t.kind == "m" then
      -- scope 来源:有 class 字段=类里的实现体;否则取 interface 字段=声明。
      -- (Scope origin: a `class:` field means a real body, else `interface:`.)
      local is_class = t.class ~= nil and t.class ~= ""
      local sc = simple_name(t.class or t.interface)
      if sc and type_set[sc] and sc ~= skip_type and (not only_class or is_class) then
        t._scope = sc
        table.insert(hits, t)
      end
    end
  end
  return hits
end

-- 复用入口:给定【类型简单名 + 方法名】跳到实现体,供调用点(ctags_callsite)复用。
-- opts.include_self=true 把类型 T 自身也纳入候选(具体类接收者 impl.foo() 需要它,
-- 因为要跳的就是 T 自己的方法体);默认 false 沿用"只找子类型"语义。
-- opts.only_class=true 只列 scope 来自 class 的方法体,滤掉接口声明(列表更干净)。
-- 找不到返回 false 让调用方决定是否回退;成功(含弹选择)返回 true。
-- (Reusable entry: jump to implementations of a given simple type + method name,
--  for the call-site path. include_self adds T itself (needed for concrete-class
--  receivers); only_class drops interface declarations. Returns false on empty.)
function M.implementations_of(type_name, method_name, opts)
  opts = opts or {}
  local graph, err = get_graph()
  if not graph then
    vim.notify(err, vim.log.levels.WARN, { title = "ctags-oop" })
    return false
  end
  -- 候选类型集 = T 的所有子类型(反向图闭包),按需并入 T 自身。
  -- (Candidate types = subtypes of T via the reverse graph, plus T itself.)
  local types = closure(graph.rev, type_name)
  if opts.include_self then
    types[type_name] = true
  end
  -- 不排除自身(skip_type=nil):是否含 T 完全由 include_self 决定。
  -- (No skip_type here; membership of T is governed solely by include_self.)
  local hits = methods_in_types(method_name, types, nil, opts.only_class)
  if #hits == 0 then
    return false
  end
  present(hits, "") -- #hits>0 已保证,empty_msg 不会触发 (never empty here)
  return true
end

-- gI: 跳到当前(接口/类)方法的所有实现/重写 —— 沿反向图找子类型里的同名方法。
-- (Go to implementations: same-named methods in subtypes, via the reverse graph.)
function M.implementations()
  local graph, err = get_graph()
  if not graph then
    vim.notify(err, vim.log.levels.WARN, { title = "ctags-oop" })
    return
  end
  local m, merr = method_at_cursor()
  if not m then
    vim.notify(merr, vim.log.levels.WARN, { title = "ctags-oop" })
    return
  end
  local subtypes = closure(graph.rev, m.type)
  local hits = methods_in_types(m.name, subtypes, m.type)
  present(hits, string.format("no implementations of %s.%s found in tags", m.type, m.name))
end

-- gs: 跳到父接口/父类里对应的方法 —— 沿正向图找祖先类型里的同名方法。
-- (Go to super: same-named method in an ancestor type, via the forward graph.)
function M.super()
  local graph, err = get_graph()
  if not graph then
    vim.notify(err, vim.log.levels.WARN, { title = "ctags-oop" })
    return
  end
  local m, merr = method_at_cursor()
  if not m then
    vim.notify(merr, vim.log.levels.WARN, { title = "ctags-oop" })
    return
  end
  local ancestors = closure(graph.fwd, m.type)
  local hits = methods_in_types(m.name, ancestors, m.type)
  present(hits, string.format("no super/overridden method for %s.%s found in tags", m.type, m.name))
end

return M
