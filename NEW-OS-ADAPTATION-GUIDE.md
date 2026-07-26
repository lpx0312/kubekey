# 新增一个操作系统适配：完整 SOP

> 本指南把"给 KubeKey 适配一个新 OS"的全流程固化成标准操作步骤，照着做即可。最近一次成功实践是 **openEuler 适配（补丁 8）**，下文以 **统信 UOS** 为虚拟案例演示（你实际操作时把 UOS 换成你的目标 OS 即可）。
>
> **前置阅读**：[ADD-PATCH-TUTORIAL.md](ADD-PATCH-TUTORIAL.md)（补丁归档的踩坑详解）、[PATCH-MAINTENANCE.md](PATCH-MAINTENANCE.md)（补丁体系结构）。

---

## 0. 先判断：这个 OS 真的需要全套适配吗？

适配工作量取决于目标 OS 和 kubekey 现有支持的差异。先做 5 分钟的判定，避免做无用功：

### 判定表

| 目标 OS 特征 | 需要做的事 |
|--------------|-----------|
| `ID_LIKE="rhel fedora"`（标准 RHEL 系：CentOS/Rocky/AlmaLinux/RHEL 本身） | **通常什么都不用做**——precheck 白名单已含 `centos`，分类逻辑命中 `rhel fedora` 分支，ISO 名自动拼对 |
| `ID_LIKE="debian"`（标准 Debian 系：Debian/Ubuntu 本身） | 同上，已支持 |
| RHEL/Debian 系**但 `ID` 不在白名单**（如 kylin、rocky） | 只需改 [第 3 步](#3-修改-kubekey-源码并验证) 的白名单 + 分类（HCE 模式，2 处改动） |
| RHEL/Debian 系**但没有 `ID_LIKE` 字段**（如 HCE、openEuler） | 白名单 + 分类 + **可能需要 ISO 名特判**（见下） |
| **一个主版本对应多个 SP/子版本**（如 openEuler 22.03 SP1–SP4） | 白名单 + 分类 + **ISO 名 SP 提取特判**（openEuler 模式，3 处改动） |
| 非 RHEL/Debian 系（完全独立的包管理器，如 Alpine apk） | **不建议用这套方案**——`install_package.yaml` 的 yum/apt 双分支覆盖不了，需要改的远不止白名单 |

### 关键侦察：在目标 OS 上跑这两条命令

```bash
cat /etc/os-release      # 看 ID / VERSION_ID / VERSION / ID_LIKE 四个字段
which yum apt dnf        # 确认包管理器（决定走 yum 分支还是 apt 分支）
```

记录下来，[第 3 步](#3-修改-kubekey-源码并验证)要用。**核心问题永远是三个**：
1. `ID` 字段值是什么？（决定白名单加什么）
2. 有没有 `ID_LIKE`？值是什么？（决定是否需要分类特判）
3. 一个主版本是否有多个子版本（SP）？（决定是否需要 ISO 名特判——这是工作量分水岭）

---

## 1. 准备目标 OS 的 Docker 基础镜像

ISO 由 GitHub Actions 在 Docker 容器里构建，所以需要目标 OS 的 Docker 镜像作为构建环境。

### 1.1 优先用公开镜像

大多数主流 OS 有官方/社区 Docker 镜像：

```bash
# 验证镜像存在且多架构（amd64 + arm64）
docker manifest inspect <registry>/<image>:<tag>
```

例如：
- UOS：`docker.io/uos` 或统信官方仓库（需查证）
- 麒麟：之前用 `registry.cn-hangzhou.aliyuncs.com/lpx03/kylin:v10`
- openEuler：`registry.cn-hangzhou.aliyuncs.com/lpx03/openeuler:22.03-lts-sp3`

### 1.2 没有公开镜像时：自建并推送

如果目标 OS 只有 ISO/QCOW2，没有 Docker 镜像（比如某些国产化 OS），需要自己制作：

```bash
# 方案 A：用官方 ISO 制作（fedora-shell 类工具，或 manual debootstrap）
# 方案 B：用最小化 tar 包导入
docker import uos-rootfs.tar uos:v20-1050

# 推送到自己的仓库（Actions 要能拉到）
docker tag uos:v20-1050 registry.cn-hangzhou.aliyuncs.com/<你的命名空间>/uos:v20-1050
docker push registry.cn-hangzhou.aliyuncs.com/<你的命名空间>/uos:v20-1050

# 务必验证多架构（amd64 + arm64 都要有，kubekey 默认支持双架构）
docker manifest inspect registry.cn-hangzhou.aliyuncs.com/<你的命名空间>/uos:v20-1050
```

> ⚠️ **多架构是硬要求**：kubekey 的 ISO 产物名带 `-amd64` / `-arm64` 后缀，workflow 用 `platforms: linux/amd64,linux/arm64` 构建。如果目标 OS 只有单架构镜像，需要拆成两个 matrix 条目分别构建，或放弃某架构。

### 1.3 验证软件源可访问

镜像里要能配置一个可用的软件源（yum repo / apt source），用于下载依赖包：

```bash
# 在目标 OS 容器里手动验证源可达
docker run --rm -it <image> bash
# 容器内：
#   RHEL系: 配置 /etc/yum.repos.d/xxx.repo, 跑 yum makecache
#   Debian系: 配置 /etc/apt/sources.list, 跑 apt update
# 确认 repomd.xml (RHEL) 或 Release (Debian) 能下载（HTTP 200）
```

源不可达 = ISO 构建必然失败。务必先验证。

---

## 2. 编写 dockerfile 并接入 GitHub Actions（生成 ISO）

ISO 的本质：把目标 OS 的依赖包（socat/conntrack/ipset/ebtables/chrony/ipvsadm 等）下载到一个目录，做成 yum/apt 仓库，打包成 iso9660 镜像。kubekey 在 worker 节点上挂载这个 ISO 作为本地仓库装依赖。

### 2.1 选一个最接近的现有 dockerfile 作模板

`hack/gen-repository-iso/` 下已有大量模板，**挑一个和目标 OS 同源的改**：

| 目标 OS 包管理器 | 推荐模板 | 产物后缀 |
|------------------|---------|---------|
| yum/dnf（RHEL 系） | `dockerfile.hce20`（最简单）或 `dockerfile.openeuler2203sp3`（带 SP 特判） | `-rpms` |
| apt（Debian 系） | `dockerfile.ubuntu2204` | `-debs` |

### 2.2 dockerfile 的固定结构（rpm 系示例）

以 `dockerfile.hce20` 为骨架，**只需要改 5 个地方**：

```dockerfile
FROM registry.cn-hangzhou.aliyuncs.com/<你的命名空间>/<image>:<tag> as <stage名>

ARG TARGETARCH
ARG DIR=<osname>-<version>-${TARGETARCH}-rpms          # ← 改1: ISO 内部目录名
ARG PKGS=".common[],.rpms[]"
ARG BUILD_TOOLS="createrepo_c genisoimage"

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# ← 改2: 软件源 baseurl（amd64/arm64 不同，按 TARGETARCH 选）
RUN if [ "$TARGETARCH" = "amd64" ]; then \
       BASEURL="https://<你的源>/x86_64/"; \
    else \
       BASEURL="https://<你的源>/aarch64/"; \
    fi \
    && echo "[base]" > /etc/yum.repos.d/local.repo \
    && echo "name=Base" >> /etc/yum.repos.d/local.repo \
    && echo "baseurl=$BASEURL" >> /etc/yum.repos.d/local.repo \
    && echo "enabled=1" >> /etc/yum.repos.d/local.repo \
    && echo "gpgcheck=0" >> /etc/yum.repos.d/local.repo \
    && rm -f /etc/yum.repos.d/*.repo.* 2>/dev/null || true \
    && yum clean all \
    && yum makecache --disablerepo="*" --enablerepo="base"

RUN yum install -y --disablerepo="*" --enablerepo="base" $BUILD_TOOLS \
    && yum clean all

WORKDIR /package
COPY packages.yaml .
COPY --from=mikefarah/yq:4.11.1 /usr/bin/yq /usr/bin/yq

# 逐包下载 + 容错（某些包在特定 OS 源里不存在，跳过不影响其余包）
RUN mkdir -p ${DIR} \
    && yq eval "${PKGS}" packages.yaml | while read pkg; do \
         if [ -n "$pkg" ]; then \
             echo "Downloading $pkg..."; \
             yum install -y --downloadonly --downloaddir=${DIR} \
                --disablerepo="*" --enablerepo="base" $pkg || echo "not found: $pkg"; \
         fi; \
    done

RUN createrepo_c ${DIR} \
    && genisoimage -r -o ${DIR}.iso ${DIR}

FROM scratch
COPY --from=<stage名> /package/*.iso /
```

**5 个改动点**：
1. `FROM` 行的镜像地址和 tag
2. `ARG DIR=` 的目录名（决定 ISO 内部结构）
3. 软件源 `BASEURL`（amd64 + arm64 两个）
4. yum repo 的 `enablerepo` 名字（和上面 `[base]` 对应）
5. `as <stage名>` 和最后 `COPY --from=` 的 stage 名（两处要一致）

### 2.3 关键约束：ISO 文件名必须和 [第 3 步](#3-修改-kubekey-源码并验证) 的 `system_string` 对得上

workflow 最后会把产物重命名为 `<matrix.name>-amd64.iso` 和 `<matrix.name>-arm64.iso`（见 [2.4](#24-接入-github-actions-matrix)）。kubekey 在节点上根据 OS 信息拼出 `system_string`，再找 `<system_string>-rpms-amd64.iso`。**两者必须完全一致**。

**命名规则**（参照现有约定）：
- 单版本：`<osname>-<version>`，如 `hce-2.0`、`centos-8`
- 多 SP：`<osname>-<version>-spN`，如 `openeuler-22.03-sp3`、`kylin-v10sp3`
- 全小写，版本号保持原样

> 💡 **ISO 名是整条流水线的"对接面"**。dockerfile 里的 `DIR`、workflow 里的 `matrix.name`、kubekey 源码里的 `system_string`，三者最终要收敛到同一个字符串。先在 [第 0 步](#0-先判断这个-os-真的需要全套适配吗) 想好这个字符串再动手。

### 2.4 接入 GitHub Actions matrix

编辑 `.github/workflows/gen-repository-iso.yaml`，在 `matrix.include` 里加一条：

```yaml
        include:
          # ... 现有条目 ...
          - name: <osname>-<version>-spN-rpms     # ← matrix.name, 决定最终 ISO 文件名
            dockerfile: dockerfile.<osname><version>   # ← 对应 dockerfile 文件名
```

**`name` 字段的命名就是 ISO 的基础名**：workflow 会产出 `<name>-amd64.iso` 和 `<name>-arm64.iso`，上传到 `iso-latest` Release。

### 2.5 本地预验证（可选但强烈推荐）

push 前先本地构建一次，避免浪费 Actions 额度：

```bash
cd hack/gen-repository-iso
docker buildx build -f dockerfile.<osname><version> \
  --platform linux/amd64 -t test-iso --load .
# 从镜像里拷出 ISO, 验证能挂载、能 yum install
docker create --name tmp test-iso
docker cp tmp:/*.iso ./test.iso
docker rm tmp
mkdir /mnt/iso && mount -o loop test.iso /mnt/iso
# 验证 repodata 存在
ls /mnt/iso/repodata/
```

### 2.6 触发构建

```bash
# 方式 A: 推一个 iso-latest tag 触发（workflow_dispatch 也可手动触发）
git tag -f iso-latest
git push origin iso-latest --force

# 方式 B: GitHub Actions 页面手动 Run workflow (GenRepositoryISO)
```

构建产物会自动上传到 `iso-latest` Release，文件名形如 `<name>-amd64.iso` / `<name>-arm64.iso`。

---

## 3. 修改 kubekey 源码并验证

这一步让 kubekey 能识别新 OS、能装依赖、能找到对应的 ISO。**改动点取决于 [第 0 步](#0-先判断这个-os-真的需要全套适配吗) 的判定结果**。

### 3.1 改动清单（按需选取）

下表是三种典型场景，按你的情况对号入座：

| 场景 | 改 `cluster_require` | 改 `install_package` | 改 `repository/main` |
|------|:----:|:----:|:----:|
| **A. 简单**（有 `ID_LIKE=rhel fedora` 或 `debian`，只是 `ID` 不在白名单） | ✅ 白名单 | ❌ | ❌ |
| **B. 中等**（无 `ID_LIKE`，RHEL/Debian 系）—— **HCE 模式** | ✅ 白名单 | ✅ 加分类特判 | ❌ |
| **C. 复杂**（无 `ID_LIKE` + 一个主版本多个 SP）—— **openEuler 模式** | ✅ 白名单 | ✅ 加分类特判 | ✅ 加 SP 提取特判 |

下面三个文件的位置（都在 `builtin/core/roles/`，都是 `//go:embed` 编译进 kk 二进制）：

```
builtin/core/roles/defaults/defaults/main/01-cluster_require.yaml        # 白名单
builtin/core/roles/native/repository/tasks/install_package.yaml          # OS 分类 + 包安装
builtin/core/roles/native/repository/tasks/main.yaml                      # system_string (ISO 名)
```

### 3.2 改动 1：白名单（所有场景都要）

`01-cluster_require.yaml` 的 `supported_os_distributions` 加两行（裸值 + 带引号值）：

```yaml
  supported_os_distributions:
    - ubuntu
    - '"ubuntu"'
    # ... 其他 ...
    - <ID字段值的小写或原样>            # ← 新增, 例: openEuler / hce / kylin
    - '"<ID字段值的小写或原样>"'        # ← 新增, 例: '"openEuler"' / '"hce"'
```

> ⚠️ **为什么要两个（带引号和不带引号）**：kubekey 的 Go 端 `convertBytesToMap` 解析 `/etc/os-release` 时**保留引号**，所以 `ID="openEuler"` 在内存里是字符串 `"openEuler"`（含引号）。precheck 的 `supported_os_distributions | has .os.release.ID` 要两个形式都匹配。**照搬现有 ubuntu/centos/kylin/hce 的双行写法就不会错**。
>
> ⚠️ **大小写敏感**：`ID` 字段是什么就写什么。openEuler 是 `ID="openEuler"`（大写 E），所以白名单写 `openEuler` 而不是 `openeuler`。

### 3.3 改动 2：OS 分类特判（场景 B/C 需要）

`install_package.yaml` 的 `current_host_type` 加一个分支。**关键是判断目标 OS 走 yum（centos）还是 apt（ubuntu）分支**：

```yaml
- name: Repository | Check current host debian or rhel
  set_fact:
    current_host_type: >-
      {{- if .os.release.ID_LIKE | eq "debian" }}
      ubuntu
      {{- else if .os.release.ID_LIKE | unquote | eq "rhel fedora" }}
      centos
      {{- else if .os.release.ID | unquote | eq "kylin" }}
      centos
      {{- else if .os.release.ID | unquote | eq "hce" }}
      centos
      {{- else if .os.release.ID | unquote | eq "openEuler" }}
      centos
      {{- else if .os.release.ID | unquote | eq "<你的ID>" }}   # ← 新增
      centos                                                     # ← RHEL系写centos, Debian系写ubuntu
      {{- end -}}
```

**怎么判断写 `centos` 还是 `ubuntu`**：看 [第 0 步](#0-先判断这个-os-真的需要全套适配吗) 记录的包管理器。`yum`/`dnf` → `centos`，`apt` → `ubuntu`。这决定了走下面的 yum 安装块还是 apt 安装块。

### 3.4 改动 3：ISO 名 SP 提取特判（仅场景 C 需要）

只有当**一个主版本对应多个子版本（SP）且 ISO 名带 `-spN`** 时才需要。参照 `repository/tasks/main.yaml` 的 openEuler/kylin 模式：

```yaml
    # 仿 kylin / openEuler 的 sp 提取, 新增你的 OS 特判
    - name: Repository | Check system version when use <你的OS>
      set_fact:
        <os>_sp: >-
          {{- if .os.release.VERSION | contains "SP1" }}
          -sp1
          {{- else if .os.release.VERSION | contains "SP2" }}
          -sp2
          {{- else if .os.release.VERSION | contains "SP3" }}
          -sp3
          {{- else if .os.release.VERSION | contains "SP4" }}
          -sp4
          {{- end -}}
      when: .os.release.ID | unquote | eq "<你的ID>"

    - name: Repository | Define the system string based on distribution
      set_fact:
        system_string: >-
          {{- if .os.release.ID | unquote | eq "kylin" }}
          kylin-{{ .os.release.VERSION_ID | replace "\"" "" | unquote | trim | lower }}{{ .sp_version | trim }}
          {{- else if .os.release.ID | unquote | eq "openEuler" }}
          openeuler-{{ .os.release.VERSION_ID | replace "\"" "" | unquote | trim }}{{ .oe_sp | trim | lower }}
          {{- else if .os.release.ID | unquote | eq "<你的ID>" }}                    # ← 新增
          <osname>-{{ .os.release.VERSION_ID | replace "\"" "" | unquote | trim }}{{ .<os>_sp | trim | lower }}
          {{- else if .os.release.ID_LIKE | unquote | eq "rhel fedora" }}
          {{ .os.release.ID | replace "\"" "" | unquote | trim | lower  }}{{ .os.release.VERSION_ID | replace "\"" "" | unquote | trim }}
          {{- else }}
          {{ .os.release.ID | replace "\"" "" | unquote | trim | lower  }}-{{ .os.release.VERSION_ID | replace "\"" "" | unquote | trim }}
          {{- end -}}
```

> ⚠️ **场景 A/B 不需要这步**：else 分支会自动产出 `<ID>-<VERSION_ID>`（如 `hce-2.0`、`rocky-9`），只要和你的 ISO 名一致就够。

#### system_string 拼接规则速查

理解这三条规则，就能预判你的 OS 会拼出什么 ISO 名：

```
分支1 (kylin/你的OS特判):  手动控制, 最灵活
分支2 (ID_LIKE=rhel fedora): <ID小写><VERSION_ID>    注意: 无横杠!  例: centos8, rocky9
分支3 (else):              <ID小写>-<VERSION_ID>     有横杠         例: hce-2.0, debian-11
```

**你的 ISO 名必须等于 `<system_string>-rpms-amd64.iso`**。先算出 system_string，再让 dockerfile 的 `matrix.name` 等于它。

### 3.5 验证 template 渲染（关键，避免踩坑）

kubekey 用 **sprig** 模板库 + 自定义 `unquote` 函数。**改完 `main.yaml` 必须验证 system_string 拼接结果**，因为 `{{- }}` 的 trim 行为反直觉。

最快验证方式——用仓库自己的 sprig FuncMap 跑一段 Go：

```bash
cd /path/to/kubekey
cat > /tmp/verify.go << 'EOF'
package main

import (
	"bytes"
	"fmt"
	"strconv"
	"text/template"
	"github.com/Masterminds/sprig/v3"
)

func unquote(input any) string {  // 复刻 KK 的 unquote
	s, ok := input.(string)
	if !ok { return "" }
	out, err := strconv.Unquote(s)
	if err != nil { return s }
	return out
}

func main() {
	f := sprig.TxtFuncMap()
	f["unquote"] = unquote
	// 贴入你改的 system_string 片段
	tmpl := `{{- if .os.release.ID | unquote | eq "<你的ID>" }}
<osname>-{{ .os.release.VERSION_ID | replace "\"" "" | unquote | trim }}{{ .<os>_sp | trim | lower }}
{{- end -}}`
	t := template.Must(template.New("").Funcs(f).Parse(tmpl))
	// 模拟目标 OS 的 os-release 数据 (bare 和 quoted 两种都测)
	for _, c := range []map[string]any{
		{"ID": "<你的ID>", "VERSION_ID": "<版本>", "VERSION": "<含SP的完整VERSION>"},
		{"ID": "\"<你的ID>\"", "VERSION_ID": "\"<版本>\"", "VERSION": "\"<含SP的完整VERSION>\""},
	} {
		data := map[string]any{"os": map[string]any{"release": c}, "<os>_sp": "<预期sp后缀>"}
		var buf bytes.Buffer
		t.Execute(&buf, data)
		fmt.Printf("got: %q\n", buf.String())
	}
}
EOF
go run /tmp/verify.go
```

**预期输出必须严格等于你的 `matrix.name`**（如 `openeuler-22.03-sp3`）。不等于就回去调 template。

### 3.6 编译并实测

```bash
# 编译带改动的 kk
make kk

# 在目标 OS 机器上实测 add-node (最权威验证)
./kk add nodes -i inventory.yaml -c config.yaml -v 5
# 重点看日志:
#   - precheck 是否通过 (白名单改动)
#   - current_host_type 是否正确 (分类改动)
#   - system_string 是否拼对 (ISO 名改动)
#   - ISO 是否成功挂载并装上 socat 等依赖
```

---

## 4. 打成补丁并归档（接入 patch 体系）

代码改动验证通过后，按补丁流程归档。**完整踩坑详解见 [ADD-PATCH-TUTORIAL.md](ADD-PATCH-TUTORIAL.md)，这里只列要点**。

### 4.1 提交修复 commit（在 port-fix 分支）

```bash
git checkout port-fix
git pull origin port-fix
git fetch origin --tags --force   # 确保 patch/* tag 最新

# 改代码 (第 3 步的 2-3 个文件), 然后提交
git add builtin/core/roles/defaults/defaults/main/01-cluster_require.yaml
git add builtin/core/roles/native/repository/tasks/install_package.yaml
git add builtin/core/roles/native/repository/tasks/main.yaml   # 仅场景C
git commit -m "fix(<os>): support <OS全名> as a worker node OS

<说明 ID 字段、ID_LIKE 情况、为什么需要这些改动、ISO 名如何对上>
"
NEW_PATCH_COMMIT=$(git rev-parse HEAD)
echo "新补丁 commit: $NEW_PATCH_COMMIT"
```

### 4.2 重建干净的补丁链（关键，不能跳过）

```bash
# 切到官方基线
git checkout --detach patch/base

# 依次 cherry-pick 所有补丁 (老到新) + 新补丁
OLDCOMMITS=$(git rev-list --reverse patch/base..patch/port-fix)
git cherry-pick $OLDCOMMITS $NEW_PATCH_COMMIT

# 验证: 链必须全是 fix(...) commit, 无 docs/ci 夹杂
git log --oneline patch/base..HEAD
```

### 4.3 更新 tag + 生成 patch 文件

```bash
# 更新 patch/port-fix 指向新链顶
git tag -f patch/port-fix -m "Private patches: <全部补丁清单>"

# 生成 patch 归档文件 (序号 = 现有最大 + 1)
git checkout port-fix
git format-patch -1 $NEW_PATCH_COMMIT --stdout > patches/000<N>-fix-<os>-os-support.patch
```

### 4.4 更新文档（4 个文件）

| 文件 | 改什么 |
|------|--------|
| `README.md` | "当前维护 N 个私有补丁" 数量 +1；新增一节描述补丁解决了什么 |
| `PATCH-MAINTENANCE.md` | 3 处：① 已维护 patch 表格加行 ② 离线 patch 列表 + `git am` 示例加行 ③ "冲突核心判断标准"加一条 + "当前 N 个补丁"数字 ④ 末尾补丁详细说明加一节 |
| `scripts/sync-patch.sh` | cherry-pick 冲突提示段加一条解决说明 |
| `patches/000N-*.patch` | 4.3 已生成 |

```bash
git add patches/000<N>-*.patch README.md PATCH-MAINTENANCE.md scripts/sync-patch.sh
git commit -m "docs(patch): add <OS> OS support patch (N) + update tooling"
```

### 4.5 推送（force push tag）

```bash
# 推分支 (带网络重试)
for i in 1 2 3 4 5 6; do timeout 60 git push origin port-fix && break; sleep 5; done

# force push tag (指向变了, 必须 --force)
for i in 1 2 3 4 5 6; do timeout 60 git push origin patch/port-fix --force && break; sleep 5; done
```

### 4.6 触发发布流水线（生成带新补丁的 kk 二进制）

```bash
# 生成 vX.Y.Z-portfix Release (官方版本 + 全部补丁 + 6 平台二进制)
gh workflow run sync-patch.yml -R <你的fork>/kubekey --ref port-fix \
  -f version=v4.0.5 -f push=true
```

约 11 分钟后产出 `v4.0.5-portfix` Release。

---

## 5. 完整 Checklist

每次适配新 OS，过一遍这个清单：

### 准备阶段
- [ ] 在目标 OS 上跑 `cat /etc/os-release`，记录 `ID` / `VERSION_ID` / `VERSION` / `ID_LIKE`
- [ ] 确认包管理器（yum/apt），判定走 centos 还是 ubuntu 分支
- [ ] 判定场景 A/B/C（[第 0 步](#0-先判断这个-os-真的需要全套适配吗)表格）
- [ ] 想好 ISO 基础名（`<osname>-<version>[-spN]`），它是对接面

### ISO 构建（第 1-2 步）
- [ ] 准备 Docker 基础镜像（公开或自建），验证 **amd64 + arm64 双架构**
- [ ] 验证软件源可达（容器内 `yum makecache` / `apt update` 成功）
- [ ] 复制最接近的 dockerfile 模板，改 5 个地方
- [ ] `matrix.name` = ISO 基础名（和 system_string 对得上）
- [ ] 本地 `docker buildx build` 预验证一次
- [ ] 触发 workflow，确认 `iso-latest` Release 出现 `<name>-amd64.iso` / `<name>-arm64.iso`

### 源码改动（第 3 步）
- [ ] 改动 1：白名单加 `ID` + `'"ID"'`（所有场景）
- [ ] 改动 2：`install_package.yaml` 加分类特判（场景 B/C）
- [ ] 改动 3：`repository/main.yaml` 加 SP 提取特判（仅场景 C）
- [ ] 用 sprig FuncMap 验证 system_string 渲染 = ISO 基础名
- [ ] `make kk` 编译通过
- [ ] 目标 OS 机器实测 add-node 成功

### 补丁归档（第 4 步）
- [ ] 提交修复 commit
- [ ] 重建干净补丁链（验证全是 fix() commit）
- [ ] 更新 `patch/port-fix` tag
- [ ] 生成 `patches/000N-*.patch`
- [ ] 更新 README / PATCH-MAINTENANCE / sync-patch.sh
- [ ] 推送分支 + force push tag
- [ ] 触发 sync-patch 流水线

---

## 附录：历史适配案例对照

| OS | ID | ID_LIKE | 场景 | 改动数 | 补丁 |
|----|-----|---------|------|--------|------|
| kylin（麒麟） | kylin | (空) | C（多 SP） | 3 处 | 已在官方 |
| HCE 2.0 | hce | (空) | B | 2 处 | 0006 |
| openEuler 20.03/22.03/24.03 | openEuler | (空) | C（多 SP） | 3 处 | 0008 |
| rocky | rocky | rhel fedora | A（仅白名单）| 0 处（官方已支持） | — |

**新增适配时，找最接近的案例照搬**：
- 你的 OS 无 `ID_LIKE` + 多 SP → 完全照搬 **openEuler（补丁 8）**
- 你的 OS 无 `ID_LIKE` + 单版本 → 照搬 **HCE（补丁 6）**，省掉改动 3
- 你的 OS 有 `ID_LIKE=rhel fedora` → 只改白名单（场景 A）

最近的完整实践 commit 可查：
```bash
git show 51f3426b   # openEuler 修复 commit (场景 C, 3 处改动)
git show af7b72cb   # HCE 修复 commit (场景 B, 2 处改动)
```
