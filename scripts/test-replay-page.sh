#!/bin/bash
# 登录补投页（template/ui/index.cgi）离线自测。
#
# 为什么需要：补投页是「本机回环回调」类渠道（Trae /authorize、千问 /callback、
# CodeArts /oauth/callback、Gemini /oauth-callback、LobsterAI /auth/callback）
# 在 NAS 上唯一能完成登录的通道。它坏了不会有人报错，只会表现为
# 「点添加账号 → 授权完页面打不开 → 面板转圈到超时」。改这个 CGI 必须跑本脚本。
#
# 用法： bash scripts/test-replay-page.sh [index.cgi 路径]
# 依赖： bash + python3（仅测试用假回调服务），无需 go / 无需 NAS。
set -uo pipefail

CGI="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/template/ui/index.cgi}"
[ -f "$CGI" ] || { echo "FATAL: 找不到 $CGI"; exit 1; }

WORK="$(mktemp -d)"
PORT=$(( (RANDOM % 20000) + 20000 ))
HITS="$WORK/hits.log"
FAIL=0

cat > "$WORK/srv.py" <<'PY'
import http.server, sys
log, port = sys.argv[1], int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(log, 'a') as f:
            f.write(self.path + "\n")
        self.send_response(200); self.send_header('Content-Type', 'text/plain'); self.end_headers()
        self.wfile.write(b'ok')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
PY
python3 "$WORK/srv.py" "$HITS" "$PORT" &
SRV=$!
cleanup() { kill "$SRV" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

for _ in $(seq 1 50); do
    curl -s --noproxy '*' -m 1 "http://127.0.0.1:$PORT/__ready" >/dev/null 2>&1 && break
    sleep 0.1
done
: > "$HITS"

submit() { # $1 = 完整回调地址 → 打印结果正文
    local enc
    enc=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1")
    REQUEST_URI="/cgi/ThirdParty/wildwork/index.cgi/?u=$enc" bash "$CGI" 2>&1
}

check_hit() { # $1=描述 $2=期望路径
    if grep -qxF "$2" "$HITS"; then
        echo "  PASS 转发成功：$1 → $2"
    else
        echo "  FAIL 未转发：$1 → 期望 $2；实收：$(tr '\n' ' ' < "$HITS")"
        FAIL=1
    fi
}

echo "== 1. 各渠道回调路径都能转交 =="
: > "$HITS"
for pair in \
    "Trae|/authorize?isRedirect=true&code=a1" \
    "千问办公|/callback?code=a2&state=s" \
    "CodeArts|/oauth/callback?code=a3&state=s" \
    "Gemini|/oauth-callback?code=a4&state=s" \
    "LobsterAI|/auth/callback?code=a5&state=s" ; do
    name="${pair%%|*}"; path="${pair#*|}"
    out=$(submit "http://127.0.0.1:$PORT$path")
    case "$out" in
        *已转交成功*) : ;;
        *) echo "  FAIL $name 页面未提示成功：$(printf '%s' "$out" | sed 's/<[^>]*>/ /g' | tr -s ' \n' ' ' | head -c 160)"; FAIL=1 ;;
    esac
    check_hit "$name" "$path"
done

echo "== 2. localhost 形态（Gemini 用 localhost）=="
: > "$HITS"
submit "http://localhost:$PORT/oauth-callback?code=b1&state=s" >/dev/null
check_hit "localhost" "/oauth-callback?code=b1&state=s"

echo "== 3. 安全边界：外站 / 非法路径 / 低端口 不得转发 =="
: > "$HITS"
submit "http://evil.example/oauth/callback?code=x1" >/dev/null
submit "http://127.0.0.1:$PORT/etc/passwd?code=x2" >/dev/null
submit "http://127.0.0.1:22/oauth/callback?code=x3" >/dev/null
sleep 0.3
if [ -s "$HITS" ]; then
    echo "  FAIL 有请求被错误转发：$(tr '\n' ' ' < "$HITS")"; FAIL=1
else
    echo "  PASS 外站 / 非法路径 / 低端口 均未转发"
fi

echo "== 4. 表单页可渲染 =="
page=$(REQUEST_URI="/cgi/ThirdParty/wildwork/index.cgi/" bash "$CGI" 2>&1)
case "$page" in
    *"确认提交"*"location.href='/cgi/ThirdParty/wildwork/index.cgi/?u='"*)
        echo "  PASS 表单页与提交基址正常" ;;
    *)
        echo "  FAIL 表单页异常"; echo "$page" | head -c 300; FAIL=1 ;;
esac

echo
if [ "$FAIL" -eq 0 ]; then echo "RESULT: ALL PASS"; else echo "RESULT: FAILED"; fi
exit "$FAIL"
