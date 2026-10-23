-- 复制 Java 全限定名到剪贴板 (copy fully-qualified name)
-- ---------------------------------------------------------------------------
-- <leader>cy:光标在类名 -> 复制 pkg.Type;在方法名 -> 复制 pkg.Type#method
-- (IDEA "Copy Reference" 风格)。仅定义处生效,详见 config/java_fqn.lua。
-- (Copy the FQN of the symbol under the cursor; class -> pkg.Type,
--  method -> pkg.Type#method. Definition-site only.)
local M = {}

function M.copy()
  local fqn, err = require("config.java_fqn").fqn()
  if not fqn then
    vim.notify(err, vim.log.levels.WARN, { title = "copy-fqn" })
    return
  end
  vim.fn.setreg("+", fqn) -- 系统剪贴板 (system clipboard)
  vim.fn.setreg('"', fqn) -- 无名寄存器,方便就地 p (unnamed register too)
  vim.notify("Copied: " .. fqn, vim.log.levels.INFO, { title = "copy-fqn" })
end

return M
