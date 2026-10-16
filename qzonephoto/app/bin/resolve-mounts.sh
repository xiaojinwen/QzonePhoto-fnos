#!/bin/bash
# 解析容器「额外挂载目录」（宿主机侧执行）
#
# 背景：飞牛的应用只装在一个存储卷上，用户往往需要让容器访问其它盘。
# 本脚本负责把「自动探测的存储卷」+「用户手填的目录」合并为一份安全的挂载清单，
# 容器内挂载点与宿主机路径保持一致（/vol1 → /vol1），用户在客户端里直接填
# 宿主机上看到的路径即可，无需换算。
#
# 用法（环境变量）：
#   MOUNT_MODE=auto|manual|keep    auto=自动探测+手填；manual=仅用手填；keep=原样返回
#   EXTRA_MOUNTS_RAW="..."         用户手填，支持空白/逗号/分号/换行分隔
#   EXCLUDE_DIRS="..."             需要排除的宿主路径（已单独挂载的目录）
#   EXTRA_MOUNTS_KEEP="..."        MOUNT_MODE=keep 时原样返回的值
# 输出：空格分隔的宿主绝对路径（可直接写入 app.conf）
set -u

MOUNT_MODE="${MOUNT_MODE:-auto}"
RAW="${EXTRA_MOUNTS_RAW:-}"
EXCLUDE="${EXCLUDE_DIRS:-}"
KEEP="${EXTRA_MOUNTS_KEEP:-}"

OUT=""

# 系统路径黑名单（精确匹配或其子路径）。挂载这些会让容器获得改写宿主机系统的能力。
# 注意：只拦真正的系统目录；/mnt/xxx、/media/xxx、/volN、/home/xxx 这类用户数据区放行。
SYS_DENY="/bin /boot /dev /etc /lib /lib32 /lib64 /libx32 /proc /root /run /sbin /sys /usr /var /lost+found"

is_denied() {
    p="${1%/}"
    [ -n "$p" ] || p="/"
    [ "$p" = "/" ] && return 0
    for b in $SYS_DENY; do
        [ "$p" = "$b" ] && return 0
        case "$p" in "$b"/*) return 0 ;; esac
    done
    return 1
}

# 任意分隔符 → 每行一个路径
normalize() {
    printf '%s' "${1:-}" |
        tr ',;' '\n\n' |
        tr ' \t' '\n\n' |
        sed 's/#.*//' |
        grep -v '^[[:space:]]*$' || true
}

is_mountpoint() {
    p="${1%/}"
    [ -n "$p" ] || return 1
    mountpoint -q "$p" 2>/dev/null && return 0
    awk -v t="$p" '$2 == t {f = 1} END {exit !f}' /proc/mounts 2>/dev/null
}

add() {
    p="${1%/}"
    [ -n "$p" ] || return 0
    # 必须绝对路径；禁止 .. 与含空白的路径（后者会破坏 shell 分词与 YAML 生成）
    case "$p" in
    /*) ;;
    *) return 0 ;;
    esac
    case "$p" in
    *..*) return 0 ;;
    *" "* | *"	"*) return 0 ;;
    esac
    is_denied "$p" && return 0
    [ -d "$p" ] || return 0
    # 已单独挂载的目录不再重复映射
    for e in ${EXCLUDE}; do
        [ "${e%/}" = "$p" ] && return 0
    done
    for q in ${OUT}; do
        [ "$q" = "$p" ] && return 0
    done
    OUT="${OUT} ${p}"
}

# 飞牛存储卷为 /vol1 /vol2 …；外接设备常见于 /mnt/<名称> 与 /media/<名称>
auto_detect() {
    local d
    for d in /vol[0-9] /vol[0-9][0-9]; do
        [ -d "$d" ] && add "$d"
    done
    for d in /mnt/* /media/*; do
        [ -d "$d" ] || continue
        is_mountpoint "$d" && add "$d"
    done
    return 0
}

case "$MOUNT_MODE" in
keep)
    printf '%s' "$KEEP"
    exit 0
    ;;
auto) auto_detect ;;
manual) ;;
*) printf '%s' "$KEEP"; exit 0 ;;
esac

# 手填目录叠加（while 走 here-doc 而非管道，保证 OUT 的累加留在当前 shell）
while IFS= read -r p; do
    add "$p"
done <<EOFM
$(normalize "$RAW")
EOFM

printf '%s' "${OUT# }"
exit 0
