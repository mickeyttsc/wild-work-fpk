#!/bin/bash
# Wild Work 登录回调补投页面
# 把浏览器里打不开的 http://127.0.0.1:端口/authorize?... 地址转交给 NAS 上的 wild-work

URI_NO_QUERY="${REQUEST_URI:-/cgi/ThirdParty/wildwork/index.cgi/}"
QUERY=""
case "$URI_NO_QUERY" in
  *\?*)
    QUERY="${URI_NO_QUERY#*\?}"
    URI_NO_QUERY="${URI_NO_QUERY%%\?*}"
    ;;
esac

# 基础路径（只保留安全字符，防止注入）
BASE="$(printf '%s' "${URI_NO_QUERY%/}" | tr -cd '/A-Za-z0-9._-')/"
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

STYLE='body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;background:#eef6ff;color:#1f2937;display:grid;place-items:center;min-height:92vh;margin:0}main{background:#fff;border-radius:16px;padding:28px;max-width:660px;width:92%;box-shadow:0 4px 24px rgba(0,0,0,.08)}h1{font-size:20px;margin:0 0 12px}p,li{font-size:14px;line-height:1.8}textarea{width:100%;height:96px;box-sizing:border-box;font-size:13px;padding:10px;border:1px solid #cbd5e1;border-radius:8px;word-break:break-all}button{margin-top:12px;background:#2563eb;color:#fff;border:0;border-radius:8px;padding:10px 24px;font-size:15px;cursor:pointer}a{color:#2563eb}.ok{color:#15803d;font-size:16px}.bad{color:#b91c1c;font-size:16px}'

# ---------- 提交模式: /端口/authorize?原始查询 ----------
port="$(printf '%s' "$REL_PATH" | sed -n 's#^/\([0-9]\{2,5\}\)/authorize$#\1#p')"
if [ -n "$port" ] && [ -n "$QUERY" ]; then
  tmp="$(mktemp 2>/dev/null)" || tmp="/tmp/ww_cb.$$"
  errf="$(mktemp 2>/dev/null)" || errf="/tmp/ww_cb_err.$$"
  trap 'rm -f "$tmp" "$errf" 2>/dev/null' EXIT
  target="http://127.0.0.1:${port}/authorize?${QUERY}"
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
      msg='已转交成功。回到 Wild Work 控制台刷新一下，看账号是否已经添加。'
      cls='ok' ;;
    000)
      msg='连不上 NAS 上的回调服务（可能已经关闭）。请回控制台重新点一次『添加账号』，登录后在 10 分钟内把新地址粘贴过来。'
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
form_html="${form_html}<p>电脑浏览器登录 Trae / Qoder 后，会跳到一条 <b>http://127.0.0.1:端口/authorize?...</b> 地址并显示打不开，这是正常的。把地址栏里的<b>完整地址</b>粘贴到这里点确认，我替你转交给 NAS 上的 wild-work。</p>"
form_html="${form_html}<ol><li>Wild Work 控制台点『添加账号』，浏览器里完成登录</li><li>浏览器停在打不开的 127.0.0.1 地址时，复制地址栏<b>完整内容</b></li><li>粘贴到下面，点确认（授权码 10 分钟内有效）</li><li>回到 Wild Work 控制台查看账号</li></ol>"
form_html="${form_html}<textarea id=\"u\" placeholder=\"http://127.0.0.1:38629/authorize?isRedirect=true&...\"></textarea>"
form_html="${form_html}<button onclick=\"go()\">确认提交</button>"
form_html="${form_html}<script>
function go(){
  var v=document.getElementById('u').value.trim();
  var m=v.match(/^http:\/\/127\.0\.0\.1:(\d+)(\/authorize[^\s]*)$/i);
  if(!m){alert('请粘贴完整的 http://127.0.0.1:端口/authorize?... 地址');return;}
  location.href='__BASE__'+m[1]+m[2];
}
</script>"
form_html="${form_html//__BASE__/${BASE}}"

send_page "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Wild Work 登录补投</title><style>${STYLE}</style></head><body><main>${form_html}</main></body></html>"
