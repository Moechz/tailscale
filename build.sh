#!/usr/bin/env bash
# ============================================================
# build.sh —— 把 Tailscale 封装成 TOS 7 应用中心规范的 deb
#
#   规范依据:
#     - /Volume1/projects/TOS-DEB-PACKAGING-GUIDE.md（真机坑清单）
#     - https://github.com/terramaster-tos/tos-app-pkg-tools
#
#   形态: deb / 新标签页(External Open) / 回环 + 平台 nginx 反代
#   阶段: fetch → stage → verify → deb
#
#   产物 out/:
#     tailscale_<版本>_<arch>.deb       本地安装测试（带版本号）
#     tailscale_<platform>.deb          商店 Release 资产名（无版本号）
#     tailscale_<platform>.deb.sha256   上架必需的校验文件
#
#   用法:
#     ./build.sh all
#     TARGET_ARCH=arm64 ./build.sh all
#     ./build.sh fetch|stage|verify|deb|clean|info
# ============================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.env
. "$SCRIPT_DIR/config.env"

BUILD_DIR="$SCRIPT_DIR/build"
DL_DIR="$BUILD_DIR/downloads"
STAGE_DIR="$BUILD_DIR/pkgroot-$TARGET_ARCH"   # 按架构隔离，避免双架构互相覆盖
WEBUI_DIR="$BUILD_DIR/webui"
OUT_DIR="$SCRIPT_DIR/out"
ASSETS_DIR="$SCRIPT_DIR/assets"

VERSION_FULL="${TS_VERSION}-${PKG_RELEASE}"

case "$TARGET_ARCH" in
  amd64) TOS_PLATFORM="x86_64";  TGZ="tailscale_${TS_VERSION}_amd64.tgz"; PINNED_SHA256="$SHA256_TARBALL_AMD64"; ELF_MACHINE="x86-64" ;;
  arm64) TOS_PLATFORM="aarch64"; TGZ="tailscale_${TS_VERSION}_arm64.tgz"; PINNED_SHA256="$SHA256_TARBALL_ARM64"; ELF_MACHINE="ARM aarch64" ;;
  *) echo "错误: 未知 TARGET_ARCH=$TARGET_ARCH（支持 amd64 / arm64）" >&2; exit 1 ;;
esac

DEB_FILE="$OUT_DIR/${APP_ID}_${VERSION_FULL}_${TARGET_ARCH}.deb"
STORE_DEB="$OUT_DIR/${APP_ID}_${TOS_PLATFORM}.deb"

MAINTAINER_FULL="$MAINTAINER_NAME <$MAINTAINER_EMAIL>"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

fetch() { # fetch <url> <dest>
  local url=$1 dest=$2 attempt=0
  if [ -s "$dest" ]; then log "已缓存: $(basename "$dest")"; return 0; fi
  mkdir -p "$(dirname "$dest")"
  log "下载: $(basename "$dest")"
  while [ $attempt -lt 6 ]; do
    attempt=$((attempt+1))
    if curl -4 -fL --retry 3 --retry-delay 2 --connect-timeout 20 -C - -o "$dest.part" "$url"; then
      mv "$dest.part" "$dest"; return 0
    fi
    rm -f "$dest.part"
    warn "下载失败（第 $attempt 次），5 秒后重试…"
    sleep 5
  done
  die "下载失败: $url"
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

# ============================================================
# fetch
# ============================================================
stage_fetch() {
  mkdir -p "$DL_DIR"
  fetch "$UPSTREAM_BASE/$TGZ" "$DL_DIR/$TGZ"
  fetch "$UPSTREAM_REPO/raw/v${TS_VERSION}/LICENSE" "$DL_DIR/LICENSE"

  local got
  got=$(sha256_of "$DL_DIR/$TGZ")
  [ "$got" = "$PINNED_SHA256" ] || die "sha256 与 config.env pin 不符（want=$PINNED_SHA256 got=$got）"
  log "sha256 校验通过（$TARGET_ARCH → $TOS_PLATFORM）"
}

# ============================================================
# stage
# ============================================================
stage_stage() {
  local APP="$STAGE_DIR/usr/local/$APP_ID"
  local EXTRACT="$BUILD_DIR/extract-$TARGET_ARCH"
  log "组装文件系统树（$TOS_PLATFORM）"
  rm -rf "$STAGE_DIR" "$EXTRACT"
  mkdir -p "$STAGE_DIR/usr/share/doc/$APP_ID"
  mkdir -p "$APP/bin" "$APP/images/icons" "$APP/nginx" "$APP/init.d" "$APP/webui"
  mkdir -p "$STAGE_DIR/etc/systemd/system" "$STAGE_DIR/etc/nginx/conf.d" \
           "$STAGE_DIR/etc/tmpfiles.d" "$STAGE_DIR/etc/polkit-1/rules.d"

  # ---- 上游二进制（原样解出，不 strip / 不加壳）----
  log "  + bin/tailscaled, bin/tailscale（上游 $TS_VERSION 官方静态包）"
  mkdir -p "$EXTRACT"
  tar xzf "$DL_DIR/$TGZ" -C "$EXTRACT"
  local src="$EXTRACT/tailscale_${TS_VERSION}_${TARGET_ARCH}"
  [ -x "$src/tailscaled" ] && [ -x "$src/tailscale" ] || die "上游包内缺少 tailscaled/tailscale"
  cp "$src/tailscaled" "$APP/bin/tailscaled"
  cp "$src/tailscale"  "$APP/bin/tailscale"
  chmod 0755 "$APP/bin/tailscaled" "$APP/bin/tailscale"

  # ---- config.ini ----
  log "  + config.ini（External Open / path=/tailscale/）"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      -e "s|@@PUBLISHER@@|$PUBLISHER|g" \
      -e "s|@@PLATFORM@@|$TOS_PLATFORM|g" \
      -e "s|@@GITHUB_REPO@@|$GITHUB_REPO|g" \
      "$ASSETS_DIR/config.ini.in" > "$APP/config.ini"

  # ---- 语言文件 ----
  log "  + $APP_ID.lang（23 语超集）"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" "$ASSETS_DIR/$APP_ID.lang" > "$APP/$APP_ID.lang"

  # ---- 图标 ----
  cp "$ASSETS_DIR/images/icons/$APP_ID.svg" "$APP/images/icons/$APP_ID.svg"

  # ---- systemd 单元（init.d 只放主单元，辅助单元只落 /etc/systemd/system，坑 11）----
  log "  + init.d/$APP_ID.service + /etc/systemd/system/（主 + web 双单元）"
  cp "$ASSETS_DIR/init.d/$APP_ID.service" "$APP/init.d/$APP_ID.service"
  cp "$ASSETS_DIR/init.d/$APP_ID.service" "$STAGE_DIR/etc/systemd/system/$APP_ID.service"
  cp "$ASSETS_DIR/init.d/$APP_ID-web.service" "$STAGE_DIR/etc/systemd/system/$APP_ID-web.service"

  # ---- nginx（双落盘）----
  cp "$ASSETS_DIR/nginx/$APP_ID.conf" "$APP/nginx/$APP_ID.conf"
  cp "$ASSETS_DIR/nginx/$APP_ID.conf" "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf"

  # ---- tmpfiles / polkit ----
  cp "$ASSETS_DIR/tmpfiles/$APP_ID.conf" "$STAGE_DIR/etc/tmpfiles.d/$APP_ID.conf"
  cp "$ASSETS_DIR/polkit/49-tailscale-resolved.rules" "$STAGE_DIR/etc/polkit-1/rules.d/49-tailscale-resolved.rules"

  # ---- webui.bz2（入口页；解压后必须是可打开的 .html）----
  log "  + webui.bz2（入口页）"
  rm -rf "$WEBUI_DIR"; mkdir -p "$WEBUI_DIR"
  cp "$ASSETS_DIR/webui/index.html" "$WEBUI_DIR/index.html"
  chmod 0644 "$WEBUI_DIR/index.html"   # 构建机 umask 可能把 600 打进 webui.bz2
  export COPYFILE_DISABLE=1
  find "$WEBUI_DIR" -name '._*' -delete 2>/dev/null || true
  python3 - "$WEBUI_DIR" "$APP/webui.bz2" <<'PYW'
import sys, tarfile
from pathlib import Path
src_dir, out = sys.argv[1], sys.argv[2]
with tarfile.open(out, "w:bz2") as tf:
    for p in sorted(Path(src_dir).iterdir()):
        ti = tf.gettarinfo(str(p), arcname=p.name)
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = "root"
        ti.mtime = 0
        if ti.isfile():
            with open(p, "rb") as f:
                tf.addfile(ti, f)
        else:
            tf.addfile(ti)
PYW

  # ---- 配置模板 / 隐私政策 / 溯源 ----
  cp "$ASSETS_DIR/$APP_ID.env.example" "$APP/$APP_ID.env.example"
  cp "$ASSETS_DIR/privacy-policy.html" "$APP/privacy-policy.html"
  cp "$ASSETS_DIR/PROVENANCE.md" "$APP/PROVENANCE.md"

  # ---- doc 白名单（copyright / changelog 才会幸存）----
  cp "$DL_DIR/LICENSE" "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"
  {
    echo "$APP_ID ($VERSION_FULL) TOS7; urgency=medium"
    echo ""
    echo "  * 基于上游 Tailscale $TS_VERSION（$UPSTREAM_LICENSE）重打包，二进制逐字节一致"
    echo "  * 专用非 root 用户 + CAP_NET_ADMIN/CAP_NET_RAW；不配置 Restart（平台托管生命周期）"
    echo "  * 控制台经平台 nginx 反代至 /tailscale/，仅监听回环 8088"
    echo "  * 自动创建 TOS 缺失的 /dev/net/tun；state 落 /var/lib/tailscale"
    echo ""
    echo " -- $MAINTAINER_FULL  $(date -R 2>/dev/null || date '+%a, %d %b %Y %H:%M:%S %z')"
  } > "$STAGE_DIR/usr/share/doc/$APP_ID/changelog.Debian"

  # ---- 文本清洗 + 权限规范化 ----
  python3 - "$APP/config.ini" "$APP/$APP_ID.lang" "$APP/nginx/$APP_ID.conf" \
            "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf" \
            "$STAGE_DIR/etc/systemd/system/$APP_ID.service" \
            "$STAGE_DIR/etc/systemd/system/$APP_ID-web.service" \
            "$STAGE_DIR/etc/tmpfiles.d/$APP_ID.conf" \
            "$STAGE_DIR/etc/polkit-1/rules.d/49-tailscale-resolved.rules" \
            "$APP/$APP_ID.env.example" "$APP/privacy-policy.html" "$APP/PROVENANCE.md" <<'PYT'
import sys
for p in sys.argv[1:]:
    with open(p, 'rb') as f: d = f.read()
    if d.startswith(b'\xef\xbb\xbf'): d = d[3:]
    d = d.replace(b'\r\n', b'\n').replace(b'\r', b'\n')
    with open(p, 'wb') as f: f.write(d)
PYT

  find "$STAGE_DIR" \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null || true
  find "$STAGE_DIR" -type d -exec chmod 0755 {} +
  find "$STAGE_DIR" -type f -exec chmod 0644 {} +
  chmod 0755 "$APP/bin/tailscaled" "$APP/bin/tailscale"
  log "组装完成: $STAGE_DIR"
}

# ============================================================
# verify
# ============================================================
stage_verify() {
  local APP="$STAGE_DIR/usr/local/$APP_ID"
  [ -d "$APP" ] || die "尚未组装，先运行: ./build.sh stage"
  local fail=0
  ok()  { log "  ✓ $*"; }
  bad() { printf '\033[1;31m  ✗ %s\033[0m\n' "$*"; fail=$((fail+1)); }
  chk() { # chk <说明> <命令...>
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
  }

  log "校验 config.ini（官方自测同口径）"
  if python3 - "$APP/config.ini" "$TOS_PLATFORM" "$VERSION_FULL" <<'PYC'
import json, sys
p, platform, version = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(p))
errs = []
if d.get("id") != "tailscale": errs.append("id != tailscale")
if d.get("platform") != platform: errs.append("platform != " + platform)
if d.get("version") != version: errs.append("version != " + version)
if d.get("path") != "/tailscale/": errs.append("path 必须是 /tailscale/（C21）")
if d.get("open_path") is not True: errs.append("open_path 必须 true（C23）")
if "type" in d: errs.append("open_path 与 type 互斥（不得出现 type）")
if d.get("exec") is not True: errs.append("exec 必须 true（C33）")
if d.get("application_type") != "deb": errs.append("application_type != deb")
for k in ("system_id", "package", "user"):
    if d.get(k) != "tailscale": errs.append(k + " != tailscale")
if d.get("publisher") != "Moechz": errs.append("publisher 必须是 Moechz")
if d.get("category") != ["Utilities"]: errs.append("category 非法")
if d.get("icon") != "/images/icons/tailscale.svg": errs.append("icon 路径非法")
if errs:
    print("    " + "; ".join(errs)); sys.exit(1)
PYC
  then ok "config.ini 字段/互斥/版本/平台"; else bad "config.ini 字段/互斥/版本/平台"; fi

  log "校验语言文件（23 语，六字段齐全）"
  if python3 - "$APP/$APP_ID.lang" "$VERSION_FULL" <<'PYL'
import re, sys
p, version = sys.argv[1], sys.argv[2]
need = ["zh-cn","zh-hk","en-us","fr-fr","de-de","it-it","es-es","hu-hu","ja-jp","ko-kr",
        "pl-pl","ru-ru","tr-tr","pt-pt","ar-sa","cs-cz","he-il","id-id","nb-no","nl-nl",
        "sv-se","th-th","vi-vn"]
txt = open(p, encoding="utf-8").read()
blocks = re.split(r"^\[([a-z]{2}-[a-z]{2})\]\s*$", txt, flags=re.M)
sections = {}
for i in range(1, len(blocks), 2):
    sections[blocks[i]] = blocks[i + 1]
errs = [k for k in need if k not in sections]
for k, body in sections.items():
    for field in ("name", "auth", "descript"):
        m = re.search(r"^" + field + r'\s*=\s*"(.+)"\s*$', body, re.M)
        if not m or not m.group(1).strip():
            errs.append(k + " 缺 " + field)
    m = re.search(r'^version\s*=\s*"([^"]+)"\s*$', body, re.M)
    if not m or m.group(1) != version:
        errs.append(k + " version 不一致")
if errs:
    print("    " + "; ".join(errs[:8])); sys.exit(1)
PYL
  then ok "23 个语言节点齐全、字段齐全、版本一致"; else bad "语言文件不合规"; fi

  log "校验图标（SVG / viewBox / 尺寸占比 81-84% / 元素数）"
  if python3 - "$APP/images/icons/$APP_ID.svg" <<'PYS'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
errs = []
if not s.lstrip().startswith("<svg"): errs.append("不是 SVG")
if "viewBox" not in s: errs.append("缺 viewBox")
if "<image" in s: errs.append("含位图引用")
m = re.search(r'<svg[^>]*viewBox="([^"]+)"', s)
if m:
    vb = [float(x) for x in re.split(r"[ ,]+", m.group(1).strip())]
    r = re.search(r'<rect[^>]*x="([\d.]+)"[^>]*y="([\d.]+)"[^>]*width="([\d.]+)"', s)
    if r and len(vb) == 4:
        ratio = float(r.group(3)) / vb[2]
    else:
        g = re.search(r'<g[^>]*transform="translate\([\d. ]+\)\s*scale\(([\d.]+)\)"', s)
        if g and len(vb) == 4:
            ratio = float(g.group(1)) * 48.0 / vb[2]   # 上游 logo 自身画布 48
        else:
            ratio = None
    if ratio is None:
        errs.append("未找到背景 rect 或 transform 背景")
    elif not (0.81 <= ratio <= 0.84):
        errs.append("背景占比 %.3f 不在 0.81-0.84" % ratio)
n = len(re.findall(r"<(rect|circle|path|line|polygon|g)\b", s))
if n > 100: errs.append("元素数 %d 过多" % n)
if errs:
    print("    " + "; ".join(errs)); sys.exit(1)
PYS
  then ok "图标合规（占比/节点数/viewBox）"; else bad "图标不合规"; fi

  log "校验 systemd 单元"
  local U="$STAGE_DIR/etc/systemd/system/$APP_ID.service"
  local W="$STAGE_DIR/etc/systemd/system/$APP_ID-web.service"
  chk "主单元 User=tailscale"        grep -q '^User=tailscale$' "$U"
  if grep -q '^User=root$' "$U"; then bad "主单元不得 User=root"; else ok "主单元非 root"; fi
  chk "主单元 ExecStart 无变量展开"   grep -qE '^ExecStart=[^$]*$' "$U"
  if grep -qE '^Restart' "$U"; then bad "主单元不得配置 Restart"; else ok "主单元不配 Restart"; fi
  chk "主单元含 CAP_NET_ADMIN"       grep -q 'CAP_NET_ADMIN' "$U"
  chk "主单元 NoNewPrivileges"       grep -q '^NoNewPrivileges=true' "$U"
  chk "web 单元仅回环 8088"          grep -q '127.0.0.1:8088' "$W"
  if [ "$(ls "$APP/init.d" | wc -l)" -eq 1 ] && [ -f "$APP/init.d/$APP_ID.service" ]; then
    ok "init.d 只放主单元"
  else
    bad "init.d 只能放一个与 system_id 同名的单元（坑 11）"
  fi

  log "校验 nginx 路由"
  local N="$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf"
  chk "含 location"                  grep -q 'location' "$N"
  chk "反代到回环 8088"              grep -q 'proxy_pass http://127.0.0.1:8088/' "$N"
  chk "Host 头带端口"                grep -q 'proxy_set_header Host \$http_host' "$N"
  if grep -v '^[[:space:]]*#' "$N" | grep -qE 'server[[:space:]]*\{'; then bad "nginx conf.d 内不得出现 server{}"; else ok "无 server{} 包裹（坑 5）"; fi

  log "校验 webui.bz2"
  chk "webui.bz2 含 index.html"      tar tjf "$APP/webui.bz2"

  log "校验维护脚本"
  chk "无 DEBIAN/conffiles"          test ! -e "$STAGE_DIR/DEBIAN/conffiles"
  if grep -rqE '(apt-get|apt) install|dpkg -i|pip install|npm install' \
       "$ASSETS_DIR/preinst" "$ASSETS_DIR/postinst" "$ASSETS_DIR/prerm" "$ASSETS_DIR/postrm"; then
    bad "维护脚本含在线安装（S8）"
  else
    ok "维护脚本零在线安装（S8）"
  fi

  log "校验二进制架构"
  if python3 - "$APP/bin/tailscaled" "$TARGET_ARCH" <<'PYE'
import sys, struct
p, arch = sys.argv[1], sys.argv[2]
b = open(p, 'rb').read(20)
if b[:4] != b'\x7fELF':
    print("    不是 ELF"); sys.exit(1)
machine = struct.unpack('<H', b[18:20])[0]
want = 62 if arch == 'amd64' else 183
if machine != want:
    print("    ELF machine=%d 期望 %d" % (machine, want)); sys.exit(1)
PYE
  then ok "ELF 架构匹配 $TARGET_ARCH"; else bad "ELF 架构不匹配 $TARGET_ARCH"; fi

  if find "$STAGE_DIR" \( -name '._*' -o -name '.DS_Store' \) | grep -q .; then
    bad "含 AppleDouble/.DS_Store"
  else
    ok "无 AppleDouble/.DS_Store"
  fi

  if [ "$fail" -gt 0 ]; then die "verify 失败：$fail 项"; fi
  log "verify 全部通过"
}

# ============================================================
# deb
# ============================================================
stage_deb() {
  [ -d "$STAGE_DIR/usr/local/$APP_ID" ] || die "尚未组装，先运行: ./build.sh stage"
  mkdir -p "$OUT_DIR"
  log "打包 deb（$TARGET_ARCH）"
  "$SCRIPT_DIR/makedeb.sh" "$STAGE_DIR" "$ASSETS_DIR" "$DEB_FILE" "$VERSION_FULL" "$TARGET_ARCH" "$MAINTAINER_FULL"
  cp "$DEB_FILE" "$STORE_DEB"
  ( cd "$OUT_DIR" && sha256sum "$(basename "$STORE_DEB")" > "$(basename "$STORE_DEB").sha256" )
  log "产物:"
  ls -lh "$DEB_FILE" "$STORE_DEB" "$STORE_DEB.sha256" | sed 's/^/    /'
}

# ============================================================
# 入口
# ============================================================
stage_clean()     { rm -rf "$STAGE_DIR" "$WEBUI_DIR" "$BUILD_DIR/extract-$TARGET_ARCH"; log "已清理 stage"; }
stage_distclean() { rm -rf "$BUILD_DIR" "$OUT_DIR"; log "已清理构建缓存与产物"; }
stage_info() {
  echo "appid     : $APP_ID"
  echo "version   : $VERSION_FULL"
  echo "arch      : $TARGET_ARCH → $TOS_PLATFORM"
  echo "tgz       : $TGZ"
  echo "sha256    : $PINNED_SHA256"
  echo "web port  : 127.0.0.1:$WEB_PORT"
  echo "udp port  : $TS_UDP_PORT"
}

case "${1:-all}" in
  fetch)    stage_fetch ;;
  stage)    stage_stage ;;
  verify)   stage_verify ;;
  deb)      stage_deb ;;
  all)      stage_fetch; stage_stage; stage_verify; stage_deb ;;
  clean)    stage_clean ;;
  distclean) stage_distclean ;;
  info)     stage_info ;;
  *) echo "用法: $0 {all|fetch|stage|verify|deb|clean|distclean|info}" >&2; exit 2 ;;
esac
