#!/bin/bash
# 敏感信息扫描：阻止把凭据 / 私人环境信息提交进这个 **公开** 仓库。
#
# 为什么要有这个：打包是自动化的，人不会每次都记得检查。
# 一旦真实密码、渠道凭据、内网 IP 或本机路径被 commit 到公开仓库，
# 就不是「改回来」能挽回的（历史里仍然在）。
#
# 用法：
#   scripts/scan-secrets.sh              # 扫 git 跟踪的文件（CI 与提交前用）
#   scripts/scan-secrets.sh --all        # 连同未跟踪文件一起扫（本机自查用）
#
# 退出码：0 = 干净，1 = 命中。
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

MODE=${1:-tracked}

if [ "$MODE" = "--all" ]; then
    # 列全部文件（排除 .git 与 .gitignore 里声明忽略的）
    FILE_LIST=$(git ls-files --cached --others --exclude-standard)
else
    FILE_LIST=$(git ls-files --cached)
fi

if [ -z "$FILE_LIST" ]; then
    echo "scan-secrets: 没有文件可扫"
    exit 0
fi

HITS=0
report() {
    # $1=规则名 $2=文件 $3=行号 $4=命中内容（脱敏后由调用方给出）
    HITS=$((HITS + 1))
    printf '✗ [%s] %s:%s\n    %s\n' "$1" "$2" "$3" "$4"
}

# ── 规则 1：本机环境标识（NAS 内网地址、主机用户名、本域）──────────────
# 只在本仓库里这些一定不该出现；命中说明是从本机环境里带出来的。
ENV_PATTERN='192\.168\.[0-9]{1,3}\.[0-9]{1,3}|10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|/vol[0-9]+/@|@appcenter/|ttao\.me'

# ── 规则 2：真实凭据形态（GitHub token、常见密钥前缀）──────────────────
CRED_PATTERN='ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----'

# ── 规则 3：把密码直接写死在「非测试」上下文 ────────────────────────────
# 允许测试夹具里的假密码（user-existing-secret / password / wizard-...），
# 那是门禁用例；这里抓的是像真密码一样的赋值（含大小写+数字的强串）。
HARDCODED_ASSIGN='(admin_password|password|passwd|token|secret|apikey|api_key)[[:space:]]*[=:][[:space:]]*["'"'"'][A-Za-z0-9!@#$%^&*_-]{12,}["'"'"']'

# 允许清单：门禁用例里刻意使用的假值。匹配到这些就不算命中。
ALLOWLIST='user-existing-secret|legacy-kept-key|old-user-key|wizard-chosen-password|must-not-override|"password"|secrets\.GITHUB_TOKEN|\$GITHUB_TOKEN|Bearer \$'

# 不该被扫的路径：
#  - 二进制/图片/压缩包无法做有意义的文本扫描
#  - **扫描器自身**：它的规则字面量本来就写着 192.168.* / ghp_ 这些模式，
#    扫自己必然自报（这是自指问题，不是泄露）。用文件名精确排除，
#    不要为了让脚本"通过"而放宽规则 —— 那会连带放掉真实命中。
EXCLUDE_PATH='\.(png|jpg|jpeg|ico|gif|fpk|tgz|gz|zip|so|woff2?|ttf)$'
SELF_PATH='(^|/)scripts/scan-secrets\.sh$'

while IFS= read -r f; do
    [ -f "$f" ] || continue
    if printf '%s' "$f" | grep -qE "$EXCLUDE_PATH"; then
        continue
    fi
    if printf '%s' "$f" | grep -qE "$SELF_PATH"; then
        continue
    fi

    # 逐规则扫，行号保留，内容脱敏（只回显前若干字符，避免把真凭据打印到日志）
    while IFS=: read -r lineno content; do
        [ -n "$lineno" ] || continue
        if printf '%s' "$content" | grep -qE "$ALLOWLIST"; then
            continue
        fi
        masked=$(printf '%s' "$content" | cut -c1-24)
        report "environment" "$f" "$lineno" "${masked}…"
    done < <(grep -nE "$ENV_PATTERN" "$f" 2>/dev/null || true)

    while IFS=: read -r lineno content; do
        [ -n "$lineno" ] || continue
        if printf '%s' "$content" | grep -qE "$ALLOWLIST"; then
            continue
        fi
        masked=$(printf '%s' "$content" | cut -c1-24)
        report "credential" "$f" "$lineno" "${masked}…"
    done < <(grep -nE "$CRED_PATTERN" "$f" 2>/dev/null || true)

    while IFS=: read -r lineno content; do
        [ -n "$lineno" ] || continue
        if printf '%s' "$content" | grep -qE "$ALLOWLIST"; then
            continue
        fi
        masked=$(printf '%s' "$content" | cut -c1-24)
        report "hardcoded-secret" "$f" "$lineno" "${masked}…"
    done < <(grep -nE "$HARDCODED_ASSIGN" "$f" 2>/dev/null || true)

done <<< "$FILE_LIST"

# ── 规则 4：不该存在的文件名（凭据/密码/状态文件）──────────────────────
FORBIDDEN_NAME='(^|/)(admin-password\.txt|credentials\.json|tokens?\.json|\.env|state-.*\.json|login-state\.json)$'
while IFS= read -r f; do
    [ -n "$f" ] || continue
    if printf '%s' "$f" | grep -qE "$SELF_PATH"; then
        continue
    fi
    if printf '%s' "$f" | grep -qE "$FORBIDDEN_NAME"; then
        report "forbidden-file" "$f" "-" "该文件类型禁止进公开仓库"
    fi
done <<< "$FILE_LIST"

echo ""
if [ "$HITS" -gt 0 ]; then
    echo "✗ 敏感信息扫描命中 $HITS 处 —— 拒绝提交。"
    echo "  若确认是测试夹具里的假值，请加进本脚本的 ALLOWLIST，不要放宽规则。"
    exit 1
fi
echo "✓ 敏感信息扫描通过（扫描 $(printf '%s\n' "$FILE_LIST" | wc -l) 个文件）"
