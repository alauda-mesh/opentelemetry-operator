#!/usr/bin/env bash
# 步骤 6b：轮询 Alauda Release 流水线直到完成。
# self-hosted runner 上的双平台镜像构建通常 10~40 分钟，必须后台运行。
# 可用 WATCH_TIMEOUT（秒，默认 3600）调整超时。
#
# 用法: watch-release.sh [run-id]   （不传则用 state 里的 RUN_ID）
# 退出码: 0=PIPELINE_SUCCESS  1=前置条件失败  2=PIPELINE_FAILED  3=PIPELINE_TIMEOUT

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state
need_gh

RUN_ID="${1:-${RUN_ID:-}}"
[[ -n "$RUN_ID" ]] || die "没有 run id，请先执行 trigger-release.sh，或显式传入: watch-release.sh <run-id>"
# 直接传 run-id 调用（没走过 trigger-release.sh）时，这两个值可能没存进 state
BUNDLE_VERSION="${BUNDLE_VERSION:-<bundle_version>}"
RELEASE_VERSION="${RELEASE_VERSION:-<release_version>}"

TIMEOUT="${WATCH_TIMEOUT:-3600}"
INTERVAL=60
START=$(date +%s)

echo "监控 run $RUN_ID（https://github.com/$REPO/actions/runs/$RUN_ID），超时 ${TIMEOUT}s ..."

STATUS=""; CONCLUSION=""
while true; do
  NOW=$(date +%s); ELAPSED=$((NOW - START))

  # 一次调用取两个字段，用 | 分隔；gh 瞬时网络错误只告警重试，不能让 set -e 杀掉整个监控
  LINE="$(gh run view "$RUN_ID" --repo "$REPO" --json status,conclusion \
    -q '.status + "|" + (.conclusion // "")' 2>/dev/null || true)"
  if [[ -z "$LINE" ]]; then
    echo "[${ELAPSED}s] WARN: 查询 run 失败（gh/网络瞬时错误），${INTERVAL}s 后重试"
    if [[ $ELAPSED -ge $TIMEOUT ]]; then echo "PIPELINE_TIMEOUT"; exit 3; fi
    sleep "$INTERVAL"; continue
  fi

  STATUS="${LINE%%|*}"
  CONCLUSION="${LINE#*|}"
  echo "[${ELAPSED}s] status=$STATUS conclusion=${CONCLUSION:--}"

  if [[ "$STATUS" == "completed" ]]; then break; fi
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "PIPELINE_TIMEOUT"
    echo "流水线仍在运行: https://github.com/$REPO/actions/runs/$RUN_ID"
    echo "之后可用: gh run view $RUN_ID --repo $REPO"
    exit 3
  fi
  sleep "$INTERVAL"
done

if [[ "$CONCLUSION" == "success" ]]; then
  echo
  echo "PIPELINE_SUCCESS"
  echo "run: https://github.com/$REPO/actions/runs/$RUN_ID"
  echo "构建镜像："
  echo "  build-harbor.alauda.cn/asm/opentelemetry-operator2:${BUNDLE_VERSION}"
  echo "  build-harbor.alauda.cn/asm/opentelemetry-operator2-bundle:v${BUNDLE_VERSION}"
  echo "GitHub Release（draft，tag ${RELEASE_VERSION}）: https://github.com/$REPO/releases"
  exit 0
fi

echo
echo "PIPELINE_FAILED"
echo "conclusion=$CONCLUSION  run: https://github.com/$REPO/actions/runs/$RUN_ID"
echo
echo "===== 失败概览 ====="
gh run view "$RUN_ID" --repo "$REPO" 2>/dev/null | sed -n '1,40p' || echo "(拉取 run 概览失败)"
echo
echo "===== 失败日志摘要 ====="
LOG="$(gh run view "$RUN_ID" --repo "$REPO" --log-failed 2>/dev/null || true)"
if [[ -z "$LOG" ]]; then
  echo "(拉取日志失败，可手动执行: gh run view $RUN_ID --repo $REPO --log-failed)"
else
  echo "--- 错误相关行 ---"
  printf '%s\n' "$LOG" | grep -iE "error|fail|fatal|denied|not found|no such|unauthorized|timeout" | tail -30 || true
  echo "--- 日志末尾 ---"
  printf '%s\n' "$LOG" | tail -20
fi
exit 2
