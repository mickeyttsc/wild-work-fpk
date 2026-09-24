#!/bin/bash
# Build-time compatibility smoke test for the packaged fnOS lifecycle wrapper.
#
# Covers BOTH real-world paths, because they fail for different reasons:
#
#   fresh   — 全新安装：三份 config.json 一个都不存在。老实现会写出发往上游
#             不认识的 listen_host/listen_port，listen 解析为空 →
#             IsLoopback()=false 且 admin_password 为空 → 启动即 fatal。
#             这是新客户首次安装 100% 失败的那个 bug。
#   legacy  — 旧版升级：@appdata 里已有旧形状的 config（无 admin_password）。
#             必须迁移成上游合法形状并补随机密码，且保留用户原有设置。
#
# 两路都必须：进程起来 → /api/auth/state 200 且鉴权开启 → 未登录 /api/state 401
# → 密码文件 0600 → 三份配置 0600 且形状合法 → 网关 socket 存在。
set -euo pipefail

PKG_ROOT=${1:?usage: test-startup-compat.sh <fnos-package-root>}
PKG_ROOT=$(cd "$PKG_ROOT" && pwd)

# 兼容两种布局（必须都支持，否则门禁 2 必然假红）：
#   build 布局 —— fnpack 打包**前**的组装目录，字节在 app/bin/ 下
#   解包布局 —— fnpack 打包**后**解出来的 fpk，fnpack 会把 app/ 的内容
#               摊平到包根，于是字节直接在 bin/ 下（实测结果，不是猜测）
if [ -f "$PKG_ROOT/app/bin/wild-work" ]; then
    APP_DIR="$PKG_ROOT/app"
else
    APP_DIR="$PKG_ROOT"
fi
APP_BIN="$APP_DIR/bin/wild-work"
BRIDGE_BIN="$APP_DIR/bin/wwbridge"
LIFECYCLE="$PKG_ROOT/cmd/main"
SHIPPED_CFG="$APP_DIR/bin/config.json"

for f in "$APP_BIN" "$BRIDGE_BIN" "$LIFECYCLE" "$SHIPPED_CFG"; do
    if [ ! -f "$f" ]; then
        echo "missing packaged file: $f" >&2
        exit 1
    fi
done

# 包内自带的 bin/config.json 必须是上游认识的形状，否则全新安装直接炸。
SHIPPED_CFG="$SHIPPED_CFG" python3 - <<'PY'
import json
import os
from pathlib import Path
p = Path(os.environ["SHIPPED_CFG"])
data = json.loads(p.read_text(encoding="utf-8"))
if not isinstance(data.get("listen"), dict):
    raise SystemExit(f"shipped bin/config.json must use {{\"listen\":{{...}}}}, got {data!r}")
if data["listen"].get("host") != "0.0.0.0":
    raise SystemExit(f"shipped listen.host must be 0.0.0.0, got {data['listen'].get('host')!r}")
PY

free_port() {
    python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

# assert_started <label> <tmpdir> <port>
assert_started() {
    local label="$1" tmp="$2" port="$3"

    curl -fsS --max-time 3 "http://127.0.0.1:$port/api/auth/state" > "$tmp/auth-state.json"

    AUTHPROBE="$tmp/auth-state.json" python3 - <<'PY'
import json
import os
from pathlib import Path
state = json.loads(Path(os.environ["AUTHPROBE"]).read_text(encoding="utf-8"))
if state.get("auth_enabled") is not True or state.get("auth_required") is not True:
    raise SystemExit(f"panel auth not enabled: {state!r}")
PY

    local code
    code=$(curl -sS -o "$tmp/guarded.json" -w '%{http_code}' --max-time 3 \
        "http://127.0.0.1:$port/api/state")
    if [ "$code" != "401" ]; then
        echo "[$label] unauthenticated /api/state returned HTTP $code, expected 401" >&2
        exit 1
    fi

    # 三份配置都要存在、0600、且 listen/admin_password 形状合法
    CFG_BIN="$tmp/app/bin/config.json" CFG_VAR="$tmp/var/config.json" \
    CFG_HOME="$tmp/home/config.json" PASS_PATH="$tmp/home/admin-password.txt" \
    python3 - "$label" <<'PY'
import json
import os
import stat
import sys
from pathlib import Path
label = sys.argv[1]
paths = [os.environ["CFG_BIN"], os.environ["CFG_VAR"], os.environ["CFG_HOME"]]
passwords = set()
for raw in paths:
    p = Path(raw)
    if not p.exists():
        raise SystemExit(f"[{label}] config not written: {p}")
    if stat.S_IMODE(p.stat().st_mode) != 0o600:
        raise SystemExit(f"[{label}] unsafe mode {oct(stat.S_IMODE(p.stat().st_mode))} on {p}")
    data = json.loads(p.read_text(encoding="utf-8"))
    listen = data.get("listen")
    if not isinstance(listen, dict) or listen.get("host") != "0.0.0.0" or not isinstance(listen.get("port"), int):
        raise SystemExit(f"[{label}] legacy listen shape survived in {p}: {listen!r}")
    if "listen_host" in data or "listen_port" in data:
        raise SystemExit(f"[{label}] legacy keys not migrated out of {p}")
    pw = data.get("admin_password")
    # 下限定在 8 位：与安装向导的 min 规则一致，同时挡住空密码。
    # 不能要求「够长」的随机串 —— 默认密码是 password（8 位），
    # 用户也可以在向导里设 8 位密码，写死 24 会把这些合法情况全判成失败。
    if not isinstance(pw, str) or len(pw.strip()) < 8:
        raise SystemExit(f"[{label}] admin_password missing/too short in {p}: {pw!r}")
    passwords.add(pw)
if len(passwords) != 1:
    raise SystemExit(f"[{label}] the three configs disagree on the admin password")

pw_file = Path(os.environ["PASS_PATH"])
if not pw_file.exists():
    raise SystemExit(f"[{label}] admin password file missing: {pw_file}")
if stat.S_IMODE(pw_file.stat().st_mode) != 0o600:
    raise SystemExit(f"[{label}] admin password file is not 0600: {pw_file}")
if pw_file.read_text(encoding="utf-8").strip() not in passwords:
    raise SystemExit(f"[{label}] admin password file does not match config")
PY

    kill -0 "$(cat "$tmp/var/wild-work.pid")"
    kill -0 "$(cat "$tmp/var/wwbridge.pid")"
    test -S "$tmp/app/app.sock"
    echo "[$label] ok: auth enabled, 401 guard, 3 configs 0600, bridge socket up"
}

# run_case <label> <prepare-fn-name>
run_case() {
    local label="$1" prepare="$2"
    local tmp port
    tmp=$(mktemp -d)
    port=$(free_port)

    mkdir -p "$tmp/app/bin" "$tmp/var" "$tmp/etc/auth" "$tmp/home" "$tmp/tmp"
    cp "$APP_BIN" "$tmp/app/bin/wild-work"
    cp "$BRIDGE_BIN" "$tmp/app/bin/wwbridge"
    chmod 755 "$tmp/app/bin/wild-work" "$tmp/app/bin/wwbridge"
    cp "$LIFECYCLE" "$tmp/main"
    chmod 755 "$tmp/main"

    export TRIM_APPDEST="$tmp/app" \
        TRIM_PKGVAR="$tmp/var" \
        TRIM_PKGETC="$tmp/etc" \
        TRIM_PKGHOME="$tmp/home" \
        TRIM_PKGTMP="$tmp/tmp" \
        TRIM_SERVICE_PORT="$port" \
        TRIM_TEMP_LOGFILE="$tmp/start-error.log"

    "$prepare" "$tmp" "$port"

    if ! bash "$tmp/main" start; then
        echo "[$label] lifecycle start failed" >&2
        [ -f "$tmp/start-error.log" ] && cat "$tmp/start-error.log" >&2
        tail -30 "$tmp/var/wild-work.log" 2>/dev/null >&2 || true
        bash "$tmp/main" stop >/dev/null 2>&1 || true
        rm -rf "$tmp"
        exit 1
    fi

    if ! assert_started "$label" "$tmp" "$port"; then
        bash "$tmp/main" stop >/dev/null 2>&1 || true
        rm -rf "$tmp"
        exit 1
    fi

    # 全新安装（向导留空）额外钉死默认密码
    if [ "$label" = "fresh" ]; then
        if ! assert_fresh_default_password "$tmp" "$port"; then
            bash "$tmp/main" stop >/dev/null 2>&1 || true
            rm -rf "$tmp"
            exit 1
        fi
    fi

    bash "$tmp/main" stop >/dev/null 2>&1 || true
    rm -rf "$tmp"
}

# --- case 1: 全新安装（三份 config 都不存在）---
prepare_fresh() {
    local tmp="$1"
    # 刻意不放任何 config.json；同时验证包内 bin/config.json 的形状
    cp "$SHIPPED_CFG" "$tmp/app/bin/config.json"
    chmod 600 "$tmp/app/bin/config.json"
    # 上游 workDir() = exe 所在目录，全新安装时存在的是打包带的那份，
    # 且它**没有** admin_password —— 正是新客户踩的坑。
    APP_CFG="$tmp/app/bin/config.json" python3 - <<'PY'
import json
import os
from pathlib import Path
p = Path(os.environ["APP_CFG"])
data = json.loads(p.read_text(encoding="utf-8"))
if data.get("admin_password"):
    raise SystemExit("fresh-install fixture must not ship an admin_password")
PY
}

# 全新安装且向导留空时，密码必须正好是文档承诺的默认值。
# 这是用户唯一能从安装界面知道的东西 —— 一旦漂回随机串，
# 用户装完就进不去控制台，且没有任何地方能查到密码。
assert_fresh_default_password() {
    local tmp="$1" port="$2" pw
    pw=$(CFG="$tmp/app/bin/config.json" python3 - <<'PY'
import json
import os
from pathlib import Path
print(json.loads(Path(os.environ["CFG"]).read_text(encoding="utf-8")).get("admin_password", ""))
PY
)
    if [ "$pw" != "password" ]; then
        echo "[fresh] 留空时应当使用默认密码 'password'，实际是 '$pw'" >&2
        exit 1
    fi
    # 默认密码必须真的能登录（不是只写进文件里）。
    # 注意：面板鉴权是 **cookie session**，不是把 admin_password 当 Bearer token：
    #   1) POST /api/auth/login {"password": "..."} → Set-Cookie: ww_admin=<token>
    #   2) 带该 cookie 请求 /api/state 才得 200
    # 直接用 Bearer 打 /api/state 必然 401 —— 那不是密码错，是鉴权方式不对。
    local jar code
    jar=$(mktemp)
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 -c "$jar" \
        -H 'Content-Type: application/json' \
        -d "{\"password\":\"$pw\"}" "http://127.0.0.1:$port/api/auth/login")
    if [ "$code" != "200" ]; then
        rm -f "$jar"
        echo "[fresh] 默认密码 'password' 登录失败（/api/auth/login HTTP $code，期望 200）" >&2
        exit 1
    fi
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 -b "$jar" \
        "http://127.0.0.1:$port/api/state")
    rm -f "$jar"
    if [ "$code" != "200" ]; then
        echo "[fresh] 默认密码登录后仍拿不到 /api/state（HTTP $code，期望 200）" >&2
        exit 1
    fi
}

# --- case 2: 旧版升级（老形状配置，无 admin_password，含自定义字段需保留）---
prepare_legacy() {
    local tmp="$1" port="$2"
    printf '{\n  "listen_host": "0.0.0.0",\n  "listen_port": %s,\n  "api_key": "legacy-kept-key"\n}\n' "$port" \
        > "$tmp/var/config.json"
    chmod 600 "$tmp/var/config.json"
    cp "$SHIPPED_CFG" "$tmp/app/bin/config.json"
    chmod 600 "$tmp/app/bin/config.json"
}

run_case fresh prepare_fresh
run_case legacy prepare_legacy

# 回归断言：legacy 升级必须保留用户原有设置（迁移只动 listen/admin_password，
# 不能把 api_key 之类的用户配置吃掉）
KEEPCHECK_DIR=$(mktemp -d)
mkdir -p "$KEEPCHECK_DIR/app/bin" "$KEEPCHECK_DIR/var" "$KEEPCHECK_DIR/etc/auth" \
    "$KEEPCHECK_DIR/home" "$KEEPCHECK_DIR/tmp"
cp "$APP_BIN" "$KEEPCHECK_DIR/app/bin/wild-work"
cp "$BRIDGE_BIN" "$KEEPCHECK_DIR/app/bin/wwbridge"
cp "$SHIPPED_CFG" "$KEEPCHECK_DIR/app/bin/config.json"
cp "$LIFECYCLE" "$KEEPCHECK_DIR/main"
chmod 755 "$KEEPCHECK_DIR/app/bin/wild-work" "$KEEPCHECK_DIR/app/bin/wwbridge" "$KEEPCHECK_DIR/main"
KEEP_PORT=$(free_port)
printf '{\n  "listen_host": "0.0.0.0",\n  "listen_port": %s,\n  "api_key": "legacy-kept-key"\n}\n' "$KEEP_PORT" \
    > "$KEEPCHECK_DIR/var/config.json"
chmod 600 "$KEEPCHECK_DIR/var/config.json"
TRIM_APPDEST="$KEEPCHECK_DIR/app" TRIM_PKGVAR="$KEEPCHECK_DIR/var" \
TRIM_PKGETC="$KEEPCHECK_DIR/etc" TRIM_PKGHOME="$KEEPCHECK_DIR/home" \
TRIM_PKGTMP="$KEEPCHECK_DIR/tmp" TRIM_SERVICE_PORT="$KEEP_PORT" \
TRIM_TEMP_LOGFILE="$KEEPCHECK_DIR/start-error.log" \
    bash "$KEEPCHECK_DIR/main" start >/dev/null
for cfg in "$KEEPCHECK_DIR/app/bin/config.json" "$KEEPCHECK_DIR/var/config.json" "$KEEPCHECK_DIR/home/config.json"; do
    CFG="$cfg" python3 - <<'PY'
import json
import os
from pathlib import Path
data = json.loads(Path(os.environ["CFG"]).read_text(encoding="utf-8"))
if data.get("api_key") != "legacy-kept-key":
    raise SystemExit(f"legacy user setting api_key was lost in {os.environ['CFG']}: {data!r}")
PY
done
# 升级路径必须留回滚点
if [ ! -f "$KEEPCHECK_DIR/var/config.json.pre-admin-auth.bak" ]; then
    echo "legacy migration did not leave config.json.pre-admin-auth.bak" >&2
    exit 1
fi
TRIM_APPDEST="$KEEPCHECK_DIR/app" TRIM_PKGVAR="$KEEPCHECK_DIR/var" \
TRIM_PKGETC="$KEEPCHECK_DIR/etc" TRIM_PKGHOME="$KEEPCHECK_DIR/home" \
TRIM_PKGTMP="$KEEPCHECK_DIR/tmp" TRIM_SERVICE_PORT="$KEEP_PORT" \
    bash "$KEEPCHECK_DIR/main" stop >/dev/null 2>&1 || true
rm -rf "$KEEPCHECK_DIR"
echo "legacy user settings preserved + rollback point written"

# --- 断言 3：安装向导设的密码必须在全新安装时生效 ---
# 用户视角：安装界面填了密码，装完就该能用它登录，而不是被随机串顶掉。
WIZCHECK_DIR=$(mktemp -d)
mkdir -p "$WIZCHECK_DIR/app/bin" "$WIZCHECK_DIR/var" "$WIZCHECK_DIR/etc/auth" \
    "$WIZCHECK_DIR/home" "$WIZCHECK_DIR/tmp"
cp "$APP_BIN" "$WIZCHECK_DIR/app/bin/wild-work"
cp "$BRIDGE_BIN" "$WIZCHECK_DIR/app/bin/wwbridge"
cp "$SHIPPED_CFG" "$WIZCHECK_DIR/app/bin/config.json"
cp "$LIFECYCLE" "$WIZCHECK_DIR/main"
chmod 755 "$WIZCHECK_DIR/app/bin/wild-work" "$WIZCHECK_DIR/app/bin/wwbridge" "$WIZCHECK_DIR/main"
WIZ_PORT=$(free_port)
WIZ_PW="wizard-chosen-password-9f3a"
TRIM_APPDEST="$WIZCHECK_DIR/app" TRIM_PKGVAR="$WIZCHECK_DIR/var" \
TRIM_PKGETC="$WIZCHECK_DIR/etc" TRIM_PKGHOME="$WIZCHECK_DIR/home" \
TRIM_PKGTMP="$WIZCHECK_DIR/tmp" TRIM_SERVICE_PORT="$WIZ_PORT" \
TRIM_TEMP_LOGFILE="$WIZCHECK_DIR/start-error.log" \
wizard_admin_password="$WIZ_PW" \
    bash "$WIZCHECK_DIR/main" start >/dev/null
for cfg in "$WIZCHECK_DIR/app/bin/config.json" "$WIZCHECK_DIR/var/config.json" "$WIZCHECK_DIR/home/config.json"; do
    CFG="$cfg" WANT="$WIZ_PW" python3 - <<'PY'
import json
import os
from pathlib import Path
data = json.loads(Path(os.environ["CFG"]).read_text(encoding="utf-8"))
if data.get("admin_password") != os.environ["WANT"]:
    raise SystemExit(
        f"wizard password not applied in {os.environ['CFG']}: got {data.get('admin_password')!r}")
PY
done
PW_FILE="$WIZCHECK_DIR/home/admin-password.txt" WANT="$WIZ_PW" python3 - <<'PY'
import os
from pathlib import Path
got = Path(os.environ["PW_FILE"]).read_text(encoding="utf-8").strip()
if got != os.environ["WANT"]:
    raise SystemExit(f"admin-password.txt does not carry the wizard password: {got!r}")
PY
TRIM_APPDEST="$WIZCHECK_DIR/app" TRIM_PKGVAR="$WIZCHECK_DIR/var" \
TRIM_PKGETC="$WIZCHECK_DIR/etc" TRIM_PKGHOME="$WIZCHECK_DIR/home" \
TRIM_PKGTMP="$WIZCHECK_DIR/tmp" TRIM_SERVICE_PORT="$WIZ_PORT" \
    bash "$WIZCHECK_DIR/main" stop >/dev/null 2>&1 || true
rm -rf "$WIZCHECK_DIR"
echo "install-wizard password applied to all configs + password file"

# --- 断言 4：升级时向导值绝不能覆盖用户已有密码 ---
# 用户视角：升级界面也带这个字段，若它覆盖既有密码，等于升级时被静默改凭据，
# 用户下次登录就进不去了。
KEEPW_DIR=$(mktemp -d)
mkdir -p "$KEEPW_DIR/app/bin" "$KEEPW_DIR/var" "$KEEPW_DIR/etc/auth" \
    "$KEEPW_DIR/home" "$KEEPW_DIR/tmp"
cp "$APP_BIN" "$KEEPW_DIR/app/bin/wild-work"
cp "$BRIDGE_BIN" "$KEEPW_DIR/app/bin/wwbridge"
cp "$SHIPPED_CFG" "$KEEPW_DIR/app/bin/config.json"
cp "$LIFECYCLE" "$KEEPW_DIR/main"
chmod 755 "$KEEPW_DIR/app/bin/wild-work" "$KEEPW_DIR/app/bin/wwbridge" "$KEEPW_DIR/main"
KEEPW_PORT=$(free_port)
printf '{\n  "listen": {"host": "0.0.0.0", "port": %s},\n  "admin_password": "user-existing-secret"\n}\n' \
    "$KEEPW_PORT" > "$KEEPW_DIR/var/config.json"
chmod 600 "$KEEPW_DIR/var/config.json"
TRIM_APPDEST="$KEEPW_DIR/app" TRIM_PKGVAR="$KEEPW_DIR/var" \
TRIM_PKGETC="$KEEPW_DIR/etc" TRIM_PKGHOME="$KEEPW_DIR/home" \
TRIM_PKGTMP="$KEEPW_DIR/tmp" TRIM_SERVICE_PORT="$KEEPW_PORT" \
TRIM_TEMP_LOGFILE="$KEEPW_DIR/start-error.log" \
wizard_admin_password="must-not-override" \
    bash "$KEEPW_DIR/main" start >/dev/null
for cfg in "$KEEPW_DIR/app/bin/config.json" "$KEEPW_DIR/var/config.json" "$KEEPW_DIR/home/config.json"; do
    CFG="$cfg" python3 - <<'PY'
import json
import os
from pathlib import Path
data = json.loads(Path(os.environ["CFG"]).read_text(encoding="utf-8"))
if data.get("admin_password") != "user-existing-secret":
    raise SystemExit(
        f"upgrade reset the user's password in {os.environ['CFG']}: got {data.get('admin_password')!r}")
PY
done
TRIM_APPDEST="$KEEPW_DIR/app" TRIM_PKGVAR="$KEEPW_DIR/var" \
TRIM_PKGETC="$KEEPW_DIR/etc" TRIM_PKGHOME="$KEEPW_DIR/home" \
TRIM_PKGTMP="$KEEPW_DIR/tmp" TRIM_SERVICE_PORT="$KEEPW_PORT" \
    bash "$KEEPW_DIR/main" stop >/dev/null 2>&1 || true
rm -rf "$KEEPW_DIR"
echo "upgrade keeps the user's existing password (wizard value ignored)"

echo "both startup compatibility paths passed"
