#!/bin/bash
# 轮询最新构建直到完成
cd /var/minis/workspace/FreeRouteAI || exit 1
for i in $(seq 1 14); do
  sleep 60
  read -r ID S C <<<"$(gh run list --workflow='iOS Build' --limit 1 --json databaseId,status,conclusion --jq '.[0] | "\(.databaseId) \(.status) \(.conclusion // "-")"')"
  echo "[$i min] run $ID $S/$C"
  if [ "$S" = "completed" ]; then
    gh run view "$ID" --json jobs --jq '.jobs[0].steps[]|select(.conclusion=="failure")|"失败："+.name'
    gh run view "$ID" --log 2>&1 | awk -F'\t' 'NF>=3{print $NF}' > /tmp/f.log
    echo "=== Swift 错误 ==="
    rg -o '[^ /]+\.swift:[0-9]+:[0-9]+: error: .{0,140}' /tmp/f.log | sort -u | head -25
    echo "=== 关键节点 ==="
    rg '主程序：|缺少主程序|Executed [0-9]+ test|Test Suite .*(passed|failed)|ARCHIVE SUCCEEDED|EXPORT|Testing failed' /tmp/f.log | sed 's/^[0-9T:.Z-]*Z //' | cut -c1-110 | sort -u | head -14
    echo "=== 协议 conformance 要求（note 给出精确签名，照抄即可）==="
    rg -o "protocol requires function '[^']*' with type '.{0,90}" /tmp/f.log | sort -u | head -8
    exit 0
  fi
done
echo "仍在进行"
