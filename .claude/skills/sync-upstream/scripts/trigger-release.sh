#!/usr/bin/env bash
# 步骤 6a：计算 Alauda Release 流水线参数并触发（workflow_dispatch）。
#
# rc 序号从历史 run 的 displayTitle 里推出来，格式固定为：
#   Release <release_version> (Operator <bundle_version>, Collector <collector_tag>)
#
# 用法:
#   trigger-release.sh --dry-run                        只计算参数并打印，不触发
#   trigger-release.sh                                  用计算出的参数触发
#   trigger-release.sh --release-version 2.0.0-rc.11 \  覆盖任意参数（未指定的仍按计算值）
#                      --bundle-version 0.156.0-rc.0 \
#                      --collector-tag 0.158.0-r0
#
# 退出码: 0=成功   1=前置条件失败

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state
need_gh

DRY_RUN=0
OVR_RELEASE=""; OVR_BUNDLE=""; OVR_COLLECTOR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)          DRY_RUN=1; shift ;;
    --release-version)  OVR_RELEASE="${2:?缺少值}"; shift 2 ;;
    --bundle-version)   OVR_BUNDLE="${2:?缺少值}"; shift 2 ;;
    --collector-tag)    OVR_COLLECTOR="${2:?缺少值}"; shift 2 ;;
    *) die "未知参数: $1" ;;
  esac
done

# ---------- 1. 读 workflow 默认值 ----------
RELEASE_BASE="$(workflow_input_default release_version)"
BUNDLE_BASE="$(workflow_input_default bundle_version)"
COLLECTOR_DEFAULT="$(workflow_input_default collector_tag)"
CHANNELS="$(workflow_input_default bundle_channels)"
[[ -n "$RELEASE_BASE" && -n "$BUNDLE_BASE" && -n "$COLLECTOR_DEFAULT" && -n "$CHANNELS" ]] \
  || die "无法从 $WORKFLOW_FILE 解析 workflow_dispatch 默认值"

if [[ "$BUNDLE_BASE" != "${NEW_VERSION}-r"* ]]; then
  warn "workflow 的 bundle_version 默认值是 $BUNDLE_BASE，与目标版本 $NEW_VERSION 对不上，请确认步骤 2 是否已执行"
fi

# ---------- 2. 从历史 run 推 rc 序号 ----------
TITLES="$(gh run list --workflow="$WORKFLOW_ID" --repo "$REPO" --limit 200 \
  --json displayTitle -q '.[].displayTitle' 2>/dev/null || true)"
[[ -n "$TITLES" ]] || warn "未取到历史 run 记录，rc 序号将从 0 开始"

# next_rc <字面量前缀>：在标题里找 "<前缀><数字>"，返回最大值 + 1；没有历史则返回 0
next_rc() {
  local prefix esc max
  prefix="$1"
  esc="$(regex_escape "$prefix")"
  max="$(printf '%s\n' "$TITLES" | sed -n "s/.*${esc}\([0-9][0-9]*\).*/\1/p" | sort -n | tail -1)"
  if [[ -z "$max" ]]; then echo 0; else echo $((max + 1)); fi
}

RELEASE_VERSION="${OVR_RELEASE:-${RELEASE_BASE}-rc.$(next_rc "Release ${RELEASE_BASE}-rc.")}"
BUNDLE_VERSION="${OVR_BUNDLE:-${NEW_VERSION}-rc.$(next_rc "Operator ${NEW_VERSION}-rc.")}"
COLLECTOR_TAG="${OVR_COLLECTOR:-$COLLECTOR_DEFAULT}"

echo "=== 计算出的流水线参数 ==="
printf '  %-18s %s\n' "release_version"  "$RELEASE_VERSION"
printf '  %-18s %s\n' "bundle_version"   "$BUNDLE_VERSION"
printf '  %-18s %s\n' "collector_tag"    "$COLLECTOR_TAG"
printf '  %-18s %s\n' "bundle_channels"  "$CHANNELS"
printf '  %-18s %s\n' "is_draft_release" "true"
printf '  %-18s %s\n' "is_pre_release"   "false"
printf '  %-18s %s\n' "ref(分支)"        "$SYNC_BRANCH"
echo "  run 标题将是: Release ${RELEASE_VERSION} (Operator ${BUNDLE_VERSION}, Collector ${COLLECTOR_TAG})"
echo
echo "--- 最近 5 次历史 run ---"
printf '%s\n' "$TITLES" | head -5 | sed 's/^/  /'

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "DRY_RUN_OK（未触发）"
  echo "确认后执行: bash \"\$SKILL_DIR/scripts/trigger-release.sh\""
  exit 0
fi

# ---------- 3. 触发 ----------
git ls-remote --exit-code --heads origin "$SYNC_BRANCH" >/dev/null 2>&1 \
  || die "远端没有分支 $SYNC_BRANCH，请先执行 create-pr.sh（workflow_dispatch 需要分支已存在于远端）"

BEFORE_ID="$(gh run list --workflow="$WORKFLOW_ID" --repo "$REPO" --limit 1 \
  --json databaseId -q '.[0].databaseId' 2>/dev/null || echo 0)"
# 没有历史 run 时 gh 会返回字面量 null，后面的数值比较会炸，统一归零
[[ "$BEFORE_ID" =~ ^[0-9]+$ ]] || BEFORE_ID=0

info "触发 $WORKFLOW_ID on $SYNC_BRANCH ..."
gh workflow run "$WORKFLOW_ID" \
  --repo "$REPO" \
  --ref "$SYNC_BRANCH" \
  --field release_version="$RELEASE_VERSION" \
  --field bundle_channels="$CHANNELS" \
  --field bundle_version="$BUNDLE_VERSION" \
  --field collector_tag="$COLLECTOR_TAG" \
  --field is_draft_release=true \
  --field is_pre_release=false

# workflow_dispatch 到 run 出现有几秒延迟，轮询等它出来
RUN_ID=""
for _ in $(seq 1 20); do
  sleep 5
  CAND="$(gh run list --workflow="$WORKFLOW_ID" --repo "$REPO" --limit 5 \
    --json databaseId,headBranch -q \
    "[.[] | select(.headBranch == \"${SYNC_BRANCH}\")] | sort_by(.databaseId) | last | .databaseId" 2>/dev/null || true)"
  if [[ -n "$CAND" && "$CAND" != "null" && "$CAND" -gt "$BEFORE_ID" ]]; then
    RUN_ID="$CAND"
    break
  fi
  echo "  等待 run 出现 ..."
done

if [[ -z "$RUN_ID" ]]; then
  echo "WARN: 已触发但未查询到新的 run，请手动确认："
  echo "  gh run list --workflow=$WORKFLOW_ID --repo $REPO --limit 5"
  exit 0
fi

RUN_URL="$(gh run view "$RUN_ID" --repo "$REPO" --json url -q .url)"
save_state RUN_ID "$RUN_ID"
save_state RELEASE_VERSION "$RELEASE_VERSION"
save_state BUNDLE_VERSION "$BUNDLE_VERSION"
save_state COLLECTOR_TAG "$COLLECTOR_TAG"

echo
echo "TRIGGERED"
echo "RUN_ID=$RUN_ID"
echo "RUN_URL=$RUN_URL"
echo "下一步: 后台运行 watch-release.sh 监控流水线"
