# 企鹅相册 · QzonePhoto —— 飞牛 fnOS 应用包

把 [11273/QzonePhoto](https://github.com/11273/QzonePhoto)（Electron 桌面客户端）打包成可在飞牛 fnOS 应用中心安装、启停、卸载的 `.fpk`。

## 实现思路

QzonePhoto 是图形界面客户端，NAS 没有桌面环境，因此采用：

```
fnOS 应用中心
   └── cmd/main → docker compose up -d
                     └── 容器 qzonephoto-app（debian:12-slim）
                             ├─ Xvfb :99        虚拟显示
                             ├─ openbox         轻量窗口管理器
                             ├─ x11vnc :5900    VNC 服务
                             ├─ websockify      noVNC，对外 8080
                             └─ /opt/企鹅相册/qzone-photo
                                    ↓
                        浏览器打开 http://<NAS_IP>:8080/vnc.html 即可操作
```

包内**不含任何二进制**：安装时才从官方 GitHub Releases 拉取指定版本的 deb 构建镜像。

## 目录结构

```
qzonephoto/
├── manifest                 # appname=com.qzonephoto.app，端口 8080
├── ICON.PNG / ICON_256.PNG  # 64 / 256 应用图标
├── LICENSE                  # 授权与隐私说明
├── cmd/                     # 生命周期脚本（9 个）
│   ├── main                 # start / stop / status / reload
│   ├── install_init         # 校验 Docker 与 Compose 可用
│   ├── install_callback     # 写配置 → 生成 compose → docker build
│   ├── upgrade_init         # 备份旧配置
│   ├── upgrade_callback     # 保留用户配置，按需重建镜像
│   ├── config_init / config_callback
│   └── uninstall_init / uninstall_callback
├── config/privilege         # run-as root（Docker 控制必需）
├── config/resource          # data-share: qzonephoto-downloads
├── wizard/                  # install / upgrade / config / uninstall
└── app/                     # → 安装后 target
    ├── Dockerfile
    ├── entrypoint.sh
    ├── bin/render-compose.sh
    └── ui/{config,images/}
```

## 打包

```bash
tools/fnpack.exe build --directory qzonephoto
# 产出 qzonephoto/com.qzonephoto.app.fpk
```

（fnpack 是飞牛官方 CLI，已下载到 `tools/`，也可从 https://developer.fnnas.com/docs/cli/fnpack 重新获取。注意官方命令是 `build`，不是 `pack`。）

## 安装与使用

1. fnOS「应用中心 → Docker」先安装并启动 Docker（本包依赖宿主机 Docker）。
2. 应用中心右上角「手动安装」，选择 `com.qzonephoto.app.fpk`。
3. 安装向导：
   - 远程桌面分辨率（默认 1600x900）
   - 界面缩放（默认 125%，放大应用内的文字与按钮）
   - 远程桌面密码（可选，建议局域网内设置）
   - 上游版本号（默认 2.8.0）
   - GitHub 加速前缀（**默认已预填一个可用加速地址** `https://xsadwsd.kdns.fr/`，一般无需修改）
   - **容器内 Debian 软件源**（默认腾讯云，可选清华/阿里/华为/中科大/南大/网易/官方）
4. 首次安装需构建镜像，约 5–15 分钟。构建前会自动预检下载源并在日志里打印结果。
5. 启动后点击桌面「企鹅相册」图标，浏览器打开 `http://<NAS_IP>:8080` 操作客户端。
6. **在客户端里把下载目录设置成 `/downloads`**，文件会落到 fnOS 共享目录 `qzonephoto-downloads`。

## 画面偏小 / 偏糊怎么调

浏览器里看到的是容器内一块虚拟屏幕，画面大小由**三个因素**共同决定：

| 因素 | 在哪改 | 作用 |
| --- | --- | --- |
| 分辨率 | 应用「配置 → 显示与访问 → 远程桌面分辨率」 | 虚拟屏幕的像素数，1600x900 / 1920x1080 / 2560x1440 |
| 界面缩放 | 应用「配置 → 显示与访问 → 界面缩放」 | 100% / 125% / 150% / 175% / 200%，放大应用内的文字与按钮 |
| 浏览器缩放 | noVNC 左侧边栏 → Settings → Scaling | `None` = 1:1 原生像素（最清晰），`Local Scaling` = 拉伸填满窗口（会略糊） |

- **界面小** → 调大「界面缩放」。它是给 Electron 传 `--force-device-scale-factor`，
  以更高像素密度渲染（同时 Xvfb 的 DPI 同步提高），**放大后依然清晰**，不是把画面拉大。
- **画面糊** → 多半是浏览器在拉伸。把 noVNC 的 Scaling 设为 `None`，
  并把分辨率调成接近浏览器窗口的实际大小（例如浏览器窗口约 1900x1000 就选 1920x1080）。
- 两者是叠加关系，推荐组合：**1600x900 + 125%**、**1920x1080 + 150%**、**2560x1440 + 150%**。
  缩放越大，应用内可用区域（CSS 像素）越小，太大会导致布局拥挤。

改完会在「配置」提交后自动重启容器。主程序窗口会自动铺满虚拟屏幕；
万一没铺满，进入桌面后手动最大化一次即可。

## 重启与常用命令

安装目录随存储卷而变，先定位（下面用 `$APP_DIR` 指代查到的路径）：

```bash
ls -d /vol*/@appcenter/com.qzonephoto.app /usr/local/apps/@appcenter/com.qzonephoto.app 2>/dev/null
```

| 需求 | 做法 |
| --- | --- |
| 重启（最快） | `docker restart qzonephoto-app` |
| 图形界面重启 | 应用中心 → 已安装 → 企鹅相册 → **停止** → **启动** |
| 停 / 开（命令行） | `$APP_DIR/cmd/main stop`、`$APP_DIR/cmd/main start` |
| 看运行状态 | `$APP_DIR/cmd/main status`（exit 0 = 运行中，3 = 未运行） |
| 看容器日志 | `docker logs -n 200 -f qzonephoto-app` |
| 看应用与构建日志 | `$APP_DIR/cmd/main logs`（会打印日志真实路径 + 末尾 30 行） |
| 重建镜像并重启 | 应用「配置 → 版本维护 → 强制重建镜像」（约 5–15 分钟） |

- 容器内守护脚本每 10 秒巡检一次：主程序退出会自动拉起，Xvfb / x11vnc / noVNC 挂了会自动重启显示栈。
  所以**客户端崩了或界面卡住，刷新浏览器或 `docker restart` 就够了，不必重装**。
- 重启**不丢数据**：登录态与客户端配置在 `$APP_DIR/var/userdata`，下载文件在共享文件夹 `qzonephoto-downloads`。
- 容器反复起不来时按序看：`docker logs` → `$APP_DIR/var/app.log` → `$APP_DIR/var/build.log`。

## 排障一：401 Unauthorized / 无法获取基础镜像

**这是飞牛 fnOS 自身的已知问题，不是本安装包的问题。**

fnOS 在 `/etc/docker/daemon.json` 里预置了默认加速源 `https://docker.fnnas.com`，
但它要求请求携带私有认证头（`X-Meta-Sign` / `X-Meta-Token`），
而标准 Docker 客户端、`docker pull`、`docker build` 都拿不到这个头
（实测其 401 响应中**没有** `Www-Authenticate`，连标准 Bearer 流程都走不了）→ 必然 401。

**本包已做的规避**：

1. Dockerfile **不再使用** `# syntax=docker/dockerfile:1` 指令 —— 该指令会额外拉取
   BuildKit 前端镜像，直接撞上这个 401，导致构建在第一步就失败（就是你看到的现象）。
2. 基础镜像改由安装脚本预先准备：**本地已有则直接用；没有则自动从走标准鉴权流程的加速源拉取**
   （`docker.1ms.run` → `docker.m.daocloud.io` → 原始 `debian:12-slim`），锁定后再交给构建。
3. 构建加 `--pull=false`，基础镜像就绪后不再回源查询。

**如果仍然失败**（三个源都不通），在飞牛里手动处理一次：

> 打开**飞牛桌面 → Docker → 镜像仓库 → 右上角「仓库设置」**，
> 添加地址 `https://docker.1ms.run`，保存后**选中它并启用**，重启 Docker。

⚠️ **不要**用 `sed`/`echo` 之类命令直接改 `/etc/docker/daemon.json`。
该文件里还有 `data-root`（存储路径）等关键配置，改坏了会导致**已有镜像和容器全部消失**。

## 排障二：`Unable to locate package libatk-bridge2.0-0 / libcups2`

**根因不是源里没有这两个包，而是旧逻辑「哪个源 `apt-get update` 先成功就定死用谁」。**
该源的索引一旦不完整（镜像同步滞后、只同步了部分组件），后续 `apt-get install` 就整体失败，
而且**永远不会去试第二个源**。

本包已重写这一步（`app/provision.sh`）：

1. **逐个候选源尝试**，判定标准是「`apt-get update` 成功 **且** 44 个依赖包全部能定位」，
   不是只看 update 成不成功。缺包的源会被跳过，自动换下一个。
2. 发行版代号**从 `/etc/os-release` 读取**而非写死。
3. 包名支持备选：Debian 13 起 `libcups2 → libcups2t64`、`libatk-bridge2.0-0 → ...t64`
   等 64 位 time_t 迁移改名，按索引里真实存在的名字选取。
4. **装完 deb 后用 `ldd` 读真实缺失的 `.so`**，映射回包名自动补装（最多两轮），
   避免"安装成功但客户端一启动就崩"的假成功；两轮仍缺会明确列出缺什么。

日志里会逐源打印结果，一眼能看到卡在哪：

```
[诊断] 源 http://mirrors.cloud.tencent.com/debian：索引可访问，但缺少这些包 → libatk-bridge2.0-0 libcups2
>>> 采用软件源: http://mirrors.tuna.tsinghua.edu.cn/debian（bookworm，44/44 个包全部可定位）
```

## 排障三：镜像构建失败（网络类）

最常见的原因不是脚本，而是 **`docker build` 走的是容器自己的网络命名空间**——宿主机上监听 `127.0.0.1` 的代理、
hosts 记录、`/etc/resolv.conf` 在构建容器里统统拿不到，所以「开不开代理都失败」是典型症状。

本包已做四处处理：

1. `docker build --network=host`：构建时复用宿主机网络栈，127.0.0.1 的代理和 DNS 直接生效。
2. 代理自动透传：`http_proxy / https_proxy / no_proxy`（含大写写法）原样传进构建。
3. Debian 源改为**候选链**：向导里选的是首选源，脚本会预检并把可达的源排到前面，
   容器内按顺序逐个 `apt-get update`，任一成功即用；全失败再回退 Debian 官方源。
4. deb 下载源多级兜底，顺序为 **内置加速 `https://xsadwsd.kdns.fr/` → 直连 → ghfast.top → gh-proxy.com → ghps.cc**，
   并对每个候选做真实性校验（ar 包魔数 `!<arch>` + 最小体积），避免加速站返回 HTML 错误页被误判成下载成功。

**关键：构建加了 `--progress=plain`。** 没有它，Docker 在 `RUN` 失败时**只回显失败的命令本身、不回显命令的输出**，
`apt` / `curl` 的真实报错会被完全吞掉——你会看到一大坨 `/bin/sh -c ...` 却不知道到底哪一步、为什么失败。
加上它之后，构建日志里会有完整的输出，安装失败的弹窗也会自动提取出关键错误行（含 `E:`、`404`、`Temporary failure` 等）。

构建前会在宿主机做两轮预检（各几十秒）：**先确保基础镜像可获取，再预检 apt 源与 deb 下载源**，
把可用的那个锁定后再启动构建，避免 apt 依赖装了好几分钟才失败。日志形如：

```
apt  源预检 [200] http://mirrors.cloud.tencent.com/debian
deb  源预检 [200] https://xsadwsd.kdns.fr/https://github.com/.../QzonePhoto-2.8.0-linux-amd64.deb
软件源尝试顺序：http://mirrors.cloud.tencent.com/debian ...
deb 源预检成功（HTTP 200），锁定下载来源：https://xsadwsd.kdns.fr/
```

### 构建日志在哪

**注意：安装失败时飞牛会回滚并删除应用目录**，应用内的日志会随之消失，所以构建日志始终会在 `/tmp` 同步留一份副本。

| 用途 | 路径 |
|---|---|
| 应用内日志（安装成功后可查） | `<安装目录>/var/build.log`，安装目录形如 `/vol2/@appcenter/com.qzonephoto.app/` |
| **临时副本（失败回滚后仍在）** | `/tmp/qzonephoto-build.log` |

不确定安装目录在哪，一条命令就能找到：

```bash
ls -d /vol*/@appcenter/com.qzonephoto.app /usr/local/apps/@appcenter/com.qzonephoto.app 2>/dev/null
# 或
find /vol* /usr/local/apps -maxdepth 4 -name build.log -path '*com.qzonephoto*' 2>/dev/null
```

若已安装成功，也可以直接问应用自己：

```bash
<安装目录>/target/cmd/main logs     # 打印全部日志路径并 tail 末尾 30 行
```

### 不依赖飞牛，直接复现构建

应用目录被回滚删掉也能跑——把 fpk 里的 `app/` 解到 `/tmp` 单独构建，看到的就是完整报错：

```bash
mkdir -p /tmp/qzd && cd /tmp/qzd
tar -xzf /path/to/com.qzonephoto.app.fpk app.tgz   # fpk 是 tar.gz
tar -xzf app.tgz
APP_VERSION=2.8.0 \
GITHUB_MIRROR=https://xsadwsd.kdns.fr/ \
BUILTIN_GITHUB_MIRROR=https://xsadwsd.kdns.fr/ \
IMAGE_TAG=qzonephoto-fnos:2.8.0 \
  bash bin/build-image.sh . /tmp/qz-manual.log
echo "退出码=$?"; tail -n 40 /tmp/qz-manual.log
```

### 三步定位

在 NAS 终端里跑这三条，能立刻分清是哪一环出问题：

```bash
# ① 容器里 Debian 官方源通不通（--network=host 是关键）
docker run --rm --network=host debian:12-slim bash -c "apt-get update -qq && echo 官方源OK"

# ② 国内镜像源通不通
docker run --rm --network=host debian:12-slim bash -c \
  "echo 'deb http://mirrors.cloud.tencent.com/debian bookworm main' > /etc/apt/sources.list && apt-get update -qq && echo 镜像源OK"

# ③ 宿主机代理在容器里能不能用（把端口换成你自己的代理端口）
docker run --rm --network=host -e http_proxy=http://127.0.0.1:7890 \
  debian:12-slim bash -c "curl -sI https://github.com | head -1"
```

| ① | ② | ③ | 结论与处理 |
|---|---|---|---|
| OK | OK | OK | 网络没问题，把 `/tmp/qzonephoto-build.log` 末尾发来看真实报错 |
| 失败 | OK | - | Debian 官方源不通，安装向导里把软件源显式选**腾讯云 / 清华 TUNA / 阿里云** |
| OK | 失败 | - | 同上，换源；也可让向导留空，容器内会按候选链逐个尝试 |
| - | - | 失败 | 代理没生效，检查端口是否只监听 `127.0.0.1`（必须依赖 `--network=host`，已默认开启），或改填代理的**局域网 IP** |
| 全失败 | | | NAS 出口受限/DNS 异常，先在飞牛「网络设置」里确认能上网 |

## 数据存放

| 内容 | 位置 | 卸载时 |
|------|------|--------|
| 登录态、客户端配置 | `<安装目录>/var/userdata` | 默认保留 |
| 下载的照片视频 | 共享目录 `qzonephoto-downloads` | 默认保留 |
| 容器编排、日志 | `<安装目录>/var/` | 默认保留 |

安装目录由安装时选择的存储空间决定，形如 `/vol2/@appcenter/com.qzonephoto.app/`。

卸载向导可选择「删除所有数据」；选择保留时重装后可断点续传。

## 访问其它存储卷（跨盘）

应用只装在一个盘上，默认只能看到自己的共享目录。若需要让客户端读写**其它盘**，把那个盘挂进容器即可。

**容器内路径 = 宿主机路径**（`/vol1` → `/vol1`），所以在客户端里直接填你在飞牛文件管理器里看到的路径就行，不用换算。

| 容器内路径 | 对应 |
|---|---|
| `/downloads` | 应用共享目录 `qzonephoto-downloads`（默认下载位置） |
| `/vol1`、`/vol2` … | 飞牛的各个存储卷（自动挂载时） |
| `/mnt/xxx`、`/media/xxx` | 外接存储设备（自动挂载时） |

### 怎么改

应用 → **配置 → 存储与挂载**：

- **挂载方式**
  - `自动挂载所有存储卷`（推荐）— 自动探测 `/volN`、`/mnt/*`、`/media/*`
  - `仅挂载下方手动填写的目录` — 不自动探测，只用手填（**填此模式且留空 = 清空挂载**）
  - `保持当前设置` — 不动
- **额外挂载目录** — 在自动探测之外再追加，多个用空格、逗号或换行分隔，例如 `/vol1/照片 /mnt/usb`

改完会重新生成 `docker-compose.yml` 并重启容器。

### 安全边界

`/etc`、`/usr`、`/var`、`/bin`、`/boot`、`/dev`、`/proc`、`/sys`、`/root`、`/sbin`、`/lib*` 等系统目录
**一律拒绝挂载**（含其子目录），由 `app/bin/resolve-mounts.sh` 强制过滤。
路径中含 `..`、含空格、非绝对路径、不存在的目录同样会被忽略。

⚠️ 挂载整个存储卷意味着容器里能看到该卷上的**全部文件**（包括其它应用的数据）。
而远程桌面默认无密码，局域网内任何人打开 `http://<NAS_IP>:8080` 都能操作。
**务必同时设置远程桌面密码。**

### 排障

看不到某个盘时，在 NAS 终端里确认它在宿主机上的真实路径：

```bash
ls -d /vol* /mnt/* /media/* 2>/dev/null
df -h | grep -E '/vol|/mnt|/media'
```

若盘的路径不在 `/volN` / `/mnt/*` / `/media/*` 之下（例如自行挂载在别处），
在「额外挂载目录」里手工填写该路径即可。

## 升级

### 升级本安装包（fnOS 侧）

改 `manifest` 的 `version` 并**递增**（fnOS 靠它判断是否有新版本，不递增无法覆盖安装/升级），重新打包即可。
当前包版本：见 `manifest` 的 `version`；版本号与上游客户端版本**无关**，别混为一谈。

### 升级上游客户端（QzonePhoto 侧）

改 `wizard/install` 里 `wizard_app_version` 的默认值（当前 2.8.0），重新打包；
也可不动包，直接在应用「配置 → 版本维护」里改上游版本号，会触发 config_callback 自动构建新镜像
（版本号需真实存在于上游 GitHub Releases，镜像 tag 为 `qzonephoto-fnos:<上游版本>`）。

## 已知限制

- **需要 root 权限运行**：控制宿主机 Docker 必须具备 root，第三方开发者无法提交到飞牛官方应用市场，本包仅适合本地打包自行安装。
- 仅 x86_64（上游 Linux 版只发布 amd64 deb），飞牛 ARM 机型不可用。
- 端口固定 8080，manifest `service_port` 与该值一致；如需修改请同步改 `manifest`、`app/ui/config` 中的 `port`。
- 通过 VNC 操作图形界面，输入法直接输入依赖客户端自身；中文剪贴板不可用时应改为在客户端内操作。
- 受 QQ 空间接口限制，登录态失效后需重新扫码登录。
