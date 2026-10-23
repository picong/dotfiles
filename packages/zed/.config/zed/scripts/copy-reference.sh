#!/usr/bin/env bash
# Copy JVM reference (fully-qualified name) to clipboard, IDEA "Copy Reference" style.
# 拷贝 JVM 引用（全限定名）到剪贴板，模仿 IDEA 的 "Copy Reference"。
#
# Class caret  -> com.xxx.ClassA          (类上光标)
# Member caret -> com.xxx.ClassA#methodA  (方法/字段/构造器上光标)
#
# Zed passes: ZED_FILE (abs path), ZED_ROW / ZED_COLUMN (caret pos, 1-based).
set -uo pipefail

file="${ZED_FILE:-}"

if [[ -z "$file" || ! -f "$file" ]]; then
  echo "no current file" >&2
  exit 1
fi

# Top-level class name = filename without extension (JVM convention).
# 顶层类名 = 去扩展名的文件名（JVM 约定）。
base="$(basename "$file")"
cls="${base%.*}"

# Read package declaration from the file (java/kotlin/groovy/scala all use `package X`).
# 从文件读取 package 声明（java/kotlin/groovy/scala 都是 `package X`）。
pkg="$(grep -m1 -oE '^[[:space:]]*package[[:space:]]+[A-Za-z0-9_.]+' "$file" 2>/dev/null \
        | grep -oE '[A-Za-z0-9_.]+$' || true)"

if [[ -n "$pkg" ]]; then
  fqcn="${pkg}.${cls}"
else
  fqcn="$cls"
fi

ref="$fqcn"

# Resolve the member from the caret position. ZED_SYMBOL is the breadcrumb and
# reports the enclosing class for a method caret, so it is unreliable; instead
# read the identifier token directly under the caret (ZED_ROW/ZED_COLUMN, both
# 1-based). If that identifier equals the class name it is the type itself
# (-> class ref); otherwise it is a member (-> #member).
# (ZED_SYMBOL 面包屑对方法光标只报外层类名不可靠；改用 ZED_ROW/ZED_COLUMN
#  直接取光标下的标识符 token。等于类名则是类本身，否则是成员。)
row="${ZED_ROW:-}"
col="${ZED_COLUMN:-}"

if [[ "$row" =~ ^[0-9]+$ && "$col" =~ ^[0-9]+$ ]]; then
  token="$(awk -v r="$row" -v col="$col" '
    NR==r {
      s=col; while (s>1 && substr($0,s-1,1) ~ /[A-Za-z0-9_$]/) s--
      e=col; while (substr($0,e,1)   ~ /[A-Za-z0-9_$]/) e++
      print substr($0,s,e-s)
    }' "$file")"

  if [[ -n "$token" && "$token" != "$cls" ]]; then
    # Caret on a member identifier (method / field / enum constant).
    # 光标落在成员标识符上（方法/字段/枚举常量）。
    ref="${fqcn}#${token}"
  fi
fi

# Copy to clipboard (Wayland first, then X11 fallbacks).
# 拷贝到剪贴板（优先 Wayland，回落 X11）。
# Copy to clipboard. wl-copy forks a daemon to hold the Wayland selection;
# Zed reaps the task's whole process group on exit, which would kill that
# daemon and empty the clipboard. setsid detaches it into a new session so
# it survives. (wl-copy 会 fork 常驻 daemon 持有选区；Zed 结束 task 时回收
# 整个进程组会连带杀掉它导致剪贴板变空，用 setsid 脱离进程组保命。)
if command -v wl-copy >/dev/null 2>&1; then
  printf '%s' "$ref" | setsid wl-copy
elif command -v xclip >/dev/null 2>&1; then
  printf '%s' "$ref" | setsid xclip -selection clipboard
elif command -v xsel >/dev/null 2>&1; then
  printf '%s' "$ref" | setsid xsel --clipboard --input
else
  echo "no clipboard tool (wl-copy/xclip/xsel)" >&2
  exit 1
fi

echo "copied: $ref"
