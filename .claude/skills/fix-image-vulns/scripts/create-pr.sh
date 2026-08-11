#!/usr/bin/env bash
# 步骤 3：push 修复分支并创建 PR（base = 基线分支，--repo 固定本 fork，不会推社区上游）。
#
# 用法: create-pr.sh <PR正文文件>
# 幂等：分支已有 open PR 时复用（回归轮追加 commit 后重跑即可，只 push 不重复建 PR）。
# 输出: PR_NUMBER= / PR_URL=
# 环境变量: TITLE 覆盖默认 PR 标题
# 退出码: 0=成功  1=前置条件失败

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state
need_gh

BODY_FILE="${1:-}"
[[ -n "$BODY_FILE" && -f "$BODY_FILE" ]] || die "用法: create-pr.sh <PR正文文件>（文件必须存在，先把正文写好）"
[[ -n "${FIX_BRANCH:-}" ]] || die "状态中没有 FIX_BRANCH，请先执行 create-fix-branch.sh"
origin_is_alauda || die "origin 不是 $REPO，拒绝 push / 建 PR（防止误推社区上游）"

CUR="$(git branch --show-current)"
[[ "$CUR" == "$FIX_BRANCH" ]] || die "当前分支是 $CUR，应在 $FIX_BRANCH 上执行"
[[ -z "$(git status --porcelain)" ]] \
  || die "有未提交的修改，请先 commit（禁止 amend，一律新建 commit）:
$(git status --short)"

git fetch -q origin "refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH" 2>/dev/null || true
AHEAD="$(git rev-list --count "refs/remotes/origin/$BASE_BRANCH..HEAD")"
[[ "$AHEAD" -ge 1 ]] || die "相对 origin/$BASE_BRANCH 没有新提交，没有内容可提 PR"
info "本次 PR 包含 $AHEAD 个提交"

info "push $FIX_BRANCH 到 origin ..."
git push -u origin "$FIX_BRANCH"

PR_NUMBER="$(gh pr list --repo "$REPO" --head "$FIX_BRANCH" --state open --json number -q '.[0].number' 2>/dev/null || true)"
if [[ -n "$PR_NUMBER" ]]; then
  info "分支已有 open PR #$PR_NUMBER，复用"
else
  gh pr create --repo "$REPO" --base "$BASE_BRANCH" --head "$FIX_BRANCH" \
    --title "${TITLE:-fix(deps): fix CVEs in opentelemetry-operator2 image ($(date -u +%Y-%m-%d))}" \
    --body-file "$BODY_FILE" >/dev/null || die "创建 PR 失败"
  PR_NUMBER="$(gh pr list --repo "$REPO" --head "$FIX_BRANCH" --state open --json number -q '.[0].number')"
fi
[[ -n "$PR_NUMBER" ]] || die "PR 创建后未能查询到编号，请用 gh pr list --repo $REPO 排查"

PR_URL="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json url -q .url)"
save_state PR_NUMBER "$PR_NUMBER"

echo
echo "PR_NUMBER=$PR_NUMBER"
echo "PR_URL=$PR_URL"
echo "下一步: trigger-release.sh --dry-run 算流水线参数，与用户确认后再正式触发"
