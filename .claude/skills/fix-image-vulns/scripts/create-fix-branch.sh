#!/usr/bin/env bash
# 步骤 2a：基于基线分支创建修复分支（在当前工作区切过去，与 sync-upstream 的做法一致）。
#
# 用法: create-fix-branch.sh [分支名]     缺省 fix/cve-<UTC日期>
# 幂等：已在该分支上时直接复用（回归轮追加 commit 用这个）。
# 输出: BRANCH= / BASE=
# 退出码: 0=OK  1=失败（工作区不干净 / 基线分支领先 origin，需人工确认）

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state
[[ -n "${BASE_BRANCH:-}" ]] || die "状态中没有 BASE_BRANCH，请先执行 resolve-input.sh"

FIX_BRANCH="${1:-fix/cve-$(date -u +%Y%m%d)}"
CUR="$(git branch --show-current)"

# ---------- 已在修复分支上：幂等复用 ----------
if [[ "$CUR" == "$FIX_BRANCH" ]]; then
  info "已在修复分支 $FIX_BRANCH 上，直接复用"
else
  [[ -z "$(git status --porcelain)" ]] \
    || die "工作区有未提交改动，请先处理干净再建修复分支:
$(git status --short)"
  [[ "$CUR" == "$BASE_BRANCH" ]] \
    || die "当前在分支 $CUR，但状态里的基线分支是 $BASE_BRANCH。请切回去，或重新执行 resolve-input.sh 重设基线"

  # 基线领先 origin 时，基于它建分支会把未 push 的 commit 一并带进 PR
  if git fetch -q origin "refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH" 2>/dev/null; then
    AHEAD="$(git rev-list --count "refs/remotes/origin/$BASE_BRANCH..refs/heads/$BASE_BRANCH")"
    BEHIND="$(git rev-list --count "refs/heads/$BASE_BRANCH..refs/remotes/origin/$BASE_BRANCH")"
    [[ "$AHEAD" -gt 0 ]] && die "本地 $BASE_BRANCH 领先 origin $AHEAD 个 commit，基于它建修复分支会把这些未 push 的提交带进 PR。请先 push 或与用户确认后再重跑"
    if [[ "$BEHIND" -gt 0 ]]; then
      warn "本地 $BASE_BRANCH 落后 origin $BEHIND 个 commit，修复将基于本地旧基线（需要最新代码就先 git pull 再重跑 resolve-input.sh）"
    fi
  else
    warn "fetch origin/$BASE_BRANCH 失败，跳过领先/落后检查"
  fi

  if git rev-parse --verify --quiet "refs/heads/$FIX_BRANCH" >/dev/null; then
    warn "本地已存在分支 $FIX_BRANCH（上次中断？），直接检出复用其历史"
    git checkout -q "$FIX_BRANCH"
  else
    git checkout -q -b "$FIX_BRANCH" "refs/heads/$BASE_BRANCH"
  fi
fi

save_state FIX_BRANCH "$FIX_BRANCH"

echo
echo "BRANCH_READY"
echo "BRANCH=$FIX_BRANCH"
echo "BASE=$BASE_BRANCH（$(git rev-parse --short "refs/heads/$BASE_BRANCH")）"
echo "下一步: 按扫描给出的修复目标执行 update-go-version.sh / gomod-bump.sh"
