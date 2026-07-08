# 镜像打包与推送的内部机制（oras）

本文档说明 KubeKey 在「打包镜像」（`kk artifact export`）和「推送镜像」（`kk artifact images --push`）两个流程中，是如何通过 [oras](https://oras.land/) 实现镜像拉取、存储与推送的。当你需要排查镜像架构不匹配、推送中断、本地存储格式等问题时，可参考本文定位根因。

> **前置阅读**：建议先阅读 [image 模块](../framework/modules/image.md) 了解 `src`/`dest`/`manifests`/`platform` 等参数含义。

---

## 一、oras 是什么

ORAS（OCI Registry As Storage）是 CNCF 的一个项目，提供**命令行工具（CLI）和 Go 库**，用于和符合 OCI Distribution 规范的镜像仓库（Harbor、Docker Hub、docker registry、ACR 等）交互。

和 `docker pull/push` 不同的是，docker 只认容器镜像，而 oras 能通过 OCI Distribution 协议处理**任意制品**（容器镜像、Helm chart、普通文件、SBOM、二进制等）。

在 KubeKey 里，oras 有两种形态，作用完全不同：

| 形态 | 在 KubeKey 里的角色 |
|------|---------------------|
| **oras-go 库**（`oras.land/oras-go/v2`） | KubeKey 镜像操作的**核心依赖**。`pkg/modules/image/` 全部依赖它 |
| **oras CLI 工具**（命令行） | **KubeKey 从不调用它**。只是打包进离线 artifact，作为附带的运维便利工具 |

> **常见误解**：很多人以为 `tools/<arch>/oras_1.3.0_linux_<arch>.tar.gz` 是 kk 用来拉/推镜像的工具。**不是**。kk 拉取和推送镜像完全靠内嵌的 oras **Go 库**完成，和那个 CLI 工具无关。CLI 工具只是随包提供给用户离线后手动使用的。

---

## 二、核心设计：打包与推送是同一份代码

KubeKey 的镜像操作只有**一个核心函数** `ModuleImage`（`pkg/modules/image/image.go`）。打包和推送的区别，只在于 `src` 和 `dest` 的前缀方向：

| 流程 | src | dest | 含义 |
|------|-----|------|------|
| 打包（`artifact export`） | `oci://`（远端仓库） | `local://`（本地目录） | 从远端拉到本地 |
| 推送（`artifact images --push`） | `local://`（本地目录） | `oci://`（远端仓库） | 从本地推到远端 |
| 本地拷贝（package 阶段） | `local://` | `local://` | 本地目录间复制 |

底层都调用同一个 `oras.Copy()`，它是**双向**的：从 src 复制到 dst。oras 库负责 OCI Distribution 协议层（拆 manifest/config/layer、发 HTTP 请求），KubeKey 负责定义 src 和 dst 各自指向哪里。

---

## 三、打包流程里 oras 库具体做了什么

当你执行 `kk artifact export`，对 manifest 列表中的每个镜像（例如 `hub.kubesphere.com.cn/library/haproxy:2.9.6-alpine`），KubeKey 会执行以下步骤：

### 1. 解析镜像名
`registry.ParseReference(img)`（`image.go`）把镜像引用拆成三段：
- registry = `hub.kubesphere.com.cn`
- repository = `library/haproxy`
- reference（tag/digest）= `2.9.6-alpine`

### 2. 建立源仓库连接
`remote.NewRepository(...)`（`repository.go`）建立到源 registry 的 HTTPS 连接，带上认证信息（username/password/skip_tls_verify/plain_http 等）。

### 3. 建立目标仓库连接（关键技巧）
目标是本地目录，但 oras 库只能连"真 registry"。KubeKey 的解决办法是构造一个**假的 `remote.Repository`**，把它的 HTTP Client 的 Transport 换成自己实现的 `imageTransport`。这样 oras 以为自己在和真 registry 通信，发出的每个 HTTP 请求都被 `imageTransport` 拦截，转成对本地文件系统的读写。

### 4. 拉取并复制镜像内容

**单架构镜像**（无 platform 过滤，或 platform 含 `all`）：

```go
oras.Copy(ctx, srcRepo, srcRepo.Reference.Reference, dstRepo, dstRepo.Reference.Reference, oras.DefaultCopyOptions)
```
oras 会递归把 manifest + config + 所有 layer blob 从 src 复制到 dst。

**多架构镜像**（指定了 platform，走 `copyWithPlatformFilter`）：

1. `manifests.Resolve` —— 解析 tag 拿到 manifest 描述符（descriptor）
2. `manifests.Fetch` —— 下载 manifest list / image index 的 JSON
3. 解析 `manifests[]` 数组，按请求的 `os/arch` 过滤出匹配的平台条目
4. **对每个被选中的平台**，调用 `oras.Copy(src, digest, dst, digest)` —— 这一步真正下载该平台的 manifest + config + 所有 layer blob
5. `dst.Manifests().PushReference(...)` —— 把筛选后重新组装的 index 按 tag 写入目标

---

## 四、推送流程里 oras 库具体做了什么

当你执行 `kk artifact images --push`，方向反过来，但**代码完全相同**：

1. 解析镜像名（同上）
2. **源是本地** → `imageTransport` 把磁盘文件读出来，伪装成 HTTP 响应返回给 oras
3. **目标是真 registry** → `remote.NewRepository` 连接到 Harbor
4. `oras.Copy()` —— oras 库向 Harbor 发送标准 OCI Distribution 接口请求：
   - `POST /v2/<name>/blobs/uploads/` —— 申请 blob 上传会话
   - `PUT /v2/<name>/blobs/uploads/?digest=<digest>` —— 上传 blob 层数据
   - `PUT /v2/<name>/manifests/<reference>` —— 上传 manifest

   这些 HTTP 请求**全部由 oras 库内部发出**，KubeKey 不写一行 HTTP 代码。

> 推送前，KubeKey 还会用 `curl` 调 Harbor 的 `POST /api/v2.0/projects` 创建项目（`push/tasks/main.yaml`），这一步与 oras 无关。

---

## 五、本地 OCI 存储的实现（imageTransport）

KubeKey 没有使用 oras 官方的 OCI layout store（`content/oci`），而是自己实现了一个 `imageTransport`（`pkg/modules/image/repository.go`），它实现了 `http.RoundTripper` 接口。

它的工作原理：**把本地目录伪装成一个 OCI registry**。

```
oras.Copy 以为自己在和真 registry 通信
        ↓ 发出 HTTP 请求
imageTransport.RoundTrip 拦截每个请求:
  ├── HEAD /v2/.../blobs/<digest>   → os.Stat() 检查 blob 文件是否存在
  ├── GET  /v2/.../blobs/<digest>   → os.Open() 读取 blob 文件流返回
  ├── POST /v2/.../blobs/uploads/   → 返回 202 Accepted 假装接收上传
  ├── PUT  /v2/.../blobs/uploads/   → io.Copy() 把数据写入 blobs/<digest> 文件
  └── PUT  /v2/.../manifests/<ref>  → 写入 manifest 文件 + 更新 layout 索引
```

### 磁盘布局

对一个镜像 `<host>/<repo>:<tag>`，写入本地目录后的结构：

```
images/
├── blobs/                          ← 所有 layer + config blob（平铺，按 digest 命名）
│   ├── sha256:<layer-digest-1>
│   ├── sha256:<layer-digest-2>
│   └── sha256:<config-digest>
└── <host>/<repo>/                  ← 例如 hub.kubesphere.com.cn/library/haproxy/
    ├── layout                      ← tag→digest 映射 JSON（KubeKey 自创格式）
    ├── sha256:<manifest-digest>    ← manifest 内容，按 digest 命名
    └── sha256:<sub-manifest>       ← 多架构时的各平台子 manifest
```

> **注意**：这不是标准 OCI image-layout 格式（标准格式有 `oci-layout` 文件、`index.json`、`blobs/sha256/<algo>/<hash>` 两层目录）。KubeKey 用的是简化版：根目录下一个平铺的 `blobs/`，加上按 `<host>/<repo>/<digest>` 路径组织的 manifest 文件，外加一个自定义 `layout` 文件做 tag 索引。

---

## 六、关于离线包里的 oras CLI 工具

`tools/<arch>/oras_1.3.0_linux_<arch>.tar.gz` 解压后是一个 `oras` 可执行文件。它的处理流程：

1. **下载**（在线打包时）：`download/tasks/tools.yaml` 用 `http_get_file` 从 GitHub Releases 下载 tar.gz
2. **打包**：`download/package/tasks/tools.yaml` 用 `copy` 模块把 tar.gz 拷进 artifact
3. **使用**：**KubeKey 自身从不调用它**

它只是作为附带的运维工具随离线包提供。离线安装完成后，用户可手动解压使用，例如：

```sh
# 把任意文件（非镜像）推到 Harbor
oras push harbor.example.com/mystuff/myfile:v1 ./some-file.txt

# 从 Harbor 拉取
oras pull harbor.example.com/mystuff/myfile:v1

# 命令行版跨仓库复制镜像
oras copy docker.io/library/nginx:latest harbor.example.com/library/nginx:latest
```

---

## 七、常见问题排查

### Q：打包时镜像只拉了一种架构？

检查 config 的 `download.arch`。打包模板（`download/tasks/images.yaml`）的 `platform` 参数由 `download.arch` 生成。如果只写了 `arch: [arm64]`，则只拉 arm64。

### Q：推送时报 `no matching platforms found ... in [linux/amd64]`？

**最常见原因**：推送用的 config 没有写 `download.arch`，回落到默认 `["amd64"]`，但离线包里只有 arm64 的镜像。解决：在推送 config 里补上 `download.arch`，且必须和打包时一致。

```yaml
spec:
  download:
    arch:
      - arm64          # 必须和打包时一致
  image_registry:
    auth: ...
```

### Q：推送时如何把多架构镜像（arm64 + amd64）都推上去？

在推送 config 里把两种架构都列出：

```yaml
spec:
  download:
    arch:
      - amd64
      - arm64
  image_registry:
    auth: ...
```

但要注意 `policy`（默认 `strict`）：如果某个镜像在离线包里只有一种架构，strict 模式会因为 `missingPlatforms` 报错中断。这时可以把 `policy` 改成 `warn`（缺失架构的镜像跳过而非报错）：

```yaml
spec:
  download:
    arch:
      - amd64
      - arm64
    images:
      policy: warn
  image_registry:
    auth: ...
```

### Q：`imageTransport` 和标准 OCI layout 有什么区别？

KubeKey 的本地存储是自实现的简化版，不是标准 OCI image-layout。详见上文「磁盘布局」一节。这意味着你不能直接用 `skopeo copy dir:...` 或 `oras pull` 去读这个目录，但 KubeKey 自己能正确读写。

---

## 八、相关源码索引

| 文件 | 作用 |
|------|------|
| `pkg/modules/image/image.go` | `ModuleImage` 入口、`oras.Copy`、`copyWithPlatformFilter`、`registry.ParseReference` 调用 |
| `pkg/modules/image/repository.go` | `imageTransport`（本地目录伪装成 registry）、`newRemoteRepository`（远端连接 + 认证） |
| `pkg/modules/image/image_deprecated.go` | 旧 pull/push/copy 格式的兼容转换层（最终也走 `imageArgs.copy`） |
| `builtin/core/roles/download/tasks/images.yaml` | 打包：拉取镜像（`oci://` → `local://`） |
| `builtin/core/roles/download/package/tasks/images.yaml` | 打包：本地拷贝（`local://` → `local://`） |
| `builtin/core/roles/image-registry/push/tasks/main.yaml` | 推送镜像（`local://` → `oci://`） |
| `builtin/core/roles/image-registry/pull/tasks/main.yaml` | 部署时从 registry 拉取（`oci://` → `local://`） |
| `builtin/core/roles/defaults/defaults/main/10-download.yaml` | `download.arch` 默认值（`["amd64"]`）、oras CLI 下载地址定义 |
| `go.mod` | 依赖 `oras.land/oras-go/v2 v2.6.0` |
