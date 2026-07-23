#!/usr/bin/env bash
# 步骤 1a：把用户输入解析成目标镜像列表，并初始化状态文件。
# 用法: resolve-images.sh <RUN_ID|run URL>          （Build Kiali Images 的流水线 run）
#       resolve-images.sh <镜像> [镜像 ...]          （明确的镜像地址，1~3 个）
# 输入为 run 时，从其 "Output image: " 步骤名提取镜像（矩阵构建会返回多行）。
# 只接受 kiali server 镜像；kiali-operator / kiali-operator-bundle 不在本 skill 范围。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root

[[ $# -ge 1 && -n "$1" ]] || die "用法: resolve-images.sh <RUN_ID|run URL|镜像 ...>"

RUN_ID=""
if [[ $# -eq 1 && "$1" =~ ^[0-9]+$ ]]; then
  RUN_ID="$1"
elif [[ $# -eq 1 && "$1" =~ /actions/runs/([0-9]+) ]]; then
  RUN_ID="${BASH_REMATCH[1]}"
fi

IMAGES=()
if [[ -n "$RUN_ID" ]]; then
  gh auth status >/dev/null 2>&1 || die "gh 未认证。请提示用户在会话中执行: ! gh auth login"
  # 构建 job 有名为 "Output image: <镜像>" 的步骤，从步骤名结构化提取比 grep 日志可靠
  mapfile -t IMAGES < <(gh run view "$RUN_ID" --repo "$REPO" --json jobs \
    --jq '.jobs[].steps[].name | select(startswith("Output image: ")) | sub("^Output image: "; "")')
  [[ ${#IMAGES[@]} -ge 1 ]] \
    || die "run ${RUN_ID} 中没有 'Output image: ' 步骤（构建未完成/失败，或不是 Build Kiali Images 的 run）"
else
  IMAGES=("$@")
fi
[[ ${#IMAGES[@]} -le 3 ]] || die "镜像数量 ${#IMAGES[@]} 超过上限 3 个，请拆分处理"

VERSIONS=""
for img in "${IMAGES[@]}"; do
  [[ "$img" == */kiali:* ]] \
    || die "$img 不是 kiali server 镜像（kiali-operator / operator-bundle 的漏洞不在本 skill 范围）"
  v="$(image_version "$img")" || die "无法从 $img 的 tag 解析出 vX.Y.Z 版本号"
  VERSIONS="$VERSIONS $v"
  [[ "$img" == "$PUBLISH_REGISTRY"/* ]] \
    || warn "$img 不是 $PUBLISH_REGISTRY 发布镜像（PR 构建的 ghcr 镜像可能无法匿名拉取）"
done
VERSIONS="$(echo "$VERSIONS" | tr ' ' '\n' | grep -v '^$' | sort -uV | paste -sd' ' -)"

mkdir -p "$VULN_DIR"
{
  echo "IMAGES='${IMAGES[*]}'"
  echo "VERSIONS='${VERSIONS}'"
  echo "RUN_ID=${RUN_ID}"
  echo "ROUND=1"
} >"$STATE_FILE"

echo
echo "RESOLVED"
printf '镜像: %s\n' "${IMAGES[@]}"
echo "涉及版本: ${VERSIONS}"
echo "下一步: 执行 scan-images.sh 扫描（Bash timeout 设为 600000）"
