-- agent.lua — AI agent 工作流
--
-- 架构:agent 跑在 herdr 的独立 pane 里,nvim 只做两件事 ——
--   1. 把「引用」推给 agent(<leader>A…)
--   2. review agent 改出来的 diff(<leader>Ad / <leader>Ar)
--
-- 这是 r/neovim 社区的压倒性共识:不要把 agent 做成插件。CLI agent
-- 迭代太快,插件层永远在追;而 herdr 已经给了 pane 管理 + agent 状态感知。
--
-- 键位前缀说明:<leader>a 已被 BlameToggle 占用(config/keymaps.lua),
-- 所以 agent 相关统一用大写 <leader>A。

local function herdr()
  return require("config.herdr")
end

-- 定位 agent:opts.kind 给了就点名找那一种(没有就问要不要起),
-- 没给就列出当前 workspace 的全部 agent 让你选。
local function locate(opts, cb)
  if opts.kind then
    herdr().pick_kind(opts.kind, cb)
  else
    herdr().pick(cb)
  end
end

-- 把一段文本发给 agent。focus=true 时发完直接切过去。
local function send(build, opts)
  opts = opts or {}
  return function()
    local text = build()
    if not text or text == "" then
      return vim.notify("没有可发送的内容", vim.log.levels.WARN, { title = "herdr" })
    end
    locate(opts, function(a)
      herdr().prompt(a.pane_id, text, opts)
    end)
  end
end

-- 先问一句话,再带上当前文件/选区的 @ 引用一起发。
-- 这是最常用的入口:@引用让 agent 去读文件,问题给意图。
local function ask(ref_fn, opts)
  opts = opts or {}
  return function()
    local ref = ref_fn and ref_fn()
    local who = opts.kind and (" → " .. opts.kind) or ""
    -- 提示里只显示首行:selection_text 带的是整个代码块,直接塞进 prompt
    -- 会把输入框撑爆
    local head = ref and ref:gsub("\n.*", "") or nil
    local hint = head and (head .. who .. ": ") or ("问 agent" .. who .. ": ")
    vim.ui.input({ prompt = hint }, function(input)
      if not input or input == "" then
        return
      end
      local text = ref and (ref .. "\n\n" .. input) or input
      locate(opts, function(a)
        herdr().prompt(a.pane_id, text, opts)
      end)
    end)
  end
end

return {
  -- ── review 层:agent 改完看 diff ────────────────────────────
  -- 社区在 review 工具上几乎无异议地收敛到 git 原生那套。codediff 的
  -- 优势是普通 buffer(不是 TUI 浮层),能在 diff 里直接导航和编辑。
  {
    "esmuellert/codediff.nvim",
    cmd = "CodeDiff",
    keys = {
      { "<leader>Ad", "<cmd>CodeDiff<cr>", desc = "Agent: review 工作区改动" },
      { "<leader>Ar", "<cmd>CodeDiff HEAD<cr>", desc = "Agent: review vs HEAD" },
      { "<leader>AS", "<cmd>CodeDiff --staged<cr>", desc = "Agent: review 已 stage" },
      { "<leader>AH", "<cmd>CodeDiff history<cr>", desc = "Agent: 提交历史" },
    },
    opts = {
      diff = {
        layout = "side_by_side",
        -- agent 的 diff 常常跨多个文件,让 ]c/[c 能一路翻过去
        cycle_hunks_across_files = true,
        jump_to_first_change = true,
      },
      explorer = {
        position = "left",
        width = 34,
        -- agent 新建的文件默认不在 git 里,不显示就等于漏 review
        untracked = true,
      },
    },
  },

  -- ── 发送层:把引用推给 herdr 里的 agent ─────────────────────
  -- 不装插件,直接挂键位。用 which-key 注册前缀说明。
  {
    "folke/which-key.nvim",
    opts = {
      spec = {
        { "<leader>A", group = "AI agent (herdr)" },
      },
    },
    keys = {
      -- 发引用:agent 拿到路径会自己读周围上下文,比粘代码更准更省 token
      {
        "<leader>Af",
        send(function()
          return herdr().ref_file()
        end),
        desc = "Agent: 发当前文件引用",
      },
      {
        "<leader>Al",
        send(function()
          return herdr().ref_line()
        end),
        desc = "Agent: 发当前行引用",
      },
      {
        "<leader>Av",
        send(function()
          return herdr().ref_selection()
        end),
        mode = "x",
        desc = "Agent: 发选区引用",
      },
      {
        "<leader>Ax",
        send(function()
          local d = herdr().ref_diagnostics()
          return d and ("修掉这些诊断:\n\n" .. d)
        end),
        desc = "Agent: 发当前文件诊断",
      },

      -- 问问题:引用 + 意图一起发,这是日常主力入口
      {
        "<leader>Aa",
        ask(function()
          return herdr().ref_file()
        end),
        desc = "Agent: 带文件引用提问",
      },
      {
        "<leader>Ac",
        ask(function()
          return herdr().ref_line()
        end),
        desc = "Agent: 带行号引用提问",
      },
      {
        "<leader>As",
        ask(function()
          return herdr().ref_selection()
        end),
        mode = "x",
        desc = "Agent: 带选区引用提问",
      },
      {
        "<leader>Ai",
        ask(nil),
        desc = "Agent: 纯提问(无引用)",
      },

      -- 发完直接切到 agent pane(想盯着它跑的时候用)
      {
        "<leader>AA",
        ask(function()
          return herdr().ref_file()
        end, { focus = true }),
        desc = "Agent: 提问并切过去",
      },

      -- ── 点名某个 agent ───────────────────────────────────
      -- 上面的键位会列出全部 agent 让你选;这组直接点名,不弹选择框。
      -- 那种 agent 没在跑时会问要不要新起一个 pane 启动它。
      -- 助记:1=claude 2=pi 3=codex(按你常用顺序排)
      {
        "<leader>A1",
        ask(function()
          return herdr().ref_file()
        end, { kind = "claude" }),
        desc = "Agent: 问 claude",
      },
      {
        "<leader>A2",
        ask(function()
          return herdr().ref_file()
        end, { kind = "pi" }),
        desc = "Agent: 问 pi",
      },
      {
        "<leader>A3",
        ask(function()
          return herdr().ref_file()
        end, { kind = "codex" }),
        desc = "Agent: 问 codex",
      },
      -- 选区版本:发 @文件:行范围 引用(不含代码正文)
      --
      -- 默认选引用而不是代码正文,因为大多数 code review 类问题(DRY、
      -- 命名、抽象是否合理)的答案在选区【之外】—— 重复的另一半可能在
      -- 同文件别处、兄弟 Controller、或 common 模块里已有的工具类。
      -- 只给一段选区,agent 只能答"这段内部有重复";给引用,它能读完
      -- 整个文件再按需搜别处。
      {
        "<leader>A1",
        ask(function()
          return herdr().ref_selection()
        end, { kind = "claude" }),
        mode = "x",
        desc = "Agent: 选区问 claude",
      },
      {
        "<leader>A2",
        ask(function()
          return herdr().ref_selection()
        end, { kind = "pi" }),
        mode = "x",
        desc = "Agent: 选区问 pi",
      },
      {
        "<leader>A3",
        ask(function()
          return herdr().ref_selection()
        end, { kind = "codex" }),
        mode = "x",
        desc = "Agent: 选区问 codex",
      },

      -- 选区正文版本:@引用 + 带行号的代码块一起发。
      --
      -- 什么时候用这个:
      --   · 文件太大,让 agent 整份读进去会吃掉上下文
      --   · 问题纯局部(这个循环能不能简化、这几行有没有 NPE 风险)
      --   · 代码还没存盘,agent 读文件会拿到旧内容
      {
        "<leader>Ay",
        send(function()
          return herdr().selection_text()
        end),
        mode = "x",
        desc = "Agent: 发选区代码正文",
      },
      {
        "<leader>AY",
        ask(function()
          return herdr().selection_text()
        end),
        mode = "x",
        desc = "Agent: 带选区代码正文提问",
      },

      -- 切到 agent pane / 列出 agent 状态
      {
        "<leader>Ag",
        function()
          herdr().pick(function(a)
            vim.system({ vim.env.HERDR_BIN_PATH or "herdr", "agent", "focus", a.pane_id }):wait()
          end)
        end,
        desc = "Agent: 切到 agent pane",
      },
      {
        "<leader>A?",
        function()
          local agents, err = herdr().agents()
          if not agents then
            return vim.notify("herdr agent list 失败: " .. tostring(err), vim.log.levels.WARN)
          end
          if #agents == 0 then
            return vim.notify("当前 workspace 没有其他 agent", vim.log.levels.INFO)
          end
          local lines = {}
          for _, a in ipairs(agents) do
            table.insert(
              lines,
              string.format(
                "%-8s %-8s %s",
                a.agent or "?",
                a.agent_status or "?",
                vim.fn.fnamemodify(a.cwd or "", ":~")
              )
            )
          end
          vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "herdr agents" })
        end,
        desc = "Agent: 列出 agent 状态",
      },
    },
  },
}
