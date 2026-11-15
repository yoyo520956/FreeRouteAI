#!/bin/sh
# 工作流校验：优先 actionlint（iSH 下 Go 运行时偶发段错误，故 GOMAXPROCS=1 并失败兜底），
# actionlint 不可用时退回纯 Python 结构校验，保证门一直在。
GOMAXPROCS=1 actionlint "$@"
c=$?
if [ $c -ge 2 ]; then
  echo "（actionlint 退出码 $c，iSH 下 Go 不稳定，改用 Python 结构校验）" >&2
  python3 "$(dirname "$0")/check-workflow.py"
fi
