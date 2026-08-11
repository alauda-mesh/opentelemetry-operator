#!/usr/bin/env bash
# 步骤 2b：升级 alauda-release.yaml 里 setup-go 的 go-version（修 go stdlib 漏洞）。
#
# 用法: update-go-version.sh <X.Y.Z>    例: update-go-version.sh 1.26.7
#   版本格式与 setup-go 一致（不带 go 前缀）。只改值不 commit，便于 review diff。
#
# 为什么只改这一个文件：镜像里的 manager 二进制只由 alauda-release.yaml 构建，
# 它是全仓库唯一把 go-version 钉成精确版本的地方；社区 workflow 用的是 "~1.26.5"
# （自动取该 minor 的最新 patch），跟发布镜像无关，不要顺手改。
#
# 退出码: 0=OK  1=前置失败  2=go-version 行不唯一（结构变了，需用 Edit 手改）

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state

[[ $# -eq 1 ]] || die "用法: update-go-version.sh <X.Y.Z>（如 1.26.7，不带 go 前缀）"
V="$1"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "go-version 格式应为 X.Y.Z，收到: $V"
[[ -f "$WORKFLOW_FILE" ]] || die "缺少 $WORKFLOW_FILE"

N="$(grep -cE '^[[:space:]]*go-version:' "$WORKFLOW_FILE" || true)"
if [[ "$N" -ne 1 ]]; then
  echo "PATTERN_MISMATCH"
  echo "$WORKFLOW_FILE 中 go-version 行有 $N 处（预期恰好 1 处），请用 Edit 手动把 setup-go 的 go-version 改成 $V"
  exit 2
fi

OLD="$(extract_go_version "$WORKFLOW_FILE")"
if [[ "$OLD" == "$V" ]]; then
  echo "OK: $WORKFLOW_FILE 的 go-version 已经是 $V"
else
  sed -i -E "s|^([[:space:]]*)go-version:.*$|\1go-version: \"$V\"|" "$WORKFLOW_FILE"
  [[ "$(extract_go_version "$WORKFLOW_FILE")" == "$V" ]] \
    || die "$WORKFLOW_FILE 的 go-version 替换未生效，请用 Edit 手动修改"
  echo "OK: $WORKFLOW_FILE go-version: $OLD → $V"
fi

# minor 变化的影响面：go.mod 的 go directive 只是下限，用更高的 toolchain 编译没问题，
# 但发布镜像和社区 CI 会落在不同 minor 上，这属于需要人知道的事
GOMOD_GO="$(sed -n 's/^go \([0-9.]*\).*/\1/p' go.mod | head -1)"
OLD_MINOR="$(cut -d. -f1-2 <<<"${OLD:-0.0}")"
NEW_MINOR="$(cut -d. -f1-2 <<<"$V")"
echo
if [[ "$NEW_MINOR" == "$OLD_MINOR" ]]; then
  echo "GO_VERSION_UPDATED（同 minor $NEW_MINOR 内升 patch，影响面仅限发布镜像）"
else
  echo "CROSS_MINOR: go minor 从 $OLD_MINOR 升到了 $NEW_MINOR（go.mod 的 go directive 是 $GOMOD_GO）。"
  echo "  - go.mod 的 go directive 是版本下限，不必跟着改，但要确认 $NEW_MINOR 能正常编译（gomod-bump.sh 会验证）；"
  echo "  - 社区 workflow 仍钉在 \"~$OLD_MINOR.x\"，发布镜像与社区 CI 会落在不同 minor，属预期但要说明；"
  echo "  - 这是 go 大版本变更，必须在 PR 正文和最终报告里着重强调。"
fi
git diff --stat -- "$WORKFLOW_FILE" | tail -3
