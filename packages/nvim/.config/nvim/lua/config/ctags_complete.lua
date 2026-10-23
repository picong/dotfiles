-- 基于 ctags 的补全源 (ctags-backed completion)
-- ---------------------------------------------------------------------------
-- 把 ctags 符号喂进 blink.cmp 的补全菜单，弥补"无 LSP 时跨文件类名/方法名
-- 补不出来"的空白。实现走 Vim 的 complete-function 协议(:h complete-functions)，
-- 再由 blink 内置的 complete_func 源包装成补全项。
--
-- 性能约束(实测)：taglist 短前缀(如 'get')命中 1.8 万条要 ~123ms，长前缀
-- (如 'findByPa')仅 1.2ms。所以设 3 字符门槛、按 name 去重、截断 200 条，
-- 避免"边打边补"卡顿，也避免菜单被海量同名项刷屏。
-- (ctags has no type inference; we prefix-match symbol names. A 3-char gate
--  keeps the hot path off the 123ms short-prefix case; dedup + cap keep the
--  menu clean. signature is surfaced as the menu text.)
local M = {}

-- 触发补全所需的最小输入长度 (min chars before querying ctags)
local MIN_CHARS = 3
-- 单次补全最多返回多少项 (cap on returned items)
local MAX_ITEMS = 200

-- ctags kind -> Vim complete-item kind 字母 (:h complete-items 的 'kind')
-- blink 的 complete_func 源再把这些字母映射成补全图标。
-- (Map ctags kinds to Vim complete-item kind letters; blink maps them to icons.)
local KIND_MAP = {
  c = "t", -- class -> typedef
  i = "t", -- interface -> typedef
  e = "t", -- enum -> typedef
  m = "f", -- method -> function
  f = "f", -- field/function -> function
  p = "m", -- package/member -> member
}

-- complete-function：findstart=1 求词起始列，findstart=0 求候选列表。
-- (Vim complete-function entrypoint.)
function M.completefunc(findstart, base)
  if findstart == 1 then
    -- 从光标回扫到 \k 词边界，返回起始列(0-based)。
    -- (Scan back to the keyword boundary; return 0-based start column.)
    local line = vim.fn.getline(".")
    local col = vim.fn.col(".") - 1
    local start = col
    while start > 0 and line:sub(start, start):match("[%w_]") do
      start = start - 1
    end
    return start
  end

  -- findstart=0：base 为已输入前缀 (the typed prefix)
  if not base or #base < MIN_CHARS then
    return {} -- 未达门槛，交给 buffer 词补全 (below gate, defer to buffer source)
  end

  local pat = "^" .. vim.fn.escape(base, "/.$^*~[]")
  local tags = vim.fn.taglist(pat)
  local seen, items = {}, {}
  for _, t in ipairs(tags) do
    if not seen[t.name] then
      seen[t.name] = true
      local scope = t.class or t.interface or t["enum"]
      local info = scope and (scope .. "  " .. vim.fn.fnamemodify(t.filename, ":t")) or vim.fn.fnamemodify(
        t.filename,
        ":t"
      )
      table.insert(items, {
        word = t.name,
        kind = KIND_MAP[t.kind] or t.kind,
        menu = t.signature or "", -- 补全菜单右侧显示签名 (signature shown in menu)
        info = info, -- 文档窗显示所属类 + 文件 (class + file in doc popup)
        dup = 0,
      })
      if #items >= MAX_ITEMS then
        break
      end
    end
  end
  return items
end

-- 供 blink.cmp 的 complete_func 源调用：返回 completefunc 的 v:lua 引用串。
-- (Return the v:lua reference string blink's complete_func source invokes.)
function M.complete_func()
  return "v:lua.require'config.ctags_complete'.completefunc"
end

return M
