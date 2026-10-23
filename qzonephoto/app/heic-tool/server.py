#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HEIC 转换工具 —— 企鹅相册 fnOS 容器配套

为什么需要它：
    QzonePhoto 官方向上只接受 JPG / PNG / GIF / BMP / WEBP，HEIC 在文件选择框被硬拦截；
    而且 debian:12-slim 容器没有 HEIC 解码库，Electron/Chromium 也解不出 HEIC 缩略图。
    这与官方 QQ 相册工具的做法一致：上传前先把 HEIC 转成 JPG，再交给客户端上传。

本服务：
    1) 扫描允许根目录下的 .heic / .HEIC 文件，返回可勾选清单（含大小、修改时间）；
    2) 将勾选的文件在同目录转成同名 .jpg（heif-convert，质量可调）；
    3) 转完后在「企鹅相册」客户端里把生成的 JPG 正常上传即可。

纯标准库实现，无第三方依赖。安全边界：
    1) 扫描/转换路径必须位于允许根目录内，禁止 .. 逃逸；
    2) 访问认证：设置 HEIC_TOOL_PASSWORD 后启用认证，只校验口令，不需要用户名
       （页面自带口令输入框，只填一个密码即可；直接访问接口仍走标准 Basic 认证，
        用户名可留空）。未设置口令时不做认证（适合仅本机/内网可信环境）。
"""
import argparse
import base64
import hmac
import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

DEFAULT_ROOTS = ["/downloads"]
SCAN_MAX_DEPTH = 8
HEIF_CONVERT = "heif-convert"


def norm_path(p):
    return os.path.normpath(os.path.abspath(p))


def is_under_roots(path, roots):
    path = norm_path(path)
    for r in roots:
        r = norm_path(r)
        if path == r or path.startswith(r + os.sep):
            return True
    return False


def list_heic(root, recursive=True):
    root = norm_path(root)
    if not os.path.isdir(root):
        return []
    out = []
    if recursive:
        for dirpath, dirnames, filenames in os.walk(root):
            depth = dirpath[len(root):].count(os.sep)
            if depth >= SCAN_MAX_DEPTH:
                dirnames[:] = []
            for fn in filenames:
                if fn.lower().endswith(".heic"):
                    fp = os.path.join(dirpath, fn)
                    try:
                        st = os.stat(fp)
                        out.append({
                            "path": fp,
                            "name": fn,
                            "size": st.st_size,
                            "mtime": int(st.st_mtime),
                        })
                    except OSError:
                        continue
    else:
        try:
            for fn in os.listdir(root):
                fp = os.path.join(root, fn)
                if fn.lower().endswith(".heic") and os.path.isfile(fp):
                    st = os.stat(fp)
                    out.append({
                        "path": fp,
                        "name": fn,
                        "size": st.st_size,
                        "mtime": int(st.st_mtime),
                    })
        except OSError:
            pass
    out.sort(key=lambda x: x["path"])
    return out


def list_dirs(root):
    """列出某个目录下的直接子目录，供前端「选择输出位置」时使用"""
    root = norm_path(root)
    if not os.path.isdir(root):
        return []
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return []
    out = []
    for n in names:
        if n.startswith("."):
            continue
        fp = os.path.join(root, n)
        if os.path.isdir(fp):
            out.append(fp)
    return out


def build_dst(src, outdir, base, keepstruct, ext):
    """计算输出文件路径。

    - 未指定 outdir：与原 HEIC 同目录，仅换扩展名。
    - 指定 outdir 且 keepstruct：把 src 相对基准目录 base 的子目录结构
      原样搬到 outdir 之下（只换最前面的根），例如
        base=/downloads/photos, src=/downloads/photos/2023/trip/a.heic
        outdir=/vol2/jpg  →  /vol2/jpg/2023/trip/a.jpg
    - 无法算出相对路径（不在 base 下）时退化为平铺到 outdir。
    """
    src_dir = os.path.dirname(src)
    stem = os.path.splitext(os.path.basename(src))[0] + ext
    if not outdir:
        return os.path.join(src_dir, stem)
    dst_root = norm_path(outdir)
    dst_dir = dst_root
    if keepstruct and base:
        try:
            rel = os.path.relpath(src_dir, norm_path(base))
        except ValueError:
            rel = None
        if rel and rel != "." and not rel.startswith(".."):
            dst_dir = os.path.join(dst_root, rel)
    return os.path.join(dst_dir, stem)


def convert_one(src, quality, outdir=None, base=None, keepstruct=True, fmt="jpg"):
    src = norm_path(src)
    if not src.lower().endswith(".heic") or not os.path.isfile(src):
        return {"src": src, "ok": False, "msg": "文件不存在或非 HEIC"}
    png = str(fmt).lower() == "png"
    ext = ".png" if png else ".jpg"
    try:
        src_size = os.path.getsize(src)
    except OSError:
        src_size = 0

    dst = build_dst(src, outdir, base, keepstruct, ext)
    dst_dir = os.path.dirname(dst)
    # 目标已存在则跳过，避免覆盖已有文件
    if os.path.exists(dst):
        return {"src": src, "ok": True, "skipped": True, "dst": dst,
                "size": os.path.getsize(dst), "srcSize": src_size, "msg": "目标已存在，跳过"}
    try:
        # 保持目录结构时可能多级子目录都不存在，这里统一创建
        os.makedirs(dst_dir, exist_ok=True)
    except OSError as e:
        return {"src": src, "ok": False, "msg": "无法创建输出目录 %s：%s" % (dst_dir, e.strerror or e)}

    cmd = [HEIF_CONVERT]
    if not png:
        # -q 只对有损的 JPG 有效；PNG 是无损压缩，传入无意义
        cmd += ["-q", str(quality)]
    cmd += [src, dst]
    try:
        # errors=replace：极端情况下 heif-convert 的输出含非 UTF-8 字节时不至于让本线程崩溃
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120, errors="replace")
    except subprocess.TimeoutExpired:
        return {"src": src, "ok": False, "msg": "转换超时（>120s）"}
    except FileNotFoundError:
        return {"src": src, "ok": False, "msg": "未找到 heif-convert，请确认容器已安装 libheif-examples"}
    if proc.returncode != 0:
        return {"src": src, "ok": False, "msg": (proc.stderr or proc.stdout).strip()[:300]}
    if not os.path.exists(dst):
        return {"src": src, "ok": False, "msg": "转换命令已返回成功但未生成文件"}
    return {"src": src, "ok": True, "dst": dst, "size": os.path.getsize(dst),
            "srcSize": src_size, "msg": "成功"}


class Handler(BaseHTTPRequestHandler):
    roots = DEFAULT_ROOTS
    quality = 90
    # 访问口令（HTTP Basic 认证）。为空表示不启用认证。
    # 由环境变量 HEIC_TOOL_PASSWORD 提供，飞牛包里与「远程桌面密码」取同一个值。
    auth_password = ""

    def _is_xhr(self):
        """页面自身的 fetch 会带 X-Requested-With，用于和浏览器地址栏直接访问区分。"""
        return bool(self.headers.get("X-Requested-With"))

    def _unauthorized(self):
        """口令校验失败。

        浏览器只在响应带 WWW-Authenticate 时才会弹出「用户名 + 密码」原生弹窗，
        而本工具不需要用户名。因此对页面发起的 XHR 不回该头部，改以 401 + JSON
        告知前端，由页面内的口令输入框处理；直接用浏览器/其它客户端打开接口时，
        仍回标准 Basic 认证头（用户名留空即可）。
        """
        if self._is_xhr():
            self._send_json({"error": "需要访问口令", "needAuth": True}, 401)
            return
        self.send_response(401)
        self.send_header('WWW-Authenticate', 'Basic realm="HEIC Tool", charset="UTF-8"')
        self.send_header("Content-Length", "0")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

    def _authorized(self):
        """未设置口令时放行；否则只校验口令本身（用户名可留空）。"""
        if not self.auth_password:
            return True
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            self._unauthorized()
            return False
        try:
            raw = base64.b64decode(header.split(" ", 1)[1]).decode("utf-8")
        except Exception:
            self._unauthorized()
            return False
        _, _, pw = raw.partition(":")
        if not hmac.compare_digest(pw, self.auth_password):
            self._unauthorized()
            return False
        return True

    def _send_json(self, obj, code=200):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def _send_file(self, path, ctype):
        try:
            with open(path, "rb") as f:
                body = f.read()
        except OSError:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        # 前端带自定义头（Authorization / X-Requested-With）时浏览器可能先发预检
        self.send_response(204)
        self.send_header("Allow", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Requested-With")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        # 页面本身不做认证：它只是静态 UI，不含任何数据；认证由页面内的口令框完成，
        # 这样浏览器不会弹出需要填用户名的原生认证框。所有 /api 接口仍强制认证。
        if parsed.path in ("/", "/index.html"):
            here = os.path.dirname(os.path.abspath(__file__))
            self._send_file(os.path.join(here, "index.html"), "text/html; charset=utf-8")
            return
        if not self._authorized():
            return
        # 口令校验探测：前端用它判断「是否需要口令 / 已填的口令是否正确」
        if parsed.path == "/api/ping":
            self._send_json({"ok": True, "needAuth": bool(self.auth_password)})
            return
        if parsed.path == "/api/roots":
            self._send_json({"roots": [norm_path(r) for r in self.roots]})
            return
        if parsed.path == "/api/dirs":
            # 列出直接子目录，供前端下拉选择输出位置
            qs = parse_qs(parsed.query)
            root = unquote(qs.get("root", [self.roots[0]])[0])
            if not is_under_roots(root, self.roots):
                self._send_json({"error": "路径不在允许目录内"}, 403)
                return
            root = norm_path(root)
            self._send_json({"root": root, "dirs": list_dirs(root)})
            return
        if parsed.path == "/api/scan":
            qs = parse_qs(parsed.query)
            root = qs.get("root", [self.roots[0]])[0]
            root = unquote(root)
            recursive = qs.get("recursive", ["1"])[0] != "0"
            if not is_under_roots(root, self.roots):
                self._send_json({"error": "路径不在允许目录内"}, 403)
                return
            self._send_json({"root": norm_path(root), "files": list_heic(root, recursive)})
            return
        self.send_error(404)

    def do_POST(self):
        if not self._authorized():
            return
        parsed = urlparse(self.path)
        if parsed.path == "/api/convert":
            try:
                length = int(self.headers.get("Content-Length", 0))
                raw = self.rfile.read(length) if length else b"{}"
                payload = json.loads(raw.decode("utf-8") or "{}")
            except (ValueError, json.JSONDecodeError):
                self._send_json({"error": "请求体不是合法 JSON"}, 400)
                return
            files = payload.get("files", [])
            quality = int(payload.get("quality", self.quality))
            quality = max(1, min(100, quality))
            fmt = "png" if str(payload.get("format", "jpg")).lower() == "png" else "jpg"
            # 是否保留原目录结构（默认开启）；仅在指定了输出目录时有意义
            ks = payload.get("keepstruct")
            keepstruct = True if ks is None else bool(ks)
            # 输出目录：留空表示与原 HEIC 同目录
            raw_out = payload.get("outdir")
            outdir = raw_out.strip() if isinstance(raw_out, str) else ""
            if outdir:
                outdir = norm_path(outdir)
                if not is_under_roots(outdir, self.roots):
                    self._send_json({"error": "输出目录不在允许的根目录内"}, 403)
                    return
                try:
                    os.makedirs(outdir, exist_ok=True)
                except OSError as e:
                    self._send_json({"error": "无法创建输出目录：%s" % (e.strerror or e)}, 400)
                    return
            # 基准目录：用于把 src 之下的相对目录结构复制到输出根目录之下
            raw_base = payload.get("base")
            base = raw_base.strip() if isinstance(raw_base, str) else ""
            if base:
                base = norm_path(base)
                if not is_under_roots(base, self.roots):
                    self._send_json({"error": "基准目录不在允许的根目录内"}, 403)
                    return
            results = []
            for f in files:
                if not isinstance(f, str) or not is_under_roots(f, self.roots):
                    results.append({"src": f, "ok": False, "msg": "路径不在允许目录内"})
                    continue
                results.append(convert_one(f, quality, outdir or None, base or None, keepstruct, fmt))
            self._send_json({"results": results})
            return
        self.send_error(404)

    def log_message(self, fmt, *args):
        # 安静日志，避免刷屏
        pass


def main():
    ap = argparse.ArgumentParser(description="HEIC 转换工具（企鹅相册 fnOS 配套）")
    ap.add_argument("--port", type=int, default=int(os.environ.get("HEIC_TOOL_PORT", "8090")))
    ap.add_argument("--roots", default=os.environ.get("HEIC_TOOL_ROOTS", ",".join(DEFAULT_ROOTS)))
    ap.add_argument("--quality", type=int, default=90)
    # 访问口令：留空则不启用认证（与飞牛包里的「远程桌面密码」保持一致）
    ap.add_argument("--password", default=os.environ.get("HEIC_TOOL_PASSWORD", ""))
    args = ap.parse_args()

    roots = [r.strip() for r in args.roots.split(",") if r.strip()] or DEFAULT_ROOTS
    Handler.roots = roots
    Handler.quality = max(1, min(100, args.quality))
    Handler.auth_password = args.password

    httpd = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    auth_state = "已启用（与远程桌面密码相同）" if args.password else "未启用（未设置远程桌面密码）"
    print(
        f"[heic-tool] 监听 0.0.0.0:{args.port}，允许根目录：{roots}，访问认证：{auth_state}",
        flush=True,
    )
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
