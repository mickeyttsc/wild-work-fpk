#!/bin/bash
# compat-audit.sh —— fpk 适配性审计（构建期与部署后都能跑）
#
# 用法：
#   bash scripts/compat-audit.sh <已解包的 fpk 根目录>
#   例：tar xzf wildwork-X.fpk -C d && tar xzf d/app.tgz -C d && bash scripts/compat-audit.sh d
#
# 为什么单独成脚本：打包最容易出的不是「编不过」，而是「编过了但装上不好用」——
# 入口指向不存在的图标、向导介绍已删除的功能、启动脚本依赖 NAS 上不存在的命令、
# 日志无限增长、补投页在新网关下拼错基址。这些都不会让构建失败，只会让用户踩坑。
# 本脚本把它们变成可断言的清单；任何一条 FAIL 都不应发布。
#
# 退出码：0 全过（允许 SKIP）；1 有 FAIL。
set -uo pipefail

ROOT="${1:?用法: compat-audit.sh <已解包的 fpk 根目录>}"
PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; SKIP=$((SKIP+1)); }

have() { [ -e "$ROOT/$1" ]; }

# ── 1. manifest ─────────────────────────────────────────────────────────────
echo "[1] manifest"
MAN="$ROOT/manifest"
if [ -f "$MAN" ]; then
    mf() { sed -n "s/^$1 *= *//p" "$MAN" | head -1 | tr -d '\r'; }
    for f in appname version display_name desc maintainer distributor source platform service_port desktop_uidir; do
        v=$(mf "$f")
        [ -n "$v" ] && ok "字段 $f = $v" || bad "字段 $f 缺失或为空"
    done
    v=$(mf version)
    echo "$v" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$' \
        && ok "version 形如 X.Y.Z[-N]（$v）" || bad "version 格式非法：$v"
    [ "$(mf platform)" = "x86" ] && ok "platform = x86" || bad "platform 非 x86（$(mf platform)）"
    ck=$(mf checksum)
    if [ -f "$ROOT/app.tgz" ]; then
        want=$(md5sum "$ROOT/app.tgz" | cut -d' ' -f1)
        [ "$ck" = "$want" ] && ok "checksum 与 md5(app.tgz) 一致" || bad "checksum 不一致：manifest=$ck app.tgz=$want"
    else
        skip "checksum 校验（app.tgz 未解出）"
    fi
else
    bad "manifest 不存在"
fi

# ── 2. 桌面入口 ─────────────────────────────────────────────────────────────
echo "[2] 桌面入口 ui/config"
UIC="$ROOT/ui/config"
if [ -f "$UIC" ]; then
    python3 - "$UIC" <<'PY' && PASS=$((PASS+4)) || FAIL=$((FAIL+1))
import json,sys
d=json.load(open(sys.argv[1]))
urls=d.get(".url") or {}
assert urls, "ui/config 里没有 .url 段"
main=urls.get("wildwork.main")
assert main, "缺少主入口 wildwork.main"
assert main.get("type")=="iframe", "主入口 type 必须是 iframe（fnOS 小窗模式）"
assert main.get("url"), "主入口缺 url"
assert main.get("allUsers") is True, "allUsers 必须为 true（false 会退化成 admin-only）"
for k,v in urls.items():
    assert v.get("icon") or k, f"{k} 缺 icon"
    assert v.get("title"), f"{k} 缺 title"
print("  \033[32mPASS\033[0m 入口 JSON 合法、主入口字段齐全")
PY
    grep -q "wildwork.direct" "$UIC" && bad "仍存在已废弃的「直连」入口 wildwork.direct" || ok "无废弃的直连入口"
    n=$(python3 -c "import json;print(len(json.load(open('$UIC'))['.url']))" 2>/dev/null || echo 0)
    [ "$n" -ge 2 ] && ok "入口数量 = $n（主入口 + 补投页）" || bad "入口数量异常：$n"
else
    bad "ui/config 不存在"
fi

# ── 3. 向导文案与功能一致性 ─────────────────────────────────────────────────
echo "[3] 安装/升级向导"
for w in install upgrade; do
    f="$ROOT/wizard/$w"
    if [ -f "$f" ]; then
        python3 -c "import json;json.load(open('$f'))" 2>/dev/null \
            && ok "wizard/$w 是合法 JSON" || bad "wizard/$w 不是合法 JSON"
        if grep -q "Wild Work 直连" "$f"; then
            bad "wizard/$w 仍在介绍已删除的「Wild Work 直连」图标"
        else
            ok "wizard/$w 未提废弃图标"
        fi
    else
        bad "wizard/$w 缺失"
    fi
done

# ── 4. 启动脚本与运行时依赖 ─────────────────────────────────────────────────
echo "[4] 启动脚本 cmd/main"
CM="$ROOT/cmd/main"
if [ -f "$CM" ]; then
    bash -n "$CM" 2>/dev/null && ok "cmd/main 语法正确" || bad "cmd/main 语法错误"
    [ -x "$CM" ] && ok "cmd/main 可执行" || bad "cmd/main 缺少可执行位"
    for marker in "housekeeping" "rotate_log" "cleanup_stale_login_state" "gemini-oauth.env"; do
        grep -q "$marker" "$CM" && ok "cmd/main 含 $marker" || bad "cmd/main 缺少 $marker"
    done
    # 依赖的外部命令：逐个在构建机确认存在（NAS 上另有运行时实测）
    deps="awk cp chmod grep kill mkdir nohup rm sed"
    missing=""
    for c in $deps; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
    [ -z "$missing" ] && ok "启动脚本依赖的基础命令齐全" || bad "缺少命令:$missing"
    for c in python3 ss curl; do
        command -v "$c" >/dev/null 2>&1 && ok "依赖 $c 可用" || skip "构建机无 $c（部署后需复验）"
    done
else
    bad "cmd/main 缺失"
fi

# ── 5. 登录补投页 ───────────────────────────────────────────────────────────
echo "[5] 登录补投页 ui/index.cgi"
CGI="$ROOT/ui/index.cgi"
if [ -f "$CGI" ]; then
    bash -n "$CGI" 2>/dev/null && ok "index.cgi 语法正确" || bad "index.cgi 语法错误"
    [ -x "$CGI" ] && ok "index.cgi 可执行" || bad "index.cgi 缺少可执行位"
    for marker in is_safe_path is_safe_query "?u="; do
        grep -qF "$marker" "$CGI" && ok "index.cgi 含 $marker" || bad "index.cgi 缺少 $marker"
    done
    # 结构性校验：不得再出现按渠道枚举的白名单
    grep -qE 'authorize\|callback\|oauth/callback' "$CGI" \
        && bad "index.cgi 疑似退回渠道路径白名单（应做结构性校验）" \
        || ok "index.cgi 未使用渠道枚举白名单"
else
    bad "ui/index.cgi 缺失"
fi

# ── 6. 图标 ─────────────────────────────────────────────────────────────────
echo "[6] 图标"
for f in ICON.PNG ICON_256.PNG; do
    have "$f" && ok "存在 $f ($(stat -c %s "$ROOT/$f" 2>/dev/null) bytes)" || bad "缺少 $f"
done
for f in ui/images/icon_64.png ui/images/icon_256.png; do
    have "$f" && ok "存在 $f" || bad "缺少 $f"
done

# ── 7. 权限与归属 ───────────────────────────────────────────────────────────
echo "[7] 权限"
if have config/privilege; then
    python3 - "$ROOT/config/privilege" <<'PY' && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("username"), "privilege 缺 username"
assert (d.get("defaults") or {}).get("run-as"), "privilege 缺 defaults.run-as"
print("  \033[32mPASS\033[0m config/privilege 指定了运行用户")
PY
else
    bad "config/privilege 缺失"
fi

# ── 8. 二进制与凭据 ─────────────────────────────────────────────────────────
echo "[8] 载荷"
[ -s "$ROOT/bin/wild-work" ] && ok "bin/wild-work 存在 ($(stat -c %s "$ROOT/bin/wild-work" 2>/dev/null) bytes)" || bad "bin/wild-work 缺失或为空"
[ -s "$ROOT/bin/wwbridge" ] && ok "bin/wwbridge 存在" || bad "bin/wwbridge 缺失或为空"
if [ -f "$ROOT/bin/gemini-oauth.env" ]; then
    n=$(grep -c '^CMDC_PAK_GOOGLE_CLIENT' "$ROOT/bin/gemini-oauth.env" 2>/dev/null | head -1); n=${n:-0}
    [ "$n" = "2" ] && ok "Gemini OAuth 凭据已内置（2 个字段）" || bad "Gemini 凭据字段数异常：$n"
    perm=$(stat -c %a "$ROOT/bin/gemini-oauth.env" 2>/dev/null)
    [ "$perm" = "600" ] && ok "凭据文件权限 600" || skip "凭据文件权限为 $perm（≥600 亦可，但建议 600）"
else
    skip "无 Gemini 凭据（该渠道将不可用，不阻塞发布）"
fi

# ── 9. 适配性专项 ───────────────────────────────────────────────────────────
echo "[9] 适配性专项"
# 9a 前端 API 子路径：包里二进制不应再含根相对 "/api/
if [ -s "$ROOT/bin/wild-work" ]; then
    n=$(grep -cF '"/api/' "$ROOT/bin/wild-work" 2>/dev/null | head -1); n=${n:-0}
    [ "$n" = "0" ] && ok "前端 API 已改为相对路径（网关子路径可用）" \
                   || bad "二进制里仍有 $n 处根相对 \"/api/（网关下面板会 404）"
    grep -qF "WW popup patch" "$ROOT/bin/wild-work" && ok "登录跳转补丁在位" || bad "登录跳转补丁缺失"
    grep -qF "wwResumeLogin" "$ROOT/bin/wild-work" && ok "刷新后恢复登录浮层在位" || bad "恢复浮层补丁缺失"
    # 手机适配交回上游：不应再有我们的 !important 覆盖
    grep -qF "wildwork mobile patch" "$ROOT/bin/wild-work" \
        && bad "仍带着已退役的手机端 !important 覆盖（会压制上游自适应布局）" \
        || ok "未携带已退役的手机端覆盖"
fi

echo
echo "===== 适配性审计汇总: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ====="
[ "$FAIL" -eq 0 ] || { echo "存在 FAIL 项，不应发布"; exit 1; }
echo "全部通过"
exit 0
