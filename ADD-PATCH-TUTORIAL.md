# 新增私有补丁完整教程（无坑版）

> 本教程基于实战经验总结，涵盖了新增一个私有补丁从开发到发布的**全部步骤**，并标注了每个环节的**踩坑点**。
>
> 适用前提：你已经按 [PATCH-MAINTENANCE.md](PATCH-MAINTENANCE.md) 建好了 patch 体系（`port-fix` 分支 + `patch/base`/`patch/port-fix` 双 tag）。
>
> 当前已维护 3 个补丁（端口修复 / etcd 备份 / 证书续期），本教程以"新增第 4 个补丁"为例。

---

## 全局认知：补丁体系的本质

在动手前，必须先理解这套体系的核心设计，否则一定会踩坑：

```
patch/base        → 官方基线（不含任何补丁）          ← 永远不动
patch/port-fix    → 所有补丁的最新汇总点              ← 每加一个补丁就往前挪
patches/000N-*.patch → 每个补丁的独立归档文件          ← 离线备用的快照
port-fix 分支     → 日常工作分支（基线 + 全部补丁 + 文档/脚本）
vX.Y.Z-portfix    → 发布产物 tag = 官方 vX.Y.Z + 全部补丁
```

**核心铁律（违反任何一条都会出问题）：**

1. ⚠️ `patch/base..patch/port-fix` 这条 commit 链**必须是干净的直线**——只能包含补丁 commit，**不能夹杂** docs/ci/脚本等无关 commit。否则发布的 tag 会带上一堆垃圾。
2. ⚠️ 每个补丁是这条链上的**一个独立 commit**。
3. ⚠️ 新增补丁后，`patch/port-fix` tag 必须**指向重新构建的干净链顶端**，并 `--force` 推送。
4. ⚠️ 发布流水线里**绝对不能**用 `gh release delete --cleanup-tag`（会删掉正确 tag，详见 [坑点详解](#坑点-2cleanup-tag-会毁掉正确的-tag)）。

---

## 完整流程（9 步）

下面以新增"第 4 个补丁"为例，假设补丁名叫 `fix-xxx`。

### 第 1 步：同步到最新状态

```bash
cd /path/to/kubekey
git checkout port-fix
git pull origin port-fix
git fetch origin --tags --force   # 确保 patch/* tag 是最新的
```

**验证当前 patch 链状态**（确认起点干净）：
```bash
git log --oneline patch/base..patch/port-fix
```
应该看到当前所有补丁（如 3 个），且都是 `fix(...)` 开头的补丁 commit，没有 docs/ci 夹杂。

> **坑点 0**：如果你的 `patch/base` 或 `patch/port-fix` tag 丢失或落后，后续全部步骤都会错。每次开始前务必 `git fetch origin --tags --force` 同步。

---

### 第 2 步：编写并验证修复代码

在 `port-fix` 分支上直接改代码。先分析 bug，找到要改的文件，改完做基本验证：

```bash
# 编辑目标文件
vim path/to/some/file.sh

# 如果是 Go 代码，跑测试
go test ./pkg/modules/xxx/...

# 如果是 shell 脚本，跑语法检查
bash -n path/to/some/file.sh
```

> **坑点 1（template 文件）**：如果改的是 `builtin/core/roles/*/templates/*.sh` 这类 Go template 文件，注意 `{{- }}` 的贪婪 trim 会吃掉换行符。改完要在脑子里模拟渲染后的样子，或用 `kk` 实际跑一次确认渲染结果正确。证书续期那个 bug 就是因为 `{{- if/else/end -}}` 把脚本挤成一行。
>
> **坑点 2（改对文件）**：确认你改的是**源码模板**（`builtin/core/roles/.../templates/` 或 `pkg/`），而不是某台服务器上已经渲染部署过的成品文件。源码在仓库里，成品在集群节点上。

---

### 第 3 步：在 port-fix 分支提交修复 commit

```bash
git add path/to/some/file.sh
git commit -m "fix(xxx): 简述修复内容

详细说明根因和修复方式。
"
```

commit message 规范：`fix(组件): 简述`，body 里写清楚根因。这个 message 会进 patch 文件和发布 tag，写得清楚以后好排查。

**记录这个 commit 的 hash**（下一步要用）：
```bash
NEW_PATCH_COMMIT=$(git rev-parse HEAD)
echo "新补丁 commit: $NEW_PATCH_COMMIT"
```

此时新补丁 commit 挂在 `port-fix` 分支顶端，但它的父链里夹着 docs/ci 等无关 commit。**不能直接拿这个 commit 当 patch 源**，必须做第 4 步。

> **坑点 3**：不要跳过第 4 步直接把 `patch/port-fix` 指向这个 commit。那样 `patch/base..patch/port-fix` 范围会把 docs/ci/iso 等无关 commit 全 cherry-pick 进发布 tag。

---

### 第 4 步：重建干净的补丁链（最关键的一步）

这一步把所有补丁（含新的）重新串成一条基于 `patch/base` 的干净直线。**这一步做错会导致发布 tag 带垃圾 commit，是整个流程的核心。**

#### 4.1 基于官方基线，依次 cherry-pick 所有补丁

```bash
# 切到官方基线（detached HEAD，不建分支）
git checkout --detach patch/base

# 依次 cherry-pick 所有补丁 commit，顺序从老到新
# 把下面的 hash 换成实际的补丁 commit hash
#   - 老补丁的 hash 用 'git log --oneline patch/base..patch/port-fix' 查
#   - 新补丁的 hash 用第 3 步记下的 NEW_PATCH_COMMIT
git cherry-pick <老补丁1> <老补丁2> <老补丁3> "$NEW_PATCH_COMMIT"
```

> **如何拿到老补丁的 hash**：在新终端跑 `git log --oneline patch/base..patch/port-fix`，**从下往上**（从老到新）依次取。

#### 4.2 验证链是干净的

```bash
git log --oneline patch/base..HEAD
```
应该**只看到补丁 commit**（全部是 `fix(...)` 开头），**不能有** docs/ci/iso 等无关 commit。

> **坑点 4**：如果这里看到了 docs/ci commit，说明你 cherry-pick 的源 commit 选错了——你选了 port-fix 分支上的 commit（它父链里有垃圾），而不是干净补丁链上的 commit。正确做法是老补丁从 `patch/port-fix` 的祖先里取（`git log patch/base..patch/port-fix`），新补丁用第 3 步的 hash。

#### 4.3 端到端验证补丁能干净 apply

在重建的链上确认关键文件都是修复版：
```bash
# 例：检查端口修复
grep "ContainsAny" pkg/modules/image/image.go
# 检查你的新补丁
grep "你的修复标志" path/to/your/file
```

#### 4.4 更新 patch/port-fix tag 指向新链顶

```bash
# 当前 HEAD 就是新链顶（含全部补丁）
git tag -f patch/port-fix -m "Private patches: port-fix + etcd-backup + certs-renew + <新补丁名>"
```

---

### 第 5 步：生成 patch 归档文件

回到 port-fix 分支，为新补丁生成独立的 `.patch` 文件（序号递增）：

```bash
git checkout port-fix

# 序号 = 现有最大序号 + 1（当前是 0003，下一个就是 0004）
git format-patch -1 "$NEW_PATCH_COMMIT" --stdout > patches/0004-fix-xxx-yyy.patch
```

> **注意**：`format-patch` 用的 hash 是第 3 步 port-fix 分支上的那个 commit（`$NEW_PATCH_COMMIT`），**不是**第 4 步干净链上重新生成的 hash。因为 patch 文件记录的是 diff 内容，hash 不同但 diff 一样，apply 时没问题。

验证 patch 文件内容：
```bash
head -10 patches/0004-fix-xxx-yyy.patch
```

---

### 第 6 步：更新文档

四个文件需要同步更新：

#### 6.1 `README.md`

在「补丁解决了什么问题」段，补丁数量 +1，并加一节说明：

```markdown
本仓库当前维护四个私有补丁：   ← 改数量

### 补丁 4：<简述>
**官方 bug**：...
**修复方式**（`<文件路径>`）：...
> ⚠️ 已部署的集群：...（如果是部署类补丁，写明旧集群如何手动同步）
```

#### 6.2 `PATCH-MAINTENANCE.md`

三处需要改：

**(a)「已维护的 patch 列表」表格加一行：**
```markdown
| <新补丁简述> | `<改动文件>` | `patches/0004-fix-xxx-yyy.patch` |
```

**(b)「离线 patch 文件」表格加一行：**
```markdown
| `patches/0004-fix-xxx-yyy.patch` | <新补丁简述> |
```
同时更新"按序号顺序逐个应用"示例，加上 `git am .../0004-*.patch`。

**(c)「补丁修复要点（备查）」加一节：**
```markdown
### 补丁 4：<名称>
（简述改前/改后、根因、旧集群迁移提示）
```

**(d)「冲突的核心判断标准」加一条：**
```markdown
- <新补丁名>：<关键判断标志>
```

#### 6.3 `scripts/sync-patch.sh`

更新 cherry-pick 冲突提示段，加新补丁的解决说明（第 133-141 行附近）：

```bash
echo "       - <新补丁名> (<文件>): <正确的修复标志>"
```

#### 6.4 `patches/` 目录

已在第 5 步生成。

---

### 第 7 步：提交所有改动到 port-fix 分支

把第 3 步的修复 commit（已在分支上）和第 5、6 步的文档/脚本改动一起提交。注意修复 commit 是单独一个，文档是另一个：

```bash
# 确认在 port-fix 分支
git checkout port-fix

# 提交文档/脚本/patch 文件（修复 commit 第 3 步已提交）
git add patches/0004-fix-xxx-yyy.patch README.md PATCH-MAINTENANCE.md scripts/sync-patch.sh
git commit -m "docs(patch): add <新补丁名> patch + update tooling for Nth patch

- patches/0004-*.patch: archived patch file
- README.md / PATCH-MAINTENANCE.md: document the new patch
- scripts/sync-patch.sh: extend conflict hint
"
```

---

### 第 8 步：推送到远程

两个东西要推送：**port-fix 分支** 和 **patch/port-fix tag**。

```bash
# 推送分支
git push origin port-fix

# 推送 tag（必须 --force，因为指向变了）
git push origin patch/port-fix --force
```

> **坑点 5（网络）**：`github.com` 在国内时通时断。如果 push 失败，带重试：
> ```bash
> for i in 1 2 3 4 5 6; do
>   timeout 45 git push origin port-fix && break
>   sleep 5
> done
> ```
> `patch/port-fix` 必须 `--force`，因为它从旧的"3 补丁链顶"变成了"4 补丁链顶"。`patch/base` 不变，不用推。

**验证推送成功**：
```bash
# 确认远程 tag 指向最新链顶
gh api repos/lpx0312/kubekey/git/refs/tags/patch/port-fix --jq '.object.sha[:7]'
```

---

### 第 9 步：触发流水线生成 Release

#### 9.1 触发方式（三选一）

**方式 A：GitHub Actions 页面（推荐）**

进入 https://github.com/lpx0312/kubekey/actions/workflows/sync-patch.yml → `Run workflow` → ref 选 `port-fix` → version 填 `v4.0.5`（或官方新版本）→ push 勾选 → 运行。

**方式 B：命令行**
```bash
gh workflow run sync-patch.yml -R lpx0312/kubekey --ref port-fix -f version=v4.0.5 -f push=true
```

**方式 C：本地脚本**（需 Go 环境）
```bash
./scripts/sync-patch.sh v4.0.5
```

#### 9.2 监控运行（约 11 分钟）

```bash
# 查看状态
gh run list -R lpx0312/kubekey --workflow=sync-patch.yml --limit 1

# 查看详情（sync job + release job）
gh run view <run-id> -R lpx0312/kubekey
```

正常会有两个 job：
- `Sync patch → v4.0.5`（约 1-2 分钟，cherry-pick + 打 tag）
- `Release v4.0.5-portfix`（约 9-10 分钟，编译 6 平台二进制 + 发 Release）

#### 9.3 验证发布 tag 正确（必做！）

**这是最容易踩坑的一步**，必须验证发布 tag 的 commit 链是干净的。

```bash
# 查发布 tag 的 commit 链（倒数5个）
gh api "repos/lpx0312/kubekey/commits?sha=v4.0.5-portfix&per_page=5" \
  --jq '.[] | .sha[:7] + " " + (.commit.message | split("\n")[0])'
```

**期望输出**（干净版）：
```
<新hash> fix(certs)...（或你的新补丁）
<hash>   fix(etcd)...
<hash>   fix(image)...
9c3c076  fix: add ipv6 support in cri-dockerd (#3125)    ← 官方 v4.0.5 基线 ✅
4d85ced  fix: error template for kube-proxy (#3123)
```

**错误输出**（带垃圾，说明 tag 错了）：
```
<hash> docs(patch)...    ← ❌ 不该有 docs/ci commit
<hash> ci(iso)...
...
51b4abc1 kubekey v4.0.5 (from tag v4.0.5 tarball)        ← ❌ 这是 tarball 基线，不是官方 v4.0.5
```

如果看到错误输出，参考下面的[坑点详解](#坑点-2cleanup-tag-会毁掉正确的-tag)排查。

#### 9.4 验证源码内容

```bash
# 验证新补丁在 release tag 里
gh api repos/lpx0312/kubekey/contents/<你改的文件>?ref=v4.0.5-portfix \
  --jq '.content' | base64 -d | grep "<你的修复标志>"
```

---

## 坑点详解

### 坑点 1：template trim 吃换行

改 `builtin/core/roles/*/templates/*.sh` 时，`{{- }}` 的 `-` 是贪婪 trim，会吃掉空白和换行。多个 `{{- if/else/end -}}` 连用可能把脚本挤成一行，bash 语法损坏。

**预防**：
- 改完在脑子里模拟渲染结果
- 如果模板里有版本判断 `{{- if semverCompare "<v1.20.0" }}`，确认这个分支是不是死代码（kubekey v4 最低支持 v1.23），死代码直接删掉，避免 trim 问题
- 尽量用 `kk` 实际跑一次确认渲染结果

### 坑点 2：cleanup-tag 会毁掉正确的 tag

`.github/workflows/sync-patch.yml` 的 release job 里，**绝对不能用** `gh release delete --cleanup-tag`。

`--cleanup-tag` 会删掉 sync job 正确放置的 tag（指向"官方基线+补丁"），然后 GoReleaser 重新创建 tag 时，因为 checkout 的 ref 已失效、fallback 到 port-fix 分支 HEAD，导致 tag 落到 `a29cd989`（port-fix 分支），而不是干净的官方基线+补丁链。

**正确的写法**（当前仓库已是这个版本）：
```yaml
gh release delete "$RELEASE_TAG" -R "$GITHUB_REPOSITORY" --yes   # 只删 release，不删 tag
```

**症状**：发布 tag 的 commit 链底层是 `51b4abc1`（tarball 基线）而非 `9c3c076`（官方 v4.0.5），且夹杂 docs/ci commit。

**修复**：去掉 `--cleanup-tag`，重新触发流水线。

### 坑点 3：patch 链不干净导致发布 tag 带垃圾

如果第 4 步没做、或做错了，`patch/base..patch/port-fix` 范围里会包含 docs/ci 等无关 commit。这些会被 cherry-pick 进发布 tag。

**症状**：发布 tag 的 commit 链里出现 `docs(...)` / `ci(...)` commit。

**根因**：第 4 步 cherry-pick 时，老补丁的 hash 取错了（取了 port-fix 分支上的而非干净链上的）。

**预防**：第 4.2 步必须验证 `git log --oneline patch/base..HEAD` 只看到补丁 commit。

### 坑点 4：github.com 网络时通时断

国内访问 `github.com`（443）经常被 reset，但 `api.github.com` 是通的。`git push`/`git fetch` 走的是 `github.com`。

**应对**：
- push 带重试循环（见第 8 步）
- 实在推不上去，用 `gh` CLI（走 api.github.com）验证远程状态：
  ```bash
  gh api repos/lpx0312/kubekey/git/refs/tags/patch/port-fix --jq '.object.sha[:7]'
  ```

### 坑点 5：旧集群不会自动修复

补丁升级的是 **kk 二进制**（影响新装集群），但已经部署的集群上，`backup_etcd.sh`、`renew_script.sh` 等是 `kk create cluster` 时一次性渲染部署的，**不会因为换了 kk 二进制就自动更新**。

**应对**：对每个旧集群，手动同步修改过的文件到每台节点。参考各补丁的"旧集群迁移"说明。

---

## 速查：一图看懂

```
开发:  port-fix 分支改代码 → commit (第2-3步)
         ↓
清链:  基于 patch/base cherry-pick 所有补丁 → 验证干净 → 更新 patch/port-fix (第4步)
         ↓
归档:  git format-patch 生成 patches/000N-*.patch (第5步)
         ↓
文档:  更新 README + PATCH-MAINTENANCE + sync-patch.sh (第6步)
         ↓
提交:  commit 文档改动 (第7步)
         ↓
推送:  git push port-fix + git push patch/port-fix --force (第8步)
         ↓
发布:  触发 sync-patch.yml → 生成 vX.Y.Z-portfix Release (第9步)
         ↓
验证:  检查发布 tag commit 链底部 == 官方基线 (必做!)
```

---

## 速查：常用命令

```bash
# 查看当前 patch 链
git log --oneline patch/base..patch/port-fix

# 验证发布 tag 是否干净
gh api "repos/lpx0312/kubekey/commits?sha=v4.0.5-portfix&per_page=5" \
  --jq '.[] | .sha[:7] + " " + (.commit.message | split("\n")[0])'

# 触发流水线
gh workflow run sync-patch.yml -R lpx0312/kubekey --ref port-fix -f version=v4.0.5 -f push=true

# 查看流水线状态
gh run list -R lpx0312/kubekey --workflow=sync-patch.yml --limit 1

# 本地编译验证（在干净补丁链上）
git checkout --detach patch/port-fix
LDFLAGS=$(bash hack/version.sh)
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -tags "builtin" -ldflags "$LDFLAGS" \
  -o _output/bin/kk cmd/kk/kubekey.go
git checkout port-fix
```

---

## 附录：当前补丁清单

> 完整、权威的清单见 [PATCH-MAINTENANCE.md](PATCH-MAINTENANCE.md) 的「已维护的 patch 列表」。本附录仅作速查。

| # | 补丁 | patch 文件 |
|---|------|-----------|
| 1 | 镜像仓库地址支持端口 | `0001-fix-image-support-registry-addresses-with-a-port.patch` |
| 2 | etcd 定时备份脚本修复 | `0002-fix-etcd-backup-script-unbound-var-and-multi-endpoint.patch` |
| 3 | k8s 证书自动续期修复 + 脚本改名 | `0003-fix-certs-k8s-certs-renew-timer-3-bugs-and-rename.patch` |
| 4 | NFS 默认存储类不生效 | `0004-fix-nfs-default-storageclass-wrong-variable.patch` |
| 5 | `kk certs renew` 命令直接失败 | `0005-fix-certs-renew-playbook-references-nonexistent-role.patch` |
| 6 | HCE 2.0 作为 worker 节点不被识别 | `0006-fix-hce-2.0-os-support.patch` |
| 7 | ISO 离线包下载地址硬编码 | `0007-fix-iso-download-host-configurable.patch` |
| 8 | openEuler 作为 worker 节点不被识别 | `0008-fix-openeuler-os-support.patch` |
| 9 | `iso_host` 指向平铺目录时 404 | `0009-fix-iso-host-flat-directory.patch` |
| 10 | Harbor 高可用 push 镜像 TLS 校验失败 + keepalived 不启动 | `0010-fix-harbor-ha-registry-tls-wrong-hostname.patch` |

新增补丁时，序号从 **11** 开始递增。

> 补丁 10 说明：修复 `.groups.image_registry` 在渲染阶段不可靠导致的两个问题——(1) harbor.yml 的 `hostname` 渲染成节点名致 TLS 失败；(2) keepalived（install 2 处 + uninstall 1 处，共 3 处）依赖该 group 致 VIP 起不来/卸载残留。统一改用 `ha_vip`/`auth.registry` 判断。已在真实 2 节点 HA 集群端到端验证。
