#!/bin/bash
# check-published.sh —— 判断某个上游版本是否已在本仓库发布过可用产物
#
# 用法：check-published.sh <UPSTREAM_TAG>      # 如 v2.5.5
#
# 输出（末两行，供调用方读 GITHUB_OUTPUT / grep 取用）：
#   PUBLISHED=true|false
#   MAX_N=<n>        已发布产物里最大的重打包序号（无后缀的老包记 0）
# 退出码恒为 0（仅环境/网络出错才非 0）。调用方按 PUBLISHED 判断，
# 不要用退出码 —— 否则带 `set -e` 的调用方会在「未发布」时提前退出。
#
# 环境变量：GITHUB_REPOSITORY、GITHUB_TOKEN / GH_TOKEN
# 若设置了 GITHUB_OUTPUT（GitHub Actions），同时把两个值写进去。
#
# ★ 为什么用 releases 列表而不是 releases/tags/<tag>：
#   tags 端点会返回陈旧缓存（实测同一 release，tags 端点 assets=[]，
#   而按数字 id 查得到 1 个附件）。列表端点一次就带回所有 release 及其 assets，
#   既避开缓存，也避免为 60 种可能的 tag 命名各发一次请求。
#
# ★ 为什么 tag 命名要宽匹配：历史上两种形态都用过（`v2.5.3` 与 `v2.5.3-3`）。
#   只认一种会把「其实已有包」误判成未发布 → 反复重建，
#   而重建还可能把修好的版本覆盖回旧内容。
set -euo pipefail

TAG=${1:?用法: check-published.sh <UPSTREAM_TAG>}
: "${GITHUB_REPOSITORY:?缺少 GITHUB_REPOSITORY}"
TOK=${GITHUB_TOKEN:-${GH_TOKEN:-}}
[ -n "$TOK" ] || { echo "FATAL: 缺少 GITHUB_TOKEN / GH_TOKEN"; exit 1; }

BASE="${TAG#v}"
# 附件名形如 wildwork-<base>.fpk 或 wildwork-<base>-<N>.fpk。
# ★ `-N` 后缀必须可选：早期流水线产出的是不带后缀的 `wildwork-2.4.1.fpk`
#   （见 Release v2.4.1 / v2.5.2 / v2.5.3），只认带后缀会把它们判成「未发布」。
#   base 里的点要转义成正则里的字面点。
RX="^wildwork-${BASE//./\\.}(-[0-9]+)?\\.fpk\$"

rels=$(curl -sf -H "Authorization: token ${TOK}" -H "Cache-Control: no-cache" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases?per_page=100") \
  || { echo "FATAL: 读不到 release 列表"; exit 1; }

hit=$(echo "$rels" | jq -r --arg b "$BASE" --arg rx "$RX" '
  [ .[]
    | (.tag_name | sub("^v";"")) as $t
    | select($t == $b or ($t | startswith($b + "-")))
    | .assets[]?
    | select(.name | test($rx))
    | { name: .name, size: .size,
        n: ((.name | capture("-(?<n>[0-9]+)\\.fpk$").n // "0") | tonumber) }
  ] | unique_by(.name) | sort_by(.n) | .[] | "\(.n) \(.name) \(.size)"')

if [ -z "$hit" ]; then
  echo "上游 ${TAG} 在本仓库还没有已发布的包"
  PUBLISHED=false; MAX_N=0
else
  echo "上游 ${TAG} 已发布："
  printf '%s\n' "$hit" | sed 's/^[0-9]* /  /'
  PUBLISHED=true
  MAX_N=$(printf '%s\n' "$hit" | awk '{print $1}' | sort -n | tail -1)
fi

echo "PUBLISHED=${PUBLISHED}"
echo "MAX_N=${MAX_N}"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "published=${PUBLISHED}"
    echo "max_n=${MAX_N}"
  } >> "$GITHUB_OUTPUT"
fi
