#!/usr/bin/env bash
# Test runner for the doctor extension. Node 22.6+ strips TS types natively, so no
# build step is needed; node_modules symlink resolves the pi package imports.
# (doctor 扩展的测试入口。Node 22.6+ 原生擦除 TS 类型，无需构建；
#  node_modules 符号链接用于解析 pi 包导入。)
set -uo pipefail
cd "$(dirname "$0")/.."
[ -e node_modules ] || ln -sfn "$(npm root -g)" node_modules
fail=0
for t in test/*.test.ts; do
  echo "── $t"
  out=$(node "$t" 2>&1) || { echo "$out"; echo "ERROR running $t"; fail=1; continue; }
  echo "$out"
  grep -q '^FAIL' <<<"$out" && fail=1
done
echo
[ "$fail" -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit "$fail"
