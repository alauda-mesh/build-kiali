#!/usr/bin/env bash
# 步骤 3（辅助）：输出上游新旧 tag 之间需要人工审阅的 diff：
#   1. kiali-ossm 的 CSV（据此把通用变化合入我们的 CSV）
#   2. requirements.yml（有变化时需要复制到 kiali-operator/）

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state

UP="_output/upstream/kiali-operator"
[[ -d "$UP/.git" ]] || die "未找到上游克隆 $UP，请先执行 sync.sh"

OLD_TAG="v${OLD_VERSION}"
if ! git -C "$UP" rev-parse --verify --quiet "refs/tags/$OLD_TAG" >/dev/null; then
  git -C "$UP" fetch --quiet --depth 1 origin tag "$OLD_TAG" \
    || die "上游获取旧 tag ${OLD_TAG} 失败，无法生成 diff，请手动对比"
fi

section() { echo; echo "===================== $1 ====================="; }

section "上游 CSV diff（${OLD_TAG} -> ${NEW_TAG}，kiali-ossm）"
CSV_PATH=manifests/kiali-ossm/manifests/kiali.clusterserviceversion.yaml
if git -C "$UP" diff --quiet "refs/tags/$OLD_TAG" "refs/tags/$NEW_TAG" -- "$CSV_PATH"; then
  echo "NO_CHANGE"
else
  git -C "$UP" diff "refs/tags/$OLD_TAG" "refs/tags/$NEW_TAG" -- "$CSV_PATH"
fi

section "上游 requirements.yml diff（${OLD_TAG} -> ${NEW_TAG}）"
if git -C "$UP" diff --quiet "refs/tags/$OLD_TAG" "refs/tags/$NEW_TAG" -- requirements.yml; then
  echo "NO_CHANGE"
else
  git -C "$UP" diff "refs/tags/$OLD_TAG" "refs/tags/$NEW_TAG" -- requirements.yml
  echo
  echo "提示: 上游 requirements.yml 有变化，请执行: cp $UP/requirements.yml kiali-operator/requirements.yml"
fi
