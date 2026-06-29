# 私有 Patch 维护手册

本仓库在官方 `kubesphere/kubekey` 基础上维护一个私有 patch（端口修复）。
官方不会合并此 PR，因此需要长期自行维护，并在官方每次发布新版本时把 patch 搬到新版本上。

## 仓库结构

```
origin     → git@github.com:lpx0312/kubekey.git     你的 fork (push 目标)
upstream   → https://github.com/kubesphere/kubekey   官方 (只读, 拉新版本)

tag: patch/port-fix → 端口修复 commit (跨版本稳定引用)
```

## 发布 tag 命名规则

- 官方原版 tag: `v4.0.6`           ← 来自 upstream, 只读, 不动
- 你的补丁版 tag: `v4.0.6-portfix`  ← fork 上发布, = 官方 v4.0.6 + 你的 patch

加 `-portfix` 后缀是为了**避免和官方同名 tag 冲突**（`git fetch upstream --tags`
不会互相覆盖）。

## 已维护的 patch 列表

| Tag | 说明 | 改动文件 |
|-----|------|---------|
| `patch/port-fix` | 支持 `host:port` 形式的 registry 地址 | `pkg/modules/image/image.go`, `pkg/modules/image/image_test.go` |

---

## 每次官方发布新版本时（一键同步）

> 假设官方刚发布了 `v4.0.6`，要把它带上你的 patch。

```bash
./scripts/sync-patch.sh v4.0.6
```

这条命令会自动完成：
1. 配置代理 + 从 upstream 拉取最新 tag
2. 检出官方 `v4.0.6` 代码（detached HEAD，**不创建任何分支**）
3. cherry-pick 你的端口修复（`patch/port-fix`）
4. 运行 image 模块测试验证
5. 打发布 tag `v4.0.6-portfix`（官方原版 `v4.0.6` 不动）
6. 推送 `v4.0.6-portfix` 到 fork
7. 切回原分支

完成后，你的 fork 上就有了 `v4.0.6-portfix` tag = 官方 v4.0.6 + 你的端口修复。

如果只想打补丁不推送：`./scripts/sync-patch.sh v4.0.6 --no-push`

---

## 编译 Linux 二进制（带 builtin tag）

```bash
# 检出你发布的补丁版 tag
git checkout v4.0.6-portfix

LDFLAGS=$(bash hack/version.sh)
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -tags "builtin" -ldflags "$LDFLAGS" \
  -o _output/bin/kk-linux-amd64 cmd/kk/kubekey.go
```

> 注意：必须带 `-tags builtin`，否则 `artifact` 子命令不会被编译进去。

---

## 如果 cherry-pick 时遇到冲突

官方新版本如果也改动了 `normalizeImageName` 函数，cherry-pick 会冲突。
脚本会暂停并提示冲突文件，手动解决方法：

```bash
# 1. 编辑冲突文件, 确保最终代码是这一行:
#    if strings.ContainsAny(firstPart, ".:") || firstPart == "localhost" {
#    (而不是官方的 govalidator.IsHost(firstPart))
#    同时确认 import 块里已删除 "github.com/asaskevich/govalidator"

# 2. 标记冲突已解决
git add pkg/modules/image/image.go pkg/modules/image/image_test.go
git cherry-pick --continue

# 3. 然后手动打发布 tag 并推送
git tag -a v4.0.6-portfix -m "Release: official v4.0.6 + private patch"
git push origin refs/tags/v4.0.6-portfix
```

冲突的核心判断标准：**只要 `normalizeImageName` 函数里的 host 判断是
`strings.ContainsAny(firstPart, ".:") || firstPart == "localhost"` 这一行，就对了**。

---

## 查看已发布的补丁版本

```bash
# 查看所有补丁版 tag
git tag -l '*-portfix'

# 查看某个补丁版相对官方原版多了哪些 commit
git log --oneline v4.0.6..v4.0.6-portfix
```

---

## 网络问题

脚本默认使用代理 `http://127.0.0.1:7897`（在脚本顶部 `PROXY` 变量可改）。
若代理不可用，手动 fetch 失败时的备选方案：

```bash
# 方案 A: 用 gh 通过 api.github.com 下载 tag tarball
gh api repos/kubesphere/kubekey/tarball/v4.0.6 > /tmp/kk-v4.0.6.tar.gz
# 解压后手动 apply patch 文件
cd /path/to/new-kubekey
git am patches/0001-fix-image-support-registry-addresses-with-a-port.patch
```

`patches/` 目录下有独立的 patch 文件，可离线使用（见下）。

---

## 离线 patch 文件

`patches/0001-fix-image-support-registry-addresses-with-a-port.patch`
是端口修复的独立 patch 文件。万一某次网络彻底拉不动官方仓库，解压官方 tarball
后可直接应用：

```bash
cd /path/to/official-kubekey-source
git am /path/to/patches/0001-*.patch
# 若 git am 冲突, 改用 git apply --3way
```

---

## 当前 patch 的完整 diff（备查）

```
pkg/modules/image/image.go:
  - 删除 import "github.com/asaskevich/govalidator"
  - normalizeImageName 中:
      改前: if govalidator.IsHost(firstPart) {
      改后: if strings.ContainsAny(firstPart, ".:") || firstPart == "localhost" {
```
