#!/usr/bin/env bash
# 步骤 2b：在修复 worktree 中升级 go.mod 依赖并验证构建。
# 用法: gomod-bump.sh <worktree目录> <module@vX.Y.Z> [module@vX.Y.Z ...]
#   例: gomod-bump.sh _output/kiali-fix-2.22.2 golang.org/x/net@v0.56.0 golang.org/x/crypto@v0.52.0
# kiali 不是 vendor 模式：go get → go mod tidy → go build ./... 即可验证。
# 前端（make build-ui）与 go.mod 无关，流水线里单独构建，这里不涉及。
# 版本号必须带 v 前缀（trivy 给的修复候选没有 v，拼参数时要加上）。
# 退出码: 0=构建验证通过（RESULT: BUILD_OK） 非0=某一步失败（保留现场供分析）

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[[ $# -ge 2 ]] || die "用法: gomod-bump.sh <worktree目录> <module@version ...>"
WT="$1"; shift
[[ -f "$WT/go.mod" ]] || die "$WT 不是 go 模块目录（先执行 create-fix-branch.sh）"
command -v go >/dev/null 2>&1 || die "找不到 go 工具链"

cd "$WT"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"   # 与流水线 env 一致
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"                # go.mod 要求更高版本时自动获取

info "go get $*"
go get "$@"
info "go mod tidy"
go mod tidy
# kiali 用 go:embed all:build 内嵌前端产物（yarn 构建生成，本地没有）。放一个
# 占位文件让 embed 能编译；frontend/build 在 kiali 的 .gitignore 里，不会被提交。
mkdir -p frontend/build
[[ -n "$(ls -A frontend/build)" ]] || touch frontend/build/.claude-build-stub
info "go build ./...（构建验证，首次会下载依赖，需要几分钟）"
go build ./...

echo
echo "实际落位版本（依赖间约束可能使其高于请求版本，属正常）:"
for spec in "$@"; do
  mod="${spec%@*}"
  echo "  $(go list -m "$mod" 2>/dev/null || echo "$mod （已不在依赖图中）")"
done
echo
echo "变更文件:"
git status --short
echo "RESULT: BUILD_OK"
