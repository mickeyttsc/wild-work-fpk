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

# 第一个参数是本仓库的打包版本（默认 v2.3.1-1），第二个参数是上游 ref。
# 打包版本带 -N，避免同一个上游版本修复封装后仍沿用原 version，导致
# fnOS 把它识别成“同版本”或直接跳过升级。
VERSION=${1-v2.3.1-1}
UPSTREAM_REF=${2-v2.3.1}
PKG_VERSION="${VERSION#v}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR=$(mktemp -d)

# ★ 版本号硬校验：不能为空、必须是 <数字.数字.数字>[-N] 形态。
#   踩过的坑：check-upstream.yml 重构后仍引用旧输出名（steps.upstream.outputs.package_version），
#   于是 dispatch 传进来 version="v" → PKG_VERSION 为空 → manifest 缺 version
#   → fnpack 报 "Required field version is missing in manifest file" 才失败。
#   在最早的位置拦住，比让 fnpack 在最后一步报错更容易定位。
if [[ ! "$PKG_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$ ]]; then
    echo "FATAL: 打包版本号非法：VERSION='$VERSION' → PKG_VERSION='$PKG_VERSION'"
    echo "       期望形如 v2.5.5-1（或 v2.5.5）。检查调用方传参是否解析成了空串。"
    exit 1
fi
if [ -z "$UPSTREAM_REF" ]; then
    echo "FATAL: UPSTREAM_REF 为空"
    exit 1
fi

echo "=== Wild Work FPK Auto-Build ==="
echo "Version: $VERSION (manifest: $PKG_VERSION)"
echo "Upstream ref: $UPSTREAM_REF"
echo "Work dir: $WORK_DIR"

# 先建好组装目录（绝对路径常量，后面全程用它，不做 cd 往返）
BUILD_ROOT="$WORK_DIR/pkg"
TPL="$SCRIPT_DIR/template"
UPSTREAM="$WORK_DIR/upstream"

# ---------- 1. 克隆并编译上游 ----------
# ★ 必须按 release tag 检出，不能用 master：
#   master 是开发分支，可能领先/落后于已发布的 release，编出来的二进制
#   与 release 产物不一致（哈希对不上、版本号可能带脏后缀）。
#   UPSTREAM_REF 由 check-upstream.yml 传入上游 release 的 tag（如 v2.3.1）。
git clone --depth 1 --branch "$UPSTREAM_REF" https://github.com/rockswang/wild-work.git "$UPSTREAM" \
  || { echo "FATAL: 无法按 ref '$UPSTREAM_REF' 克隆上游（tag 不存在？）"; exit 1; }
ls -la "$UPSTREAM" | head -20

# ★ 前端子路径补丁（fnOS 网关部署必需）：
#   2.6.x 面板把 API 硬编码成根相对 fetch("/api/...")。页面经网关挂在
#   /app/wildwork/ 时，这类请求打到 origin 根的 /api/* → 返回飞牛自己的
#   404 页，面板全断（直连 7863 不受影响）。改成文档基址相对路径
#   ("api/...") 后：网关子路径解析为 /app/wildwork/api/*，直连解析为
#   /api/*，两种部署都对。内容变化会让内嵌 FS 的 ETag 自然失效，
#   浏览器缓存自愈，无需清缓存。
#   上游若哪天原生支持子路径，这里匹配不到即为空操作，补丁自动退役。
APPJS="$UPSTREAM/cmd/wild-work/web/app.js"
if [ -f "$APPJS" ]; then
    # -F 定长匹配（引号+斜杠开头两种形式），避免 ERE/BRE 括号转义坑。
    before=$(( $(grep -c -F '"/api/' "$APPJS" || true) + $(grep -c -F '`/api/' "$APPJS" || true) ))
    sed -i 's|"/api/|"api/|g; s|`/api/|`api/|g' "$APPJS"
    after=$(( $(grep -c -F '"/api/' "$APPJS" || true) + $(grep -c -F '`/api/' "$APPJS" || true) ))
    echo "webui subpath patch: root-relative api paths ${before} -> ${after} (期望 after=0)"
    if [ "$before" -gt 0 ] && [ "$after" -ne 0 ]; then
        # 硬校验：打了补丁却没打干净 = 网关面板必 404，宁可不发布。
        echo "FATAL: app.js 仍有根相对 /api/ 残留（$after 处），sed 模式失效？检查上游前端写法变化"
        exit 1
    fi
    if [ "$before" -eq 0 ]; then
        echo "NOTE: 上游 app.js 没有根相对 /api/（可能已原生支持子路径），补丁空操作"
    fi
else
    echo "WARN: 上游没有 $APPJS（前端布局变了？），跳过子路径补丁——装完若网关面板 404 需人工核查"
fi

# ★ 手机适配补丁（2026-10-09，CDP 393px 仿真实测通过）：
#   上游已带 3 段 @media (max-width: 640px)，但渠道按钮组是固定 5 列 grid
#   （.pa-group.pa-right，实测 601px），顶栏双列信息格与 .credit-tip 固定宽
#   都没进断点 → 手机上整页横向溢出（docScrollW 714 > 393）。追加覆盖块：
#   按钮 3 列换行、信息格单列可断行、浮层自适应、表格横向滚动。
#   与 app.js 子路径补丁同机制：改的是上游源码树里的 style.css，go:embed
#   打进二进制，上游更新时自动跟随（若无此文件则空操作）。
STYLECSS="$UPSTREAM/cmd/wild-work/web/style.css"
if [ -f "$STYLECSS" ]; then
    if ! grep -q 'wildwork mobile patch' "$STYLECSS"; then
        cat >> "$STYLECSS" <<'MOBILECSS'

/* ==== wildwork mobile patch (2026-10-09) ==== */
@media (max-width: 640px) {
  .panel-actions-wrap { flex-wrap: wrap; row-gap: 8px; }
  .pa-group.pa-right { grid-template-columns: repeat(3, 1fr); width: 100%; }
  .pa-group.pa-right .btn { width: 100%; min-width: 0; }
  .top-info { grid-template-columns: 1fr; width: 100%; }
  .info-value { display: block; max-width: 100%; overflow-wrap: anywhere; word-break: break-all; white-space: normal; }
  .credit-tip { width: auto !important; max-width: calc(100vw - 20px); }
  .panel table { display: block; overflow-x: auto; -webkit-overflow-scrolling: touch; }
}

/* ==== wildwork mobile patch v2 (2026-10-09, CDP 393px 实测) ====
   v1 的 grid 三列覆盖被上游 ".pa-right .btn{justify-self:stretch;white-space:nowrap}"
   及既有 @media 规则顺序压住不生效；改用 flex 强覆盖：按钮三列等宽换行。 ==== */
@media (max-width: 640px) {
  .panel-actions-wrap { flex-wrap: wrap !important; row-gap: 8px; }
  .pa-group.pa-right { display: flex !important; flex-wrap: wrap !important; gap: 6px !important; width: 100% !important; }
  .pa-group.pa-right .btn { flex: 1 1 calc(33% - 6px) !important; width: auto !important; min-width: 0 !important;
    white-space: normal !important; font-size: 12px !important; padding: 8px 6px !important; text-align: center !important; }
}
MOBILECSS
        echo "mobile css patch: appended (@media 640px override v1+v2)"
    else
        echo "mobile css patch: already present, skip"
    fi
else
    echo "WARN: 上游没有 $STYLECSS（前端布局变了？），跳过手机适配补丁"
fi

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
# ★ wwbridge 从本仓 bridge/ 源码现编（v2 起）：修复上游 2.5.5+ CSRF 在
#   fnOS 网关链路（$host 丢端口 + HTTP 不发 Sec-Fetch-Site）误拦浏览器
#   POST 的问题。历史二进制 template/wwbridge 仅作故障回滚参照，不再打进包。
if ! command -v go >/dev/null 2>&1; then
    echo "FATAL: 缺少 go 工具链，无法编译 wwbridge（CI 的 setup-go 步必须在使用本脚本之前）"
    exit 1
fi
(cd "$SCRIPT_DIR/bridge" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$BUILD_ROOT/app/bin/wwbridge" .) \
  || { echo "FATAL: wwbridge 编译失败"; exit 1; }
[ -s "$BUILD_ROOT/app/bin/wwbridge" ] || { echo "FATAL: wwbridge 产物为空"; exit 1; }
chmod +x "$BUILD_ROOT/app/bin/wwbridge"
echo "wwbridge SHA256: $(sha256sum "$BUILD_ROOT/app/bin/wwbridge" | cut -d' ' -f1)"
cp "$TPL/bin-config.json" "$BUILD_ROOT/app/bin/config.json"

# app/ui: 入口配置 + 登录补投页 + 图标（fnpack 要求必须在 app/ui/ 下）
cp "$TPL/ui/config" "$BUILD_ROOT/app/ui/config"
cp "$TPL/ui/index.cgi" "$BUILD_ROOT/app/ui/index.cgi"
chmod +x "$BUILD_ROOT/app/ui/index.cgi"

# ★ 图标用上游官方图标（黑底 + 荧光绿笔刷 "W"），不要用 template 里的占位图。
#   上游 icon.png 与 build/appicon.png 内容完全相同（同为 858x858），指向
#   build/appicon.png 是为了不依赖顶层 icon.png 的检出结果。
#   注意：绝不能静默回退到 template 图标——那会让桌面显示蓝色的 "WWW" 占位图，
#   且失败被吞掉无从察觉。取不到就直接 FATAL。
UPSTREAM_ICON=""
for cand in "$UPSTREAM/build/appicon.png" "$UPSTREAM/icon.png"; do
    if [ -f "$cand" ]; then UPSTREAM_ICON="$cand"; break; fi
done
if [ -z "$UPSTREAM_ICON" ]; then
    echo "FATAL: 上游源码里找不到图标（试过 build/appicon.png 与 icon.png）"
    echo "--- $UPSTREAM 顶层内容 ---"; ls -la "$UPSTREAM"
    exit 1
fi
echo "Using upstream icon: $UPSTREAM_ICON ($(sha256sum "$UPSTREAM_ICON" | cut -d' ' -f1))"
if ! command -v convert &>/dev/null; then
    echo "FATAL: 缺少 ImageMagick 的 convert，无法生成 64/256 图标"
    exit 1
fi
convert "$UPSTREAM_ICON" -resize 64x64 "$BUILD_ROOT/app/ui/images/icon_64.png"
convert "$UPSTREAM_ICON" -resize 256x256 "$BUILD_ROOT/app/ui/images/icon_256.png"

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

# 顶层图标（app center / 桌面读的就是这两个）
# ★ 必须用上一步 generate 出来的图标，不能再从 template 拷——
#   template 是占位图，拷过来会让顶层图标与 app/ui/images 里的不一致。
cp "$BUILD_ROOT/app/ui/images/icon_64.png" "$BUILD_ROOT/ICON.PNG"
cp "$BUILD_ROOT/app/ui/images/icon_256.png" "$BUILD_ROOT/ICON_256.PNG"

# manifest: CRLF 换行（与原包一致；fnpack 会规范化）
M="$BUILD_ROOT/manifest"
printf 'appname               = wildwork\r\n' > "$M"
printf 'version               = %s\r\n' "$PKG_VERSION" >> "$M"
printf 'display_name          = Wild Work\r\n' >> "$M"
printf 'desc                  = wild-work 账号池代理（自封装版）。提供 OpenAI 兼容 API（/v1）与内置 Web 控制台，默认端口 7863。多渠道聚合，支持自动签到。状态数据保存在应用数据目录，登录凭据保存在应用配置目录。\r\n' >> "$M"
printf 'maintainer            = rockswang\r\n' >> "$M"
printf 'distributor           = Mickey\r\n' >> "$M"
printf 'source                = thirdparty\r\n' >> "$M"
printf 'platform              = x86\r\n' >> "$M"
printf 'ctl_stop              = true\r\n' >> "$M"
printf 'service_port          = 7863\r\n' >> "$M"
printf 'desktop_uidir         = ui\r\n' >> "$M"
printf 'desktop_applaunchname = wildwork.main\r\n' >> "$M"
printf 'changelog             = 自封装版：上游主程序升级到官方 %s（sha256 %s）；fnOS 封装版本 %s。\r\n' "$UPSTREAM_REF" "$BINARY_SHA256" "$PKG_VERSION" >> "$M"

echo "--- BUILD_ROOT 内容 ---"
find "$BUILD_ROOT" -type f | sort

# ---------- 3. 启动兼容门禁 ----------
# 不能只证明二进制能编译：用旧版两字段 config.json 实际启动本包，
# 防止“非环回监听新增必填配置”这类升级破坏再次发布出去。
bash "$SCRIPT_DIR/scripts/test-startup-compat.sh" "$BUILD_ROOT"

# ---------- 4. 打包 ----------
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

# ---------- 5. 打包后内容回验 ----------
CHECK_DIR="$WORK_DIR/verify"
mkdir -p "$CHECK_DIR"
tar xzf "$FPK_FILE" -C "$CHECK_DIR"
tar xzf "$CHECK_DIR/app.tgz" -C "$CHECK_DIR"
bash "$SCRIPT_DIR/scripts/test-startup-compat.sh" "$CHECK_DIR"

# 供后续 workflow 步骤取用：复制到工作区稳定路径
if [ -n "$GITHUB_WORKSPACE" ]; then
    cp "$FPK_FILE" "$GITHUB_WORKSPACE/wildwork-${PKG_VERSION}.fpk"
    echo "Artifact staged: $GITHUB_WORKSPACE/wildwork-${PKG_VERSION}.fpk"
fi
cp "$FPK_FILE" /tmp/wildwork-latest.fpk 2>/dev/null || true
