#!/bin/bash
# 容器入口：虚拟显示(Xvfb) + 窗口管理器(openbox) + x11vnc + websockify(noVNC) + Electron 主程序
# 主程序意外退出会自动拉起，保证浏览器端始终可用。
set -u

APP_BIN="/opt/企鹅相册/qzone-photo"
LOG_DIR="/var/log/qzonephoto"

SCREEN_SIZE="${SCREEN_SIZE:-1600x900}"
NOVNC_PORT="${NOVNC_PORT:-8080}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
# HEIC 转换工具：监听端口与允许扫描的根目录（多个用逗号分隔）
# 若需固定根目录而非自动探测挂载卷，设置 HEIC_TOOL_ROOTS_OVERRIDE=1 并指定 HEIC_TOOL_ROOTS
HEIC_TOOL_PORT="${HEIC_TOOL_PORT:-8090}"
HEIC_TOOL_ROOTS="${HEIC_TOOL_ROOTS:-/downloads}"
HEIC_TOOL_ROOTS_OVERRIDE="${HEIC_TOOL_ROOTS_OVERRIDE:-}"
# 界面缩放：放大应用内的文字与按钮。1.0=原始大小，1.25=放大 25%（推荐）
# 原理：给 Electron 传 --force-device-scale-factor，画面以更高的像素密度渲染，
#       应用内可用区域（CSS 像素）相应变小，按钮和字号看起来就更大，同时保持 1:1 像素不模糊。
UI_SCALE="${UI_SCALE:-1.25}"

WIDTH="${SCREEN_SIZE%x*}"
HEIGHT="${SCREEN_SIZE#*x}"

# 分辨率与缩放都要是合法值，否则回退到安全组合
case "$SCREEN_SIZE" in
[0-9]*x[0-9]*) ;;
*)
    SCREEN_SIZE="1600x900"
    WIDTH="1600"
    HEIGHT="900"
    ;;
esac

case "$UI_SCALE" in
1 | 1.0 | 1.00)
    UI_SCALE="1.0"
    SCREEN_DPI=96
    ;;
1.25)
    SCREEN_DPI=120
    ;;
1.5 | 1.50)
    UI_SCALE="1.5"
    SCREEN_DPI=144
    ;;
1.75)
    SCREEN_DPI=168
    ;;
2 | 2.0 | 2.00)
    UI_SCALE="2.0"
    SCREEN_DPI=192
    ;;
*)
    UI_SCALE="1.25"
    SCREEN_DPI=120
    ;;
esac

mkdir -p "$LOG_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [entrypoint] $*" | tee -a "$LOG_DIR/entrypoint.log"
}

if [ ! -x "$APP_BIN" ]; then
    log "错误：未找到主程序 $APP_BIN"
    exit 1
fi

terminate() {
    log "收到停止信号，正在退出"
    for pid in "${PID_APP:-}" "${PID_NOVNC:-}" "${PID_X11VNC:-}" "${PID_WM:-}" "${PID_XVFB:-}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
    done
    wait 2>/dev/null
    log "已退出"
    exit 0
}
trap terminate TERM INT QUIT

# openbox 配置：让新窗口默认最大化、去掉标题栏，避免应用只占屏幕中间一小块
write_openbox_conf() {
    mkdir -p /root/.config/openbox
    cat >/root/.config/openbox/rc.xml <<'XMLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <resistance>
    <strength>10</strength>
    <screen_edge_strength>20</screen_edge_strength>
  </resistance>
  <focus>
    <focusNew>yes</focusNew>
    <followMouse>no</followMouse>
    <raiseOnFocus>no</raiseOnFocus>
  </focus>
  <placement>
    <policy>Smart</policy>
  </placement>
  <theme>
    <name>Clearlooks</name>
  </theme>
  <desktops>
    <number>1</number>
    <firstdesk>1</firstdesk>
    <names>
      <name>desktop 1</name>
    </names>
  </desktops>
  <resize>
    <drawContents>yes</drawContents>
  </resize>
  <applications>
    <application class="*">
      <maximized>yes</maximized>
      <decor>no</decor>
    </application>
  </applications>
</openbox_config>
XMLEOF
}

start_display_stack() {
    rm -rf /tmp/.X99-lock /tmp/.X11-unix/X99

    Xvfb :99 -screen 0 "${WIDTH}x${HEIGHT}x24" -dpi "${SCREEN_DPI}" -nolisten tcp \
        >>"$LOG_DIR/xvfb.log" 2>&1 &
    PID_XVFB=$!
    sleep 2

    write_openbox_conf
    DISPLAY=:99 openbox >>"$LOG_DIR/openbox.log" 2>&1 &
    PID_WM=$!
    sleep 2
    # 自定义配置若不被接受则回退到 openbox 默认配置，避免窗口管理器没起来
    if ! kill -0 "${PID_WM}" 2>/dev/null; then
        log "openbox 自定义配置启动失败，回退默认配置"
        rm -f /root/.config/openbox/rc.xml
        DISPLAY=:99 openbox >>"$LOG_DIR/openbox.log" 2>&1 &
        PID_WM=$!
        sleep 1
    fi

    DISPLAY=:99 xset s off -dpms -display :99 s noblank >>"$LOG_DIR/xset.log" 2>&1 || true

    # -threads：启用多线程编码，多核 NAS 上画面刷新更跟手
    if [ -n "$VNC_PASSWORD" ]; then
        x11vnc -display :99 -forever -shared -threads -rfbport 5900 \
            -passwd "$VNC_PASSWORD" >>"$LOG_DIR/x11vnc.log" 2>&1 &
    else
        x11vnc -display :99 -forever -shared -threads -nopw -rfbport 5900 \
            >>"$LOG_DIR/x11vnc.log" 2>&1 &
    fi
    PID_X11VNC=$!
    sleep 1

    websockify --web=/usr/share/novnc "$NOVNC_PORT" 127.0.0.1:5900 \
        >>"$LOG_DIR/novnc.log" 2>&1 &
    PID_NOVNC=$!

    log "虚拟桌面 ${SCREEN_SIZE}（缩放 ${UI_SCALE}x / ${SCREEN_DPI}dpi）已就绪，noVNC 监听 ${NOVNC_PORT}"
}

# 定位主程序窗口：先按窗口类名匹配，匹配不到就取当前活动窗口，再不行取面积最大的可见窗口
find_app_window() {
    local c id
    for c in "com.qzonephoto.app" "qzone-photo" "QzonePhoto" "qzonephoto" "企鹅相册"; do
        id="$(DISPLAY=:99 xdotool search --onlyvisible --limit 1 --class "$c" 2>/dev/null | head -n 1)"
        if [ -n "$id" ]; then
            printf '%s\n' "$id"
            return 0
        fi
    done

    id="$(DISPLAY=:99 xdotool getactivewindow 2>/dev/null | head -n 1)"
    if [ -n "$id" ] && DISPLAY=:99 xdotool getwindowname "$id" >/dev/null 2>&1; then
        printf '%s\n' "$id"
        return 0
    fi

    local best="" best_area=0 geo w h area
    for id in $(DISPLAY=:99 xdotool search --onlyvisible "" 2>/dev/null | head -n 30); do
        geo="$(DISPLAY=:99 xdotool getwindowgeometry --shell "$id" 2>/dev/null)"
        w="$(printf '%s\n' "$geo" | sed -n 's/^WIDTH=//p' | head -n 1)"
        h="$(printf '%s\n' "$geo" | sed -n 's/^HEIGHT=//p' | head -n 1)"
        [ -n "$w" ] && [ -n "$h" ] || continue
        if [ "$w" -le 1 ] || [ "$h" -le 1 ]; then continue; fi
        area=$((w * h))
        if [ "$area" -gt "$best_area" ]; then
            best_area="$area"
            best="$id"
        fi
    done
    [ -n "$best" ] && printf '%s\n' "$best"
}

# 把主程序窗口铺满虚拟屏幕；启动初期窗口还没创建，需要多试几次
fit_window() {
    local id="" i
    for i in 1 2 3 4 5 6 7 8; do
        sleep 5
        id="$(find_app_window)"
        [ -n "$id" ] || continue
        DISPLAY=:99 xdotool windowactivate --sync "$id" >>"$LOG_DIR/xdotool.log" 2>&1 || true
        DISPLAY=:99 xdotool windowstate --add MAXIMIZED_HORZ --add MAXIMIZED_VERT "$id" \
            >>"$LOG_DIR/xdotool.log" 2>&1 || true
        DISPLAY=:99 xdotool windowmove "$id" 0 0 >>"$LOG_DIR/xdotool.log" 2>&1 || true
        DISPLAY=:99 xdotool windowsize "$id" "$WIDTH" "$HEIGHT" >>"$LOG_DIR/xdotool.log" 2>&1 || true
        log "主程序窗口 ${id} 已铺满 ${SCREEN_SIZE}"
        return 0
    done
    log "提示：未定位到主程序窗口，可进入桌面后手动最大化窗口"
}

# 运行期巡检：主程序重启后窗口会回到默认尺寸，这里再拉一次
refit_if_needed() {
    local id geo w h
    id="$(find_app_window)"
    [ -n "$id" ] || return 0
    geo="$(DISPLAY=:99 xdotool getwindowgeometry --shell "$id" 2>/dev/null)"
    w="$(printf '%s\n' "$geo" | sed -n 's/^WIDTH=//p' | head -n 1)"
    h="$(printf '%s\n' "$geo" | sed -n 's/^HEIGHT=//p' | head -n 1)"
    [ -n "$w" ] && [ -n "$h" ] || return 0
    if [ "$w" -lt "$WIDTH" ] || [ "$h" -lt "$HEIGHT" ]; then
        DISPLAY=:99 xdotool windowstate --add MAXIMIZED_HORZ --add MAXIMIZED_VERT "$id" \
            >>"$LOG_DIR/xdotool.log" 2>&1 || true
        DISPLAY=:99 xdotool windowsize "$id" "$WIDTH" "$HEIGHT" >>"$LOG_DIR/xdotool.log" 2>&1 || true
        log "窗口尺寸回退到 ${w}x${h}，已重新铺满 ${SCREEN_SIZE}"
    fi
}

start_app() {
    DISPLAY=:99 HOME=/root "$APP_BIN" \
        --no-sandbox \
        --disable-gpu \
        --disable-dev-shm-usage \
        --disable-software-rasterizer \
        --no-first-run \
        --disable-features=DBusMenu \
        --force-device-scale-factor="${UI_SCALE}" \
        >>"$LOG_DIR/app.log" 2>&1 &
    PID_APP=$!
    log "主程序已启动 pid=${PID_APP}（界面缩放 ${UI_SCALE}x）"
}

# 列出容器内可直接访问的数据目录，便于确认「其它盘」是否已挂进来
# 宿主路径与容器内路径一致（/vol1 → /vol1），客户端里直接填飞牛上看到的路径
log_mounts() {
    local found=0
    for d in /downloads /vol[0-9] /vol[0-9][0-9] /mnt/* /media/*; do
        [ -d "$d" ] || continue
        found=1
        log "可访问目录：${d}"
    done
    [ "$found" = "1" ] || log "提示：当前没有挂载任何额外存储卷"
}
log_mounts

# HEIC 转换工具：扫描允许根目录下的 .heic 并转成 JPG，供客户端上传
start_heic_tool() {
    if ! command -v python3 >/dev/null 2>&1; then
        log "未找到 python3，HEIC 转换工具不启动"
        return 0
    fi
    if [ ! -f /usr/local/bin/heic-tool/server.py ]; then
        log "未找到 HEIC 转换工具，跳过"
        return 0
    fi
    # 默认根目录：共享目录 + 已挂载的存储卷；若用户显式设置了 HEIC_TOOL_ROOTS 则不覆盖
    if [ -z "${HEIC_TOOL_ROOTS_OVERRIDE:-}" ]; then
        local roots="/downloads"
        for d in /vol[0-9]* /vol[0-9][0-9] /mnt/* /media/*; do
            [ -d "$d" ] && roots="${roots},${d}"
        done
        HEIC_TOOL_ROOTS="$roots"
    fi
    # 访问口令：与远程桌面密码取同一个值（HEIC_TOOL_PASSWORD 为空时 8090 不做认证）
    [ -n "${HEIC_TOOL_PASSWORD:-}" ] || HEIC_TOOL_PASSWORD="${VNC_PASSWORD:-}"
    HEIC_TOOL_PORT="$HEIC_TOOL_PORT" HEIC_TOOL_ROOTS="$HEIC_TOOL_ROOTS" \
        HEIC_TOOL_PASSWORD="$HEIC_TOOL_PASSWORD" \
        python3 /usr/local/bin/heic-tool/server.py >>"$LOG_DIR/heic-tool.log" 2>&1 &
    PID_HEIC=$!
    if [ -n "$HEIC_TOOL_PASSWORD" ]; then
        log "HEIC 转换工具已启动 pid=${PID_HEIC}（端口 ${HEIC_TOOL_PORT}，已启用访问密码）"
    else
        log "HEIC 转换工具已启动 pid=${PID_HEIC}（端口 ${HEIC_TOOL_PORT}，未设密码，无需认证）"
    fi
}

log "启动虚拟桌面 ${SCREEN_SIZE}，界面缩放 ${UI_SCALE}x"
start_display_stack
start_heic_tool
fit_window &
start_app

TICK=0
while true; do
    if ! kill -0 "${PID_XVFB:-}" 2>/dev/null; then
        log "Xvfb 已退出，重启显示栈"
        start_display_stack
    fi
    if ! kill -0 "${PID_X11VNC:-}" 2>/dev/null; then
        log "x11vnc 已退出，重启显示栈"
        start_display_stack
    fi
    if ! kill -0 "${PID_NOVNC:-}" 2>/dev/null; then
        log "noVNC 已退出，重启显示栈"
        start_display_stack
    fi
    if ! kill -0 "${PID_HEIC:-}" 2>/dev/null; then
        log "HEIC 转换工具已退出，重新启动"
        start_heic_tool
    fi
    if ! kill -0 "${PID_APP:-}" 2>/dev/null; then
        log "主程序已退出，重新启动"
        start_app
        fit_window &
    fi
    TICK=$((TICK + 1))
    if [ $((TICK % 6)) = 0 ]; then
        refit_if_needed
    fi
    sleep 10
done
