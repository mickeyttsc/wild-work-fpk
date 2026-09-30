# 脚本使用说明

本目录的两个脚本各司其职：**打包**（build-fpk.sh）与**验包**（test-startup-compat.sh），
外加一个**防泄露扫描**（scan-secrets.sh）。三者都在 CI 里自动执行，不必手工跑，
但本地改完先跑一遍能省掉一轮 CI 往返。

---

## build-fpk.sh —— 打包

### 用途
从上游 `rockswang/wild-work` 按指定 ref 克隆源码、编译二进制，
套上 `template/` 里真机验证过的 fnOS 骨架（`cmd/main` + `wwbridge` + `ui` + `wizard`），
用 fnpack 打成可安装的 `.fpk`。

### 参数
- `$1`：**本仓库的打包版本**，如 `v2.5.3-3`。带 `-N` 后缀用于同一上游版本的封装重打
  （不带后缀会让 fnOS 当成同版本、跳过升级）
- `$2`：**上游 ref**（release tag 或 commit），如 `v2.5.3`

默认值写在脚本开头。两者**必须分开**：`-N` 后缀在上游仓库里并不存在。

### 用法
```bash
./build-fpk.sh v2.5.3-3 v2.5.3
```

### 输出
- `wildwork-<版本>.fpk`
- 打印二进制 SHA256、包 MD5/SHA256、包内容清单与 checksum 自洽结果

### 依赖
- Git、Go（CI 用 stable）
- ImageMagick（生成 64/256 图标；缺了会 FATAL，不静默回退占位图）
- fnpack（脚本内自动下载）

### 注意事项
1. **不依赖本机已装环境**：骨架全部来自仓库内 `template/`，上游源码临时克隆编译。
   这正是它能跑在 GitHub Actions 上的前提。
2. **需要联网**：克隆上游 + 下载 fnpack。
3. **不需要 root**：只要工作目录可写。

---

## test-startup-compat.sh —— 启动兼容门禁

### 用途
用**真实二进制**起一遍服务，验证两类真实路径，防止把坏包发出去：

| 用例 | 场景 |
|---|---|
| `fresh` | 全新安装：三份 config.json 一个都不存在 |
| `legacy` | 旧版升级：老形状 config（`listen_host`/`listen_port`）+ 用户自定义字段 |

### 断言（共 6 项，任一失败即退出 1）

1. 进程起来 → `/api/auth/state` 鉴权开启 → 未登录 `/api/state` 返回 401
2. 三份 config 均为 `0600` 且 `listen` 是上游认识的 `{"host","port"}` 形状
3. `fresh` 留空时密码**正好是默认 `password`**，且用它走
   `POST /api/auth/login` 取 cookie 后 `/api/state` 得 200（端到端，非只查文件）
4. 安装向导填的密码写进三份 config + `admin-password.txt`
5. 升级时向导值**绝不覆盖**用户既有密码
6. `wizard/install` 恰有 1 个密码字段、`wizard/upgrade` 必须 0 个
   （官方 wizard 无条件跳过机制，「已设密码就跳过」靠两份向导文件实现）
7. 无密码的老版本升级后落到默认 `password` 且能登录，用户 `api_key` 不丢

另外验证升级前会写出回滚点（`config.json.pre-admin-auth.bak`）。

### 用法
```bash
# 参数是「包根」：可以是打包前的组装目录，也可以是解包后的 fpk
./scripts/test-startup-compat.sh /path/to/pkg-root
```
脚本自动识别两种布局（打包前 `app/bin/` vs fnpack 解包后摊平到根 `bin/`）。

`build-fpk.sh` 会调用它**两次**：打包前（组装目录）+ 打包后（解包回验）。

### 注意
- 需要 `python3` 与 `curl`
- 会自选空闲端口，互不冲突

---

## scan-secrets.sh —— 敏感信息扫描

### 用途
阻止把凭据、内网地址、本机路径提交进这个**公开**仓库。
打包是自动化的，人不会每次记得检查；一旦进了历史就撤不回来。

### 用法
```bash
./scripts/scan-secrets.sh          # 扫 git 跟踪的文件（CI 用）
./scripts/scan-secrets.sh --all    # 连未跟踪文件一起扫（本机自查用）
```
命中则列出「规则名 + 文件:行号 + 脱敏内容」并退出 1。

### 规则
| 规则 | 抓什么 |
|---|---|
| `environment` | 内网 IP（`192.168.*` / `10.*`）、本机存储路径、个人域名 |
| `credential` | GitHub token、`sk-`、`xox*`、AWS key、私钥块 |
| `hardcoded-secret` | 把强密码/token 直接赋值写死在代码里 |
| `forbidden-file` | `admin-password.txt`、`.env`、凭据与状态文件等 |

门禁用例里刻意使用的假值（如 `user-existing-secret`）在脚本的 `ALLOWLIST` 里豁免。
**要放行新内容时改 ALLOWLIST，不要放宽规则本身。**

---

## check-published.sh —— 判断上游版本是否已发布

### 用途
查本仓库 Release 里有没有某个上游版本的可用 fpk 附件。
`check-upstream.yml` 的「是否要构建」与「Repair」两步都靠它。

### 用法
```bash
GITHUB_REPOSITORY=<owner>/<repo> GITHUB_TOKEN=<tok> ./scripts/check-published.sh v2.5.5
```
stdout 末两行是判据（同时写进 `$GITHUB_OUTPUT`，若已设置）：
```
PUBLISHED=true|false
MAX_N=<n>          # 已发布产物里最大的重打包序号（无后缀的老包记 0）
```
**退出码恒为 0**（仅环境/网络出错才非 0）—— 调用方按 `PUBLISHED` 判断。
不要改成「未发布就 exit 1」：带 `set -e` 的调用方会在那一步直接退出。

### 两条设计约束（都是踩坑换来的）
1. **用 `releases?per_page=100` 列表，不用 `releases/tags/<tag>`**。
   tags 端点会返回陈旧缓存（实测同一 release：tags 端点 `assets: []`，
   按数字 id 查得到 1 个附件）。列表端点一次带回全部 release 及其 assets，
   既避开缓存，也省掉为几十种候选 tag 各发一次请求。
2. **tag 与附件名都宽匹配**。历史上 tag 有 `v2.5.3` 与 `v2.5.3-3` 两种形态，
   附件名有 `wildwork-2.4.1.fpk`（无后缀）与 `wildwork-2.5.3-4.fpk`。
   只认一种会把「其实已有包」判成未发布 → 每 2 小时重复重建，
   而重建还可能把修好的版本覆盖回旧内容。

---

## publish-release.sh —— 发布 Release 附件

### 用途
把某次 `build-fpk.yml` 运行的 artifact 发布成本仓库的 Release 附件，
并做内容自检与上传后回读校验。`check-upstream.yml` 的正常路径与 Repair 路径共用它。

### 用法
```bash
# 已知 run id（最稳，本机复现/补发用）
./scripts/publish-release.sh v2.5.5 2.5.5-1 --run-id 36730104529

# 刚 dispatch 完，不知道 run id：按时间下界自己找
./scripts/publish-release.sh v2.5.5 2.5.5-1 --since $(( $(date +%s) - 120 ))
```
参数：`<Release tag> <包版本> (--run-id N | --since EPOCH)`。

### 它做的四件事（每一步都是补过的洞）
1. **定位 run**：按 `build-fpk.yml` 过滤 + 按时间下界过滤。
   只筛 `event=workflow_dispatch` 会把别的 workflow 算进来；
   只取「最新一次」会撞上 runs 列表端点的陈旧缓存 ——
   实测 check 步骤轮询到了 **9 天前**那次成功运行，于是拿着别人的 run
   去下载 artifact，报「包里没有预期文件」。
2. **内容自检**：解包断言 `manifest` 的 `version` 等于包版本，
   且二进制里能找到上游版本串。这是「包到底换没换版」的判据。
3. **上传带 `Content-Length`**：不带该头时上传流会被中间层改写而**静默损坏**
   （实测 7860260 → 7860244 字节），API 照样回 `201`、`state=uploaded`。
4. **回读验收**：重新下载附件、按**实际字节**重算 sha256，
   与 artifact 的哈希比对。只比 `size` 字段不够 —— 上传损坏时 size 也是坏值。

> 轮询期间遇到 `cancelled` 不判失败：`build-fpk.yml` 有
> `concurrency: cancel-in-progress`，短时间内连发两次 dispatch 时先到的那次会被取消
> （实测 run 61 cancelled → run 62 success）。继续等后续运行即可。

---

## 本地自检三部曲

改完 `template/` 或 `cmd/main` 后，不必等 CI：

```bash
bash -n template/cmd/main            # 语法
./scripts/scan-secrets.sh --all      # 防泄露
./scripts/test-startup-compat.sh <组装的包根>   # 启动兼容
```

改完 CI 逻辑（`check-upstream.yml` / `build-fpk.sh`）后，**本机就能实跑**：

```bash
bash -n build-fpk.sh scripts/*.sh
# 版本号守卫的负向验证：这三种都必须非 0 退出
bash build-fpk.sh "" v2.5.5 ; bash build-fpk.sh "v" v2.5.5 ; bash build-fpk.sh "main" v2.5.5
# 已发布判定（拿真实仓库数据跑，不依赖上游发新版）
GITHUB_REPOSITORY=<owner>/<repo> GITHUB_TOKEN=<tok> ./scripts/check-published.sh v2.5.3
# 用历史 run 复现发布全链路
GITHUB_REPOSITORY=<owner>/<repo> GITHUB_TOKEN=<tok> ./scripts/publish-release.sh v2.5.5 2.5.5-1 --run-id <run_id>
```
