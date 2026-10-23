return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      vim.list_extend(opts.ensure_installed, {
        "java",
        "gomod",
        "gowork",
      })
      opts.highlight = {
        enable = true,
        additional_vim_regex_highlighting = false,
      }
    end,
  },
}