## 同步

### ansible-operator

见 [alauda-mesh/ansible-operator-plugins](https://github.com/alauda-mesh/ansible-operator-plugins)

## kiali-operator

同步 `github.com/kiali/kiali-operator`，修改 kiali-operator-bundle/manifests 下的 CSV，并且

1. 移除 `roles/` 下不需要的版本
2. 移除 `kiali-default-supported-images.yml` 下不需要的版本
3. 修改 Makefile 中的 CREATED_AT

## 版本升级

使用 Claude Code skill [`sync-upstream`](.claude/skills/sync-upstream/SKILL.md)（仅显式调用）同步上游 [kiali/kiali-operator](https://github.com/kiali/kiali-operator) 到本仓库，自动完成：源码复制与版本裁剪（保留最新 3 个版本快照 + default）、[alauda-mesh/kiali](https://github.com/alauda-mesh/kiali) 构建分支（`kiali-<版本>`）创建、VERSION/Makefile/CSV/CRD/wolfi/apko/流水线的版本更新、一致性校验、创建 PR 并监控三条流水线。

用法（在仓库根目录的 Claude Code 会话中）：

```
/sync-upstream v2.27.1 master
```

- 参数 1：上游 tag，其 minor 必须拥有 `roles/vX.Y` 版本快照（OSSM 对齐版本，如 v2.17/v2.22/v2.27）
- 参数 2：目标分支，通常为 `master`

同步完成后 review 并合并 skill 创建的 `sync/<tag>` PR 即可。

## 漏洞修复

使用 Claude Code skill [`fix-image-vulns`](.claude/skills/fix-image-vulns/SKILL.md)（仅显式调用）修复 Build Kiali Images 流水线构建的 kiali server 镜像漏洞（kiali-operator / operator-bundle 镜像不在范围）：本地 trivy 扫描并分类（os 与 go stdlib 级只报告不修复，go.mod 依赖漏洞修复）→ 基于 [alauda-mesh/kiali](https://github.com/alauda-mesh/kiali) 的 `kiali-<版本>` 构建分支创建修复 PR → 用户 review 合并后按 epoch 触发流水线重建 → 回归扫描（最多 3 轮修复）。

用法（在仓库根目录的 Claude Code 会话中，二选一）：

```
/fix-image-vulns 29989531701                                    # Build Kiali Images 的 run ID 或 URL
/fix-image-vulns build-harbor.alauda.cn/asm/kiali:v2.22.2-rt.1  # 或直接给 1~3 个镜像地址
```

环境要求：本机安装 trivy ≥ 0.52（kiali 打包成 APK，扫描需 `--detection-priority comprehensive`，不能走内部扫描服务）、gh 已认证、同级目录有 alauda-mesh/kiali 克隆。