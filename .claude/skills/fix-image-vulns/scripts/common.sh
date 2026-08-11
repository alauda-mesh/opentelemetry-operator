#!/usr/bin/env bash
# fix-image-vulns 公共函数与状态管理，供各步骤脚本 source 使用。
#
# 状态目录 .git/otel-op-fix-vulns/（在 .git/ 下，天然不入库、不被 make clean 波及）：
#   state.env          键值状态（ROUND、BASE_BRANCH、FIX_BRANCH、PR_NUMBER、RUN_ID ...）
#   images-roundN.tsv  第 N 轮待扫描镜像（轮次 / 来源 / 镜像地址）
#   scans/roundN/      扫描原始 JSON 与分类后的 TSV

set -euo pipefail

# 本仓库（ACP fork）。gh 一律显式 --repo，避免误推社区上游
REPO="${REPO:-alauda-mesh/opentelemetry-operator}"
# 构建镜像的流水线：workflow_dispatch 触发，PR 不会触发
WORKFLOW_ID="${WORKFLOW_ID:-alauda-release.yaml}"
WORKFLOW_NAME="${WORKFLOW_NAME:-Alauda Release workflow}"
WORKFLOW_FILE=".github/workflows/${WORKFLOW_ID}"
# 修复范围：只有 operator2 镜像里有 go 二进制；-bundle 只是 OLM 元数据镜像，无漏洞，不扫不修
FIX_IMAGE_REPO="${FIX_IMAGE_REPO:-opentelemetry-operator2}"
# 内网镜像扫描服务：主备两个地址（备用地址的服务容易故障），scan-images.sh 探测选用
SCAN_API_PRIMARY="${SCAN_API_PRIMARY:-http://192.168.141.42:8888}"
SCAN_API_BACKUP="${SCAN_API_BACKUP:-http://192.168.25.100:8888}"
# 修复轮次上限（首轮 + 回归后最多再修 2 次）
MAX_ROUND="${MAX_ROUND:-3}"

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }
info() { echo "INFO: $*" >&2; }

# 定位仓库根并 cd 过去，导出 STATE_DIR / STATE_FILE
repo_root() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "当前目录不在 git 仓库内"
  [[ -f "$root/$WORKFLOW_FILE" && -f "$root/versions.txt" ]] \
    || die "当前仓库不是 alauda-mesh/opentelemetry-operator（缺少 $WORKFLOW_FILE 或 versions.txt）"
  cd "$root"
  STATE_DIR="$(git rev-parse --absolute-git-dir)/otel-op-fix-vulns"
  STATE_FILE="$STATE_DIR/state.env"
  mkdir -p "$STATE_DIR"
}

# save_state KEY VALUE —— 幂等写入（先删同名 key）
save_state() {
  touch "$STATE_FILE"
  sed -i "/^${1}=/d" "$STATE_FILE"
  printf '%s=%s\n' "$1" "$2" >>"$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "未找到状态文件 $STATE_FILE，请先执行 resolve-input.sh"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  [[ -n "${ROUND:-}" ]] || die "状态文件内容不完整，请重新执行 resolve-input.sh"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "未安装 $1"; }

need_gh() {
  need_cmd gh
  gh auth status >/dev/null 2>&1 || die "gh 未认证，请提示用户执行: ! gh auth login"
}

# push / 建 PR / 触发流水线前的守卫：origin 必须是本 fork
origin_is_alauda() {
  local url
  url="$(git remote get-url origin 2>/dev/null || true)"
  [[ "$url" =~ github\.com[:/]${REPO}(\.git)?$ ]]
}

# 镜像地址 → 安全文件名
img_slug() { tr '/:@' '___' <<<"$1"; }

# 镜像地址 → 短仓库名（build-harbor.alauda.cn/asm/opentelemetry-operator2:0.156.0-rc.0 → opentelemetry-operator2）
img_repo() { local p="${1%%:*}"; echo "${p##*/}"; }

# 从 workflow 文件提取 setup-go 的 go-version（值可能带引号）
extract_go_version() { # extract_go_version <workflow文件>
  sed -n 's/^[[:space:]]*go-version:[[:space:]]*"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}.*$/\1/p' "$1" | head -1
}

# workflow_input_default <input名> [workflow文件]
# 读 workflow_dispatch 某个 input 的 default（去掉两端引号）。依赖固定缩进：
# input key 在 6 空格缩进，其属性在 8 空格缩进。
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

# 从一次 run 里提取产出镜像清单（每行一个）。
# 依赖 alauda-release.yaml 把镜像写进了 "Output images: <逗号分隔清单>" 这个 step 名，
# 比下载 job 日志快一个数量级；只取 conclusion=success 的 step，失败 run 里已推送的镜像照样能拿到。
extract_build_images() { # extract_build_images <run_id>
  gh run view "$1" --repo "$REPO" --json jobs --jq '
    [ .jobs[].steps[]
      | select(.conclusion == "success")
      | .name
      | select(startswith("Output images: "))
      | sub("^Output images: "; "")
      | split(",")[] ] | unique | .[]' 2>/dev/null || true
}

# 把镜像清单写成某一轮的 TSV，只保留待修复的 operator2 镜像；stdout 只输出 TSV 路径。
# 用法: tsv=$(write_round_images <轮次> <来源标记> <镜像...>)
write_round_images() {
  local n="$1" src="$2"; shift 2
  local tsv="$STATE_DIR/images-round${n}.tsv" img
  : >"$tsv"   # 重跑时整体重建，保持幂等
  for img in "$@"; do
    [[ -n "$img" ]] || continue
    if [[ "$(img_repo "$img")" == "$FIX_IMAGE_REPO" ]]; then
      printf '%s\t%s\t%s\n' "$n" "$src" "$img" >>"$tsv"
    else
      echo "  跳过（不在修复范围，bundle 为 OLM 元数据镜像、无 go 二进制）: $img" >&2
    fi
  done
  sort -u -o "$tsv" "$tsv"
  [[ -s "$tsv" ]] || die "没有找到任何 ${FIX_IMAGE_REPO} 镜像可扫描"
  echo "$tsv"
}
