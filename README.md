# wild-work-fpk

飞牛 fnOS 上的 **Wild Work** 安装包（FPK）。自动跟随上游
[rockswang/wild-work](https://github.com/rockswang/wild-work) 构建，下载即装。

Wild Work 是「多渠道账号聚合工具」：把 WorkBuddy(CodeBuddy)、TraeWork、Qoder
的多个账号聚合成一个 OpenAI 兼容 API。

## 包信息

| 项 | 值 |
|---|---|
| 包名（appname） | `wildwork`（技术标识，勿改） |
| 显示名 | Wild Work（应用中心里看到的） |
| 服务端口 | `7863`（本机回环；桌面图标经 fnOS 网关 `/app/wildwork` 小窗打开） |
| 内置组件 | 上游主程序 + wwbridge 网关桥（Go 源码在本仓 `bridge/`） |
| 上游来源 | `rockswang/wild-work`（每 2 小时巡检，有新版本自动构建） |
| 产物文件名 | `wildwork-<版本>.fpk`（如 `wildwork-2.7.2-1.fpk`） |

## 本包改动（相对上游原版）

- **fnOS 网关接入**：上游 app.js 根相对 API 路径补丁（修复网关入口整页 404）。
- **wwbridge 桥接**：源码化并修复 fnOS 网关 CSRF 误拦；目录入口无尾斜杠自动补斜杠（修复 301）。
- **手机适配**：构建期注入 `@media 640px` 覆盖块 + flex 强覆盖（v2，CDP 实测）。
- **自动跟随上游**：每 2 小时巡检上游，新版本自动 bump + 构建 + 发版。
- **敏感信息门禁**：仓库扫描器 + CI + 本地 git 钩子，防止凭据进库。

## 下载与安装

- 下载：见 [Releases](https://github.com/mickeyttsc/wild-work-fpk/releases) 页附件（`wildwork-<版本>.fpk`）
- 安装：飞牛应用中心 → 手动安装 → 选择 fpk。

## 使用说明

- 打开方式：fnOS 桌面图标（经网关小窗进入；服务端口仅本机回环，不对外监听）。
- 首次进入在界面里添加 WorkBuddy / TraeWork / Qoder 账号，多个账号聚合为一个 OpenAI 兼容 API 使用。
- **本机回调类渠道**（CodeArts / Gemini / LobsterAI / 千问办公 / Trae）：服务跑在 NAS 上、浏览器在你自己的设备上，
  授权完成后浏览器会跳到 `127.0.0.1:<端口>/…` 并显示打不开——这是正常的（回调落在你的设备上）。
  把地址栏**整条**复制，粘回面板登录弹窗里的「**粘贴回调地址**」框提交即可（上游 v2.9.3 起内置，
  就地换取凭据，还会校验端口是否属于本次登录）。ZCode / MiniMax / Qoder 走服务端轮询，不需要补投。
- 升级 / 重装保留已添加的账号与配置（数据在应用数据目录）。

## 维护

自动出包链路与历史坑点：[FPK-AUTO-BUILD.md](FPK-AUTO-BUILD.md) ｜ 脚本说明：[scripts/README.md](scripts/README.md)

## 说明

上游 `rockswang/wild-work` 未声明开源许可；本仓库仅作 fnOS 打包分发（自用）。
