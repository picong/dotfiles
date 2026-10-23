-- Go productivity helpers built on top of gopls, impl and gomodifytags.
-- (基于 gopls、impl、gomodifytags 的 Go 开发增强工具)
-- These are intentionally plugin-free: they only shell out to the binaries that
-- LazyVim's go extra already installs through Mason.
-- (刻意不依赖额外插件，仅调用 LazyVim go extra 已通过 Mason 安装好的二进制)

local M = {}

-- Resolve a Mason-installed binary, falling back to PATH.
-- (解析 Mason 安装的二进制路径，找不到时回退到 PATH)
local function bin(name)
  local mason = vim.fn.stdpath("data") .. "/mason/bin/" .. name
  if vim.fn.executable(mason) == 1 then
    return mason
  end
  if vim.fn.executable(name) == 1 then
    return name
  end
  return nil
end

-- Notify helper with a stable title. (统一标题的通知辅助函数)
local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Go Tools" })
end

-- Find the enclosing struct's receiver-friendly name and a sample receiver var.
-- (查找光标所在结构体的类型名，并生成一个建议的接收者变量名)
-- Uses Treesitter so it works regardless of cursor position inside the struct.
-- (使用 Treesitter，无论光标在结构体内部何处都能识别)
local function struct_at_cursor()
  local ok, parser = pcall(vim.treesitter.get_parser, 0, "go")
  if not ok or not parser then
    return nil
  end
  local tree = parser:parse()[1]
  if not tree then
    return nil
  end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1

  -- Walk up from the smallest node under the cursor to find a type_declaration
  -- whose underlying type is a struct_type. (从光标处的最小节点向上找到 struct 类型声明)
  local node = tree:root():named_descendant_for_range(row, col, row, col)
  while node do
    if node:type() == "type_declaration" then
      for child in node:iter_children() do
        if child:type() == "type_spec" then
          local name_node = child:field("name")[1]
          local type_node = child:field("type")[1]
          if name_node and type_node and type_node:type() == "struct_type" then
            local name = vim.treesitter.get_node_text(name_node, 0)
            return {
              name = name,
              -- Lowercased first letter as a conventional receiver var.
              -- (取首字母小写作为约定俗成的接收者变量名)
              recv_var = name:sub(1, 1):lower(),
              -- Treesitter end row points at the closing brace; +1 lands just
              -- after the struct so stubs are inserted below it.
              -- (Treesitter 结束行指向右花括号，+1 后恰好落在结构体下方)
              insert_row = ({ node:range() })[3] + 1,
            }
          end
        end
      end
    end
    node = node:parent()
  end
  return nil
end

-- Read the package name declared in the current buffer.
-- (读取当前缓冲区声明的包名)
local function current_package()
  for _, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, 64, false)) do
    local pkg = line:match("^%s*package%s+([%w_]+)")
    if pkg then
      return pkg
    end
  end
  return nil
end

-- Generate interface method stubs for the struct under the cursor.
-- (为光标所在结构体生成实现某接口的方法存根)
function M.implement_interface()
  if vim.bo.filetype ~= "go" then
    notify("Not a Go buffer", vim.log.levels.WARN)
    return
  end

  local impl = bin("impl")
  if not impl then
    notify("'impl' not found. Install it with :Mason", vim.log.levels.ERROR)
    return
  end

  local struct = struct_at_cursor()
  if not struct then
    notify("No struct found under cursor", vim.log.levels.WARN)
    return
  end

  vim.ui.input({
    prompt = "Implement interface for " .. struct.name .. " (e.g. io.Reader, fmt.Stringer): ",
  }, function(iface)
    if not iface or iface == "" then
      return
    end

    iface = vim.trim(iface)

    -- For an interface declared in the current package, impl wants the bare
    -- name (e.g. BaseTool), not the qualified one (tools.BaseTool).
    -- (实现同包内的接口时，impl 要求用裸名 BaseTool，而不是 tools.BaseTool)
    local pkg = current_package()
    if pkg then
      iface = iface:gsub("^" .. pkg .. "%.", "")
    end

    -- Persist the buffer first so impl parses the struct you just typed and is
    -- not tripped up by a stale or empty file on disk.
    -- (先保存，让 impl 能解析你刚写的结构体，避免磁盘上是陈旧或空文件)
    if vim.bo.modified then
      vim.cmd("silent noautocmd write")
    end

    -- Receiver: pointer by default, which is the most common Go idiom.
    -- (接收者默认用指针，符合 Go 最常见写法)
    local recv = struct.recv_var .. " *" .. struct.name
    local dir = vim.fn.expand("%:p:h")
    local cmd = { impl, "-dir", dir, recv, iface }

    vim.system(cmd, { text = true }, function(res)
      vim.schedule(function()
        local stderr = (res.stderr or ""):gsub("%s+$", "")
        if res.code ~= 0 or stderr ~= "" then
          local msg = "impl failed: " .. stderr
          -- A parse error usually means a broken/empty .go file in the package.
          -- (解析错误通常意味着包里有破损或空的 .go 文件)
          if stderr:find("expected 'package'") then
            msg = msg .. "\nHint: there is an empty or invalid .go file in this package."
          elseif stderr:find("unrecognized interface") or stderr:find("not found") then
            msg = msg .. "\nHint: for an interface in this package use the bare name (BaseTool), and make sure all files in the package compile."
          end
          notify(msg, vim.log.levels.ERROR)
          return
        end

        local out = (res.stdout or ""):gsub("%s+$", "")
        if out == "" then
          notify("impl produced no output", vim.log.levels.WARN)
          return
        end

        -- Re-resolve the struct position: the earlier save may have reformatted
        -- the buffer (gofmt/goimports), shifting line numbers.
        -- (重新定位结构体：之前的保存可能触发格式化导致行号变动)
        local current = struct_at_cursor()
        local insert_row = current and current.insert_row or struct.insert_row

        -- Insert the stubs right after the struct's closing brace.
        -- (将方法存根插入到结构体定义结束之后)
        local lines = { "" }
        vim.list_extend(lines, vim.split(out, "\n"))
        vim.api.nvim_buf_set_lines(0, insert_row, insert_row, false, lines)
        notify("Implemented " .. iface .. " for " .. struct.name)
      end)
    end)
  end)
end

-- Run a gomodifytags operation on the struct under the cursor.
-- (对光标所在结构体执行 gomodifytags 操作)
-- `action` is either "add" or "remove"; `keys` is e.g. "json".
-- (action 取值 "add"/"remove"，keys 形如 "json")
local function modify_tags(action, keys, opts)
  local tool = bin("gomodifytags")
  if not tool then
    notify("'gomodifytags' not found. Install it with :Mason", vim.log.levels.ERROR)
    return
  end

  local struct = struct_at_cursor()
  if not struct then
    notify("No struct found under cursor", vim.log.levels.WARN)
    return
  end

  -- Persist the buffer first so gomodifytags reads up-to-date content on disk.
  -- (先保存，确保 gomodifytags 读取磁盘上的最新内容)
  if vim.bo.modified then
    vim.cmd("silent noautocmd write")
  end

  local file = vim.fn.expand("%:p")
  -- Note: no -quiet here, since we read the rewritten source from stdout.
  -- (注意：不加 -quiet，因为我们需要从 stdout 读取改写后的源码)
  local cmd = { tool, "-file", file, "-struct", struct.name, "-format", "source" }

  if action == "add" then
    vim.list_extend(cmd, { "-add-tags", keys, "-add-options", keys .. "=omitempty", "-transform", "snakecase" })
  else
    vim.list_extend(cmd, { "-remove-tags", keys })
  end

  if opts and opts.override then
    table.insert(cmd, "-override")
  end

  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        notify("gomodifytags failed: " .. (res.stderr or ""):gsub("%s+$", ""), vim.log.levels.ERROR)
        return
      end

      local out = res.stdout or ""
      if out == "" then
        notify("gomodifytags produced no output", vim.log.levels.WARN)
        return
      end

      -- Replace the whole buffer with the rewritten source, then reload from
      -- disk to keep gopls and the undo history consistent.
      -- (用改写后的源码整体替换缓冲区，再保存以保持 gopls 与撤销历史一致)
      local new_lines = vim.split(out:gsub("\n$", ""), "\n")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, new_lines)
      vim.cmd("silent noautocmd write")
      local verb = action == "add" and "Added" or "Removed"
      notify(verb .. " '" .. keys .. "' tags on " .. struct.name)
    end)
  end)
end

-- Add struct tags (prompts for the tag key, defaults to json).
-- (添加结构体标签，提示输入标签键，默认 json)
function M.add_tags()
  if vim.bo.filetype ~= "go" then
    notify("Not a Go buffer", vim.log.levels.WARN)
    return
  end
  vim.ui.input({ prompt = "Add tags (key, default json): " }, function(input)
    local keys = (input == nil or input == "") and "json" or input
    modify_tags("add", keys, { override = true })
  end)
end

-- Remove struct tags (prompts for the tag key, defaults to json).
-- (移除结构体标签，提示输入标签键，默认 json)
function M.remove_tags()
  if vim.bo.filetype ~= "go" then
    notify("Not a Go buffer", vim.log.levels.WARN)
    return
  end
  vim.ui.input({ prompt = "Remove tags (key, default json): " }, function(input)
    local keys = (input == nil or input == "") and "json" or input
    modify_tags("remove", keys)
  end)
end

-- Fill a struct literal using gopls' "Fill struct" code action.
-- (使用 gopls 的 "Fill struct" code action 填充结构体字面量)
function M.fill_struct()
  if vim.bo.filetype ~= "go" then
    notify("Not a Go buffer", vim.log.levels.WARN)
    return
  end
  vim.lsp.buf.code_action({
    apply = true,
    context = {
      only = { "refactor.rewrite.fillStruct", "refactor.rewrite" },
      diagnostics = {},
    },
  })
end

-- Extract selection into a new function/variable via gopls refactor actions.
-- (通过 gopls 的 refactor code action 将选区提取为函数/变量)
function M.extract()
  if vim.bo.filetype ~= "go" then
    notify("Not a Go buffer", vim.log.levels.WARN)
    return
  end
  vim.lsp.buf.code_action({
    context = {
      only = { "refactor.extract" },
      diagnostics = {},
    },
  })
end

return M
