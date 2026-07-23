#!/usr/bin/env bash
# 步骤 2a：在同级 kiali fork 克隆中创建修复分支。
# 用法: create-fix-branch.sh <版本>   例如: create-fix-branch.sh 2.22.2
# 基于 origin/kiali-<版本>（wolfi 构建用的分支）创建 fix 分支。用 git worktree 把
# 分支检出到 build-kiali/_output/kiali-fix-<版本>（gitignore 内），不打扰用户在
# kiali 克隆里的当前工作区。重复执行时同名分支的干净 worktree 直接复用。
# 输出: WORKTREE= / BRANCH= / BASE=

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state

VER="${1:-}"
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "用法: create-fix-branch.sh <版本号 X.Y.Z>"
BASE_BRANCH="kiali-${VER}"
FIX_BRANCH="fix/${BASE_BRANCH}-cve-$(date -u +%Y%m%d)-r${ROUND}"
WT="$ROOT/_output/kiali-fix-${VER}"

[[ -d "$KIALI_DIR/.git" ]] || die "同级目录没有 kiali 克隆: $KIALI_DIR（可用 KIALI_REPO_DIR 覆盖）"
ORIGIN="$(git -C "$KIALI_DIR" remote get-url origin 2>/dev/null)" || die "$KIALI_DIR 没有 origin remote"
[[ "$ORIGIN" == *"$KIALI_REPO"* ]] || die "$KIALI_DIR 的 origin（$ORIGIN）不是 $KIALI_REPO"

info "fetch origin/${BASE_BRANCH} ..."
git -C "$KIALI_DIR" fetch origin "refs/heads/${BASE_BRANCH}:refs/remotes/origin/${BASE_BRANCH}" \
  || die "fetch origin/${BASE_BRANCH} 失败（fork 上没有该构建分支？）"

if [[ -e "$WT" ]]; then
  CUR="$(git -C "$WT" branch --show-current 2>/dev/null || true)"
  if [[ "$CUR" == "$FIX_BRANCH" ]]; then
    info "worktree 已在分支 ${FIX_BRANCH} 上，直接复用"
    echo "WORKTREE=$WT"; echo "BRANCH=$FIX_BRANCH"; echo "BASE=origin/${BASE_BRANCH}"
    exit 0
  elif [[ -z "$(git -C "$WT" status --porcelain 2>/dev/null)" ]]; then
    info "移除残留的干净 worktree（其分支 ${CUR:-未知} 的引用仍保留在 kiali 仓库中）"
    git -C "$KIALI_DIR" worktree remove --force "$WT"
  else
    die "$WT 已存在且有未提交改动（分支 ${CUR:-未知}），请人工确认后再处理"
  fi
fi
git -C "$KIALI_DIR" rev-parse --verify --quiet "refs/heads/${FIX_BRANCH}" >/dev/null \
  && die "分支 ${FIX_BRANCH} 已存在（残留？确认无用后执行: git -C $KIALI_DIR branch -D ${FIX_BRANCH}）"

git -C "$KIALI_DIR" worktree add "$WT" -b "$FIX_BRANCH" "refs/remotes/origin/${BASE_BRANCH}"
set_state "BRANCH_$(ver_us "$VER")" "$FIX_BRANCH"

echo
echo "BRANCH_READY"
echo "WORKTREE=$WT"
echo "BRANCH=$FIX_BRANCH"
echo "BASE=origin/${BASE_BRANCH}（$(git -C "$WT" rev-parse --short HEAD)）"
echo "下一步: 在该 worktree 中用 gomod-bump.sh 升级漏洞库"
