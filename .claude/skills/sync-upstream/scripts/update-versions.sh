#!/usr/bin/env bash
# 步骤 2：机械更新版本号（Makefile / CSV / wolfi / apko / operator base 镜像）。
# 不 commit，便于 review。每项修改后都自检，失败项汇总输出并以退出码 2 结束，
# 由模型按输出提示用 Edit 手动补齐。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state

NEW_US="$(minor_us "$NEW_MINOR")"          # 2_29
FAILURES=()

# 记录一项校验：ok "描述" <grep 等命令...>
ok() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "OK   $desc"
  else
    echo "FAIL $desc"
    FAILURES+=("$desc")
  fi
}

# ============ 1. Makefile ============
MK=Makefile
sed -i -E "s|^KIALI_OPERATOR_BUNDLE_VERSION \?= .*|KIALI_OPERATOR_BUNDLE_VERSION ?= ${NEW_VERSION}|" "$MK"
sed -i -E "s|^KIALI_OPERATOR_VERSION \?= .*|KIALI_OPERATOR_VERSION ?= ${NEW_VERSION}|" "$MK"
TODAY="$(date -u +%Y-%m-%dT00:00:00Z)"
sed -i -E "s|^CREATED_AT \?= .*|CREATED_AT ?= ${TODAY}|" "$MK"

# 移除被淘汰版本的变量块与 envsubst 行
for d in $DROP_MINORS; do
  us="$(minor_us "$d")"
  sed -i -E "/^KIALI_${us}_VERSION \?= /d; /^KIALI_${us} \?= /d" "$MK"
  sed -i -E "/^[[:space:]]*KIALI_${us}=\\\$\(KIALI_${us}\) \\\\$/d" "$MK"
done

if [[ "$SAME_MINOR" == "true" ]]; then
  # 同 minor 升级：只更新已有变量的版本号
  sed -i -E "s|^KIALI_${NEW_US}_VERSION \?= .*|KIALI_${NEW_US}_VERSION ?= v${NEW_VERSION}|" "$MK"
else
  # 新 minor：在原最新版本块之前插入新块（保持从新到老的顺序）；已存在则跳过（幂等，支持重跑）
  PREV_MINOR="$(echo "$KEEP_MINORS" | tr ' ' '\n' | grep -vx "$NEW_MINOR" | sort -V | tail -1)"
  PREV_US="$(minor_us "$PREV_MINOR")"
  if ! grep -qE "^KIALI_${NEW_US}_VERSION \?= " "$MK"; then
    awk -v prev="KIALI_${PREV_US}_VERSION ?= " \
        -v l1="KIALI_${NEW_US}_VERSION ?= v${NEW_VERSION}" \
        -v l2="KIALI_${NEW_US} ?= \$(HUB)/kiali:\$(KIALI_${NEW_US}_VERSION)" \
        'index($0, prev) == 1 && !done {print l1; print l2; done=1} {print}' "$MK" >"$MK.tmp" && mv "$MK.tmp" "$MK"
  fi
  # envsubst 行：复用原最新版本行的缩进
  if ! grep -q "KIALI_${NEW_US}=\$(KIALI_${NEW_US})" "$MK"; then
    awk -v prev="KIALI_${PREV_US}=" -v us="KIALI_${NEW_US}" '
      !done && $0 ~ "^[\t ]*" prev {
        line=$0; match(line, /^[\t ]*/)
        print substr(line, 1, RLENGTH) us "=$(" us ") \\"
        done=1
      } {print}' "$MK" >"$MK.tmp" && mv "$MK.tmp" "$MK"
  fi
fi

ok "Makefile: KIALI_OPERATOR_BUNDLE_VERSION ?= ${NEW_VERSION}" grep -q "^KIALI_OPERATOR_BUNDLE_VERSION ?= ${NEW_VERSION}$" "$MK"
ok "Makefile: KIALI_OPERATOR_VERSION ?= ${NEW_VERSION}" grep -q "^KIALI_OPERATOR_VERSION ?= ${NEW_VERSION}$" "$MK"
ok "Makefile: CREATED_AT ?= ${TODAY}" grep -q "^CREATED_AT ?= ${TODAY}$" "$MK"
ok "Makefile: KIALI_${NEW_US}_VERSION ?= v${NEW_VERSION}" grep -q "^KIALI_${NEW_US}_VERSION ?= v${NEW_VERSION}$" "$MK"
ok "Makefile: envsubst 含 KIALI_${NEW_US}" grep -q "KIALI_${NEW_US}=\$(KIALI_${NEW_US})" "$MK"
for d in $DROP_MINORS; do
  us="$(minor_us "$d")"
  ok "Makefile: 已移除 KIALI_${us}" bash -c "! grep -q 'KIALI_${us}' '$MK'"
done

# ============ 2. CSV（relatedImages 与 RELATED_IMAGE_* 环境变量） ============
CSV=kiali-operator-bundle/manifests/kiali.clusterserviceversion.yaml
DROP_US_LIST="$(for d in $DROP_MINORS; do minor_us "$d"; done | paste -sd' ' -)"
# 同 minor 升级无需插入；新条目已存在（重跑场景）时也不再插入（幂等）
SKIP_INSERT="$SAME_MINOR"
grep -q -- "- name: kiali_v${NEW_US}$" "$CSV" && SKIP_INSERT=true
awk -v drops="$DROP_US_LIST" -v new_us="$NEW_US" -v skip_insert="$SKIP_INSERT" '
  BEGIN { n = split(drops, da, " ") }
  {
    # 删除被淘汰版本的条目（name 行 + 紧随的 image/value 行）
    for (i = 1; i <= n; i++) {
      if (da[i] != "" && $0 ~ ("- name: (RELATED_IMAGE_)?kiali_v" da[i] "$")) { getline; next }
    }
    # kiali_default 指向新版本，并在其后插入新版本条目（克隆 default 的两行）
    if ($0 ~ /- name: (RELATED_IMAGE_)?kiali_default$/) {
      name_line = $0
      getline val_line
      gsub(/\$\{KIALI_2_[0-9]+\}/, "${KIALI_" new_us "}", val_line)
      print name_line
      print val_line
      if (skip_insert != "true") {
        ins = name_line
        sub(/kiali_default/, "kiali_v" new_us, ins)
        print ins
        print val_line
      }
      next
    }
    print
  }' "$CSV" >"$CSV.tmp" && mv "$CSV.tmp" "$CSV"

ok "CSV: relatedImages/env 各含 kiali_v${NEW_US}（共 2 处）" \
  bash -c "[[ \$(grep -c -- '- name: \(RELATED_IMAGE_\)\?kiali_v${NEW_US}\$' '$CSV') -eq 2 ]]"
ok "CSV: kiali_default 已指向 \${KIALI_${NEW_US}}（共 4 处引用）" \
  bash -c "[[ \$(grep -c '\${KIALI_${NEW_US}}' '$CSV') -ge 4 ]]"
for d in $DROP_MINORS; do
  us="$(minor_us "$d")"
  ok "CSV: 已移除 kiali_v${us}" bash -c "! grep -q 'KIALI_${us}' '$CSV'"
done

# ============ 3. wolfi 构建配置 ============
TEMPLATE_WOLFI="$(ls wolfi/kiali-*.yaml | sort -V | tail -1)"
NEW_WOLFI="wolfi/kiali-${NEW_VERSION}.yaml"
if [[ "$TEMPLATE_WOLFI" != "$NEW_WOLFI" ]]; then
  cp "$TEMPLATE_WOLFI" "$NEW_WOLFI"
  [[ "$SAME_MINOR" == "true" ]] && rm "$TEMPLATE_WOLFI"
fi
sed -i -E "s|^  name: kiali-[0-9.]+$|  name: kiali-${NEW_MINOR#v}|" "$NEW_WOLFI"
sed -i -E "s|^  version: \".*\"$|  version: \"${NEW_VERSION}\"|" "$NEW_WOLFI"
sed -i -E "s|^  epoch: .*$|  epoch: 0|" "$NEW_WOLFI"
sed -i -E "s|expected-commit: .*$|expected-commit: ${KIALI_COMMIT}|" "$NEW_WOLFI"
for d in $DROP_MINORS; do rm -f wolfi/kiali-"${d#v}".*.yaml; done

ok "wolfi: ${NEW_WOLFI} name=kiali-${NEW_MINOR#v}" grep -q "^  name: kiali-${NEW_MINOR#v}$" "$NEW_WOLFI"
ok "wolfi: ${NEW_WOLFI} version=${NEW_VERSION} epoch=0" \
  bash -c "grep -q '^  version: \"${NEW_VERSION}\"$' '$NEW_WOLFI' && grep -q '^  epoch: 0$' '$NEW_WOLFI'"
ok "wolfi: ${NEW_WOLFI} expected-commit=${KIALI_COMMIT}" grep -q "expected-commit: ${KIALI_COMMIT}" "$NEW_WOLFI"

# ============ 4. apko 镜像配置 ============
TEMPLATE_APKO="$(ls configs/kiali/v*.apko.yaml | sort -V | tail -1)"
NEW_APKO="configs/kiali/v${NEW_VERSION}.apko.yaml"
if [[ "$TEMPLATE_APKO" != "$NEW_APKO" ]]; then
  cp "$TEMPLATE_APKO" "$NEW_APKO"
  [[ "$SAME_MINOR" == "true" ]] && rm "$TEMPLATE_APKO"
fi
sed -i -E "s|kiali=[0-9][^@]*@local|kiali=${NEW_VERSION}-r0@local|" "$NEW_APKO"
for d in $DROP_MINORS; do rm -f configs/kiali/"${d}".*.apko.yaml; done

ok "apko: ${NEW_APKO} kiali=${NEW_VERSION}-r0@local" grep -q "kiali=${NEW_VERSION}-r0@local" "$NEW_APKO"

# ============ 5. operator base 镜像版本 ============
WF_OP=.github/workflows/build-kiali-operator.yaml
LATEST_BASE="$(gh api repos/alauda-mesh/ansible-operator-plugins/releases/latest -q .tag_name 2>/dev/null || true)"
if [[ -n "$LATEST_BASE" ]]; then
  sed -i -E "s|^([[:space:]]*OPERATOR_BASE_IMAGE_VERSION:).*|\1 ${LATEST_BASE}|" "$WF_OP"
  ok "workflows: OPERATOR_BASE_IMAGE_VERSION -> ${LATEST_BASE}" \
    grep -q "OPERATOR_BASE_IMAGE_VERSION: ${LATEST_BASE}" "$WF_OP"
else
  warn "gh 查询 alauda-mesh/ansible-operator-plugins 最新 release 失败，OPERATOR_BASE_IMAGE_VERSION 保持原值，需手动确认（https://github.com/alauda-mesh/ansible-operator-plugins/releases）"
fi

# ============ 汇总 ============
echo
echo "本脚本产生的变更:"
git diff --stat
echo
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "PATTERN_MISMATCH: 以下 ${#FAILURES[@]} 项未能自动完成，请用 Edit 手动修改后再继续:"
  printf ' - %s\n' "${FAILURES[@]}"
  exit 2
fi
echo "DONE: 机械更新全部完成。下一步: 按 SKILL.md 步骤 3 编辑三条 workflow 并审阅 wolfi/CSV。"
