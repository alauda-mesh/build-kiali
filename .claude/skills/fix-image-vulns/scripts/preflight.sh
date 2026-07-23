#!/usr/bin/env bash
# 步骤 0：环境预检。
# 重点是本地 trivy：kiali 二进制打包成 APK 装进镜像，trivy 默认的
# --detection-priority precise 会把它当 os 包、跳过 go 依赖分析，必须用
# comprehensive；内部扫描服务（192.168.25.100:8888）固定 precise，因此不能用。
# 退出码: 0=通过  3=trivy 缺失或版本过旧（提示用户安装/升级后重跑本脚本）  1=其他前置缺失

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root

TRIVY_MIN="0.52.0"   # --detection-priority 自该版本引入
if ! command -v trivy >/dev/null 2>&1; then
  echo "TRIVY_MISSING: 本机未安装 trivy。请提示用户安装后再重跑本脚本，例如:"
  echo "  curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin"
  echo "  （其他安装方式见 https://trivy.dev/docs/getting-started/installation/）"
  exit 3
fi
TRIVY_VER="$(trivy --version 2>/dev/null | awk '/^Version:/ {print $2; exit}')"
if [[ -z "$TRIVY_VER" || "$(printf '%s\n%s\n' "$TRIVY_MIN" "$TRIVY_VER" | sort -V | head -1)" != "$TRIVY_MIN" ]]; then
  echo "TRIVY_TOO_OLD: trivy ${TRIVY_VER:-版本未知} < ${TRIVY_MIN}，不支持 --detection-priority，请提示用户升级后再重跑本脚本"
  exit 3
fi
info "trivy ${TRIVY_VER} OK（>= ${TRIVY_MIN}，支持 --detection-priority comprehensive）"

command -v jq >/dev/null 2>&1 || die "找不到 jq"
command -v gh >/dev/null 2>&1 || die "找不到 gh CLI"
gh auth status >/dev/null 2>&1 || die "gh 未认证。请提示用户在会话中执行: ! gh auth login"
info "jq / gh 认证 OK"

# 以下是修复阶段才用到的依赖：扫描结果干净时用不到，缺失只 WARN 不拦
if command -v go >/dev/null 2>&1; then
  info "go 工具链 OK（$(go version | awk '{print $3}')）"
else
  warn "本机没有 go 工具链，若扫出 go.mod 漏洞需先安装 go 才能修复"
fi
if [[ -d "$KIALI_DIR/.git" ]]; then
  ORIGIN="$(git -C "$KIALI_DIR" remote get-url origin 2>/dev/null || true)"
  if [[ "$ORIGIN" == *"$KIALI_REPO"* ]]; then
    info "kiali fork 克隆 OK: $KIALI_DIR"
  else
    warn "$KIALI_DIR 的 origin（$ORIGIN）不是 $KIALI_REPO，若需修复请先处理（或用 KIALI_REPO_DIR 指定正确路径）"
  fi
else
  warn "同级目录没有 kiali 克隆（$KIALI_DIR），若需修复请先 git clone git@github.com:${KIALI_REPO}.git"
fi

echo
echo "PREFLIGHT_OK"
