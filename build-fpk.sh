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

# ★ 补投页引导补丁（2026-10-18）：
#   上游 2.6+ 陆续新增「本机回环回调」渠道（CodeArts /oauth/callback、Gemini /oauth-callback、
#   LobsterAI /auth/callback、千问 /callback）。wild-work 跑在 NAS 上、浏览器在用户设备上，
#   授权完成后浏览器必然跳到用户自己的 127.0.0.1:随机端口 并显示打不开，面板只能干等到超时。
#   封装层的 template/ui/index.cgi 负责把这条地址转交回 NAS（补投），但用户不知道有这一页。
#   这里在「等待登录」浮层里常驻一行说明 + 入口链接（锚点唯一，上游改版找不到就跳过）。
INDEXHTML="$UPSTREAM/cmd/wild-work/web/index.html"
if [ -f "$INDEXHTML" ]; then
    python3 - "$INDEXHTML" <<'PYPATCH'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'ww-replay-tip' in s:
    print('replay tip patch: already present, skip')
    sys.exit(0)
anchor = '      <div class="login-buttons">'
tip = ('      <div id="wwReplayTip" class="ww-replay-tip" style="margin-top:10px;font-size:12.5px;'
       'line-height:1.7;color:#92400e;background:#fffbeb;border:1px solid #fde68a;border-radius:8px;'
       'padding:8px 10px">登录后若浏览器跳到一条 <b>127.0.0.1</b> 地址并显示打不开，属正常'
       '（回调落在你自己的设备上）。把地址栏整条复制到 '
       '<a href="/cgi/ThirdParty/wildwork/index.cgi/" target="_blank" rel="noopener" '
       'style="color:#b45309;text-decoration:underline">登录补投</a> 页提交，NAS 端才会收到授权码。'
       'ZCode / MiniMax / Qoder 走服务端轮询，不需要补投。</div>\n')
if anchor in s:
    s = s.replace(anchor, tip + anchor, 1)
    open(p, 'w', encoding='utf-8').write(s)
    print('replay tip patch: injected')
else:
    print('WARN: 未找到 login-buttons 锚点，跳过补投提示注入（不影响功能）')
PYPATCH
else
    echo "WARN: 上游没有 $INDEXHTML，跳过补投提示注入"
fi

# ★ 登录跳转补丁（2026-10-18，对应「点登录没有任何反应」）：
#   上游 startLogin() 是 async，window.open 写在 `await api(...)` **之后** —— 此时已脱离
#   用户点击的同步执行栈，浏览器弹窗拦截器直接吞掉，用户看到的就是「点了不跳转」。
#   修复三处：
#     A. await 之前同步预开一个空白窗口，拿到句柄后再 location.replace 到授权页；
#     B. 登录浮层里常驻一条可点击的授权链接（手机端/被拦时的兜底）；
#     C. 刷新页面后若后端仍有 login_busy，恢复浮层并给出「取消」入口
#        （否则流程卡在内存里，用户既看不到浮层也点不到取消，只能干等 6 分钟超时）。
#   锚点找不到一律 WARN 不失败（上游重构不阻塞出包），落地与否在下面硬校验。
APPJS2="$UPSTREAM/cmd/wild-work/web/app.js"
if [ -f "$APPJS2" ]; then
    python3 - "$APPJS2" <<'PYAPPJS'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'WW popup patch' in s:
    print('login popup patch: already present, skip')
    sys.exit(0)

anchor_a = 'async function startLogin(channel, accountLabel) {\n  try {\n    const r = await api("/api/login/start"'
anchor_a = anchor_a.replace('/api/', 'api/')  # 子路径补丁已把 /api/ 改成 api/
prelude = '''async function startLogin(channel, accountLabel) {
  // ★ WW popup patch (2026-10-18)：window.open 必须在 await 之前**同步**调用。
  //   await 之后调用已脱离用户手势栈，浏览器弹窗拦截器会直接吞掉 ——
  //   现象就是「点了登录没有任何反应」（浮层起来了，但没有新标签页）。
  let wwWin = null;
  let wwUsed = false; // 预开的空白窗是否已被用于跳转（决定最后要不要清掉）
  try { wwWin = window.open("", "_blank"); } catch (e) { wwWin = null; }
  const wwClosePre = () => { try { if (wwWin && !wwWin.closed) wwWin.close(); } catch (e) {} };
  const wwOpen = (u) => {
    if (wwWin && !wwWin.closed) {
      try { wwWin.location.replace(u); wwWin.opener = null; wwUsed = true; return true; } catch (e) {}
    }
    try { return !!window.open(u, "_blank"); } catch (e) { return false; }
  };
  try {
    const r = await api("/api/login/start"'''
prelude = prelude.replace('/api/', 'api/')

ok_a = False
if anchor_a in s:
    s = s.replace(anchor_a, prelude, 1)
    ok_a = True
    # 不打开浏览器的分支要关掉预开的空白窗；要打开的分支改走 wwOpen
    s = s.replace(
        '    if (!url) { toast("无法获取登录链接"); return; }',
        '    if (!url) { wwClosePre(); toast("无法获取登录链接"); return; }', 1)
    s = s.replace(
        '      window.open(url, "_blank", "noopener,noreferrer");',
        '      if (!wwOpen(url)) toast("浏览器拦截了弹窗，请点「复制链接」手动打开", 6000);', 1)
    s = s.replace(
        '      $("loginMsg").textContent = "请在浏览器新窗口中完成登录…";\n      window.open(url, "_blank", "noopener,noreferrer");',
        '      $("loginMsg").textContent = "请在浏览器新窗口中完成登录…";\n'
        '      if (!wwOpen(url)) toast("浏览器拦截了弹窗，请点「复制链接」手动打开", 6000);', 1)
    # backend_opened / hasWebLogin / loomy 之外的分支：后端没开窗时清掉空白窗
    s = s.replace(
        '    $("loginOverlay").classList.remove("hidden");\n    $("btnCopyUrl").dataset.url = url;',
        '    if (!wwUsed) wwClosePre(); // 没用到预开窗（后端已自己开窗 / 走 CDP 捕获）就清掉，别留空白标签页\n'
        '    $("loginOverlay").classList.remove("hidden");\n'
        '    $("btnCopyUrl").dataset.url = url;\n'
        '    // ★ WW popup patch：浮层里给出可点击链接（手机端 window.open 常被拦，这是最稳的兜底）\n'
        '    (function (u) {\n'
        '      let box = document.getElementById("wwAuthLinkBox");\n'
        '      if (!box) {\n'
        '        const ov = $("loginOverlay");\n'
        '        const body = ov ? ov.querySelector(".modal-body") : null;\n'
        '        if (!body) return;\n'
        '        box = document.createElement("div");\n'
        '        box.id = "wwAuthLinkBox";\n'
        '        box.style.cssText = "margin-top:10px;font-size:13px;word-break:break-all";\n'
        '        body.appendChild(box);\n'
        '      }\n'
        '      box.innerHTML = \'<a href="\' + String(u).replace(/"/g, "&quot;") + \'" target="_blank" rel="noopener" style="color:#2563eb;text-decoration:underline">若没有自动打开，点此打开授权页</a>\';\n'
        '    })(url);', 1)
else:
    print('WARN: 未找到 startLogin 锚点，跳过登录跳转补丁 A')

# C：刷新页面后恢复登录浮层（否则卡在 login_busy 里无从取消）
tail = '''
// ★ WW popup patch：进入面板时若后端仍有登录流程在跑（典型场景：刷新过页面），
// 把浮层恢复出来并给出取消入口 —— 否则流程锁在内存里，用户既看不到浮层也点不到取消，
// 只能干等 app.pollLogin 的 5~6 分钟超时，期间点任何渠道都会被「已有登录流程进行中」拒绝。
setTimeout(function () {
  try {
    if (!state || !state.login_busy) return;
    if (typeof loginPoll !== "undefined" && loginPoll) return;
    if (document.getElementById("wwResumeLogin")) return;
    const ov = document.getElementById("loginOverlay");
    if (!ov) return;
    const msg = document.getElementById("loginMsg");
    const title = document.getElementById("loginTitle");
    if (title) title.textContent = "登录进行中";
    if (msg) {
      msg.innerHTML = "上一次登录流程还没结束（可能是刷新页面导致的）。"
        + "若已放弃，请点「取消」释放；否则继续在浏览器里完成授权。"
        + \'<div id="wwResumeLogin" style="margin-top:10px">\'
        + \'<a href="#" onclick="cancelLogin();return false;" style="color:#b91c1c">释放这次登录流程</a></div>\';
    }
    ov.classList.remove("hidden");
  } catch (e) { /* 静默：这是辅助提示，绝不能影响面板主流程 */ }
}, 1500);
'''
if 'WW popup patch：进入面板时' not in s:
    s = s.rstrip() + '\n' + tail
    ok_c = True
else:
    ok_c = False

open(p, 'w', encoding='utf-8').write(s)
print('login popup patch: A=%s C=%s' % (ok_a, ok_c))
PYAPPJS
    if ! grep -q 'WW popup patch' "$APPJS2"; then
        echo "FATAL: 登录跳转补丁未落地（上游 app.js 结构变了？），会重现「点登录没反应」"
        exit 1
    fi
    echo "login popup patch: markers=$(grep -c 'WW popup patch' "$APPJS2")"
else
    echo "WARN: 上游没有 $APPJS2，跳过登录跳转补丁"
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

# ★ Gemini 渠道凭据提取（2026-10-18）：
#   上游 <internal/gemini/oauthclient.go> 在运行时按「环境变量 → 本机官方 CLI 包」两级
#   查找 Google OAuth 客户端（client_id / client_secret）。这两个值是官方 CLI 内嵌的
#   **公开**凭据（任何装了 @google/gemini-cli-core 的人都能提取），但上游**刻意没有**写进
#   源码 —— 因为 GitHub Secret Scanning Push Protection 只看格式不看是否公开，会直接
#   拒绝推送（GH013）。而 NAS 上既没有环境变量也没有官方 CLI ⇒ 面板点「＋Gemini」
#   只会弹窗报「未获取到 Google OAuth 客户端凭据」。
#   解法：构建期从**公开 npm 包**动态提取，落进包内 bin/gemini-oauth.env（该文件不进 git），
#   由 template/cmd/main 启动时导入。跟随上游更新，无需人工维护任何硬编码值。
GEMINI_ENV_OUT="$BUILD_ROOT/app/bin/gemini-oauth.env"
: > "$GEMINI_ENV_OUT"
chmod 600 "$GEMINI_ENV_OUT" 2>/dev/null || true
if command -v npm >/dev/null 2>&1; then
    # ★★ 安全（2026-10-18 实测事故）：本脚本开头是 `set -ex`，xtrace 会把
    #   `gem_id=$(…)` / `[ -n "$gem_secret" ]` / `printf … "$gem_id"` 的**展开后参数**
    #   原样打进 CI 日志。公开仓库的 Actions 日志对所有人可见 —— 实测 2.9.0-4 的构建日志里
    #   就出现了 `+ '[' -n GOCSPX-… ']'` 这样的明文。这两枚虽是公开凭据，但绝不该出现在日志里
    #   （会触发 secret scanning 告警，也会让后续维护者误以为仓库泄密）。
    #   所以：从提取到写盘全程 set +x，只保留下面那句不含值的结论 echo。
    set +x
    GEM_TMP=$(mktemp -d)
    for gem_pkg in @google/gemini-cli-core @google/gemini-cli @google/antigravity; do
        ( cd "$GEM_TMP" && npm pack "$gem_pkg" --silent >/dev/null 2>&1 ) || continue
        gem_tgz=$(ls "$GEM_TMP"/*.tgz 2>/dev/null | head -1)
        [ -n "$gem_tgz" ] || continue
        rm -rf "$GEM_TMP/x"; mkdir -p "$GEM_TMP/x"
        tar xzf "$gem_tgz" -C "$GEM_TMP/x" 2>/dev/null || { rm -f "$gem_tgz"; continue; }
        gem_id=$(grep -rhoE '[0-9]{10,}-[a-z0-9]{20,}\.apps\.googleusercontent\.com' "$GEM_TMP/x" 2>/dev/null | head -1)
        gem_secret=$(grep -rhoE 'GOCSPX-[A-Za-z0-9_-]{20,}' "$GEM_TMP/x" 2>/dev/null | head -1)
        rm -f "$gem_tgz"
        if [ -n "$gem_id" ] && [ -n "$gem_secret" ]; then
            printf 'CMDC_PAK_GOOGLE_CLIENT_ID=%s\nCMDC_PAK_GOOGLE_CLIENT_SECRET=%s\n' \
                "$gem_id" "$gem_secret" > "$GEMINI_ENV_OUT"
            chmod 600 "$GEMINI_ENV_OUT" 2>/dev/null || true
            GEM_HIT="$gem_pkg"
            break
        fi
    done
    rm -rf "$GEM_TMP"
    set -x
    if [ -s "$GEMINI_ENV_OUT" ]; then
        echo "gemini oauth client: extracted from ${GEM_HIT:-?}"
    fi
else
    echo "::warning::无 npm，跳过 Gemini 凭据提取（该渠道会提示需自建 OAuth 客户端）"
fi
if [ -s "$GEMINI_ENV_OUT" ]; then
    # 只打印形态，不打印值（日志会进 CI 与制品说明）
    echo "gemini oauth client: packaged ($(grep -c . "$GEMINI_ENV_OUT") fields)"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "- Gemini OAuth 客户端凭据：已从公开 npm 包提取并随包分发" >> "$GITHUB_STEP_SUMMARY"
    fi
else
    echo "::warning::未提取到 Gemini 凭据 —— Gemini 渠道在该包里不可用（其余渠道不受影响）"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "- ⚠️ Gemini OAuth 客户端凭据：**提取失败**，该渠道在本包内不可用" >> "$GITHUB_STEP_SUMMARY"
    fi
fi

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

# ---------- 6. 封装层补丁「落地断言」----------
# 为什么必须从**产物**回读：本脚本所有补丁都是「拿字符串去匹配上游源码」，
# 上游改一行写法就可能静默失效。失效的后果不是构建失败，而是发出一个
# 「看起来正常、功能缺失」的包 —— 用户在 NAS 上点按钮才发现
# （补投页没有入口 / 点登录不跳转 / 手机上整页溢出）。这类问题在 CI 里
# 只表现为一行 WARN，很容易被忽略，所以这里升级成硬门禁。
#
# ★ 判据设计：补投引导允许「两处任一」（index.html 的常驻提示 / app.js 的浮层链接），
#   上游改其中一边不至于误伤；两边都没了才拦 —— 那说明登录浮层整体重构了，必须人工看。
assert_marker() { # $1=文件 $2=标记 $3=说明
    [ -f "$1" ] || { echo "FATAL: 补丁断言失败 [$3]：文件不存在 $1"; exit 1; }
    grep -qF "$2" "$1" || { echo "FATAL: 补丁断言失败 [$3]：$1 里找不到标记 '$2'"; exit 1; }
    echo "  ok [ $3 ]"
}
assert_absent() { # $1=文件 $2=标记 $3=说明
    [ -f "$1" ] || return 0
    if grep -qF "$2" "$1"; then
        echo "FATAL: 补丁断言失败 [$3]：$1 里仍有 '$2'"
        exit 1
    fi
    echo "  ok [ $3 ]"
}

echo "--- 封装层补丁落地断言 ---"
WWBIN="$CHECK_DIR/bin/wild-work"
assert_marker "$WWBIN" "WW popup patch"        "登录跳转补丁（同步预开窗）"
assert_marker "$WWBIN" "wwAuthLinkBox"         "浮层内可点授权链接"
assert_marker "$WWBIN" "wwResumeLogin"         "刷新后恢复登录浮层"
assert_marker "$WWBIN" "wildwork mobile patch" "手机端 CSS 覆盖"
# 补投引导：两处任一
if grep -qF "ww-replay-tip" "$WWBIN" || grep -qF "wwAuthLinkBox" "$WWBIN"; then
    echo "  ok [ 补投引导（常驻提示或浮层链接，至少一处）]"
else
    echo "FATAL: 补丁断言失败 [补投引导]：产物里既没有 ww-replay-tip 也没有 wwAuthLinkBox"
    exit 1
fi
assert_marker "$CHECK_DIR/ui/index.cgi" "is_safe_path"  "补投页结构性校验"
assert_marker "$CHECK_DIR/ui/index.cgi" "is_safe_query" "补投页查询串校验"
assert_absent "$CHECK_DIR/ui/config"    "wildwork.direct" "「直连」入口已移除"
assert_marker "$CHECK_DIR/cmd/main"     "gemini-oauth.env" "Gemini 凭据启动导入"

# ---------- 7. 上游渠道清单（跟随上游的「感知层」）----------
# 用户的核心诉求是「上游加了新渠道，封装层别掉队」。补投页改成结构性校验后，
# 本机回调类新渠道**不需要再改封装**；但还有两类情况需要人工知情：
#   · 需要本机浏览器/客户端才能完成登录的（NAS 上没有 → 该渠道在 NAS 部署下用不了）
#   · 需要额外资质的（如 Gemini 要 Google OAuth 客户端，已由本脚本自动内置）
# 这里按「登录形态」给本包里的渠道分档并写进 step summary：零维护、无需快照文件，
# 上游一变，下次构建的 summary 里自然体现。
# ⚠️ 判定只用于「提醒」，不做判决：`internal/login` 是基础包（不是渠道），必须排除；
#    Loomy 这类"本机引导页"与 OAuth 回调一样都在 127.0.0.1 监听，靠注释里出现
#    redirect_uri 这种信号是分不出来的 —— 所以本机监听型统一成一句话说明，不硬分类。
echo "--- 上游登录渠道清单（按登录形态分档）---"
CH_LIST=""
CH_N_LOOPBACK=0; CH_N_LOCALBROWSER=0; CH_N_SERVER=0
for d in "$UPSTREAM"/internal/login*/; do
    [ -d "$d" ] || continue
    ch=$(basename "$d"); ch=${ch#login_}
    [ -n "$ch" ] || continue
    [ "$ch" = "login" ] && continue   # internal/login 是 OAuth 基础包，不是渠道
    if grep -rqE 'net\.Listen\("tcp", *(fmt\.Sprintf\()?"127\.0\.0\.1' "$d" 2>/dev/null; then
        kind="本机监听（OAuth 回调走补投页；引导页类需 NAS 本机浏览器）"; CH_N_LOOPBACK=$((CH_N_LOOPBACK+1))
    elif grep -rqE 'internal/cdp|platform\.OpenURL|Incognito' "$d" 2>/dev/null; then
        kind="需本机浏览器/客户端（⚠️ NAS 部署下不可用）"; CH_N_LOCALBROWSER=$((CH_N_LOCALBROWSER+1))
    else
        kind="服务端轮询/设备码（跨设备可用）"; CH_N_SERVER=$((CH_N_SERVER+1))
    fi
    echo "  - $ch : $kind"
    CH_LIST="${CH_LIST}- \`$ch\` : $kind"$'\n'
done
CH_TOTAL=$((CH_N_LOOPBACK + CH_N_LOCALBROWSER + CH_N_SERVER))
echo "共 $CH_TOTAL 个登录渠道：本机监听 $CH_N_LOOPBACK / 需本机浏览器 $CH_N_LOCALBROWSER / 服务端 $CH_N_SERVER"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### 本包支持的登录渠道（自动扫描上游源码，零维护）"
        echo ""
        printf '%s' "$CH_LIST"
        echo ""
        echo "- 本机监听 $CH_N_LOOPBACK 个 / 需本机浏览器 $CH_N_LOCALBROWSER 个 / 服务端 $CH_N_SERVER 个"
        echo ""
        echo "> 本机回调类渠道在 NAS 部署下经「登录补投」页转交（补投页已做结构性校验，"
        echo "> 上游新增此类渠道**无需修改封装**）。导入型渠道（MonkeyCode / OfficeAce 等）"
        echo "> 没有 \`internal/login_*\` 目录，不在上表内。"
    } >> "$GITHUB_STEP_SUMMARY"
fi


# 供后续 workflow 步骤取用：复制到工作区稳定路径
if [ -n "$GITHUB_WORKSPACE" ]; then
    cp "$FPK_FILE" "$GITHUB_WORKSPACE/wildwork-${PKG_VERSION}.fpk"
    echo "Artifact staged: $GITHUB_WORKSPACE/wildwork-${PKG_VERSION}.fpk"
fi
cp "$FPK_FILE" /tmp/wildwork-latest.fpk 2>/dev/null || true
