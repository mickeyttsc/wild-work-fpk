# Wild Work FPK 自动打包

GitHub Actions 会自动在以下情况构建 fpk：

1. **Tag 推送**：当推送到 `v*` 格式 tag 时（如 `v2.2.2`）
2. **手动触发**：通过 GitHub Actions 界面手动触发，指定版本号和上游 ref

## 使用方式

### 自动触发（推荐）
在上游仓库发布新版本 tag 后，GitHub Actions 会自动构建 fpk：

```bash
# 在上游仓库创建并推送 tag
git tag v2.2.2
git push origin v2.2.2
```

### 手动触发
1. 访问 https://github.com/rockswang/wild-work/actions
2. 点击 "Build Wild Work FPK" workflow
3. 点击 "Run workflow"
4. 输入版本号（如 `v2.2.2`）和上游 ref（如 `main` 或具体 commit）
5. 点击 "Run workflow"

## 打包特点

- ✅ **复用现有结构**：自动从已安装版本复制 `cmd/main`、`wwbridge`、`ui` 等组件
- ✅ **只替换二进制**：保留原有生命周期脚本和配置，避免重新踩坑
- ✅ **自动验证**：生成 MD5/SHA256 校验和，确保包完整性
- ✅ **Icon 处理**：自动从 upstream icon.png 生成 64x64 和 256x256 图标
- ✅ **Manifest 更新**：自动更新 version 字段和 changelog

## 输出产物

- `wildwork-v2.2.2.fpk` - 可直接安装的飞牛 NAS fpk 包
- GitHub Release 附件（tag 推送时自动创建）

## 已知坑点（已规避）

1. **cmd/scripts 必需性**：复用已装版本的 cmd/main + wizard 文件，不重新手写
2. **wizard JSON 格式**：直接复制已装版本的 wizard/install/upgrade/config
3. **manifest checksum**：由 fnpack 自动计算，不手动填写
4. **换行符问题**：fnpack build 会自动规范化为 LF，无需纠结 CRLF
5. **权限问题**：privilege/resource 配置复用已装版本

## 回滚方案

升级前会备份到：
```
/vol2/1000/备份/Hermes 操作目录/wildwork_<原版本>_rollback_<时间戳>/
```

包含：
- `main` - cmd/main 脚本
- `manifest` - 原 manifest 文件
- `wild-work` - 旧版本二进制
