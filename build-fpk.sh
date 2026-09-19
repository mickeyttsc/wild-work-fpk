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

set -e

VERSION=${1:-v2.2.2}
UPSTREAM_REF=${2:-master}
# 去掉 v 前缀作为 manifest version
PKG_VERSION="${VERSION#v}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR=$(mktemp -d)

echo "=== Wild Work FPK Auto-Build ==="
echo "Version: $VERSION (manifest: $PKG_VERSION)"
echo "Upstream ref: $UPSTREAM_REF"
echo "Work dir: $WORK_DIR"

# ---------- 1. 编译上游 ----------
git clone --depth 1 --branch "$UPSTREAM_REF" https://github.com/rockswang/wild-work.git upstream 2>/dev/null \
  || git clone --depth 1 https://github.com/rockswang/wild-work.git upstream
cd upstream

# 上游默认分支是 master；若指定 main 而 main 不存在则回退 master
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" = "HEAD" ]; then
    # detached，克隆的就是默认分支，继续
    echo "Using upstream default branch"
fi

go mod download
go build -o wild-work -ldflags="-s -w" ./cmd/wild-work

if [ ! -x wild-work ]; then
    echo "ERROR: Binary build failed"
    exit 1
fi
BINARY_SHA256=$(sha256sum wild-work | cut -d' ' -f1)
echo "Binary SHA256: $BINARY_SHA256"

# ---------- 2. 组装 fpk 目录 ----------
cd "$WORK_DIR"
BUILD_ROOT="$WORK_DIR/pkg"
mkdir -p "$BUILD_ROOT"
cd "$BUILD_ROOT"

TPL="$SCRIPT_DIR/template"

# app/bin: 上游二进制 + 桥接二进制 + 启动配置
mkdir -p app/bin
cp "$WORK_DIR/upstream/wild-work" app/bin/wild-work
chmod +x app/bin/wild-work
cp "$TPL/wwbridge" app/bin/wwbridge 2>/dev/null && chmod +x app/bin/wwbridge \
  || echo "WARNING: template/wwbridge missing - gateway bridge will not work"
cp "$TPL/bin-config.json" app/bin/config.json

# app/ui: 入口配置 + 登录补投页 + 图标（fnpack 要求必须在 app/ui/ 下）
mkdir -p app/ui/images
cp "$TPL/ui/config" app/ui/config
cp "$TPL/ui/index.cgi" app/ui/index.cgi
chmod +x app/ui/index.cgi
if [ -f "$WORK_DIR/upstream/icon.png" ] && command -v convert &>/dev/null; then
    convert "$WORK_DIR/upstream/icon.png" -resize 64x64 app/ui/images/icon_64.png
    convert "$WORK_DIR/upstream/icon.png" -resize 256x256 app/ui/images/icon_256.png
else
    cp "$TPL/ui/images/icon_64.png" app/ui/images/
    cp "$TPL/ui/images/icon_256.png" app/ui/images/
fi

# cmd/: 生命周期脚本（照搬真机模板）
mkdir -p cmd
for f in main install_init install_callback upgrade_init upgrade_callback \
         uninstall_init uninstall_callback config_init config_callback; do
    cp "$TPL/cmd/$f" cmd/
    chmod +x "cmd/$f"
done

# config/: 权限与资源（resource 必须是对象！）
mkdir -p config
cp "$TPL/privilege" config/privilege
cp "$TPL/resource" config/resource

# wizard/: 安装/升级向导（必须是合法 JSON 数组）
mkdir -p wizard
for w in install upgrade config; do
    cp "$TPL/wizard/$w" "wizard/$w"
done

# 顶层图标
cp "$TPL/ui/images/icon_64.png" ICON.PNG
cp "$TPL/ui/images/icon_256.png" ICON_256.PNG

# manifest: CRLF 换行（fnpack 会规范化，保持与原包一致）
printf 'appname               = wildwork\r\n' > manifest
printf 'version               = %s\r\n' "$PKG_VERSION" >> manifest
printf 'display_name          = Wild Work\r\n' >> manifest
printf 'desc                  = wild-work 账号池代理（自封装版）。提供 OpenAI 兼容 API（/v1）与内置 Web 控制台，默认端口 7863。多渠道聚合，支持自动签到。状态数据保存在应用数据目录，登录凭据保存在应用配置目录。\r\n' >> manifest
printf 'maintainer            = Mickey\r\n' >> manifest
printf 'distributor           = Mickey\r\n' >> manifest
printf 'source                = thirdparty\r\n' >> manifest
printf 'platform              = x86\r\n' >> manifest
printf 'ctl_stop              = true\r\n' >> manifest
printf 'service_port          = 7863\r\n' >> manifest
printf 'desktop_uidir         = ui\r\n' >> manifest
printf 'desktop_applaunchname = wildwork.main\r\n' >> manifest
printf 'changelog             = 自封装版：上游主程序升级到官方 %s（sha256 %s）。\r\n' "$VERSION" "$BINARY_SHA256" >> manifest
printf 'checksum              = placeholder\r\n' >> manifest

# ---------- 3. 打包 ----------
echo "Building FPK package..."
if ! command -v fnpack &> /dev/null; then
    wget -q https://static2.fnnas.com/fnpack/fnpack-1.2.1-linux-amd64 -O /tmp/fnpack
    chmod +x /tmp/fnpack
    export PATH="/tmp:$PATH"
fi

fnpack build -d .

FPK_FILE="wildwork-${PKG_VERSION}.fpk"
mv wildwork.fpk "$FPK_FILE"

FPK_MD5=$(md5sum "$FPK_FILE" | cut -d' ' -f1)
FPK_SHA256=$(sha256sum "$FPK_FILE" | cut -d' ' -f1)

echo ""
echo "=== Build Complete ==="
echo "FPK file: $WORK_DIR/$FPK_FILE"
echo "Size: $(ls -lh "$FPK_FILE" | awk '{print $5}')"
echo "MD5: $FPK_MD5"
echo "SHA256: $FPK_SHA256"
echo "Binary SHA256: $BINARY_SHA256"
echo ""
echo "Package contents:"
tar tzf "$FPK_FILE" | head -25

# 自洽校验：manifest checksum = md5(app.tgz)
INNER_MD5=$(tar xzf "$FPK_FILE" -O app.tgz | md5sum | cut -d' ' -f1)
echo ""
echo "Checksum self-check: manifest=$INNER_MD5 (should match md5(app.tgz))"

# 供后续步骤使用
mkdir -p "$SCRIPT_DIR/../../dist" 2>/dev/null || true
cp "$FPK_FILE" /tmp/wildwork-latest.fpk
echo "Artifact staged: /tmp/wildwork-latest.fpk"
