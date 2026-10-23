return {
  -- Use catppuccin as the default colorscheme(将 catppuccin 设为默认主题)
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "catppuccin",
    },
  },
  -- Flavour selection; other options: latte / frappe / macchiato(主题色调，其余可选值见此注释)
  {
    "catppuccin/nvim",
    name = "catppuccin",
    opts = {
      flavour = "mocha",
    },
  },
}
