<div align=center><img src="docs/images/kubekey-logo.svg?raw=true"></div>

[![CI](https://github.com/kubesphere/kubekey/actions/workflows/golangci-lint.yaml/badge.svg?branch=main)](https://github.com/kubesphere/kubekey/actions/workflows/golangci-lint.yaml)
[![Sync Patch](https://github.com/lpx0312/kubekey/actions/workflows/sync-patch.yml/badge.svg?branch=port-fix)](https://github.com/lpx0312/kubekey/actions/workflows/sync-patch.yml)

---

# 🔧 本仓库 = 官方 KubeKey + 私有补丁（port-fix）

> 这是 [`kubesphere/kubekey`](https://github.com/kubesphere/kubekey) 的 **fork**，在官方版本基础上打了一个私有补丁，并附带一键同步工具。下方为补丁说明与使用方法，官方原始 README 内容见 [本节之后](#comparison-of-new-features-in-3x)。

## 补丁解决了什么问题

支持 **带端口的镜像仓库地址**，例如 `harbor.example.com:7000/library/nginx:latest`。

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

## 获取补丁版二进制

直接从本仓库的 [Releases](https://github.com/lpx0312/kubekey/releases) 下载，命名形如 `kubekey-vX.Y.Z-portfix-<os>-<arch>.tar.gz`（含 6 个平台：linux/windows/darwin × amd64/arm64）。

当前最新版：[![release](https://img.shields.io/github/v/release/lpx0312/kubekey?include_prereleases&label=)](https://github.com/lpx0312/kubekey/releases/latest)

## 仓库结构

| 名字 | 含义 |
|------|------|
| `port-fix` 分支（默认） | 长期维护分支 = 官方基线 + 私有补丁 + 同步脚本/文档 |
| `master` 分支 | 官方原始内容（备份） |
| `patch/port-fix` tag | 端口补丁的稳定引用（cherry-pick 时用） |
| `vX.Y.Z-portfix` tag / Release | 发布产物 = 官方 `vX.Y.Z` + 补丁 |

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
