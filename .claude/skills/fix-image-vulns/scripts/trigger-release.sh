#!/usr/bin/env bash
# 步骤 4a：在修复分支上触发 Alauda Release 流水线（workflow_dispatch），产出待回归扫描的新镜像。
#
# PR 本身不会触发任何构建，所以建完 PR 必须显式触发一次。参数取自 workflow_dispatch
# 的 default，rc 序号从历史 run 的 displayTitle 推出来，标题格式固定为：
#   Release <release_version> (Operator <bundle_version>, Collector <collector_tag>)
#
# rc 序号必须每轮递增，有两个硬性理由：
#   1. bundle_version 决定镜像 tag，序号不变就会覆盖同名 tag，回归扫描可能扫到旧镜像；
#   2. release_version 会被 gh release create 当成 tag 名，重复会直接失败。
#
# 用法:
#   trigger-release.sh --dry-run                          只算参数并打印，不触发
#   trigger-release.sh                                    用算出的参数触发
#   trigger-release.sh --bundle-version 0.156.0-rc.3 ...  覆盖任意参数
#
# 退出码: 0=成功  1=前置条件失败

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state
need_gh
[[ -n "${FIX_BRANCH:-}" ]] || die "状态中没有 FIX_BRANCH，请先执行 create-fix-branch.sh"
origin_is_alauda || die "origin 不是 $REPO，拒绝触发流水线"

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
BUNDLE_DEFAULT="$(workflow_input_default bundle_version)"
COLLECTOR_DEFAULT="$(workflow_input_default collector_tag)"
CHANNELS="$(workflow_input_default bundle_channels)"
[[ -n "$RELEASE_BASE" && -n "$BUNDLE_DEFAULT" && -n "$COLLECTOR_DEFAULT" && -n "$CHANNELS" ]] \
  || die "无法从 $WORKFLOW_FILE 解析 workflow_dispatch 默认值"
# 默认值形如 0.156.0-r0 / 0.156.0-rc.2，剥掉后缀得到版本基线 0.156.0
BUNDLE_BASE="$(sed -E 's/-r(c\.)?[0-9]+$//' <<<"$BUNDLE_DEFAULT")"

# ---------- 2. 从历史 run 标题推 rc 序号 ----------
TITLES="$(gh run list --workflow="$WORKFLOW_ID" --repo "$REPO" --limit 200 \
  --json displayTitle -q '.[].displayTitle' 2>/dev/null || true)"
[[ -n "$TITLES" ]] || warn "未取到历史 run 记录，rc 序号将从 0 开始"

# next_rc <字面量前缀>：在历史标题里找 "<前缀><数字>"，返回最大值 + 1
next_rc() {
  local esc max
  esc="$(regex_escape "$1")"
  max="$(printf '%s\n' "$TITLES" | sed -n "s/.*${esc}\([0-9][0-9]*\).*/\1/p" | sort -n | tail -1)"
  if [[ -z "$max" ]]; then echo 0; else echo $((max + 1)); fi
}

RELEASE_VERSION="${OVR_RELEASE:-${RELEASE_BASE}-rc.$(next_rc "Release ${RELEASE_BASE}-rc.")}"
BUNDLE_VERSION="${OVR_BUNDLE:-${BUNDLE_BASE}-rc.$(next_rc "Operator ${BUNDLE_BASE}-rc.")}"
COLLECTOR_TAG="${OVR_COLLECTOR:-$COLLECTOR_DEFAULT}"

echo "=== 本次流水线参数（第 ${ROUND} 轮验证构建）==="
printf '  %-18s %s\n' "ref(分支)"        "$FIX_BRANCH"
printf '  %-18s %s\n' "release_version"  "$RELEASE_VERSION"
printf '  %-18s %s\n' "bundle_version"   "$BUNDLE_VERSION"
printf '  %-18s %s\n' "collector_tag"    "$COLLECTOR_TAG"
printf '  %-18s %s\n' "bundle_channels"  "$CHANNELS"
printf '  %-18s %s\n' "is_draft_release" "true"
printf '  %-18s %s\n' "is_pre_release"   "false"
echo "  回归扫描将扫: build-harbor.alauda.cn/asm/${FIX_IMAGE_REPO}:${BUNDLE_VERSION}"
echo "  副作用: 会新建一个 draft GitHub Release（tag ${RELEASE_VERSION}）；draft 在 publish 前不会真的打 tag，"
echo "          但会留在 releases 列表里，最终汇报要列出来让用户决定是否清理。"
echo
echo "--- 最近 5 次历史 run ---"
printf '%s\n' "$TITLES" | head -5 | sed 's/^/  /'

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "DRY_RUN_OK（未触发）"
  echo "与用户确认后执行: bash \"\$SKILL_DIR/scripts/trigger-release.sh\""
  exit 0
fi

# ---------- 3. 触发 ----------
git ls-remote --exit-code --heads origin "$FIX_BRANCH" >/dev/null 2>&1 \
  || die "远端没有分支 $FIX_BRANCH，请先执行 create-pr.sh（workflow_dispatch 要求分支已存在于远端）"

BEFORE_ID="$(gh run list --workflow="$WORKFLOW_ID" --repo "$REPO" --limit 1 \
  --json databaseId -q '.[0].databaseId' 2>/dev/null || echo 0)"
[[ "$BEFORE_ID" =~ ^[0-9]+$ ]] || BEFORE_ID=0   # 没有历史 run 时 gh 返回字面量 null

info "触发 $WORKFLOW_ID on $FIX_BRANCH ..."
gh workflow run "$WORKFLOW_ID" \
  --repo "$REPO" \
  --ref "$FIX_BRANCH" \
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
    "[.[] | select(.headBranch == \"${FIX_BRANCH}\")] | sort_by(.databaseId) | last | .databaseId" 2>/dev/null || true)"
  if [[ -n "$CAND" && "$CAND" != "null" && "$CAND" -gt "$BEFORE_ID" ]]; then
    RUN_ID="$CAND"; break
  fi
  echo "  等待 run 出现 ..."
done

if [[ -z "$RUN_ID" ]]; then
  echo "WARN: 已触发但未查询到新的 run，请手动确认:"
  echo "  gh run list --workflow=$WORKFLOW_ID --repo $REPO --limit 5"
  exit 0
fi

save_state RUN_ID "$RUN_ID"
save_state RELEASE_VERSION "$RELEASE_VERSION"
save_state BUNDLE_VERSION "$BUNDLE_VERSION"

echo
echo "TRIGGERED"
echo "RUN_ID=$RUN_ID"
echo "RUN_URL=https://github.com/$REPO/actions/runs/$RUN_ID"
echo "下一步: 后台运行 watch-release.sh 监控流水线（Bash 的 run_in_background: true）"
