-- 基于 ctags 的悬浮签名 (ctags-backed hover)
-- ---------------------------------------------------------------------------
-- 接管 java buffer 的 K：无 LSP 时 K 默认是 :Man，对 Java 没用。这里用
-- taglist 查光标下符号的所有定义，浮窗顶部显示"类.方法 签名 (文件:行)"，
-- 底部附第一个定义处的源码前几行。纯 ctags 字段拼装，毫秒级。
-- (Replace the useless `K = :Man` in java buffers. Show every definition's
--  signature/scope/location from ctags, plus a source snippet of the first.)
local M = {}

-- 浮窗里附带的源码行数 (lines of source preview appended)
local SNIPPET_LINES = 8

-- 读某文件指定行起的若干行 (read N lines from a file starting at `from`)
local function read_lines(path, from, count)
  local fd = io.open(path, "r")
  if not fd then
    return {}
  end
  local lines, n = {}, 0
  for line in fd:lines() do
    n = n + 1
    if n >= from then
      table.insert(lines, line)
      if #lines >= count then
        break
      end
    end
  end
  fd:close()
  return lines
end

-- K：悬浮显示光标下符号的定义签名 + 源码片段。
-- (Hover: signatures + source snippet for the symbol under the cursor.)
function M.hover()
  local word = vim.fn.expand("<cword>")
  if word == "" then
    return
  end
  local tags = vim.fn.taglist("^" .. vim.fn.escape(word, "/.$^*~[]") .. "$")
  if #tags == 0 then
    vim.notify("ctags: no definition for '" .. word .. "'", vim.log.levels.INFO, { title = "ctags-hover" })
    return
  end

  local md = {}
  -- 顶部：每个定义一行签名 (top: one signature line per definition)
  for _, t in ipairs(tags) do
    local scope = t.class or t.interface or t["enum"]
    local sig = t.signature or ""
    local head = scope and (scope .. "." .. t.name) or t.name
    table.insert(md, string.format("```java\n%s%s\n```", head, sig))
    table.insert(md, string.format("_%s:%s_", vim.fn.fnamemodify(t.filename, ":~:."), t.line or "?"))
  end

  -- 底部：第一个定义处的源码片段 (bottom: source snippet of the first def)
  local first = tags[1]
  local from = tonumber(first.line)
  if from then
    local snippet = read_lines(first.filename, from, SNIPPET_LINES)
    if #snippet > 0 then
      table.insert(md, "---")
      table.insert(md, "```java")
      vim.list_extend(md, snippet)
      table.insert(md, "```")
    end
  end

  -- 用 LSP 的浮窗工具渲染：自带 markdown 高亮、q 关闭、再次按 K 进入浮窗。
  -- (Render via the LSP float util: markdown highlight + q-to-close for free.)
  vim.lsp.util.open_floating_preview(md, "markdown", {
    border = "rounded",
    max_width = 100,
    focusable = true,
  })
end

return M
