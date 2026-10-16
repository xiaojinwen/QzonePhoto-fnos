# 企鹅相册 · QzonePhoto — fnOS 容器镜像
# 说明：本镜像不包含任何二次分发的二进制，构建时才从官方 GitHub Releases
#       拉取对应版本的 deb 包。上游项目 https://github.com/11273/QzonePhoto
#
# 注意：此处刻意不使用 `# syntax=docker/dockerfile:1` 指令。
#   该指令会让 BuildKit 额外去拉取 docker/dockerfile 前端镜像，而 fnOS 默认的
#   镜像加速源 docker.fnnas.com 需要私有认证头（X-Meta-Sign/X-Meta-Token），
#   标准 Docker 客户端拿不到，会直接 401 导致构建在第一步就失败。
#   本 Dockerfile 未使用任何需要新前端支持的语法，用内置前端即可。
ARG BASE_IMAGE=debian:12-slim
FROM ${BASE_IMAGE}

ARG QZONE_VERSION=2.8.0
# GitHub 加速前缀，例如 https://ghfast.top/ ；留空表示直连并自动尝试公共加速
ARG GITHUB_MIRROR=""
# 内置备用加速前缀：用户自有的 GitHub 代理，在直连不通时自动兜底
ARG BUILTIN_GITHUB_MIRROR="https://xsadwsd.kdns.fr/"
# Debian 软件源候选列表（空格分隔，按顺序尝试），例如
#   "http://mirrors.cloud.tencent.com/debian http://mirrors.tuna.tsinghua.edu.cn/debian"
# 全部不可用时回退 Debian 官方源
ARG APT_MIRRORS=""

# 代理透传：需与 docker build --build-arg http_proxy=... 配合使用
ARG http_proxy=""
ARG https_proxy=""
ARG no_proxy=""
ARG HTTP_PROXY=""
ARG HTTPS_PROXY=""
ARG NO_PROXY=""

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=zh_CN.UTF-8 \
    LC_ALL=zh_CN.UTF-8 \
    HOME=/root \
    DISPLAY=:99 \
    SCREEN_SIZE=1600x900 \
    UI_SCALE=1.25 \
    NOVNC_PORT=8080 \
    VNC_PASSWORD=""

# 1) 运行时依赖：虚拟显示 + VNC + noVNC + 轻量窗口管理器 + Electron 运行库 + 中文字体
#    具体逻辑在 provision.sh：逐个候选源尝试，直到「apt-get update 成功 且 所需包
#    全部可定位」才采用；单一源索引不完整时自动换源，而不是整体失败。
COPY build-common.sh provision.sh install-deb.sh /usr/local/bin/
RUN set -eux; \
    chmod 0755 /usr/local/bin/build-common.sh /usr/local/bin/provision.sh /usr/local/bin/install-deb.sh; \
    bash /usr/local/bin/provision.sh

# 2) 下载并安装官方 deb，再用 ldd 校验依赖闭包
#    下载源依次尝试：自定义加速前缀 → 内置备用加速 → 直连 → 若干公共加速，任一成功即继续。
#    每个候选都会做真实性校验（ar 包魔数 + 最小体积），避免加速站返回 HTML 错误页被误判为成功。
RUN set -eux; \
    bash /usr/local/bin/install-deb.sh

# 3) 入口脚本
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# 4) noVNC 首屏：自动进入连接页，并显式关闭画面缩放（1:1 像素最清晰）
#    如需让画面填满浏览器窗口（会略糊），可在 noVNC 侧边栏 Settings 里把 Scaling 改为 Local Scaling
RUN set -eux; \
    if [ -f /usr/share/novnc/vnc.html ]; then \
        printf '%s\n' \
            '<!DOCTYPE html>' \
            '<html lang="zh-CN"><head><meta charset="utf-8">' \
            '<title>企鹅相册 · 远程桌面</title>' \
            '<meta http-equiv="refresh" content="0; url=vnc.html?autoconnect=true&reconnect=true&resize=off">' \
            '</head><body style="font-family:sans-serif">' \
            '<p>正在打开远程桌面……如未自动跳转，请 <a href="vnc.html?autoconnect=true&reconnect=true&resize=off">点此进入</a>。</p>' \
            '</body></html>' \
            > /usr/share/novnc/index.html; \
    fi

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -sf -o /dev/null "http://127.0.0.1:${NOVNC_PORT}/vnc.html" || exit 1

CMD ["/usr/local/bin/entrypoint.sh"]
