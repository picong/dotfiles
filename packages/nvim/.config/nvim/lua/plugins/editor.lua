return {
  {
    "windwp/nvim-autopairs",
    opts = {
      -- 禁用在快速连续输入时的某些行为
      fast_wrap = {},
      disable_filetype = { "TelescopePrompt", "vim" },
    },
    config = function(_, opts)
      local autopairs = require("nvim-autopairs")
      autopairs.setup(opts)

      -- 针对 Python 引号的特殊处理
      local Rule = require("nvim-autopairs.rule")
      local cond = require("nvim-autopairs.conds")

      autopairs.add_rules({
        -- 当已经有三个引号时，不再自动补全第四个
        Rule('"""', '"""', "python"):with_pair(cond.not_after_text('"""')),
        Rule("'''", "'''", "python"):with_pair(cond.not_after_text("'''")),
      })
    end,
  },
}
