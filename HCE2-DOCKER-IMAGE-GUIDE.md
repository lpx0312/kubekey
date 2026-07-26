# HCE 2.0 Docker 镜像制作指南（实测无坑版）

> 基于 Huawei Cloud EulerOS 2.0，参考华为文档 [EDOC1100403146 cb7b32d1](https://support.huawei.com/enterprise/zh/doc/EDOC1100403146/cb7b32d1) 与 [HCE 用户指南](https://support.huaweicloud.com/intl/zh-cn/usermanual-hce/hce_manual_docker.html)。
> 本文档所有命令均已在华为云 HCE 2.0 机器（115.120.117.219）上实测跑通，并修复了官方文档在特定环境下的踩坑点。

---

## 0. 环境前提

- 一台 HCE 2.0 机器（本文示例：`115.120.117.219`，root 用户）
- 能访问 `http://repo.huaweicloud.com/hce/2.0/`
- `/etc/yum.repos.d/hce.repo` 已正确配置（见下）

`hce.repo` 内容（正常情况出厂就有，无需改动）：

```ini
[base]
name=HCE $releasever base
baseurl=http://repo.huaweicloud.com/hce/$releasever/os/$basearch/
enabled=1
gpgcheck=1
gpgkey=http://repo.huaweicloud.com/hce/$releasever/os/RPM-GPG-KEY-HCE-2

[updates]
name=HCE $releasever updates
baseurl=http://repo.huaweicloud.com/hce/$releasever/updates/$basearch/
enabled=1
gpgcheck=1
gpgkey=http://repo.huaweicloud.com/hce/$releasever/updates/RPM-GPG-KEY-HCE-2
```

---

## ⚠️ 制作前必读：两个官方文档没说、但会让你直接卡死的坑

### 坑 1：`/tmp` 是 tmpfs（内存盘），容量只有 ~400MB

华为云 HCE 出厂把 `/tmp` 挂成 tmpfs：

```
tmpfs on /tmp type tmpfs (rw,nosuid,nodev,size=413580k,...)   # 只有 ~404MB
```

而官方文档第二步让你把 rootfs 建在 `/tmp/docker_rootfs`。yum 一装 146 个包（~270MB 安装体积 + rpm 缓存），瞬间撑爆 tmpfs，报错：

```
Error: Transaction test error:
  installing package ... needs 66MB more space on the / filesystem
Disk Requirements:
   At least 66MB more space needed on the / filesystem.
```

**注意**：这里的 "/ filesystem" 指的是那个 404MB 的 tmpfs，**不是**宿主机根盘。宿主机根盘（`/dev/vda1`）通常有几十 GB 空闲，根本不缺空间。`df -h /` 和 `df -h /tmp` 一对比就能看出来。

**解决**：把工作目录放到**真磁盘**上（本文统一用 `/root/docker_rootfs`），不要用 `/tmp`。

### 坑 2：yum 必须加 `-y`，否则非交互模式下直接 abort

在 SSH 远程/脚本/nohup 等非 TTY 环境下，yum 遇到确认提示 `Is this ok [y/N]:` 时，**默认回答 N**，直接 `Operation aborted.` 退出：

```
Total download size: 69 M
Installed size: 270 M
Is this ok [y/N]: Operation aborted.
```

且退出码为 1。官方文档示例里常省略 `-y`，照抄必踩。

**解决**：所有 yum 命令一律加 `-y`。

---

## 1. 整体流程

```
配置 repo源 ──► 新建rootfs目录 ──► yum --installroot 装基础包
                                              │
                                              ▼
              docker import ◄── tar打包(xz) ◄── chroot精简(删/boot,man,doc,cache等)
                  │
                  ▼
            docker run 验证
```

---

## 2. 逐步操作

### 第 0 步：确认磁盘空间（避开坑 1）

```bash
df -h / /tmp
mount | grep "on /tmp "
```

**判断标准**：
- 如果 `/tmp` 是 tmpfs 且 `size` 只有几百 MB → **工作目录必须放 `/root`，不要放 `/tmp`**
- 如果 `/tmp` 在普通磁盘上（`/dev/vd*`）且空间充足 → 用 `/tmp` 也行

本文后续一律用 `/root/docker_rootfs`，两种情况都安全。

### 第 1 步：新建 rootfs 目录

```bash
# 清理可能残留的旧目录（首次制作可跳过）
rm -rf /root/docker_rootfs
mkdir -p /root/docker_rootfs
```

### 第 2 步：用 yum --installroot 安装基础包（核心步骤）

```bash
yum -y \
    --installroot=/root/docker_rootfs \
    --releasever=2.0 \
    --setopt=install_weak_deps=false \
    install \
        bash yum coreutils security-tool procps-ng vim-minimal \
        tar findutils filesystem hce-repos hce-rootfiles cronie
```

参数说明：
- `-y`：自动确认（**坑 2**，必加）
- `--installroot=/root/docker_rootfs`：把包装进这个目录而不是宿主系统
- `--releasever=2.0`：指定 HCE 版本（chroot 目录里没有 `/etc/os-release`，必须显式指定，否则 `$releasever` 解析不出）
- `--setopt=install_weak_deps=false`：不装弱依赖，减小体积

预期结果：安装约 **146 个包**，下载 69MB，安装后占用约 270MB。

```
Complete!
```

> **如果这一步报空间不足**：回到第 0 步，你一定是把目录建在 `/tmp`(tmpfs) 上了。改用 `/root/docker_rootfs` 即可。

### 第 3 步：验证 rootfs 可用

```bash
ls /root/docker_rootfs/                      # 应有 bin boot etc usr var 等完整目录
rpm --root=/root/docker_rootfs -qa | wc -l   # 应为 147 左右
ls /root/docker_rootfs/bin/bash              # 必须存在
ls /root/docker_rootfs/usr/bin/yum           # 必须存在
```

### 第 4 步：chroot 精简镜像（减小体积）

官方文档第三步想用 `yum remove` 删除 `security-tool`、`cronie`、`systemd`。**但在 HCE 2.0 上这三个删不掉**——它们分别是 `sudo`、`dnf` 的受保护依赖：

```
Error: The operation would result in removing the following protected packages: sudo / dnf
```

强删（`rpm -e --nodeps`）会破坏镜像内的包管理器，**不要这么做**。容器里这些服务本来就不会被 systemd 拉起，保留只是多占点磁盘，无功能影响。

真正有效且安全的精简是**删文件**（实测 378M → 248M）：

```bash
# 1. 删除内核/启动相关（容器用不到）
rm -rf /root/docker_rootfs/boot/*

# 2. 删除文档/手册/locale（镜像最小化的常规操作）
rm -rf /root/docker_rootfs/usr/share/man/*
rm -rf /root/docker_rootfs/usr/share/doc/*
rm -rf /root/docker_rootfs/usr/share/info/*
rm -rf /root/docker_rootfs/usr/share/mime/*
rm -rf /root/docker_rootfs/usr/share/locale/*

# 3. 清理缓存和日志
rm -rf /root/docker_rootfs/var/cache/*
rm -rf /root/docker_rootfs/var/log/*

# 4. 清空 machine-id（每个容器应有独立 ID，不能沿用宿主机的）
> /root/docker_rootfs/etc/machine-id

# 5. 查看精简后大小
du -sh /root/docker_rootfs
```

> 说明：删除 `/usr/share/locale/*` 会让镜像只剩英文 locale。如果业务需要中文等其他 locale，跳过这一行。

### 第 5 步：打包成 tar.xz 归档

```bash
cd /root/docker_rootfs
tar --numeric-owner -cf /root/hce-docker.x86_64.tar .
cd /root
xz -T0 -6 hce-docker.x86_64.tar        # -T0 多线程，-6 压缩等级（体积/速度平衡）
ls -lh /root/hce-docker.x86_64.tar.xz
```

参数说明：
- `--numeric-owner`：用数字 UID/GID 而非名字，避免导入后属主错乱
- `-T0`：使用所有 CPU 核心，加速压缩
- `-6`：默认等级（-9 太慢，体积差别不大）

预期：232MB 的 tar 压缩后约 **50MB**。

> 也可以一步到位：`tar --numeric-owner -cJf /root/hce-docker.x86_64.tar.xz -C /root/docker_rootfs .`（`-J` = tar 内置 xz）

### 第 6 步：安装 docker（如果机器上没有）

HCE 官方源提供 `docker-engine`（华为维护的 docker 分支）：

```bash
# 确认包是否存在
yum list available docker-engine

# 安装
yum -y install docker-engine

# 启动并设置开机自启
systemctl enable --now docker

# 验证
docker --version
docker info | grep -E "Server Version|Storage Driver|Cgroup Driver"
```

预期输出：
```
Docker version 18.09.0, build c8237b0
Server Version: 18.09.0
Storage Driver: overlay2
Cgroup Driver: cgroupfs
```

### 第 7 步：导入镜像

```bash
docker import /root/hce-docker.x86_64.tar.xz hce:2.0
docker images
```

预期：
```
REPOSITORY          TAG                 IMAGE ID            CREATED             SIZE
hce                 2.0                 0c87601e1b42        ...                 235MB
```

### 第 8 步：验证镜像

```bash
# 查看系统信息
docker run --rm hce:2.0 cat /etc/os-release

# 验证 bash 和 yum
docker run --rm hce:2.0 bash -c 'echo $BASH_VERSION; yum --version'

# 验证基础环境
docker run --rm hce:2.0 bash -c 'id; ls /'
```

预期：
```
NAME="Huawei Cloud EulerOS"
VERSION="2.0 (x86_64)"
ID="hce"
PRETTY_NAME="Huawei Cloud EulerOS 2.0 (x86_64)"
```

---

## 3. 一键脚本

把上面整合成一个可重复执行的脚本（幂等，已存在则覆盖）：

```bash
#!/bin/bash
# HCE 2.0 Docker 镜像制作脚本（实测无坑版）
set -euo pipefail

ROOTFS=/root/docker_rootfs
ARCHIVE=/root/hce-docker.x86_64.tar.xz
IMAGE_TAG=hce:2.0

echo "===== [1/7] 清理并新建 rootfs 目录 ====="
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"

echo "===== [2/7] yum --installroot 安装基础包 ====="
yum -y \
    --installroot="$ROOTFS" \
    --releasever=2.0 \
    --setopt=install_weak_deps=false \
    install bash yum coreutils security-tool procps-ng vim-minimal \
            tar findutils filesystem hce-repos hce-rootfiles cronie

echo "===== [3/7] 精简镜像（删 /boot, man, doc, locale, cache, log）====="
rm -rf "$ROOTFS/boot/*"
rm -rf "$ROOTFS"/usr/share/{man,doc,info,mime,locale}/*
rm -rf "$ROOTFS"/var/{cache,log}/*
> "$ROOTFS/etc/machine-id"

echo "===== [4/7] 打包 tar.xz ====="
rm -f "$ARCHIVE"
tar --numeric-owner -cJf "$ARCHIVE" -C "$ROOTFS" .
ls -lh "$ARCHIVE"

echo "===== [5/7] 确保 docker 已安装并运行 ====="
command -v docker >/dev/null || yum -y install docker-engine
systemctl is-active docker >/dev/null || systemctl enable --now docker

echo "===== [6/7] docker import ====="
docker import "$ARCHIVE" "$IMAGE_TAG"

echo "===== [7/7] 验证 ====="
docker run --rm "$IMAGE_TAG" bash -c 'cat /etc/os-release | grep PRETTY; echo "bash=$BASH_VERSION"; yum --version | head -1'

echo ""
echo "✅ 完成！镜像: $IMAGE_TAG"
docker images "$IMAGE_TAG"
```

保存为 `/root/build-hce-docker.sh`，执行：

```bash
chmod +x /root/build-hce-docker.sh
/root/build-hce-docker.sh
```

---

## 4. 产物清单

| 产物 | 路径 | 说明 |
|------|------|------|
| rootfs 目录 | `/root/docker_rootfs` | 约 248MB，147 个包 |
| 归档文件 | `/root/hce-docker.x86_64.tar.xz` | 约 50MB（xz 压缩） |
| docker 镜像 | `hce:2.0` | 约 235MB |

**导出镜像到其他机器**：

```bash
# 在本机导出
docker save hce:2.0 -o /root/hce-2.0.docker.tar
# scp 到目标机后导入
docker load -i hce-2.0.docker.tar
```

或者直接拷贝 `hce-docker.x86_64.tar.xz`，在目标机 `docker import hce-docker.x86_64.tar.xz hce:2.0`。

---

## 5. 踩坑速查表

| 现象 | 原因 | 解决 |
|------|------|------|
| `needs XXMB more space on the / filesystem` | rootfs 建在 `/tmp`(tmpfs,~400MB) 上 | 改用 `/root/docker_rootfs`（真磁盘） |
| `Is this ok [y/N]: Operation aborted.` | yum 非 TTY 下默认回答 N | 加 `-y` 参数 |
| `would result in removing protected packages: sudo/dnf` | 想删 security-tool/cronie/systemd 但它们是受保护依赖 | 不要删，改为删文件精简（见第 4 步） |
| `$releasever` 解析失败 / 装错版本 | chroot 目录无 `/etc/os-release` | yum 加 `--releasever=2.0` |
| nohup `&` 后台命令被拦截 / 不执行 | 某些环境对后台命令有限制 | 用前台执行 + MCP 大超时，或写成脚本 |
| 容器里中文 locale 乱码 | 删了 `/usr/share/locale/*` | 保留 locale，或按需只删非中文 |

---

## 6. 与官方文档的差异说明

| 点 | 官方文档 | 本文档 | 原因 |
|----|----------|--------|------|
| 工作目录 | `/tmp/docker_rootfs` | `/root/docker_rootfs` | 华为云 `/tmp` 是 404MB tmpfs，会爆盘 |
| yum 参数 | 无 `-y` | 加 `-y` | 非交互环境必须，否则 abort |
| `--releasever` | 未提及 | 显式 `2.0` | chroot 目录无 os-release，避免版本解析问题 |
| 删 security-tool/cronie/systemd | 建议删 | **不删** | HCE 2.0 下是受保护依赖，删不了；删了会破坏包管理器 |
| 精简方式 | 删包 | 删文件(/boot,man,doc,locale,cache,log) | 安全有效，实测 378M→248M |
| docker 版本 | 未指定 | `docker-engine`(18.09,HCE 官方源) | HCE 源自带，免额外配置 docker-ce repo |

---

## 参考

- [制作Docker镜像并启动容器 (EDOC1100403146)](https://support.huawei.com/enterprise/zh/doc/EDOC1100403146/cb7b32d1)
- [HCE 2.0 用户指南 - 制作Docker镜像](https://support.huaweicloud.com/intl/zh-cn/usermanual-hce/hce_manual_docker.html)
- [在HCE上安装Docker（最佳实践）](https://support.huaweicloud.com/bestpractice-hce/hce_bp_0002.html)
