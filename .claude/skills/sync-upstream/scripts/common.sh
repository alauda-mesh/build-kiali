#!/usr/bin/env bash
# 公共函数与常量，供各步骤脚本 source 使用。

set -euo pipefail

REPO="alauda-mesh/build-kiali"
UPSTREAM_OPERATOR_URL="${UPSTREAM_OPERATOR_URL:-https://github.com/kiali/kiali-operator.git}"
UPSTREAM_KIALI_URL="${UPSTREAM_KIALI_URL:-https://github.com/kiali/kiali.git}"
# kiali server 源码构建使用的 fork（wolfi git-checkout 从它的 kiali-<版本> 分支拉源码）
FORK_KIALI_URL="${FORK_KIALI_URL:-https://github.com/alauda-mesh/kiali.git}"

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*"; }
info() { echo "INFO: $*"; }

# 定位仓库根目录并 cd 过去
repo_root() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "当前目录不在 git 仓库内"
  [[ -f "$root/kiali-operator/VERSION" ]] || die "当前仓库不是 build-kiali（缺少 kiali-operator/VERSION）"
  cd "$root"
  ROOT="$root"
}

STATE_FILE_REL="_output/sync-state.env"

# 加载 sync.sh 写入的状态（NEW_TAG/KEEP_MINORS/DROP_MINORS 等）
load_state() {
  [[ -f "$ROOT/$STATE_FILE_REL" ]] || die "未找到 $STATE_FILE_REL，请先执行 sync.sh"
  # shellcheck disable=SC1090
  source "$ROOT/$STATE_FILE_REL"
  [[ -n "${NEW_TAG:-}" ]] || die "$STATE_FILE_REL 内容不完整，请重新执行 sync.sh"
}

# 把 minor 版本（v2.29）转成 Makefile/CSV 使用的下划线形式（2_29）
minor_us() { echo "${1#v}" | tr '.' '_'; }
