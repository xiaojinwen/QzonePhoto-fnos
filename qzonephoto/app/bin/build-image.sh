#!/bin/bash
# 构建（或重建）企鹅相册镜像
# 用法：APP_VERSION=.. [GITHUB_MIRROR=..] [APT_MIRROR=..] build-image.sh <target 目录> <build log 路径>
#
# 关键点：
#  1. --network=host —— 构建容器复用宿主机网络栈，宿主机上监听 127.0.0.1 的代理、
#      hosts 记录和 /etc/resolv.conf 才能生效（否则"开了代理也失败"）。
#  2. --progress=plain —— 必须：默认进度模式在 RUN 失败时只回显命令、不回显命令输出，
#      apt/curl 的真实报错会被吞掉，根本无法排障。
#  3. 代理必须在 Dockerfile 里显式 ARG 声明，才会注入到 RUN 层。
#  4. 构建前先准备基础镜像、预检 apt 源与 deb 下载源，避免跑了几分钟才失败。
set -u

DEST="${1:?用法: build-image.sh <target目录> <构建日志>}"
BUILD_LOG="${2:?用法: build-image.sh <target目录> <构建日志>}"

APP_VERSION="${APP_VERSION:?未指定 APP_VERSION}"
GITHUB_MIRROR="${GITHUB_MIRROR:-}"
BUILTIN_GITHUB_MIRROR="${BUILTIN_GITHUB_MIRROR:-}"
APT_MIRROR="${APT_MIRROR:-}"
IMAGE_TAG="${IMAGE_TAG:-qzonephoto-fnos:${APP_VERSION}}"

mkdir -p "$(dirname "$BUILD_LOG")" 2>/dev/null || true

# 安装失败时飞牛会回滚并删除应用数据目录，应用内日志会随之消失。
# 因此在 /tmp 同步留一份，保证任何退出路径（含被中断、失败）都能拿到日志。
ALT_LOG="/tmp/qzonephoto-build.log"
sync_alt() { cp -f "$BUILD_LOG" "$ALT_LOG" 2>/dev/null || true; }
trap sync_alt EXIT INT TERM

{
    echo
    echo "=================== build-image.sh $(date '+%F %T') ==================="
    echo "主日志     = ${BUILD_LOG}"
    echo "临时副本   = ${ALT_LOG}（安装失败回滚后仍可查看）"
} >>"$BUILD_LOG"

# ---------- 基础镜像准备 ----------
# fnOS 预置加速源 docker.fnnas.com 需要飞牛账号私有认证头（X-Meta-Sign/X-Meta-Token），
# 标准 Docker 客户端与 BuildKit 都拿不到 → 必然 401。因此基础镜像做多级兜底：
# 本地已有 → 依次从走标准鉴权流程的可用加速源拉取。
# 放在最前面：daemon 配置有问题时能立刻失败，不必等后续步骤。
BASE_IMAGE="debian:12-slim"
BASE_IMAGE_READY=0

if docker image inspect "debian:12-slim" >/dev/null 2>&1; then
    echo "基础镜像 debian:12-slim 已存在于本地，直接使用" >>"$BUILD_LOG"
    BASE_IMAGE_READY=1
else
    for IMG in \
        "docker.1ms.run/library/debian:12-slim" \
        "docker.m.daocloud.io/library/debian:12-slim" \
        "debian:12-slim"; do
        echo "尝试拉取基础镜像：${IMG}" >>"$BUILD_LOG"
        if docker pull "$IMG" >>"$BUILD_LOG" 2>&1; then
            BASE_IMAGE="$IMG"
            BASE_IMAGE_READY=1
            echo "基础镜像就绪：${IMG}" >>"$BUILD_LOG"
            break
        fi
        echo "  该源不可用，尝试下一个" >>"$BUILD_LOG"
    done
fi

if [ "$BASE_IMAGE_READY" != "1" ]; then
    {
        echo "错误：无法获取基础镜像 debian:12-slim。"
        echo "fnOS 预置的 docker.fnnas.com 加速源需要飞牛账号认证，命令行与构建过程都无法使用。"
        echo "处理办法（任选其一）："
        echo "  1. 「飞牛 Docker → 镜像仓库 → 仓库设置」添加加速源 https://docker.1ms.run 并启用；"
        echo "  2. 在飞牛 Docker 界面手动拉取 debian:12-slim，然后重新安装。"
    } >>"$BUILD_LOG"
    exit 1
fi

REL_URL="https://github.com/11273/QzonePhoto/releases/download/v${APP_VERSION}/QzonePhoto-${APP_VERSION}-linux-amd64.deb"

have_curl=0
command -v curl >/dev/null 2>&1 && have_curl=1

# 取最终响应码：-I -L 会对每个重定向跳各输出一次，只保留最后一个；连接失败输出为空 → 000
http_code() {
    c="$(curl -sIL -o /dev/null -w '%{http_code}\n' \
        --connect-timeout 8 --max-time 30 "$1" 2>/dev/null | tail -n 1)"
    [ -n "$c" ] || c="000"
    printf '%s' "$c"
}

# ---------- Debian 软件源候选 ----------
# 向导里选的是「首选源」，其余作为兜底；预检可达的排前面，容器内按该顺序逐个 apt-get update。
APT_MIRRORS=""
add_apt() {
    [ -z "${1:-}" ] && return 0
    case " ${APT_MIRRORS} " in *" $1 "*) return 0 ;; esac
    APT_MIRRORS="${APT_MIRRORS} $1"
}
add_apt "$APT_MIRROR"
for m in \
    "http://mirrors.cloud.tencent.com/debian" \
    "http://mirrors.tuna.tsinghua.edu.cn/debian" \
    "http://mirrors.aliyun.com/debian" \
    "http://mirrors.huaweicloud.com/debian" \
    "http://mirrors.ustc.edu.cn/debian" \
    "http://mirrors.nju.edu.cn/debian" \
    "http://mirrors.163.com/debian" \
    "http://deb.debian.org/debian"; do
    add_apt "$m"
done

APT_MIRRORS="${APT_MIRRORS# }"
if [ "$have_curl" = "1" ]; then
    APT_REACHABLE=""
    APT_UNREACHABLE=""
    for m in ${APT_MIRRORS}; do
        code="$(http_code "$m/dists/bookworm/Release")"
        echo "apt  源预检 [${code}] ${m}" >>"$BUILD_LOG"
        if [ "$code" = "200" ]; then
            APT_REACHABLE="${APT_REACHABLE} $m"
        else
            APT_UNREACHABLE="${APT_UNREACHABLE} $m"
        fi
    done
    # 可达的排前面；不可达的仍保留在末尾（宿主机探测失败不代表容器内一定失败）
    APT_MIRRORS="$(printf '%s %s' "${APT_REACHABLE# }" "${APT_UNREACHABLE# }" | sed 's/^ *//; s/  */ /g; s/ *$//')"
else
    echo "宿主机无 curl，跳过 apt 源预检" >>"$BUILD_LOG"
fi
echo "软件源尝试顺序：${APT_MIRRORS:-<镜像内默认源>}" >>"$BUILD_LOG"

# ---------- deb 下载源预检 ----------
# 顺序与 Dockerfile 内候选链保持一致：自定义 → 内置备用 → 直连 → 公共加速
norm() { printf '%s' "${1:-}" | sed 's#/*$#/#; s#^/$##'; }

PREFIX_LIST=()
for p in "$GITHUB_MIRROR" "$BUILTIN_GITHUB_MIRROR" "" \
    "https://ghfast.top/" "https://gh-proxy.com/" "https://ghps.cc/"; do
    np="$(norm "$p")"
    dup=0
    for q in ${PREFIX_LIST[@]+"${PREFIX_LIST[@]}"}; do
        [ "$q" = "$np" ] && dup=1 && break
    done
    [ "$dup" = "0" ] && PREFIX_LIST+=("$np")
done

BEST_PREFIX=""
BEST_CODE=""
if [ "$have_curl" = "1" ]; then
    for p in "${PREFIX_LIST[@]}"; do
        code="$(http_code "${p}${REL_URL}")"
        echo "deb  源预检 [${code}] ${p}${REL_URL}" >>"$BUILD_LOG"
        case "$code" in
        200 | 301 | 302)
            BEST_PREFIX="$p"
            BEST_CODE="$code"
            break
            ;;
        esac
    done
else
    echo "宿主机无 curl，跳过 deb 下载源预检" >>"$BUILD_LOG"
fi

if [ -n "$BEST_PREFIX" ]; then
    echo "deb 源预检成功（HTTP ${BEST_CODE}），锁定下载来源：${BEST_PREFIX:-<直连>}" >>"$BUILD_LOG"
    GITHUB_MIRROR="$BEST_PREFIX"
else
    echo "警告：deb 源预检未找到可达来源，交由容器内候选链继续重试" >>"$BUILD_LOG"
fi

ARGS=(
    --network=host
    --build-arg "BASE_IMAGE=${BASE_IMAGE}"
    --build-arg "QZONE_VERSION=${APP_VERSION}"
    --build-arg "GITHUB_MIRROR=${GITHUB_MIRROR}"
    --build-arg "BUILTIN_GITHUB_MIRROR=${BUILTIN_GITHUB_MIRROR}"
    --build-arg "APT_MIRRORS=${APT_MIRRORS}"
)

# 透传代理环境变量（宿主机代理常监听 127.0.0.1，依赖上面的 host 网络）
for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
    val="$(printenv "$v" 2>/dev/null || true)"
    [ -n "$val" ] && ARGS+=(--build-arg "${v}=${val}")
done

{
    echo "------------------- docker build 参数 -------------------"
    echo "image      = ${IMAGE_TAG}"
    echo "base image = ${BASE_IMAGE}"
    echo "version    = ${APP_VERSION}"
    echo "apt mirrors= ${APT_MIRRORS:-<镜像内默认源>}"
    echo "gh  mirror = ${GITHUB_MIRROR:-<直连>}"
    echo "builtin gh = ${BUILTIN_GITHUB_MIRROR:-<未设置>}"
    echo "proxy      = ${http_proxy:-${HTTP_PROXY:-<未设置>}}"
    echo "--------------------------------------------------------"
} >>"$BUILD_LOG"
sync_alt

# --pull=false：基础镜像已就绪，不再回源查询，规避 fnOS 预置加速源的认证问题
# --progress=plain：输出 RUN 层的完整 stdout/stderr，否则失败时看不到真实报错
if docker build --pull=false --progress=plain "${ARGS[@]}" \
    -t "$IMAGE_TAG" -f "${DEST}/Dockerfile" "${DEST}" >>"$BUILD_LOG" 2>&1; then
    echo "构建成功 ${IMAGE_TAG}" >>"$BUILD_LOG"
    exit 0
fi

echo "构建失败 ${IMAGE_TAG}" >>"$BUILD_LOG"
exit 1
