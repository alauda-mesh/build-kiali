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