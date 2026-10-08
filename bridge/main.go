// wwbridge — fnOS 网关桥接：unix socket -> 127.0.0.1:7863（wild-work 控制台）
//
// fork 重写版（v2 起）。只解决一件事：上游 2.5.5+ 在 guardMux 挂的 stdlib
// CrossOriginProtection（CSRF）在 fnOS 网关链路误拦浏览器 POST，表现为
// 「添加账号 / 签到 / 改设置全部 403: cross-origin request detected」。
//
// 链路事实（2026-10-07 实测）：
//
//	浏览器页面挂在 http://<NAS>:5666/app/wildwork/（fnOS 登录页嵌入）。
//	fnOS nginx 对 /app/ 固定 `proxy_set_header Host $host;` —— $host 语义
//	**不含端口**，所以本桥收到的 Host 是 <NAS>（无端口），而 Origin 带端口
//	（http://<NAS>:5666）。上游 CSRF 无 Sec-Fetch-Site 时回退判
//	Origin.Host == req.Host："<NAS>:5666" != "<NAS>" ⇒ 403。
//	HTTP 是非可信上下文，浏览器不发 Sec-Fetch-Site，所以每次必踩；
//	HTTPS 入口（fnos.net / 反代域名）是安全上下文、浏览器原生带
//	Sec-Fetch-Site: same-origin，所以一直正常。
//
// 修复（透传层两条，不碰请求体/响应体；回调补投继续走 ui/index.cgi 既有机制）：
//  1. Host 对齐：入口 Host 无端口而 Origin 有端口且 host 名一致时，把端口
//     补回转发 Host（$host 丢端口的直接补救）。
//  2. 同源注入：Origin 的 host 名与入口 Host 的 host 名一致、且 UA 是浏览器、
//     且原生缺 Sec-Fetch-Site 时，补 same-origin —— 命中上游第一优先级放行，
//     不依赖回退比较。host 名不一致（真跨站）一律不注入，上游照常 403，
//     CSRF 防护语义不削弱；Origin 缺失的非浏览器客户端本来就 fail-open，
//     本桥不伪造任何头。
package main

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"time"
)

func main() {
	logSet := log.New(os.Stderr, "wwbridge: ", 0)
	args := os.Args[1:]
	if len(args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: wwbridge <socket> <prefix> <tcp-addr> [lan-ip]")
		os.Exit(2)
	}
	sockPath, prefix, tcpAddr := args[0], args[1], args[2]
	// 第 4 参 lan-ip 为兼容旧版签名保留，本实现不使用。
	_ = args

	if !strings.HasPrefix(prefix, "/") {
		prefix = "/" + prefix
	}
	prefix = strings.TrimSuffix(prefix, "/")

	transport := &http.Transport{
		DialContext:           (&net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		MaxIdleConns:          64,
		MaxIdleConnsPerHost:   32,
		IdleConnTimeout:       90 * time.Second,
		ResponseHeaderTimeout: 0, // 登录轮询/长挂请求不能被掐
	}

	proxy := &httputil.ReverseProxy{
		Director: func(r *http.Request) {
			r.URL.Scheme = "http"
			r.URL.Host = tcpAddr

			entry := r.Host
			if entry == "" {
				entry = "localhost"
			}
			origin := r.Header.Get("Origin")

			if oHost, oPort := splitOrigin(origin); oHost != "" &&
				strings.EqualFold(oHost, hostNoPort(entry)) &&
				strings.Contains(r.Header.Get("User-Agent"), "Mozilla") {
				// 1) $host 丢端口 → 补回 Origin 的端口
				if portNo(entry) == "" && oPort != "" {
					entry = entry + ":" + oPort
				}
				// 2) HTTP 非可信源不发元数据头 → 注入同源声明
				if r.Header.Get("Sec-Fetch-Site") == "" {
					r.Header.Set("Sec-Fetch-Site", "same-origin")
					if r.Header.Get("Sec-Fetch-Mode") == "" {
						r.Header.Set("Sec-Fetch-Mode", "cors")
					}
					if r.Header.Get("Sec-Fetch-Dest") == "" {
						r.Header.Set("Sec-Fetch-Dest", "empty")
					}
				}
			}

			r.Host = entry
			r.Header.Set("X-Forwarded-Host", entry)
			if r.Header.Get("X-Forwarded-Proto") == "" {
				r.Header.Set("X-Forwarded-Proto", "http")
			}
			r.RequestURI = ""
		},
		Transport: transport,
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			logSet.Printf("upstream %s: %v", tcpAddr, err)
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			w.WriteHeader(http.StatusBadGateway)
			_, _ = w.Write([]byte("wild-work is not reachable"))
		},
	}

	// 路径分发与旧桥对齐：带 /app/wildwork 前缀（含 cgi 未剥的情况）→ 剥掉；
	// 不带前缀（cgi 已剥 / 直连探测）→ 原样透传。不能用 http.StripPrefix，
	// 它在前缀不匹配时直接回 404，会砍掉旧桥允许的「无前缀直达」行为。
	var handler http.Handler = proxy
	if prefix != "" {
		p := prefix
		base := proxy
		handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch {
			case r.URL.Path == p:
				// 目录型入口不带尾斜杠（桌面/应用中心/手机 App 生成的入口 URL 均无斜杠）：
				// 按 http.ServeMux 惯例 301 补斜杠，让浏览器把 ./app.js 等文档相对路径
				// 解析到 /app/wildwork/ 基址下。若只做内部重写，文档基址停在 /app/，
				// 静态资源全部 404、面板 JS 挂死（2026-10-09 实测回归，详见技能 wildwork-ops）。
				u := *r.URL
				u.Path += "/"
				http.Redirect(w, r, u.String(), http.StatusMovedPermanently)
				return
			case strings.HasPrefix(r.URL.Path, p+"/"):
				r.URL.Path = strings.TrimPrefix(r.URL.Path, p)
			}
			base.ServeHTTP(w, r)
		})
	}

	ln, err := listenUnix(sockPath)
	if err != nil {
		logSet.Printf("listen %s: %v", sockPath, err)
		os.Exit(1)
	}
	fmt.Printf("%s wwbridge: %s (%s) -> %s\n",
		time.Now().Format("2006/01/02 15:04:05"), sockPath, prefix, tcpAddr)
	srv := &http.Server{Handler: handler, ReadHeaderTimeout: 15 * time.Second}
	if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
		logSet.Printf("serve: %v", err)
		os.Exit(1)
	}
}

// splitOrigin 解析 Origin（scheme://host[:port]）→ host、port（无端口则 ""）。
func splitOrigin(v string) (string, string) {
	if v == "" {
		return "", ""
	}
	u, err := url.Parse(v)
	if err != nil || u.Host == "" {
		return "", ""
	}
	return u.Hostname(), u.Port()
}

// hostNoPort 取入口 Host（host[:port] 形式）的主机名部分。
// 浏览器发来的 Host 不会是裸 IPv6（那会带方括号），SplitHostPort
// 失败时按原样返回即可。
func hostNoPort(s string) string {
	if h, _, err := net.SplitHostPort(s); err == nil {
		return strings.Trim(h, "[]")
	}
	return strings.Trim(s, "[]")
}

// portNo 取入口 Host 的字面端口（无端口返回 ""）。
func portNo(s string) string {
	if _, p, err := net.SplitHostPort(s); err == nil {
		return p
	}
	return ""
}

func listenUnix(sockPath string) (net.Listener, error) {
	ln, err := net.Listen("unix", sockPath)
	if err == nil {
		_ = os.Chmod(sockPath, 0666) // 与旧版一致：fnOS 侧任意用户进程可连
		return ln, nil
	}
	// 残留 socket（升级/重启后旧进程已死）：探测无人监听则接管
	if fi, statErr := os.Stat(sockPath); statErr == nil && fi.Mode()&os.ModeSocket != 0 {
		if probe, perr := net.DialTimeout("unix", sockPath, 300*time.Millisecond); perr != nil {
			_ = os.Remove(sockPath)
			if ln, err = net.Listen("unix", sockPath); err == nil {
				_ = os.Chmod(sockPath, 0666)
				return ln, nil
			}
		} else {
			_ = probe.Close()
		}
	}
	return nil, err
}
