#!/bin/bash
# 构建期步骤 2：下载官方 deb、安装，并依据二进制真实的 ELF 依赖做闭包校验
#
# 校验的意义：不再靠"猜"该装哪些运行库。安装完 deb 后用 ldd 读出实际缺失的
# lib*.so，映射回 Debian 包名补装，两轮仍缺则明确失败并列出缺什么，
# 避免出现"安装成功但客户端一启动就崩"的假成功。
set -u
. "$(dirname "$0")/build-common.sh"

QZONE_VERSION="${QZONE_VERSION:?未指定 QZONE_VERSION}"
GITHUB_MIRROR="${GITHUB_MIRROR:-}"
BUILTIN_GITHUB_MIRROR="${BUILTIN_GITHUB_MIRROR:-}"
DEB_FILE="/tmp/qzonephoto.deb"
APP_BIN="/opt/企鹅相册/qzone-photo"

# deb 真实性校验：ar 魔数 + 体积下限，避免加速站返回 HTML 错误页被当成下载成功
check_deb() {
    [ -s "$1" ] || return 1
    case "$(head -c 8 "$1" 2>/dev/null)" in
    '!<arch>') ;;
    *) return 1 ;;
    esac
    [ "$(stat -c %s "$1" 2>/dev/null)" -gt 10485760 ] || return 1
    return 0
}

REL_URL="https://github.com/11273/QzonePhoto/releases/download/v${QZONE_VERSION}/QzonePhoto-${QZONE_VERSION}-linux-amd64.deb"
CANDIDATES=""
if [ -n "$GITHUB_MIRROR" ]; then
    CANDIDATES="${GITHUB_MIRROR%/}/${REL_URL} "
fi
if [ -n "$BUILTIN_GITHUB_MIRROR" ] && [ "${BUILTIN_GITHUB_MIRROR%/}/" != "${GITHUB_MIRROR%/}/" ]; then
    CANDIDATES="${CANDIDATES}${BUILTIN_GITHUB_MIRROR%/}/${REL_URL} "
fi
CANDIDATES="${CANDIDATES}${REL_URL} https://ghfast.top/${REL_URL} https://gh-proxy.com/${REL_URL} https://ghps.cc/${REL_URL}"

OK=0
for URL in $CANDIDATES; do
    log "尝试下载: ${URL}"
    rm -f "$DEB_FILE"
    if curl -fL --retry 2 --retry-delay 3 --connect-timeout 20 --max-time 900 -o "$DEB_FILE" "$URL"; then
        if check_deb "$DEB_FILE"; then
            OK=1
            break
        fi
        diag "该地址返回的不是有效 deb（可能是加速站错误页），试下一个"
    fi
done
[ "$OK" = "1" ] || die "所有下载源均无法获取 deb（版本 ${QZONE_VERSION}）"
log "deb 下载完成：$(stat -c %s "$DEB_FILE") 字节"

# 沿用步骤 1 选定的源；不可用时回退官方源
if ! apt-get update >/tmp/apt-install.log 2>&1; then
    diag "沿用步骤 1 的软件源 apt-get update 失败，回退 Debian 官方源"
    write_sources "$OFFICIAL_BASE" "$(detect_suite)"
    apt-get update >>/tmp/apt-install.log 2>&1 || die "软件源不可用，无法安装 deb"
fi

if ! apt-get install -y --no-install-recommends "$DEB_FILE"; then
    diag "直接安装 deb 未成功，尝试修复依赖关系后重试"
    apt-get -f install -y --no-install-recommends >/dev/null 2>&1 || true
    apt-get install -y --no-install-recommends "$DEB_FILE" || diag "deb 仍未安装成功，继续做依赖闭包校验"
fi
[ -x "$APP_BIN" ] || die "未找到可执行文件 ${APP_BIN}，deb 安装异常"

# lib*.so → Debian 包名映射（含 Debian 13 起的 t64 改名备选）
SONAME_PKG="
libatk-1.0.so.0=libatk1.0-0|libatk1.0-0t64
libatk-bridge-2.0.so.0=libatk-bridge2.0-0|libatk-bridge2.0-0t64
libcups.so.2=libcups2|libcups2t64
libasound.so.2=libasound2|libasound2t64
libpango-1.0.so.0=libpango-1.0-0|libpango-1.0-0t64
libcairo.so.2=libcairo2
libgbm.so.1=libgbm1
libdrm.so.2=libdrm2
libnss3.so=libnss3
libnspr4.so=libnspr4
libXss.so.1=libxss1
libXtst.so.6=libxtst6
libatspi.so.0=libatspi2.0-0|libatspi2.0-0t64
libsecret-1.so.0=libsecret-1-0|libsecret-1-0t64
libgtk-3.so.0=libgtk-3-0|libgtk-3-0t64
libxkbcommon.so.0=libxkbcommon0
libXcomposite.so.1=libxcomposite1
libXdamage.so.1=libxdamage1
libXrandr.so.2=libxrandr2
libXfixes.so.3=libxfixes3
libxcb-dri3.so.0=libxcb-dri3-0
libX11-xcb.so.1=libx11-xcb1
libuuid.so.1=libuuid1
libdbus-1.so.3=libdbus-1-3
libexpat.so.1=libexpat1
libglib-2.0.so.0=libglib2.0-0
"

missing_libs() {
    ldd "$APP_BIN" 2>/dev/null | awk '/not found/ {print $1}' | sort -u
}

for round in 1 2; do
    ML="$(missing_libs)"
    [ -n "$ML" ] || break
    diag "第 ${round} 轮依赖检查：缺少 $(printf '%s' "$ML" | tr '\n' ' ')"
    PKGS=""
    for so in $ML; do
        spec="$(printf '%s\n' "$SONAME_PKG" | sed -n "s|^${so}=||p" | head -n 1)"
        if [ -z "$spec" ]; then
            diag "  ${so} 未在映射表中，跳过"
            continue
        fi
        if n="$(pick "$spec")"; then
            PKGS="${PKGS} ${n}"
        else
            diag "  ${so} → ${spec} 在当前软件源索引中不存在"
        fi
    done
    [ -n "$PKGS" ] || break
    log "补装运行库：${PKGS}"
    apt-get install -y --no-install-recommends $PKGS || diag "补装未成功"
done

ML="$(missing_libs)"
if [ -n "$ML" ]; then
    log "E: 依赖闭包不完整，仍缺少运行库：$(printf '%s' "$ML" | tr '\n' ' ')"
    diag "当前软件源：$(grep -m1 '^deb ' /etc/apt/sources.list 2>/dev/null)"
    die "客户端将无法启动；请在安装向导中更换「容器内 Debian 软件源」后重试"
fi
log "依赖闭包校验通过"

rm -f "$DEB_FILE"
apt-get clean
rm -rf /var/lib/apt/lists/*
test -x "$APP_BIN" || die "可执行文件不存在：${APP_BIN}"
ln -sf "$APP_BIN" /usr/local/bin/qzonephoto
diag "应用安装完成：${APP_BIN}"
