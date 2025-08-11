## 同步

### ansible-operator

见 [alauda-mesh/ansible-operator-plugins](https://github.com/alauda-mesh/ansible-operator-plugins)

## kiali-operator

同步 `github.com/kiali/kiali-operator`，修改 kiali-operator-bundle/manifests 下的 CSV，并且

1. 移除 `roles/` 下不需要的版本
2. 移除 `kiali-default-supported-images.yml` 下不需要的版本
3. 修改 Makefile 中的 CREATED_AT