return {
  {
    "gbprod/substitute.nvim",
    vscode = true,
    opts = {},
    config = function()
      require("substitute").setup({})
      -- Keymaps must live outside setup()'s option table; previously they were
      -- nested inside it and only worked as a side effect of building the table.
      -- (快捷键应放在 setup() 配置表之外；之前嵌在表里只是靠构造参数表的副作用才生效)
      vim.keymap.set("n", "gs", require("substitute").operator, { desc = "substitute operation", noremap = true })
      vim.keymap.set("n", "gss", require("substitute").line, { desc = "substitute line", noremap = true })
      vim.keymap.set("n", "gS", require("substitute").eol, { desc = "substitute eol", noremap = true })
      vim.keymap.set("x", "gs", require("substitute").visual, { desc = "substitute visual", noremap = true })
    end,
  },
  {
    "folke/snacks.nvim",
    priority = 1000,
    lazy = false,
    ---@type snacks.Config
    opts = {
      -- 开启 image 模块：weread.nvim 用它内联渲染书籍插图（kitty/ghostty 图形协议）
      image = {
        enabled = true,
        -- kitty 在 tmux 里时 snacks 的探测不会把终端标成「支持图形」，于是插图什么都不画。
        -- 实际是支持的（它自己会打开 allow-passthrough），这一行是明确告诉它。
        -- (kitty under tmux: snacks' detection does not mark the terminal as
        -- graphics-capable, so illustrations are never drawn. They do work.)
        force = true,
        doc = {
          -- 关闭 snacks 自带的 markdown 文档内联渲染：本机 markdown 的
          -- inline 注入没被解析，它本来就找不到图片；weread 章节的插图由
          -- 插件自己驱动 snacks 的 placement API 渲染（见 weread.image）。
          inline = false,
          float = true,
          -- 书籍插图偏窄，限制尺寸免得一页只放得下一张图
          max_width = 60,
          max_height = 20,
          -- 只对数学公式做 conceal；插图保持可见
          conceal = function(_, kind)
            return kind == "math"
          end,
        },
      },
      scroll = {
        enabled = false,
      },
    },
  },
  {
    'FabijanZulj/blame.nvim',
    lazy = false,
    config = function()
      require('blame').setup {}
    end,
    opts = {
      blame_options = { '-w' },
    },
  },
}
