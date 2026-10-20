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

# ★★ 手机适配补丁已退役（2026-10-18，实测判定）
#   上游 v2.9.0 已系统性重做移动端：style.css 里有 12 段 @media（700/640/779/679/719/899/479
#   + hover:none pointer:coarse），并针对顶栏、接口信息、账号卡片、费率表、运行统计、
#   用量流水、触控目标七类问题逐条注释了实测数据（和当年我们踩的是同一批坑）。
#   渠道按钮改用 `.pa-right { grid-template-columns: repeat(auto-fit, minmax(118px,1fr)) }`
#   自适应列数，比我们硬钉三列更合理。
#   CDP 三视口实测（官方原版 vs 我们带补丁版）：
#     393px  官方 2列/按钮高35 统一   |  补丁版 3列/按钮高 52+35 混排（文字换行，视觉参差）
#     480px  官方 3列                 |  补丁版 3列
#     600px  官方 4列（自适应）        |  补丁版 3列（退化，按钮被拉宽到 173px）
#     三个断点官方溢出均为 0 —— 当年打补丁的目标（docScrollW 714 > 393）上游已自行达标。
#   结论：这段补丁从「修复」变成了「带 !important 的排版倒退」，直接删除，
#   移动端交回上游维护（上游每次改版都会自带最新适配，我们不需要跟）。

# ★ 封装层补投引导 —— 已于 2026-10-20 退役，不要恢复：
#   上游 v2.9.3（R104）把「粘贴回调地址」做进**面板登录弹窗自身**：后端 POST /api/login/callback
#   + manualCallbackKind 五渠道白名单（CodeArts/LobsterAI/TraeWork/QwenWork/Gemini），前端按
#   /api/login/start 返回的 manual_callback 显隐 lcCallbackRow 粘贴框。它就地提交、不依赖 fnOS 会话、
#   还带端口一致性校验（粘上一次登录的地址会被 400 明确指出），全面优于封装层 ui/index.cgi 那页。
#   两套补投 UI 并存时用户不知道信哪个 —— 所以整段删除，登录兜底交回上游维护。
#   守护断言见下方「上游自带补投」段（既断言它在，也断言我们那套没被加回来）。

# ★ 登录跳转补丁（2026-10-18，对应「点登录没有任何反应」）：
#   上游 startLogin() 是 async，window.open 写在 `await api(...)` **之后** —— 此时已脱离
#   用户点击的同步执行栈，浏览器弹窗拦截器直接吞掉，用户看到的就是「点了不跳转」。
#   修复三处：
#     A. await 之前同步预开一个空白窗口，拿到句柄后再 location.replace 到授权页；
#     B. 登录浮层里常驻一条可点击的授权链接（手机端/被拦时的兜底）；
#     C. 刷新页面后若后端仍有 login_busy，恢复浮层并给出「取消」入口
#        （否则流程卡在内存里，用户既看不到浮层也点不到取消，只能干等 6 分钟超时）。
#   锚点策略（2026-10-18 修正）：**不再用固定字符串锚定 startLogin 开头**。
#   上游 2.9.1 在函数头与 try 之间插了注释块和 `if (channel === "officeace")` 分派，
#   固定锚点必然断，进而 FATAL 卡死自动跟随。改为按 AST 找函数体 → 在「取登录链接的
#   await 所在的 try」之前插入预开窗前置，函数内部替换按语义串匹配。
#   A 段（startLogin）打不上且上游也没原生修复 → FATAL 拒绝出包；
#   startOfficeAceWebLogin（2.9.1 新增的同类入口）打不上 → 只 WARN，不阻塞出包。
APPJS2="$UPSTREAM/cmd/wild-work/web/app.js"
if [ -f "$APPJS2" ]; then
    # set -e 下 python 非零会直接终止脚本，导致下面的诊断分支永远进不去，
    # 所以这里显式关闭 errexit 拿到退出码再判定。
    set +e
    python3 - "$APPJS2" <<'PYAPPJS'

import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'WW popup patch' in s:
    print('login popup patch: already present, skip')
    sys.exit(0)

PRELUDE = '''  // \u2605 WW popup patch\uff1awindow.open \u5fc5\u987b\u5728 await \u4e4b\u524d**\u540c\u6b65**\u8c03\u7528\u3002
  //   await \u4e4b\u540e\u8c03\u7528\u5df2\u8131\u79bb\u7528\u6237\u624b\u52bf\u6808\uff0c\u6d4f\u89c8\u5668\u5f39\u7a97\u62e6\u622a\u5668\u4f1a\u76f4\u63a5\u541e\u6389 \u2014\u2014
  //   \u73b0\u8c61\u5c31\u662f\u300c\u70b9\u4e86\u767b\u5f55\u6ca1\u6709\u4efb\u4f55\u53cd\u5e94\u300d\uff08\u6d6e\u5c42\u8d77\u6765\u4e86\uff0c\u4f46\u6ca1\u6709\u65b0\u6807\u7b7e\u9875\uff09\u3002
  let wwWin = null;
  let wwUsed = false; // \u9884\u5f00\u7684\u7a7a\u767d\u7a97\u662f\u5426\u5df2\u88ab\u7528\u4e8e\u8df3\u8f6c\uff08\u51b3\u5b9a\u6700\u540e\u8981\u4e0d\u8981\u6e05\u6389\uff09
  try { wwWin = window.open("", "_blank"); } catch (e) { wwWin = null; }
  const wwClosePre = () => { try { if (wwWin && !wwWin.closed) wwWin.close(); } catch (e) {} };
  const wwOpen = (u) => {
    if (wwWin && !wwWin.closed) {
      try { wwWin.location.replace(u); wwWin.opener = null; wwUsed = true; return true; } catch (e) {}
    }
    try { return !!window.open(u, "_blank"); } catch (e) { return false; }
  };
'''

def find_func_span(s, name):
    m = re.search(r'(?:async\s+)?function\s+' + re.escape(name) + r'\s*\([^)]*\)\s*\{', s)
    if not m:
        return None
    i = m.end() - 1
    depth = 0
    for j in range(i, min(len(s), i + 30000)):
        if s[j] == '{':
            depth += 1
        elif s[j] == '}':
            depth -= 1
            if depth == 0:
                return (i, j + 1)
    return None

def insert_prelude(body, call_marker):
    i_api = body.find(call_marker)
    if i_api < 0:
        return None, 'call marker not found'
    i_try = body.rfind('try {', 0, i_api)
    if i_try < 0:
        return None, 'try { not found before call'
    ls = body.rfind('\n', 0, i_try) + 1
    if body[ls:i_try].strip():
        return None, 'try { not at line start'
    return body[:ls] + PRELUDE + body[ls:], None

def patch_func(s, name, call_marker, extras):
    span = find_func_span(s, name)
    if not span:
        return s, 'function not found'
    a, b = span
    body = s[a:b]
    if 'wwWin' in body:
        return s, 'already patched'
    nb, err = insert_prelude(body, call_marker)
    if err:
        return s, err
    for old, new in extras:
        if old not in nb:
            return s, 'extra anchor not found: %r' % old[:70]
        nb = nb.replace(old, new)
    return s[:a] + nb + s[b:], None

TOAST_BLOCK = 'if (!wwOpen(url)) toast("\u6d4f\u89c8\u5668\u62e6\u622a\u4e86\u5f39\u7a97\uff0c\u8bf7\u70b9\u300c\u590d\u5236\u94fe\u63a5\u300d\u624b\u52a8\u6253\u5f00", 6000);'
BOX = ('    // \u2605 WW popup patch\uff1a\u6d6e\u5c42\u91cc\u7ed9\u51fa\u53ef\u70b9\u51fb\u94fe\u63a5\uff08\u624b\u673a\u7aef window.open \u5e38\u88ab\u62e6\uff0c\u8fd9\u662f\u6700\u7a33\u7684\u515c\u5e95\uff09\n'
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
       '      box.innerHTML = \'<a href="\' + String(u).replace(/"/g, "&quot;") + \'" target="_blank" rel="noopener" style="color:#2563eb;text-decoration:underline">\u82e5\u6ca1\u6709\u81ea\u52a8\u6253\u5f00\uff0c\u70b9\u6b64\u6253\u5f00\u6388\u6743\u9875</a>\';\n'
       '    })(url);')
startlogin_extras = [
    ('if (!url) { toast("\u65e0\u6cd5\u83b7\u53d6\u767b\u5f55\u94fe\u63a5"); return; }',
     'if (!url) { wwClosePre(); toast("\u65e0\u6cd5\u83b7\u53d6\u767b\u5f55\u94fe\u63a5"); return; }'),
    ('window.open(url, "_blank", "noopener,noreferrer");', TOAST_BLOCK),
    ('    $("loginOverlay").classList.remove("hidden");\n    $("btnCopyUrl").dataset.url = url;',
     '    if (!wwUsed) wwClosePre(); // \u6ca1\u7528\u5230\u9884\u5f00\u7a97\uff08\u540e\u7aef\u5df2\u81ea\u5df1\u5f00\u7a97 / \u8d70 CDP \u6355\u83b7\uff09\u5c31\u6e05\u6389\uff0c\u522b\u7559\u7a7a\u767d\u6807\u7b7e\u9875\n'
     '    $("loginOverlay").classList.remove("hidden");\n'
     '    $("btnCopyUrl").dataset.url = url;\n' + BOX),
]
s, err_a = patch_func(s, 'startLogin', 'const r = await api("api/login/start"', startlogin_extras)

if err_a == 'already patched':
    ok_a = True
elif err_a:
    native_fixed = False
    span = find_func_span(s, 'startLogin')
    if span:
        body = s[span[0]:span[1]]
        _w = body.find('await api(')
        _o = body.find('window.open(url')
        if _w > 0 and _o > 0 and _o < _w:
            native_fixed = True
    if native_fixed:
        print('login popup patch: \u4e0a\u6e38\u5df2\u539f\u751f\u4fee\u590d\u5f39\u7a97\u65f6\u5e8f\uff0cA \u6bb5\u6574\u4f53\u8df3\u8fc7\uff08\u4ec5\u4fdd\u7559\u6062\u590d\u6d6e\u5c42 C \u6bb5\uff09')
        s = s.rstrip() + '\n// ww-native-ok: \u4e0a\u6e38\u5df2\u539f\u751f\u4fee\u590d\u5f39\u7a97\u65f6\u5e8f\uff08window.open \u5728 await \u4e4b\u524d\uff09\n'
        ok_a = False
    else:
        print('FATAL: startLogin \u8865\u4e01\u951a\u70b9\u5931\u6548\u4e14\u4e0a\u6e38\u672a\u539f\u751f\u4fee\u590d \u2014\u2014 \u539f\u56e0\uff1a%s' % err_a)
        print('\u5f53\u524d startLogin \u5f00\u5934\uff1a')
        span = find_func_span(s, 'startLogin')
        print(s[span[0]:span[0] + 900] if span else '(\u627e\u4e0d\u5230 startLogin \u51fd\u6570)')
        sys.exit(2)
else:
    ok_a = True

oa_old = ('    const w = window.open(url, "_blank");\n'
          '    if (w) {\n'
          '      try { w.opener = null; } catch (e) { /* \u8de8\u57df\u65f6\u53ef\u80fd\u88ab\u62d2\uff0c\u5ffd\u7565 */ }\n'
          '    } else {\n'
          '      toast("\u6d4f\u89c8\u5668\u62e6\u622a\u4e86\u5f39\u7a97\uff0c\u8bf7\u70b9\u300c\u590d\u5236\u94fe\u63a5\u300d\u624b\u52a8\u6253\u5f00", 6000);\n'
          '    }')
oa_new = ('    if (!wwOpen(url)) {\n'
          '      toast("\u6d4f\u89c8\u5668\u62e6\u622a\u4e86\u5f39\u7a97\uff0c\u8bf7\u70b9\u300c\u590d\u5236\u94fe\u63a5\u300d\u624b\u52a8\u6253\u5f00", 6000);\n'
          '    }\n'
          '    if (!wwUsed) wwClosePre(); // \u7528\u7684\u662f\u5907\u7528\u7a97\uff0c\u628a\u9884\u5f00\u7684\u7a7a\u767d\u7a97\u6e05\u6389')
oa_extras = [
    ('if (!url) { toast("\u65e0\u6cd5\u83b7\u53d6\u767b\u5f55\u94fe\u63a5"); return; }',
     'if (!url) { wwClosePre(); toast("\u65e0\u6cd5\u83b7\u53d6\u767b\u5f55\u94fe\u63a5"); return; }'),
    (oa_old, oa_new),
]
s_oa, err_oa = patch_func(s, 'startOfficeAceWebLogin', 'const r = await api("api/login/officeace_auto"', oa_extras)
if err_oa and err_oa != 'already patched':
    print('WARN: startOfficeAceWebLogin \u672a\u6253\u8865\u4e01\uff08%s\uff09\u2014\u2014 \u4e0d\u963b\u585e\u51fa\u5305' % err_oa)
else:
    s = s_oa
    if err_oa != 'already patched':
        print('login popup patch: officeace \u5165\u53e3\u540c\u6b65\u9884\u5f00\u7a97\u5df2\u6253')

tail = '''
// \u2605 WW popup patch\uff1a\u8fdb\u5165\u9762\u677f\u65f6\u82e5\u540e\u7aef\u4ecd\u6709\u767b\u5f55\u6d41\u7a0b\u5728\u8dd1\uff08\u5178\u578b\u573a\u666f\uff1a\u5237\u65b0\u8fc7\u9875\u9762\uff09\uff0c
// \u628a\u6d6e\u5c42\u6062\u590d\u51fa\u6765\u5e76\u7ed9\u51fa\u53d6\u6d88\u5165\u53e3 \u2014\u2014 \u5426\u5219\u6d41\u7a0b\u9501\u5728\u5185\u5b58\u91cc\uff0c\u7528\u6237\u65e2\u770b\u4e0d\u5230\u6d6e\u5c42\u4e5f\u70b9\u4e0d\u5230\u53d6\u6d88\uff0c
// \u53ea\u80fd\u5e72\u7b49 app.pollLogin \u7684 5~6 \u5206\u949f\u8d85\u65f6\uff0c\u671f\u95f4\u70b9\u4efb\u4f55\u6e20\u9053\u90fd\u4f1a\u88ab\u300c\u5df2\u6709\u767b\u5f55\u6d41\u7a0b\u8fdb\u884c\u4e2d\u300d\u62d2\u7edd\u3002
setTimeout(function () {
  try {
    if (!state || !state.login_busy) return;
    if (typeof loginPoll !== "undefined" && loginPoll) return;
    if (document.getElementById("wwResumeLogin")) return;
    const ov = document.getElementById("loginOverlay");
    if (!ov) return;
    const msg = document.getElementById("loginMsg");
    const title = document.getElementById("loginTitle");
    if (title) title.textContent = "\u767b\u5f55\u8fdb\u884c\u4e2d";
    if (msg) {
      msg.innerHTML = "\u4e0a\u4e00\u6b21\u767b\u5f55\u6d41\u7a0b\u8fd8\u6ca1\u7ed3\u675f\uff08\u53ef\u80fd\u662f\u5237\u65b0\u9875\u9762\u5bfc\u81f4\u7684\uff09\u3002"
        + "\u82e5\u5df2\u653e\u5f03\uff0c\u8bf7\u70b9\u300c\u53d6\u6d88\u300d\u91ca\u653e\uff1b\u5426\u5219\u7ee7\u7eed\u5728\u6d4f\u89c8\u5668\u91cc\u5b8c\u6210\u6388\u6743\u3002"
        + '<div id="wwResumeLogin" style="margin-top:10px">'
        + '<a href="#" onclick="cancelLogin();return false;" style="color:#b91c1c">\u91ca\u653e\u8fd9\u6b21\u767b\u5f55\u6d41\u7a0b</a></div>';
    }
    ov.classList.remove("hidden");
  } catch (e) { /* \u9759\u9ed8\uff1a\u8fd9\u662f\u8f85\u52a9\u63d0\u793a\uff0c\u7edd\u4e0d\u80fd\u5f71\u54cd\u9762\u677f\u4e3b\u6d41\u7a0b */ }
}, 1500);
'''
if 'WW popup patch\uff1a\u8fdb\u5165\u9762\u677f\u65f6' not in s:
    s = s.rstrip() + '\n' + tail
    ok_c = True
else:
    ok_c = False

open(p, 'w', encoding='utf-8').write(s)
print('login popup patch: A=%s C=%s' % (ok_a, ok_c))
PYAPPJS
    appjs_rc=$?
    set -e
    if [ "$appjs_rc" -ne 0 ]; then
        # python 段自己已经打印了 FATAL 原因与当前 startLogin 的样貌
        echo "FATAL: 登录跳转补丁无法落地（exit=$appjs_rc）。上游重构了前端登录流程，"
        echo "       需人工检查 build-fpk.sh 里登录补丁的匹配串（startLogin 内语义锚点）后再出包。"
        echo "       本次**不会**发出缺功能的包。"
        exit 1
    fi
    # 二次保险：A 段若打了，必须真的带出 wwUsed（预开窗逻辑），
    # 不能用宽泛的 'WW popup patch'（C 段尾部也含该串，会造成"打了一半也算过"）。
    if grep -qF 'WW popup patch' "$APPJS2" && ! grep -qF 'ww-native-ok' "$APPJS2"; then
        grep -qF 'wwUsed' "$APPJS2" || {
            echo "FATAL: A 段补丁只落了一半（有标记但缺 wwUsed），拒绝出包"; exit 1; }
        grep -qF 'wwAuthLinkBox' "$APPJS2" || {
            echo "FATAL: A 段补丁缺兜底链接（wwAuthLinkBox），拒绝出包"; exit 1; }
    fi
    grep -qF 'wwResumeLogin' "$APPJS2" || { echo "FATAL: C 段补丁（恢复登录浮层）缺失，拒绝出包"; exit 1; }
    echo "login popup patch: markers=$(grep -c 'WW popup patch' "$APPJS2" | head -1)"
else
    echo "WARN: 上游没有 $APPJS2，跳过登录跳转补丁"
fi

# ★ Gemini OAuth scope 收敛补丁（2026-10-18，修「错误 403：restricted_client」）：
#   上游 Scopes 抄了 6 项（openid / cloud-platform / userinfo.email / userinfo.profile /
#   cclog / experimentsandconfigs），但**这两枚凭据来自 Google 官方 Gemini CLI 的公开
#   client_id**，Google 只为它注册了 3 项。多要的 `cclog`（Cloud Code 内部日志通道）和
#   `experimentsandconfigs` 属受限 scope，授权页直接回：
#       错误 403：restricted_client
#       Unregistered scope(s) in the request: https://www.googleapis.com/auth/cclog
#   实测依据（本机解包 @google/gemini-cli-core@0.64.0 的 dist/src/code_assist/oauth2.js:55）：
#       const OAUTH_SCOPE = ['…/auth/cloud-platform', '…/auth/userinfo.email', '…/auth/userinfo.profile'];
#   ⇒ 官方 CLI 只用 3 项就能跑通全部功能，故这里把 Scopes 收敛到官方这 3 项。
#   补丁锚点失效（上游重写了常量）时 WARN 不失败，由 compat-audit 的产物断言兜底。
GEMCONST="$UPSTREAM/internal/gemini/constants.go"
if [ -f "$GEMCONST" ]; then
    python3 - "$GEMCONST" <<'PYGEM'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'ww-scope-patch' in s:
    print('gemini scope patch: already present, skip'); sys.exit(0)
# 匹配 var Scopes = []string{ ... } 整块
m = re.search(r'var Scopes = \[\]string\{(.*?)\n\}', s, re.S)
if not m:
    print('WARN: 未找到 var Scopes 定义，跳过 Gemini scope 收敛（Gemini 授权会 403）')
    sys.exit(0)
new = ('var Scopes = []string{\n'
       '\t// ww-scope-patch (2026-10-18): 仅保留 Google 官方 Gemini CLI 注册的 3 项。\n'
       '\t// 上游原本多要 cclog / experimentsandconfigs / openid，而本 client_id 未注册\n'
       '\t// 前两者 ⇒ 授权页 403 restricted_client。官方 CLI 用这 3 项即可完整工作。\n'
       '\tScopeCloudPlatform,\n'
       '\tScopeUserInfoEmail,\n'
       '\tScopeUserInfoProfile,\n'
       '}')
s2 = s[:m.start()] + new + s[m.end():]
open(p, 'w', encoding='utf-8').write(s2)
print('gemini scope patch: 已收敛为 3 项（去 cclog / experimentsandconfigs / openid）')
PYGEM
    if ! grep -q 'ww-scope-patch' "$GEMCONST"; then
        echo "::warning::Gemini scope 补丁未落地 —— 该渠道授权会 403 restricted_client"
    fi
else
    echo "WARN: 上游没有 internal/gemini/constants.go，跳过 Gemini scope 收敛"
fi

# ★ 确定性构建（2026-10-18）：两个二进制都必须带 -trimpath -buildvcs=false。
#   起因：同输入连续两次构建（2.9.0-8 vs 2.9.0-9）二进制 sha256 不一致，实测取证——
#   · wild-work 缺 -trimpath ⇒ 把构建机路径（/home/runner/go/pkg/mod/...）与
#     每次随机的工作目录（/tmp/tmp.XXXX/upstream/...）编进了二进制，必然每次不同；
#   · 两者都缺 -buildvcs=false ⇒ go build 会把当前 git 的 commit/dirty 状态嵌进去，
#     提交与否、工作区脏不脏都会改变产物。
#   后果：无法证明「Release 上的包 == 某次构建产物」，回滚/复现都失去依据。
#   修完判据：同输入连打两次，wild-work 与 wwbridge 的 sha256 必须逐字节一致。
(cd "$UPSTREAM" && go mod download && go build -trimpath -buildvcs=false -o wild-work -ldflags="-s -w" ./cmd/wild-work)

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
(cd "$SCRIPT_DIR/bridge" && CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags="-s -w" -o "$BUILD_ROOT/app/bin/wwbridge" .) \
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

# app/ui: 入口配置 + 图标（fnpack 要求必须在 app/ui/ 下）
# ⚠️ 不再拷贝 index.cgi：封装层补投页已于 2026-10-20 退役（上游自带粘贴兜底，见上方说明）。
cp "$TPL/ui/config" "$BUILD_ROOT/app/ui/config"

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
# ⚠️ -define png:exclude-chunk=time 不能省：ImageMagick 默认往 PNG 写 tIME（生成时刻），
#    于是同一源码两次构建的图标字节必然不同 —— 实测两个包像素数据（IDAT）完全一致，
#    只有 tIME 差 25 分钟，却导致 manifest checksum 与整包 sha256 都变。
#    后果：CI artifact 与 Release 附件对不上，更新器会把本地同版本包判成「内容与 Release 不一致」。
#    用 exclude-chunk 而不是 -strip：只去掉时间戳，保留 cHRM/pHYs 等色彩信息。
convert "$UPSTREAM_ICON" -resize 64x64 -define png:exclude-chunk=time "$BUILD_ROOT/app/ui/images/icon_64.png"
convert "$UPSTREAM_ICON" -resize 256x256 -define png:exclude-chunk=time "$BUILD_ROOT/app/ui/images/icon_256.png"

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
printf 'changelog             = 自封装版：上游主程序升级到官方 %s（sha256 %s）；fnOS 封装版本 %s。登录回调补投改由面板登录弹窗内置的「粘贴回调地址」框承担（v2.9.3 起上游自带），独立的「登录补投」页与桌面图标已移除。\r\n' "$UPSTREAM_REF" "$BINARY_SHA256" "$PKG_VERSION" >> "$M"

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

# ---------- 5b. 适配性审计（构建期硬门禁）----------
# 前面两步证明的是「能启动、补丁都在」；这里补上「装上之后好用」那一层：
# 向导文案是否还在介绍已删入口、启动脚本有没有日志轮转、图标/权限/入口字段
# 是否合 fnOS 规范、前端 API 是否已改成相对路径…… 任何一条 FAIL 都不发布。
# （脚本可独立在部署后复跑：bash scripts/compat-audit.sh <解包目录>）
bash "$SCRIPT_DIR/scripts/compat-audit.sh" "$CHECK_DIR"

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
# ⚠️ 不要再断言 "wildwork mobile patch"：该补丁已于 2026-10-18 退役（上游自带 12 段断点适配，
#    实测 393/480/600 三档均 0 溢出且布局更优）。若哪天有人把它加回来，这里也不该再护着。
# 补投能力：判据从「我们的补投页」改成「守护上游自带的粘贴兜底」（v2.9.3 R104）。
# 标记取前端 DOM id lcCallbackRow —— app.js 与 index.html 都随 go:embed 打进二进制，
# 上游一旦重构掉这条链路，用户就回到「浏览器停在 127.0.0.1 打不开、面板干等超时」的死局，
# 那必须人工介入，所以是硬门禁而非 WARN。
if grep -qF "lcCallbackRow" "$WWBIN"; then
    echo "  ok [ 上游自带补投（lcCallbackRow 粘贴回调地址）]"
else
    echo "FATAL: 上游自带补投丢失（二进制里找不到 lcCallbackRow）—— 上游重构了登录弹窗，需人工确认"
    exit 1
fi
# 反向守护：封装层补投页已退役，谁把两套补投 UI 加回来就让构建失败。
assert_absent "$WWBIN" "ww-replay-tip" "封装补投引导已退役"
if [ -e "$CHECK_DIR/ui/index.cgi" ]; then
    echo "FATAL: 封装补投页 ui/index.cgi 又出现在包里（已于 2026-10-20 退役）"
    exit 1
fi
echo "  ok [ 封装补投页未打入包 ]"
assert_absent "$CHECK_DIR/ui/config" "wildwork.submit" "补投页桌面入口已移除"
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
        kind="本机监听（OAuth 回调走面板内粘贴兜底；引导页类需 NAS 本机浏览器）"; CH_N_LOOPBACK=$((CH_N_LOOPBACK+1))
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
        echo "> 本机回调类渠道在 NAS 部署下经**面板登录弹窗内的「粘贴回调地址」**兜底转交"
        echo "> （上游 manualCallbackKind 白名单，v2.9.3 起自带；封装层补投页已退役）。导入型渠道（MonkeyCode / OfficeAce 等）"
        echo "> 没有 \`internal/login_*\` 目录，不在上表内。"
    } >> "$GITHUB_STEP_SUMMARY"
fi


# 供后续 workflow 步骤取用：复制到工作区稳定路径
if [ -n "$GITHUB_WORKSPACE" ]; then
    cp "$FPK_FILE" "$GITHUB_WORKSPACE/wildwork-${PKG_VERSION}.fpk"
    echo "Artifact staged: $GITHUB_WORKSPACE/wildwork-${PKG_VERSION}.fpk"
fi
cp "$FPK_FILE" /tmp/wildwork-latest.fpk 2>/dev/null || true
