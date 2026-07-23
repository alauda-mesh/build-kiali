---
name: sync-upstream
description: 同步上游 kiali/kiali-operator 指定 tag 到本仓库（alauda-mesh/build-kiali）。完成：复制上游源码并裁剪版本（roles 只保留最新 3 个版本 + default）、确保 alauda-mesh/kiali fork 上存在对应的 kiali-<版本> 构建分支、更新 VERSION/Makefile/CSV/CRD、生成新版本 wolfi 与 apko 构建配置、更新三条 GitHub 流水线、创建 PR 并监控流水线（失败时分析原因并修复）。仅限用户显式通过 /sync-upstream 调用。
argument-hint: "[上游 tag] [目标分支]，例如: v2.27.1 master"
disable-model-invocation: true
---

# 同步上游 kiali-operator（kiali → alauda-mesh/build-kiali）

把 https://github.com/kiali/kiali-operator 的指定 tag 同步到本仓库的目标分支。
下文的 `$SKILL_DIR` 指本 skill 的根目录（即调用时提示的 Base directory）。

## 参数

- 上游 tag：`$0`（形如 `v2.28.0`）
- 目标分支：`$1`（通常为 `master`）

两个参数都必须明确。若任一为空，用 AskUserQuestion 向用户询问（可先用 `git ls-remote --tags https://github.com/kiali/kiali-operator.git` 查出最新 tag 作为推荐项，目标分支推荐 `master`），不要自行猜测。

## 背景知识

- 本仓库**不是** kiali-operator 的 git fork，而是"复制上游源码子集 + 自建构建体系"：`kiali-operator/` 存放上游的 roles/playbooks/watches，`kiali-operator-bundle/` 是 ACP 定制的 OLM bundle，`wolfi/` + `configs/kiali/` 构建 kiali server 镜像，`.github/workflows/` 下有三条流水线（Build Kiali Images / Build Kiali Operator / Build Kiali Operator Bundle）。
- **上游版本模型**：上游 `roles/` 下的 `vX.Y` 是历史版本快照，只在 OSSM 对齐版本创建（如 v2.11/v2.17/v2.22/v2.27，间隔 5~6 个 minor）；`default` 即当前最新版。因此**同步的 tag 必须带有自己 minor 的快照**（sync.sh 会校验并在不满足时拒绝）——否则 default 与最新快照版本不一致，会引入一个从未构建过的 kiali 镜像依赖。用户给的 tag 被拒绝时，把脚本说明转告用户并列出可选 tag。
- **版本保留策略**：`roles/` 下最多保留最新 3 个版本快照 + `default`。同步新 minor 版本时移除最老的一个；同 minor 的 patch 升级不增减版本。`playbooks/kiali-default-supported-images.yml` 与版本目录保持一致（`ossmconsole-default-supported-images.yml` 不用裁剪）。
- ACP 不包含 OSSMConsole，也不部署 OpenShift 专属资源；我们的 CSV 是从上游 `manifests/kiali-ossm` 的 CSV 裁剪定制来的，同步时只合入通用变化。
- kiali server（kiali/kiali）与 operator（kiali/kiali-operator）的 tag 版本号保持一致。**kiali server 镜像的源码来自 alauda-mesh/kiali fork 的 `kiali-<版本>` 分支**（wolfi 的 git-checkout 不再使用上游 tag + expected-commit），分支基于上游 kiali/kiali 的同版本号 tag 创建，之后允许在分支上追加 CVE/hotfix 提交（因此分支头可能领先于 tag）。创建/push 分支使用本地的 fork 克隆，默认取与本仓库同级的 `../kiali` 目录（`KIALI_REPO_DIR` 可覆盖）。
- 脚本间通过 `_output/sync-state.env` 传递状态（KEEP/DROP 版本列表等），`_output/` 已在 gitignore 中。
- 全程禁止 `git commit --amend`，一律创建新 commit。build-kiali 的同步分支在步骤 7 之前不要 push、不要建 PR；步骤 2 对 alauda-mesh/kiali 的分支 push 是例外（分支内容与上游 tag 完全一致，无自定义改动，且流水线构建依赖它先存在）。

## 步骤 1：同步上游源码

```bash
bash "$SKILL_DIR/scripts/sync.sh" <上游tag> <目标分支>
```

脚本会自动：前置检查（工作区干净、tag 格式）→ 基于 `origin/<目标分支>` 创建 `sync/<tag>` 分支 → 浅克隆上游到 `_output/upstream/` → 解析 kiali/kiali tag 的 commit → 计算保留/移除版本 → 复制 roles/playbooks/watches → 裁剪 roles 与 kiali-default-supported-images.yml → 更新 VERSION → 复制上游 CRD → 自动提交一个 commit。

- **退出码 0（SYNCED）**：成功，输出 KEEP/DROP 版本列表和变更概览，继续步骤 2。若输出含 `RESTORED`（上游已删除某个我们要保留的版本目录，脚本已从原分支恢复），在最终汇报中特别标注。
- **退出码 1**：前置条件问题（工作区不干净、分支已存在、tag 不存在等），把报错原样告知用户并询问如何处理，不要擅自 stash 或删分支。

## 步骤 2：同步 kiali fork 构建分支

```bash
bash "$SKILL_DIR/scripts/sync-kiali-fork.sh"
```

wolfi 构建从 alauda-mesh/kiali 的 `kiali-<版本>` 分支拉取源码，本步骤确保该分支存在（这是步骤 7 流水线 git-checkout 的硬依赖）：

- **BRANCH_EXISTS（退出码 0）**：远端分支已存在，脚本不做任何修改。若输出 INFO 提示分支头与上游 tag 不一致，说明分支带有 hotfix 提交，属正常情况，记入汇报；
- **BRANCH_CREATED（退出码 0）**：远端没有该分支，脚本已在本地同级 kiali 克隆中基于上游 tag `v<版本>` 创建分支并 push 到 alauda-mesh/kiali（创建分支不切换该克隆的工作区，push 后会校验远端分支头）；
- **退出码 1**：前置问题（本地 kiali 克隆缺失、origin 不是 alauda-mesh/kiali、本地同名分支指向异常、push 失败等）。把报错原样告知用户；本地克隆位置不同时可用 `KIALI_REPO_DIR=<路径>` 重跑。

被淘汰版本对应的老分支保留不删（历史构建可追溯）。

## 步骤 3：机械更新版本号

```bash
bash "$SKILL_DIR/scripts/update-versions.sh"
```

脚本自动完成确定性的版本号修改（不 commit，便于 review）：

- Makefile：`KIALI_OPERATOR_BUNDLE_VERSION`/`KIALI_OPERATOR_VERSION`/`CREATED_AT`（今天）；新增 `KIALI_2_XX` 变量块和 envsubst 行，移除被淘汰版本的；
- CSV：`kiali_default` 指向新版本；新增/移除 `relatedImages` 条目和 `RELATED_IMAGE_kiali_*` 环境变量；
- wolfi/configs：以最新版本文件为模板生成新版本的 `wolfi/kiali-<版本>.yaml`（改 name/version/epoch=0，并把构建分支 `branch:` 与日志 echo 行替换为 `kiali-<新版本>`）和 `configs/kiali/v<版本>.apko.yaml`，删除被淘汰版本的文件；
- `build-kiali-operator.yaml` 的 `OPERATOR_BASE_IMAGE_VERSION` ← alauda-mesh/ansible-operator-plugins 的最新 release tag（gh 查询失败时输出 WARN 并保持原值，此时手动查 https://github.com/alauda-mesh/ansible-operator-plugins/releases 后用 Edit 修改）。

**退出码 2（PATTERN_MISMATCH）**：某些文件结构变了导致脚本没匹配上，输出会逐项列出 `FAIL` 的修改点，用 Edit 手动完成这些项（参照输出中的期望值），其余已完成的项不要重复改。

## 步骤 4：更新流水线与审阅（模型判断）

脚本只改了确定性内容，以下需要你用 Edit 完成（新增 minor 版本时才需要；同 minor patch 升级只需核对版本号字面量）：

1. `.github/workflows/build-kiali.yaml`：`run-name` 中的版本列表、`workflow_dispatch` 新增 `epoch_v2_XX` 输入并移除被淘汰的、`Set version matrix` 步骤中对应的 `find_version` 分支、`Determine publish tag` 的 case 分支；
2. `.github/workflows/build-bundle.yaml`：`run-name`（格式串与参数序号）、新增 `kiali_v2_XX_tag` 输入并移除被淘汰的、`tag`/`operator_tag` 输入的 default 改为新版本、`Determine image version` 步骤新增 `KIALI_2_XX_VERSION` 导出并移除被淘汰的；
3. `.github/workflows/build-kiali-operator.yaml`：`run-name` 中的版本字面量改为新版本。

然后审阅两处生成/合并内容：

4. **wolfi 构建步骤**：Read 新生成的 `wolfi/kiali-<版本>.yaml`。`branch:` 行与日志 echo 行已由脚本替换为新分支，但它复制自旧版本模板，新版本 kiali 的前端构建工具链可能变化（例如 v2.22 开始需要 corepack 启用 Yarn 4），检查注释与构建步骤是否仍适用；同时把注释里引用的旧版本号改写为新版本（残留的旧版本号会在该版本未来被淘汰时触发 check-leftovers 的 FAIL）。不确定就查上游 kiali 仓库对应 tag 的 `make/Makefile.build.mk`（`clean-all`/`build-ui`/`.ensure-yarn-version` 目标）与 `frontend/package.json` 的 `packageManager`、`engines.node`；
5. **CSV 语义合并**：

```bash
bash "$SKILL_DIR/scripts/diff-upstream.sh"
```

脚本输出上游两个 tag 之间 kiali-ossm CSV 的 diff 和 requirements.yml 的 diff。逐条分析 CSV diff：与 kiali operator 部署相关的通用变化（容器 args、env、RBAC 权限、alm-examples、描述文本）要用 Edit 合入我们的 `kiali-operator-bundle/manifests/kiali.clusterserviceversion.yaml`；OSSMConsole、OpenShift 专属资源（oauth、route、console 等）的变化跳过。requirements.yml 有 diff 时把上游文件复制过来。拿不准的改动停下来向用户提问。

## 步骤 5：一致性校验

```bash
bash "$SKILL_DIR/scripts/check-leftovers.sh"
```

脚本逐项校验：VERSION/Makefile/CSV/三条 workflow/wolfi/configs/roles/supported-images 中新版本是否齐全、被淘汰版本是否残留、alauda-mesh/kiali 上构建分支是否存在。输出 `PASS`/`FAIL`/`WARN` 列表：

- **FAIL**：必须修复（通常是步骤 4 的遗漏；fork 分支缺失则回到步骤 2），修完重跑本脚本直到无 FAIL；
- **WARN**（roles/、原样复制的 CRD 等上游内容里出现老版本号）：逐条判断，属上游自带内容可保留并在汇报中说明。已知的良性例子：CRD 里的 `DEPRECATED AFTER vX.Y` 弃用文案（指配置项弃用时间点，不是版本快照残留）、`ossmconsole-default-supported-images.yml` 里的老版本行。

## 步骤 6：提交与汇报

把步骤 3～5 的全部修改提交为一个新 commit（如 `chore: bump kiali to <tag>`；若 CSV 语义合并改动较大可单独一个 commit）。然后向用户汇报（这是用户 review 的依据）：

1. 同步分支名、保留/移除的版本列表、是否有 RESTORED 恢复项；
2. kiali fork 构建分支状态（BRANCH_CREATED / BRANCH_EXISTS，分支头 commit；分支头领先上游 tag 时说明其包含的 hotfix）；
3. Makefile/CSV/流水线的版本变更概要，`OPERATOR_BASE_IMAGE_VERSION` 的新值；
4. wolfi 构建步骤审阅结论（是否沿用模板、有无工具链调整）；
5. CSV 上游 diff 逐条结论（合入了什么 / 为什么跳过）；
6. check-leftovers 的 WARN 项说明。

## 步骤 7：创建 PR 并监控三条流水线

先把 PR 描述写进临时文件（scratchpad 下，如 `pr-body.md`）：内容取步骤 6 汇报的精简版，结尾加一行 `🤖 Generated with [Claude Code](https://claude.com/claude-code)`。然后：

```bash
bash "$SKILL_DIR/scripts/create-pr.sh" <PR正文文件>
```

脚本会 push 同步分支并用 gh 创建 PR（分支已有 PR 时幂等复用），输出 `PR_NUMBER=`/`PR_URL=`。若报 gh 未认证，提示用户执行 `! gh auth login` 后重试。

接着监控三条流水线（Build Kiali Images / Build Kiali Operator / Build Kiali Operator Bundle）。self-hosted runner 的多平台构建通常需要 10～30 分钟，**必须用后台方式运行**（Bash 工具的 `run_in_background: true`）：

```bash
bash "$SKILL_DIR/scripts/watch-pipelines.sh"
```

注意：三条 workflow 的 `paths` 过滤按**整个 PR 的 diff** 评估，因此之后每次 push（包括只改文档的 commit）都会重新触发全部三条流水线——修复/补充要攒成一批一次 push。watch-pipelines.sh 每轮都会重取 PR 最新 head，监控运行中 push 无需重启它；只有在它已退出（如 PIPELINE_FAILED 后修复重推）时才需要重新后台运行。

按退出结果处理：

- **PIPELINE_SUCCESS（0）**：全部成功，把各流水线链接加入最终汇报；
- **PIPELINE_FAILED（2）**：输出已附失败 job 概览与日志摘要。分析失败原因：定位失败 step，判断是本次同步引入（新版本源码构建不兼容、前端工具链变化、kiali fork 分支缺失或内容问题导致 git-checkout 失败、CSV/bundle 校验失败、workflow 编辑错误）还是环境问题（runner、registry 登录、代理）。需要更多日志时用 `gh run view <run-id> --repo alauda-mesh/build-kiali --log-failed`。属同步引入的问题：修复 → 新 commit → `git push origin HEAD`（PR 会自动触发新一轮流水线）→ 重新后台运行 watch-pipelines.sh；拿不准的修复先向用户提问；
- **PIPELINE_TIMEOUT（3）**：告知用户流水线仍在运行，附 run 链接；
- **PIPELINE_NOT_FOUND（4）**：按脚本提示排查（runner 不在线、paths 未触发），如实告知用户；
- **其他退出码（如 1）**：脚本自身异常（历史上出现过 gh 瞬时网络错误被 `set -e` 终止，已在脚本内加重试防护），读后台输出定位原因，必要时修脚本后重新后台运行。

最后补充汇报：PR 链接 + 三条流水线结果（成功链接 / 失败原因分析）。到此流程结束，等用户 review 与合并；不要自行 merge PR。
