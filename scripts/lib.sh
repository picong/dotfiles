#!/usr/bin/env bash
# Shared helpers (公共函数)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m ✗\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# Run a command, or only print it in dry-run mode. (执行命令；dry-run 时只打印)
run() {
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        printf '   [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

# Print non-empty, non-comment lines of a list file. (读取清单文件的有效行)
read_list() {
    grep -vE '^\s*(#|$)' "$1" | sed 's/\s*#.*$//'
}
