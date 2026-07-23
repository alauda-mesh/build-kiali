#!/usr/bin/env bash
# 步骤 1：同步上游源码。
# 用法: sync.sh <上游tag> <目标分支>   例如: sync.sh v2.27.1 master
# 职责: 前置校验 → 克隆上游并校验版本快照 → 建同步分支 → 复制 roles/playbooks/watches →
#       裁剪版本 → 更新 VERSION → 复制 CRD → 写状态文件 → 自动 commit。
#
# 上游版本模型: roles/ 下的 vX.Y 是历史版本快照（只在 OSSM 对齐版本创建，如 v2.17/v2.22/v2.27），
# default 即当前最新版。因此目标 tag 的 minor 必须拥有自己的快照，否则 default 与最新快照版本
# 不一致，会引入一个从未构建过的 kiali 镜像依赖，脚本会拒绝并说明。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

NEW_TAG="${1:-}"
TARGET_BRANCH="${2:-}"
[[ -n "$NEW_TAG" && -n "$TARGET_BRANCH" ]] || die "用法: sync.sh <上游tag> <目标分支>"
[[ "$NEW_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag 格式应为 vX.Y.Z，实际: $NEW_TAG"

NEW_VERSION="${NEW_TAG#v}"                       # 2.27.1
NEW_MINOR="v${NEW_VERSION%.*}"                   # v2.27

repo_root

# ---------- 前置检查 ----------
git diff --quiet && git diff --cached --quiet || die "工作区不干净，请先提交或 stash"
SYNC_BRANCH="sync/${NEW_TAG}"
git rev-parse --verify --quiet "$SYNC_BRANCH" >/dev/null && die "分支 $SYNC_BRANCH 已存在，请先处理（删除或换 tag）"
git fetch origin "$TARGET_BRANCH" || die "fetch origin/$TARGET_BRANCH 失败"

OLD_VERSION="$(git show "origin/$TARGET_BRANCH:kiali-operator/VERSION")"
[[ "$OLD_VERSION" != "$NEW_VERSION" ]] || die "VERSION 已是 $NEW_VERSION，无需同步"

# ---------- 解析 kiali/kiali 的 expected-commit（wolfi 构建用） ----------
info "解析 kiali/kiali tag ${NEW_TAG} 的 commit ..."
KIALI_COMMIT="$(git ls-remote "$UPSTREAM_KIALI_URL" "refs/tags/${NEW_TAG}^{}" | awk '{print $1}')"
if [[ -z "$KIALI_COMMIT" ]]; then
  KIALI_COMMIT="$(git ls-remote "$UPSTREAM_KIALI_URL" "refs/tags/${NEW_TAG}" | awk '{print $1}')"
fi
[[ -n "$KIALI_COMMIT" ]] || die "kiali/kiali 不存在 tag ${NEW_TAG}（server 与 operator 版本不一致？请与用户确认）"

# ---------- 克隆上游 ----------
UP="_output/upstream/kiali-operator"
rm -rf "$UP" && mkdir -p "$(dirname "$UP")"
info "浅克隆上游 kiali-operator ${NEW_TAG} ..."
git clone --quiet --depth 1 --branch "$NEW_TAG" "$UPSTREAM_OPERATOR_URL" "$UP" 2>/dev/null \
  || die "克隆上游 tag ${NEW_TAG} 失败（tag 不存在或网络问题）"
[[ -d "$UP/roles" && -d "$UP/playbooks" ]] || die "上游仓库结构异常：缺少 roles/ 或 playbooks/"

# ---------- 校验版本快照并计算保留/移除列表 ----------
UPSTREAM_SNAPSHOTS="$(ls "$UP/roles" | grep -E '^v[0-9]+\.[0-9]+$' | sort -V)"
if ! grep -qx "$NEW_MINOR" <(echo "$UPSTREAM_SNAPSHOTS"); then
  die "上游 ${NEW_TAG} 没有 roles/${NEW_MINOR} 版本快照（现有快照: $(echo "$UPSTREAM_SNAPSHOTS" | paste -sd' ' -)）。
       本仓库按快照版本（OSSM 对齐版本）同步；请改用带快照的 tag（通常是最新快照的 patch 版本），
       或与用户确认非对齐版本的特殊处理方案。"
fi
NEWEST_SNAPSHOT="$(echo "$UPSTREAM_SNAPSHOTS" | tail -1)"
[[ "$NEW_MINOR" == "$NEWEST_SNAPSHOT" ]] \
  || die "目标 ${NEW_MINOR} 不是上游最新快照（最新: $NEWEST_SNAPSHOT），不支持向旧版本同步"

CURRENT_MINORS="$(git ls-tree --name-only "origin/$TARGET_BRANCH" kiali-operator/roles/ \
  | xargs -n1 basename | grep -E '^v[0-9]+\.[0-9]+$' | sort -V)"
ALL_MINORS="$(printf '%s\n%s\n' "$CURRENT_MINORS" "$NEW_MINOR" | grep -v '^$' | sort -uV)"
KEEP_MINORS="$(echo "$ALL_MINORS" | tail -3)"
DROP_MINORS="$(grep -vxF -f <(echo "$KEEP_MINORS") <(echo "$ALL_MINORS") || true)"
# 同 minor 的 patch 升级：新 minor 已在旧列表里
SAME_MINOR=false
grep -qx "$NEW_MINOR" <(echo "$CURRENT_MINORS") && SAME_MINOR=true
# 跳版本同步时提示中间未保留的上游快照（如 2.22 直接跳 2.33 会跳过 2.27）
TOP_CURRENT="$(echo "$CURRENT_MINORS" | tail -1)"
SKIPPED="$(grep -vxF -f <(echo "$ALL_MINORS") <(echo "$UPSTREAM_SNAPSHOTS") \
  | while read -r s; do
      [[ "$(printf '%s\n%s\n' "$s" "$TOP_CURRENT" | sort -V | tail -1)" == "$s" ]] && echo "$s"
    done || true)"
[[ -n "$SKIPPED" ]] && warn "上游还有更新的中间快照未被保留: $(echo "$SKIPPED" | paste -sd' ' -)（跳版本同步，请在汇报中说明）"

# ---------- 创建同步分支 ----------
git checkout -b "$SYNC_BRANCH" "origin/$TARGET_BRANCH"

# ---------- 复制源码 ----------
info "复制 roles/playbooks/watches ..."
rm -rf kiali-operator/roles kiali-operator/playbooks
cp -r "$UP/roles" "$UP/playbooks" kiali-operator/
cp "$UP"/*.yaml kiali-operator/

# ---------- 裁剪 roles/：只留 default + KEEP_MINORS ----------
RESTORED=""
for d in kiali-operator/roles/*/; do
  name="$(basename "$d")"
  [[ "$name" == "default" ]] && continue
  grep -qx "$name" <(echo "$KEEP_MINORS") || rm -rf "$d"
done
# 理论上不会发生（上游不删快照），保底：要保留的版本上游没有时从原分支恢复
while read -r m; do
  [[ -n "$m" ]] || continue
  if [[ ! -d "kiali-operator/roles/$m" ]]; then
    git checkout "origin/$TARGET_BRANCH" -- "kiali-operator/roles/$m" \
      || die "上游无 roles/$m 且原分支恢复失败"
    RESTORED="$RESTORED $m"
  fi
done <<<"$KEEP_MINORS"

# ---------- 裁剪 kiali-default-supported-images.yml ----------
IMAGES_FILE="kiali-operator/playbooks/kiali-default-supported-images.yml"
[[ -f "$IMAGES_FILE" ]] || die "上游缺少 $IMAGES_FILE"
KEEP_PATTERN="$(echo "$KEEP_MINORS" | sed 's/\./\\./g' | paste -sd'|' -)"
grep -E "^(default|${KEEP_PATTERN}):" "$IMAGES_FILE" >"${IMAGES_FILE}.tmp"
mv "${IMAGES_FILE}.tmp" "$IMAGES_FILE"
# 恢复的老版本在上游文件里可能没有对应行，从原分支的文件补
while read -r m; do
  [[ -n "$m" ]] || continue
  if ! grep -q "^${m}:" "$IMAGES_FILE"; then
    old_line="$(git show "origin/$TARGET_BRANCH:$IMAGES_FILE" | grep "^${m}:" || true)"
    [[ -n "$old_line" ]] || die "supported-images 中找不到 ${m} 的条目（上游与原分支均无）"
    # 插到 default 行后，保持从老到新的顺序
    awk -v line="$old_line" '1; /^default:/ {print line}' "$IMAGES_FILE" >"${IMAGES_FILE}.tmp"
    mv "${IMAGES_FILE}.tmp" "$IMAGES_FILE"
    RESTORED="$RESTORED ${m}(supported-images)"
  fi
done <<<"$KEEP_MINORS"

# ---------- VERSION 与 CRD ----------
printf '%s' "$NEW_VERSION" >kiali-operator/VERSION
CRD_SRC="$UP/manifests/kiali-ossm/manifests/kiali.crd.yaml"
[[ -f "$CRD_SRC" ]] || die "上游缺少 $CRD_SRC，目录结构可能已变化"
cp "$CRD_SRC" kiali-operator-bundle/manifests/kiali.crd.yaml

# ---------- 写状态文件（供后续脚本使用） ----------
mkdir -p _output
{
  echo "NEW_TAG=$NEW_TAG"
  echo "NEW_VERSION=$NEW_VERSION"
  echo "NEW_MINOR=$NEW_MINOR"
  echo "OLD_VERSION=$OLD_VERSION"
  echo "TARGET_BRANCH=$TARGET_BRANCH"
  echo "SYNC_BRANCH=$SYNC_BRANCH"
  echo "SAME_MINOR=$SAME_MINOR"
  echo "KIALI_COMMIT=$KIALI_COMMIT"
  echo "KEEP_MINORS='$(echo "$KEEP_MINORS" | paste -sd' ' -)'"
  echo "DROP_MINORS='$(echo "$DROP_MINORS" | paste -sd' ' -)'"
  echo "RESTORED='${RESTORED# }'"
} >"$STATE_FILE_REL"

# ---------- 提交 ----------
git add -A
git commit --quiet -m "chore: sync kiali-operator ${NEW_TAG} from upstream"

# ---------- 汇报 ----------
echo
echo "SYNCED"
echo "分支: $SYNC_BRANCH（基于 origin/$TARGET_BRANCH）"
echo "版本: $OLD_VERSION -> $NEW_VERSION（同 minor 升级: $SAME_MINOR）"
echo "保留版本: $(echo "$KEEP_MINORS" | paste -sd' ' -) + default"
echo "移除版本: $(echo "$DROP_MINORS" | paste -sd' ' -)"
[[ -n "$RESTORED" ]] && echo "RESTORED（上游已删、从原分支恢复）:${RESTORED}"
echo "expected-commit(kiali/kiali): $KIALI_COMMIT"
echo "commit: $(git rev-parse --short HEAD) $(git log -1 --format=%s)"
echo
echo "变更概览:"
git show --stat HEAD | tail -5
echo
echo "下一步: 执行 update-versions.sh"
