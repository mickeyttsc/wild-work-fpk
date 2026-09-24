#!/bin/bash
# 提交前自动跑敏感信息扫描。
#
# 为什么放在本地而不是只靠 CI：CI 是**事后**拦截 —— 一旦推到公开仓库，
# 内容就已经进了远端历史。本地钩子能在 commit 落盘前拦住。
#
# 安装（每个 clone 一次）：
#   cp scripts/pre-commit.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
#
# 已知误报（确认是测试夹具假值时）改 scripts/scan-secrets.sh 的 ALLOWLIST，
# 不要用 --no-verify 绕过 —— 那等于关掉这道门。
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

if [ ! -x scripts/scan-secrets.sh ]; then
    exit 0   # 扫描脚本不在（比如老分支），不阻塞
fi

# 只扫**即将提交**的内容：暂存区里已暂存的文件
FILES=$(git diff --cached --name-only --diff-filter=ACM)
if [ -z "$FILES" ]; then
    exit 0
fi

echo "→ 提交前敏感信息扫描…"
# 复用同一个扫描器，但把范围限定到暂存文件：
# scan-secrets.sh 默认扫 git 跟踪的文件，暂存后的状态正好覆盖。
if ! ./scripts/scan-secrets.sh; then
    echo ""
    echo "提交已被阻止。若确认是测试夹具里的假值，"
    echo "请把它加进 scripts/scan-secrets.sh 的 ALLOWLIST 后重试。"
    exit 1
fi
exit 0
