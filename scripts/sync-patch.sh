#!/usr/bin/env bash
#
# sync-patch.sh — 把私有 patch 打到官方新版本上, 以 tag 形式发布到 fork
#
# 工作流 (不创建任何分支):
#   官方 tag → 检出 (detached HEAD) → cherry-pick patch → 覆盖同名 tag → 推送 tag
#
# 用法:
#   ./scripts/sync-patch.sh <官方版本号>           # 打补丁 + 推送 tag
#   ./scripts/sync-patch.sh <官方版本号> --no-push  # 只打补丁, 不推送
#
# 示例:
#   ./scripts/sync-patch.sh v4.0.6
#   ./scripts/sync-patch.sh v4.0.6 --no-push
#   SYNC_PROXY=http://127.0.0.1:7897 ./scripts/sync-patch.sh v4.0.6   # 本地走代理
#
# 前提: 已配置 upstream remote (见 PATCH-MAINTENANCE.md)
#
set -euo pipefail

# ---------- 配置 ----------
UPSTREAM_REMOTE="upstream"
ORIGIN_REMOTE="origin"
PATCH_TAG="patch/port-fix"          # 你的私有 patch 的稳定引用 tag
PATCH_SUFFIX="-portfix"             # fork 上发布 tag 的后缀 (避开与官方同名 tag 冲突)
# 网络代理: 默认不使用。本地网络受限时通过环境变量开启, 例:
#   SYNC_PROXY=http://127.0.0.1:7897 ./scripts/sync-patch.sh v4.0.6
# GitHub Actions runner 在境外, 直连 GitHub 无需代理。
PROXY="${SYNC_PROXY:-}"
# --------------------------

# 颜色输出
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}▶${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}!${NC} $*"; }
die()   { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

# ---------- 参数校验 ----------
VERSION="${1:-}"
PUSH="yes"
if [[ "${2:-}" == "--no-push" ]]; then PUSH="no"; fi

[[ -n "$VERSION" ]] || die "用法: $0 <官方版本号> [--no-push]   例: $0 v4.0.6"
[[ "$VERSION" == v* ]] || warn "版本号 '$VERSION' 不以 v 开头, 通常是 vx.y.z 形式, 请确认"

# 确认在 git 仓库根目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"
[[ -d .git ]] || die "不在 git 仓库内 ($REPO_DIR)"

# 确认 upstream remote 存在
git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 || \
  die "未找到 remote '$UPSTREAM_REMOTE'。请先执行: git remote add upstream https://github.com/kubesphere/kubekey.git"

# 确认 patch tag 存在
git rev-parse "$PATCH_TAG" >/dev/null 2>&1 || \
  die "未找到 patch tag '$PATCH_TAG'。这是你的私有修复引用, 不能缺失。"

# 保存当前状态, 完成后切回 (必须在任何 checkout 之前抓取)
# 建议在 port-fix 分支上运行本脚本 (该分支 = 官方基线 + 私有 patch + 本脚本/文档)。
# 注意: 某些 git 客户端 (如 MSYS) 的 symbolic-ref/abbrev-ref 会返回 "heads/<branch>"
# 带前缀的形式, checkout 这种带前缀的名字会进入 detached HEAD, 所以要剥离前缀。
ORIG_BRANCH=""
if git symbolic-ref -q HEAD >/dev/null 2>&1; then
  ORIG_BRANCH="$(git symbolic-ref --short HEAD)"
  # 兼容 MSYS/Git-for-Windows: 剥离可能的 "heads/" 前缀
  ORIG_BRANCH="${ORIG_BRANCH#heads/}"
  ORIG_BRANCH="${ORIG_BRANCH#refs/heads/}"
fi
ORIG_REF="$(git rev-parse HEAD)"

info "本仓库: $REPO_DIR"
info "目标版本: $VERSION  (官方 tag)"
info "发布 tag: ${VERSION}${PATCH_SUFFIX}  (打补丁后的成品, 推送到 fork)"
info "私有 patch: $PATCH_TAG"
[[ "$PUSH" == "yes" ]] && info "完成后将推送到: $ORIGIN_REMOTE tag ${VERSION}${PATCH_SUFFIX}" || info "已指定 --no-push, 不推送"
echo ""

# ---------- 1. 配置代理 ----------
if [[ -n "$PROXY" ]]; then
  info "配置 git 代理 ($PROXY)"
  git config --local http.proxy "$PROXY"
  git config --local https.proxy "$PROXY"
fi

# ---------- 2. 拉取官方最新 tag ----------
info "从 $UPSTREAM_REMOTE 拉取最新 tag..."
git fetch "$UPSTREAM_REMOTE" --tags
ok "fetch 完成"

# fetch --tags 可能拉回与本地分支同名的官方 tag (如 v4.0.5),
# 造成后续 'matches more than one' / push 歧义。这里清理掉所有这类冲突 tag。
# (仅清理与本地分支同名的 tag; 官方 tag 信息仍保留在 upstream remote ref 里)
if [[ -n "$ORIG_BRANCH" ]]; then
  if git rev-parse "refs/tags/$ORIG_BRANCH" >/dev/null 2>&1; then
    warn "fetch 拉回了与当前分支同名的 tag '$ORIG_BRANCH', 删除以避免歧义"
    git tag -d "$ORIG_BRANCH"
  fi
fi

# 确认官方存在该 tag
git rev-parse "refs/remotes/$UPSTREAM_REMOTE/tags/$VERSION" >/dev/null 2>&1 \
  || git rev-parse "refs/tags/$VERSION" >/dev/null 2>&1 \
  || die "官方不存在 tag '$VERSION'。请确认版本号。
       可用 tag 列表: git tag -l 'v4.*' --sort=-v:refname | head"

# ---------- 3. 检出官方 tag (detached HEAD, 不创建分支) ----------
info "检出官方 tag $VERSION (不创建分支)..."
git checkout --detach "$VERSION" 2>&1 | grep -E "HEAD is now|Switched" | head -1
ok "已检出官方 $VERSION 代码 (detached HEAD)"

# ---------- 4. cherry-pick 私有 patch ----------
info "cherry-pick 私有 patch ($PATCH_TAG)..."
if git cherry-pick "$PATCH_TAG"; then
  ok "cherry-pick 成功, 无冲突"
else
  echo ""
  warn "cherry-pick 出现冲突! 请手动解决后继续。"
  echo ""
  echo "  冲突文件:"
  git diff --name-only --diff-filter=U | sed 's/^/    - /'
  echo ""
  echo "  解决方法:"
  echo "    1. 编辑上述文件, 确保最终代码为 (而非 govalidator.IsHost):"
  echo "       if strings.ContainsAny(firstPart, \".:\") || firstPart == \"localhost\" {"
  echo "    2. 确认 import 块已删除 \"github.com/asaskevich/govalidator\""
  echo "    3. 标记解决并继续:"
  echo "       git add -A && git cherry-pick --continue"
  echo ""
  die "请解决冲突。当前处于 detached HEAD, 不要在此建分支。
       放弃本次: git cherry-pick --abort; git checkout $ORIG_BRANCH"
fi

# ---------- 5. 编译验证 ----------
if command -v go >/dev/null 2>&1; then
  info "运行 image 模块测试..."
  if go test ./pkg/modules/image/... ; then
    ok "测试通过"
  else
    warn "测试失败! 请检查后手动决定是否继续"
  fi
else
  warn "未找到 go 命令, 跳过测试验证"
fi

# ---------- 6. 打带后缀的新 tag ----------
NEW_COMMIT="$(git rev-parse HEAD)"
RELEASE_TAG="${VERSION}${PATCH_SUFFIX}"
info "打发布 tag $RELEASE_TAG (官方原版 $VERSION 不动)..."
# 若已存在同名 tag, 删除后重建 (确保指向最新补丁结果)
if git rev-parse "refs/tags/$RELEASE_TAG" >/dev/null 2>&1; then
  git tag -d "$RELEASE_TAG" >/dev/null
fi
git tag -a "$RELEASE_TAG" "$NEW_COMMIT" -m "Release: official $VERSION + private patch ($PATCH_TAG)"
ok "本地 tag $RELEASE_TAG 已创建 → $(git rev-parse --short $RELEASE_TAG)"
echo ""
ok "成品 $RELEASE_TAG = 官方 $VERSION + 你的私有 patch"
ok "官方原版 $VERSION 保持不变 (无冲突)"
echo ""
git log --oneline -3
echo ""

# ---------- 7. 推送 tag 到 fork ----------
# 用 --force 推送, 使脚本幂等: 同一版本可重复运行, 总是覆盖为最新结果。
# (远程可能已存在同名 tag, 例如之前跑过一次, 此时普通 push 会被拒绝)
if [[ "$PUSH" == "yes" ]]; then
  info "推送 tag $RELEASE_TAG 到 $ORIGIN_REMOTE (允许覆盖已存在的同名 tag)..."
  if git push "$ORIGIN_REMOTE" "refs/tags/$RELEASE_TAG" --force; then
    ok "推送成功: $ORIGIN_REMOTE 上的 $RELEASE_TAG = 官方 $VERSION + patch"
  else
    die "推送失败 (可能是网络问题)。可稍后手动重试:
         git push $ORIGIN_REMOTE refs/tags/$RELEASE_TAG --force"
  fi
else
  info "已指定 --no-push, 跳过推送。需要时手动执行:"
  echo "    git push $ORIGIN_REMOTE refs/tags/$RELEASE_TAG --force"
fi

# ---------- 8. 切回原状态 ----------
if [[ -n "$ORIG_BRANCH" ]]; then
  git checkout "$ORIG_BRANCH" 2>/dev/null || true
  echo ""
  ok "全部完成, 已切回原分支 $ORIG_BRANCH"
else
  echo ""
  warn "脚本启动时处于 detached HEAD, 已切回原 commit $(git rev-parse --short ORIG_REF)"
  git checkout "$ORIG_REF" 2>/dev/null || true
fi
