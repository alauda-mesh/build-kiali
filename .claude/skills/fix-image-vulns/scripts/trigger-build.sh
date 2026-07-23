#!/usr/bin/env bash
# 步骤 5a：修复 PR 合并后，dispatch build-kiali 的 Build Kiali Images 流水线。
# 用法: trigger-build.sh [版本 ...]（缺省 = 状态中记录了修复 PR 的版本）
# 只给受影响版本填 epoch，值 = 当前 UTC 时间（YYYYmmddHHMM）：单调不重复，
# 不需要查询历史 epoch；发布 tag 会是 v<版本>-r<epoch>。
# 环境变量: SKIP_MERGE_CHECK=1 跳过 PR 合并校验；DRY_RUN=1 只打印命令不触发。
# 输出: BUILD_RUN_ID= / EPOCH=（写入状态，供 watch-build.sh 使用）

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state

if [[ $# -ge 1 ]]; then
  FIX_LIST="$*"
else
  FIX_LIST=""
  for v in $VERSIONS; do
    key="PR_$(ver_us "$v")"
    [[ -n "${!key:-}" ]] && FIX_LIST="$FIX_LIST $v"
  done
  FIX_LIST="${FIX_LIST# }"
fi
[[ -n "$FIX_LIST" ]] || die "状态中没有记录修复 PR 的版本；如要为指定版本触发重建请传参，如: trigger-build.sh 2.22.2"

# 防止拿旧代码重建：校验每个版本的修复 PR 已合并
if [[ "${SKIP_MERGE_CHECK:-}" != "1" ]]; then
  for v in $FIX_LIST; do
    key="PR_$(ver_us "$v")"
    pr="${!key:-}"
    [[ -n "$pr" ]] || { warn "版本 $v 没有记录修复 PR，跳过合并校验"; continue; }
    PR_STATE="$(gh pr view "$pr" --repo "$KIALI_REPO" --json state --jq .state)" \
      || die "查询 PR #$pr 状态失败"
    [[ "$PR_STATE" == "MERGED" ]] \
      || die "PR #$pr（$v）状态为 ${PR_STATE}，尚未合并。请等用户合并后再触发（或 SKIP_MERGE_CHECK=1 强制）"
  done
fi

EPOCH="$(date -u +%Y%m%d%H%M)"
ARGS=()
for v in $FIX_LIST; do ARGS+=(-f "$(epoch_input "$v")=${EPOCH}"); done

info "gh workflow run ${WORKFLOW_FILE} --repo ${REPO} --ref master ${ARGS[*]}"
if [[ "${DRY_RUN:-}" == "1" ]]; then
  echo "DRY_RUN: 未实际触发"
  exit 0
fi
gh workflow run "$WORKFLOW_FILE" --repo "$REPO" --ref master "${ARGS[@]}"

# dispatch 是异步的：run-name 会把每个非空 epoch 渲染成 r<epoch>，用它精确匹配新 run
info "等待 run 出现（epoch=${EPOCH}）..."
BUILD_RUN_ID=""
for _ in $(seq 1 24); do
  sleep 5
  BUILD_RUN_ID="$(gh run list --repo "$REPO" --workflow "$WORKFLOW_FILE" --event workflow_dispatch \
    --limit 5 --json databaseId,displayTitle \
    --jq "[.[] | select(.displayTitle | contains(\"r${EPOCH}\"))][0].databaseId // empty" 2>/dev/null || true)"
  [[ -n "$BUILD_RUN_ID" ]] && break
done
[[ -n "$BUILD_RUN_ID" ]] || die "dispatch 后 120s 内没有看到 epoch=${EPOCH} 的新 run，请到 Actions 页面确认"

set_state EPOCH "$EPOCH"
set_state BUILD_RUN_ID "$BUILD_RUN_ID"
echo
echo "BUILD_RUN_ID=${BUILD_RUN_ID}"
echo "EPOCH=${EPOCH}"
echo "URL=$(gh run view "$BUILD_RUN_ID" --repo "$REPO" --json url --jq .url)"
echo "下一步: 后台执行 watch-build.sh 监控构建（run_in_background: true）"
