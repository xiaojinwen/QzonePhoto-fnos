#!/bin/bash
# 构建期步骤 1：挑选可用软件源，安装虚拟显示 / VNC / Electron 运行时依赖
#
# 为什么这么写（fnOS 环境下反复踩到的坑）：
#   旧实现是「哪个源 apt-get update 先成功就定死用哪个」，一旦该源索引不完整，
#   后续 apt-get install 会以 "Unable to locate package" 整体失败，且永远不会去试别的源。
#   现在改为：逐个候选源尝试，直到「apt-get update 成功 且 所需包全部可定位」才采用。
#   同时：发行版代号从 /etc/os-release 读取而非写死；包名支持备选（Debian 13 起
#   libcups2 → libcups2t64 等 64 位 time_t 迁移改名），按索引实际存在者选取。
#
# 依赖分两类：
#   CORE_SPECS —— 主程序运行必需。缺任何一个即视为该源不可用；全部源都装不上才失败。
#   OPT_SPECS  —— 可选增强（HEIC 图像转换）。装不上只告警，绝不影响主程序安装，
#                 对应功能在容器内运行时会优雅降级（HEIC 工具提示"未找到 heif-convert"）。
set -u
. "$(dirname "$0")/build-common.sh"

SUITE="$(detect_suite)"
ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
PRETTY="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-未知发行版}")"
diag "基础镜像：${PRETTY}｜代号=${SUITE}｜架构=${ARCH}"
[ "$ARCH" = "amd64" ] || diag "注意：当前架构为 ${ARCH}，而上游仅发布 amd64 版 deb"

# 必需包。"|" 分隔备选名（不同 Debian 版本包名可能不同）
CORE_SPECS="
ca-certificates
curl
tzdata
locales
procps
netcat-openbsd
fonts-noto-cjk
fonts-noto-core
xvfb
x11vnc
novnc
websockify
openbox
x11-utils
xdotool
libgtk-3-0|libgtk-3-0t64
libnotify4
libnss3
libnspr4
libxss1
libxtst6
xdg-utils
libatspi2.0-0|libatspi2.0-0t64
libuuid1
libsecret-1-0|libsecret-1-0t64
libasound2|libasound2t64
libgbm1
libdrm2
libdrm-common
libxkbcommon0
libx11-xcb1
libxcb-dri3-0
libxcomposite1
libxdamage1
libxrandr2
libxfixes3
libpango-1.0-0|libpango-1.0-0t64
libcairo2
libatk1.0-0|libatk1.0-0t64
libatk-bridge2.0-0|libatk-bridge2.0-0t64
libcups2|libcups2t64
libdbus-1-3
libexpat1
libglib2.0-0
python3
"

# 可选包：HEIC 图像转换（heif-convert）。
#   Debian 系 heif-convert 由 libheif-examples 提供；libheif-tools 是其它发行版的名称，
#   仅作兜底（Debian 12 里并不存在，曾因写成裸 libheif-tools 导致构建失败）。
#   libheif-plugin-libde265 是新版 libheif 的 HEVC 解码插件；Debian 12 的 libheif1 已内置
#   依赖 libde265-0，故用备选名兼容两代。
OPT_SPECS="
libheif-examples|libheif-tools
libheif-plugin-libde265|libde265-0
"

# 候选源：向导首选（已由宿主机按可达性排序）+ 官方源兜底（去重）
SRC_LIST=""
for m in ${APT_MIRRORS:-}; do
    case " ${SRC_LIST} " in *" $m "*) continue ;; esac
    SRC_LIST="${SRC_LIST} ${m}"
done
case " ${SRC_LIST} " in
*" ${OFFICIAL_BASE} "*) ;;
*) SRC_LIST="${SRC_LIST} ${OFFICIAL_BASE}" ;;
esac
SRC_LIST="${SRC_LIST# }"
diag "候选软件源（按序尝试）：${SRC_LIST}"

OK=0
WINNER=""
REPORT=""
TOTAL="$(printf '%s\n' $CORE_SPECS | grep -c .)"

for S in $SRC_LIST; do
    log "=== 尝试软件源: ${S} ==="
    write_sources "$S" "$SUITE"

    if ! apt-get update >/tmp/apt-update.log 2>&1; then
        diag "源 ${S}：apt-get update 失败"
        grep -aE '^(E|W): ' /tmp/apt-update.log 2>/dev/null | tail -n 2 | sed 's/^/[诊断]    /'
        rm -rf /var/lib/apt/lists/*
        REPORT="${REPORT}
  ${S}  → update 失败"
        continue
    fi

    RESOLVED=""
    MISSING=""
    for spec in $CORE_SPECS; do
        if n="$(pick "$spec")"; then
            RESOLVED="${RESOLVED} ${n}"
        else
            MISSING="${MISSING} ${spec%%|*}"
        fi
    done

    if [ -n "$MISSING" ]; then
        diag "源 ${S}：索引可访问，但缺少必需包 →${MISSING}"
        rm -rf /var/lib/apt/lists/*
        REPORT="${REPORT}
  ${S}  → 缺少必需包:${MISSING}"
        continue
    fi

    CNT="$(printf '%s\n' $RESOLVED | grep -c .)"
    log ">>> 采用软件源: ${S}（${SUITE}，${CNT}/${TOTAL} 个必需包全部可定位）"
    if apt-get install -y --no-install-recommends $RESOLVED; then
        OK=1
        WINNER="$S"
        break
    fi
    diag "源 ${S}：apt-get install 执行失败，换下一个源重试"
    REPORT="${REPORT}
  ${S}  → install 失败"
    rm -rf /var/lib/apt/lists/*
done

if [ "$OK" != "1" ]; then
    log "E: 所有候选软件源均无法完成必需依赖安装"
    diag "逐源结果："
    printf '%s\n' "$REPORT" | sed 's/^/[诊断] /'
    die "必需依赖安装失败：请在安装向导中把「容器内 Debian 软件源」改为清华 TUNA 或 Debian 官方源后重试"
fi

# ---------- 可选：HEIC 图像转换依赖（失败绝不阻断安装） ----------
OPT_RESOLVED=""
OPT_MISSING=""
for spec in $OPT_SPECS; do
    if n="$(pick "$spec")"; then
        OPT_RESOLVED="${OPT_RESOLVED} ${n}"
    else
        OPT_MISSING="${OPT_MISSING} ${spec%%|*}"
    fi
done
if [ -n "$OPT_MISSING" ]; then
    diag "HEIC 可选依赖在当前源缺失：${OPT_MISSING}（仅影响「HEIC 转换」工具，主程序不受影响）"
fi
if [ -n "$OPT_RESOLVED" ]; then
    if apt-get install -y --no-install-recommends $OPT_RESOLVED; then
        log "HEIC 可选依赖安装完成：${OPT_RESOLVED}"
    else
        diag "HEIC 可选依赖安装失败（仅影响「HEIC 转换」工具，主程序不受影响）"
    fi
fi

# 中文 locale
sed -i 's/^# *\(zh_CN.UTF-8 UTF-8\)/\1/' /etc/locale.gen 2>/dev/null || true
locale-gen zh_CN.UTF-8 >/dev/null 2>&1 || diag "locale-gen zh_CN.UTF-8 失败（不影响运行）"

apt-get clean
rm -rf /var/lib/apt/lists/*
diag "运行时依赖安装完成，最终采用软件源：${WINNER}"
