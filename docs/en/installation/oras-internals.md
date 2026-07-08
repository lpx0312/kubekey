# Image Packaging and Push Internals (oras)

This document explains how KubeKey uses [oras](https://oras.land/) to pull, store, and push container images during **artifact export** (`kk artifact export`) and **artifact image push** (`kk artifact images --push`). Use it to diagnose architecture mismatches, push interruptions, or local storage format questions.

> **Prerequisite reading**: read the [image module](../framework/modules/image.md) docs first to understand `src`/`dest`/`manifests`/`platform` parameters.

---

## 1. What is oras

ORAS (OCI Registry As Storage) is a CNCF project providing both a **CLI tool** and **Go libraries** to interact with OCI Distribution-compliant registries (Harbor, Docker Hub, docker registry, ACR, etc.).

Unlike `docker pull/push` (which only handles container images), oras can move **any artifact** (container images, Helm charts, plain files, SBOMs, binaries) over the OCI Distribution protocol.

In KubeKey, oras appears in two forms with very different roles:

| Form | Role in KubeKey |
|------|-----------------|
| **oras-go library** (`oras.land/oras-go/v2`) | **Core dependency** for image operations. `pkg/modules/image/` relies entirely on it. |
| **oras CLI tool** (command line) | **Never invoked by KubeKey.** Only bundled into the offline artifact as an optional ops tool. |

> **Common misconception**: Many assume `tools/<arch>/oras_1.3.0_linux_<arch>.tar.gz` is what KubeKey uses to pull/push images. **It is not.** Image pull and push are handled entirely by the embedded oras **Go library**; the CLI tool is unrelated to those flows and is only provided for manual use after offline installation.

---

## 2. Core Design: Packaging and Pushing Share One Code Path

KubeKey has only **one core function** for image operations: `ModuleImage` (in `pkg/modules/image/image.go`). The difference between packaging and pushing is only the direction of `src` and `dest` prefixes:

| Flow | src | dest | Meaning |
|------|-----|------|---------|
| Package (`artifact export`) | `oci://` (remote registry) | `local://` (local dir) | Pull from remote to local |
| Push (`artifact images --push`) | `local://` (local dir) | `oci://` (remote registry) | Push from local to remote |
| Local copy (package stage) | `local://` | `local://` | Copy between local dirs |

All three call the same `oras.Copy()`, which is **bidirectional** (src → dst). The oras library handles the OCI Distribution protocol layer (splitting manifest/config/layers, sending HTTP requests); KubeKey defines where src and dst point.

---

## 3. What the oras Library Does During Packaging

When you run `kk artifact export`, for each image in the manifest list (e.g., `hub.kubesphere.com.cn/library/haproxy:2.9.6-alpine`), KubeKey performs:

### Step 1. Parse the image name
`registry.ParseReference(img)` (in `image.go`) splits the reference into:
- registry = `hub.kubesphere.com.cn`
- repository = `library/haproxy`
- reference (tag/digest) = `2.9.6-alpine`

### Step 2. Connect to the source repository
`remote.NewRepository(...)` (in `repository.go`) establishes an HTTPS connection to the source registry with auth (username/password/skip_tls_verify/plain_http).

### Step 3. Connect to the destination repository (the key trick)
The destination is a local directory, but the oras library can only talk to "real registries." KubeKey's solution: construct a **fake `remote.Repository`** whose HTTP Client Transport is replaced with a custom `imageTransport`. oras thinks it's talking to a real registry; every HTTP request it issues is intercepted by `imageTransport` and translated into local filesystem reads/writes.

### Step 4. Pull and copy image content

**Single-arch image** (no platform filter, or platform contains `all`):

```go
oras.Copy(ctx, srcRepo, srcRepo.Reference.Reference, dstRepo, dstRepo.Reference.Reference, oras.DefaultCopyOptions)
```
oras recursively copies manifest + config + all layer blobs from src to dst.

**Multi-arch image** (platform specified, goes through `copyWithPlatformFilter`):

1. `manifests.Resolve` — resolve the tag to a manifest descriptor
2. `manifests.Fetch` — download the manifest list / image index JSON
3. Parse the `manifests[]` array, filter entries matching the requested `os/arch`
4. **For each selected platform**, call `oras.Copy(src, digest, dst, digest)` — this is where the platform's manifest + config + all layer blobs are actually downloaded
5. `dst.Manifests().PushReference(...)` — write the reassembled (filtered) index to the destination with the tag

---

## 4. What the oras Library Does During Push

When you run `kk artifact images --push`, the direction is reversed but **the code is identical**:

1. Parse the image name (same as above)
2. **Source is local** → `imageTransport` reads disk files and fakes HTTP responses back to oras
3. **Destination is a real registry** → `remote.NewRepository` connects to Harbor
4. `oras.Copy()` — the oras library sends standard OCI Distribution requests to Harbor:
   - `POST /v2/<name>/blobs/uploads/` — initiate a blob upload session
   - `PUT /v2/<name>/blobs/uploads/?digest=<digest>` — upload blob layer data
   - `PUT /v2/<name>/manifests/<reference>` — upload the manifest

   These HTTP requests are **all issued internally by the oras library**; KubeKey writes no HTTP code itself.

> Before pushing, KubeKey also uses `curl` to call Harbor's `POST /api/v2.0/projects` to create the project (in `push/tasks/main.yaml`). This step is unrelated to oras.

---

## 5. Local OCI Storage Implementation (imageTransport)

KubeKey does not use oras's official OCI layout store (`content/oci`). Instead it implements its own `imageTransport` (in `pkg/modules/image/repository.go`), which implements the `http.RoundTripper` interface.

How it works: **it disguises a local directory as an OCI registry**.

```
oras.Copy thinks it's talking to a real registry
        ↓ issues HTTP requests
imageTransport.RoundTrip intercepts each request:
  ├── HEAD /v2/.../blobs/<digest>   → os.Stat() check if the blob file exists
  ├── GET  /v2/.../blobs/<digest>   → os.Open() read and stream the blob file
  ├── POST /v2/.../blobs/uploads/   → return 202 Accepted, pretending to accept upload
  ├── PUT  /v2/.../blobs/uploads/   → io.Copy() write data to blobs/<digest> file
  └── PUT /v2/.../manifests/<ref>   → write manifest file + update layout index
```

### On-disk layout

For an image `<host>/<repo>:<tag>`, the local directory structure is:

```
images/
├── blobs/                          ← all layer + config blobs (flat, named by digest)
│   ├── sha256:<layer-digest-1>
│   ├── sha256:<layer-digest-2>
│   └── sha256:<config-digest>
└── <host>/<repo>/                  ← e.g., hub.kubesphere.com.cn/library/haproxy/
    ├── layout                      ← tag→digest JSON map (KubeKey-specific format)
    ├── sha256:<manifest-digest>    ← manifest content, named by digest
    └── sha256:<sub-manifest>       ← per-platform sub-manifests for multi-arch images
```

> **Note**: This is **not** the standard OCI image-layout format (which has an `oci-layout` file, `index.json`, and a two-level `blobs/sha256/<algo>/<hash>` directory). KubeKey uses a simplified variant: a flat `blobs/` at the root, manifests organized by `<host>/<repo>/<digest>` path, plus a custom `layout` file for the tag index.

---

## 6. About the oras CLI Tool in the Artifact

`tools/<arch>/oras_1.3.0_linux_<arch>.tar.gz` extracts to an `oras` executable. Its lifecycle:

1. **Download** (during online packaging): `download/tasks/tools.yaml` fetches the tar.gz from GitHub Releases via `http_get_file`
2. **Package**: `download/package/tasks/tools.yaml` copies the tar.gz into the artifact via the `copy` module
3. **Usage**: **KubeKey itself never invokes it**

It is only bundled as an optional ops tool. After offline installation, users can extract and use it manually, for example:

```sh
# Push arbitrary (non-image) files to Harbor
oras push harbor.example.com/mystuff/myfile:v1 ./some-file.txt

# Pull from Harbor
oras pull harbor.example.com/mystuff/myfile:v1

# Cross-registry image copy (command-line version)
oras copy docker.io/library/nginx:latest harbor.example.com/library/nginx:latest
```

---

## 7. Troubleshooting Common Issues

### Q: Only one architecture was pulled during packaging?

Check `download.arch` in the config. The packaging template (`download/tasks/images.yaml`) generates the `platform` parameter from `download.arch`. If you only wrote `arch: [arm64]`, only arm64 is pulled.

### Q: Push fails with `no matching platforms found ... in [linux/amd64]`?

**Most common cause**: the push config does not specify `download.arch`, so it falls back to the default `["amd64"]`, but the offline artifact only contains arm64 images. Fix: add `download.arch` to the push config, matching the packaging config.

```yaml
spec:
  download:
    arch:
      - arm64          # must match the packaging config
  image_registry:
    auth: ...
```

### Q: How do I push a multi-arch image (arm64 + amd64) during push?

List both architectures in the push config:

```yaml
spec:
  download:
    arch:
      - amd64
      - arm64
  image_registry:
    auth: ...
```

Note the `policy` (default `strict`): if some image in the artifact has only one architecture, strict mode will fail with `missingPlatforms`. In that case set `policy` to `warn` (skip images missing the requested architecture instead of failing):

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

### Q: What's the difference between imageTransport and standard OCI layout?

KubeKey's local storage is a self-implemented simplified variant, not standard OCI image-layout. See the "On-disk layout" section above. This means you cannot directly read this directory with `skopeo copy dir:...` or `oras pull`, but KubeKey itself reads and writes it correctly.

---

## 8. Source Code Index

| File | Purpose |
|------|---------|
| `pkg/modules/image/image.go` | `ModuleImage` entry point, `oras.Copy`, `copyWithPlatformFilter`, `registry.ParseReference` |
| `pkg/modules/image/repository.go` | `imageTransport` (local dir as fake registry), `newRemoteRepository` (remote connection + auth) |
| `pkg/modules/image/image_deprecated.go` | Legacy pull/push/copy format compatibility layer (also routes to `imageArgs.copy`) |
| `builtin/core/roles/download/tasks/images.yaml` | Package: pull images (`oci://` → `local://`) |
| `builtin/core/roles/download/package/tasks/images.yaml` | Package: local copy (`local://` → `local://`) |
| `builtin/core/roles/image-registry/push/tasks/main.yaml` | Push images (`local://` → `oci://`) |
| `builtin/core/roles/image-registry/pull/tasks/main.yaml` | Pull from registry during deployment (`oci://` → `local://`) |
| `builtin/core/roles/defaults/defaults/main/10-download.yaml` | `download.arch` default (`["amd64"]`), oras CLI download URL |
| `go.mod` | Dependency `oras.land/oras-go/v2 v2.6.0` |
