#!/bin/bash
# Wild Work 登录回调补投页面
# 把浏览器里打不开的 http://127.0.0.1:端口/<回调路径>?... 地址转交给 NAS 上的 wild-work。
#
# 为什么需要泛化回调路径（2026-10-18）：上游 2.6+ 陆续加了多个「本机回环回调」渠道，
# 回调路径各不相同，而 wild-work 跑在 NAS 上、浏览器跑在用户设备上，127.0.0.1 永远打不通：
#   Trae        /authorize
#   千问办公     /callback
#   CodeArts    /oauth/callback
#   Gemini      /oauth-callback
#   LobsterAI   /auth/callback
# 旧版本只认 /authorize，导致新渠道「点了添加、授权完页面打不开、面板一直转圈到超时」。

URI_NO_QUERY="${REQUEST_URI:-/cgi/ThirdParty/wildwork/index.cgi/}"
QUERY=""
case "$URI_NO_QUERY" in
  *\?*)
    QUERY="${URI_NO_QUERY#*\?}"
    URI_NO_QUERY="${URI_NO_QUERY%%\?*}"
    ;;
esac

# 基础路径：一律截到 index.cgi 为止（提交模式下的 REL_PATH 会带端口/回调路径，
# 若直接取全路径，"再补投一条"和前端跳转会拼出错误的基址）。
case "$URI_NO_QUERY" in
  *index.cgi*)
    BASE="$(printf '%s' "${URI_NO_QUERY%%index.cgi*}index.cgi/" | tr -cd '/A-Za-z0-9._-')" ;;
  *)
    BASE="/cgi/ThirdParty/wildwork/index.cgi/" ;;
esac
REL_PATH="/"
case "$URI_NO_QUERY" in
  *index.cgi*)
    rp="${URI_NO_QUERY#*index.cgi}"
    REL_PATH="/${rp#/}"
    ;;
esac

send_page() {
  printf 'Content-Type: text/html; charset=utf-8\r\n\r\n'
  printf '%s' "$1"
}

# 找一个可用的 HTTP 客户端（网关 CGI 环境的 PATH 可能查不到，故绝对路径优先）
find_http_client() {
  for p in /usr/bin/curl /bin/curl /usr/local/bin/curl; do
    [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  for p in /usr/bin/wget /bin/wget /usr/local/bin/wget; do
    [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  c="$(command -v curl 2>/dev/null)" && [ -n "$c" ] && { printf '%s' "$c"; return 0; }
  w="$(command -v wget 2>/dev/null)" && [ -n "$w" ] && { printf '%s' "$w"; return 0; }
  return 1
}

# 允许的回调路径白名单（多段路径用 / 分隔；只允许这些，防 SSRF 打内网其它端口）
is_allowed_cb() {
  case "$1" in
    authorize|callback|oauth/callback|oauth-callback|auth/callback|oauth2callback|oauth2/callback) return 0 ;;
    *) return 1 ;;
  esac
}

STYLE='body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;background:#eef6ff;color:#1f2937;display:grid;place-items:center;min-height:92vh;margin:0}main{background:#fff;border-radius:16px;padding:28px;max-width:660px;width:92%;box-shadow:0 4px 24px rgba(0,0,0,.08)}h1{font-size:20px;margin:0 0 12px}p,li{font-size:14px;line-height:1.8}textarea{width:100%;height:96px;box-sizing:border-box;font-size:13px;padding:10px;border:1px solid #cbd5e1;border-radius:8px;word-break:break-all}button{margin-top:12px;background:#2563eb;color:#fff;border:0;border-radius:8px;padding:10px 24px;font-size:15px;cursor:pointer}a{color:#2563eb}.ok{color:#15803d;font-size:16px}.bad{color:#b91c1c;font-size:16px}code{background:#f1f5f9;padding:1px 4px;border-radius:4px}'

# ---------- 提交模式: /端口/<回调路径>?原始查询 ----------
port=""
cb_path=""

# 首选入口：?u=<完整回调地址>（前端统一用这一种）。
# 为什么不用 /端口/回调路径 的多段 URL：fnOS 的 trim_http_cgi 网关如何转发多段 PATH_INFO
# 没有文档保证，而查询参数只依赖 REQUEST_URI 里的 query —— 那条路径旧版已经跑了很久，最稳。
if [ -n "$QUERY" ]; then
  raw_u=""
  case "&${QUERY}&" in
    *"&u="*) raw_u="${QUERY#*u=}"; raw_u="${raw_u%%&*}" ;;
  esac
  if [ -n "$raw_u" ]; then
    # 只解 %XX（前端用 encodeURIComponent，不会留下裸反斜杠）
    u="$(printf '%b' "${raw_u//%/\\x}")"
    case "$u" in
      http://127.0.0.1:*|http://localhost:*|http://\[::1\]:*)
        rest="${u#http://}"
        hostport="${rest%%/*}"
        port="${hostport##*:}"
        pathq="/${rest#*/}"
        cb_path="${pathq%%\?*}"
        cb_path="${cb_path#/}"
        QUERY=""
        case "$pathq" in
          *\?*) QUERY="${pathq#*\?}" ;;
        esac
        ;;
    esac
  fi
fi

# 兜底入口：/端口/<回调路径>?原始查询（旧书签 / 手动拼的地址）
if [ -z "$port" ]; then
  case "$REL_PATH" in
    /[0-9]*/*)
      port="$(printf '%s' "$REL_PATH" | sed -n 's#^/\([0-9]\{2,5\}\)/.*$#\1#p')"
      cb_path="$(printf '%s' "$REL_PATH" | sed -n 's#^/[0-9]\{2,5\}/\(.*\)$#\1#p')"
      ;;
  esac
fi
# 端口只允许非特权区间，避免把本页当成打内网低端口的跳板
bad_port=""
if [ -n "$port" ] && { [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; } 2>/dev/null; then
  bad_port="$port"; port=""
fi
if [ -n "$bad_port" ]; then
  body="<h1>提交结果</h1><p class=\"bad\">网址里的端口 <code>${bad_port}</code> 不在允许范围（1024-65535）。请确认粘贴的是浏览器地址栏里的<b>完整</b>地址。</p><p><a href=\"${BASE}\">← 再补投一条</a></p>"
  send_page "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><title>Wild Work 登录补投</title><style>${STYLE}</style></head><body><main>${body}</main></body></html>"
  exit 0
fi

if [ -n "$port" ] && [ -n "$QUERY" ]; then
  if ! is_allowed_cb "$cb_path"; then
    body="<h1>提交结果</h1><p class=\"bad\">网址里的回调路径 <code>/${cb_path}</code> 不在支持范围内，请确认粘贴的是浏览器地址栏里的<b>完整</b>地址。</p><p><a href=\"${BASE}\">← 再补投一条</a></p>"
    send_page "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><title>Wild Work 登录补投</title><style>${STYLE}</style></head><body><main>${body}</main></body></html>"
    exit 0
  fi
  tmp="$(mktemp 2>/dev/null)" || tmp="/tmp/ww_cb.$$"
  errf="$(mktemp 2>/dev/null)" || errf="/tmp/ww_cb_err.$$"
  trap 'rm -f "$tmp" "$errf" 2>/dev/null' EXIT
  target="http://127.0.0.1:${port}/${cb_path}?${QUERY}"
  code=""
  client="$(find_http_client)" || client=""
  case "$client" in
    */curl)
      code="$("$client" -sS -o "$tmp" -w '%{http_code}' --max-time 15 "$target" 2>"$errf")"
      ;;
    */wget)
      if "$client" -q -T 15 -O "$tmp" "$target" 2>"$errf"; then
        code="200"
      else
        code="$(sed -n 's/.* \([0-9][0-9][0-9]\) .*/\1/p' "$errf" | head -n 1)"
      fi
      ;;
    *)
      code=""
      ;;
  esac
  case "$code" in
    200|201|204|302|303)
      msg='已转交成功。回到 Wild Work 控制台刷新一下，看账号是否已经添加（多等 5~10 秒，面板会自动同步）。'
      cls='ok' ;;
    000)
      msg='连不上 NAS 上的回调服务（可能已经关闭或已超时）。请回控制台重新点一次『添加账号』，登录后在 10 分钟内把新地址粘贴过来。'
      cls='bad' ;;
    '')
      msg='NAS 上没有可用的 curl / wget，无法转交。'
      cls='bad' ;;
    *)
      msg="回调服务返回 HTTP ${code}，授权码可能已过期或无效。请重新点『添加账号』获取新地址再试一次。"
      cls='bad' ;;
  esac
  body="<h1>提交结果</h1><p class=\"${cls}\">${msg}</p><p><a href=\"${BASE}\">← 再补投一条</a></p>"
  send_page "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><title>Wild Work 登录补投</title><style>${STYLE}</style></head><body><main>${body}</main></body></html>"
  exit 0
fi

# ---------- 表单页 ----------
form_html="<h1>Wild Work 登录补投</h1>"
form_html="${form_html}<p>在<b>自己的电脑/手机</b>上完成渠道登录后，浏览器会跳到一条 <b>http://127.0.0.1:端口/...</b> 地址并显示打不开——这是正常的：回调落在了你的设备上，而 Wild Work 跑在 NAS 上。把地址栏里的<b>完整地址</b>粘贴到这里，我替你转交给 NAS 端。</p>"
form_html="${form_html}<ol><li>Wild Work 控制台点『添加账号』，在浏览器里完成登录/授权</li><li>浏览器停在打不开的 <code>127.0.0.1</code> 地址时，复制地址栏<b>完整内容</b></li><li>粘贴到下面，点确认（授权码一般 10 分钟内有效）</li><li>回到 Wild Work 控制台，等 5~10 秒看账号是否出现</li></ol>"
form_html="${form_html}<p style=\"font-size:13px;opacity:.75\">支持的渠道与回调路径：Trae <code>/authorize</code>、千问办公 <code>/callback</code>、CodeArts <code>/oauth/callback</code>、Gemini <code>/oauth-callback</code>、LobsterAI <code>/auth/callback</code>。<br>（ZCode、MiniMax、Qoder 等走服务端轮询/设备码，不需要补投。）</p>"
form_html="${form_html}<textarea id=\"u\" placeholder=\"http://127.0.0.1:38629/oauth/callback?code=...&amp;state=...\"></textarea>"
form_html="${form_html}<button onclick=\"go()\">确认提交</button>"
form_html="${form_html}<script>
function go(){
  var v=document.getElementById('u').value.trim();
  var m=v.match(/^https?:\/\/(?:127\.0\.0\.1|localhost|\[::1\]):(\d+)(\/(?:authorize|callback|oauth\/callback|oauth-callback|auth\/callback|oauth2callback|oauth2\/callback)[^\s]*)$/i);
  if(!m){alert('请粘贴完整的 http://127.0.0.1:端口/… 回调地址（地址栏整条复制）');return;}
  location.href='__BASE__?u='+encodeURIComponent(v);
}
</script>"
form_html="${form_html//__BASE__/${BASE}}"

send_page "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Wild Work 登录补投</title><style>${STYLE}</style></head><body><main>${form_html}</main></body></html>"
