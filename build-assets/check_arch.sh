#!/usr/bin/env bash
#
# check_arch.sh — 检查 config.yaml 中 image_manifests: 列出的每个镜像是否包含指定架构的 manifest
#
# 用法:
#   ./check_arch.sh <config.yaml 路径> <架构> [镜像名过滤]
#
# 说明:
#   - 仅做 manifest 探测(HEAD/GET manifest list),不会下载镜像层,不会执行 pull。
#   - 通过 skopeo inspect --raw 获取 manifest list(index),解析其中各 platform.architecture。
#   - 区分三种结果:
#       ✅ OK        : manifest list 中存在目标架构
#       ❌ MISSING   : manifest list 存在,但没有目标架构
#       ⚠  ERROR     : 访问失败/仓库不可达/manifest 解析失败
#
# 依赖: skopeo, jq, awk, grep, sed, timeout
#
set -uo pipefail

# ----------------------------- 颜色 -----------------------------
if [ -t 1 ]; then
    C_GREEN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_YELLOW=$'\033[1;33m'
    C_CYAN=$'\033[1;36m';   C_BOLD=$'\033[1m';  C_OFF=$'\033[0m'
else
    C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""; C_OFF=""
fi

# ----------------------------- 用法 -----------------------------
usage() {
    cat >&2 <<EOF
用法: $(basename "$0") <config.yaml 路径> <架构> [镜像名过滤(可选)]

示例:
  $(basename "$0") /data/kubekey/tt/tt2/k8sv1.31.14-ks4.1.3-artifact/config.yaml arm64
  $(basename "$0") ./config.yaml amd64 nginx           # 只检查名字包含 nginx 的镜像
  $(basename "$0") ./config.yaml arm64 | tee result.log

环境变量:
  TIMEOUT       单镜像探测超时秒数 (默认 60)
  CONCURRENCY   并发数 (默认 8)
EOF
    exit 1
}

[ $# -lt 2 ] && usage

CONFIG="$1"
ARCH="$2"
FILTER="${3:-}"
TIMEOUT="${TIMEOUT:-60}"
CONCURRENCY="${CONCURRENCY:-8}"

# ----------------------------- 依赖检查 -----------------------------
for dep in skopeo jq awk grep sed timeout; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "${C_RED}错误: 缺少依赖 '$dep',请先安装。${C_OFF}" >&2
        exit 2
    fi
done

if [ ! -f "$CONFIG" ]; then
    echo "${C_RED}错误: 配置文件不存在: $CONFIG${C_OFF}" >&2
    exit 2
fi

# ----------------------------- 解析 image_manifests -----------------------------
# 1) 用 awk 截取从 "image_manifests:" 这一行开始到 EOF 的内容(只取第一个匹配段,
#    到下一个顶层 key 或文件末尾)。这里 image_manifests 通常是文件最后一个块,
#    所以直接取到 EOF。
# 2) 在该段里,挑出以 "- " 开头的"非注释"行作为镜像。
#    - 先用 sed 去掉行内注释( # 及之后)
# 3) 注意: yaml 里列表项的写法是 "  - image:xxx",我们取冒号后面的内容并 trim。
#
extract_images() {
    awk -v imgkey="image_manifests:" '
        BEGIN { in_section = 0 }
        {
            # 顶层 key 检测: 行首非空白 且 以 xxx: 结尾(不带 "- ")
            if (!in_section) {
                if ($0 ~ /^[[:space:]]*image_manifests:[[:space:]]*$/) { in_section = 1; next }
                next
            } else {
                # 遇到下一个顶层 key(行首直接是字母且不是 "- ") 则结束本段
                if ($0 ~ /^[[:alnum:]_]/ && $0 !~ /^[[:space:]]*-/) { exit }
            }
            print
        }
    ' "$CONFIG" \
    | sed -E 's/#.*$//' \
    | grep -E '^[[:space:]]*-[[:space:]]' \
    | sed -E 's/^[[:space:]]*-[[:space:]]*//' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -E '.+' \
    | awk 'NF'
}

IMAGES_TMP=$(mktemp)
trap 'rm -f "$IMAGES_TMP"' EXIT

extract_images > "$IMAGES_TMP"

TOTAL=$(wc -l < "$IMAGES_TMP" | tr -d ' ')

if [ "$TOTAL" -eq 0 ]; then
    echo "${C_RED}错误: 未能从 $CONFIG 的 image_manifests: 中解析出任何镜像。${C_OFF}" >&2
    exit 3
fi

# 去重统计
TOTAL_UNIQUE=$(sort -u "$IMAGES_TMP" | wc -l | tr -d ' ')

if [ -n "$FILTER" ]; then
    grep -F "$FILTER" "$IMAGES_TMP" > "${IMAGES_TMP}.filt"
    mv "${IMAGES_TMP}.filt" "$IMAGES_TMP"
    TOTAL=$(wc -l < "$IMAGES_TMP" | tr -d ' ')
fi

# ----------------------------- 表头 -----------------------------
printf "\n${C_BOLD}配置文件${C_OFF} : %s\n" "$CONFIG"
printf "${C_BOLD}目标架构${C_OFF} : %s\n" "$ARCH"
printf "${C_BOLD}镜像数量${C_OFF} : %s (去重前 %s)\n" "$TOTAL" "${TOTAL:-0}"
printf "${C_BOLD}单镜像超时${C_OFF} : %ss\n" "$TIMEOUT"
printf "${C_BOLD}并发数${C_OFF}   : %s\n\n" "$CONCURRENCY"

printf "%-6s %-9s %-22s %s\n" "结果" "架构" "镜像" ""
printf "%-6s %-9s %-22s %s\n" "----" "--------" "----------------------" "----------------------------------------"

# ----------------------------- 单镜像探测 -----------------------------
# 输出: RESULT|FOUND_ARCHS|IMAGE
#   RESULT = OK / MISSING / ERROR
#   FOUND_ARCHS = 逗号分隔的架构列表(单架构镜像可能为 "amd64")
#
# 说明: 架构信息有两种存放方式:
#   1) manifest list / OCI index -> manifest 自身包含 manifests[].platform.architecture
#   2) 单架构镜像(无 index)     -> 架构信息在 config blob 的 .architecture 字段,
#      需要单独获取(skopeo inspect 不带 --raw 会自动拉取这个几 KB 的 config JSON,
#      不下载镜像层)。我们用 raw 判断类型,单架构时再取 .Architecture。
check_one() {
    local img="$1"
    local raw mtype found result

    # 1) 获取 raw manifest (不下载层),失败重试一次
    if ! raw=$(timeout "$TIMEOUT" skopeo inspect --raw --no-tags "docker://${img}" 2>/dev/null); then
        if ! raw=$(timeout "$TIMEOUT" skopeo inspect --raw --no-tags "docker://${img}" 2>/dev/null); then
            echo "ERROR|ACCESS_FAIL|${img}"
            return
        fi
    fi

    # 2) 判断 manifest 类型
    mtype=$(echo "$raw" | jq -r '.mediaType // ""' 2>/dev/null)

    # 是不是 manifest list / OCI index?  判定条件: 有 .manifests 数组
    local is_list
    is_list=$(echo "$raw" | jq -r 'if (.manifests | type) == "array" then "yes" else "no" end' 2>/dev/null)

    if [ "$is_list" = "yes" ]; then
        # --- 多架构 manifest list: 直接从 manifest 解析各平台架构 ---
        found=$(echo "$raw" | jq -r '
            [ .manifests[]
              | select(.platform.architecture != null and .platform.architecture != "unknown")
              | .platform.architecture
            ] | unique | join(",")
        ' 2>/dev/null)
    else
        # --- 单架构镜像: 架构在 config blob 里,用 skopeo inspect (无 --raw) 获取 ---
        # 注意: 这只会拉取几 KB 的 image config,不会下载镜像层
        found=$(timeout "$TIMEOUT" skopeo inspect --no-tags --format '{{.Architecture}}' "docker://${img}" 2>/dev/null)
        # filebeat 等老镜像可能 .Architecture 为空,兜底取 .Os
        [ -z "$found" ] || [ "$found" = "null" ] && found="<single-arch>"
    fi

    if [ -z "$found" ] || [ "$found" = "null" ]; then
        echo "ERROR|PARSE_FAIL|${img}"
        return
    fi

    # 3) 检查目标架构是否存在(逗号边界匹配,兼容 "amd64,arm64")
    if printf ',%s,' "$found" | grep -Eq ",${ARCH},"; then
        result="OK"
    else
        result="MISSING"
    fi
    echo "${result}|${found}|${img}"
}
export -f check_one
export TIMEOUT ARCH

# ----------------------------- 并发执行 -----------------------------
OK=0; MISSING=0; ERROR=0
MISSING_LIST=()
ERROR_LIST=()

while IFS='|' read -r result found img; do
    case "$result" in
        OK)
            printf "${C_GREEN}%-6s${C_OFF} %-9s %-22s %s\n" "✅ OK" "$ARCH" "${img:0:40}" "${img}"
            OK=$((OK+1))
            ;;
        MISSING)
            printf "${C_RED}%-6s${C_OFF} %-9s %-22s %s\n" "❌ MISS" "$found" "${img:0:40}" "${img}"
            MISSING=$((MISSING+1))
            MISSING_LIST+=("$img  ->  $found")
            ;;
        *)
            printf "${C_YELLOW}%-6s${C_OFF} %-9s %-22s %s\n" "⚠ ERR" "-" "${img:0:40}" "${img}"
            ERROR=$((ERROR+1))
            ERROR_LIST+=("$img")
            ;;
    esac
done < <(xargs -a "$IMAGES_TMP" -P "$CONCURRENCY" -I {} bash -c 'check_one "$@"' _ {})

# ----------------------------- 汇总 -----------------------------
printf "\n${C_BOLD}========== 汇总 ==========${C_OFF}\n"
printf "目标架构: %s\n" "$ARCH"
printf "总镜像数: %s\n" "$TOTAL"
printf "${C_GREEN}✅ 存在 (%s): %d${C_OFF}\n" "$ARCH" "$OK"
printf "${C_RED}❌ 缺失 (%s): %d${C_OFF}\n" "$ARCH" "$MISSING"
printf "${C_YELLOW}⚠  错误(访问/解析): %d${C_OFF}\n" "$ERROR"

if [ "${#MISSING_LIST[@]}" -gt 0 ]; then
    printf "\n${C_BOLD}--- 缺失 %s 架构的镜像 ---${C_OFF}\n" "$ARCH"
    for l in "${MISSING_LIST[@]}"; do printf "  %s\n" "$l"; done
fi

if [ "${#ERROR_LIST[@]}" -gt 0 ]; then
    printf "\n${C_BOLD}--- 访问/解析失败的镜像(建议人工复核) ---${C_OFF}\n"
    for l in "${ERROR_LIST[@]}"; do printf "  %s\n" "$l"; done
fi
printf "\n"

# 退出码: 有 MISSING 返回 1, 仅 ERROR 返回 4, 全 OK 返回 0
if [ "$MISSING" -gt 0 ]; then
    exit 1
elif [ "$ERROR" -gt 0 ]; then
    exit 4
fi
exit 0
