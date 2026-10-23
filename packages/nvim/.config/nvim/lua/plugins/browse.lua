-- 代码浏览栈：aerial（大纲）+ gutentags（自动 ctags 索引）
-- 服务于 java.lua 的"纯浏览模式"，但本身语言无关，Go/其他文本项目也能用。
return {
  -- 大纲：基于 treesitter，纯语法解析，不需要 LSP/编译
  {
    "stevearc/aerial.nvim",
    cmd = { "AerialToggle", "AerialOpen", "AerialNavToggle" },
    dependencies = {
      "nvim-treesitter/nvim-treesitter",
      "nvim-tree/nvim-web-devicons",
    },
    opts = {
      backends = { "treesitter", "markdown", "man" },
      layout = {
        max_width = { 45, 0.3 },
        min_width = 28,
        default_direction = "right",
      },
      attach_mode = "global",
      show_guides = true,
      filter_kind = {
        "Class",
        "Constructor",
        "Enum",
        "Function",
        "Interface",
        "Method",
        "Struct",
        "Field",
      },
      -- 用 treesitter 取符号，避免任何 LSP 依赖
      lazy_load = true,
    },
    keys = {
      { "<leader>cs", "<cmd>AerialToggle<cr>", desc = "Symbols Outline (aerial)" },
      { "{", "<cmd>AerialPrev<cr>", desc = "Prev symbol" },
      { "}", "<cmd>AerialNext<cr>", desc = "Next symbol" },
    },
  },

  -- gutentags：保存时自动增量更新 ctags，提供 <C-]> 跳定义
  {
    "ludovicchabant/vim-gutentags",
    event = { "BufReadPost", "BufNewFile" },
    init = function()
      -- 项目根标记：识别 Java/Go/通用仓库
      -- 注意：下面的自定义 finder 会优先用 git 根，这个列表只在 finder 的
      -- 回退分支用到（非 git 项目）。
      vim.g.gutentags_project_root = {
        "pom.xml",
        "build.gradle",
        "settings.gradle",
        "go.mod",
        ".git",
      }
      vim.g.gutentags_ctags_tagfile = ".tags" -- 避免与手动 tags 冲突
      vim.g.gutentags_modules = { "ctags" }

      -- 自定义项目根探测：多模块 Maven 仓库优先用 git 仓库根，避免只索引
      -- 单个子模块导致跨模块跳转 E426。详见 config/gutentags_root.lua。
      -- (Custom root finder: prefer git repo root so multi-module Maven repos
      --  get indexed as a whole; otherwise cross-module jumps fail with E426.)
      vim.cmd([[
        function! GutentagsFindRoot(path) abort
          return luaeval('require("config.gutentags_root").find(_A)', a:path)
        endfunction
      ]])
      vim.g.gutentags_project_root_finder = "GutentagsFindRoot"

      -- Never treat $HOME as a project root: home dir is a git repo (dotfiles),
      -- so any non-project file would make ctags index the entire home dir.
      -- (家目录本身是 dotfiles 的 git 仓库，若不排除，打开任意散文件都会让
      --  gutentags 把整个 $HOME 当项目根递归索引，吃满 CPU、生成数十 GB tags)
      vim.g.gutentags_exclude_project_root = {
        "/usr/local",
        "/opt/homebrew",
        "/home/linuxbrew/.linuxbrew",
        vim.fn.expand("~"),
      }

      -- tags 统一放到缓存目录，不污染项目目录
      local cache = vim.fn.stdpath("cache") .. "/tags"
      vim.fn.mkdir(cache, "p")
      vim.g.gutentags_cache_dir = cache

      -- universal-ctags 调优：只索引 Java/XML，带继承/访问信息。
      -- (Universal Ctags tuning: index only Java/XML with inheritance/signature fields.)
      vim.g.gutentags_ctags_extra_args = {
        "--tag-relative=yes",
        "--languages=Java,XML",
        "--fields=+ailmnS",
        "--extras=+q",
        "--java-kinds=+cefimp",
      }
      vim.g.gutentags_ctags_exclude = {
        "target",
        "build",
        ".git",
        ".idea",
        ".vscode",
        "node_modules",
        ".claude",
        ".claude-worktrees",
        ".superpowers",
        ".worktrees",
        "docs",
        "*.min.js",
        "*.class",
        "*.jar",
        "dist",
        "out",
        -- 非源码目录：文档/AI 缓存/计划，索引它们只会拖慢扫描、污染符号表。
        -- (Non-source dirs: docs / AI caches / plans — indexing them only
        --  slows scans and pollutes the symbol table.)
        "doc",
        "apifox-doc",
        "code_review_cache",
        "code_review_report",
        "plans",
      }

      -- Disable ALL automatic ctags scanning. Tags are generated only on
      -- demand via <leader>ct (Maven-only), defined in java.lua. Other
      -- languages rely on LSP and never need ctags.
      -- (彻底关闭自动扫描：仅在 Java Maven 项目里用 <leader>ct 手动触发，
      --  见 java.lua；其余语言走 LSP，不需要 ctags)
      -- 注意：gutentags_enabled 保持默认 1，这样 buffer 仍会 attach——
      -- tags 文件照常挂到 &tags、GutentagsUpdate 命令照常定义，
      -- 已生成的 tags 仍可用于 <C-]> 跳转与符号查找，只是不会自动重扫。
      vim.g.gutentags_generate_on_new = 0
      vim.g.gutentags_generate_on_missing = 0
      vim.g.gutentags_generate_on_write = 0
      vim.g.gutentags_generate_on_empty_buffer = 0
    end,
  },
}
