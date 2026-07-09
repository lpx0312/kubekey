# 私有 Patch 维护手册

本仓库在官方 `kubesphere/kubekey` 基础上维护多个私有补丁（官方不会合并这些 PR），因此需要长期自行维护，并在官方每次发布新版本时把全部 patch 搬到新版本上。

本手册描述 patch 体系的结构、发布流程，以及新增补丁的标准操作。

## 仓库结构

```
origin     → git@github.com:lpx0312/kubekey.git     你的 fork (push 目标)
upstream   → https://github.com/kubesphere/kubekey   官方 (只读, 拉新版本)

分支:
  port-fix   ← 长期维护分支 = 官方 v4.0.5 基线 + 全部私有 patch + 本脚本/文档
                (日常就在这个分支上工作, 官方发新版后用脚本生成 vX.Y.Z-portfix tag)
  master     ← 官方 v4.0.5 原始内容 (备份, 不动)

tag:
  patch/base        → patch 基线 (官方版本, 不含任何补丁, cherry-pick 起点)
  patch/port-fix    → 全部私有补丁的最新汇总点 (cherry-pick 终点)
  vX.Y.Z-portfix    → 发布产物 = 官方 vX.Y.Z + 你的全部 patch (脚本生成)
```

### 为什么需要 patch/base 和 patch/port-fix 两个 tag

sync-patch.sh 用 **范围 cherry-pick**（`patch/base..patch/port-fix`）一次性把所有补丁搬到新版本。这两个 tag 圈定了补丁的范围：

- `patch/base` 是起点（不含补丁的官方基线）
- `patch/port-fix` 是终点（所有补丁应用完的最新 commit）
- 两个 tag 之间的所有 commit 就是全部私有补丁，无论有多少个都能一次搬过去

> 注意 tag 名 `patch/port-fix` 沿用了历史命名（最初只有端口修复一个补丁），现在它的含义已扩展为"全部私有补丁的汇总点"。

## 发布 tag 命名规则

- 官方原版 tag: `v4.0.6`           ← 来自 upstream, 只读, 不动
- 你的补丁版 tag: `v4.0.6-portfix`  ← fork 上发布, = 官方 v4.0.6 + 你的全部 patch

加 `-portfix` 后缀是为了**避免和官方同名 tag 冲突**（`git fetch upstream --tags`
不会互相覆盖）。

## 已维护的 patch 列表

| 补丁 | 改动文件 | 对应 patch 文件 |
|------|---------|----------------|
| 镜像仓库地址支持端口（`harbor:7000/...`） | `pkg/modules/image/image.go`, `pkg/modules/image/image_test.go` | `patches/0001-fix-image-support-registry-addresses-with-a-port.patch` |
| etcd 定时备份脚本修复（变量未定义 + 多端点） | `builtin/core/roles/etcd/install/templates/backup.sh` | `patches/0002-fix-etcd-backup-script-unbound-var-and-multi-endpoint.patch` |
| k8s 证书自动续期修复 + 脚本改名（template trim + 正则 + 改名） | `builtin/core/roles/kubernetes/certs/templates/k8s-certs-renew.sh`（原 renew_script.sh）, `files/k8s-certs-renew.service`, `tasks/main.yaml` | `patches/0003-fix-certs-k8s-certs-renew-timer-3-bugs-and-rename.patch` |
| NFS 默认存储类不生效（引用了错误变量） | `builtin/core/roles/storageclass/nfs/templates/values.yaml` | `patches/0004-fix-nfs-default-storageclass-wrong-variable.patch` |

`patches/` 目录下的 `.patch` 文件是每个补丁的独立归档，用于离线场景（见[离线 patch 文件](#离线-patch-文件)）。

---

## 每次官方发布新版本时（一键同步）

> 假设官方刚发布了 `v4.0.6`，要把它带上你的全部 patch。

### 前提：在 port-fix 分支上，且为最新

```bash
git checkout port-fix
git pull origin port-fix
```

确认 `patch/base` 和 `patch/port-fix` 两个 tag 都存在：
```bash
git tag -l 'patch/*'
# 应输出:
# patch/base
# patch/port-fix
```

### 触发方式（三选一）

**方式一：GitHub Actions（推荐）**

进入 [Actions → Sync Patch](https://github.com/lpx0312/kubekey/actions/workflows/sync-patch.yml) → `Run workflow` → ref 选 `port-fix` → 输入官方版本号（如 `v4.0.6`）→ 运行。约 11 分钟后自动产出 `v4.0.6-portfix` Release（补丁 + 6 平台二进制）。

**方式二：命令行触发**
```bash
gh workflow run sync-patch.yml -R lpx0312/kubekey --ref port-fix -f version=v4.0.6 -f push=true
```

**方式三：本地脚本**（需 Go 环境，网络受限时用代理 `SYNC_PROXY=...`）
```bash
./scripts/sync-patch.sh v4.0.6
```
只打补丁不推送：`./scripts/sync-patch.sh v4.0.6 --no-push`

以上三种方式都是**幂等**的：同一版本可重复运行，总是覆盖为最新结果。

### 脚本自动完成的步骤

`sync-patch.sh v4.0.6` 会自动完成：

1. 配置代理（若设置了 `SYNC_PROXY`）+ 从 upstream 拉取最新 tag
2. 检出官方 `v4.0.6` 代码（detached HEAD，**不创建任何分支**）
3. **范围 cherry-pick** 你的全部补丁（`patch/base..patch/port-fix`）
4. 运行 image 模块测试验证
5. 打发布 tag `v4.0.6-portfix`（官方原版 `v4.0.6` 不动）
6. 推送 `v4.0.6-portfix` 到 fork
7. 切回 `port-fix` 分支

完成后，你的 fork 上就有了 `v4.0.6-portfix` tag = 官方 v4.0.6 + 你的全部补丁。

---

## 新增一个私有补丁（完整流程）

> 📖 **完整无坑版教程见 [ADD-PATCH-TUTORIAL.md](ADD-PATCH-TUTORIAL.md)**，包含每一步的命令、验证方法、以及所有踩过的坑（template trim / cleanup-tag / patch 链不干净 / 网络问题 / 旧集群迁移）的详解。下面是简要步骤。

当你要加第 N 个补丁时，按以下步骤操作。核心原则：**每个补丁是 port-fix 分支上一个独立的 commit，补丁链必须是一条基于 `patch/base` 的干净直线**（不能夹杂 docs/ci 等无关 commit）。

### 第 1 步：在 port-fix 分支上做修复 commit

```bash
git checkout port-fix
git pull origin port-fix

# 编辑代码, 修复问题
vim builtin/core/roles/xxx/templates/yyy.sh

# 提交 (一个补丁对应一个 commit)
git add builtin/core/roles/xxx/templates/yyy.sh
git commit -m "fix(xxx): 简述修复内容"
```

### 第 2 步：重建干净的补丁链（关键）

新补丁的 commit 此时挂在 port-fix 分支上，和 docs/ci 等无关 commit 混在一起。需要把所有补丁重新串成一条基于 `patch/base` 的干净直线，作为新的 `patch/port-fix`。

```bash
# 基于官方基线 patch/base, 依次 cherry-pick 所有补丁 commit
# (把下面的 <补丁commit1> <补丁commit2> ... 换成实际的补丁 commit hash,
#  顺序从老到新)
git checkout --detach patch/base
git cherry-pick <补丁commit1> <补丁commit2> ... <新补丁commit>

# 确认补丁链干净 (应该只看到补丁 commit, 没有无关 commit)
git log --oneline patch/base..HEAD

# 更新 patch/port-fix 指向这条干净链的顶端
git tag -f patch/port-fix -m "Private patches: <补丁清单简述>"
```

### 第 3 步：生成 patch 归档文件

```bash
# 回到 port-fix 分支
git checkout port-fix

# 为新补丁生成独立 patch 文件 (序号递增)
git format-patch -1 <新补丁commit> --stdout > patches/000N-fix-xxx-yyy.patch
git add patches/000N-fix-xxx-yyy.patch
```

### 第 4 步：更新文档

同步更新以下文件：

- **`PATCH-MAINTENANCE.md`**：在「已维护的 patch 列表」表格加一行
- **`README.md`**：在「补丁解决了什么问题」补一节说明
- **`scripts/sync-patch.sh`**：若新补丁的冲突解决方式特殊，更新脚本里冲突提示段
- **`patches/` 目录**：已在前一步生成

### 第 5 步：提交 + 推送

```bash
git add PATCH-MAINTENANCE.md README.md scripts/sync-patch.sh patches/
git commit -m "docs(patch): add <新补丁名> patch + update tooling"

# 推送分支和 tag
git push origin port-fix
git push origin patch/port-fix --force    # --force 因为 tag 指向变了
```

> `patch/port-fix` 必须 `--force` 推送，因为它的指向每次新增补丁都会变。`patch/base` 通常不变（除非升级基线版本）。

### 第 6 步：触发发布

按「每次官方发布新版本时」的方式触发 `sync-patch.yml`，生成带新补丁的 Release。

---

## 编译 Linux 二进制（带 builtin tag）

**方式一：直接在 port-fix 分支编译**（port-fix 分支本身已含全部 patch，当前基线是 v4.0.5）：
```bash
git checkout port-fix
```

**方式二：检出某个发布的补丁版 tag 编译**（如官方已发布更高版本并用脚本生成了）：
```bash
git checkout v4.0.6-portfix
```

然后编译：
```bash
LDFLAGS=$(bash hack/version.sh)
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -tags "builtin" -ldflags "$LDFLAGS" \
  -o _output/bin/kk-linux-amd64 cmd/kk/kubekey.go
```

> 注意：必须带 `-tags builtin`，否则 `artifact` 子命令不会被编译进去。

---

## 如果 cherry-pick 时遇到冲突

官方新版本如果也改动了补丁涉及的同一处代码，范围 cherry-pick 会在某个补丁处冲突。脚本会暂停并提示冲突文件。

```bash
# 1. 查看冲突文件
git diff --name-only --diff-filter=U

# 2. 编辑冲突文件, 保留私有补丁的意图:
#    - 镜像端口修复 (image.go): host 判断应为
#      if strings.ContainsAny(firstPart, ".:") || firstPart == "localhost" {
#      并确认 import 块里已删除 "github.com/asaskevich/govalidator"
#    - etcd 备份修复 (backup.sh): snapshot save 那行 endpoints 应为
#      --endpoints="https://localhost:{{ .etcd.port }}"

# 3. 标记冲突已解决并继续 (可能需要重复解决多个补丁的冲突)
git add -A
git cherry-pick --continue

# 4. 全部补丁完成后, 手动打发布 tag 并推送
git tag -a v4.0.6-portfix -m "Release: official v4.0.6 + private patches"
git push origin refs/tags/v4.0.6-portfix
```

**冲突的核心判断标准**：每个补丁的"修复意图"必须保留。具体到当前四个补丁：
- 镜像端口修复：`normalizeImageName` 里必须是 `strings.ContainsAny(firstPart, ".:")`，不能是官方的 `govalidator.IsHost`
- etcd 备份修复：`backup.sh` 的 `snapshot save` 行必须是 localhost 单点，不能是多端点列表
- 证书续期修复：脚本已改名为 `k8s-certs-renew.sh`，不得出现 `{{- if ... <v1.20.0 }}` 死代码分支；`getCertValidDays` 必须用 `RESIDUAL TIME` 列解析；`k8s-certs-renew.service` 的 ExecStart 和 `tasks/main.yaml` 都引用 `k8s-certs-renew.sh`
- NFS 默认 SC 修复：`nfs/templates/values.yaml` 的 `defaultClass` 必须是 `.storage_class.nfs.default`，不能是 `.storage_class.local.default`

---

## 查看已发布的补丁版本

```bash
# 查看所有补丁版 tag
git tag -l '*-portfix'

# 查看某个补丁版相对官方原版多了哪些 commit
git log --oneline v4.0.6..v4.0.6-portfix

# 查看当前 patch 链包含哪些补丁
git log --oneline patch/base..patch/port-fix
```

---

## 网络问题

脚本默认不使用代理。若本地网络受限，通过环境变量开启：
```bash
SYNC_PROXY=http://127.0.0.1:7897 ./scripts/sync-patch.sh v4.0.6
```
GitHub Actions runner 在境外，直连 GitHub 无需代理。

若网络彻底拉不动官方仓库，可用 gh 通过 api.github.com 下载官方 tag tarball，再用离线 patch 文件应用（见下）。

---

## 离线 patch 文件

`patches/` 目录下有每个补丁的独立 patch 文件，按序号命名。万一某次网络彻底拉不动官方仓库，解压官方 tarball 后可直接应用：

```bash
cd /path/to/official-kubekey-source
# 按序号顺序逐个应用
git am /path/to/patches/0001-*.patch
git am /path/to/patches/0002-*.patch
git am /path/to/patches/0003-*.patch
git am /path/to/patches/0004-*.patch
# 若 git am 冲突, 改用 git apply --3way
```

当前归档的 patch 文件：

| 文件 | 说明 |
|------|------|
| `patches/0001-fix-image-support-registry-addresses-with-a-port.patch` | 镜像仓库地址支持端口 |
| `patches/0002-fix-etcd-backup-script-unbound-var-and-multi-endpoint.patch` | etcd 定时备份脚本修复 |
| `patches/0003-fix-certs-k8s-certs-renew-timer-3-bugs-and-rename.patch` | k8s 证书自动续期修复 + 脚本改名 |
| `patches/0004-fix-nfs-default-storageclass-wrong-variable.patch` | NFS 默认存储类不生效 |

---

## 四个补丁的修复要点（备查）

### 补丁 1：镜像仓库地址支持端口

```
pkg/modules/image/image.go:
  - 删除 import "github.com/asaskevich/govalidator"
  - normalizeImageName 中:
      改前: if govalidator.IsHost(firstPart) {
      改后: if strings.ContainsAny(firstPart, ".:") || firstPart == "localhost" {
```

原因：`govalidator.IsHost()` 对含 `:`（端口）的字符串返回 false，导致 `harbor:7000` 被误判为 project 名。

### 补丁 2：etcd 定时备份脚本修复

```
builtin/core/roles/etcd/install/templates/backup.sh:
  snapshot save 那行:
    改前: --endpoints="$ENDPOINTS"            (变量未定义 → unbound variable)
    改后: --endpoints="https://localhost:{{ .etcd.port }}"   (单点, 满足 etcdctl 限制)
```

原因：两个叠加 bug——(1) 脚本定义的是 `ETCD_ENDPOINTS` 但引用 `$ENDPOINTS`（未定义），配合 `set -o nounset` 必然失败；(2) 即便修好变量名，`etcdctl snapshot save` 也不支持多端点。改用 localhost 单点同时解决两个问题。

> ⚠️ 升级 kk 二进制只保证**新装的**集群备份正常；**已部署的旧集群**需手动把修好的 `backup.sh` 同步到每台 etcd 节点的 `/usr/local/bin/kube-scripts/backup_etcd.sh`。

### 补丁 3：k8s 证书自动续期修复 + 脚本改名

```
builtin/core/roles/kubernetes/certs/templates/k8s-certs-renew.sh (原 renew_script.sh):
  - 文件改名 renew_script.sh → k8s-certs-renew.sh (与 service ExecStart 名实相符)
  - 删除 {{- if .kubernetes.kube_version | semverCompare "<v1.20.0" }} 死代码分支
    (kubekey v4 最低支持 v1.23), 固定 kubeadmCerts='/usr/local/bin/kubeadm certs'
  - 开头加 set -euo pipefail
  - getCertValidDays():
      改前: grep -o "[A-Za-z]\{3,4\}\s\w\w,..." (BRE 不支持 \s\w, 永远空)
      改后: grep -oE '[0-9]+d' | grep -oE '[0-9]+' | sort -n | head -1
            解析失败兜底返回 9999 (跳过续期)

builtin/core/roles/kubernetes/certs/files/k8s-certs-renew.service:
  ExecStart: /usr/local/bin/kube-scripts/k8s-certs-renew.sh

builtin/core/roles/kubernetes/certs/tasks/main.yaml:
  src/dest 同步改为 k8s-certs-renew.sh
```

原因：三个叠加 bug——(1) Go template `{{- -}}` 贪婪 trim 把脚本挤成一行，bash 语法损坏；(2) service ExecStart 指向不存在的文件名，timer 每次必败；(3) 日期正则用 PCRE 的 `\s\w` 但 grep 默认 BRE 不支持，匹配永远为空导致误判。改名让模板、部署文件、systemd 三者名称统一。

> ⚠️ 升级 kk 二进制只保证**新装的**集群续期正常；**已部署的旧集群**需手动同步（旧集群脚本名是 `renew_script.sh`，要改名成 `k8s-certs-renew.sh`）+ 更新 `k8s-certs-renew.service`，然后 `systemctl daemon-reload && systemctl restart k8s-certs-renew.timer`。

### 补丁 4：NFS 默认存储类不生效

```
builtin/core/roles/storageclass/nfs/templates/values.yaml:
  defaultClass:
    改前: {{ .storage_class.local.default }}  (读错变量, 永远是 false)
    改后: {{ .storage_class.nfs.default }}
```

原因：模板引用了错误的变量 `storage_class.local.default`（固定 false），而非 `storage_class.nfs.default`。导致 config 里设 `nfs.default: true` 不生效，NFS SC 不被标记默认，空 storageClassName 的 PVC 永远 Pending。

> ⚠️ 升级 kk 二进制只保证**新装的**集群生效；**已部署的旧集群**可紧急止血（不改代码）：
> `kubectl patch sc nfs-client -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'`
