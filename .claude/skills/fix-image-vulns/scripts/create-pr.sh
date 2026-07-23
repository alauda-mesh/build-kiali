#!/usr/bin/env bash
# 步骤 3：push 修复分支并在 alauda-mesh/kiali 创建 PR（base = kiali-<版本> 构建分支）。
# 用法: create-pr.sh <版本> [PR正文文件]
# 幂等：分支已有 PR 时直接复用（迭代轮 push 新 commit 即可）。
# 输出: PR_NUMBER= / PR_URL=，并记录到状态文件（trigger-build.sh 校验合并状态用）。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state

VER="${1:-}"; BODY_FILE="${2:-}"
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "用法: create-pr.sh <版本号 X.Y.Z> [PR正文文件]"
[[ -z "$BODY_FILE" || -f "$BODY_FILE" ]] || die "PR 正文文件不存在: $BODY_FILE"
WT="$ROOT/_output/kiali-fix-${VER}"
[[ -d "$WT" ]] || die "找不到修复 worktree: $WT（请先执行 create-fix-branch.sh）"
command -v gh >/dev/null 2>&1 || die "找不到 gh CLI"
gh auth status >/dev/null 2>&1 || die "gh 未认证。请提示用户在会话中执行: ! gh auth login"

cd "$WT"
BASE_BRANCH="kiali-${VER}"
BRANCH="$(git branch --show-current)"
[[ "$BRANCH" == fix/* ]] || die "worktree 当前分支 ${BRANCH:-<无>} 不是 fix/* 修复分支"
[[ -z "$(git status --porcelain)" ]] || die "worktree 有未提交改动，请先 commit（禁止 amend，一律新建 commit）"
N="$(git rev-list --count "origin/${BASE_BRANCH}..HEAD")"
[[ "$N" -ge 1 ]] || die "相对 origin/${BASE_BRANCH} 没有新 commit，无内容可提 PR"

info "push ${BRANCH} 到 origin ..."
git push -u origin "$BRANCH"

if PR_INFO="$(gh pr view "$BRANCH" --repo "$KIALI_REPO" --json number,url --jq '"\(.number) \(.url)"' 2>/dev/null)" \
   && [[ -n "$PR_INFO" ]]; then
  info "分支 ${BRANCH} 已存在 PR，直接复用"
else
  TITLE="fix: bump vulnerable go modules (kiali ${VER})"
  if [[ -n "$BODY_FILE" ]]; then
    gh pr create --repo "$KIALI_REPO" --base "$BASE_BRANCH" --head "$BRANCH" \
      --title "$TITLE" --body-file "$BODY_FILE" >/dev/null
  else
    # 兜底正文：修复提交列表
    BODY="$(printf '修复镜像漏洞扫描发现的 go.mod 依赖漏洞。\n\n```\n%s\n```\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' \
      "$(git log --oneline "origin/${BASE_BRANCH}..HEAD" | head -20)")"
    gh pr create --repo "$KIALI_REPO" --base "$BASE_BRANCH" --head "$BRANCH" \
      --title "$TITLE" --body "$BODY" >/dev/null
  fi
  PR_INFO="$(gh pr view "$BRANCH" --repo "$KIALI_REPO" --json number,url --jq '"\(.number) \(.url)"')"
fi

PR_NUMBER="${PR_INFO%% *}"
PR_URL="${PR_INFO##* }"
set_state "PR_$(ver_us "$VER")" "$PR_NUMBER"
echo
echo "PR_NUMBER=${PR_NUMBER}"
echo "PR_URL=${PR_URL}"
