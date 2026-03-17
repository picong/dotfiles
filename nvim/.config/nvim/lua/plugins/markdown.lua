return {
  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = { "markdown", "Avante" },
    config = function()
      require("render-markdown").setup({
        enable = true,
        callout = {
          abstract = { raw = "[!ABSTRACT]", rendered = "󰯂 Abstract", highlight = "RenderMarkdownInfo", category = "obsidian" },
          summary = { raw = "[!SUMMARY]", rendered = "󰯂 Summary", highlight = "RenderMarkdownInfo", category = "obsidian" },
          tldr = { raw = "[!TLDR]", rendered = "󰦩 Tldr", highlight = "RenderMarkdownInfo", category = "obsidian" },
          failure = { raw = "[!FAILURE]", rendered = " Failure", highlight = "RenderMarkdownError", category = "obsidian" },
          fail = { raw = "[!FAIL]", rendered = " Fail", highlight = "RenderMarkdownError", category = "obsidian" },
          missing = { raw = "[!MISSING]", rendered = " Missing", highlight = "RenderMarkdownError", category = "obsidian" },
          attention = { raw = "[!ATTENTION]", rendered = " Attention", highlight = "RenderMarkdownWarn", category = "obsidian" },
          warning = { raw = "[!WARNING]", rendered = " Warning", highlight = "RenderMarkdownWarn", category = "github" },
          danger = { raw = "[!DANGER]", rendered = " Danger", highlight = "RenderMarkdownError", category = "obsidian" },
          error = { raw = "[!ERROR]", rendered = " Error", highlight = "RenderMarkdownError", category = "obsidian" },
          bug = { raw = "[!BUG]", rendered = " Bug", highlight = "RenderMarkdownError", category = "obsidian" },
          quote = { raw = "[!QUOTE]", rendered = " Quote", highlight = "RenderMarkdownQuote", category = "obsidian" },
          cite = { raw = "[!CITE]", rendered = " Cite", highlight = "RenderMarkdownQuote", category = "obsidian" },
          todo = { raw = "[!TODO]", rendered = " Todo", highlight = "RenderMarkdownInfo", category = "obsidian" },
          wip = { raw = "[!WIP]", rendered = "󰦖 WIP", highlight = "RenderMarkdownHint", category = "obsidian" },
          done = { raw = "[!DONE]", rendered = " Done", highlight = "RenderMarkdownSuccess", category = "obsidian" },
        },
        sign = { enabled = false },
        code = {
          width = "block",
          min_width = 80,
          border = "thin",
          left_pad = 1,
          right_pad = 1,
          position = "right",
          language_icon = true,
          language_name = true,
          highlight_inline = "RenderMarkdownCodeInfo",
        },
        heading = {
          icons = { " 󰼏 ", " 󰎨 ", " 󰼑 ", " 󰎲 ", " 󰼓 ", " 󰎴 " },
          border = true,
          render_modes = true,
        },
        checkbox = {
          unchecked = { icon = "󰄱", highlight = "RenderMarkdownCodeFallback", scope_highlight = "RenderMarkdownCodeFallback" },
          checked = { icon = "󰄵", highlight = "RenderMarkdownUnchecked", scope_highlight = "RenderMarkdownUnchecked" },
          custom = {
            question = { raw = "[?]", rendered = "", highlight = "RenderMarkdownError", scope_highlight = "RenderMarkdownError" },
            todo = { raw = "[>]", rendered = "󰦖", highlight = "RenderMarkdownInfo", scope_highlight = "RenderMarkdownInfo" },
            canceled = { raw = "[-]", rendered = "", highlight = "RenderMarkdownCodeFallback", scope_highlight = "@text.strike" },
            important = { raw = "[!]", rendered = "", highlight = "RenderMarkdownWarn", scope_highlight = "RenderMarkdownWarn" },
            favorite = { raw = "[~]", rendered = "", highlight = "RenderMarkdownMath", scope_highlight = "RenderMarkdownMath" },
          },
        },
        pipe_table = {
          alignment_indicator = "─",
          border = { "╭", "┬", "╮", "├", "┼", "┤", "╰", "┴", "╯", "│", "─" },
        },
        link = {
          wiki = { icon = " ", highlight = "RenderMarkdownWikiLink", scope_highlight = "RenderMarkdownWikiLink" },
          image = " ",
          custom = {
            github = { pattern = "github", icon = " " },
            gitlab = { pattern = "gitlab", icon = "󰮠 " },
            youtube = { pattern = "youtube", icon = " " },
            cern = { pattern = "cern.ch", icon = " " },
          },
          hyperlink = " ",
        },
        anti_conceal = {
          disabled_modes = { "n" },
          ignore = {
            bullet = true,
            head_border = true,
            head_background = true,
          },
        },
        render_modes = { 'n', 'i', 'c' },
        win_options = { concealcursor = { rendered = "nvc" } },
        completions = {
          blink = { enabled = true },
          lsp = { enabled = true },
        },
      })
    end,
  },
  {
    "AndrewRadev/switch.vim",
    config = function()
      vim.keymap.set("n", "`", function()
        vim.cmd([[Switch]])
      end, { desc = "Switch strings" })
      vim.g.switch_custom_definitions = {
        { "> [!TODO]", "> [!WIP]", "> [!DONE]", "> [!FAIL]" },
        { "height",    "width" },
      }
    end,
  },
  {
    "bullets-vim/bullets.vim",
    ft = { "markdown" },
  },
  {
    "HakonHarnes/img-clip.nvim",
    ft = { "tex", "markdown", "typst" },
    opts = {
      default = {
        dir_path = "./attachments",
        use_absolute_path = false,
        copy_images = true,
        prompt_for_file_name = false,
        file_name = "%y%m%d-%H%M%S",
        extension = "png",
        process_cmd = "magick convert - -quality 90 png:-",
      },
      filetypes = {
        markdown = {
          template = "![image$CURSOR]($FILE_PATH)",
        },
        tex = {
          dir_path = "./figs",
          extension = "png",
          process_cmd = "",
          template = [[
\begin{figure}[h]
  \centering
  \includegraphics[width=0.8\textwidth]{$FILE_PATH}
\end{figure}
          ]],
        },
        typst = {
          dir_path = "./figs",
          extension = "png",
          process_cmd = "magick convert - -density 300 png:-",
          template = [[
#align(center)[#image("$FILE_PATH", height: 80%)]
          ]],
        },
      },
    },
    keys = {
      { "<leader>P", "<cmd>PasteImage<cr>", desc = "Paste image from system clipboard" },
    },
  },
}

