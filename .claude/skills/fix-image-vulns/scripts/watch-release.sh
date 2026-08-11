#!/usr/bin/env bash
# 步骤 4b：轮询 Alauda Release 流水线直到完成；成功则收集新镜像、轮次 +1，供回归扫描。
#
# 用法: watch-release.sh [run-id]     不传则用状态里的 RUN_ID
# 退出码: 0=PIPELINE_SUCCESS  1=前置条件失败  2=PIPELINE_FAILED  3=PIPELINE_TIMEOUT
# 环境变量: WATCH_TIMEOUT=3600  WATCH_INTERVAL=60
#
# 注意: self-hosted runner 上的双平台镜像构建通常 10~40 分钟，
#       必须用后台方式运行（Bash 的 run_in_background: true），别前台干等。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state
need_gh

RUN_ID="${1:-${RUN_ID:-}}"
[[ -n "$RUN_ID" ]] || die "没有 run id，请先执行 trigger-release.sh，或显式传入: watch-release.sh <run-id>"
TIMEOUT="${WATCH_TIMEOUT:-3600}"
INTERVAL="${WATCH_INTERVAL:-60}"
START="$(date +%s)"
RUN_URL="https://github.com/$REPO/actions/runs/$RUN_ID"

echo "监控 run $RUN_ID（$RUN_URL），超时 ${TIMEOUT}s ..."
STATUS=""; CONCLUSION=""
while true; do
  ELAPSED=$(( $(date +%s) - START ))
  # 一次调用取两个字段；gh 瞬时网络错误只告警重试，不能让 set -e 杀掉整个监控
  LINE="$(gh run view "$RUN_ID" --repo "$REPO" --json status,conclusion \
    -q '.status + "|" + (.conclusion // "")' 2>/dev/null || true)"
  if [[ -z "$LINE" ]]; then
    echo "[${ELAPSED}s] WARN: 查询 run 失败（gh/网络瞬时错误），${INTERVAL}s 后重试"
  else
    STATUS="${LINE%%|*}"; CONCLUSION="${LINE#*|}"
    echo "[${ELAPSED}s] status=$STATUS conclusion=${CONCLUSION:--}"
    [[ "$STATUS" == "completed" ]] && break
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo
    echo "PIPELINE_TIMEOUT"
    echo "流水线仍在运行: $RUN_URL"
    echo "稍后可重跑本脚本继续等，或 gh run view $RUN_ID --repo $REPO 查看"
    exit 3
  fi
  sleep "$INTERVAL"
done

# ---------- 失败：给出失败概览与日志摘要 ----------
if [[ "$CONCLUSION" != "success" ]]; then
  echo
  echo "PIPELINE_FAILED  conclusion=$CONCLUSION  run: $RUN_URL"
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
  echo
  echo "分析失败原因后：在当前分支追加 commit → create-pr.sh（push）→ 重新 trigger-release.sh → 本脚本"
  exit 2
fi

# ---------- 成功：收集新镜像，写回归轮清单 ----------
NEXT=$((ROUND + 1))
IMAGES=()
while IFS= read -r img; do
  [[ -n "$img" ]] && IMAGES+=("$img")
done < <(extract_build_images "$RUN_ID")
[[ ${#IMAGES[@]} -gt 0 ]] || die "run $RUN_ID 成功但未能提取产出镜像，无法生成回归扫描清单"

IMG_TSV="$(write_round_images "$NEXT" "run-$RUN_ID" "${IMAGES[@]}")"
save_state ROUND "$NEXT"

echo
echo "PIPELINE_SUCCESS"
echo "run: $RUN_URL"
echo "本轮产出、待回归扫描的镜像:"
awk -F'\t' '{printf "  %s\n", $3}' "$IMG_TSV"
echo "draft GitHub Release（tag ${RELEASE_VERSION:-见触发参数}）: https://github.com/$REPO/releases"

# ---------- PR 上的社区 CI 状态（best-effort，如实报告，不影响退出码） ----------
if [[ -n "${PR_NUMBER:-}" ]]; then
  echo
  echo "PR #$PR_NUMBER 上未通过的 check（社区 CI，在 fork 上可能有固有失败项）:"
  gh pr view "$PR_NUMBER" --repo "$REPO" --json statusCheckRollup \
    --jq '.statusCheckRollup[] | select((.conclusion // .state) as $c | ["SUCCESS","SKIPPED","NEUTRAL","PENDING"] | index($c) | not) | "  \(.name // .context): \(.conclusion // .state)"' \
    2>/dev/null | sort -u | head -20 || echo "  （读取 check 状态失败）"
  echo "  （为空即全部通过/跳过；有失败项要判断是否本次修复引入，如实写进最终报告）"
fi

echo
if [[ "$NEXT" -gt "$MAX_ROUND" ]]; then
  warn "已达修复轮次上限 $MAX_ROUND，若回归扫描仍有漏洞，如实汇报并交用户决策，不要继续盲改"
fi
echo "下一步: 执行 scan-images.sh 做第 ${NEXT} 轮回归扫描（Bash timeout 600000）"
