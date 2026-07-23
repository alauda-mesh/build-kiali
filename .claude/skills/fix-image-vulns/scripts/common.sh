#!/usr/bin/env bash
# fix-image-vulns 各脚本共享的函数与常量
set -euo pipefail

die()  { echo "错误: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }
info() { echo "==> $*"; }

# 仓库与镜像地址（测试时可用环境变量覆盖）
REPO="${FIX_VULNS_REPO:-alauda-mesh/build-kiali}"
KIALI_REPO="${KIALI_FORK_REPO:-alauda-mesh/kiali}"
WORKFLOW_FILE="build-kiali.yaml"
# 发布 registry（镜像的正式地址）与扫描 registry（trivy 实际拉取地址，可匿名拉）
PUBLISH_REGISTRY="build-harbor.alauda.cn"
SCAN_REGISTRY="${SCAN_REGISTRY:-registry.alauda.cn:60070}"

# 定位 build-kiali 仓库根目录并初始化路径变量
repo_root() {
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "当前目录不在 git 仓库内"
  [[ -f "$ROOT/kiali-operator/VERSION" && -d "$ROOT/wolfi" ]] \
    || die "当前仓库不是 build-kiali（缺少 kiali-operator/VERSION 或 wolfi/）"
  cd "$ROOT"
  STATE_FILE="$ROOT/_output/vuln-state.env"
  VULN_DIR="$ROOT/_output/vuln"
  # 同级目录的 kiali fork 克隆（修复分支基于它创建）
  KIALI_DIR="${KIALI_REPO_DIR:-$(dirname "$ROOT")/kiali}"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "找不到状态文件 $STATE_FILE，请先执行 resolve-images.sh"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

# 更新状态文件中的一个键（先删旧行再追加，保持其余行不变）
set_state() {
  local key="$1" value="$2"
  sed -i "/^${key}=/d" "$STATE_FILE"
  echo "${key}=${value}" >>"$STATE_FILE"
}

# 2.22.2 → 2_22_2（状态文件键名用）
ver_us() { echo "${1//./_}"; }

# 2.22.2 → epoch_v2_22（build-kiali.yaml workflow_dispatch 的输入名）
epoch_input() { local m="${1%.*}"; echo "epoch_v${m//./_}"; }

# 镜像扫描地址：把发布 registry 替换为可匿名拉取的扫描 registry
scan_ref() { echo "${1/${PUBLISH_REGISTRY}/${SCAN_REGISTRY}}"; }

# 从镜像 tag 提取版本号: ...:v2.22.2-rt.1 → 2.22.2（解析失败返回 1）
image_version() {
  local tag="${1##*:}"
  [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+) ]] && echo "${BASH_REMATCH[1]}"
}
