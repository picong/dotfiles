return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        gopls = {
          settings = {
            gopls = {
              analyses = {
                unusedparams = true,
              },
              staticcheck = true,
            },
          },
        },
        pyright = {
          enabled = true,
          settings = {
            python = {
              analysis = {
                autoImportCompletions = true, -- Auto import in completion list(补全列表中显示导入建议)
                typeCheckingMode = "standard", -- Report undefined names for import code actions(报告未定义名称以触发导入code action)
                autoSearchPaths = true, -- Auto search paths(自动搜索路径)
                useLibraryCodeForTypes = true, -- Use library code for types(使用库代码推断类型)
                diagnosticMode = "openFilesOnly", -- Only check open files to avoid performance issues(仅检查打开的文件)
              },
            },
          },
        },
        ruff = {
          keys = {
            ["<leader>co"] = {
              function()
                vim.lsp.buf.code_action({
                  apply = true,
                  context = {
                    only = { "source.organizeImports" },
                    diagnostics = {},
                  },
                })
              end,
              desc = "Organize imports (Ruff)",
            },
          },
        },
        ruff_lsp = { enabled = false },
      },
      setup = {
        ruff = function()
          require("snacks").util.lsp.on({ name = "ruff" }, function(_, client)
            client.server_capabilities.hoverProvider = false
          end)
        end,
      },
    },
  },
  {
    "stevearc/conform.nvim",
    optional = true,
    opts = {
      formatters_by_ft = {
        python = { "ruff_format" },
      },
    },
  },
}
