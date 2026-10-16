#!/bin/bash
# 构建期脚本公共函数（由 provision.sh / install-deb.sh source，不单独执行）

log() { printf '%s\n' "$*"; }
diag() { printf '[诊断] %s\n' "$*"; }
die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# 发行版代号：不写死（Debian 12=bookworm、13=trixie …）。
# DEB_SUITE 仅用于离线自测时覆盖。
detect_suite() {
    if [ -n "${DEB_SUITE:-}" ]; then
        printf '%s' "$DEB_SUITE"
        return 0
    fi
    local s
    s="$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}")"
    [ -n "$s" ] || s=bookworm
    printf '%s' "$s"
}

OFFICIAL_BASE="http://deb.debian.org/debian"
OFFICIAL_SEC="http://security.debian.org/debian-security"

# 国内镜像的安全仓库地址 = 仓库地址 + "-security"；官方源是独立域名
security_of() {
    case "$1" in
    "$OFFICIAL_BASE" | "http://ftp.debian.org/debian") printf '%s' "$OFFICIAL_SEC" ;;
    *) printf '%s-security' "$1" ;;
    esac
}

# 写入 sources.list；$1=仓库地址，$2=发行版代号
write_sources() {
    local base="$1" suite="$2" sec
    sec="$(security_of "$1")"
    {
        printf 'deb %s %s main contrib non-free-firmware\n' "$base" "$suite"
        printf 'deb %s %s-updates main contrib non-free-firmware\n' "$base" "$suite"
        printf 'deb %s %s-security main contrib non-free-firmware\n' "$sec" "$suite"
    } >/etc/apt/sources.list
    rm -f /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list 2>/dev/null || true
}

# 包是否存在于当前索引：按输出判断，不依赖 apt-cache 的返回码
# （apt-cache show 在包不存在时仍可能返回 0）
pkg_exists() {
    apt-cache show "$1" 2>/dev/null | grep -q '^Package: '
}

# 从 "名1|名2|名3" 中取当前索引里存在的第一个名字
pick() {
    local n
    for n in $(printf '%s' "$1" | tr '|' ' '); do
        if pkg_exists "$n"; then
            printf '%s' "$n"
            return 0
        fi
    done
    return 1
}
