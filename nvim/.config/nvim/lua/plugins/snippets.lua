return {
  "L3MON4D3/LuaSnip",
  opts = function(_, opts)
    local ls = require("luasnip")
    local s = ls.snippet
    local t = ls.text_node
    local i = ls.insert_node
    local rep = require("luasnip.extras").rep

    -- 为 go 语言添加片段
    ls.add_snippets("go", {
      s("goc", {
        t("func New"), i(1, "Name"), t("("), i(2), t(") *"), rep(1), t({ " {", "\treturn &" }), rep(1), t("{"), i(0), t({
        "", "}" })
      }),
    })
  end,
}
