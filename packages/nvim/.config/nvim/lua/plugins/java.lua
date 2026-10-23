-- Java：纯浏览模式，不启用 jdtls（LSP）
-- 设计目标：打开大型 Java 微服务仓库不卡、内存几十 MB 级别。
-- 语义精确跳转交给 IDEA（Power Save Mode）兜底；这里只做"读 + 跳 + 搜"。
--
-- 提供能力：
--   * treesitter 语法高亮（已在 treesitter.lua 里 ensure java）
--   * aerial 大纲：当前文件类/方法跳转（纯语法解析，不编译）
--   * gutentags + universal-ctags：跨文件 <C-]> 跳定义 / g<C-]> 选择引用
--   * snacks.picker：文件查找 / 全局 grep / ctags 符号查找（仅 java buffer 绑定）
return {
  -- 1) 彻底禁用 jdtls：既不让 lspconfig 起，也不安装 nvim-jdtls
  {
    "neovim/nvim-lspconfig",
    optional = true,
    opts = {
      servers = {
        jdtls = {
          autostart = false,
          mason = false,
        },
      },
      setup = {
        -- 拦截 jdtls 的 setup，直接吞掉，确保任何路径都不会拉起它
        jdtls = function()
          return true
        end,
      },
    },
  },

  -- 2) 不再安装 nvim-jdtls（用 enabled=false 显式关闭，保留配置痕迹便于以后想回切）
  {
    "mfussenegger/nvim-jdtls",
    enabled = false,
  },

  -- 3) 不让 mason 再拉 jdtls（节省磁盘和更新时间）
  {
    "mason-org/mason.nvim",
    optional = true,
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      opts.ensure_installed = vim.tbl_filter(function(v)
        return v ~= "jdtls"
      end, opts.ensure_installed)
    end,
  },

  -- 4) Java 专属浏览快捷键（只在 java buffer 上绑定，不影响 Go/Python）
  {
    "folke/snacks.nvim",
    optional = true,
    init = function()
      vim.api.nvim_create_autocmd("FileType", {
        pattern = "java",
        callback = function(ev)
          local Snacks = require("snacks")
          local map = function(lhs, fn, desc)
            vim.keymap.set("n", lhs, fn, { buffer = ev.buf, desc = desc, silent = true })
          end
          -- which-key buffer-local 分组标签:仅在 java buffer 生效。键都是
          -- buffer-local 的,所以标签也用 buffer 字段绑在本 buffer,不污染
          -- 其他文件类型(与 go.lua 的全局 spec 不同)。<leader>c 组由
          -- LazyVim 默认提供("code"),这里只补诊断两个键的说明。
          -- (Buffer-local which-key labels for java only; keys are buffer-local
          --  so labels bind to this buffer too, unlike go.lua's global spec.)
          local ok_wk, wk = pcall(require, "which-key")
          if ok_wk then
            wk.add({
              { "<leader>cp", desc = "Diagnostics: export classpath + import index", buffer = ev.buf, icon = { icon = "\u{f0877}", color = "yellow" } },
              { "<leader>cd", desc = "Diagnostics: run javac on this file", buffer = ev.buf, icon = { icon = "\u{f0877}", color = "red" } },
              { "<leader>cu", desc = "Java: remove unused imports", buffer = ev.buf, icon = { icon = "\u{f0219}", color = "green" } },
              { "<M-CR>", desc = "Java: code action (import / create method)", buffer = ev.buf, icon = { icon = "\u{f0335}", color = "cyan" } },
            })
          end
          -- 文件与文本搜索（项目根 = git/pom/gradle）
          map("<leader>ff", function()
            Snacks.picker.files()
          end, "Find Files")
          map("<leader>fg", function()
            Snacks.picker.grep()
          end, "Grep (live)")
          map("<leader>fw", function()
            Snacks.picker.grep_word()
          end, "Grep current word")
          -- ctags 符号查找（依赖 gutentags 生成的 tags）
          map("<leader>fs", function()
            Snacks.picker.tags()
          end, "Find Tags (ctags symbols)")
          -- 手动触发 ctags 扫描：仅 Maven 项目（向上能找到 pom.xml）才允许。
          -- 自动扫描已全局关闭（见 browse.lua），这是唯一的 ctags 生成入口。
          -- (Manually trigger a ctags scan; only allowed inside a Maven
          --  project. Auto-scan is globally disabled, this is the only entry.)
          map("<leader>gt", function()
            require("config.ctags_progress").scan(ev.buf)
          end, "ctags: scan project (Maven only)")
          -- 查询当前扫描进度：状态 + 临时文件实时大小（ctags 不报百分比，
          -- 临时文件大小是唯一的真实进度信号）。
          -- (Query scan progress: state + live temp-file size; ctags emits no
          --  percentage, the growing temp file is the only real signal.)
          map("<leader>gT", function()
            require("config.ctags_progress").status(ev.buf)
          end, "ctags: scan progress / status")
          -- 当前文件大纲（aerial）
          map("<leader>cs", "<cmd>AerialToggle<cr>", "Symbols Outline (aerial)")
          -- Jump: prefer qualified Java member tags, then fall back to native tags.
          -- (跳转：优先按 Java 代码里的限定前缀精确命中，再回退原生 tags。)
          map("<C-]>", function()
            require("config.java_fqn").jump_member(false)
          end, "Tag: jump to definition")
          map("g<C-]>", function()
            require("config.java_fqn").jump_member(true)
          end, "Tag: select definition")
          -- 查找引用：用 GNU Global 的 GTAGS 库做真·引用查询(global -r)，
          -- 只列出真实调用点，不像 grep 会混入注释/字符串/同名噪声。库由
          -- <leader>gt 与 ctags 一并重建，存缓存目录。详见 config/global_refs.lua。
          -- (Find references via GNU Global: global -r lists real call sites,
          --  not grep noise. The GTAGS db is built alongside ctags by <leader>gt.)
          map("gr", function()
            require("config.global_refs").references(ev.buf)
          end, "Tag: find references (global -r)")
          -- 悬浮签名:接管无用的 K(=:Man)，用 ctags 字段显示光标下符号的所有
          -- 定义签名 + 所在类 + 位置 + 定义处源码片段。详见 config/ctags_hover.lua。
          -- (Hover: replace the useless K=:Man with a ctags-backed signature
          --  popup — every definition's signature/scope/location + a snippet.)
          map("K", function()
            require("config.ctags_hover").hover()
          end, "Hover: signatures (ctags)")
          -- 复制全限定名:光标在类名 -> pkg.Type;在方法名 -> pkg.Type#method
          -- (IDEA Copy Reference 风格)。仅定义处生效。详见 config/java_copy_ref.lua。
          -- (Copy FQN: class -> pkg.Type, method -> pkg.Type#method. Def-site only.)
          map("<leader>cy", function()
            require("config.java_copy_ref").copy()
          end, "Copy fully-qualified name")
          -- 跳实现 / 跳父方法：ctags 没有 OOP 关系，靠 tags 里的 inherits +
          -- class/interface scope 字段在内存重建继承图来模拟，详见
          -- config/ctags_oop.lua。
          -- gI 三级分流(先判光标在【定义处】还是【调用点】,据行号比对):
          --   定义处(光标≈方法定义行): Dao/Mapper 接口方法 -> 跳 MyBatis XML;
          --                            否则 -> 跳实现(ctags_oop)。
          --   调用点(userService.foo()): 推断接收者类型 -> 跳实现体/XML,
          --                            推不出则按方法名 picker 回退(ctags_callsite)。
          -- (gI routes by whether the cursor is on a method DEFINITION or a CALL
          --  SITE: definitions use the existing mybatis->impl chain; call sites
          --  infer the receiver type then jump to the impl body / XML.)
          map("gI", function()
            if require("config.java_fqn").at_method_definition() then
              if not require("config.mybatis_jump").jump(ev.buf) then
                require("config.ctags_oop").implementations()
              end
            else
              require("config.ctags_callsite").goto_impl(ev.buf)
            end
          end, "gI: go to implementations (def-site & call-site)")
          map("gts", function()
            require("config.ctags_oop").super()
          end, "Tag: go to super method (parent type)")
          -- 诊断:导出 classpath(首次手动,mvn 异步)。顺带构建导包索引
          -- (扫依赖 jar+项目源码+JDK,缓存到磁盘),供 <M-CR> 自动导包用。
          -- (Export classpath via mvn, then build the auto-import class-name index.)
          map("<leader>cp", function()
            require("config.java_diag").build_classpath(ev.buf, function(ok)
              if ok then
                require("config.java_diag").diagnose(ev.buf)
                require("config.java_import").build_index(ev.buf)
              end
            end)
          end, "Diagnostics: export classpath + import index")
          -- 诊断:手动触发一次 javac 检查当前文件 (manual javac diagnose)
          map("<leader>cd", function()
            require("config.java_diag").diagnose(ev.buf)
          end, "Diagnostics: run javac on this file")
          -- code action (IDEA 风 Alt+Enter):光标行有 javac 诊断时,按
          -- symbol 类型提供快修——缺类->自动导包,缺方法->创建骨架。
          -- kitty 能可靠识别 <M-CR>。详见 config/java_import.lua。
          -- (Alt+Enter code action: import missing class / create missing method.)
          map("<M-CR>", function()
            require("config.java_import").code_action(ev.buf)
          end, "Java: code action (import / create method)")
          -- 独立命令:清理未使用 import(纯文本分析,javac 不报 unused import)。
          -- (Remove unused imports; text-based since javac never reports them.)
          map("<leader>cu", function()
            require("config.java_import").remove_unused_imports(ev.buf)
          end, "Java: remove unused imports")
          -- 保存时自动诊断:异步 javac,只渲染当前文件 error(无 classpath 缓存
          -- 时静默提示按 <leader>cp,不自动跑 mvn,贴合手动哲学)。
          -- (Auto-diagnose on save: async javac, current-file errors only.)
          vim.api.nvim_create_autocmd("BufWritePost", {
            buffer = ev.buf,
            callback = function()
              require("config.java_diag").diagnose(ev.buf)
            end,
          })
          -- 诊断显示:关掉行尾 virtual_text(挤右端看不全),改成光标停在错误
          -- 行时在屏幕中心弹浮框显示完整信息。仅 java buffer 生效。
          -- (Display: no end-of-line virtual_text; centered float on CursorHold.)
          require("config.java_diag").setup_display(ev.buf)
        end,
      })
    end,
  },

  -- 5) lualine 状态栏：ctags 扫描进行中显示 spinner，扫完自动消失。
  -- (Statusline indicator: shows a spinner while ctags is scanning.)
  {
    "nvim-lualine/lualine.nvim",
    optional = true,
    opts = function(_, opts)
      opts.sections = opts.sections or {}
      opts.sections.lualine_x = opts.sections.lualine_x or {}
      table.insert(opts.sections.lualine_x, 1, {
        function()
          return require("config.ctags_progress").lualine()
        end,
        color = { fg = "#d79921" }, -- gruvbox yellow，醒目但不刺眼
      })
    end,
  },

  -- 6) blink.cmp：给 java buffer 挂 ctags 补全源(跨文件类名/方法名补全)。
  -- 无 LSP 时 blink 默认只有 buffer 词补全，跨文件符号补不出来。这里复用
  -- blink 内置的 complete_func 源，把基于 taglist 的 completefunc 包成补全项，
  -- 签名显示在菜单里。仅 java：通过 per_filetype 挂载，Go/Python 仍走 LSP。
  -- (Add a ctags completion source for java buffers via blink's built-in
  --  complete_func source; signatures show in the menu. per_filetype keeps it
  --  java-only so Go/Python keep their LSP sources. 3-char gate in the module.)
  {
    "saghen/blink.cmp",
    optional = true,
    opts = {
      sources = {
        per_filetype = {
          java = { inherit_defaults = true, "ctags" },
        },
        providers = {
          ctags = {
            name = "ctags",
            module = "blink.cmp.sources.complete_func",
            min_keyword_length = 3,
            opts = {
              complete_func = function()
                return require("config.ctags_complete").complete_func()
              end,
            },
          },
        },
      },
    },
  },
}
