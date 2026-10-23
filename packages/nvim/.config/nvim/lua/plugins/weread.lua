-- weread.nvim —— 在 Neovim 里读微信读书
-- 本地开发仓：~/projects/weread.nvim
-- 需要 snacks.nvim 的 image 模块来内联渲染插图（已在 core.lua 中开启）。
return {
  {
    dir = vim.fn.expand("~/projects/weread.nvim"),
    name = "weread.nvim",
    dependencies = { "folke/snacks.nvim" },
    -- 启动即加载：health 模块只在插件进入 runtimepath 后才找得到，而
    -- :checkhealth weread 是文档给出的首选自检入口，不能等懒加载。命令在
    -- plugin/weread.lua 里注册，插件 setup 只加载几个小模块，代价可忽略。
    -- （已开：全部 14 个 :WeRead* 命令启动后即可用，无需先触发加载）
    lazy = false,
    -- 全局快捷键：书架选择器。用 <leader>wb（b = bookshelf），而不是 <leader>ws：
    -- <leader>wd / <leader>wm 被 LazyVim 的窗口组占着，而章节 buffer 内插件自己占了
    -- t/o/a/s/r/h/d/c —— b 两处都是空的，因此在章节里和在编辑器里行为一致。
    keys = {
      { "<leader>wb", "<cmd>WeRead<cr>", desc = "微信读书：书架" },
    },
    ---@type weread.Config
    opts = {
      -- 排版：段间不留空行 + 首行缩进两格（中文书的排法）；章节标题交给 winbar 显示
      paragraph = {
        compact = true,
        indent = "　　",
        gap = "compact", -- "none" 会连标题/插图周围的空行也去掉
        chapter_title = false, -- true 则正文里也重复一次章节标题
      },
      -- 阅读配色，只作用于章节窗口（paper / sepia / light / night / none）
      -- none：沿用编辑器配色方案
      theme = "none",
      -- 阅读字体：终端字体由终端掌管，用 :WeReadFont 选（会生成 kitty 片段）
      font = nil,
      -- 不画 colorcolumn 竖线（默认 0 就是关闭；设成 >0 会在正文里插一条竖线）
      text_width = 0,
      -- 不高亮整个光标行：压在折行的中文段落上很重
      cursorline = false,
      -- 每 N 秒把阅读进度与时长回传微信读书，0 表示关闭
      sync_interval = 60,
      -- 插图内联渲染的上限（终端单元格）；高度克制一点，免得把正文挤下去
      image = { max_width = 60, max_height = 14 },
      -- 某些代理会把国内流量绕到境外，可按需改成 "direct"
      proxy = nil,
    },
    config = function(_, opts)
      require("weread").setup(opts)
    end,
  },
}
