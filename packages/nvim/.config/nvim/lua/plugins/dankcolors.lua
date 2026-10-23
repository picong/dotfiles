if true then
  return {}
end
return {
  {
    "RRethy/base16-nvim",
    priority = 1000,
    config = function()
      require("base16-colorscheme").setup({
        base00 = "#15130b",
        base01 = "#15130b",
        base02 = "#8f8c84",
        base03 = "#8f8c84",
        base04 = "#e7e4d9",
        base05 = "#fffdf8",
        base06 = "#fffdf8",
        base07 = "#fffdf8",
        base08 = "#ffa89f",
        base09 = "#ffa89f",
        base0A = "#f2dd8b",
        base0B = "#b2ffa5",
        base0C = "#fff3c5",
        base0D = "#f2dd8b",
        base0E = "#ffeda5",
        base0F = "#ffeda5",
      })

      vim.api.nvim_set_hl(0, "Visual", {
        bg = "#8f8c84",
        fg = "#fffdf8",
        bold = true,
      })
      vim.api.nvim_set_hl(0, "Statusline", {
        bg = "#f2dd8b",
        fg = "#15130b",
      })
      vim.api.nvim_set_hl(0, "LineNr", { fg = "#8f8c84" })
      vim.api.nvim_set_hl(0, "CursorLineNr", { fg = "#fff3c5", bold = true })

      vim.api.nvim_set_hl(0, "Statement", {
        fg = "#ffeda5",
        bold = true,
      })
      vim.api.nvim_set_hl(0, "Keyword", { link = "Statement" })
      vim.api.nvim_set_hl(0, "Repeat", { link = "Statement" })
      vim.api.nvim_set_hl(0, "Conditional", { link = "Statement" })

      vim.api.nvim_set_hl(0, "Function", {
        fg = "#f2dd8b",
        bold = true,
      })
      vim.api.nvim_set_hl(0, "Macro", {
        fg = "#f2dd8b",
        italic = true,
      })
      vim.api.nvim_set_hl(0, "@function.macro", { link = "Macro" })

      vim.api.nvim_set_hl(0, "Type", {
        fg = "#fff3c5",
        bold = true,
        italic = true,
      })
      vim.api.nvim_set_hl(0, "Structure", { link = "Type" })

      vim.api.nvim_set_hl(0, "String", {
        fg = "#b2ffa5",
        italic = true,
      })

      vim.api.nvim_set_hl(0, "Operator", { fg = "#e7e4d9" })
      vim.api.nvim_set_hl(0, "Delimiter", { fg = "#e7e4d9" })
      vim.api.nvim_set_hl(0, "@punctuation.bracket", { link = "Delimiter" })
      vim.api.nvim_set_hl(0, "@punctuation.delimiter", { link = "Delimiter" })

      vim.api.nvim_set_hl(0, "Comment", {
        fg = "#8f8c84",
        italic = true,
      })

      local current_file_path = vim.fn.stdpath("config") .. "/lua/plugins/dankcolors.lua"
      if not _G._matugen_theme_watcher then
        local uv = vim.uv or vim.loop
        _G._matugen_theme_watcher = uv.new_fs_event()
        _G._matugen_theme_watcher:start(
          current_file_path,
          {},
          vim.schedule_wrap(function()
            local new_spec = dofile(current_file_path)
            if new_spec and new_spec[1] and new_spec[1].config then
              new_spec[1].config()
              print("Theme reload")
            end
          end)
        )
      end
    end,
  },
}
