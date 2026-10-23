-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here
-- 自定义快捷键
vim.keymap.set('i', 'jj', '<Esc>', { desc = 'To normal mode' })
vim.keymap.set('n', '<leader>a', ':BlameToggle<CR>', { desc = 'Toggle git blame' })

-- Python add missing import (leader ci)
vim.api.nvim_create_autocmd("FileType", {
  pattern = "python",
  callback = function()
    vim.keymap.set("n", "<leader>ci", function()
      vim.lsp.buf.code_action({
        apply = true,
        context = {
          only = { "source.addMissingImports", "quickfix" },
          diagnostics = vim.diagnostic.get(0),
        },
      })
    end, { desc = "Add missing import", buffer = true })
  end,
})

-- Java organize imports 依赖 jdtls，但本配置已在 plugins/java.lua 里彻底禁用
-- jdtls（纯浏览模式），:JdtOrganizeImports 根本不存在。原来的 <leader>co
-- 绑定是个会报错的死键，故移除。组织 import 如今需要交给 IDEA 或外部工具。
-- (The Java organize-imports map called :JdtOrganizeImports, which no longer
--  exists because jdtls is fully disabled in plugins/java.lua. Removed the
--  dead, error-raising binding.)

-- 在 Obsidian 中打开当前 Markdown 文件(实现见 config/obsidian_open.lua)。
-- 键位挂在 FileType 上而非全局:Obsidian 只认笔记,在 java/go buffer 上给个
-- 能按但必然失败的键没有意义。
-- (Open the current Markdown file in Obsidian. Bound per-filetype rather than
--  globally — the mapping is meaningless outside notes.)
vim.api.nvim_create_user_command("Obsidian", function()
  require("config.obsidian_open").open()
end, { desc = "在 Obsidian 中打开当前文件 (Open current file in Obsidian)" })

vim.api.nvim_create_user_command("ObsidianInfo", function()
  require("config.obsidian_open").info()
end, { desc = "Obsidian 预览库状态 (Shadow vault diagnostics)" })

local function map_obsidian(bufnr)
  vim.keymap.set("n", "<leader>mo", function()
    require("config.obsidian_open").open(bufnr)
  end, { buffer = bufnr, desc = "在 Obsidian 中打开 (Open in Obsidian)" })
end

vim.api.nvim_create_autocmd("FileType", {
  pattern = { "markdown", "markdown.mdx" },
  callback = function(ev)
    map_obsidian(ev.buf)
  end,
})

-- 本文件由 LazyVim 在 VeryLazy 时才加载,而 `nvim note.md` 这种启动方式的
-- FileType 事件在 VeryLazy【之前】就烧掉了 —— 上面那个 autocmd 接不到首个
-- buffer。所以注册完再补扫一遍已经打开的 markdown buffer。
-- (This file is loaded on VeryLazy, but `nvim note.md` fires FileType before
--  that, so the autocmd above misses the very first buffer. Sweep the already
--  open markdown buffers once after registering.)
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "markdown" then
    map_obsidian(buf)
  end
end

-- VSCode keymaps are now in init.lua (VSCode 快捷键已移至 init.lua)
