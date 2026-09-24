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
    if not isinstance(pw, str) or len(pw.strip()) < 24:
        raise SystemExit(f"[{label}] admin_password missing/too short in {p}")
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

echo "both startup compatibility paths passed"
