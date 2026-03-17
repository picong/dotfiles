-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

-- 禁用 Markdown 文件的拼写检查，避免中文显示红色下划线
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "markdown" },
  callback = function()
    vim.opt_local.spell = false
  end,
})

-- 新建 Go 文件时自动插入 package 声明
vim.api.nvim_create_autocmd({ "BufNewFile", "BufRead" }, {
  pattern = "*.go",
  callback = function()
    local line_count = vim.api.nvim_buf_line_count(0)
    local first_line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]

    if line_count == 1 and (first_line == nil or first_line == "") then
      local filename = vim.fn.expand("%:t")

      if filename == "main.go" then
        vim.api.nvim_buf_set_lines(0, 0, 0, false, {
          "package main",
          "",
          "func main() {",
          "\t",
          "}",
        })
        vim.api.nvim_win_set_cursor(0, { 4, 1 })
      else
        local package_name = vim.fn.expand("%:p:h:t")
        vim.api.nvim_buf_set_lines(0, 0, 0, false, { "package " .. package_name, "" })
      end
    end
  end,
})
