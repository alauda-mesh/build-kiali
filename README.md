## 同步

### ansible-operator

`ansible-operator` 的开源版本有不少遗留漏洞，因此我们可以采用一些 openshift 的基础设施，同步主要是将 `github.com/openshift/ansible-operator-plugins` 这个仓库中的 `openshift` 目录，拷贝到当前仓库的 `ansible-operator` 目录中

## kiali-operator

同步 `github.com/kiali/kiali-operator`，修改 kiali-operator-bundle/manifests 下的 CSV，并且

1. 移除 `roles/` 下不需要的版本
2. 移除 `kiali-default-supported-images.yml` 下不需要的版本
3. 修改 Makefile 中的 CREATED_AT