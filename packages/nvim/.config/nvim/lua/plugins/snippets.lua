return {
  -- 让 blink.cmp 使用 LuaSnip 作为 snippet 引擎
  -- (make blink.cmp use LuaSnip as the snippet engine)
  {
    "saghen/blink.cmp",
    dependencies = { "L3MON4D3/LuaSnip" },
    opts = {
      snippets = {
        preset = "luasnip",
      },
    },
  },

  -- 注册自定义 LuaSnip 片段
  -- (register custom LuaSnip snippets)
  {
    "L3MON4D3/LuaSnip",
    opts = function(_, opts)
      local ls = require("luasnip")
      local s = ls.snippet
      local t = ls.text_node
      local i = ls.insert_node
      local rep = require("luasnip.extras").rep

      -- 为 go 语言添加片段 (add snippets for go)
      ls.add_snippets("go", {
        s("goc", {
          t("func New"), i(1, "Name"), t("("), i(2), t(") *"), rep(1), t({ " {", "\treturn &" }), rep(1), t("{"), i(0), t({
          "", "}" })
        }),
      })
    end,
  },
}
