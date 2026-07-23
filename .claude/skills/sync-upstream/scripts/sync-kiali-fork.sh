#!/usr/bin/env bash
# 步骤 2：确保 alauda-mesh/kiali fork 上存在目标版本的构建分支 kiali-<版本>。
# wolfi 构建从该 fork 分支拉取 kiali server 源码（便于之后在分支上追加 CVE/hotfix 提交），
# 分支基于上游 kiali/kiali 的同版本号 tag 创建。
# 幂等：远端分支已存在时不做任何修改（分支可能已带 hotfix，只汇报状态）。
# 依赖 sync.sh 写入的 _output/sync-state.env；本地 fork 克隆默认取 build-kiali 同级目录的
# kiali，可用环境变量 KIALI_REPO_DIR 覆盖。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state

KIALI_BRANCH="kiali-${NEW_VERSION}"
KIALI_DIR="${KIALI_REPO_DIR:-$(dirname "$ROOT")/kiali}"

# ---------- 前置检查 ----------
[[ -d "$KIALI_DIR/.git" ]] || die "未找到本地 kiali fork 克隆: $KIALI_DIR（可用 KIALI_REPO_DIR=<路径> 指定）"
ORIGIN_URL="$(git -C "$KIALI_DIR" remote get-url origin 2>/dev/null || true)"
[[ "$ORIGIN_URL" == *alauda-mesh/kiali* ]] \
  || die "$KIALI_DIR 的 origin 不是 alauda-mesh/kiali（实际: ${ORIGIN_URL:-未配置}）"

# ---------- 远端已有分支：保持不动 ----------
REMOTE_HEAD="$(git -C "$KIALI_DIR" ls-remote origin "refs/heads/${KIALI_BRANCH}" | awk '{print $1}')"
if [[ -n "$REMOTE_HEAD" ]]; then
  echo "BRANCH_EXISTS"
  echo "分支: ${KIALI_BRANCH}（alauda-mesh/kiali 上已存在，保持不动）"
  echo "分支头: ${REMOTE_HEAD}"
  if [[ "$REMOTE_HEAD" != "$KIALI_COMMIT" ]]; then
    echo "INFO: 分支头与上游 tag ${NEW_TAG}（${KIALI_COMMIT}）不一致，分支上可能有 hotfix 提交，属正常情况，请在汇报中说明"
  fi
  echo
  echo "下一步: 执行 update-versions.sh"
  exit 0
fi

# ---------- 获取上游 tag（按 URL fetch，无需在 fork 克隆里配置 upstream remote） ----------
info "从 kiali/kiali 获取 tag ${NEW_TAG} ..."
git -C "$KIALI_DIR" fetch --no-tags "$UPSTREAM_KIALI_URL" "refs/tags/${NEW_TAG}:refs/tags/${NEW_TAG}" \
  || die "获取上游 tag ${NEW_TAG} 失败（网络问题或 tag 不存在）"
TAG_COMMIT="$(git -C "$KIALI_DIR" rev-parse "refs/tags/${NEW_TAG}^{}")"
[[ "$TAG_COMMIT" == "$KIALI_COMMIT" ]] \
  || die "本地取到的 tag commit（$TAG_COMMIT）与 sync-state 记录（$KIALI_COMMIT）不一致，状态可能过期，请重跑 sync.sh"

# ---------- 创建本地分支（git branch 不切换工作区，不影响该克隆当前的工作状态） ----------
if git -C "$KIALI_DIR" rev-parse --verify --quiet "refs/heads/${KIALI_BRANCH}" >/dev/null; then
  LOCAL_HEAD="$(git -C "$KIALI_DIR" rev-parse "refs/heads/${KIALI_BRANCH}")"
  [[ "$LOCAL_HEAD" == "$TAG_COMMIT" ]] \
    || die "本地已有分支 ${KIALI_BRANCH} 但不指向 tag commit（本地: $LOCAL_HEAD，tag: $TAG_COMMIT），可能是手工分支，请与用户确认后处理"
  info "本地分支 ${KIALI_BRANCH} 已存在且指向 tag commit，直接 push"
else
  git -C "$KIALI_DIR" branch "$KIALI_BRANCH" "refs/tags/${NEW_TAG}^{}"
fi

# ---------- push 并校验 ----------
info "push ${KIALI_BRANCH} 到 alauda-mesh/kiali ..."
git -C "$KIALI_DIR" push origin "refs/heads/${KIALI_BRANCH}:refs/heads/${KIALI_BRANCH}" \
  || die "push 失败（权限或网络问题）"
REMOTE_HEAD="$(git -C "$KIALI_DIR" ls-remote origin "refs/heads/${KIALI_BRANCH}" | awk '{print $1}')"
[[ "$REMOTE_HEAD" == "$TAG_COMMIT" ]] \
  || die "push 后校验失败：远端分支头 ${REMOTE_HEAD:-空} != tag commit ${TAG_COMMIT}"

echo
echo "BRANCH_CREATED"
echo "分支: ${KIALI_BRANCH}（基于上游 tag ${NEW_TAG} 创建并已 push 到 alauda-mesh/kiali）"
echo "分支头: ${REMOTE_HEAD}"
echo
echo "下一步: 执行 update-versions.sh"
