-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- 剪贴板配置 (WSL2 专用)
vim.opt.clipboard = "unnamedplus"

-- 在 WSL2 中使用 xclip 而不是 wl-clipboard
if vim.fn.has("wsl") == 1 then
  vim.g.clipboard = {
    name = "WslClipboard",
    copy = {
      ["+"] = "xclip -selection clipboard",
      ["*"] = "xclip -selection clipboard",
    },
    paste = {
      ["+"] = "xclip -selection clipboard -o",
      ["*"] = "xclip -selection clipboard -o",
    },
    cache_enabled = 0,
  }
end

-- neovide 配置
if vim.g.neovide then
  vim.o.guifont = "Maple Mono NF CN:h10"
  vim.g.neovide_opacity = 1
  vim.g.transparency = 0.8
  vim.g.neovide_cursor_vfx_mode = "railgun"
end

