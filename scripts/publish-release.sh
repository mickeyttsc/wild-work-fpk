#!/bin/bash
# publish-release.sh —— 把某次 build-fpk 运行的 artifact 发布成本仓库的 Release 附件
#
# 为什么单独成脚本：打包（build-fpk.yml）与发布（check-upstream.yml）是两件事，
# 而「发布」有三条入口 —— 正常跟随上游、Repair 补建、手工重打。
# 内联在 YAML 里等于复制三份，且无法在本机实跑验证（YAML 里的 run 体只能靠 CI 试）。
# 抽成脚本后本机就能用真实 run id 跑一遍。
#
# 用法：
#   publish-release.sh <TAG> <PKG_VERSION> --run-id <ID>
#   publish-release.sh <TAG> <PKG_VERSION> --since <EPOCH>
#
#   TAG          本仓库 Release 的 tag，如 v2.5.5（约定 = 上游 tag）
#   PKG_VERSION  包版本，如 2.5.5-1（决定 artifact 里的文件名 wildwork-<PKG_VERSION>.fpk）
#   --run-id     直接用这个 run id（已知时最稳）
#   --since      dispatch 前记下的 epoch 秒；脚本自己挑「该时刻之后最新的一次 build run」
#
# 环境变量：GITHUB_REPOSITORY（owner/repo）、GITHUB_TOKEN 或 GH_TOKEN
# 退出码：0 = Release 上已有校验通过的附件；非 0 = 失败并打印原因
set -euo pipefail

TAG=${1:?用法: publish-release.sh <TAG> <PKG_VERSION> (--run-id N | --since EPOCH)}
PKG_VERSION=${2:?缺少 PKG_VERSION}
MODE=${3:?缺少 --run-id 或 --since}
VALUE=${4:?缺少 --run-id/--since 的取值}

: "${GITHUB_REPOSITORY:?缺少 GITHUB_REPOSITORY}"
TOK=${GITHUB_TOKEN:-${GH_TOKEN:-}}
[ -n "$TOK" ] || { echo "FATAL: 缺少 GITHUB_TOKEN / GH_TOKEN"; exit 1; }

API="https://api.github.com/repos/${GITHUB_REPOSITORY}"
AUTH=(-H "Authorization: token ${TOK}" -H "Accept: application/vnd.github+json")
FPK_FILE="wildwork-${PKG_VERSION}.fpk"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

log() { echo "[publish] $*"; }
die() { echo "::error::$*"; exit 1; }

# ── 1. 定位要发布的 build run ────────────────────────────────────────────
# ★ 必须按 workflow 过滤，不能只筛 event=workflow_dispatch：
#   那会把别的 workflow 的运行（甚至手工触发的 check-upstream 自己）也算进来。
# ★ 必须按时间下界过滤，不能只取「最新一次」：
#   runs 列表端点会返回陈旧缓存 —— 实测 check 步骤轮询到的是 9 天前那次成功运行，
#   于是拿着别人的 run 去下载 artifact，报「包里没有预期文件」。
RUN_ID=""
if [ "$MODE" = "--run-id" ]; then
  RUN_ID="$VALUE"
  log "使用指定 run: $RUN_ID"
else
  [ "$MODE" = "--since" ] || die "未知模式 $MODE（只支持 --run-id / --since）"
  SINCE="$VALUE"
  log "等待 $SINCE 之后触发的 build-fpk 运行（最长 12 分钟）…"
  last_state=""
  for i in $(seq 1 24); do
    sleep 30
    # 取最近若干次，找 created_at >= SINCE 的最新一条
    cand=$(curl -sf -H "Authorization: token ${TOK}" \
      "${API}/actions/workflows/build-fpk.yml/runs?event=workflow_dispatch&per_page=20" \
      | jq -r --argjson since "$SINCE" '
          [ .workflow_runs[]
            | select((.created_at | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601) >= $since)
          ] | sort_by(.created_at) | reverse | .[0]
          | "\(.id) \(.status) \(.conclusion // "-") \(.created_at)"' 2>/dev/null || true)
    if [ -n "$cand" ] && [ "$cand" != "null" ]; then
      set -- $cand
      rid=$1; status=$2; concl=$3; created=$4
      last_state="$rid/$status/$concl"
      log "[$i] run $rid: $status / $concl ($created)"
      if [ "$status" = "completed" ]; then
        if [ "$concl" = "success" ]; then
          RUN_ID="$rid"
          break
        fi
        # ★ 不在这里立刻失败：build-fpk.yml 有 concurrency cancel-in-progress，
        #   短时间内连发两次 dispatch 时先到的那次会被「取消」——
        #   实测正是这个模式（run 61 cancelled → run 62 success）。
        #   继续等后续 run，直到超时；这比把一次取消当成永久失败稳。
        log "  该次未成功（$concl），继续等后续运行…"
      fi
    else
      log "[$i] 还没有出现该时刻之后的 build run…"
    fi
  done
  [ -n "$RUN_ID" ] || die "12 分钟内没等到成功的 build run（最后状态：${last_state:-无}）"
fi

# 复核 run 归属与结论（--run-id 路径也要查，避免把失败的 run 当成功）
run_json=$(curl -sf -H "Authorization: token ${TOK}" "${API}/actions/runs/${RUN_ID}") \
  || die "读不到 run $RUN_ID"
run_path=$(echo "$run_json" | jq -r '.path')
run_concl=$(echo "$run_json" | jq -r '.conclusion')
case "$run_path" in
  *build-fpk.yml) : ;;
  *) die "run $RUN_ID 不是 build-fpk.yml 的运行（path=$run_path）" ;;
esac
[ "$run_concl" = "success" ] || die "run $RUN_ID 结论是 $run_concl，不是 success"

# ── 2. 取 artifact（这是唯一的真值来源）────────────────────────────────
art=$(curl -sf -H "Authorization: token ${TOK}" "${API}/actions/runs/${RUN_ID}/artifacts")
art_id=$(echo "$art" | jq -r '[.artifacts[] | select(.name=="wildwork-fpk")][0].id // empty')
[ -n "$art_id" ] || { echo "$art" | jq .; die "run $RUN_ID 上没有 wildwork-fpk artifact"; }
log "下载 artifact $art_id"
curl -sfL -o "$WORK/artifact.zip" \
  -H "Authorization: token ${TOK}" "${API}/actions/artifacts/${art_id}/zip" \
  || die "artifact 下载失败"
( cd "$WORK" && unzip -oq artifact.zip ) || die "artifact 解压失败"
[ -f "$WORK/$FPK_FILE" ] || {
  echo "--- artifact 内文件 ---"; ls -la "$WORK"
  die "artifact 里没有 $FPK_FILE（版本号对不上？）"
}
SRC="$WORK/$FPK_FILE"
SRC_SHA=$(sha256sum "$SRC" | cut -d' ' -f1)
SRC_SIZE=$(stat -c%s "$SRC")
log "artifact: $FPK_FILE size=$SRC_SIZE sha256=$SRC_SHA"

# ── 3. 内容自检：manifest 版本必须是 PKG_VERSION，二进制里必须带上游版本 ──
# 这两条是「包是不是真的换版了」的判据。曾经因为 dispatch 传了空版本号，
# 编出 manifest 缺 version 的包让 fnpack 直接失败 —— 断言在这里能更早暴露。
mf_ver=$(tar xzf "$SRC" -O manifest | tr -d '\r' | sed -n 's/^version *= *//p' | head -1)
[ "$mf_ver" = "$PKG_VERSION" ] || die "manifest version='$mf_ver' 与期望 '$PKG_VERSION' 不符"
base_ver="${TAG#v}"
( cd "$WORK" && tar xzf "$SRC" -O app.tgz | tar xz -O bin/wild-work > "$WORK/wild-work.bin" )
cnt=$(python3 -c "import sys;b=open('$WORK/wild-work.bin','rb').read();print(b.count(b'$base_ver'))")
[ "$cnt" -ge 1 ] || die "二进制里找不到上游版本串 '$base_ver'（包内容可疑）"
log "内容自检通过：manifest=$mf_ver，二进制含版本串 $base_ver ×$cnt"

# ── 4. 找或建 Release（按 tag_name 在列表里找，不用 releases/tags —— 那个会返回陈旧缓存）
rel_id=$(curl -sf -H "Authorization: token ${TOK}" "${API}/releases?per_page=100" \
  | jq -r --arg t "$TAG" '[.[] | select(.tag_name==$t)][0].id // empty')
if [ -z "$rel_id" ]; then
  body=$(jq -nc --arg t "$TAG" --arg p "$PKG_VERSION" \
    '{tag_name:$t, name:("Wild Work FPK " + $t),
      body:("自动构建于上游 " + $t + " (rockswang/wild-work releases)。下载 wildwork-" + $p + ".fpk 在飞牛 fnOS 应用中心手动安装。"),
      draft:false, prerelease:false}')
  resp=$(curl -sS -w '\n%{http_code}' -X POST "${API}/releases" \
    -H "Authorization: token ${TOK}" -H "Accept: application/vnd.github+json" -d "$body")
  code=$(echo "$resp" | tail -1)
  [ "$code" = "201" ] || { echo "$resp" | head -n -1; die "创建 Release $TAG 失败（HTTP $code）"; }
  rel_id=$(echo "$resp" | head -n -1 | jq -r '.id')
  log "已创建 Release $TAG (id=$rel_id)"
else
  log "Release $TAG 已存在 (id=$rel_id)，复用"
fi

# ── 5. 删掉同名旧附件（GitHub 不允许同名重复上传）──────────────────────
stale=$(curl -sf -H "Authorization: token ${TOK}" "${API}/releases/${rel_id}/assets" \
  | jq -r --arg n "$FPK_FILE" '.[] | select(.name==$n) | .id')
if [ -n "$stale" ]; then
  log "删除同名旧附件 $stale"
  dc=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
    -H "Authorization: token ${TOK}" "${API}/releases/assets/${stale}")
  case "$dc" in 204|404) : ;; *) die "删除旧附件失败（HTTP $dc）";; esac
fi

# ── 6. 上传（Content-Length 必须显式带，否则流会被改写而静默损坏）──────
uploaded=""
for attempt in 1 2 3 4 5; do
  resp=$(curl -sS -w '\n%{http_code}' -X POST \
    "https://uploads.github.com/repos/${GITHUB_REPOSITORY}/releases/${rel_id}/assets?name=${FPK_FILE}" \
    -H "Authorization: token ${TOK}" \
    -H "Content-Type: application/octet-stream" \
    -H "Content-Length: ${SRC_SIZE}" \
    --data-binary "@${SRC}") || true
  code=$(echo "$resp" | tail -1)
  log "上传第 $attempt 次 -> HTTP $code"
  if [ "$code" = "201" ]; then
    uploaded=$(echo "$resp" | head -n -1 | jq -r '.browser_download_url')
    break
  fi
  echo "$resp" | head -n -1 | head -c 800; echo
  sleep $((attempt * 10))
done
[ -n "$uploaded" ] && [ "$uploaded" != "null" ] || die "$TAG 的附件上传 5 次都失败"

# ── 7. 验收：回读附件并按「实际下载到的字节」重算哈希 ───────────────────
# ★ 只比 size 字段不够：上传损坏时 size 也会是坏值，只有重新下载才能定性。
asset=$(curl -sf -H "Authorization: token ${TOK}" "${API}/releases/${rel_id}/assets" \
  | jq -r --arg n "$FPK_FILE" '.[] | select(.name==$n)')
a_id=$(echo "$asset" | jq -r '.id')
a_size=$(echo "$asset" | jq -r '.size')
[ -n "$a_id" ] && [ "$a_id" != "null" ] || die "$TAG 上没有 $FPK_FILE"
[ "$a_size" = "$SRC_SIZE" ] || die "附件 size=$a_size 与本地 $SRC_SIZE 不一致"
curl -sfL -o "$WORK/back.fpk" -H "Authorization: token ${TOK}" \
  -H "Accept: application/octet-stream" "${API}/releases/assets/${a_id}" \
  || die "附件回读失败"
BACK_SHA=$(sha256sum "$WORK/back.fpk" | cut -d' ' -f1)
[ "$BACK_SHA" = "$SRC_SHA" ] || die "附件哈希不一致：回读 $BACK_SHA != artifact $SRC_SHA"

echo "Release ready: ${TAG} -> ${FPK_FILE} size=${SRC_SIZE} sha256=${SRC_SHA} (run ${RUN_ID})"
