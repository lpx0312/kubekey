# KubeKey 集群证书说明与续期指南

本文档说明 KubeKey（以下简称 kk）安装的 Kubernetes 集群中，各类证书的有效期、是否需要手动管理，自动续期机制如何工作，以及需要手动处理的部分。

## 背景：为什么要关注证书

Kubernetes 集群大量使用 TLS 证书来保证组件间通信安全。证书一旦过期，apiserver、etcd 等核心组件会无法工作，整个集群不可用。因此需要提前了解证书有效期，并在到期前完成续期。

很多人担心"每年都要换证书很麻烦"，本文档把这个事情讲清楚——结论是：**大部分证书 kk 已经自动处理了，只有一类需要少量手动操作。**

---

## 一、集群里的四类证书

kk 安装的集群涉及四类证书，有效期和管理方式各不相同：

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

kubelet 连接 apiserver 用的客户端证书（`/var/lib/kubelet/pki/kubelet-client-current.pem`）。虽然 kubeadm 签发时默认有效期只有 1 年，但 kk 生成的 `KubeletConfiguration` 里**硬编码开启了自动轮转**：

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
rotateCertificates: true    # 关键：kubelet 客户端证书自动轮转
```

模板位置：`builtin/core/roles/kubernetes/init-kubernetes/templates/kubeadm/kubeadm-init.v1beta3`（和 `v1beta4`）。

> **结论：`rotateCertificates: true` 开启后，kubelet 客户端证书到期前会自动向 apiserver 申请新证书并替换，无需手动操作。**

### 第三类：kubeadm 生成的控制面组件证书（1 年，timer 自动续期 ✅）

kube-apiserver、kube-controller-manager、kube-scheduler 的服务端证书，由 kubeadm 签发，**默认有效期只有 1 年**。

**好消息是：kk 在安装时已经自动部署了定时续期机制（见第二节），正常情况下无需手动干预。**

涉及的具体证书（在**控制面节点**的 `/etc/kubernetes/pki/` 下）：

- `apiserver.crt` / `apiserver.key`
- `apiserver-kubelet-client.crt` / `.key`
- `front-proxy-client.crt` / `.key`
- `controller-manager.conf`
- `scheduler.conf`
- `admin.conf` / `kubelet.conf` / `super-admin.conf`（kubeadm 配置文件）
- etcd 相关：`apiserver-etcd-client.crt`、`etcd/server.crt`、`etcd/peer.crt`、`etcd/healthcheck-client.crt`

> **结论：这一类证书有效期 1 年，但 kk 已自动部署 timer 定时续期（见第二节）。万一自动续期失效，可用 `kk certs renew` 手动续期（见第三节）。**

### 第四类：kubelet 服务端证书（1 年，需手动续期 ⚠️）

kubelet 的**服务端**证书（`/var/lib/kubelet/pki/kubelet.crt`），用于 apiserver 回连 kubelet（`kubectl exec`、`kubectl logs`、`kubectl port-forward` 等操作）。

这个证书**不在 kubeadm 的管理范围内**（`kubeadm certs renew all` 不会续它），是 kubelet 在首次启动时**自签**的，有效期 1 年。

| 特性 | 说明 |
|------|------|
| 位置 | `/var/lib/kubelet/pki/kubelet.crt`（所有节点都有） |
| 签发者 | kubelet 自签（`CN=<hostname>-ca`） |
| 有效期 | 1 年 |
| 是否自动续期 | ❌ **不自动续期**（`RotateKubeletServerCertificate` feature gate 虽默认 true，但 kubelet 不轮转自签证书） |
| 到期影响 | `kubectl exec/logs/port-forward` 报 `x509: certificate has expired`；**不影响节点 Ready**（节点心跳走客户端证书） |

> **结论：这一类证书有效期 1 年，到期前需手动续期（见第四节）。续期方法很简单，单台中断约 2 秒。**

---

## 二、控制面证书自动续期机制（kk 已自动部署）

kk 在安装集群时（`create cluster` / `add nodes`），会在**每个控制面节点**上自动部署一套证书自动续期机制，由三个文件组成：

### 1. 续期脚本 `renew_script.sh`

**位置**：`/usr/local/bin/kube-scripts/renew_script.sh`

**核心逻辑**：
1. 用 `kubeadm certs check-expiration` 获取所有证书的剩余天数
2. 取**最早过期**的那个证书的剩余天数
3. 如果剩余天数 **< 30 天**，才执行续期：
   - 运行 `kubeadm certs renew all`（续期所有控制面证书）
   - 用 `crictl rmp -f` 重启控制面 static pod（apiserver / controller-manager / scheduler / etcd）
   - 更新 `/root/.kube/config`
4. 等待 apiserver 的 6443 端口恢复

**关键设计**：平时每周检查一次，只有证书剩余 < 30 天才真正动手续期，避免频繁重启控制面。

### 2. systemd service `k8s-certs-renew.service`

**位置**：`/etc/systemd/system/k8s-certs-renew.service`

```ini
[Unit]
Description=Renew K8S control plane certificates
[Service]
Type=oneshot
ExecStart=/usr/local/bin/kube-scripts/renew_script.sh
```

`Type=oneshot` 表示执行一次就退出，常驻服务。

### 3. systemd timer `k8s-certs-renew.timer`

**位置**：`/etc/systemd/system/k8s-certs-renew.timer`

```ini
[Unit]
Description=Timer to renew K8S control plane certificates
[Timer]
OnCalendar=Mon *-*-* 03:00:00        # 每周一凌晨 3 点触发
Unit=k8s-certs-renew.service
[Install]
WantedBy=multi-user.target
```

**每周一凌晨 3:00** 自动触发 service，进而执行续期脚本。

### 部署范围：只有控制面（master）节点

源码位置：`builtin/core/roles/kubernetes/certs/tasks/main.yaml`，在 `create_cluster.yaml` 里的调用条件：

```yaml
- role: kubernetes/certs
  when:
    - .kubernetes.certs.renew
    - .groups.kube_control_plane | has .inventory_hostname   # ← 只给 master
```

**只有 master（control-plane）节点会部署这套机制。** worker 节点没有（也不需要——worker 不跑 apiserver 等控制面组件）。

如果集群有 3 个 master，那 3 个 master 各自独立部署 timer，到期前各自独立触发续期。

### 自动续期工作流程图

```
每周一 03:00 (每个 master 独立运行):
  ┌──────────────────────────────────────────────────┐
  │ timer 触发 k8s-certs-renew.service               │
  │           ↓                                      │
  │ 执行 renew_script.sh                             │
  │   1. kubeadm certs check-expiration 获取剩余天数 │
  │   2. 最早过期的证书剩余 ≥ 30 天?                 │
  │      ├─ 是 → 只打印状态,什么都不做 (结束)        │
  │      └─ 否 → 执行续期:                           │
  │           a. kubeadm certs renew all             │
  │           b. crictl rmp 重启控制面 static pod     │
  │           c. 更新 /root/.kube/config             │
  │           d. 等待 apiserver 6443 恢复             │
  └──────────────────────────────────────────────────┘
```

### 检查自动续期是否正常工作

```sh
# 1. timer 是否启用且 active
systemctl is-enabled k8s-certs-renew.timer
systemctl is-active k8s-certs-renew.timer

# 2. 下次触发时间
systemctl list-timers k8s-certs-renew.timer

# 3. 手动触发一次（证书未到期不会真的续，只检查）
systemctl start k8s-certs-renew.service
systemctl status k8s-certs-renew.service     # 应为 status=0/SUCCESS

# 4. 查看执行日志
journalctl -u k8s-certs-renew.service -n 20 --no-pager
```

### ⚠️ 已知问题：源码模板的 bug（影响 v4.0.5 及之前版本）

kk v4.0.5 的源码模板 `builtin/core/roles/kubernetes/certs/templates/renew_script.sh` 存在两个 bug，导致**用该版本安装的集群，自动续期机制实际不生效**：

1. **脚本换行被吃掉**：Go template 的 `{{- -}}` trim 掉了换行符，导致生成的 `renew_script.sh` 第一行变成 `#!/bin/bashkubeadmCerts='...'getCertValidDays() {`（三行挤一行），bash 无法执行。
2. **service 文件名不匹配**：`k8s-certs-renew.service` 的 `ExecStart` 指向 `k8s-certs-renew.sh`，但实际部署的脚本叫 `renew_script.sh`，timer 触发时找不到脚本。

**症状**：`journalctl -u k8s-certs-renew.service` 显示 `No entries`（从未成功执行过）。

**手动修复方法**（已在生产环境验证）：

```sh
# 1. 修复 service 的 ExecStart 路径
sed -i "s|k8s-certs-renew.sh|renew_script.sh|" /etc/systemd/system/k8s-certs-renew.service
systemctl daemon-reload

# 2. 替换损坏的 renew_script.sh（内容见下方"修复版脚本"）
#    确保第一行是干净的 #!/bin/bash
chmod +x /usr/local/bin/kube-scripts/renew_script.sh

# 3. 验证
systemctl start k8s-certs-renew.service
systemctl status k8s-certs-renew.service     # 应为 SUCCESS
```

**修复版脚本**（`/usr/local/bin/kube-scripts/renew_script.sh`）：

```bash
#!/bin/bash
set -euo pipefail

kubeadmCerts='/usr/local/bin/kubeadm certs'

# 返回最早过期的 kubeadm 证书的剩余天数。
# 使用 kubeadm 打印的 "RESIDUAL TIME" 列（如 "364d"），比自己解析日期更可靠。
getCertValidDays() {
  local minDays
  minDays=$(${kubeadmCerts} check-expiration 2>/dev/null \
    | grep -oE '[0-9]+d' \
    | grep -oE '[0-9]+' \
    | sort -n | head -n 1)
  if [ -z "${minDays}" ]; then
    echo "9999"   # 无法确定时假设还很远，跳过续期（安全兜底）
    return
  fi
  echo -n "${minDays}"
}

echo "## Expiration before renewal ##"
${kubeadmCerts} check-expiration

days=$(getCertValidDays)
echo "## Earliest cert residual days: ${days} ##"

if [ "${days}" -lt 30 ]; then
  echo "## Renewing certificates managed by kubeadm ##"
  ${kubeadmCerts} renew all

  echo "## Restarting control plane pods managed by kubeadm ##"
  $(which crictl) pods --namespace kube-system \
    --name 'kube-scheduler-*|kube-controller-manager-*|kube-apiserver-*|etcd-*' -q \
    | /usr/bin/xargs $(which crictl) rmp -f

  echo "## Updating /root/.kube/config ##"
  cp /etc/kubernetes/admin.conf /root/.kube/config
fi

echo "## Waiting for apiserver to be up again ##"
until printf "" 2>>/dev/null >>/dev/tcp/127.0.0.1/6443; do sleep 1; done

echo "## Expiration after renewal ##"
${kubeadmCerts} check-expiration
```

---

## 三、手动续期控制面证书：`kk certs renew`

如果自动续期机制失效（比如上节的 bug 没修复），或你想主动续期，可以用 kk 提供的命令。

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

### 在单个节点上手动续期（不用 kk 命令）

如果只想续某一台 master，直接在该节点上执行：

```sh
kubeadm certs renew all
# 重启控制面 static pod
crictl pods --namespace kube-system \
  --name 'kube-scheduler-*|kube-controller-manager-*|kube-apiserver-*|etcd-*' -q \
  | xargs crictl rmp -f
# 更新 kubeconfig
cp /etc/kubernetes/admin.conf /root/.kube/config
```

### 续期时机

kubeadm 控制面证书默认 1 年。建议：

- **装完集群后立即记下到期日**（见第五节查看方法）。
- 确认自动续期 timer 正常工作（见第二节检查方法）。
- 如果自动续期已生效，**无需手动操作**；如果不放心，在到期前 1 个月手动跑一次 `kk certs renew`。

### 续期前后不需要重启整个集群

续期只会重启控制面静态 Pod（apiserver/controller-manager/scheduler 的 static pod），worker 节点和业务 Pod 不受影响。续期过程通常在几分钟内完成。

---

## 四、kubelet 服务端证书（kubelet.crt）的手动续期

这是**唯一需要手动处理**的证书（见第一节第四类）。

### 为什么需要手动

`kubelet.crt` 是 kubelet 自签的服务端证书，有效期 1 年。它**不在 kubeadm 管理范围**，自动续期脚本（`renew_script.sh`）和 `kk certs renew` 都不会续它。kubelet 虽然有 `RotateKubeletServerCertificate` feature gate（v1.31 默认 true），但**不会轮转自签的证书**——只有通过 CSR 从 apiserver 获取的证书才会被轮转，而自签证书不走这个流程。

### 续期方法

在**每个节点**（master + worker）上执行：

```sh
rm -f /var/lib/kubelet/pki/kubelet.crt /var/lib/kubelet/pki/kubelet.key
systemctl restart kubelet
```

kubelet 重启时会发现证书不存在，自动重新自签一个新的（有效期 1 年）。

### 实测影响（可放心操作）

经过生产环境实测，单台节点的中断情况：

| 指标 | 结果 |
|------|------|
| kubelet.crt 重新生成 | **约 2 秒** |
| kubelet 恢复 active | **约 2 秒** |
| 节点状态 | **全程 Ready**（从未 NotReady） |
| 业务 Pod | **无影响**（容器继续运行） |
| 新证书有效期 | 重新签发日起 1 年 |

**为什么几乎无影响**：
- kubelet 重启极快（1-2 秒）
- kubelet 启动时发现没有 crt，第一件事就是自签一个，不存在"无证书真空期"
- k8s 判断节点 NotReady 的阈值是 `node-monitor-grace-period`（默认 40 秒），2 秒的中断远低于阈值

### 操作顺序（重要！）

**多个节点必须逐台操作，不能同时进行：**

```sh
# 正确做法：逐台，每台等 Ready 后再做下一台
节点1 rm + restart → kubectl get nodes 确认 Ready → 节点2 rm + restart → 确认 Ready → ...
```

**为什么不能同时**：三台 master 同时重启 kubelet，那 2 秒内所有 apiserver 短暂不可用，有 etcd quorum 风险。逐台操作则始终有足够数量的 master 正常运行。

每台间隔约 5-10 秒（等 Ready），3 台 master 约 30 秒完成。

> **worker 节点**可以更随意——worker 不跑 etcd/apiserver，同时重启多个 worker 风险较低。

### 自动化建议

如果不想每年手动操作，可以把 kubelet.crt 续期逻辑加进 `renew_script.sh`（在 `kubeadm certs renew all` 之后），让 timer 同时续两类证书。但注意：
- 这个脚本只部署在 master 上，worker 节点需要单独处理
- 或者把脚本 + timer 也部署到 worker 节点

---

## 五、查看证书到期时间

### 方法 1：用 kubeadm 查看控制面证书（推荐）

在**控制面节点**上执行（需要 root）：

```sh
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

`RESIDUAL TIME` 就是剩余有效期。当它接近 0（比如小于 30d）时，就该关注了。

### 方法 2：用 openssl 查看单个证书

```sh
# 查看 apiserver 证书有效期
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -dates

# 查看 etcd 证书有效期
sudo openssl x509 -in /etc/kubernetes/pki/etcd/server.crt -noout -dates

# 查看 kubelet 服务端证书有效期（每个节点都有）
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet.crt -noout -dates
```

输出：

```
notBefore=Jan  1 00:00:00 2026 GMT
notAfter=Dec 31 00:00:00 2026 GMT
```

`notAfter` 就是到期时间。

### 方法 3：一键检查脚本

以下脚本可一次性列出节点上所有证书的到期情况：

```bash
#!/bin/bash
echo "========== kubeadm 管理的证书 =========="
kubeadm certs check-expiration 2>/dev/null
echo ""
echo "========== 所有 .crt 文件有效期 =========="
for crt in $(find /etc/kubernetes/pki /var/lib/kubelet/pki /etc/ssl/etcd -name "*.crt" 2>/dev/null); do
  enddate=$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2)
  if [ -n "$enddate" ]; then
    end_epoch=$(date -d "$enddate" +%s 2>/dev/null)
    now_epoch=$(date +%s)
    days=$(( (end_epoch - now_epoch) / 86400 ))
    if [ "$days" -lt 30 ]; then
      echo "⚠️  $crt  到期:$enddate  剩余${days}天"
    else
      echo "✅ $crt  到期:$enddate  剩余${days}天"
    fi
  fi
done
```

---

## 六、常见误区澄清

### 误区 1："证书到期 = 所有 Pod 起不来"

**错误。** 证书到期只影响**组件之间**的 TLS 通信（apiserver ↔ etcd、apiserver ↔ kubelet 等）。业务 Pod 的 Pending/CrashLoopBackOff 绝大多数是其他原因（调度失败、镜像拉取失败、StorageClass 缺失、资源配置不足等）。

如果 Pod 状态是 `Pending`（而非 `CrashLoopBackOff` 或节点 `NotReady`），基本可以排除证书问题。Pending 用 `kubectl describe pod <pod> -n <ns>` 看 Events 即可定位。

### 误区 2："可以在 config 里把证书有效期配成 10 年一劳永逸"

**错误。** kubeadm 不暴露证书有效期配置项，这是上游硬限制（见第七节）。config 里能配的 `certs.*.date` 只影响 kk 自签的 CA/etcd 证书（已经是 10 年），影响不了 kubeadm 控制面证书。

### 误区 3："kubelet 客户端证书每年要手动换一次"

**错误。** `KubeletConfiguration` 里 `rotateCertificates: true` 让 kubelet 客户端证书自动轮转，无需手动操作。

### 误区 4："kubelet.crt 会让节点 NotReady"

**错误。** `kubelet.crt` 是服务端证书，到期只影响 `kubectl exec/logs/port-forward`（apiserver 回连 kubelet）。节点心跳走的是**客户端**证书（`kubelet-client-current.pem`），不受影响，所以节点不会 NotReady。

---

## 七、为什么不能在安装时把证书签得更长？

很多人问：能不能在 `kk create cluster` 时配置一个字段，让 kubeadm 一次性把证书签成 10 年？

**答案：不能。这是 Kubernetes 上游（kubeadm）的硬限制，不是 kk 的限制。**

具体原因：

1. kubeadm 的 `ClusterConfiguration`（`kubeadm.k8s.io/v1beta3` / `v1beta4`）**根本没有"证书有效期"这个配置字段**。证书有效期是写死在 kubeadm 二进制里的常量。
2. kk 的 kubeadm 配置模板（`kubeadm-init.v1beta3` / `v1beta4`）完整覆盖了 kubeadm 暴露的所有可配置项，没有任何一项能影响证书有效期。
3. 这是 Kubernetes 社区的设计哲学：**短期证书 + 定期轮转**，而非超长有效期证书。各大云厂商（GKE/EKS/AKS）也都是这个思路。

所以，**不存在任何 config 字段能让 `kk create cluster` 把 kubeadm 证书签成 10 年**。这跟 kk 怎么实现无关——即使把 kubeadm 的所有配置都用尽，证书有效期依然是 1 年。

---

## 八、操作清单（速查）

| 证书类型 | 有效期 | 管理方式 | 操作 | 频率 |
|---------|--------|---------|------|------|
| kk 自签 CA / etcd | 10 年 | 不用管 | 无 | — |
| kubelet 客户端证书 | 1 年 | 自动轮转 | 无 | — |
| kubeadm 控制面证书 | 1 年 | timer 自动续期 | 确认 timer 正常即可 | 检查一次 |
| kubelet 服务端证书 | 1 年 | **手动续期** | `rm kubelet.crt + restart kubelet` | 约每年一次 |

### 日常检查命令

```sh
# 查看到期时间
sudo kubeadm certs check-expiration

# 确认自动续期 timer 正常
systemctl status k8s-certs-renew.timer
journalctl -u k8s-certs-renew.service -n 5
```

### 到期前操作（约每年一次）

```sh
# 1. 控制面证书：确认 timer 已自动续期（正常则无需操作）
systemctl start k8s-certs-renew.service   # 手动触发一次检查

# 2. kubelet 服务端证书：逐台续期（每台等 Ready 再做下一台）
rm -f /var/lib/kubelet/pki/kubelet.crt /var/lib/kubelet/pki/kubelet.key
systemctl restart kubelet
```

---

## 附：相关源码位置

| 文件 | 作用 |
|------|------|
| `builtin/core/roles/defaults/defaults/main/02-certs.yaml` | kk 自签证书的有效期与策略配置 |
| `builtin/core/roles/certs/init/tasks/main.yaml` | 安装时签发证书的逻辑 |
| `builtin/core/roles/kubernetes/init-kubernetes/templates/kubeadm/kubeadm-init.v1beta3` | kubeadm 配置模板（v1beta3，含 `rotateCertificates: true`） |
| `builtin/core/roles/kubernetes/init-kubernetes/templates/kubeadm/kubeadm-init.v1beta4` | kubeadm 配置模板（v1beta4） |
| `builtin/core/roles/kubernetes/certs/templates/renew_script.sh` | 自动续期脚本模板（⚠️ v4.0.5 有 bug，见第二节） |
| `builtin/core/roles/kubernetes/certs/files/k8s-certs-renew.service` | 自动续期 systemd service（⚠️ v4.0.5 文件名 bug） |
| `builtin/core/roles/kubernetes/certs/files/k8s-certs-renew.timer` | 自动续期 systemd timer（每周一 03:00） |
| `builtin/core/roles/kubernetes/certs/tasks/main.yaml` | 部署自动续期机制的任务（只给 control-plane） |
| `builtin/core/playbooks/certs_renew.yaml` | `kk certs renew` 的 playbook |
| `builtin/core/roles/certs/renew/` | `kk certs renew` 各步骤任务 |
| `cmd/kk/app/builtin/certs.go` | `kk certs renew` 命令定义 |
