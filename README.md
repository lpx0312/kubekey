<div align=center><img src="docs/images/kubekey-logo.svg?raw=true"></div>

[![CI](https://github.com/kubesphere/kubekey/actions/workflows/golangci-lint.yaml/badge.svg?branch=main)](https://github.com/kubesphere/kubekey/actions/workflows/golangci-lint.yaml)
[![Sync Patch](https://github.com/lpx0312/kubekey/actions/workflows/sync-patch.yml/badge.svg?branch=port-fix)](https://github.com/lpx0312/kubekey/actions/workflows/sync-patch.yml)

---

# 🔧 本仓库 = 官方 KubeKey + 私有补丁（port-fix）

> 这是 [`kubesphere/kubekey`](https://github.com/kubesphere/kubekey) 的 **fork**，在官方版本基础上打了私有补丁，并附带一键同步工具。下方为补丁说明与使用方法，官方原始 README 内容见 [本节之后](#comparison-of-new-features-in-3x)。

## 补丁解决了什么问题

本仓库当前维护八个私有补丁：

### 补丁 1：支持带端口的镜像仓库地址

例如 `harbor.example.com:7000/library/nginx:latest`。

**官方 bug**：`normalizeImageName` 用 `govalidator.IsHost()` 判断首段是否为 registry 域名，但该函数对**含 `:`（端口）的字符串返回 false**，导致 `harbor.example.com:7000` 被误判为 project 名，被错误补上 `docker.io/` 前缀，最终报错：

```
failed to parse reference "docker.io/harbor.example.com:7000/library/nginx:latest":
invalid reference: invalid tag "7000/library/nginx:latest"
```

**修复方式**（`pkg/modules/image/image.go`）：
```diff
- if govalidator.IsHost(firstPart) {
+ if strings.ContainsAny(firstPart, ".:") || firstPart == "localhost" {
```
首段含 `.`（域名）或 `:`（端口）或等于 `localhost` 即视为 registry host，与 oras `registry.ParseReference` 的判定规则一致。

### 补丁 2：修复 etcd 定时备份脚本从未成功

**官方 bug**：`kk create cluster` 部署的 etcd 定时备份脚本（`backup_etcd.sh`，由 systemd timer 每 30 分钟触发）**从集群创建第一天起就全部失败，从未产出过一份可用快照**。两个叠加 bug：

1. **变量名写错**：脚本定义的是 `ETCD_ENDPOINTS`，但 `etcdctl snapshot save` 那行引用的是 `$ENDPOINTS`（未定义）。配合 `set -o nounset`，每次必然报 `ENDPOINTS: unbound variable`。
2. **多端点不支持**：即使修好变量名，`etcdctl snapshot save` 也只接受单个 endpoint，而模板渲染出的是 3 节点列表，会报 `snapshot must be requested to one selected node, not multiple`。

**修复方式**（`builtin/core/roles/etcd/install/templates/backup.sh`）：把 `snapshot save` 那一行的 endpoints 改为本机单点 `https://localhost:{{ .etcd.port }}`，与 kk 安装时一次性备份 role（`roles/etcd/backup`）的做法一致。一次改动同时解决两个 bug。

> ⚠️ **已部署的集群**：升级到补丁版 kk 只能保证**新装的**集群备份正常；旧集群需手动把修好的 `backup.sh` 同步到每台 etcd 节点的 `/usr/local/bin/kube-scripts/backup_etcd.sh`。

### 补丁 3：修复 k8s 证书自动续期从未生效

**官方 bug**：`kk create cluster` 部署的 k8s 控制面证书自动续期定时任务（`k8s-certs-renew.timer`，每周触发）**从集群创建起就全部失败，证书到期前不会被自动续期**。三个叠加 bug：

1. **Go template trim 吃掉换行**：续期脚本模板 `renew_script.sh` 的 `{{- if/else/end -}}` 贪婪 trim，渲染后 `#!/bin/bash`、`kubeadmCerts=...`、函数定义挤成一行，bash 语法损坏。
2. **systemd ExecStart 路径不匹配**：service 指向 `k8s-certs-renew.sh`（不存在），实际部署的是 `renew_script.sh`，每次必然 `status=203/EXEC`。
3. **日期解析正则失效**：`grep` 用了 PCRE 的 `\s \w`（BRE 不支持），永远匹配空 → 算出负数天数 → 每次都误触发续期（或反过来静默跳过）。

**修复方式**（3 处改动）：
- `builtin/core/roles/kubernetes/certs/templates/k8s-certs-renew.sh`（原 `renew_script.sh`）：删除 `<v1.20.0` 死代码分支（kubekey v4 最低支持 v1.23），固定用 `kubeadm certs`；`getCertValidDays()` 改用 kubeadm 输出的 `RESIDUAL TIME` 列（`NNNd`），解析失败兜底返回 `9999`（跳过续期）；加 `set -euo pipefail`。
- `builtin/core/roles/kubernetes/certs/files/k8s-certs-renew.service`：`ExecStart` 为 `/usr/local/bin/kube-scripts/k8s-certs-renew.sh`。
- **改名**：把脚本从 `renew_script.sh` 改名为 `k8s-certs-renew.sh`，让模板、部署文件、systemd ExecStart 三者名称一致（原 service 引用的 `k8s-certs-renew.sh` 本就不存在，改名后名实相符）。`tasks/main.yaml` 同步更新 src/dest。

> ⚠️ **已部署的集群**：升级补丁版 kk 只保证**新装的**集群续期正常；旧集群需手动同步脚本和 service 文件并重启 timer（注意旧集群脚本名是 `renew_script.sh`，要一并改成 `k8s-certs-renew.sh`）。

> ℹ️ 这是控制面组件证书（kube-apiserver 等，1 年有效期）的自动续期。kubelet 客户端证书由 `rotateCertificates: true` 自动轮转，无需此补丁；CA/etcd 证书由 kk 签发，有效期 10 年。详见 [CERTS-GUIDE.md](CERTS-GUIDE.md)。

### 补丁 4：修复 NFS 默认存储类不生效

**官方 bug**：NFS StorageClass 的 Helm values 模板 `builtin/core/roles/storageclass/nfs/templates/values.yaml` 第 12 行**引用了错误的变量**：

```yaml
defaultClass: {{ .storage_class.local.default }}   # ❌ 读的是 local.default，不是 nfs.default
```

导致在 config 里设置 `storage_class.nfs.default: true` 完全不生效——渲染出的 `defaultClass: false`，NFS StorageClass 不会被标记为默认。集群没有默认 SC → 所有 `storageClassName` 为空的 PVC 永远 Pending（连带 Jenkins、Prometheus 等 Pod 起不来）。

**修复方式**（`builtin/core/roles/storageclass/nfs/templates/values.yaml`，1 行）：
```diff
- defaultClass: {{ .storage_class.local.default }}
+ defaultClass: {{ .storage_class.nfs.default }}
```

> ⚠️ **已部署的集群**：代码修复只对**新装**集群生效。旧集群可紧急止血（不改代码）：`kubectl patch sc nfs-client -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'`

### 补丁 5：修复 `kk certs renew` 命令直接失败

**官方 bug**：`kk certs renew` 启动即报 `failed to find role`，命令完全不可用。两处 role 引用都少写了 `certs/` 前缀：`playbooks/certs_renew.yaml` 写成 `cert/init`（单数，目录不存在）；`certs/renew/meta/main.yaml` 的三个 dependency 写成 `renew/xxx`（缺 `certs/`）。其他所有 playbook 和 role 的 dependency 都正确使用完整路径前缀。

**修复方式**：`cert/init → certs/init`；`renew/xxx → certs/renew/xxx`。

> ⚠️ 只影响 kk 二进制（playbook 和 role 都是 `//go:embed` 编译进二进制的）。重新编译带此补丁的 kk 即可，已部署的集群本身不受影响。

### 补丁 6：支持 HCE 2.0（华为云欧拉）作为 worker 节点

**官方 bug**：HCE 2.0（Huawei Cloud EulerOS，`ID=hce`，基于 openEuler 22.03 LTS 的 RHEL 系发行版）在 kubekey 中**完全不被识别**，add-node 时 HCE 节点会失败。两个叠加问题：

1. **OS 白名单不含 HCE**：`01-cluster_require.yaml` 的 `supported_os_distributions` 只有 ubuntu/centos/kylin/rocky，precheck 直接拒绝 HCE 节点。
2. **OS 分类无 HCE 特判**：HCE 的 `/etc/os-release` **没有 `ID_LIKE` 字段**（不像普通 RHEL 系是 `rhel fedora`），`install_package.yaml` 的 `current_host_type` 三个分支都不命中 → 结果为空 → yum 仓库初始化和 `socat/conntrack/ipset/ebtables/chrony/ipvsadm` 等系统依赖**整段被跳过**，join 后节点异常。

**修复方式**（2 处）：
- `01-cluster_require.yaml`：白名单加 `hce` 和 `'"hce"'`（带引号变体，因 Go 端解析 `/etc/os-release` 保留引号，与 ubuntu/centos/kylin 写法一致）。
- `install_package.yaml`：加 `ID == hce → centos` 特判分支（与 kylin 同样的处理）。

**ISO 文件名天然吻合**：HCE 的 `ID=hce` + `VERSION_ID=2.0` + 空 `ID_LIKE` 命中 `repository/tasks/main.yaml` 的 else 分支，产出 `system_string=hce-2.0`，正好匹配预构建的 `hce-2.0-rpms-{amd64,arm64}.iso`（由 `hack/gen-repository-iso/dockerfile.hce20` 构建）。

> ⚠️ 只影响 kk 二进制。重新编译带此补丁的 kk 后，新增 HCE 节点即可正常 add-node；已部署的集群不受影响。

### 补丁 7：ISO 离线包下载地址可配置（支持代理/镜像）

**官方 bug**：离线打包（`kk artifact export`）时，ISO 依赖包（如 `hce-2.0-rpms-{amd64,arm64}.iso`、`kylin-v10SP3-rpms-*.iso`）的下载 URL `https://github.com/kubesphere/kubekey/releases/download/iso-latest/...` **硬编码在 `download/tasks/iso.yaml` 里**，没有任何 config 字段可以配置。`download.iso` 只控制下载哪些 ISO（列表），`download.cn_host` 只在 `zone=cn` 时换一个固定加速域名（`kubekey.pek3b.qingstor.com`），都换不成用户自建的 GitHub 代理/镜像（如 `ghproxy.xxx/github.com/yourname/kubekey`）。导致内网或被墙环境无法从自有源拉 ISO。

**修复方式**（2 处）：
- `10-download.yaml`：`download` 段新增 `iso_host` 字段，**默认空**（保持官方行为）。
- `iso.yaml`：URL 模板改为：设了 `iso_host` 就完全用它（含 `https://` 前缀，忽略 `zone`/`cn_host`）；没设则走官方原逻辑（`zone=cn` 时 qingstor 兜底）。

**用法**：在 config 里填**完整的 ISO 源前缀**（含 `https://` 和 owner/repo）：
```yaml
spec:
  download:
    iso_host: https://ghproxy.example.com/github.com/yourname/kubekey
```
完整 URL 会拼成 `https://ghproxy.example.com/github.com/yourname/kubekey/releases/download/iso-latest/hce-2.0-rpms-amd64.iso`。

**设计要点**：`iso_host` 是**完整 URL 前缀**（含协议），不是 owner/repo 路径。这样设了就完全接管 ISO URL，**不再与 `cn_host`/`zone=cn` 叠加**（否则会拼出 `https://kubekey.pek3b.qingstor.com/ghproxy.xxx/...` 双重路径 404）。不设则行为与官方完全一致，老 config 无需改动。

**影响范围极窄**：只改 ISO 下载 URL。普通 binary（etcd/kubelet 等）、镜像、Helm chart 各走独立模板，不受影响。

### 补丁 8：支持 openEuler 20.03/22.03/24.03 LTS 作为 worker 节点

**官方 bug**：openEuler（`ID=openEuler`，20.03 / 22.03 / 24.03 三大 LTS 系列，每系列 SP1–SP4）在 kubekey 中**完全不被识别**，add-node 时 openEuler 节点会失败。比 HCE 2.0 多一层问题，共三个叠加：

1. **OS 白名单不含 openEuler**：`01-cluster_require.yaml` 的 `supported_os_distributions` 只有 ubuntu/centos/kylin/hce/rocky，precheck 直接拒绝 openEuler 节点。
2. **OS 分类无 openEuler 特判**：openEuler 的 `/etc/os-release` **没有 `ID_LIKE` 字段**（和 HCE 一样），`install_package.yaml` 的 `current_host_type` 分支都不命中 → 结果为空 → yum 仓库初始化和 `socat/conntrack/ipset/ebtables/chrony/ipvsadm` 等系统依赖**整段被跳过**，join 后节点异常。
3. **ISO 文件名带 SP 但取不到**（openEuler 独有，HCE 没这问题）：openEuler 一个主版本对应**多个 SP 的 ISO**（如 `openeuler-22.03-sp1/sp2/sp3/sp4-rpms-*.iso`，共 11 个），但 `VERSION_ID` 只携带主版本号（`22.03`），区分 SP 的信息**只在 `VERSION`**（`22.03 (LTS-SP3)`）。原 `system_string` 的 else 分支会让 4 个 SP 坍缩成同一个 `openeuler-22.03`，**4 个 ISO 一个都选不中**。

**修复方式**（3 处）：
- `01-cluster_require.yaml`：白名单加 `openEuler` 和 `'"openEuler"'`（注意大写 E）。
- `install_package.yaml`：加 `ID == openEuler → centos` 特判分支（与 kylin/hce 同样处理）。
- `repository/tasks/main.yaml`：仿 kylin 的 `sp_version` 特判，新增 `oe_sp`（从 `VERSION` 提取 `SP1–SP4` 拼成小写后缀 `-sp1`..`-sp4`）和 system_string 的 openEuler 分支（`openeuler-<VERSION_ID><oe_sp>`），产出 `openeuler-22.03-sp3` 等精确匹配 11 个预构建 ISO。

**已验证**：用仓库实际的 sprig FuncMap + KK `unquote` 渲染，全部 11 个版本（bare 和 quoted 两种 os-release 形式）都正确产出匹配的 ISO 名。

> ⚠️ 只影响 kk 二进制。重新编译带此补丁的 kk 后，新增 openEuler 节点即可正常 add-node；已部署的集群不受影响。ISO 依赖包（`openeuler-*-rpms-*.iso`）已构建并发布到 `iso-latest` Release（见 commit `89dbc235`）。

## 获取补丁版二进制

直接从本仓库的 [Releases](https://github.com/lpx0312/kubekey/releases) 下载，命名形如 `kubekey-vX.Y.Z-portfix-<os>-<arch>.tar.gz`（含 6 个平台：linux/windows/darwin × amd64/arm64）。

当前最新版：[![release](https://img.shields.io/github/v/release/lpx0312/kubekey?include_prereleases&label=)](https://github.com/lpx0312/kubekey/releases/latest)

## 仓库结构

| 名字 | 含义 |
|------|------|
| `port-fix` 分支（默认） | 长期维护分支 = 官方基线 + 私有补丁 + 同步脚本/文档 |
| `master` 分支 | 官方原始内容（备份） |
| `patch/base` tag | patch 基线（官方版本，不含任何补丁，cherry-pick 起点） |
| `patch/port-fix` tag | 所有私有补丁的最新汇总点（cherry-pick 终点） |
| `vX.Y.Z-portfix` tag / Release | 发布产物 = 官方 `vX.Y.Z` + 全部补丁 |

## 跟随官方新版本（一键同步 + 自动发布）

**方式一：GitHub Actions（推荐）**

进入 [Actions → Sync Patch](https://github.com/lpx0312/kubekey/actions/workflows/sync-patch.yml) → `Run workflow` → 输入官方版本号（如 `v4.0.6`）→ 运行。约 11 分钟后自动产出 `v4.0.6-portfix` Release（补丁 + 6 平台二进制）。

**方式二：命令行触发**

```bash
gh workflow run sync-patch.yml -R lpx0312/kubekey --ref port-fix -f version=v4.0.6 -f push=true
```

**方式三：本地脚本**（需 Go 环境，网络受限时用代理 `SYNC_PROXY=...`）

```bash
git checkout port-fix
./scripts/sync-patch.sh v4.0.6
```

以上三种方式都是**幂等**的：同一版本可重复运行，总是覆盖为最新结果。

## 新增私有补丁

发现官方代码还有 bug 需要修复时，按 [ADD-PATCH-TUTORIAL.md](ADD-PATCH-TUTORIAL.md) 的 **9 步流程**操作即可。核心要点：

1. 在 `port-fix` 分支改代码并提交一个 `fix(...)` commit
2. 基于 `patch/base` 重建干净的补丁链（所有补丁串成一条直线，**不能夹 docs/ci 等无关 commit**），更新 `patch/port-fix` tag
3. 用 `git format-patch` 生成 `patches/000N-*.patch` 归档，同步更新 README / PATCH-MAINTENANCE / sync-patch.sh
4. 推送 `port-fix` 分支 + `patch/port-fix` tag（`--force`），然后触发 `sync-patch.yml` 生成新 Release

> ⚠️ 教程里有 **5 个踩坑点详解**（template trim 吃换行、`--cleanup-tag` 毁掉正确 tag、patch 链带垃圾 commit、网络问题、旧集群迁移），动手前务必先读一遍。其中"**重建干净补丁链**"和"**验证发布 tag 的 commit 链底部是官方基线**"两步是关键，做错会导致发布的 tag 指向错误。

## 自建离线依赖包（ISO）

离线安装 K8s 时，`kk` 需要从 GitHub Release 下载各发行版的系统依赖包 ISO（含 chrony、conntrack、socat 等）。为避免依赖官方 [`kubesphere/kubekey`](https://github.com/kubesphere/kubekey) 的 `iso-latest` Release 消失，本仓库自带改造后的 **GenRepositoryISO** workflow，可在本 fork 内独立构建并发布全部 ISO 依赖包。

**产物**：[Releases · iso-latest](https://github.com/lpx0312/kubekey/releases/tag/iso-latest)，共 37 个文件（12 个发行版 × amd64/arm64 + sha256 + harbor 离线包），与官方一一对应。

**方式一：GitHub Actions（推荐）**

进入 [Actions → GenRepositoryISO](https://github.com/lpx0312/kubekey/actions/workflows/gen-repository-iso.yaml) → `Run workflow` → 选择 `port-fix` 分支 → 运行。约 10 分钟后产物覆盖到 `iso-latest` Release。

**方式二：命令行触发**

```bash
gh workflow run gen-repository-iso.yaml -R lpx0312/kubekey --ref port-fix
```

**方式三：打 tag 自动触发**

```bash
git tag -f iso-latest port-fix
git push origin iso-latest -f
```

**确定性说明**：改造后的 workflow 删除了上游的 `update-tag` 自动移 tag 逻辑，构建直接使用你触发时所选 ref（分支/tag）指向的 commit，产物版本完全由触发者决定，不会偷偷跟随 `main`。

**风险与隔离**：Kylin 系列依赖第三方镜像 `hxsoong/kylin`，若其不可用只会导致 4 个 kylin job 失败（`fail-fast: false` 已隔离），其余 8 个发行版照常出包。自定义包列表可编辑 [`hack/gen-repository-iso/packages.yaml`](hack/gen-repository-iso/packages.yaml)。

## 本地编译

```bash
git checkout port-fix   # 或 git checkout vX.Y.Z-portfix
LDFLAGS=$(bash hack/version.sh)
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -tags "builtin" -ldflags "$LDFLAGS" \
  -o _output/bin/kk cmd/kk/kubekey.go
```

> 必须带 `-tags "builtin"`，否则 `artifact` 子命令不会被编译进去。

更多维护细节见 [PATCH-MAINTENANCE.md](PATCH-MAINTENANCE.md)。

---

# 官方 KubeKey 说明（以下为原始内容）

> English | [中文](README_zh-CN.md)

**👋 Welcome to KubeKey!**

KubeKey is an open-source lightweight task flow execution tool. It provides a flexible and fast way to install Kubernetes.

> KubeKey has passed the [CNCF Kubernetes Conformance Certification](https://www.cncf.io/certification/software-conformance/)

# Comparison of new features in 3.x
1. Expanded from Kubernetes lifecycle management tool to task execution tool (flow design refers to [Ansible](https://github.com/ansible/ansible))
2. Supports multiple ways to manage task templates: git, local, etc.
3. Supports multiple node connection methods, including: local, ssh, kubernetes, prometheus.
4. Supports cloud-native automated batch task management
5. Advanced features: UI page (not yet open)

# Get KubeKey

## Method 1: Release Page

Get the corresponding binary files from the [Release](https://github.com/kubesphere/kubekey/releases) page.

## Method 2: Run Script

```shell
curl -sfL https://get-kk.kubesphere.io | sh -
```

| Original File | Extracted File |
|--------|--------|
| kubekey-v4.x.x-linux-amd64.tar.gz | kk: KubeKey binary |
| web-installer.tgz | dist: Web UI resources.<br>host-check.yaml, kubernetes, kubesphere: Task template files.<br>schema: Configuration files.<br>README.md: Installation documentation. |
| package.sh | Offline package build script. |

# Quick Start

## Method 1: Command Line

```shell
./kk create cluster
```

## Method 2: Web UI

**UI only supported after v4.0.0**

```shell
./kk web --schema-path web-installer/schema --ui-path web-installer/dist
```

# Documentation Navigation

- **[Install Kubernetes](docs/en/installation/README.md)**
  - [Component Versions](docs/en/installation/components.md)
  - [Online Installation](docs/en/installation/online.md)
  - [Offline Installation](docs/en/installation/offline.md)
  - [Add Cluster Nodes](docs/en/installation/add-nodes.md)
  - [Delete Cluster Nodes](docs/en/installation/delete-nodes.md)
- **[Configuration Reference](docs/en/reference/config.md)**
- **Playbooks**
  - [Create Kubernetes Cluster](docs/en/reference/playbooks/create_cluster.md)
  - [Delete Kubernetes Cluster](docs/en/reference/playbooks/delete_cluster.md)
  - [Add Nodes](docs/en/reference/playbooks/add_nodes.md)
  - [Delete Nodes](docs/en/reference/playbooks/delete_nodes.md)
  - [Renew Certificates](docs/en/reference/playbooks/certs_renew.md)
  - [Export Offline Artifact](docs/en/reference/playbooks/artifact_export.md)
  - [Pre-installation Check](docs/en/reference/playbooks/precheck.md)
  - [Initialize OS](docs/en/reference/playbooks/init_os.md)
- **[Image Registry Installation](docs/en/image-registry/README.md)**
- **[Dependency Packages](docs/en/dependency-packages/README.md)**
- **[Task Execution Framework](docs/en/framework/README.md)**
  - [Project](docs/en/framework/001-project.md)
  - [Playbook](docs/en/framework/002-playbook.md)
  - [Role](docs/en/framework/003-role.md)
  - [Task](docs/en/framework/004-task.md)
  - [Template Syntax](docs/en/framework/101-syntax.md)
  - [Variables](docs/en/framework/201-variable.md)
