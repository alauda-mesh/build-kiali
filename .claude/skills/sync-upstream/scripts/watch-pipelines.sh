#!/usr/bin/env bash
# 步骤 6（监控）：轮询 PR 最新 commit 触发的三条流水线直到全部完成。
# 需后台运行（构建通常 10~30 分钟）。可用 WATCH_TIMEOUT（秒，默认 2700）调整超时。
# 退出码: 0=PIPELINE_SUCCESS  2=PIPELINE_FAILED  3=PIPELINE_TIMEOUT  4=PIPELINE_NOT_FOUND

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state

command -v gh >/dev/null || die "未安装 gh"
[[ -n "${PR_NUMBER:-}" ]] || die "状态文件中无 PR_NUMBER，请先执行 create-pr.sh"

TIMEOUT="${WATCH_TIMEOUT:-2700}"
INTERVAL=60
GRACE=300   # 等待流水线出现/补齐的宽限期（秒）；pull_request 触发的三条通常几十秒内会一起出现
EXPECTED_WORKFLOWS=("Build Kiali Images" "Build Kiali Operator" "Build Kiali Operator Bundle")
START=$(date +%s)

echo "监控 PR #$PR_NUMBER（https://github.com/$REPO/pull/$PR_NUMBER）的流水线，超时 ${TIMEOUT}s ..."

while true; do
  NOW=$(date +%s); ELAPSED=$((NOW - START))

  # 每轮都取 PR 最新 head（期间可能 push 了修复 commit）
  HEAD_OID="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefOid -q .headRefOid)"
  # 注意: 必须用 workflowName（.name 返回的是 run-name 展示标题，不是 workflow 名）
  RUNS="$(gh run list --repo "$REPO" --commit "$HEAD_OID" \
    --json workflowName,status,conclusion,url,databaseId \
    -q 'sort_by(.databaseId) | .[] | "\(.workflowName)\t\(.status)\t\(.conclusion)\t\(.url)\t\(.databaseId)"' 2>/dev/null || true)"
  # 同名 workflow 取最新一次 run（sort_by 后同名靠后覆盖靠前）
  RUNS="$(echo "$RUNS" | awk -F'\t' 'NF { latest[$1] = $0 } END { for (k in latest) print latest[k] }')"

  RUN_COUNT="$(echo "$RUNS" | grep -c . || true)"
  if [[ "$RUN_COUNT" -eq 0 ]]; then
    if [[ $ELAPSED -ge $GRACE ]]; then
      echo "PIPELINE_NOT_FOUND"
      echo "等待 ${GRACE}s 后仍未发现 commit ${HEAD_OID:0:8} 触发的流水线。排查方向: self-hosted runner 是否在线、PR 变更是否命中各 workflow 的 paths 过滤、目标分支是否为 ${TARGET_BRANCH}。"
      exit 4
    fi
    echo "[${ELAPSED}s] 尚未发现流水线，继续等待 ..."
    sleep "$INTERVAL"; continue
  fi

  PENDING="$(echo "$RUNS" | awk -F'\t' '$2 != "completed"' | grep -c . || true)"
  echo "[${ELAPSED}s] commit ${HEAD_OID:0:8}: ${RUN_COUNT} 条流水线，${PENDING} 条未完成"
  echo "$RUNS" | awk -F'\t' '{printf "  - %s: %s %s\n", $1, $2, ($3 == "" ? "-" : $3)}'

  if [[ "$PENDING" -eq 0 ]]; then
    # 宽限期内继续等可能还没触发的 workflow（三条 paths 都会命中同步 PR）
    if [[ "$RUN_COUNT" -lt ${#EXPECTED_WORKFLOWS[@]} && $ELAPSED -lt $GRACE ]]; then
      sleep "$INTERVAL"; continue
    fi
    break
  fi
  [[ $ELAPSED -ge $TIMEOUT ]] && { echo "PIPELINE_TIMEOUT"; echo "$RUNS" | awk -F'\t' '{print "  - " $1 ": " $4}'; exit 3; }
  sleep "$INTERVAL"
done

# 全部完成，汇总结论
FAILED="$(echo "$RUNS" | awk -F'\t' '$3 != "success"')"
for wf in "${EXPECTED_WORKFLOWS[@]}"; do
  echo "$RUNS" | awk -F'\t' -v w="$wf" '$1 == w' | grep -q . \
    || echo "INFO: workflow 「${wf}」 本次未触发（PR 变更未命中其 paths？请确认是否符合预期）"
done

if [[ -z "$FAILED" ]]; then
  echo "PIPELINE_SUCCESS"
  echo "$RUNS" | awk -F'\t' '{print "  - " $1 ": success " $4}'
  exit 0
fi

echo "PIPELINE_FAILED"
echo "$FAILED" | awk -F'\t' '{print "  - " $1 ": " $3 " " $4}'
echo
echo "$FAILED" | while IFS=$'\t' read -r name status conclusion url id; do
  [[ -n "$id" ]] || continue
  echo "===== 失败日志摘要: $name (run $id) ====="
  LOG="$(gh run view "$id" --repo "$REPO" --log-failed 2>/dev/null || true)"
  if [[ -z "$LOG" ]]; then
    echo "(拉取日志失败，可手动执行: gh run view $id --repo $REPO --log-failed)"
  else
    echo "--- 错误相关行 ---"
    echo "$LOG" | grep -iE "error|fail|fatal|warn|denied|not found|no such" | tail -25
    echo "--- 日志末尾 ---"
    echo "$LOG" | tail -15
  fi
  echo
done
exit 2
