-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here
-- 自定义快捷键
vim.keymap.set('i', 'jj', '<Esc>', { desc = 'To normal mode' })
vim.keymap.set('n', '<leader>a', ':BlameToggle<CR>', { desc = 'Toggle git blame' })

if vim.g.vscode then
  vim.api.nvim_set_keymap(
    "n",
    "<leader>e",
    ':lua require("vscode").action("workbench.action.toggleSidebarVisibility")<CR>',
    { noremap = true, silent = true }
  )

  vim.api.nvim_set_keymap(
    "n",
    "<leader>gs",
    '<Cmd>lua require("vscode").action("editor.action.formatSelection")<CR>',
    { noremap = true, silent = true }
  )

  vim.api.nvim_set_keymap(
    "n",
    "<Leader>gb",
    '<Cmd>lua require("vscode").action("gitlens.toggleFileBlame")<CR>',
    { noremap = true, silent = true }
  )
end
