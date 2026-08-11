#!/usr/bin/env bash
# 步骤 3：本地轻量校验（编译 + 生成物一致性 + CSV patch 逻辑）。
# 首次运行会下载 controller-gen / kustomize / operator-sdk 等工具并拉 Go 依赖，
# 通常 5~15 分钟，必须用 Bash 工具的 run_in_background: true 后台运行。
#
# 用法:
#   verify.sh                跑全部三项检查
#   verify.sh --patch-only   只跑 make alauda-patch 那一项（几秒钟）。
#                            步骤 4 改完 alauda-csv.yaml / alauda-patch.sh 后复验用，不必重跑整套。
#
# 退出码: 0=VERIFY_OK   1=前置条件失败   2=VERIFY_FAILED

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state

PATCH_ONLY=0
if [[ "${1:-}" == "--patch-only" ]]; then PATCH_ONLY=1; fi
[[ "$PATCH_ONLY" -eq 1 ]] || need_cmd go

LOG="$WORK_DIR/verify.log"
: >"$LOG"
echo "日志: $LOG"

# step <说明> <命令...>
step() {
  local name="$1"; shift
  echo "=== $name ===" >>"$LOG"
  echo "[$(date +%H:%M:%S)] 开始: $name"
  if "$@" >>"$LOG" 2>&1; then
    echo "[$(date +%H:%M:%S)]   OK: $name"
    return 0
  fi
  echo "[$(date +%H:%M:%S)]   FAILED: $name"
  return 1
}

dump_log() {
  echo
  echo "--- 错误相关行 ---"
  grep -inE "error|cannot|undefined|failed|no such|not up to date" "$LOG" | tail -25 || true
  echo "--- 日志末尾 ---"
  tail -30 "$LOG"
  echo
  echo "完整日志: $LOG"
}

if [[ "$PATCH_ONLY" -eq 0 ]]; then
  # 1. 编译 operator 二进制：merge 引入的源码不兼容会在这里暴露
  if ! step "make manager（编译 operator）" make manager; then
    echo
    echo "VERIFY_FAILED"
    echo "阶段: make manager（编译失败）"
    dump_log
    exit 2
  fi

  # 2. 生成物一致性：API 类型与 zz_generated / bundle / config / docs/api 必须对得上。
  #    上游 tag 自身一定是自洽的，这里真正拦的是「合并冲突解错了」。
  if ! step "make ensure-update-is-noop（生成物一致性）" make ensure-update-is-noop; then
    echo
    echo "VERIFY_FAILED"
    echo "阶段: make ensure-update-is-noop（生成物与源码不一致）"
    dump_log
    echo
    echo "常见成因: 合并冲突在 apis/ 或 config/ 解错了。"
    echo "处理: 先看上面提示的目录，用 make update 重新生成后确认 diff 合理，再作为新 commit 提交。"
    exit 2
  fi
else
  info "--patch-only：跳过 make manager 与 make ensure-update-is-noop"
fi

# 3. CSV patch 逻辑校验：hack/alauda-patch.sh 里写死了 bundle 路径与 yq 表达式，
#    上游一旦改动 bundle 布局或 CSV 结构，这里会先炸——否则要等 20 分钟后流水线才暴露。
#    会临时改写 bundle/community/，跑完立刻还原。
PATCH_CHECK="SKIPPED"
if ! command -v yq >/dev/null; then
  info "未安装 yq，跳过 CSV patch 校验（流水线上会执行）"
elif [[ -n "$(git status --porcelain bundle/ || true)" ]]; then
  warn "bundle/ 有未提交改动，跳过 CSV patch 校验（避免还原时误删你的改动）"
elif step "make alauda-patch（CSV patch 逻辑）" \
       make alauda-patch -e ALAUDA_OPERATOR2_TAG=verifytag -e ALAUDA_COLLECTOR_TAG=verifycol; then
  PATCH_FAIL=0
  LEFT="$(grep -c 'PLACEHOLDER' "$CSV_COMMUNITY" || true)"
  [[ "$LEFT" -eq 0 ]] || { echo "  FAIL: patch 后仍残留 $LEFT 处 PLACEHOLDER"; PATCH_FAIL=1; }
  grep -q '^  name: opentelemetry-operator2\.vverifytag' "$CSV_COMMUNITY" \
    || { echo "  FAIL: CSV 的 metadata.name 未被 patch 成 opentelemetry-operator2.v<tag>"; PATCH_FAIL=1; }
  grep -q 'RELATED_IMAGE_COLLECTOR' "$CSV_COMMUNITY" \
    || { echo "  FAIL: CSV 中缺少 RELATED_IMAGE_COLLECTOR 环境变量"; PATCH_FAIL=1; }
  grep -q 'opentelemetry-operator2' bundle/community/metadata/annotations.yaml \
    || { echo "  FAIL: annotations.yaml 未被改写为 opentelemetry-operator2"; PATCH_FAIL=1; }
  grep -q 'opentelemetry-operator2' bundle/community/bundle.Dockerfile \
    || { echo "  FAIL: bundle.Dockerfile 未被改写为 opentelemetry-operator2"; PATCH_FAIL=1; }
  git checkout -- bundle/   # 还原 patch 产生的临时改动
  if [[ "$PATCH_FAIL" -eq 1 ]]; then
    echo
    echo "VERIFY_FAILED"
    echo "阶段: make alauda-patch（patch 结果不符合预期）"
    echo "成因: 上游多半改了 bundle 布局或 CSV 结构，hack/alauda-patch.sh 需要同步调整。"
    exit 2
  fi
  PATCH_CHECK="OK"
else
  git checkout -- bundle/
  echo
  echo "VERIFY_FAILED"
  echo "阶段: make alauda-patch（执行失败）"
  dump_log
  echo
  if [[ "$PATCH_ONLY" -eq 1 ]]; then
    echo "成因: 优先怀疑刚才对 alauda/alauda-csv.yaml 或 hack/alauda-patch.sh 的改动"
    echo "     （YAML 语法错误、yq 路径写错都会在这里报出来，看上面的错误行）。"
  else
    echo "成因: 上游多半改了 bundle 路径或 CSV 结构，hack/alauda-patch.sh 需要同步调整。"
  fi
  exit 2
fi

# 4. 工作区污染检查：ensure-update-is-noop 期望跑完是干净的，
#    脏了说明有生成物被改写（config/manager/kustomization.yaml 已被 gitignore，不会出现在这里）。
#    步骤 2 改过、尚未提交的文件属于预期内，不该报成警告。
DIRTY="$(git status --porcelain || true)"
EXPECTED_RE=" (\.github/workflows/alauda-release\.yaml|alauda/alauda-csv\.yaml|hack/alauda-patch\.sh)$"
UNEXPECTED="$(printf '%s\n' "$DIRTY" | grep -vE "$EXPECTED_RE" | grep . || true)"
echo
if [[ -n "$UNEXPECTED" ]]; then
  warn "校验后出现预期外的工作区改动，请逐个确认是否应纳入本次提交："
  printf '%s\n' "$UNEXPECTED" | sed 's/^/  /'
elif [[ -n "$DIRTY" ]]; then
  info "工作区只有预期内的未提交改动（步骤 2/4 的定制文件）："
  printf '%s\n' "$DIRTY" | sed 's/^/  /'
else
  info "校验后工作区干净"
fi

echo
echo "VERIFY_OK"
echo "CSV patch 校验: $PATCH_CHECK"
if [[ "$PATCH_ONLY" -eq 1 ]]; then
  echo "下一步: 把步骤 4 的跟进改动提交为一个新 commit"
else
  echo "下一步: 提交步骤 2 的流水线默认值改动，然后按步骤 4 的 review 结论继续"
fi
