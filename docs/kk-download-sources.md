# KubeKey 离线包下载源对照文档

> 适用版本：KubeKey v4.x（模块化版本，数据驱动 YAML 任务）
> 命令：`./kk artifact export -c config.yaml --workdir prepare`
> 本文以 `--workdir prepare` 为例，`binary_dir = prepare/kubekey`，工具落在 `prepare/tools`。

---

## 一、核心机制：5 类下载任务 + fileExists 跳过

`download/tasks/main.yaml` 依次执行 5 个子任务：

| 顺序 | 任务文件 | 下载内容 | 存放目录 | 跳过判断 |
|------|---------|---------|---------|---------|
| 1 | `binary.yaml` | 核心二进制 | `prepare/kubekey/<组件>/<版本>/<架构>/` | `fileExists` 本地路径 |
| 2 | `helm.yaml` | Helm charts | `prepare/kubekey/cni/`、`storageclass/` | `fileExists` 本地路径 |
| 3 | `images.yaml` | 容器镜像（OCI） | `prepare/kubekey/images/` | OCI manifest 已存在 |
| 4 | `iso.yaml` | ISO 仓库镜像 | `prepare/kubekey/repository/` | `fileExists` 本地路径 |
| 5 | `tools.yaml` | 工具 | `prepare/tools/<架构>/` | `fileExists` 本地路径 |

**关键结论**：所有 HTTP 下载类（1/2/4/5）都有 `fileExists` 判断 —— **只要把文件按正确文件名放到正确路径，就不会从远端下载**。容器镜像（3）走 OCI 协议，判断方式不同。

---

## 二、`zone` 字段的作用机制

```yaml
# builtin/core/roles/defaults/defaults/main/01-main.yaml:20
zone: ""    # 默认空字符串
```

URL 模板统一写法（以 etcd 为例）：

```yaml
etcd: >-
  {{- .zone | eq "cn" | ternary (tpl "https://{{ .download.cn_host}}/" .) "https://" -}}
  github.com/etcd-io/etcd/releases/download/{{ "{{ .version }}" }}/etcd-{{ "{{ .version }}" }}-linux-{{ "{{ .arch }}" }}.tar.gz
```

`cn_host` 默认值（`10-download.yaml:5`）：

```yaml
cn_host: kubekey.pek3b.qingstor.com
```

**两种 zone 的前缀渲染**：

| zone 值 | URL 前缀 | 含义 |
|---------|---------|------|
| `""`（默认，未设或非 cn） | `https://` | 直连原始源（GitHub / dl.k8s.io / 等） |
| `"cn"` | `https://kubekey.pek3b.qingstor.com/` | 走青云 QingStor 国内镜像 |

> ⚠️ QingStor 镜像完整复制了原始路径结构，只是把域名换成 `kubekey.pek3b.qingstor.com`，后面接 `github.com/...`、`dl.k8s.io/...` 等原始路径。

---

## 三、完整下载清单对照表（zone 两种取值）

> 下表以 `kube_version=v1.31.14, arch=amd64` 为例展示 URL 样例。`${cn}` = `https://kubekey.pek3b.qingstor.com`。

### ① 核心二进制（`binary.yaml`）→ `prepare/kubekey/`

| 组件 | 版本 | 本地文件名 | zone=""（直连）源 | zone="cn"（镜像）源 |
|------|------|-----------|------------------|---------------------|
| etcd | v3.5.24 | `etcd/v3.5.24/amd64/etcd-v3.5.24-linux-amd64.tar.gz` | `https://github.com/etcd-io/etcd/releases/download/v3.5.24/etcd-v3.5.24-linux-amd64.tar.gz` | `${cn}/github.com/etcd-io/etcd/releases/download/v3.5.24/etcd-v3.5.24-linux-amd64.tar.gz` |
| kubelet | v1.31.14 | `kube/v1.31.14/amd64/kubelet` | `https://dl.k8s.io/release/v1.31.14/bin/linux/amd64/kubelet` | `${cn}/dl.k8s.io/release/v1.31.14/bin/linux/amd64/kubelet` |
| kubeadm | v1.31.14 | `kube/v1.31.14/amd64/kubeadm` | `https://dl.k8s.io/release/v1.31.14/bin/linux/amd64/kubeadm` | `${cn}/dl.k8s.io/release/v1.31.14/bin/linux/amd64/kubeadm` |
| kubectl | v1.31.14 | `kube/v1.31.14/amd64/kubectl` | `https://dl.k8s.io/release/v1.31.14/bin/linux/amd64/kubectl` | `${cn}/dl.k8s.io/release/v1.31.14/bin/linux/amd64/kubectl` |
| helm | v3.13.3 | `helm/v3.13.3/amd64/helm-v3.13.3-linux-amd64.tar.gz` | `https://get.helm.sh/helm-v3.13.3-linux-amd64.tar.gz` | `${cn}/get.helm.sh/helm-v3.13.3-linux-amd64.tar.gz` |
| crictl | v1.31.0 | `crictl/v1.31.0/amd64/crictl-v1.31.0-linux-amd64.tar.gz` | `https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.31.0/crictl-v1.31.0-linux-amd64.tar.gz` | `${cn}/github.com/kubernetes-sigs/cri-tools/releases/download/v1.31.0/crictl-v1.31.0-linux-amd64.tar.gz` |
| **docker** ⚠️ | 25.0.5 | `docker/25.0.5/amd64/docker-25.0.5.tgz` | `https://mirrors.aliyun.com/docker-ce/linux/static/stable/x86_64/docker-25.0.5.tgz` | **相同**（阿里云，不受 zone 影响） |
| cri-dockerd | v0.3.21 | `cri-dockerd/v0.3.21/amd64/cri-dockerd-0.3.21.amd64.tgz` | `https://github.com/Mirantis/cri-dockerd/releases/download/v0.3.21/cri-dockerd-0.3.21.amd64.tgz` | `${cn}/github.com/Mirantis/cri-dockerd/releases/download/v0.3.21/cri-dockerd-0.3.21.amd64.tgz` |
| containerd | v1.7.13 | `containerd/v1.7.13/amd64/containerd-1.7.13-linux-amd64.tar.gz` | `https://github.com/containerd/containerd/releases/download/v1.7.13/containerd-1.7.13-linux-amd64.tar.gz` | `${cn}/github.com/containerd/containerd/releases/download/v1.7.13/containerd-1.7.13-linux-amd64.tar.gz` |
| runc | v1.1.12 | `runc/v1.1.12/amd64/runc.amd64` | `https://github.com/opencontainers/runc/releases/download/v1.1.12/runc.amd64` | `${cn}/github.com/opencontainers/runc/releases/download/v1.1.12/runc.amd64` |
| calicoctl | v3.30.5 | `cni/calico/v3.30.5/amd64/calicoctl-linux-amd64` | `https://github.com/projectcalico/calico/releases/download/v3.30.5/calicoctl-linux-amd64` | `${cn}/github.com/projectcalico/calico/releases/download/v3.30.5/calicoctl-linux-amd64` |
| docker-registry | 2.8.3 | `image-registry/docker-registry/2.8.3/amd64/docker-registry-2.8.3-linux-amd64.tgz` | `https://docker.io/registry/2.8.3/docker-registry-2.8.3-linux-amd64.tgz` | `${cn}/docker.io/registry/2.8.3/docker-registry-2.8.3-linux-amd64.tgz` |
| docker-compose | v2.20.3 | `image-registry/docker-compose/v2.20.3/amd64/docker-compose` | `https://github.com/docker/compose/releases/download/v2.20.3/docker-compose-linux-x86_64` | `${cn}/github.com/docker/compose/releases/download/v2.20.3/docker-compose-linux-x86_64` |
| harbor | v2.10.2 | `image-registry/harbor/v2.10.2/amd64/harbor-offline-installer-v2.10.2.tgz` | `https://github.com/goharbor/harbor/releases/download/v2.10.2/harbor-offline-installer-v2.10.2.tgz`（arm64 时走 `kubesphere/kubekey` + `iso-latest`） | `${cn}/github.com/goharbor/harbor/releases/download/v2.10.2/harbor-offline-installer-v2.10.2.tgz` |
| **keepalived** ⚠️ | 2.0.20 | `image-registry/keepalived/2.0.20/amd64/keepalived-2.0.20-linux-amd64.tgz` | `https://kubekey.pek3b.qingstor.com/osixia/keepalived/2.0.20/keepalived-2.0.20-linux-amd64.tgz` | **相同**（模板里直接写 `{{ .download.cn_host}}`，不走 ternary，**永远走 cn_host**） |

### ② Helm charts（`helm.yaml`）→ `prepare/kubekey/cni/`、`storageclass/`

| Chart | 版本 | 本地文件名 | zone=""（直连）源 | zone="cn"（镜像）源 |
|-------|------|-----------|------------------|---------------------|
| tigera-operator（calico） | v3.30.5 | `cni/calico/tigera-operator-v3.30.5.tgz` | `https://github.com/projectcalico/calico/releases/download/v3.30.5/tigera-operator-v3.30.5.tgz` | `${cn}/github.com/projectcalico/calico/releases/download/v3.30.5/tigera-operator-v3.30.5.tgz` |
| cilium | 1.19.1 | `cni/cilium/cilium-1.19.1.tgz` | `https://helm.cilium.io/cilium-1.19.1.tgz` | `${cn}/helm.cilium.io/cilium-1.19.1.tgz` |
| flannel | v0.27.4 | `cni/flannel/flannel-v0.27.4.tgz` | `https://github.com/flannel-io/flannel/releases/download/v0.27.4/flannel.tgz` | `${cn}/github.com/flannel-io/flannel/releases/download/v0.27.4/flannel.tgz` |
| kube-ovn | v1.15.0 | `cni/kubeovn/kube-ovn-v1.15.0.tgz` | `https://kubeovn.github.io/kube-ovn/kube-ovn-v1.15.0.tgz` | `${cn}/kubeovn.github.io/kube-ovn/kube-ovn-v1.15.0.tgz` |
| spiderpool | v1.1.1 | `cni/spiderpool/spiderpool-v1.1.1.tgz` | `https://github.com/spidernet-io/spiderpool/releases/download/v1.1.1/spiderpool-v1.1.1.tgz` | `${cn}/github.com/spidernet-io/spiderpool/releases/download/v1.1.1/spiderpool-v1.1.1.tgz` |
| localpv-provisioner | 4.4.0 | `storageclass/local/localpv-provisioner-4.4.0.tgz` | `https://openebs.github.io/dynamic-localpv-provisioner/localpv-provisioner-4.4.0.tgz` | `${cn}/openebs.github.io/dynamic-localpv-provisioner/localpv-provisioner-4.4.0.tgz` |
| nfs-subdir-provisioner | 4.0.18 | `storageclass/nfs/nfs-subdir-external-provisioner-4.0.18.tgz` | `https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/releases/download/nfs-subdir-external-provisioner-4.0.18/nfs-subdir-external-provisioner-4.0.18.tgz` | `${cn}/github.com/kubernetes-sigs/nfs-subdir-external-provisioner/releases/download/nfs-subdir-external-provisioner-4.0.18/nfs-subdir-external-provisioner-4.0.18.tgz` |

### ③ ISO 仓库镜像（`iso.yaml`）→ `prepare/kubekey/repository/`

| 配置项 | 本地文件名 | zone=""（直连）源 | zone="cn"（镜像）源 |
|--------|-----------|------------------|---------------------|
| `kylin-v10SP3-rpms` | `repository/kylin-v10SP3-rpms-amd64.iso` | `https://github.com/kubesphere/kubekey/releases/download/iso-latest/kylin-v10SP3-rpms-amd64.iso` | `${cn}/github.com/kubesphere/kubekey/releases/download/iso-latest/kylin-v10SP3-rpms-amd64.iso` |
| 其他 ISO | `repository/<iso名>-<架构>.iso` | `https://github.com/kubesphere/kubekey/releases/download/iso-latest/<iso名>-<架构>.iso` | `${cn}/github.com/kubesphere/kubekey/releases/download/iso-latest/<iso名>-<架构>.iso` |

合法 ISO 名清单（CI 构建矩阵，`.github/workflows/gen-repository-iso.yaml`）：
`almalinux-9.0-rpms`、`centos-8-rpms`、`debian-10-debs`、`debian-11-debs`、
`kylin-v10SP1-rpms`、`kylin-v10SP2-rpms`、`kylin-v10SP3-rpms`、`kylin-v10SP3-2403-rpms`、
`ubuntu-18.04-debs`、`ubuntu-20.04-debs`、`ubuntu-22.04-debs`、`ubuntu-24.04-debs`

### ④ 工具（`tools.yaml`）→ `prepare/tools/<架构>/`

| 工具 | 版本 | 本地文件名 | zone=""（直连）源 | zone="cn"（镜像）源 |
|------|------|-----------|------------------|---------------------|
| oras | v1.3.0 | `tools/amd64/oras_1.3.0_linux_amd64.tar.gz` | `https://github.com/oras-project/oras/releases/download/v1.3.0/oras_1.3.0_linux_amd64.tar.gz` | `${cn}/github.com/oras-project/oras/releases/download/v1.3.0/oras_1.3.0_linux_amd64.tar.gz` |
| nerdctl | v2.2.1 | `tools/amd64/nerdctl-2.2.1-linux-amd64.tar.gz` | `https://github.com/containerd/nerdctl/releases/download/v2.2.1/nerdctl-2.2.1-linux-amd64.tar.gz` | `${cn}/github.com/containerd/nerdctl/releases/download/v2.2.1/nerdctl-2.2.1-linux-amd64.tar.gz` |
| kubekey（自身） | — | `tools/amd64/kubekey-*.tar.gz` | 由 `package.sh` 的 `--set download.tools.kubekey=...` 覆盖 | 同左（不看 zone） |

### ⑤ 容器镜像（`images.yaml`）→ `prepare/kubekey/images/`（不走 HTTP）

| 项 | zone="" | zone="cn" |
|----|---------|-----------|
| 默认 registry | **空**（不设，需在 config 显式指定，否则 manifests 里的镜像地址原样拉取） | `hub.kubesphere.com.cn`（KubeSphere 官方镜像仓库） |
| 拉取方式 | OCI 协议（oras） | OCI 协议（oras） |
| 说明 | 镜像清单 `images.manifests` 里的地址（如 `docker.io/...`、`quay.io/...`）原样作为拉取源 | manifest 中的镜像会被自动加 `hub.kubesphere.com.cn/` 前缀重定向到官方源 |

> 容器镜像**不走 cn_host**，而是由 `download.images.registry` 字段控制（`10-download.yaml:147`）。
> zone="cn" 时默认 `hub.kubesphere.com.cn`；zone="" 时该字段为空，需要自己在 config 里配 `download.images.registry`，或让 manifest 用完整地址。

### ⑥ 额外 chart（config 里 `charts:` 声明的 OCI chart）→ `prepare/artifact/charts/`

| 配置 | zone="" | zone="cn" |
|------|---------|-----------|
| `oci://hub.kubesphere.com.cn/kse/ks-core` v1.2.4 | 直接从 `hub.kubesphere.com.cn` OCI 拉取 | 相同（不受 zone 影响，地址写死在 config） |

---

## 四、不受 zone 影响的特殊项（重点）

以下组件**无论 zone 是什么，源都固定**，换 zone 不会改变它们：

| 组件 | 固定源 | 原因 |
|------|--------|------|
| **docker** | `https://mirrors.aliyun.com/docker-ce/...` | 模板里硬编码阿里云，没有 zone 分支 |
| **keepalived** | `https://kubekey.pek3b.qingstor.com/osixia/keepalived/...` | 模板里直接写 `{{ .download.cn_host}}`，**永远走 cn_host**，zone="" 时也走 QingStor |
| 容器镜像 | `download.images.registry` 决定 | 不走 cn_host，独立字段 |
| OCI chart（ks-core 等） | config 里 `charts[].url` 写死 | 不走 cn_host |
| kubekey 工具自身 | `package.sh --set download.tools.kubekey=...` | 命令行参数覆盖 |

---

## 五、手动下载 / 换源的三种方法

### 方法 1：预放文件（最简单，所有 HTTP 类通用）

只要把文件按**正确文件名**放到**正确路径**，`fileExists` 命中即跳过下载。

```bash
# 示例：手动放 kubelet
mkdir -p prepare/kubekey/kube/v1.31.14/amd64/
curl -o prepare/kubekey/kube/v1.31.14/amd64/kubelet \
  https://你想要的源/kubelet

# 示例：手动放 ISO
mkdir -p prepare/kubekey/repository/
curl -o prepare/kubekey/repository/kylin-v10SP3-rpms-amd64.iso \
  https://你想要的源/kylin-v10SP3-rpms-amd64.iso
```

**文件名规则**：见第三节各表的"本地文件名"列，必须一字不差（大小写、版本号格式、扩展名）。
**确认路径**：跑一次 `./package.sh`，日志会打印每个文件的 `fileExists` 检查路径，照着放即可。

### 方法 2：覆盖单个 `artifact_url`（精细控制，推荐）

在 config.yaml 里单独覆盖某个组件的 URL 模板，其他保持默认：

```yaml
spec:
  # zone 可不设，或设为 "cn"
  download:
    artifact_url:
      kubelet: "https://你的源/k8s/{{ .version }}/bin/linux/{{ .arch }}/kubelet"
      etcd: "https://你的源/etcd-{{ .version }}-linux-{{ .arch }}.tar.gz"
      # 只覆盖需要换的，其余保持默认
```

模板变量：`{{ .version }}`、`{{ .arch }}` 是可用的占位符。

### 方法 3：换容器镜像源

容器镜像源由独立字段控制，与 zone/cn_host 无关：

```yaml
spec:
  download:
    images:
      registry: your-registry.example.com    # ← 改这里
      manifests:
        - your-registry.example.com/library/haproxy:2.9.6-alpine
        # ... manifest 里的地址也要对应改
```

---

## 六、关键文件位置索引（源码）

| 文件 | 作用 |
|------|------|
| `builtin/core/roles/defaults/defaults/main/01-main.yaml:20` | `zone: ""` 默认值 |
| `builtin/core/roles/defaults/defaults/main/10-download.yaml:5` | `cn_host` 默认值 |
| `builtin/core/roles/defaults/defaults/main/10-download.yaml:15-105` | 所有 `artifact_url` 模板 |
| `builtin/core/roles/defaults/defaults/main/10-download.yaml:145-150` | 容器镜像 registry 默认值 |
| `builtin/core/roles/download/tasks/main.yaml` | 下载任务编排（5 个 include_tasks） |
| `builtin/core/roles/download/tasks/binary.yaml` | 二进制下载（含 fileExists 判断） |
| `builtin/core/roles/download/tasks/helm.yaml` | Helm chart 下载 |
| `builtin/core/roles/download/tasks/images.yaml` | 容器镜像 OCI 拉取 |
| `builtin/core/roles/download/tasks/iso.yaml` | ISO 下载 |
| `builtin/core/roles/download/tasks/tools.yaml` | 工具下载 |
| `builtin/core/roles/download/package/tasks/*.yaml` | 打包阶段（拷贝到 artifact_dir） |
