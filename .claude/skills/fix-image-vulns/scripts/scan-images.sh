#!/usr/bin/env bash
# 步骤 1b / 步骤 6：本地 trivy 扫描状态文件中的镜像，并按修复责任分类。
# kiali 二进制打包成 APK 装进镜像，trivy 默认的 --detection-priority precise 会把
# 它当 os 包、跳过 go 依赖分析，因此固定使用 comprehensive；扫描地址把发布
# registry（build-harbor.alauda.cn）替换为可匿名拉取的 registry.alauda.cn:60070。
# 分类:
#   OS_REPORT_ONLY  os-pkgs（wolfi 基础层）   → 不修复，如实报告
#   GO_STDLIB       gobinary PkgName=stdlib   → 不修复（构建不固定 go 版本，重建即带最新 go），如实报告
#   GO_MODULE       gobinary 其他依赖库       → 修 go.mod（本 skill 的修复对象）
#   UNKNOWN         其他                      → 人工判断
# 输出: 每镜像明细 + go.mod 修复目标聚合 + SUMMARY + RESULT: CLEAN|REPORT_ONLY|FIX_NEEDED
# 退出码: 0=扫描完成（无论结论） 非0=扫描失败
# 注意: 拉镜像+扫描可能要几分钟，调用方把 Bash timeout 设为 600000。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state

TSV="$VULN_DIR/vulns-round${ROUND}.tsv"
: >"$TSV"

for img in $IMAGES; do
  ref="$(scan_ref "$img")"
  tag="${img##*:}"
  ver="$(image_version "$img")" || die "无法从 $img 解析版本号"
  out="$VULN_DIR/scan-round${ROUND}-${tag}.json"
  log="$VULN_DIR/trivy-round${ROUND}-${tag}.log"

  info "扫描 ${ref}（第 ${ROUND} 轮）..."
  scanned=""
  for attempt in 1 2; do
    if trivy image --detection-priority comprehensive --format json --output "$out" \
         --timeout 15m --quiet "$ref" 2>"$log"; then
      scanned=1; break
    fi
    [[ "$attempt" -lt 2 ]] && { warn "扫描失败，15s 后重试"; sleep 15; }
  done
  if [[ -z "$scanned" ]]; then
    tail -5 "$log" >&2
    die "trivy 连续扫描失败: $ref（完整日志: $log）"
  fi

  # 提取为 TSV: 分类/版本/包/装机版本/修复候选(逗号分隔,去v前缀)/CVE/严重度
  rows="$(jq -r --arg ver "$ver" '
    def fixes: [(.FixedVersion // "") | split(",")[] | gsub("^\\s+|\\s+$"; "") | sub("^v"; "") | select(. != "")];
    [ .Results[]? as $r | ($r.Vulnerabilities // [])[]
      | { cat: (if $r.Class == "os-pkgs" then "OS_REPORT_ONLY"
                elif ($r.Type // "") == "gobinary" and .PkgName == "stdlib" then "GO_STDLIB"
                elif ($r.Type // "") == "gobinary" then "GO_MODULE"
                else "UNKNOWN" end),
          pkg: .PkgName, inst: (.InstalledVersion // "?"),
          fix: (fixes | join(",")), id: .VulnerabilityID, sev: (.Severity // "?") }
    ] | .[] | [.cat, $ver, .pkg, .inst, .fix, .id, .sev] | @tsv' "$out")"

  n=0
  if [[ -n "$rows" ]]; then
    printf '%s\n' "$rows" >>"$TSV"
    n="$(wc -l <<<"$rows")"
  fi
  echo
  echo "--- ${img}（漏洞 ${n} 条）---"
  [[ -n "$rows" ]] && sort <<<"$rows" | awk -F'\t' \
    '{printf "  [%s] %s %s %s %s → %s\n", $1, $3, $6, $7, $4, ($5 == "" ? "（无修复版本）" : $5)}'
done

# 同一版本的多个镜像 tag 会产生重复行，聚合前去重
sort -u "$TSV" -o "$TSV"
count_cat() { awk -F'\t' -v c="$1" '$1 == c' "$TSV" | wc -l; }
TOTAL="$(wc -l <"$TSV")"
GOMOD="$(count_cat GO_MODULE)"; STDLIB="$(count_cat GO_STDLIB)"
OS="$(count_cat OS_REPORT_ONLY)"; UNK="$(count_cat UNKNOWN)"

if [[ "$GOMOD" -gt 0 ]]; then
  echo
  echo "--- go.mod 修复目标（按 版本/包 聚合；目标 = 覆盖全部 CVE 的最高修复候选，go get 时注意加 v 前缀）---"
  while IFS=$'\t' read -r ver pkg; do
    inst="$(awk -F'\t' -v v="$ver" -v p="$pkg" '$1=="GO_MODULE" && $2==v && $3==p {print $4; exit}' "$TSV")"
    cves="$(awk -F'\t' -v v="$ver" -v p="$pkg" '$1=="GO_MODULE" && $2==v && $3==p' "$TSV" | wc -l)"
    # 该包全部 CVE 都无修复版本时 grep 会选不出任何行，pipefail 下不能让它中断脚本
    cands="$(awk -F'\t' -v v="$ver" -v p="$pkg" '$1=="GO_MODULE" && $2==v && $3==p {print $5}' "$TSV" \
      | tr ',' '\n' | grep -v '^$' | sort -uV || true)"
    if [[ -n "$cands" ]]; then
      target="$(tail -1 <<<"$cands")"
      echo "  [$ver] $pkg $inst  CVE×${cves}  候选: $(paste -sd'/' - <<<"$cands")  → go get ${pkg}@v${target}"
    else
      echo "  [$ver] $pkg $inst  CVE×${cves}  （无修复版本，升级修不了，最终汇报中如实说明）"
    fi
  done < <(awk -F'\t' '$1=="GO_MODULE" {print $2 "\t" $3}' "$TSV" | sort -u)
fi

echo
echo "SUMMARY: TOTAL=${TOTAL} GO_MODULE=${GOMOD} GO_STDLIB=${STDLIB} OS_REPORT_ONLY=${OS} UNKNOWN=${UNK}"
if [[ "$TOTAL" -eq 0 ]]; then
  echo "RESULT: CLEAN"
elif [[ "$GOMOD" -eq 0 && "$UNK" -eq 0 ]]; then
  echo "RESULT: REPORT_ONLY（只有 os / go stdlib 级漏洞，不在修复范围，如实报告；stdlib 类重新构建即可消除）"
else
  FIX_VERSIONS="$(awk -F'\t' '$1=="GO_MODULE" || $1=="UNKNOWN" {print $2}' "$TSV" | sort -uV | paste -sd' ' -)"
  echo "RESULT: FIX_NEEDED"
  echo "FIX_VERSIONS=${FIX_VERSIONS}"
fi
