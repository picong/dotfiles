-- herdr.lua — 从 nvim 把上下文推给 herdr 里的 AI agent
--
-- 为什么不用 sidekick.nvim:它的 mux 后端在类型上就写死了
-- `backend? "tmux"|"zellij"`,认不了 herdr。而 herdr 本身已经是
-- agent 专用的终端管理器,还带 socket API,直接调它比套一层插件更准。
--
-- herdr 相对 tmux 的关键优势:它知道每个 agent 的 idle/working/blocked
-- 状态。所以下面发 prompt 前可以先判断 agent 忙不忙,而不是盲发。
--
-- 设计原则(来自 r/neovim 社区共识):发【引用】不发代码本身。
-- agent 拿到 `path/to/file.go:250-400` 会自己去读周围上下文,
-- 比粘贴一段裸代码理解得更好,也更省 token。

local M = {}

local BIN = vim.env.HERDR_BIN_PATH or "herdr"

-- 是否跑在 herdr 管理的 pane 里。不在的话所有命令都该直接拒绝,
-- 而不是去操作别的 client 正聚焦的 pane。
function M.inside()
  return vim.env.HERDR_ENV == "1"
end

local function warn(msg)
  vim.notify(msg, vim.log.levels.WARN, { title = "herdr" })
end

-- 同步调用 herdr CLI 并解析 JSON。
-- herdr 的约定:服务端错误是 stderr 上的 JSON + exit 1,语法错误 exit 2。
local function call(args)
  local out = vim.system({ BIN, unpack(args) }, { text = true }):wait()
  if out.code ~= 0 then
    return nil, (out.stderr ~= "" and out.stderr or out.stdout or "exit " .. out.code)
  end
  local ok, decoded = pcall(vim.json.decode, out.stdout)
  if not ok then
    return nil, "无法解析 herdr 输出"
  end
  return decoded, nil
end

-- 列出当前 workspace 里的 agent。
-- 注意 agent list 不接受 --workspace,得自己按 workspace_id 过滤。
function M.agents()
  local res, err = call({ "agent", "list" })
  if not res then
    return nil, err
  end
  local agents = {}
  local ws = vim.env.HERDR_WORKSPACE_ID
  for _, a in ipairs(vim.tbl_get(res, "result", "agents") or {}) do
    -- 跳过 nvim 自己所在的 pane:那儿跑的是当前这个 agent,
    -- 往自己发 prompt 没有意义。
    if a.pane_id ~= vim.env.HERDR_PANE_ID and (not ws or a.workspace_id == ws) then
      table.insert(agents, a)
    end
  end
  return agents, nil
end

-- agent 的显示名。herdr 的 agent 命令接受「唯一 live agent 名」或
-- 「承载它的 pane_id」。名字不保证存在,所以统一用 pane_id 做 target。
local function label(a)
  local title = a.terminal_title_stripped or ""
  local cwd = vim.fn.fnamemodify(a.cwd or "", ":t")
  local parts = { a.agent or "?", "[" .. (a.agent_status or "?") .. "]" }
  if cwd ~= "" then
    table.insert(parts, cwd)
  end
  if title ~= "" and title ~= cwd then
    table.insert(parts, "· " .. title)
  end
  return table.concat(parts, " ")
end

-- 选一个 agent。只有一个时直接用,多个时弹 vim.ui.select。
local function pick(cb)
  if not M.inside() then
    return warn("不在 herdr pane 里,无法定位 agent")
  end
  local agents, err = M.agents()
  if not agents then
    return warn("herdr agent list 失败: " .. tostring(err))
  end
  if #agents == 0 then
    return warn("当前 workspace 没有其他 agent pane")
  end
  if #agents == 1 then
    return cb(agents[1])
  end
  vim.ui.select(agents, { prompt = "选择 agent", format_item = label }, function(choice)
    if choice then
      cb(choice)
    end
  end)
end

M.pick = pick

-- ── 按 kind 定位 agent ────────────────────────────────────────

-- 想直接点名"发给 claude / pi / codex"时用这个。
-- 找不到就问要不要新起一个:herdr agent start 需要一个已在 shell 提示符
-- 的空 pane,所以得先 split 出来。
--
-- kind 取值见 `herdr agent start --kind` 的 possible values。
function M.pick_kind(kind, cb)
  if not M.inside() then
    return warn("不在 herdr pane 里,无法定位 agent")
  end
  local agents, err = M.agents()
  if not agents then
    return warn("herdr agent list 失败: " .. tostring(err))
  end

  local matched = {}
  for _, a in ipairs(agents) do
    if a.agent == kind then
      table.insert(matched, a)
    end
  end

  if #matched == 1 then
    return cb(matched[1])
  end
  if #matched > 1 then
    -- 同一种 agent 开了多个(比如两个 claude 各管一个模块),仍要选
    return vim.ui.select(matched, { prompt = "选择 " .. kind, format_item = label }, function(choice)
      if choice then
        cb(choice)
      end
    end)
  end

  -- 一个都没有
  vim.ui.select({ "是,新起一个", "否" }, {
    prompt = "没有在跑的 " .. kind .. ",要启动吗?",
  }, function(choice)
    if choice ~= "是,新起一个" then
      return
    end
    M.start(kind, cb)
  end)
end

-- agent pane 固定开在 nvim 右侧。
--
-- 原来这里按 vim.o.columns 自适应选方向,但那个值是 nvim 所在 pane 的宽度,
-- 不是屏幕宽度 —— nvim 只占半屏时它不到 160,于是一路都切到下方去了。
-- 左右并排才是 review diff 的正确布局(nvim 一侧看代码,agent 一侧看输出),
-- 所以不再判断,固定 right。
M.split_direction = "right"

-- 在当前 tab 里 split 一个 pane 并启动 agent。
--
-- 遵循 herdr 的几条规矩:cwd 显式传(否则新 pane 可能落在别处)、
-- --no-focus 保持你的焦点在 nvim 里。
function M.start(kind, cb)
  local cwd = vim.fn.getcwd()

  local res, err = call({
    "pane",
    "split",
    "--current",
    "--direction",
    M.split_direction,
    "--cwd",
    cwd,
    "--no-focus",
  })
  if not res then
    return warn("herdr pane split 失败: " .. tostring(err))
  end

  local pane_id = vim.tbl_get(res, "result", "pane", "pane_id")
  if not pane_id then
    return warn("herdr 没有返回新 pane 的 id")
  end

  -- agent 名必须匹配 [a-z][a-z0-9_-]{0,31} 且在 live agent 里唯一。
  -- 用 kind + pane 序号,pane_id 里的冒号不合法所以换掉。
  local name = (kind .. "-" .. pane_id:gsub("[^%w]", "")):lower():sub(1, 32)

  vim.notify("正在启动 " .. kind .. " …", vim.log.levels.INFO, { title = "herdr" })

  -- agent start 要等到 agent 真的就绪才返回(默认 30s),所以异步跑,
  -- 别把 nvim 卡住。
  vim.system(
    { BIN, "agent", "start", name, "--kind", kind, "--pane", pane_id },
    { text = true },
    vim.schedule_wrap(function(out)
      if out.code ~= 0 then
        local msg = out.stderr ~= "" and out.stderr or out.stdout
        -- agent_not_ready 意味着它起来了但卡在启动阶段(比如要登录),
        -- 名字仍然可用,所以不当成彻底失败。
        if tostring(msg):find("agent_not_ready") then
          warn(kind .. " 已启动但尚未就绪(可能需要登录),请切过去看看")
        else
          warn("herdr agent start 失败: " .. tostring(msg))
        end
        return
      end
      vim.notify(kind .. " 已就绪", vim.log.levels.INFO, { title = "herdr" })
      if cb then
        cb({ pane_id = pane_id, agent = kind, agent_status = "idle", cwd = cwd })
      end
    end)
  )
end

-- 发 prompt。不加 --wait:nvim 侧不该阻塞等 agent 干完活,
-- 用户自己切过去看。blocked 状态下 herdr 会拒绝提交并返回
-- agent_blocked,这里如实报出来,而不是重试把输入灌进审批对话框。
function M.prompt(target, text, opts)
  opts = opts or {}
  local res, err = call({ "agent", "prompt", target, text })
  if not res then
    if tostring(err):find("agent_blocked") then
      warn("agent 正卡在审批/提问界面,先切过去处理")
    else
      warn("herdr agent prompt 失败: " .. tostring(err))
    end
    return false
  end
  if opts.focus then
    call({ "agent", "focus", target })
  else
    vim.notify("已发送 → " .. target, vim.log.levels.INFO, { title = "herdr" })
  end
  return true
end

-- ── 上下文引用构造 ─────────────────────────────────────────────

-- 相对仓库根的路径。agent 的 cwd 通常是仓库根,给相对路径它更容易 resolve。
--
-- 注意多模块 Maven 项目:vim.fs.root 会命中最近的 pom.xml,那是 module 根
-- 而不是仓库根,给出的相对路径 agent 解析不了。所以优先认 .git。
local function relpath()
  local abs = vim.api.nvim_buf_get_name(0)
  if abs == "" then
    return nil
  end
  -- .git 单独一轮:多模块项目里它才是真正的仓库根
  local root = vim.fs.root(abs, { ".git" }) or vim.fs.root(abs, { "pom.xml", "go.mod" })
  if root then
    local rel = abs:sub(#root + 2)
    if rel ~= "" then
      return rel
    end
  end
  return vim.fn.fnamemodify(abs, ":~:.")
end

M.relpath = relpath

-- 当前文件引用,`@lua/config/herdr.lua`
--
-- 用 @ 前缀:claude / pi / codex 都把 @path 当成"读这个文件"的显式指令,
-- 而裸路径只是一串文本,agent 可能读也可能猜。@ 让它一定去读。
-- 三个 agent 的 @ 都只在用户输入的消息里生效,而 herdr agent prompt 正是
-- 把文本当键盘输入送进去的,所以这条路径成立。
function M.ref_file()
  local p = relpath()
  return p and ("@" .. p)
end

-- 当前行引用,`@lua/config/herdr.lua:42`
function M.ref_line()
  local p = relpath()
  return p and ("@" .. p .. ":" .. vim.api.nvim_win_get_cursor(0)[1])
end

-- 当前可视选区的行范围。
--
-- 不能用 '< '> 标记:lazy.nvim 的 keys 用 Lua function 时【不会】先退出
-- visual 模式,那两个标记要么还是上一次选区的旧值,要么从未设置过(返回 0)
-- —— 这就是 `...Controller.java:0` 的来源。
-- 'v' 是选区起点、'.' 是光标当前位置,在 visual 模式里实时有效。
local function selection_range()
  local mode = vim.fn.mode()
  local s, e
  if mode:match("^[vV\22]") then
    s, e = vim.fn.line("v"), vim.fn.line(".")
  else
    -- 已经退出 visual(比如用 <cmd> 映射调进来)时退回标记
    s, e = vim.fn.line("'<"), vim.fn.line("'>")
  end
  if s == 0 or e == 0 then
    return nil
  end
  if s > e then
    s, e = e, s
  end
  return s, e
end

M.selection_range = selection_range

-- 可视选区引用,`@lua/config/herdr.lua:250-400`
function M.ref_selection()
  local p = relpath()
  if not p then
    return nil
  end
  local s, e = selection_range()
  if not s then
    return nil
  end
  if s == e then
    return "@" .. p .. ":" .. s
  end
  return "@" .. p .. ":" .. s .. "-" .. e
end

-- 选区的实际代码内容,带行号和语言标注的 fenced block。
--
-- 什么时候用这个而不是 ref_selection:见 plugins/agent.lua 里的说明。
function M.selection_text()
  local s, e = selection_range()
  if not s then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(0, s - 1, e, false)
  if #lines == 0 then
    return nil
  end
  local p = relpath() or "?"
  local ft = vim.bo.filetype
  -- 带上行号,这样 agent 引用某一行时你能直接对上
  local numbered = {}
  for i, l in ipairs(lines) do
    table.insert(numbered, string.format("%d: %s", s + i - 1, l))
  end
  return table.concat({
    "@" .. p .. ":" .. s .. "-" .. e,
    "",
    "```" .. (ft ~= "" and ft or ""),
    table.concat(numbered, "\n"),
    "```",
  }, "\n")
end

-- 当前 buffer 的诊断摘要。agent 修 bug 时给它编译/lint 错误比让它自己找快得多。
function M.ref_diagnostics()
  local diags = vim.diagnostic.get(0, { severity = { min = vim.diagnostic.severity.WARN } })
  if #diags == 0 then
    return nil
  end
  local p = relpath() or "?"
  local lines = {}
  for _, d in ipairs(diags) do
    local sev = vim.diagnostic.severity[d.severity] or "?"
    local msg = (d.message or ""):gsub("%s+", " ")
    table.insert(lines, string.format("%s:%d %s: %s", p, d.lnum + 1, sev, msg))
  end
  -- 首行给 @ 引用让 agent 去读文件,后面是诊断明细
  return "@" .. p .. "\n" .. table.concat(lines, "\n")
end

return M
