if vim.g.vscode then
  -- VSCode Neovim: only load basic options and keymaps, skip LazyVim and plugins
  -- (VSCode Neovim: 仅加载基础配置和快捷键，跳过 LazyVim 和插件)
  vim.g.mapleader = " "
  vim.g.maplocalleader = " "
  vim.opt.clipboard = "unnamedplus"
  vim.opt.timeoutlen = 500

  -- Disable search message output (禁用搜索消息输出)
  vim.opt.shortmess:append("S")  -- 禁用搜索计数(Disable search count)
  vim.opt.shortmess:append("s")  -- 禁用 "search hit BOTTOM" 消息(Disable search wrap messages)
  vim.opt.report = 9999  -- 禁用操作报告消息(Disable operation report messages)
  vim.opt.cmdheight = 999  -- 设置超大 cmdheight 防止 Output 面板弹出(Set large cmdheight to prevent output panel)

  local vscode = require("vscode")

  -- Helper to call VSCode commands (辅助函数：调用 VSCode 命令)
  local function action(cmd)
    return function()
      vscode.action(cmd)
    end
  end

  -- ===== Insert mode (插入模式) =====
  vim.keymap.set("i", "jj", "<Esc>", { desc = "To normal mode" })

  -- ===== Normal mode (普通模式) =====
  -- Redo (重做)
  vim.keymap.set("n", "U", "<C-r>", { desc = "Redo" })

  -- Debug (调试)
  vim.keymap.set("n", "<leader>d", action("workbench.action.debug.start"), { desc = "Start debug" })
  vim.keymap.set("n", "<leader>c", action("workbench.action.debug.stop"), { desc = "Stop debug" })
  vim.keymap.set("n", "<leader>bb", action("editor.debug.action.toggleBreakpoint"), { desc = "Toggle breakpoint" })

  -- Method navigation via Document Symbol API (通过文档符号API实现方法跳转)
  local method_nav_js = [[
    (async () => {
      const forward = args[0];
      const e = vscode.window.activeTextEditor;
      if (!e) return;
      const syms = await vscode.commands.executeCommand(
        'vscode.executeDocumentSymbolProvider', e.document.uri
      );
      if (!syms) return;
      const lines = [];
      const collect = (ss) => {
        for (const s of ss) {
          if ([5, 8, 11].includes(s.kind)) lines.push(s.range.start.line);
          if (s.children) collect(s.children);
        }
      };
      collect(syms);
      lines.sort((a, b) => a - b);
      const cur = e.selection.active.line;
      const t = forward
        ? lines.find(l => l > cur)
        : [...lines].reverse().find(l => l < cur);
      if (t !== undefined) {
        const p = new vscode.Position(t, 0);
        e.selection = new vscode.Selection(p, p);
        e.revealRange(new vscode.Range(p, p), 1);
      }
    })()
  ]]
  vim.keymap.set("n", "]]", function()
    vscode.eval(method_nav_js, { args = { true } })
  end, { desc = "Next method" })
  vim.keymap.set("n", "[[", function()
    vscode.eval(method_nav_js, { args = { false } })
  end, { desc = "Previous method" })

  -- Navigation (导航)
  vim.keymap.set("n", "gn", action("workbench.action.gotoSymbol"), { desc = "Go to symbol" })
  vim.keymap.set("n", "gf", action("workbench.action.findInFiles"), { desc = "Find in files" })
  vim.keymap.set("n", "gtd", action("editor.action.goToDeclaration"), { desc = "Go to declaration" })
  vim.keymap.set("n", "gti", action("editor.action.goToImplementation"), { desc = "Go to implementation" })
  vim.keymap.set("n", "gts", action("java.action.navigateToSuperImplementation"), { desc = "Go to super implementation" })
  vim.keymap.set("n", "gtf", action("workbench.action.quickOpen"), { desc = "Quick open" })

  -- Find and references (查找和引用)
  vim.keymap.set("n", "<leader>ss", action("references-view.findReferences"), { desc = "Find references view" })
  vim.keymap.set("n", "<leader>u", action("editor.action.findReferences"), { desc = "Find references" })
  vim.keymap.set("n", "<leader>h", action("editor.action.highlightReferences"), { desc = "Highlight references" })

  -- Code actions (代码操作)
  vim.keymap.set("n", "grn", action("editor.action.rename"), { desc = "Rename" })
  vim.keymap.set("n", "gi", action("editor.action.quickFix"), { desc = "Quick fix" })
  vim.keymap.set("n", "<leader>gg", action("editor.action.sourceAction"), { desc = "Source action" })
  vim.keymap.set("n", "gp", action("editor.action.triggerParameterHints"), { desc = "Parameter hints" })
  vim.keymap.set("n", "<leader>l", action("editor.action.formatSelection"), { desc = "Format selection" })

  -- Documentation and help (文档和帮助)
  vim.keymap.set("n", "gl", action("editor.action.showHover"), { desc = "Show hover" })
  vim.keymap.set("n", "gL", action("editor.action.peekDefinition"), { desc = "Peek definition" })

  -- Error navigation (错误导航)
  vim.keymap.set("n", "<leader>j", action("editor.action.marker.next"), { desc = "Next error" })
  vim.keymap.set("n", "<leader>k", action("editor.action.marker.prev"), { desc = "Previous error" })

  -- Git/VCS
  vim.keymap.set("n", "]c", action("editor.action.dirtydiff.next"), { desc = "Next change" })
  vim.keymap.set("n", "[c", action("editor.action.dirtydiff.previous"), { desc = "Previous change" })
  vim.keymap.set("n", "<leader>a", action("gitlens.toggleFileBlame"), { desc = "Toggle git blame" })

  -- Hierarchy (层级结构)
  vim.keymap.set("n", "ghc", action("editor.showCallHierarchy"), { desc = "Call hierarchy" })
  vim.keymap.set("n", "ght", action("editor.showTypeHierarchy"), { desc = "Type hierarchy" })

  -- File and window (文件和窗口)
  vim.keymap.set("n", "gw", action("workbench.action.showAllEditors"), { desc = "Show all open files" })
  vim.keymap.set("n", "gx", action("workbench.action.closeOtherEditors"), { desc = "Close other editors" })
  vim.keymap.set("n", "<leader>e", action("workbench.action.toggleSidebarVisibility"), { desc = "Toggle sidebar" })
  vim.keymap.set("n", "<leader>x", action("workbench.action.closeSidebar"), { desc = "Close sidebar" })
  vim.keymap.set("n", "<leader>o", action("workbench.action.copyFilePath"), { desc = "Copy file path" })
  vim.keymap.set("n", "<leader>sp", action("workbench.action.gotoSymbol"), { desc = "Go to symbol" })
  vim.keymap.set("n", "<leader>n", action("workbench.action.quickOpen"), { desc = "Quick open" })
  vim.keymap.set("n", "<leader>`", action("workbench.files.action.showActiveFileInExplorer"), { desc = "Show in explorer" })

  -- View (视图)
  vim.keymap.set("n", "<leader>z", action("workbench.action.toggleZenMode"), { desc = "Toggle zen mode" })

  -- Folding (折叠)
  vim.keymap.set("n", "zC", action("editor.foldRecursively"), { desc = "Fold recursively" })
  vim.keymap.set("n", "zO", action("editor.unfoldRecursively"), { desc = "Unfold recursively" })

  -- Other (其他)
  vim.keymap.set("n", "<leader>J", action("editor.action.joinLines"), { desc = "Join lines" })
  vim.keymap.set("n", "<leader>sa", action("editor.action.selectAll"), { desc = "Select all" })
  vim.keymap.set("n", "<leader>gs", action("editor.action.formatSelection"), { desc = "Format selection" })
  vim.keymap.set("n", "<leader>gb", action("gitlens.toggleFileBlame"), { desc = "Toggle git blame" })

  -- ===== Visual mode (可视模式) =====
  vim.keymap.set("v", "<leader>sa", action("editor.action.selectAll"), { desc = "Select all" })
  vim.keymap.set("v", "<leader>l", action("editor.action.formatSelection"), { desc = "Format selection" })

  -- Yank highlight (复制高亮)
  vim.api.nvim_create_autocmd("TextYankPost", {
    desc = "Highlight on yank (复制时高亮)",
    callback = function()
      vim.highlight.on_yank({ higroup = "IncSearch", timeout = 200 })
    end,
  })

  -- Load vscode-multi-cursor and flash.nvim via lazy.nvim (通过 lazy.nvim 加载多光标和跳转插件)
  local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
  if (vim.uv or vim.loop).fs_stat(lazypath) then
    vim.opt.rtp:prepend(lazypath)
    require("lazy").setup({
      { "vscode-neovim/vscode-multi-cursor.nvim", event = "VeryLazy", opts = {} },
      {
        "gbprod/substitute.nvim",
        event = "VeryLazy",
        config = function()
          require("substitute").setup({})
          vim.keymap.set("n", "gs", require("substitute").operator, { desc = "Substitute operator(替换操作符)", noremap = true })
          vim.keymap.set("n", "gss", require("substitute").line, { desc = "Substitute line(替换整行)", noremap = true })
          vim.keymap.set("n", "gS", require("substitute").eol, { desc = "Substitute to eol(替换到行尾)", noremap = true })
          vim.keymap.set("x", "gs", require("substitute").visual, { desc = "Substitute visual(可视模式替换)", noremap = true })
        end,
      },
      {
        "folke/flash.nvim",
        vscode = true,
        event = "VeryLazy",
        ---@type Flash.Config
        opts = {},
        keys = {
          { "s", mode = { "n", "x", "o" }, function() require("flash").jump() end, desc = "Flash" },
          { "S", mode = { "n", "x", "o" }, function() require("flash").treesitter() end, desc = "Flash Treesitter" },
          { "r", mode = "o", function() require("flash").remote() end, desc = "Remote Flash" },
          { "R", mode = { "o", "x" }, function() require("flash").treesitter_search() end, desc = "Treesitter Search" },
        },
      },
    })
  end
else
  -- Normal Neovim: bootstrap lazy.nvim, LazyVim and your plugins
  -- (普通 Neovim: 加载完整 LazyVim 配置)
  require("config.lazy")
end
