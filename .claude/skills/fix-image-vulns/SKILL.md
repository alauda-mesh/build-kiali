---
name: fix-image-vulns
description: 修复 Build Kiali Images 流水线（.github/workflows/build-kiali.yaml）构建的 kiali server 镜像安全漏洞。输入流水线 run（ID/URL）或 1~3 个镜像地址，完成：本地 trivy 扫描（--detection-priority comprehensive）与分类、基于 alauda-mesh/kiali 构建分支升级 go.mod 修复漏洞库、创建 PR 待用户合并、按 epoch 触发流水线重建、回归扫描（最多 3 轮）。os 与 go stdlib 级漏洞只报告不修复；kiali-operator / kiali-operator-bundle 镜像不在范围。仅限用户显式通过 /fix-image-vulns 调用。
argument-hint: "[RUN_ID | run URL | 镜像×1~3]，例如: /fix-image-vulns build-harbor.alauda.cn/asm/kiali:v2.22.2-rt.1"
disable-model-invocation: true
---

# 修复 kiali 镜像漏洞

对指定的 kiali server 镜像做漏洞扫描，修复 go.mod 依赖漏洞，直到镜像干净或达到轮次上限。
下文的 `$SKILL_DIR` 指本 skill 的根目录（即调用时提示的 Base directory）。

## 参数

- `$ARGUMENTS`：Build Kiali Images 流水线 run（纯数字 ID 或 run URL），或 1~3 个完整镜像地址（空格分隔），如 `build-harbor.alauda.cn/asm/kiali:v2.22.2-rt.1`。
- 参数里可能混有给助手的备注文字（如"顺便记录坑点"），只把 run / 镜像地址部分传给 resolve-images.sh，备注按用户附加要求执行。
- 参数为空时用 AskUserQuestion 向用户询问，不要自行猜测。
- 只处理 kiali server 镜像；kiali-operator / kiali-operator-bundle 的漏洞不在本 skill 范围（脚本会拦截并说明）。

## 背景知识

kiali 镜像 = wolfi 基础层（apko 组装）+ kiali APK 包（go 二进制 + 前端静态资源，源码来自 alauda-mesh/kiali fork 的 `kiali-<版本>` 分支）。漏洞按来源分类处理：

| 分类 | 表现 | 处理 |
| --- | --- | --- |
| OS_REPORT_ONLY | os-pkgs（wolfi 基础层的 apk 包） | **不修复**，最终汇报如实列出 |
| GO_STDLIB | gobinary 中 PkgName=stdlib | **不修复**（构建不固定 go 版本，重新构建自动带最新 go），如实报告 |
| GO_MODULE | gobinary 中的依赖库 | **修复**：升级 fork 构建分支的 go.mod |
| UNKNOWN | 其他 | 人工判断后决定 |

- **必须本地 trivy 扫描**：kiali 二进制打包成 APK 装进镜像，trivy 默认的 `--detection-priority precise` 会把它当 os 包、跳过 go 依赖分析；必须用 `comprehensive`。内部扫描服务（192.168.25.100:8888）固定 precise，不能用于 kiali。扫描时发布地址 `build-harbor.alauda.cn` 换成可匿名拉取的 `registry.alauda.cn:60070`（脚本均已内置）。
- **版本链路**：镜像 tag `v2.22.2-rt.1` → 版本 `2.22.2` → fork 构建分支 `kiali-2.22.2` → dispatch 输入 `epoch_v2_22` → 重建后新 tag `v2.22.2-r<epoch>`。修复 PR 的 base 是构建分支，不是 master。
- 修复分支用 git worktree 检出到 `build-kiali/_output/kiali-fix-<版本>`（gitignore 内），不打扰同级 kiali 克隆的当前工作区。
- gh 命令必须显式 `--repo`（脚本已内置）；全程禁止 `git commit --amend`，一律新建 commit。
- 修复轮次上限 3 轮（首轮 + 回归后最多再修 2 次），修不完就如实汇报。
- 状态文件 `_output/vuln-state.env` 串联各脚本（镜像列表、版本、轮次、PR、run）。

## 步骤 0：环境预检

```bash
bash "$SKILL_DIR/scripts/preflight.sh"
```

退出码 3 = trivy 缺失或版本过旧：按脚本输出提示用户安装/升级，本回合到此结束，等用户处理完再重跑本脚本继续。其他 die（jq/gh 缺失、未认证）同样先让用户补齐环境。WARN 项（go、kiali 克隆）不阻塞扫描，仅在进入修复阶段前需要补齐。

## 步骤 1：漏洞检测

```bash
bash "$SKILL_DIR/scripts/resolve-images.sh" <用户输入>     # 解析镜像列表，初始化状态
bash "$SKILL_DIR/scripts/scan-images.sh"                  # 逐镜像扫描 + 分类
```

拉镜像+扫描可能要几分钟，scan 的 Bash 调用把 timeout 设为 600000。无论结果如何，先向用户输出扫描摘要（每镜像漏洞数、SUMMARY 分类计数、go.mod 修复目标表）。然后按 `RESULT:` 分支：

- **CLEAN**：无漏洞，汇报后直接结束；
- **REPORT_ONLY**：剩余均为不修复项——os / stdlib 级漏洞，或无修复版本的 go module（没有可升级目标，开修复轮也是空转）。列出明细并说明原因（stdlib 类可提示用户：重新触发一次构建即可带最新 go 消除），结束；
- **FIX_NEEDED**：对 `FIX_VERSIONS` 中的每个版本执行步骤 2~3。

## 步骤 2：修复 go.mod（逐版本）

```bash
bash "$SKILL_DIR/scripts/create-fix-branch.sh" <版本>      # 输出 WORKTREE= / BRANCH=
bash "$SKILL_DIR/scripts/gomod-bump.sh" <worktree> <module@v版本> [module@v版本 ...]
```

升级目标以 scan 输出的"go.mod 修复目标"表为准（目标 = 覆盖该包全部 CVE 的最高修复候选；trivy 给的候选没有 v 前缀，`go get` 时要加上）。注意：

- 库之间有依赖约束，实际落位版本可能高于 trivy 给的修复候选，属正常，脚本会打印实际版本；
- `go get` 报 `A@vX requires B@vY, not B@vZ`：把 B 的目标提到 vY 重跑（vY 更高，CVE 覆盖不受影响）。`golang.org/x/*` 系列互相牵制时常见（如 x/net 新版会牵动 x/sys、x/crypto）；同批多版本依次修复时，把前面版本实测学到的落位版本直接用于后续版本，省一轮报错重试；
- 同一发布系列的包（如 `go.opentelemetry.io/otel` 与 `otel/sdk`）版本要对齐，统一取其中最高者；
- `go get` 可能顺带提升 go.mod 的 go directive（如 1.24 → 1.25）及若干间接依赖，构建流水线不固定 go 版本，属正常连带变更，在 PR 正文说明一句即可；
- 无修复版本的 CVE 升级修不了，记入最终汇报的"未修复项"；
- 构建失败时分析原因（版本冲突、新版本要求更高 go、API 变更），能明确解决就解决，拿不准就带着报错向用户提问，不要凭猜测大版本连锁升级。

完成后在 worktree 内提交（禁止 amend）：

```bash
git -C <worktree> commit -am "fix: bump vulnerable go modules (kiali <版本>)"
```

## 步骤 3：创建 PR（逐版本）

PR 正文写进 scratchpad 临时文件（如 `pr-body-<版本>.md`）：扫描摘要（镜像、分类计数）+ 修复表（每项：模块、版本变化、覆盖的 CVE）+ 本地 `go build ./...` 验证说明 + 结尾一行 `🤖 Generated with [Claude Code](https://claude.com/claude-code)`。然后：

```bash
bash "$SKILL_DIR/scripts/create-pr.sh" <版本> <正文文件>    # 输出 PR_NUMBER= / PR_URL=
```

幂等：分支已有 PR 时复用，迭代轮只需推新 commit 后重跑。

## 步骤 4：等用户 review 与合并

向用户汇报每个 PR 的链接与修复内容摘要，请用户 review、没问题就合并。**本回合到此结束**：不要自行 merge，不要继续步骤 5。用户答复已合并、或明确授权代合并（此时用 `gh pr merge <PR号> --repo alauda-mesh/kiali --merge` 逐个合并）后再继续；未获授权不得自行 merge。

## 步骤 5：触发并监控流水线

```bash
bash "$SKILL_DIR/scripts/trigger-build.sh"        # 校验 PR 已 MERGED，epoch=当前 UTC 时间，输出 BUILD_RUN_ID
bash "$SKILL_DIR/scripts/watch-build.sh"          # 必须后台运行（run_in_background: true），10~30 分钟
```

epoch 用当前时间（YYYYmmddHHMM）保证不与历史重复，无需查询以前的 epoch；只给受影响版本填 epoch。按 watch 结果处理：

- **PIPELINE_SUCCESS（退出码 0）**：状态中 IMAGES 已换成新镜像、ROUND+1，进入步骤 6；
- **PIPELINE_FAILED（退出码 2）**：脚本已附失败概览与日志摘要。分析原因：是本次修复引入（go 依赖升级编译错）还是环境问题（runner、registry、代理、melange/apko 工具链）；修复方向拿不准时向用户提问，不要盲目改了就重推；
- **PIPELINE_TIMEOUT（退出码 3）**：告知用户流水线仍在运行，附 run 链接。

## 步骤 6：回归扫描与迭代

```bash
bash "$SKILL_DIR/scripts/scan-images.sh"          # 状态已指向新镜像，即回归扫描
```

- **CLEAN / REPORT_ONLY**：修复完成，进入最终汇报（剩余项全部为"无修复版本"的 go module 时 scan 会判 REPORT_ONLY，不要再开修复轮）；
- **FIX_NEEDED**：先分析为什么还有漏洞（上轮目标版本仍带 CVE？升级未生效？新版本引入新漏洞？），再回到步骤 2 继续（ROUND 已 +1，会创建新一轮修复分支）→ 步骤 3 → 4 → 5。
- 回归对比时的正常现象：同一模块同一版本在不同镜像报告可能不一致——某镜像的二进制未实际链接该模块时（build info 无记录）就不报，不代表扫描失灵。

**最多 3 轮修复**。到限仍未清零时停止，如实汇报剩余漏洞、已尝试的措施和失败原因，让用户决策。

## 最终汇报

用清晰列表汇报：

1. 目标镜像与首轮扫描摘要（总数、分类计数）；
2. 修复清单：每项模块名、版本变化、覆盖的 CVE、PR 链接；
3. 剩余未修复项：os / stdlib 级漏洞明细（注明不在修复范围）、无修复版本或修不掉的项及原因；
4. 流水线 run、最终镜像名与回归扫描结论。

收尾清理（可选，PR 已合并后 worktree 无保留价值）：`git -C <kiali克隆> worktree remove <build-kiali>/_output/kiali-fix-<版本>`，残留引用用 `git -C <kiali克隆> worktree prune` 清掉。
