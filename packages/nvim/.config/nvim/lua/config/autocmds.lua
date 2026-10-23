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

-- Python 文件保存后自动格式化 + 整理导入
vim.api.nvim_create_autocmd("BufWritePost", {
  pattern = "*.py",
  callback = function()
    vim.lsp.buf.format({ async = false })
    vim.lsp.buf.code_action({
      apply = true,
      context = {
        only = { "source.organizeImports" },
        diagnostics = {},
      },
    })
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

-- User command for Maven dependency resolve (手动执行 Maven 依赖下载)
-- Usage: :MavenDeps or :MvnDeps
vim.api.nvim_create_user_command("MavenDeps", function()
  local cwd = vim.fn.getcwd()
  local pom_path = cwd .. "/pom.xml"
  local mvnw_path = cwd .. "/mvnw"

  if vim.fn.filereadable(pom_path) == 1 then
    local cmd = vim.fn.filereadable(mvnw_path) == 1 and "./mvnw" or "mvn"
    vim.notify("Downloading Maven dependencies...", vim.log.levels.INFO)
    vim.fn.jobstart(cmd .. " dependency:resolve -DskipTests", {
      cwd = cwd,
      on_exit = function(_, exit_code)
        if exit_code == 0 then
          vim.notify("Maven dependencies resolved", vim.log.levels.INFO)
        else
          vim.notify("Maven dependency resolution failed", vim.log.levels.WARN)
        end
      end,
    })
  else
    vim.notify("No pom.xml found in current directory", vim.log.levels.WARN)
  end
end, { desc = "Download Maven dependencies" })

-- Alias command
vim.api.nvim_create_user_command("MvnDeps", function()
  vim.cmd("MavenDeps")
end, { desc = "Download Maven dependencies (alias)" })

-- 注意:原来这里有一个 BufWritePost *.java 钩子,保存时调用 JdtOrganizeImports。
-- 但 jdtls 已在 plugins/java.lua 里彻底禁用,该命令不存在,导致每次保存 java
-- 文件都抛 E492 并【中断整条 BufWritePost 事件链】——其后的 javac 诊断
-- autocmd 因此从未执行。这正是"看不到报错提醒"的根因,故移除。
-- (Removed a BufWritePost *.java hook that ran :JdtOrganizeImports. jdtls is
--  fully disabled, so the command is missing; it threw E492 on every save and
--  aborted the whole BufWritePost chain, preventing the javac diagnostics
--  autocmd from ever running.)

-- 三方合并键位（仅在 git mergetool 调起 nvim 时生效）
require("config.mergetool")

-- ── agent 改文件后自动重载 buffer ────────────────────────────────
-- AI agent 跑在 herdr 的另一个 pane 里直接写磁盘,nvim 默认不知道。
-- 不重载的后果是:你以为在 review agent 的改动,其实看的是旧内容,
-- 而且一旦手动保存就把 agent 的工作覆盖掉。这是本套配置的前提条件。
--
-- autoread 本身只在某些事件上才检查,所以要显式 checktime。
-- nvim 0.13 内置了 file watcher,到时这段可以简化,但 0.12 仍需手动触发。
vim.opt.autoread = true

local reload = vim.api.nvim_create_augroup("agent_autoreload", { clear = true })

vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "CursorHoldI", "TermLeave" }, {
  group = reload,
  callback = function()
    -- 命令行窗口里 checktime 会报错;终端 buffer 无文件可查
    if vim.fn.getcmdwintype() ~= "" or vim.bo.buftype ~= "" then
      return
    end
    vim.cmd("checktime")
  end,
  desc = "检查文件是否被外部(AI agent)修改",
})

-- 文件确实被外部改了才提示。默认 nvim 什么都不说,你不会注意到 buffer 换了内容。
vim.api.nvim_create_autocmd("FileChangedShellPost", {
  group = reload,
  callback = function()
    vim.notify("文件已被外部修改,buffer 已重载", vim.log.levels.WARN, { title = "autoread" })
  end,
})