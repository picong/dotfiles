-- gutentags 项目根探测：多模块 Maven 仓库友好 (multi-module Maven aware)
-- ---------------------------------------------------------------------------
-- gutentags 默认行为是"向上撞到第一个根标记就停"，在多模块 Maven 仓库里会
-- 停在【子模块】的 pom.xml，导致只索引那一个叶子模块、跨模块跳转 E426。
-- 这里改为：优先用【git 仓库根】当项目根——多模块仓库的 .git 在最顶层，
-- 一次就能覆盖所有模块；非 git 项目再回退到最近的 pom/gradle/go.mod。
-- (Default gutentags stops at the nearest marker, which in a multi-module
--  Maven repo is the sub-module pom.xml — only that leaf gets indexed and
--  cross-module jumps fail with E426. We prefer the git repo root instead.)
--
-- 注意：本 finder 完整用 Lua 实现并返回字符串（无解析时返回 ""），刻意不调用
-- gutentags#default_get_project_root —— 后者会 throw "gutentags:" 异常，经
-- luaeval 跨边界回传后前缀可能丢失，破坏 setup_gutentags 的 catch 匹配。
-- (We re-implement fully in Lua and return "" on no match, instead of calling
--  the default finder which throws — the exception prefix may not survive the
--  lua↔vimscript boundary and would break gutentags' catch.)
local M = {}

-- 单模块 / 非 git 项目的回退根标记 (fallback markers for non-git projects)
local markers = { "pom.xml", "build.gradle", "settings.gradle", "go.mod" }

-- 该目录是否在排除名单里（如 $HOME dotfiles 仓库）(is dir excluded?)
local function is_excluded(dir)
  for _, e in ipairs(vim.g.gutentags_exclude_project_root or {}) do
    if dir == e then
      return true
    end
  end
  return false
end

-- 给定 buffer 目录，返回项目根；找不到返回 ""。
-- (Given a buffer dir, return project root, or "" if none.)
function M.find(path)
  if not path or path == "" then
    return ""
  end

  -- 1) 优先 git 仓库根：多模块仓库 .git 在最顶层，一次覆盖所有模块。
  -- (Prefer the git repo root: top-level .git covers every module at once.)
  local git = vim.fs.find(".git", { upward = true, path = path })[1]
  if git then
    local root = vim.fs.dirname(git)
    if root ~= "" and not is_excluded(root) then
      return root
    end
  end

  -- 2) 回退：向上找最近的 pom.xml/gradle/go.mod（单模块、非 git 项目）。
  -- (Fallback: nearest pom/gradle/go.mod for single-module, non-git projects.)
  local found = vim.fs.find(markers, { upward = true, path = path })[1]
  if found then
    local root = vim.fs.dirname(found)
    if root ~= "" and not is_excluded(root) then
      return root
    end
  end

  -- 3) 找不到合适项目根：返回空串，gutentags 会优雅跳过该 buffer。
  -- (No suitable root: return "" and gutentags skips this buffer cleanly.)
  return ""
end

return M
