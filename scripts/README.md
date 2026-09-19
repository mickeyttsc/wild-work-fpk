# 脚本使用说明

## build-fpk.sh

### 用途
自动构建 Wild Work 的 fnOS fpk 包，复用已安装版本的结构（cmd/main, wwbridge, ui），只替换二进制。

### 参数
- `$1`: 版本号（如 `v2.2.2`），默认 `v2.2.2`
- `$2`: 上游 git ref（tag/commit），默认 `main`

### 用法
```bash
# 指定版本和上游 ref
./scripts/build-fpk.sh v2.2.2 main

# 或使用默认值
./scripts/build-fpk.sh
```

### 输出
- `wildwork-v2.2.2.fpk` - fpk 安装包
- 打印 MD5、SHA256 校验和
- 打印包内容列表

### 依赖
- Git
- Go 1.22+
- ImageMagick（可选，用于图标处理）
- fnpack（自动下载）

### 注意事项
1. **必须从已安装环境运行**：需要 `/vol2/@appcenter/wildwork` 存在以复制结构
2. **网络要求**：可访问 GitHub 和 fnOS 官方源
3. **权限**：无需 root，但需有写入工作目录权限
