#!/usr/bin/env bash
# 步骤 4：采集 bundle CSV 差异数据，供模型判断 ACP 需要跟进哪些内容。
# 脚本只负责取数、不下结论——结论要结合 ACP 的定位和 alauda-patch.sh 的合并语义来判断。
#
# 输出四块：
#   A. 当前工作区 community -> openshift 的差异（openshift 变体独有的能力）
#   B. openshift CSV 在 基线tag -> 目标tag 之间的变化（上游这一版做了什么）
#   C. community CSV 在 基线tag -> 目标tag 之间的变化（ACP 已随 merge 自然继承的部分）
#   D. alauda/alauda-csv.yaml 现状（ACP 实际 patch 进 bundle 的内容）
#
# 用法: csv-diff.sh [--full]   （--full 打印完整 diff，默认按行数截断）
# 退出码: 0=OK   1=前置条件失败

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state

FULL=0
if [[ "${1:-}" == "--full" ]]; then FULL=1; fi
CAP=400   # 每块 diff 默认最多打印的行数（步骤 4 是决策环节，宁可多给上下文）

[[ -f "$CSV_COMMUNITY" ]] || die "找不到 $CSV_COMMUNITY"
[[ -f "$CSV_OPENSHIFT" ]] || die "找不到 $CSV_OPENSHIFT"

# emit <标题> <diff文件>
emit() {
  local title="$1" file="$2"
  local lines
  lines="$(awk 'END { print NR }' "$file")"
  echo
  echo "===== $title（$lines 行）====="
  if [[ "$lines" -eq 0 ]]; then
    echo "(无差异)"
    return
  fi
  if [[ "$FULL" -eq 1 || "$lines" -le "$CAP" ]]; then
    cat "$file"
  else
    head -"$CAP" "$file"
    echo "...（共 $lines 行，其余省略；完整内容: $file，或重跑 csv-diff.sh --full）"
  fi
}

# ---------- A. community vs openshift（当前工作区）----------
# 两个变体由同一套 config/ 生成，差异就是 OpenShift overlay 额外做的事。
# 这些内容不会进 ACP 产物（ACP 只构建 community 变体），需要逐条判断是否值得跟进。
A="$WORK_DIR/csv-A-community-vs-openshift.diff"
diff -u "$CSV_COMMUNITY" "$CSV_OPENSHIFT" >"$A" || true
# 去掉 diff 头两行的文件名/时间戳噪声
tail -n +3 "$A" >"$A.tmp" && mv "$A.tmp" "$A"
emit "A. 当前版本 community -> openshift 的差异（openshift 独有内容）" "$A"

# ---------- B/C. 跨版本变化 ----------
if git rev-parse -q --verify "refs/tags/${OLD_TAG}^{commit}" >/dev/null \
   && git rev-parse -q --verify "refs/tags/${TARGET_TAG}^{commit}" >/dev/null; then
  B="$WORK_DIR/csv-B-openshift-${OLD_TAG}-${TARGET_TAG}.diff"
  C="$WORK_DIR/csv-C-community-${OLD_TAG}-${TARGET_TAG}.diff"
  git --no-pager diff "$OLD_TAG" "$TARGET_TAG" -- "$CSV_OPENSHIFT" >"$B" || true
  git --no-pager diff "$OLD_TAG" "$TARGET_TAG" -- "$CSV_COMMUNITY" >"$C" || true
  emit "B. openshift CSV: ${OLD_TAG} -> ${TARGET_TAG}（上游这一版改了什么）" "$B"
  emit "C. community CSV: ${OLD_TAG} -> ${TARGET_TAG}（ACP 已随 merge 自然继承的部分）" "$C"
else
  warn "缺少 tag ${OLD_TAG} 或 ${TARGET_TAG}，跳过跨版本对比（B/C）"
  warn "可先执行 git fetch upstream --tags 后重跑"
fi

# ---------- D. ACP 的 patch 现状 ----------
echo
echo "===== D. ${PATCH_FILE}（ACP patch 进 community bundle 的内容，超长行已截断）====="
cut -c1-200 "$PATCH_FILE" | cat -n

echo
echo "--- D1. 已 patch 的 env 名单（deployments 只追加 env，其余字段是深合并）---"
awk '
  $1 == "env:"                        { inenv = 1; next }
  inenv && $1 == "-" && $2 == "name:" { print "  " $3; next }
  inenv && $1 == "value:"             { next }
  inenv                               { inenv = 0 }
' "$PATCH_FILE" | sort -u || true

echo
echo "CSV_DIFF_READY"
echo "下一步: 结合 A/B/C/D 逐条判断 ACP 是否跟进，输出编号表格给用户 review，然后停下来等回复"
