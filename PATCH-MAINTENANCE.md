# 私有 Patch 维护手册

本仓库在官方 `kubesphere/kubekey` 基础上维护一个私有 patch（端口修复）。
官方不会合并此 PR，因此需要长期自行维护，并在官方每次发布新版本时把 patch 搬到新版本上。

## 仓库结构

```
origin     → git@github.com:lpx0312/kubekey.git     你的 fork (push 目标)
upstream   → https://github.com/kubesphere/kubekey   官方 (只读, 拉新版本)

tag: patch/port-fix → 端口修复 commit (跨分支稳定引用, cherry-pick 时用这个)
```

## 已维护的 patch 列表

| Tag | 说明 | 改动文件 |
|-----|------|---------|
| `patch/port-fix` | 支持 `host:port` 形式的 registry 地址 | `pkg/modules/image/image.go`, `pkg/modules/image/image_test.go` |

---

## 每次官方发布新版本时（标准流程）

> 假设官方刚发布了 `v4.0.6`，要把它带上你的 patch。

```bash
# 1. 拉取官方最新 tag
git fetch upstream --tags

# 2. 确认官方新 tag 已到达
git tag -l 'v4.*'

# 3. 基于官方新 tag 创建工作分支
git checkout -b v4.0.6 upstream/v4.0.6

# 4. cherry-pick 你的端口修复 (用 tag 引用, 跨分支稳定)
git cherry-pick patch/port-fix

# 5. 验证
go test ./pkg/modules/image/...
go build ./...

# 6. 推到你的 fork
git push origin v4.0.6
```

完成后，你的 fork 上就有了 `v4.0.6` 分支 = 官方 v4.0.6 + 你的端口修复。

---

## 编译 Linux 二进制（带 builtin tag）

```bash
LDFLAGS=$(bash hack/version.sh)
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -tags "builtin" -ldflags "$LDFLAGS" \
  -o _output/bin/kk-linux-amd64 cmd/kk/kubekey.go
```

> 注意：必须带 `-tags builtin`，否则 `artifact` 子命令不会被编译进去。

---

## 如果 cherry-pick 时遇到冲突

官方新版本如果也改动了 `normalizeImageName` 函数，cherry-pick 会冲突。处理方法：

```bash
# 1. cherry-pick 冲突后会暂停, 提示哪些文件冲突
git status

# 2. 手动编辑冲突文件, 确保最终代码是这一行:
#    if strings.ContainsAny(firstPart, ".:") || firstPart == "localhost" {
#    (而不是官方的 govalidator.IsHost(firstPart))
#    同时确认 import 块里已删除 "github.com/asaskevich/govalidator"

# 3. 标记冲突已解决并继续
git add pkg/modules/image/image.go pkg/modules/image/image_test.go
git cherry-pick --continue

# 4. 如果实在想放弃本次 cherry-pick
git cherry-pick --abort
```

冲突的核心判断标准：**只要 `normalizeImageName` 函数里的 host 判断是
`strings.ContainsAny(firstPart, ".:") || firstPart == "localhost"` 这一行，就对了**。

---

## 查看当前每个版本分支带了哪些 patch

```bash
# 查看某个分支相对官方对应 tag 多了哪些 commit
git log --oneline upstream/v4.0.5..v4.0.5    # 你的 v4.0.5 分支 vs 官方 v4.0.5

# 查看当前分支是否包含端口修复
git log --oneline | grep port-fix   # 或 git branch --contains patch/port-fix
```

---

## 网络问题备选方案

本环境 `github.com` 可能时通时断。如果 `git fetch upstream` 失败：

### 方案 A：重试 + 长超时
```bash
git -c http.lowSpeedLimit=0 -c http.lowSpeedTime=999 \
    fetch upstream --tags --depth=1 refs/tags/v4.0.6:refs/tags/v4.0.6
```

### 方案 B：用 gh 通过 api.github.com 下载 tag tarball（绕过 github.com）
```bash
# gh 走 api.github.com 通道, 通常比 github.com 更稳定
gh api repos/kubesphere/kubekey/tarball/v4.0.6 > /tmp/kk-v4.0.6.tar.gz

# 解压后手动应用 patch (见下方)
```

### 方案 C：手动打 patch 文件
把端口修复导出为独立 patch 文件，新版本解压后直接 apply：
```bash
# 一次性导出 patch (只需做一次, 之后复用)
git format-patch ca702f2^..ca702f2 -o /tmp/patches/
# 生成 /tmp/patches/0001-fix-image-support-registry-addresses-with-a-port.patch

# 在新版本代码上应用
cd /path/to/new-kubekey
git am /tmp/patches/0001-*.patch
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
