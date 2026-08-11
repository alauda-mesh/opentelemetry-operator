#!/usr/bin/env bash
# 步骤 2：更新 .github/workflows/alauda-release.yaml 的 workflow_dispatch 默认参数。
#   - bundle_version  -> <目标版本>-r0
#   - collector_tag   -> alauda-mesh/alauda-opentelemetry-collector 最新的 v*-r* tag（去掉 v 前缀）
# 不自动 commit，便于人工 review diff。
#
# 用法: update-defaults.sh [--dry-run]
# 退出码: 0=OK   1=前置条件失败   2=PATTERN_MISMATCH（改写后校验不通过，需人工 Edit）

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=1; fi
[[ -f "$WORKFLOW_FILE" ]] || die "找不到 $WORKFLOW_FILE"

# set_workflow_default <input名> <新值>：改写 workflow_dispatch 里该 input 的 default 行
set_workflow_default() {
  local key="$1" newval="$2"
  awk -v key="$key" -v newval="$newval" '
    $0 ~ "^      " key ":[[:space:]]*$" { ink = 1; print; next }
    ink && /^      [a-z_]+:[[:space:]]*$/ { ink = 0 }
    ink && $1 == "default:" {
      match($0, /^[ \t]*/); indent = substr($0, 1, RLENGTH)
      print indent "default: \"" newval "\""
      ink = 0
      next
    }
    { print }
  ' "$WORKFLOW_FILE" >"$WORKFLOW_FILE.tmp"
  mv "$WORKFLOW_FILE.tmp" "$WORKFLOW_FILE"
}

OLD_BUNDLE="$(workflow_input_default bundle_version)"
OLD_COLLECTOR="$(workflow_input_default collector_tag)"
[[ -n "$OLD_BUNDLE" && -n "$OLD_COLLECTOR" ]] \
  || die "无法从 $WORKFLOW_FILE 解析 bundle_version / collector_tag 的 default，workflow 结构可能已变化，请人工 Edit"

# ---------- 1. bundle_version ----------
NEW_BUNDLE="${NEW_VERSION}-r0"

# ---------- 2. collector_tag ----------
# ACP Collector 的 tag 形如 v0.158.0-r0；workflow 里不带 v 前缀，取值时要去掉。
NEW_COLLECTOR="$OLD_COLLECTOR"
COLLECTOR_NOTE="保持原值"
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  ALL_TAGS="$(gh api "repos/${COLLECTOR_REPO}/tags?per_page=100" -q '.[].name' 2>/dev/null \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$' | sort -V || true)"
  LATEST_TAG="$(printf '%s\n' "$ALL_TAGS" | tail -1)"
  if [[ -n "$LATEST_TAG" ]]; then
    NEW_COLLECTOR="${LATEST_TAG#v}"
    COLLECTOR_NOTE="取自 ${COLLECTOR_REPO} 最新 tag ${LATEST_TAG}"
    echo "--- ${COLLECTOR_REPO} 最近的 v*-r* tag（新 -> 旧）---"
    printf '%s\n' "$ALL_TAGS" | tac | head -5 | sed 's/^/  /'
  else
    warn "在 ${COLLECTOR_REPO} 未找到形如 v*-r* 的 tag，collector_tag 保持原值 ${OLD_COLLECTOR}"
  fi
else
  warn "gh 不可用或未认证，collector_tag 保持原值 ${OLD_COLLECTOR}"
  warn "请手动查看 https://github.com/${COLLECTOR_REPO}/tags 后用 Edit 修改"
fi

# ---------- 3. 汇报与改写 ----------
echo
echo "=== 计划改写 $WORKFLOW_FILE ==="
printf '  %-16s %s -> %s\n' "bundle_version"  "$OLD_BUNDLE"    "$NEW_BUNDLE"
printf '  %-16s %s -> %s   (%s)\n' "collector_tag" "$OLD_COLLECTOR" "$NEW_COLLECTOR" "$COLLECTOR_NOTE"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "DRY_RUN_OK（未修改任何文件）"
  exit 0
fi

if [[ "$OLD_BUNDLE" != "$NEW_BUNDLE" ]]; then set_workflow_default bundle_version "$NEW_BUNDLE"; fi
if [[ "$OLD_COLLECTOR" != "$NEW_COLLECTOR" ]]; then set_workflow_default collector_tag "$NEW_COLLECTOR"; fi

# ---------- 4. 回读校验 ----------
GOT_BUNDLE="$(workflow_input_default bundle_version)"
GOT_COLLECTOR="$(workflow_input_default collector_tag)"
FAIL=0
[[ "$GOT_BUNDLE" == "$NEW_BUNDLE" ]] || { echo "FAIL: bundle_version 期望 $NEW_BUNDLE，实际 $GOT_BUNDLE"; FAIL=1; }
[[ "$GOT_COLLECTOR" == "$NEW_COLLECTOR" ]] || { echo "FAIL: collector_tag 期望 $NEW_COLLECTOR，实际 $GOT_COLLECTOR"; FAIL=1; }

echo
echo "--- git diff $WORKFLOW_FILE ---"
git --no-pager diff -- "$WORKFLOW_FILE" | sed 's/^/  /'

if [[ "$FAIL" -eq 1 ]]; then
  echo
  echo "PATTERN_MISMATCH"
  echo "改写未达预期，请用 Edit 手动修正上面 FAIL 的项（其余已完成的项不要重复改）。"
  exit 2
fi

save_state BUNDLE_DEFAULT "$NEW_BUNDLE"
save_state COLLECTOR_TAG "$NEW_COLLECTOR"

echo
echo "DEFAULTS_UPDATED"
echo "下一步: 后台运行 verify.sh 做本地校验，同时并行执行 csv-diff.sh 做 CSV 差异分析"
