#!/usr/bin/env bash
#
# sync_images.sh — 把 config.yaml 中 image_manifests: 列出的镜像同步到目标 Harbor
#
# ⚠️ 仅内网/测试用途:默认 Harbor 账号密码写在本脚本里。生产请用环境变量传密码:
#      HARBOR_PASS='xxx' HARBOR_USER='admin' ./sync_images.sh ...
#
# 用法:
#   ./sync_images.sh <config.yaml 路径> [strict|warn] [镜像名过滤]
#
# 执行流程(你的 6 步):
#   1) 检查镜像是否存在 + 架构完整性(按 POLICY: strict/warn)
#   2) 确定要同步的目标架构(默认 arm64+amd64,或按 RESPECT_CONFIG_ARCH 读 config)
#   3) 推导目标地址(取源镜像最后两段路径: project/repo:tag)
#   4) 抽取目标项目名列表(去重)
#   5) 调用 Harbor 接口,缺失的公开项目自动创建(开关 CREATE_PROJECTS)
#   6) skopeo copy 同步(--multi-arch all,registry→registry,不落盘)
#
# 环境变量(均有默认值):
#   HARBOR                目标 Harbor 地址 (默认 harbor.sktill.top:7000)
#   HARBOR_USER           Harbor 账号 (默认 admin)
#   HARBOR_PASS           Harbor 密码 (默认 Lipanxiang1102)
#   ARCHES                默认同步架构,逗号分隔 (默认 amd64,arm64)
#   RESPECT_CONFIG_ARCH   true 时改为读取 config.yaml 的 download.arch (默认 false)
#   CREATE_PROJECTS       是否自动创建 Harbor 项目 (默认 true)
#   CONCURRENCY           同步并发数 (默认 4)
#   TIMEOUT               单镜像同步超时秒数 (默认 600)
#   SRC_TLS_VERIFY        源仓库是否校验 TLS (默认 false)
#
# 依赖: skopeo, jq, awk, grep, sed, curl, timeout
#
set -uo pipefail

# ============================== 颜色 ==============================
if [ -t 1 ]; then
    C_GREEN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_YELLOW=$'\033[1;33m'
    C_CYAN=$'\033[1;36m';   C_BOLD=$'\033[1m';  C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""; C_DIM=""; C_OFF=""
fi

# ============================== 默认配置 ==============================
HARBOR="${HARBOR:-harbor.sktill.top:7000}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Lipanxiang1102}"
ARCHES="${ARCHES:-amd64,arm64}"
RESPECT_CONFIG_ARCH="${RESPECT_CONFIG_ARCH:-false}"
CREATE_PROJECTS="${CREATE_PROJECTS:-true}"
CONCURRENCY="${CONCURRENCY:-4}"
TIMEOUT="${TIMEOUT:-600}"
SRC_TLS_VERIFY="${SRC_TLS_VERIFY:-false}"

# ============================== 用法 ==============================
usage() {
    cat >&2 <<EOF
用法: $(basename "$0") <config.yaml 路径> [strict|warn] [镜像名过滤(可选)]

拉取策略 POLICY:
  strict  严格: 所有镜像必须包含全部目标架构,否则报错退出(不同步)
  warn    警告: 缺失架构仅记录 WARNING,仍同步镜像实际存在的架构 (默认)

示例:
  $(basename "$0") /data/kubekey/test-scripts/config.yaml
  $(basename "$0") ./config.yaml strict
  $(basename "$0") ./config.yaml warn nginx

环境变量(带默认值):
  HARBOR=$HARBOR
  HARBOR_USER=$HARBOR_USER
  ARCHES=$ARCHES                 (默认同步架构;RESPECT_CONFIG_ARCH=true 时此项被覆盖)
  RESPECT_CONFIG_ARCH=$RESPECT_CONFIG_ARCH   (true=改用 config.yaml 的 download.arch)
  CREATE_PROJECTS=$CREATE_PROJECTS           (是否自动创建 Harbor 公开项目)
  CONCURRENCY=$CONCURRENCY
  TIMEOUT=$TIMEOUT
  SRC_TLS_VERIFY=$SRC_TLS_VERIFY
EOF
    exit 1
}

[ $# -lt 1 ] && usage

CONFIG="$1"
POLICY="${2:-warn}"
FILTER="${3:-}"

case "$POLICY" in
    strict|warn) ;;
    *) echo "${C_RED}错误: POLICY 必须是 strict 或 warn${C_OFF}" >&2; usage ;;
esac

# ============================== 依赖检查 ==============================
for dep in skopeo jq awk grep sed curl timeout; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "${C_RED}错误: 缺少依赖 '$dep',请先安装。${C_OFF}" >&2
        exit 2
    fi
done
[ -f "$CONFIG" ] || { echo "${C_RED}错误: 配置文件不存在: $CONFIG${C_OFF}" >&2; exit 2; }

# ============================== 解析 config.yaml ==============================
# (1) 从 image_manifests: 段提取镜像列表(与 check_arch.sh 同逻辑)
extract_images() {
    awk '
        BEGIN { in_section = 0 }
        {
            if (!in_section) {
                if ($0 ~ /^[[:space:]]*image_manifests:[[:space:]]*$/) { in_section = 1; next }
                next
            } else {
                # 遇到下一个顶层 key(行首字母且非 "-")则结束本段
                if ($0 ~ /^[[:alnum:]_]/ && $0 !~ /^[[:space:]]*-/) { exit }
            }
            print
        }
    ' "$CONFIG" \
    | sed -E 's/#.*$//' \
    | grep -E '^[[:space:]]*-[[:space:]]' \
    | sed -E 's/^[[:space:]]*-[[:space:]]*//' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | awk 'NF'
}

# (2) 读取 download.arch 列表(给 RESPECT_CONFIG_ARCH 用)
extract_download_arch() {
    awk '
        BEGIN { in_dl = 0; in_arch = 0 }
        /^[[:space:]]*download:[[:space:]]*$/ { in_dl = 1; next }
        in_dl && /^[a-zA-Z]/ { exit }                      # 离开 download 段
        in_dl && /^[[:space:]]*arch:[[:space:]]*$/ { in_arch = 1; next }
        in_arch && /^[[:space:]]*-[[:space:]]+/ { gsub(/^[[:space:]]*-[[:space:]]*/,""); gsub(/[[:space:]]/,""); print; next }
        in_arch && /^[[:space:]]+[a-zA-Z]/ { in_arch = 0 } # arch 列表结束
    ' "$CONFIG"
}

IMAGES_TMP=$(mktemp)
trap 'rm -f "$IMAGES_TMP" "$ARCH_PROBE_TMP"' EXIT
ARCH_PROBE_TMP=$(mktemp)

extract_images > "$IMAGES_TMP"
[ -n "$FILTER" ] && { grep -F "$FILTER" "$IMAGES_TMP" > "${IMAGES_TMP}.f" || true; mv "${IMAGES_TMP}.f" "$IMAGES_TMP"; }

TOTAL=$(grep -c . "$IMAGES_TMP" || true)
[ "$TOTAL" -eq 0 ] && { echo "${C_RED}错误: 未能从 $CONFIG 解析出任何镜像(filter='$FILTER')${C_OFF}" >&2; exit 3; }

# 确定目标架构集合
if [ "$RESPECT_CONFIG_ARCH" = "true" ]; then
    TARGET_ARCHES=$(extract_download_arch | paste -sd, -)
    [ -z "$TARGET_ARCHES" ] && { echo "${C_RED}错误: RESPECT_CONFIG_ARCH=true 但 config.yaml 未读到 download.arch${C_OFF}" >&2; exit 2; }
else
    TARGET_ARCHES="$ARCHES"
fi

# ============================== 架构探测(复用 check_arch 逻辑) ==============================
# 输出: img|found_archs(found 逗号分隔; ERROR 时为 "ERR")
probe_arch() {
    local img="$1" raw found is_list
    if ! raw=$(timeout 60 skopeo inspect --raw --no-tags "docker://${img}" 2>/dev/null); then
        raw=$(timeout 60 skopeo inspect --raw --no-tags "docker://${img}" 2>/dev/null || true)
    fi
    [ -z "$raw" ] && { echo "${img}|ERR"; return; }
    is_list=$(echo "$raw" | jq -r 'if (.manifests|type)=="array" then "y" else "n" end' 2>/dev/null)
    if [ "$is_list" = "y" ]; then
        found=$(echo "$raw" | jq -r '[.manifests[]|select(.platform.architecture!=null and .platform.architecture!="unknown")|.platform.architecture]|unique|join(",")' 2>/dev/null)
    else
        found=$(timeout 60 skopeo inspect --no-tags --format '{{.Architecture}}' "docker://${img}" 2>/dev/null)
        [ -z "$found" ] || [ "$found" = "null" ] && found="single-arch"
    fi
    [ -z "$found" ] || [ "$found" = "null" ] && found="ERR"
    echo "${img}|${found}"
}
export -f probe_arch
export ARCH_PROBE_TMP

# ============================== 表头 ==============================
printf "\n${C_BOLD}=============== 同步镜像 ===============${C_OFF}\n"
printf "配置文件   : %s\n" "$CONFIG"
printf "拉取策略   : %s\n" "$POLICY"
printf "目标 Harbor: %s (用户 %s)\n" "$HARBOR" "$HARBOR_USER"
printf "目标架构   : %s\n" "$TARGET_ARCHES"
if [ "$RESPECT_CONFIG_ARCH" = "true" ]; then printf "            (来自 config.yaml download.arch)\n"; fi
printf "自动建项目 : %s\n" "$CREATE_PROJECTS"
printf "镜像数量   : %d (过滤='%s')\n" "$TOTAL" "$FILTER"
printf "并发/超时  : %d / %ss\n" "$CONCURRENCY" "$TIMEOUT"
printf "${C_DIM}%s${C_OFF}\n" "----------------------------------------"

# ============================== 第 1 步: 检查镜像存在 + 架构完整性 ==============================
printf "\n${C_BOLD}[1/5] 检查镜像存在性与架构完整性 (策略: %s)${C_OFF}\n" "$POLICY"

# 并发探测所有镜像的架构,结果写到 ARCH_PROBE_TMP
> "$ARCH_PROBE_TMP"
xargs -a "$IMAGES_TMP" -P 8 -I {} bash -c 'probe_arch "$@"' _ {} >> "$ARCH_PROBE_TMP"

# 把 TARGET_ARCHES 转成数组用于逐个比对
IFS=',' read -ra TARGET_ARR <<< "$TARGET_ARCHES"

declare -a WARN_MISSING=()   # 架构缺失明细(warn 用)
MISSING_ANY=0                # 任意镜像缺架构的计数
ACCESS_ERR_LIST=()

# 逐镜像评估
while IFS='|' read -r img found; do
    if [ "$found" = "ERR" ]; then
        printf "  ${C_YELLOW}⚠ ERR${C_OFF}  %s  (访问/解析失败)\n" "$img"
        ACCESS_ERR_LIST+=("$img")
        continue
    fi
    local_missing=()
    for a in "${TARGET_ARR[@]}"; do
        if ! printf ',%s,' "$found" | grep -Eq ",${a},"; then
            local_missing+=("$a")
        fi
    done
    if [ ${#local_missing[@]} -gt 0 ]; then
        MISSING_ANY=$((MISSING_ANY+1))
        printf "  ${C_RED}❌ MISS${C_OFF} %s  缺[%s] 实有[%s]\n" "$img" "$(IFS=,; echo "${local_missing[*]}")" "$found"
        WARN_MISSING+=("$img  缺[$(IFS=,; echo "${local_missing[*]}")] 实有[$found]")
    else
        printf "  ${C_GREEN}✅ OK${C_OFF}   %s  [%s]\n" "$img" "$found"
    fi
done < "$ARCH_PROBE_TMP"

# 策略判定
if [ ${#ACCESS_ERR_LIST[@]} -gt 0 ]; then
    printf "\n${C_YELLOW}⚠ %d 个镜像访问/解析失败:${C_OFF}\n" "${#ACCESS_ERR_LIST[@]}"
    for x in "${ACCESS_ERR_LIST[@]}"; do printf "    - %s\n" "$x"; done
fi

if [ "$MISSING_ANY" -gt 0 ]; then
    if [ "$POLICY" = "strict" ]; then
        printf "\n${C_RED}❌ [strict] 有 %d 个镜像缺少所需架构,已终止,未执行同步:${C_OFF}\n" "$MISSING_ANY"
        for w in "${WARN_MISSING[@]}"; do printf "    - %s\n" "$w"; done
        exit 1
    else
        printf "\n${C_YELLOW}⚠ [warn] %d 个镜像架构不全,将仍同步其现有架构:${C_OFF}\n" "$MISSING_ANY"
        for w in "${WARN_MISSING[@]}"; do printf "    - %s\n" "$w"; done
    fi
fi

# ============================== 第 3+4 步: 推导目标地址 / 项目名列表 ==============================
printf "\n${C_BOLD}[2/5] 推导目标地址 & 抽取项目名列表${C_OFF}\n"
# 构造 SRC|DEST|PROJECT 映射
MAP_TMP=$(mktemp); trap 'rm -f "$IMAGES_TMP" "$ARCH_PROBE_TMP" "$MAP_TMP"' EXIT
PROJECTS_TMP=$(mktemp)
> "$MAP_TMP"; > "$PROJECTS_TMP"
while read -r img; do
    [ -z "$img" ] && continue
    core=$(echo "$img" | awk -F'/' '{print $(NF-1)"/"$NF}')
    proj=$(echo "$core" | awk -F'/' '{print $1}')
    echo "${img}|${core}|${proj}" >> "$MAP_TMP"
    echo "$proj" >> "$PROJECTS_TMP"
done < "$IMAGES_TMP"

PROJECTS=$(sort -u "$PROJECTS_TMP" | paste -sd' ' -)
printf "  目标地址规则: <HARBOR>/<project>/<repo>:<tag>  (取源镜像最后两段)\n"
printf "  涉及项目 (%d): %s\n" "$(echo $PROJECTS | wc -w)" "$PROJECTS"
rm -f "$PROJECTS_TMP"

# ============================== 第 5 步: 创建 Harbor 项目 ==============================
printf "\n${C_BOLD}[3/5] 检查/创建 Harbor 项目${C_OFF}\n"
PROJ_CREATED=(); PROJ_SKIPPED=(); PROJ_FAIL=()

harbor_get_project() {  # echo http_code
    curl -sk -u "${HARBOR_USER}:${HARBOR_PASS}" -o /dev/null -w "%{http_code}" \
        "https://${HARBOR}/api/v2.0/projects/$1"
}
harbor_create_project() {  # echo http_code
    curl -sk -u "${HARBOR_USER}:${HARBOR_PASS}" -w "%{http_code}" -o /dev/null \
        -H 'Content-Type: application/json' -X POST "https://${HARBOR}/api/v2.0/projects" \
        -d "{\"project_name\":\"$1\",\"metadata\":{\"public\":\"true\"}}"
}

if [ "$CREATE_PROJECTS" = "true" ]; then
    for p in $PROJECTS; do
        code=$(harbor_get_project "$p")
        case "$code" in
            200) printf "  ${C_DIM}• %-20s 已存在,跳过${C_OFF}\n" "$p"; PROJ_SKIPPED+=("$p") ;;
            404)
                cc=$(harbor_create_project "$p")
                if [ "$cc" = "201" ]; then
                    printf "  ${C_GREEN}✓ %-20s 已创建(公开)${C_OFF}\n" "$p"; PROJ_CREATED+=("$p")
                else
                    printf "  ${C_RED}✗ %-20s 创建失败 (POST %s)${C_OFF}\n" "$p" "$cc"; PROJ_FAIL+=("$p")
                fi ;;
            *) printf "  ${C_YELLOW}⚠ %-20s 查询异常 (GET %s)${C_OFF}\n" "$p" "$code"; PROJ_FAIL+=("$p") ;;
        esac
    done
else
    printf "  ${C_DIM}(CREATE_PROJECTS=false, 跳过项目创建。请确保项目已存在)${C_OFF}\n"
fi

# ============================== 第 6 步: 同步镜像 ==============================
printf "\n${C_BOLD}[4/5] 同步镜像 (skopeo, multi-arch all)${C_OFF}\n"

SRC_TLS_FLAG="--src-tls-verify=$([ "$SRC_TLS_VERIFY" = "true" ] && echo true || echo false)"

sync_one() {
    local src="$1" dest="$2"
    # --multi-arch all: 同步 manifest list 里所有架构(含 amd64+arm64)
    timeout "$TIMEOUT" skopeo copy --multi-arch all --preserve-digests --retry-times 2 \
        $SRC_TLS_FLAG \
        --dest-tls-verify=false --dest-creds "${HARBOR_USER}:${HARBOR_PASS}" \
        "docker://${src}" "docker://${dest}" >/dev/null 2>&1
}
export -f sync_one
export TIMEOUT HARBOR HARBOR_USER HARBOR_PASS SRC_TLS_FLAG

# 准备 SRC 与 DEST 两个并列文件给 while 双 fd 循环读取
# 注意: 这里存"裸"镜像引用(不带 docker:// 前缀),由 sync_one 内部统一加前缀
SRC_LIST=$(mktemp); DST_LIST=$(mktemp)
trap 'rm -f "$IMAGES_TMP" "$ARCH_PROBE_TMP" "$MAP_TMP" "$SRC_LIST" "$DST_LIST"' EXIT
awk -F'|' '{print $1}' "$MAP_TMP" > "$SRC_LIST"
while IFS='|' read -r img core proj; do
    echo "${HARBOR}/${core}" >> "$DST_LIST"
done < "$MAP_TMP"

SYNC_OK=0; SYNC_FAIL=0
SYNC_FAIL_LIST=()
SYNC_OK_LIST=()

# 并发同步,逐个读取结果(进程替换保证顺序读取不会丢失)
idx=0
while read -r src <&3; read -r dst <&4; do
    idx=$((idx+1))
    core=$(echo "$src" | awk -F'/' '{print $(NF-1)"/"$NF}')
    if sync_one "$src" "$dst"; then
        printf "  ${C_GREEN}✅ [%d/%d]${C_OFF} %s\n" "$idx" "$TOTAL" "$core"
        SYNC_OK=$((SYNC_OK+1)); SYNC_OK_LIST+=("$core")
    else
        printf "  ${C_RED}❌ [%d/%d]${C_OFF} %s\n" "$idx" "$TOTAL" "$core"
        SYNC_FAIL=$((SYNC_FAIL+1)); SYNC_FAIL_LIST+=("$core")
    fi
done 3<"$SRC_LIST" 4<"$DST_LIST"

# ============================== 第 7 步: 汇总 ==============================
printf "\n${C_BOLD}=============== 汇总 ===============${C_OFF}\n"
printf "策略: %s | 目标架构: %s | Harbor: %s\n" "$POLICY" "$TARGET_ARCHES" "$HARBOR"
printf "镜像总数: %d\n" "$TOTAL"
printf "  架构缺失(WARN): %d\n" "$MISSING_ANY"
printf "  访问/解析失败  : %d\n" "${#ACCESS_ERR_LIST[@]}"
printf "  ${C_GREEN}同步成功: %d${C_OFF}\n" "$SYNC_OK"
printf "  ${C_RED}同步失败: %d${C_OFF}\n" "$SYNC_FAIL"
printf "  项目: 新建 %d / 已存在 %d / 失败 %d\n" "${#PROJ_CREATED[@]}" "${#PROJ_SKIPPED[@]}" "${#PROJ_FAIL[@]}"

if [ "$MISSING_ANY" -gt 0 ]; then
    printf "\n${C_BOLD}--- 架构缺失明细 ---${C_OFF}\n"
    for w in "${WARN_MISSING[@]}"; do printf "  %s\n" "$w"; done
fi
if [ "${#SYNC_FAIL_LIST[@]}" -gt 0 ]; then
    printf "\n${C_BOLD}--- 同步失败镜像 ---${C_OFF}\n"
    for c in "${SYNC_FAIL_LIST[@]}"; do printf "  %s\n" "$c"; done
fi
printf "\n"

# 退出码: 同步失败>0 -> 1; 否则 0
[ "$SYNC_FAIL" -gt 0 ] && exit 1
exit 0
