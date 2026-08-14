#!/usr/bin/env bash
# 步骤 1：基于 origin/main 创建 upgrade/<tag> 分支，并 merge 上游 tag。
#
# 用法: sync.sh <上游tag>
#   例: sync.sh v0.156.0
#
# 退出码: 0=MERGED   1=前置条件失败   2=CONFLICT

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root

TAG="${1:-}"
[[ -n "$TAG" ]] || die "用法: sync.sh <上游tag>，例如: sync.sh v0.156.0"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "tag 格式应为 vX.Y.Z（如 v0.156.0），收到: $TAG"

need_cmd git
NEW_VERSION="${TAG#v}"

# ---------- 1. 前置检查 ----------
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "工作区有未提交的修改，请先处理（禁止 amend，可 commit 或 stash）"
fi

if ! git remote get-url upstream >/dev/null 2>&1; then
  info "未找到 upstream remote，自动添加: $UPSTREAM_URL"
  git remote add upstream "$UPSTREAM_URL"
fi

info "git fetch upstream --tags / origin --prune ..."
git fetch upstream --tags --quiet
git fetch origin --prune --quiet

if ! git rev-parse -q --verify "refs/tags/${TAG}^{commit}" >/dev/null; then
  echo "ERROR: 上游没有 tag ${TAG}" >&2
  echo "最近的上游正式 tag：" >&2
  git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -8 | sed 's/^/  /' >&2
  exit 1
fi

SYNC_BRANCH="upgrade/${TAG}"
if git show-ref --verify --quiet "refs/heads/${SYNC_BRANCH}"; then
  die "本地已存在分支 ${SYNC_BRANCH}，请确认是否为上次未完成的同步（切过去继续，或删除后重跑）"
fi
if git show-ref --verify --quiet "refs/remotes/origin/${SYNC_BRANCH}"; then
  die "远端已存在分支 ${SYNC_BRANCH}，请先确认其 PR 状态，不要重复创建"
fi
git rev-parse --verify --quiet origin/main >/dev/null || die "找不到 origin/main"

# ---------- 2. 建分支 ----------
git switch -c "$SYNC_BRANCH" origin/main --quiet
BASE_COMMIT="$(git rev-parse --short HEAD)"
info "已基于 origin/main ($BASE_COMMIT) 创建分支 $SYNC_BRANCH"

# 版本必须在切分支之后、merge 之前读：本地 main 可能落后于 origin/main，
# merge 之后 versions.txt 又会被上游覆盖成新版本，两个时机都拿不到真正的基线版本。
OLD_VERSION="$(operator_version)"
[[ -n "$OLD_VERSION" ]] || die "无法从 versions.txt 解析 operator= 版本"
OLD_TAG="v${OLD_VERSION}"
echo "当前基线版本: $OLD_VERSION (tag $OLD_TAG)"
echo "目标版本:     $NEW_VERSION (tag $TAG)"
if [[ "$OLD_VERSION" == "$NEW_VERSION" ]]; then
  warn "当前已是目标版本，merge 大概率无内容变化，请确认是否真的需要本次同步"
fi
if ! git rev-parse -q --verify "refs/tags/${OLD_TAG}^{commit}" >/dev/null; then
  warn "本地没有基线 tag ${OLD_TAG}，步骤 4 的跨版本 CSV 对比会缺少一侧数据"
fi

save_state TARGET_TAG "$TAG"
save_state NEW_VERSION "$NEW_VERSION"
save_state OLD_VERSION "$OLD_VERSION"
save_state OLD_TAG "$OLD_TAG"
save_state SYNC_BRANCH "$SYNC_BRANCH"
save_state BASE_COMMIT "$BASE_COMMIT"

# ---------- 3. merge ----------
info "git merge $TAG ..."
if git merge "$TAG" --no-edit >"$WORK_DIR/merge.log" 2>&1; then
  MERGE_OK=1
else
  MERGE_OK=0
fi
sed 's/^/  /' "$WORK_DIR/merge.log"

if [[ "$MERGE_OK" -eq 0 ]]; then
  CONFLICTS="$(git diff --name-only --diff-filter=U || true)"
  echo
  echo "CONFLICT"
  echo "冲突文件："
  printf '%s\n' "$CONFLICTS" | sed 's/^/  /'
  echo
  echo "提示：已知的冲突只有三类，按 SKILL.md 步骤 1 处理，不必问用户："
  echo "      1) Makefile / .gitignore —— 「两边都要」，保留 ACP 新增行的同时合入上游新增行；"
  echo "      2) go.mod / go.sum（含 apis/、cmd/otel-allocator/integrationtest/ 子模块）——"
  echo "         成因是 ACP 修 CVE 时 bump 过依赖。比版本号高低：上游更高就取上游（git checkout --theirs"
  echo "         + git add），上游更低必须保留 ACP 版本，否则漏洞会被放回去；go.sum 别手工解，跑 make tidy 重建；"
  echo "      3) 以上都不是的文件 —— 定制面变了，停下来问用户。"
  echo "      解决后用 git add <文件> && git commit --no-edit 完成合并（禁止 amend），再继续步骤 2。"
  exit 2
fi

# ---------- 4. 汇报 ----------
MERGED_VERSION="$(operator_version)"
if [[ "$MERGED_VERSION" != "$NEW_VERSION" ]]; then
  warn "merge 后 versions.txt 的 operator=$MERGED_VERSION，与目标 $NEW_VERSION 不一致，请检查"
fi

COMMITS="$(git rev-list --count "${BASE_COMMIT}..HEAD")"
echo
echo "=== 合并概览 ==="
echo "合入提交数: $COMMITS"
echo "总体: $(git --no-pager diff --shortstat "$BASE_COMMIT" HEAD)"
echo "--- 改动最多的 15 个文件 ---"
# --numstat 的前两列是增/删行数，便于按改动量排序（--stat 的图形化输出没法可靠排序）
git --no-pager diff --numstat "$BASE_COMMIT" HEAD \
  | sort -k1 -rn | head -15 \
  | awk '{ printf "  +%-6s -%-6s %s\n", $1, $2, $3 }'
echo "--- versions.txt 变化 ---"
VERS_DIFF="$(git --no-pager diff "$BASE_COMMIT" HEAD -- versions.txt | grep -E '^[+-][a-z]' || true)"
if [[ -n "$VERS_DIFF" ]]; then printf '%s\n' "$VERS_DIFF" | sed 's/^/  /'; else echo "  (无变化)"; fi

echo
echo "MERGED"
echo "分支: $SYNC_BRANCH（基于 origin/main $BASE_COMMIT）"
echo "版本: $OLD_VERSION -> $MERGED_VERSION"
echo "下一步: update-defaults.sh 更新 alauda-release 流水线默认参数"
