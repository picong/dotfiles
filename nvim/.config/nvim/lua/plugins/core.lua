return {
  {
    "gbprod/substitute.nvim",
    vscode = true,
    opts = {},
    config = function()
      require("substitute").setup({
        vim.keymap.set("n", "gs", require("substitute").operator, { desc = "substitute operation", noremap = true }),
        vim.keymap.set("n", "gss", require("substitute").line, { desc = "substitute line", noremap = true }),
        vim.keymap.set("n", "gS", require("substitute").eol, { desc = "substitute eol", noremap = true }),
        vim.keymap.set("x", "gs", require("substitute").visual, { desc = "substitute visual", noremap = true }),
      })
    end,
  },
  {
    "folke/snacks.nvim",
    priority = 1000,
    lazy = false,
    ---@type snacks.Config
    opts = {
      image = {
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
