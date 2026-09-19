#!/bin/bash
# build-fpk.sh - Wild Work fnOS FPK auto-build script
# 策略：以上游 rockswang/wild-work 编译产物为载荷，套用 template/ 里的
# 真机验证过的 fpk 骨架（cmd/main + wwbridge 桥接 + ui 多入口 + wizard）。
# fnpack 硬性要求（踩坑记录）：
#   1. ui 入口必须放 app/ui/ 下（app/ui/config 等），顶层 ui/ 无效
#   2. config/resource 必须是 JSON 对象 {name:{...}}，不能是数组
#   3. wizard/{install,upgrade,config} 必须是合法 JSON 数组
#   4. 包内需要 bin/wild-work + bin/wwbridge（网关 socket 桥接）
#   5. manifest checksum 由 fnpack 自动计算，不用手写

set -ex

VERSION=${1:-v2.2.2}
UPSTREAM_REF=${2:-master}
PKG_VERSION="${VERSION#v}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR=$(mktemp -d)

echo "=== Wild Work FPK Auto-Build ==="
echo "Version: $VERSION (manifest: $PKG_VERSION)"
echo "Upstream ref: $UPSTREAM_REF"
echo "Work dir: $WORK_DIR"

# 先建好组装目录（绝对路径常量，后面全程用它，不做 cd 往返）
BUILD_ROOT="$WORK_DIR/pkg"
TPL="$SCRIPT_DIR/template"
UPSTREAM="$WORK_DIR/upstream"

# ---------- 1. 克隆并编译上游 ----------
git clone --depth 1 --branch "$UPSTREAM_REF" https://github.com/rockswang/wild-work.git "$UPSTREAM" \
  || git clone --depth 1 https://github.com/rockswang/wild-work.git "$UPSTREAM"

ls -la "$UPSTREAM" | head -20

(cd "$UPSTREAM" && go mod download && go build -o wild-work -ldflags="-s -w" ./cmd/wild-work)

# 诊断 + 硬校验：二进制必须在预期位置
ls -la "$UPSTREAM/wild-work" || { echo "FATAL: binary not at $UPSTREAM/wild-work"; ls -la "$UPSTREAM"; exit 1; }
BINARY_SHA256=$(sha256sum "$UPSTREAM/wild-work" | cut -d' ' -f1)
echo "Binary SHA256: $BINARY_SHA256"

# ---------- 2. 组装 fpk 目录 ----------
mkdir -p "$BUILD_ROOT/app/bin" "$BUILD_ROOT/app/ui/images" \
         "$BUILD_ROOT/cmd" "$BUILD_ROOT/config" "$BUILD_ROOT/wizard"

# app/bin: 上游二进制 + 桥接二进制 + 启动配置
cp "$UPSTREAM/wild-work" "$BUILD_ROOT/app/bin/wild-work"
chmod +x "$BUILD_ROOT/app/bin/wild-work"
cp "$TPL/wwbridge" "$BUILD_ROOT/app/bin/wwbridge"
chmod +x "$BUILD_ROOT/app/bin/wwbridge"
cp "$TPL/bin-config.json" "$BUILD_ROOT/app/bin/config.json"

# app/ui: 入口配置 + 登录补投页 + 图标（fnpack 要求必须在 app/ui/ 下）
cp "$TPL/ui/config" "$BUILD_ROOT/app/ui/config"
cp "$TPL/ui/index.cgi" "$BUILD_ROOT/app/ui/index.cgi"
chmod +x "$BUILD_ROOT/app/ui/index.cgi"
if [ -f "$UPSTREAM/icon.png" ] && command -v convert &>/dev/null; then
    convert "$UPSTREAM/icon.png" -resize 64x64 "$BUILD_ROOT/app/ui/images/icon_64.png"
    convert "$UPSTREAM/icon.png" -resize 256x256 "$BUILD_ROOT/app/ui/images/icon_256.png"
else
    cp "$TPL/ui/images/icon_64.png" "$BUILD_ROOT/app/ui/images/"
    cp "$TPL/ui/images/icon_256.png" "$BUILD_ROOT/app/ui/images/"
fi

# cmd/: 生命周期脚本（照搬真机模板）
for f in main install_init install_callback upgrade_init upgrade_callback \
         uninstall_init uninstall_callback config_init config_callback; do
    cp "$TPL/cmd/$f" "$BUILD_ROOT/cmd/$f"
    chmod +x "$BUILD_ROOT/cmd/$f"
done

# config/: 权限与资源（resource 必须是对象！）
cp "$TPL/privilege" "$BUILD_ROOT/config/privilege"
cp "$TPL/resource" "$BUILD_ROOT/config/resource"

# wizard/: 安装/升级向导（必须是合法 JSON 数组）
for w in install upgrade config; do
    cp "$TPL/wizard/$w" "$BUILD_ROOT/wizard/$w"
done

# 顶层图标
cp "$TPL/ui/images/icon_64.png" "$BUILD_ROOT/ICON.PNG"
cp "$TPL/ui/images/icon_256.png" "$BUILD_ROOT/ICON_256.PNG"

# manifest: CRLF 换行（与原包一致；fnpack 会规范化）
M="$BUILD_ROOT/manifest"
printf 'appname               = wildwork\r\n' > "$M"
printf 'version               = %s\r\n' "$PKG_VERSION" >> "$M"
printf 'display_name          = Wild Work\r\n' >> "$M"
printf 'desc                  = wild-work 账号池代理（自封装版）。提供 OpenAI 兼容 API（/v1）与内置 Web 控制台，默认端口 7863。多渠道聚合，支持自动签到。状态数据保存在应用数据目录，登录凭据保存在应用配置目录。\r\n' >> "$M"
printf 'maintainer            = Mickey\r\n' >> "$M"
printf 'distributor           = Mickey\r\n' >> "$M"
printf 'source                = thirdparty\r\n' >> "$M"
printf 'platform              = x86\r\n' >> "$M"
printf 'ctl_stop              = true\r\n' >> "$M"
printf 'service_port          = 7863\r\n' >> "$M"
printf 'desktop_uidir         = ui\r\n' >> "$M"
printf 'desktop_applaunchname = wildwork.main\r\n' >> "$M"
printf 'changelog             = 自封装版：上游主程序升级到官方 %s（sha256 %s）。\r\n' "$VERSION" "$BINARY_SHA256" >> "$M"

echo "--- BUILD_ROOT 内容 ---"
find "$BUILD_ROOT" -type f | sort

# ---------- 3. 打包 ----------
if ! command -v fnpack &> /dev/null; then
    wget -q https://static2.fnnas.com/fnpack/fnpack-1.2.1-linux-amd64 -O /tmp/fnpack
    chmod +x /tmp/fnpack
    export PATH="/tmp:$PATH"
fi

(cd "$BUILD_ROOT" && fnpack build -d .)

FPK_FILE="$WORK_DIR/wildwork-${PKG_VERSION}.fpk"
mv "$BUILD_ROOT/wildwork.fpk" "$FPK_FILE"

FPK_MD5=$(md5sum "$FPK_FILE" | cut -d' ' -f1)
FPK_SHA256=$(sha256sum "$FPK_FILE" | cut -d' ' -f1)

echo ""
echo "=== Build Complete ==="
echo "FPK file: $FPK_FILE"
echo "Size: $(ls -lh "$FPK_FILE" | awk '{print $5}')"
echo "MD5: $FPK_MD5"
echo "SHA256: $FPK_SHA256"
echo "Binary SHA256: $BINARY_SHA256"
echo ""
echo "Package contents:"
tar tzf "$FPK_FILE" | head -25

# 自洽校验：manifest checksum 应等于 md5(app.tgz)
INNER_MD5=$(tar xzf "$FPK_FILE" -O app.tgz | md5sum | cut -d' ' -f1)
echo ""
echo "Checksum self-check md5(app.tgz): $INNER_MD5"

# 供后续 workflow 步骤取用：复制到工作区稳定路径
if [ -n "$GITHUB_WORKSPACE" ]; then
    cp "$FPK_FILE" "$GITHUB_WORKSPACE/wildwork-${PKG_VERSION}.fpk"
    echo "Artifact staged: $GITHUB_WORKSPACE/wildwork-${PKG_VERSION}.fpk"
fi
cp "$FPK_FILE" /tmp/wildwork-latest.fpk 2>/dev/null || true
