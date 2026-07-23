#!/usr/bin/env bash
# 步骤 5b：监控 dispatch 的 Build Kiali Images run。会阻塞 10~30 分钟，必须后台运行。
# 成功时从 run 的 "Output image: " 步骤提取新镜像，写回状态（IMAGES 更新、ROUND+1），
# 步骤 6 直接重跑 scan-images.sh 即是对新镜像的回归扫描。
# 环境变量: FIX_WATCH_INTERVAL 轮询间隔秒（默认 30）；FIX_WATCH_TIMEOUT 上限秒（默认 2700）
# 退出码: 0=成功 2=失败（附日志摘要） 3=超时

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state

INTERVAL="${FIX_WATCH_INTERVAL:-30}"
TIMEOUT="${FIX_WATCH_TIMEOUT:-2700}"
[[ -n "${BUILD_RUN_ID:-}" ]] || die "状态中没有 BUILD_RUN_ID，请先执行 trigger-build.sh"

URL="$(gh run view "$BUILD_RUN_ID" --repo "$REPO" --json url --jq .url 2>/dev/null || echo "https://github.com/${REPO}/actions/runs/${BUILD_RUN_ID}")"
info "监控 run ${BUILD_RUN_ID}: ${URL}"

START="$(date +%s)"
LAST_STATUS=""
while :; do
  # gh 偶发网络失败按 unknown 处理，下一轮重查，不中断监控
  read -r STATUS CONCLUSION < <(gh run view "$BUILD_RUN_ID" --repo "$REPO" --json status,conclusion \
    --jq '"\(.status) \(.conclusion // "-")"' 2>/dev/null || echo "unknown -")
  if [[ "$STATUS" != "$LAST_STATUS" ]]; then
    echo "[$(date +%H:%M:%S)] status=${STATUS}"
    LAST_STATUS="$STATUS"
  fi
  [[ "$STATUS" == "completed" ]] && break
  if (( $(date +%s) - START > TIMEOUT )); then
    echo "RESULT: PIPELINE_TIMEOUT 等待超过 ${TIMEOUT}s 仍未完成，请稍后查看: ${URL}"
    exit 3
  fi
  sleep "$INTERVAL"
done

if [[ "$CONCLUSION" == "success" ]]; then
  mapfile -t NEW_IMAGES < <(gh run view "$BUILD_RUN_ID" --repo "$REPO" --json jobs \
    --jq '.jobs[].steps[].name | select(startswith("Output image: ")) | sub("^Output image: "; "")')
  echo "RESULT: PIPELINE_SUCCESS ${URL}"
  if [[ ${#NEW_IMAGES[@]} -ge 1 ]]; then
    set_state IMAGES "'${NEW_IMAGES[*]}'"
    set_state ROUND "$((ROUND + 1))"
    printf '新镜像: %s\n' "${NEW_IMAGES[@]}"
    echo "状态已更新（ROUND=$((ROUND + 1))）。下一步: 重跑 scan-images.sh 做回归扫描"
  else
    warn "run 成功但没有解析到 'Output image: ' 步骤，请人工确认新镜像后更新 ${STATE_FILE}"
  fi
  exit 0
fi

echo "RESULT: PIPELINE_FAILED conclusion=${CONCLUSION} ${URL}"
echo
echo "失败 job/step 概览:"
gh run view "$BUILD_RUN_ID" --repo "$REPO" 2>/dev/null | grep -E '^(X|✓|-|\*)' | head -20 || true
LOG="$(gh run view "$BUILD_RUN_ID" --repo "$REPO" --log-failed 2>/dev/null || true)"
if [[ -n "$LOG" ]]; then
  echo
  echo "错误相关行:"
  # 词边界匹配并排除 step 定义回显（shell: .../--fail 等会误命中 fail）
  grep -iE '\b(error|fail(ed|ure)?|fatal|panic|denied|not found|no such|cannot|unable)\b' <<<"$LOG" \
    | grep -vE 'shell: /usr/bin/bash|--fail' | tail -25 || true
  echo
  echo "日志尾部（完整日志: gh run view --repo ${REPO} ${BUILD_RUN_ID} --log-failed）:"
  tail -15 <<<"$LOG"
else
  echo "（拉取失败日志出错，请手动查看 ${URL}）"
fi
exit 2
