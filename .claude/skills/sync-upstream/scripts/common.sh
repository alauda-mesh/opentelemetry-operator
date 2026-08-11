#!/usr/bin/env bash
# 公共函数与常量，供各步骤脚本 source 使用。

set -euo pipefail

# 本仓库（ACP fork）
REPO="${REPO:-alauda-mesh/opentelemetry-operator}"
# 上游 OpenTelemetry Operator
UPSTREAM_REPO="${UPSTREAM_REPO:-open-telemetry/opentelemetry-operator}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/${UPSTREAM_REPO}.git}"
# ACP 自己的 Collector 发行版：alauda-release 流水线 collector_tag 默认值的来源
COLLECTOR_REPO="${COLLECTOR_REPO:-alauda-mesh/alauda-opentelemetry-collector}"
# 发布流水线（workflow_dispatch 触发，不由 PR 触发）
WORKFLOW_ID="${WORKFLOW_ID:-alauda-release.yaml}"
WORKFLOW_FILE=".github/workflows/${WORKFLOW_ID}"
# ACP bundle 走 community 变体，openshift 变体只作为"上游都做了什么"的参照
# shellcheck disable=SC2034  # 由 csv-diff.sh 使用
CSV_COMMUNITY="bundle/community/manifests/opentelemetry-operator.clusterserviceversion.yaml"
# shellcheck disable=SC2034  # 由 csv-diff.sh 使用
CSV_OPENSHIFT="bundle/openshift/manifests/opentelemetry-operator.clusterserviceversion.yaml"
PATCH_FILE="alauda/alauda-csv.yaml"

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*"; }
info() { echo "INFO: $*"; }

# 定位仓库根目录并 cd 过去，同时导出 ROOT / WORK_DIR / STATE_FILE
repo_root() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "当前目录不在 git 仓库内"
  [[ -f "$root/versions.txt" && -f "$root/$PATCH_FILE" ]] \
    || die "当前仓库不是 alauda-mesh/opentelemetry-operator（缺少 versions.txt 或 $PATCH_FILE）"
  cd "$root"
  # shellcheck disable=SC2034  # 供各步骤脚本按需引用
  ROOT="$root"
  # 中间产物统一放在 .git/ 下：天然不入库，也不会被 make 的清理目标波及
  WORK_DIR="$(git rev-parse --absolute-git-dir)/otel-op-sync"
  mkdir -p "$WORK_DIR"
  STATE_FILE="$WORK_DIR/state.env"
}

# save_state KEY VALUE —— 幂等写入（先删同名 key）
save_state() {
  local key="$1" val="$2"
  touch "$STATE_FILE"
  sed -i "/^${key}=/d" "$STATE_FILE"
  printf '%s=%s\n' "$key" "$val" >>"$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "未找到状态文件 $STATE_FILE，请先执行 sync.sh"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  [[ -n "${TARGET_TAG:-}" ]] || die "状态文件内容不完整，请重新执行 sync.sh"
}

need_cmd() { command -v "$1" >/dev/null || die "未安装 $1"; }

need_gh() {
  need_cmd gh
  gh auth status >/dev/null 2>&1 || die "gh 未认证，请提示用户执行: ! gh auth login"
}

# 读 versions.txt 的 operator= 版本（ACP 当前基线版本的权威来源）
operator_version() { awk -F= '/^operator=/ { print $2; exit }' versions.txt; }

# workflow_input_default <input名> [workflow文件]
# 读 workflow_dispatch 某个 input 的 default 值（去掉两端引号）。
# 依赖固定缩进：input key 在 6 空格缩进，其属性在 8 空格缩进。
workflow_input_default() {
  local key="$1" file="${2:-$WORKFLOW_FILE}"
  awk -v key="$key" '
    $0 ~ "^      " key ":[[:space:]]*$" { ink = 1; next }
    ink && /^      [a-z_]+:[[:space:]]*$/ { ink = 0 }
    ink && $1 == "default:" { v = $2; gsub(/^"|"$/, "", v); print v; exit }
  ' "$file"
}

# 把字符串里的正则元字符转义，供 sed 的匹配部分使用
regex_escape() { printf '%s' "$1" | sed 's/[].[^$*\/&]/\\&/g'; }
