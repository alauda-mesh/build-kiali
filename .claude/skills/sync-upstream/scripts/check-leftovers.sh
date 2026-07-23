#!/usr/bin/env bash
# 步骤 4：一致性校验。
# 检查新版本是否在所有该出现的地方齐全、被淘汰版本是否有残留。
# FAIL 必须修复后重跑；WARN（roles/ 内上游自带内容）由模型逐条判断。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state

NEW_US="$(minor_us "$NEW_MINOR")"
NEW_MINOR_NO_V="${NEW_MINOR#v}"
FAIL=0; WARNED=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }

# ---------- 被淘汰版本残留扫描 ----------
# 我们自己维护的文件里出现被淘汰版本 = FAIL；roles/、CRD 等上游原样内容里出现 = WARN
# kiali.crd.yaml 由 sync.sh 从上游原样复制，里面 "DEPRECATED AFTER vX.Y" 等描述文案
# 指的是配置项的弃用时间点，不是版本快照残留，因此排除出 FAIL 扫描、归入 WARN 扫描。
CRD_FILE=kiali-operator-bundle/manifests/kiali.crd.yaml
MANAGED=(Makefile .github kiali-operator-bundle wolfi configs
  kiali-operator/VERSION kiali-operator/playbooks/kiali-default-supported-images.yml
  ":(exclude)${CRD_FILE}")
for d in $DROP_MINORS; do
  us="$(minor_us "$d")"
  dot="$(echo "${d#v}" | sed 's/\./\\./g')"     # 2\.11
  # 依次覆盖: KIALI_2_11 / *2_11* / v2.11.0、2.11.x / v2.11（后跟非数字非点，如引号、冒号）
  pattern="(KIALI_${us}|[^0-9_]${us}([^0-9]|$)|v?${dot}\.|v${dot}([^0-9.]|$))"
  hits="$(git grep -nE "$pattern" -- "${MANAGED[@]}" 2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    fail "残留检查: 受管文件中仍有被淘汰版本 ${d}:"
    echo "$hits" | sed 's/^/       /'
  else
    pass "残留检查: 受管文件中无 ${d} 残留"
  fi
  role_hits="$(git grep -nE "$pattern" -- kiali-operator/roles kiali-operator/playbooks "$CRD_FILE" 2>/dev/null | grep -v kiali-default-supported-images.yml || true)"
  if [[ -n "$role_hits" ]]; then
    WARNED=$((WARNED + 1))
    warn "roles/playbooks/CRD（上游内容）中出现 ${d}，请逐条判断是否需要处理:"
    echo "$role_hits" | head -20 | sed 's/^/       /'
  fi
done

# ---------- 版本文件 ----------
check "VERSION == ${NEW_VERSION}" bash -c "[[ \$(cat kiali-operator/VERSION) == '${NEW_VERSION}' ]]"

# ---------- roles 与 supported-images ----------
EXPECT_ROLES="$(printf 'default\n%s\n' "$(echo "$KEEP_MINORS" | tr ' ' '\n')" | sort -V)"
ACTUAL_ROLES="$(ls kiali-operator/roles | sort -V)"
check "roles/ 目录 == default + ${KEEP_MINORS}" bash -c "[[ '$ACTUAL_ROLES' == '$EXPECT_ROLES' ]]"
IMAGES_FILE=kiali-operator/playbooks/kiali-default-supported-images.yml
ACTUAL_IMG="$(grep -oE '^[^:]+' "$IMAGES_FILE" | sort -V)"
check "kiali-default-supported-images.yml == default + ${KEEP_MINORS}" bash -c "[[ '$ACTUAL_IMG' == '$EXPECT_ROLES' ]]"

# ---------- Makefile ----------
check "Makefile: KIALI_OPERATOR_BUNDLE_VERSION == ${NEW_VERSION}" grep -q "^KIALI_OPERATOR_BUNDLE_VERSION ?= ${NEW_VERSION}$" Makefile
check "Makefile: KIALI_OPERATOR_VERSION == ${NEW_VERSION}" grep -q "^KIALI_OPERATOR_VERSION ?= ${NEW_VERSION}$" Makefile
check "Makefile: KIALI_${NEW_US}_VERSION == v${NEW_VERSION}" grep -q "^KIALI_${NEW_US}_VERSION ?= v${NEW_VERSION}$" Makefile
check "Makefile: envsubst 传入 KIALI_${NEW_US}" grep -q "KIALI_${NEW_US}=\$(KIALI_${NEW_US})" Makefile
TODAY_PREFIX="CREATED_AT ?= $(date -u +%Y-%m-%d)"
grep -q "^${TODAY_PREFIX}" Makefile || { WARNED=$((WARNED+1)); warn "Makefile: CREATED_AT 不是今天（$(grep '^CREATED_AT' Makefile)），如是跨天执行可忽略"; }
# 每个保留版本都应有变量块
for m in $KEEP_MINORS; do
  us="$(minor_us "$m")"
  check "Makefile: 保留版本 ${m} 的 KIALI_${us} 变量存在" grep -q "^KIALI_${us}_VERSION ?= " Makefile
done

# ---------- CSV ----------
CSV=kiali-operator-bundle/manifests/kiali.clusterserviceversion.yaml
check "CSV: kiali_v${NEW_US} 条目共 2 处（relatedImages + env）" \
  bash -c "[[ \$(grep -c -- '- name: \(RELATED_IMAGE_\)\?kiali_v${NEW_US}\$' '$CSV') -eq 2 ]]"
check "CSV: \${KIALI_${NEW_US}} 引用 >= 4 处（default 与 v${NEW_US} 各 2 处）" \
  bash -c "[[ \$(grep -c '\${KIALI_${NEW_US}}' '$CSV') -ge 4 ]]"
for m in $KEEP_MINORS; do
  us="$(minor_us "$m")"
  check "CSV: 保留版本 ${m} 的条目存在" grep -q -- "- name: kiali_v${us}$" "$CSV"
done

# ---------- workflows ----------
WF_BUNDLE=.github/workflows/build-bundle.yaml
check "build-bundle: 输入 kiali_v${NEW_US}_tag 存在" grep -q "kiali_v${NEW_US}_tag" "$WF_BUNDLE"
check "build-bundle: 导出 KIALI_${NEW_US}_VERSION" grep -q "KIALI_${NEW_US}_VERSION" "$WF_BUNDLE"
check "build-bundle: 输入默认值含 v${NEW_VERSION}-r0" grep -q "v${NEW_VERSION}-r0" "$WF_BUNDLE"
check "build-bundle: run-name 提到 ${NEW_VERSION}" bash -c "grep -A13 '^run-name:' '$WF_BUNDLE' | grep -q '${NEW_VERSION}'"

WF_KIALI=.github/workflows/build-kiali.yaml
check "build-kiali: 输入 epoch_v${NEW_US} 存在" grep -q "epoch_v${NEW_US}" "$WF_KIALI"
check "build-kiali: find_version \"${NEW_MINOR}\" 分支存在" grep -q "find_version \"${NEW_MINOR}\"" "$WF_KIALI"
check "build-kiali: publish-tag case 含 ${NEW_MINOR}.*" grep -q "${NEW_MINOR_NO_V//./\\.}\.\*" "$WF_KIALI"
check "build-kiali: run-name 提到 ${NEW_VERSION}" bash -c "grep -A12 '^run-name:' '$WF_KIALI' | grep -q '${NEW_VERSION}'"

WF_OP=.github/workflows/build-kiali-operator.yaml
check "build-kiali-operator: run-name 提到 ${NEW_VERSION}" bash -c "grep -A7 '^run-name:' '$WF_OP' | grep -q '${NEW_VERSION}'"
BASE_VER="$(grep -E '^\s*OPERATOR_BASE_IMAGE_VERSION:' "$WF_OP" | awk '{print $2}')"
if [[ "$BASE_VER" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$ ]]; then
  pass "build-kiali-operator: OPERATOR_BASE_IMAGE_VERSION=${BASE_VER} 是 release tag"
else
  WARNED=$((WARNED+1)); warn "build-kiali-operator: OPERATOR_BASE_IMAGE_VERSION=${BASE_VER} 不是 release tag 格式，请确认"
fi

# ---------- wolfi / apko ----------
NEW_WOLFI="wolfi/kiali-${NEW_VERSION}.yaml"
check "wolfi: ${NEW_WOLFI} 存在" test -f "$NEW_WOLFI"
check "wolfi: 使用 alauda-mesh/kiali fork 源" grep -q "repository: https://github.com/alauda-mesh/kiali$" "$NEW_WOLFI"
check "wolfi: 构建分支 == kiali-${NEW_VERSION}" grep -q "branch: kiali-${NEW_VERSION}$" "$NEW_WOLFI"
check "wolfi: name/epoch 正确（kiali-${NEW_MINOR_NO_V} / epoch 0）" \
  bash -c "grep -q '^  name: kiali-${NEW_MINOR_NO_V}$' '$NEW_WOLFI' && grep -q '^  epoch: 0$' '$NEW_WOLFI'"
# fork 远端分支存在性（流水线 git-checkout 的硬依赖，缺了必挂）
if FORK_LS="$(git ls-remote "$FORK_KIALI_URL" "refs/heads/kiali-${NEW_VERSION}" 2>/dev/null)"; then
  FORK_HEAD="$(echo "$FORK_LS" | awk '{print $1}')"
  if [[ -n "$FORK_HEAD" ]]; then
    pass "fork: alauda-mesh/kiali 存在分支 kiali-${NEW_VERSION}（head ${FORK_HEAD:0:8}）"
  else
    fail "fork: alauda-mesh/kiali 缺少分支 kiali-${NEW_VERSION}，请先执行 sync-kiali-fork.sh"
  fi
else
  WARNED=$((WARNED+1)); warn "fork: 查询 alauda-mesh/kiali 分支失败（网络问题？），请手动确认分支 kiali-${NEW_VERSION} 存在"
fi
KEEP_COUNT="$(echo "$KEEP_MINORS" | wc -w)"
check "wolfi: 配置文件数量 == ${KEEP_COUNT}" bash -c "[[ \$(ls wolfi/kiali-*.yaml | wc -l) -eq ${KEEP_COUNT} ]]"
NEW_APKO="configs/kiali/v${NEW_VERSION}.apko.yaml"
check "apko: ${NEW_APKO} 存在且引用 kiali=${NEW_VERSION}-r0@local" grep -q "kiali=${NEW_VERSION}-r0@local" "$NEW_APKO"
check "apko: 配置文件数量 == ${KEEP_COUNT}" bash -c "[[ \$(ls configs/kiali/v*.apko.yaml | wc -l) -eq ${KEEP_COUNT} ]]"

# ---------- 汇总 ----------
echo
if [[ $FAIL -gt 0 ]]; then
  echo "RESULT: ${FAIL} 项 FAIL（另有 ${WARNED} 项 WARN）。请修复 FAIL 项后重跑本脚本。"
  exit 1
fi
echo "RESULT: 全部通过（${WARNED} 项 WARN 需在汇报中说明）。下一步: 提交 commit 并按 SKILL.md 步骤 6 汇报。"
