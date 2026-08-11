#!/usr/bin/env bash
# 步骤 1a：解析输入（流水线 run 或镜像地址）→ 第 1 轮待扫描镜像清单，初始化任务状态。
#
# 用法: resolve-input.sh <RUN_ID|run URL|镜像地址> ...
#   - RUN_ID / run URL：只接受 "Alauda Release workflow" 的 run，从其
#     "Output images: <清单>" step 名提取镜像（比下载日志快很多）；
#   - 镜像地址（形如 build-harbor.alauda.cn/asm/opentelemetry-operator2:0.156.0-rc.0）：直接纳入。
#   两类可混用，多个输入取并集去重；只保留 opentelemetry-operator2，-bundle 及其他一律跳过。
#
# 修复基线 = 当前检出分支（记入状态，create-fix-branch.sh 使用）。
# 退出码: 0=OK  1=失败

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
need_cmd jq

[[ $# -ge 1 ]] || die "用法: resolve-input.sh <RUN_ID|run URL|镜像地址> ..."

# ---------- 参数分流 ----------
RUNS=(); IMAGES=()
for arg in "$@"; do
  if [[ "$arg" =~ /runs/([0-9]+) ]]; then
    RUNS+=("${BASH_REMATCH[1]}")
  elif [[ "$arg" =~ ^[0-9]+$ ]]; then
    RUNS+=("$arg")
  elif [[ "$arg" == */*:* ]]; then
    IMAGES+=("$arg")
  else
    die "无法识别的参数: $arg（应为 run ID、run URL 或带 tag 的完整镜像地址）"
  fi
done
if [[ ${#RUNS[@]} -gt 0 ]]; then need_gh; fi

# ---------- 修复基线 = 当前检出分支 ----------
BASE_BRANCH="$(git branch --show-current)"
[[ -n "$BASE_BRANCH" ]] || die "当前处于 detached HEAD，请先检出一个分支（通常是 main）再重跑"

# ---------- 残留上次任务状态：清掉，重新开始 ----------
if [[ -f "$STATE_FILE" ]]; then
  info "清理上次任务的状态目录: $STATE_DIR"
  rm -rf "$STATE_DIR" && mkdir -p "$STATE_DIR"
fi

# ---------- run → 镜像 ----------
for id in "${RUNS[@]}"; do
  META="$(gh run view "$id" --repo "$REPO" --json workflowName,status,conclusion,displayTitle,headBranch)" \
    || die "读取 run $id 失败（--repo $REPO）"
  WF="$(jq -r .workflowName <<<"$META")"
  [[ "$WF" == "$WORKFLOW_NAME" ]] \
    || die "run $id 属于工作流「$WF」，本 skill 只处理「$WORKFLOW_NAME」"
  ST="$(jq -r .status <<<"$META")"; CC="$(jq -r .conclusion <<<"$META")"
  [[ "$ST" == "completed" ]] || die "run $id 尚未完成（status=$ST），等它跑完再重跑"
  # 镜像推送成功但后续 step（如创建 release）失败时 run 整体是 failure，
  # 镜像本身仍然有效，所以这里只告警不终止
  [[ "$CC" == "success" ]] || warn "run $id 整体结论是 $CC，但只要镜像已推送就仍可扫描，继续"

  # 镜像是从 run 所在分支的代码构建的；基线分支与它不一致时，修复的源码和被扫的镜像可能对不上
  RUN_BRANCH="$(jq -r .headBranch <<<"$META")"
  [[ "$RUN_BRANCH" == "$BASE_BRANCH" ]] \
    || warn "run $id 构建自分支 $RUN_BRANCH，而修复基线是当前分支 $BASE_BRANCH。
若 $RUN_BRANCH 的改动尚未合进 $BASE_BRANCH，修复的源码与被扫镜像不是同一份，请与用户确认基线是否正确"

  echo "run $id [$(jq -r .displayTitle <<<"$META")] @ $RUN_BRANCH 产出镜像:"
  FOUND=0
  while IFS= read -r img; do
    [[ -n "$img" ]] || continue
    echo "    $img"
    IMAGES+=("$img")
    FOUND=1
  done < <(extract_build_images "$id")
  [[ "$FOUND" -eq 1 ]] || die "run $id 里没有成功的 'Output images: ...' step，说明镜像未推送，无可扫描对象"
done

# ---------- 写第 1 轮清单 ----------
IMG_TSV="$(write_round_images 1 "input" "${IMAGES[@]}")"

save_state ROUND 1
save_state BASE_BRANCH "$BASE_BRANCH"

echo
echo "INPUT_RESOLVED"
echo "修复基线分支: $BASE_BRANCH"
echo "第 1 轮待扫描镜像:"
awk -F'\t' '{printf "  %s\n", $3}' "$IMG_TSV"
echo "下一步: 执行 scan-images.sh 扫描（Bash timeout 设 600000）"
