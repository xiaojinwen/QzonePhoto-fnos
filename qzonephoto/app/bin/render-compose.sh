#!/bin/bash
# 依据 app.conf 生成 docker-compose.yml 到 stdout
# 用法：render-compose.sh <app.conf 路径>
set -u

CONF="${1:-}"
if [ -z "$CONF" ] || [ ! -f "$CONF" ]; then
    echo "用法：render-compose.sh <app.conf 路径>" >&2
    exit 1
fi

# shellcheck disable=SC1090
. "$CONF"

# YAML 双引号标量：转义反斜杠与双引号，避免路径/口令中的特殊字符破坏结构
YQ() {
    printf '"%s"' "$(printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

WEB_PORT="${WEB_PORT:-8080}"
SCREEN_SIZE="${SCREEN_SIZE:-1600x900}"
# 界面缩放：放大应用内文字与按钮（1.0 / 1.25 / 1.5 / 1.75 / 2.0）
UI_SCALE="${UI_SCALE:-1.25}"
IMAGE_TAG="${IMAGE_TAG:-qzonephoto-fnos:2.8.0}"
CONTAINER_NAME="${CONTAINER_NAME:-qzonephoto-app}"
CONFIG_DIR="${CONFIG_DIR:-}"
SHARE_DIR="${SHARE_DIR:-}"
# 额外挂载：容器内路径与宿主机一致（/vol1 → /vol1），便于直接填宿主机上看到的路径
EXTRA_MOUNTS="${EXTRA_MOUNTS:-}"

cat <<EOF
# 由 ${0##*/} 自动生成，请勿手工修改；如需变更请通过应用「配置」修改。
services:
  qzonephoto-app:
    image: $(YQ "$IMAGE_TAG")
    container_name: $(YQ "$CONTAINER_NAME")
    restart: unless-stopped
    shm_size: "1gb"
    stop_grace_period: 20s
    environment:
      TZ: "Asia/Shanghai"
      LANG: "zh_CN.UTF-8"
      LC_ALL: "zh_CN.UTF-8"
      DISPLAY: ":99"
      SCREEN_SIZE: $(YQ "$SCREEN_SIZE")
      UI_SCALE: $(YQ "$UI_SCALE")
      NOVNC_PORT: "8080"
      VNC_PASSWORD: $(YQ "${VNC_PASSWORD:-}")
    ports:
      - $(YQ "${WEB_PORT}:8080")
    volumes:
      - $(YQ "${CONFIG_DIR}:/root/.config:rw")
      - $(YQ "${SHARE_DIR}:/downloads:rw")
EOF

for m in ${EXTRA_MOUNTS}; do
    printf '      - %s\n' "$(YQ "${m}:${m}:rw")"
done

cat <<EOF
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
