-- Register Go productivity keymaps and user commands for every Go buffer.
-- (为每个 Go 缓冲区注册增强快捷键和用户命令)
local function setup_go_tools()
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "go",
    group = vim.api.nvim_create_augroup("user_go_tools", { clear = true }),
    callback = function(ev)
      local go = require("util.go-tools")
      local function map(lhs, fn, desc)
        vim.keymap.set("n", lhs, fn, { buffer = ev.buf, desc = desc })
      end

      -- Interface & struct helpers under the <leader>cg (Go) prefix to avoid
      -- clashing with LazyVim's built-in <leader>c* LSP keymaps.
      -- (Go 专属命令放在 <leader>cg 前缀下，避免与 LazyVim 自带的 <leader>c* 冲突)
      map("<leader>cgi", go.implement_interface, "Implement interface (impl)")
      map("<leader>cgs", go.fill_struct, "Fill struct (gopls)")
      map("<leader>cgt", go.add_tags, "Add struct tags")
      map("<leader>cgT", go.remove_tags, "Remove struct tags")
      map("<leader>cge", go.extract, "Extract function/variable")

      -- Visual-mode extract for selected expressions/statements.
      -- (可视模式下提取选中的表达式/语句)
      vim.keymap.set("x", "<leader>cge", go.extract, { buffer = ev.buf, desc = "Extract function/variable" })
    end,
  })

  -- Plain user commands as an alternative to the keymaps.
  -- (提供与快捷键等价的用户命令)
  local function cmd(name, method, desc)
    vim.api.nvim_create_user_command(name, function()
      require("util.go-tools")[method]()
    end, { desc = desc })
  end
  cmd("GoImpl", "implement_interface", "Implement interface for struct under cursor")
  cmd("GoFillStruct", "fill_struct", "Fill struct under cursor")
  cmd("GoAddTags", "add_tags", "Add tags to struct under cursor")
  cmd("GoRemoveTags", "remove_tags", "Remove tags from struct under cursor")
end

setup_go_tools()

return {

  -- which-key group label for the Go helper prefix.
  -- (为 Go 辅助命令前缀添加 which-key 分组标签)
  {
    "folke/which-key.nvim",
    optional = true,
    opts = {
      spec = {
        { "<leader>cg", group = "go", icon = { icon = "\u{f07d3}", color = "cyan" } },
      },
    },
  },

  -- add language parsers to treesitter
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      vim.list_extend(opts.ensure_installed, {
        "go",
        "gomod",
        "gowork",
      })
    end,
  },

  -- cmdline tools for LSP servers, DAP servers, formatters and linters
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      vim.list_extend(opts.ensure_installed, {
        "gopls",
        "goimports",
        "gofumpt",
        "delve",
        "gomodifytags",
        "impl",
        "iferr",
      })
    end,
  },

  -- setup lspconfig servers
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        gopls = {
          gofumpt = true,
          codelenses = {
            gc_details = false,
            generate = true,
            regenerate_cgo = true,
            run_govulncheck = true,
            test = true,
            tidy = true,
            upgrade_dependency = true,
            vendor = true,
          },
          hints = {
            assignVariableTypes = true,
            compositeLiteralFields = true,
            compositeLiteralTypes = true,
            constantValues = true,
            functionTypeParameters = true,
            parameterNames = true,
            rangeVariableTypes = true,
          },
          analyses = {
            fieldalignment = true,
            nilness = true,
            unusedparams = true,
            unusedwrite = true,
            useany = true,
          },
        },
      },
    },
  },

  -- Run the expensive Go linter only after saving, not on InsertLeave/BufReadPost.
  -- (仅在保存后运行高开销的 Go linter，避免退出插入模式或打开文件时卡顿。)
  {
    "mfussenegger/nvim-lint",
    optional = true,
    opts = function(_, opts)
      opts.linters_by_ft.go = nil

      vim.api.nvim_create_autocmd("BufWritePost", {
        pattern = "*.go",
        group = vim.api.nvim_create_augroup("user_go_lint_on_save", { clear = true }),
        callback = function()
          require("lint").try_lint("golangcilint")
        end,
        desc = "Lint Go files after saving",
      })
    end,
  },

  -- setup neotest adapter
  -- LazyVim 的 go extra 已改用维护更活跃的 neotest-golang（旧 neotest-go 已归档）。
  -- 这里只覆盖 adapter 配置，避免同时注册两个 Go adapter 造成测试重复发现。
  -- (LazyVim's go extra now ships neotest-golang; the archived neotest-go is
  --  dropped so only one Go adapter is registered.)
  {
    "nvim-neotest/neotest",
    optional = true,
    dependencies = {
      "fredrikaverpil/neotest-golang",
    },
    opts = {
      adapters = {
        ["neotest-golang"] = {
          -- -v 必须保留：没有它 go test 只在失败时输出，通过的测试连
          -- t.Log 都看不到，<leader>to 也就只剩一个状态标记。
          -- (-v is required; without it go test stays silent on success, so the
          --  output panel shows nothing but the pass/fail sign.)
          go_test_args = { "-v", "-count=1", "-timeout=60s", "-race", "-cover" },
          -- 该项目位于不可用的 VCS 工作区下时，Go 会让 `go list` 因版本戳
          -- 采集失败；适配器随后无法把错误输出映射回测试，最终只弹空框。
          -- (Disable VCS stamping for discovery so adapter errors remain mapped
          --  to their tests and Neotest can display the actual failure output.)
          go_list_args = { "-buildvcs=false" },
        },
      },
    },
  },
}
