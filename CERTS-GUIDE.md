# KubeKey 集群证书说明与续期指南

本文档说明 KubeKey（以下简称 kk）安装的 Kubernetes 集群中，各类证书的有效期、是否需要手动管理，以及如何续期。

## 背景：为什么要关注证书

Kubernetes 集群大量使用 TLS 证书来保证组件间通信安全。证书一旦过期，apiserver、etcd 等核心组件会无法工作，整个集群不可用。因此需要提前了解证书有效期，并在到期前完成续期。

很多人担心"每年都要换证书很麻烦"，本文档把这个事情讲清楚。

## 一、集群里的三类证书

kk 安装的集群涉及三类证书，有效期和管理方式各不相同：

### 第一类：KubeKey 自己签发的 CA 和 etcd 证书（10 年，不用管）

这一类是 kk 在 `certs/init` 阶段用 openssl 自行签发的，配置在 `builtin/core/roles/defaults/defaults/main/02-certs.yaml`：

| 证书 | 默认有效期 | 配置位置 |
|------|-----------|---------|
| 根 CA（`certs.ca`） | `87600h`（10 年） | `02-certs.yaml:32` |
| Kubernetes CA（`certs.kubernetes_ca`） | `87600h`（10 年） | `02-certs.yaml:37` |
| front-proxy CA（`certs.front_proxy_ca`） | `87600h`（10 年） | `02-certs.yaml:41` |
| etcd 证书（`certs.etcd`） | `87600h`（10 年） | `02-certs.yaml:46` |
| 镜像仓库证书（`certs.image_registry`） | `87600h`（10 年） | `02-certs.yaml:51` |

> **结论：这一类证书有效期长达 10 年，十年内不需要任何操作。** 如果确实需要调整，可以在 config 里覆盖 `certs.*.date` 字段，例如：
> ```yaml
> certs:
>   ca:
>     date: 87600h
> ```

### 第二类：kubelet 客户端证书（自动轮转，不用管）

kubelet 连接 apiserver 用的客户端证书，由 kubeadm 签发。虽然 kubeadm 签发时默认有效期只有 1 年，但 kk 生成的 `KubeletConfiguration` 里**硬编码开启了自动轮转**：

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
rotateCertificates: true    # 关键：kubelet 客户端证书自动轮转
```

模板位置：`builtin/core/roles/kubernetes/init-kubernetes/templates/kubeadm/kubeadm-init.v1beta3`（和 `v1beta4`）。

> **结论：`rotateCertificates: true` 开启后，kubelet 客户端证书到期前会自动向 apiserver 申请新证书并替换，无需手动操作。**

### 第三类：kubeadm 生成的控制面组件证书（1 年，需手动续期）

这一类是真正的痛点。kube-apiserver、kube-controller-manager、kube-scheduler 的**服务端证书**由 kubeadm 签发，**默认有效期只有 1 年**，并且 kubeadm **不会自动续期**。

典型症状：证书到期前后，apiserver 拒绝连接、kubectl 报 `certificate has expired`、控制面组件 CrashLoopBackOff。

涉及的具体证书（在控制面节点的 `/etc/kubernetes/pki/` 下）：

- `apiserver.crt` / `apiserver.key`
- `apiserver-kubelet-client.crt` / `.key`
- `front-proxy-client.crt` / `.key`
- `controller-manager.conf`
- `scheduler.conf`
- `admin.conf` / `kubelet.conf` / `super-admin.conf`（kubeadm 配置文件）
- etcd 相关：`apiserver-etcd-client.crt`、`etcd/server.crt`、`etcd/peer.crt`、`etcd/healthcheck-client.crt`

> **结论：这一类证书有效期 1 年，必须在到期前用 `kk certs renew` 续期。**

## 二、为什么不能在安装时把证书签得更长？

很多人问：能不能在 `kk create cluster` 时配置一个字段，让 kubeadm 一次性把证书签成 10 年？

**答案：不能。这是 Kubernetes 上游（kubeadm）的硬限制，不是 kk 的限制。**

具体原因：

1. kubeadm 的 `ClusterConfiguration`（`kubeadm.k8s.io/v1beta3` / `v1beta4`）**根本没有"证书有效期"这个配置字段**。证书有效期是写死在 kubeadm 二进制里的常量。
2. kk 的 kubeadm 配置模板（`kubeadm-init.v1beta3` / `v1beta4`）完整覆盖了 kubeadm 暴露的所有可配置项，没有任何一项能影响证书有效期。
3. 这是 Kubernetes 社区的设计哲学：**短期证书 + 定期轮转**，而非超长有效期证书。各大云厂商（GKE/EKS/AKS）也都是这个思路。

所以，**不存在任何 config 字段能让 `kk create cluster` 把 kubeadm 证书签成 10 年**。这跟 kk 怎么实现无关——即使把 kubeadm 的所有配置都用尽，证书有效期依然是 1 年。

## 三、怎么续期：`kk certs renew`

kk 提供了专门的证书续期命令，一行搞定控制面 + etcd + 镜像仓库证书的续期。

### 命令

```sh
kk certs renew -c <config.yaml> -i <inventory.yaml>
```

示例（使用安装集群时相同的 config 和 inventory）：

```sh
kk certs renew -c config.yaml -i inventory.yaml
```

### 这个命令做了什么

对应 playbook：`builtin/core/playbooks/certs_renew.yaml`；命令定义：`cmd/kk/app/builtin/certs.go`。

执行流程：

1. 在所有控制面节点上执行 `kubeadm certs renew all`，续期 kubeadm 生成的全部控制面证书（apiserver / controller-manager / scheduler / etcd 等）。
2. 续期 kk 自签的 etcd 证书、镜像仓库证书（`roles/certs/renew/`）。
3. 重启控制面组件（apiserver / controller-manager / scheduler）使新证书生效。

### 续期时机

kubeadm 控制面证书默认 1 年。建议：

- **装完集群后立即记下到期日**（见下文查看方法）。
- 在到期前 **1 个月**左右执行 `kk certs renew`，留出缓冲时间，不要等到最后一天。

### 续期前后不需要重启整个集群

`kk certs renew` 只会重启控制面静态 Pod（apiserver/controller-manager/scheduler 的 static pod），worker 节点和业务 Pod 不受影响。续期过程通常在几分钟内完成。

## 四、查看证书到期时间

### 方法 1：在控制面节点上用 kubeadm 查看（推荐）

```sh
# 在任意一个 control-plane 节点上执行（需要 root）
sudo kubeadm certs check-expiration
```

输出示例：

```
CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY   EXTERNALLY MANAGED
admin.conf                 Dec 31, 2026 12:00 UTC   364d            ca                      no
apiserver                  Dec 31, 2026 12:00 UTC   364d            ca                      no
apiserver-etcd-client      Dec 31, 2026 12:00 UTC   364d            etcd-ca                 no
...
```

`RESIDUAL TIME` 就是剩余有效期。当它接近 0（比如小于 30d）时，就该续期了。

### 方法 2：用 openssl 查看单个证书

```sh
# 查看 apiserver 证书有效期
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -dates

# 查看 etcd 证书有效期
sudo openssl x509 -in /etc/kubernetes/pki/etcd/server.crt -noout -dates
```

输出：

```
notBefore=Jan  1 00:00:00 2026 GMT
notAfter=Dec 31 00:00:00 2026 GMT
```

`notAfter` 就是到期时间。

## 五、常见误区澄清

### 误区 1："证书到期 = 所有 Pod 起不来"

**错误。** 证书到期只影响**控制面组件之间**的 TLS 通信（apiserver ↔ etcd、apiserver ↔ kubelet 等）。业务 Pod 的 Pending/CrashLoopBackOff 绝大多数是其他原因（调度失败、镜像拉取失败、StorageClass 缺失、资源配置不足等）。

如果 Pod 状态是 `Pending`（而非 `CrashLoopBackOff` 或节点 `NotReady`），基本可以排除证书问题。Pending 用 `kubectl describe pod <pod> -n <ns>` 看 Events 即可定位。

### 误区 2："可以在 config 里把证书有效期配成 10 年一劳永逸"

**错误。** 如本文档第二节所述，kubeadm 不暴露证书有效期配置项，这是上游硬限制。config 里能配的 `certs.*.date` 只影响 kk 自签的 CA/etcd 证书（已经是 10 年），影响不了 kubeadm 控制面证书。

### 误区 3："kubelet 证书每年要手动换一次"

**错误。** `KubeletConfiguration` 里 `rotateCertificates: true` 让 kubelet 客户端证书自动轮转，无需手动操作。

## 六、操作清单（速查）

| 操作 | 命令 / 方法 | 频率 |
|------|-----------|------|
| 查看到期时间 | `sudo kubeadm certs check-expiration` | 定期（如每月） |
| 续期所有证书 | `kk certs renew -c config.yaml -i inventory.yaml` | 到期前 1 个月（约每年一次） |
| 调整 kk 自签 CA 有效期 | config 里 `certs.ca.date: 87600h` | 仅安装时，默认已是 10 年 |

## 附：相关源码位置

| 文件 | 作用 |
|------|------|
| `builtin/core/roles/defaults/defaults/main/02-certs.yaml` | kk 自签证书的有效期与策略配置 |
| `builtin/core/roles/certs/init/tasks/main.yaml` | 安装时签发证书的逻辑 |
| `builtin/core/roles/kubernetes/init-kubernetes/templates/kubeadm/kubeadm-init.v1beta3` | kubeadm 配置模板（v1beta3，含 `rotateCertificates: true`） |
| `builtin/core/roles/kubernetes/init-kubernetes/templates/kubeadm/kubeadm-init.v1beta4` | kubeadm 配置模板（v1beta4） |
| `builtin/core/playbooks/certs_renew.yaml` | 证书续期 playbook |
| `builtin/core/roles/certs/renew/` | 证书续期各步骤任务 |
| `cmd/kk/app/builtin/certs.go` | `kk certs renew` 命令定义 |
