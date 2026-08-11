#!/usr/bin/env bash
# 步骤 1b / 步骤 5：调内网扫描服务扫当前轮镜像，按修复责任分类并聚合修复目标。
#
# 用法: scan-images.sh [轮次]   缺省用状态里的 ROUND
# 分类:
#   OS_REPORT_ONLY  基础镜像（mlops/static）里的 os 包 → 不修复，如实报告
#   GO_STDLIB       go 二进制的 stdlib                 → 升 alauda-release.yaml 的 go-version
#   GO_MODULE       go 二进制的依赖库                   → 升根 go.mod 的版本
#   UNKNOWN         其他                                → 人工判断
# 输出: 每镜像明细 + 修复目标聚合 + SUMMARY + RESULT: CLEAN|REPORT_ONLY|FIX_NEEDED
# 退出码: 0=扫描完成（无论结论） 1=失败
#
# 注意: 服务端要先拉镜像再扫，首扫可能几分钟，调用方把 Bash timeout 设为 600000。
#       扫描服务返回的 JSON 带巨大的 Description 字段，绝不要直接 cat 给模型看，
#       原始 JSON 落盘、只输出下面这些紧凑行。
# 环境变量: SCAN_API（跳过主备探测）、MAX_ATTEMPTS=3、RETRY_DELAY=15、SCAN_TIMEOUT=300

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state
need_cmd jq

MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
RETRY_DELAY="${RETRY_DELAY:-15}"
SCAN_TIMEOUT="${SCAN_TIMEOUT:-300}"

N="${1:-$ROUND}"
IMG_TSV="$STATE_DIR/images-round${N}.tsv"
[[ -s "$IMG_TSV" ]] || die "没有第 ${N} 轮镜像清单: $IMG_TSV（第 1 轮先跑 resolve-input.sh；回归轮先跑 watch-release.sh）"

# ---------- 选定扫描服务：优先主地址，不可达时切备用 ----------
# 能返回任意 HTTP 状态码即算在线（连接被拒/超时时 curl 输出 000）
probe_api() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 -m 10 "$1/" 2>/dev/null || true)"
  [[ -n "$code" && "$code" != "000" ]]
}

APIS=()
if [[ -n "${SCAN_API:-}" ]]; then
  APIS=("$SCAN_API")
  info "使用显式指定的扫描服务: $SCAN_API"
elif probe_api "$SCAN_API_PRIMARY"; then
  APIS=("$SCAN_API_PRIMARY" "$SCAN_API_BACKUP")
  info "使用主扫描服务: $SCAN_API_PRIMARY（备用: $SCAN_API_BACKUP）"
elif probe_api "$SCAN_API_BACKUP"; then
  APIS=("$SCAN_API_BACKUP")
  warn "主扫描服务不可达（$SCAN_API_PRIMARY），切换到备用: $SCAN_API_BACKUP"
else
  die "主备扫描服务均不可达: $SCAN_API_PRIMARY / $SCAN_API_BACKUP"
fi

SCAN_DIR="$STATE_DIR/scans/round${N}"
mkdir -p "$SCAN_DIR"
TSV="$SCAN_DIR/vulns.tsv"
: >"$TSV"

# ---------- 逐镜像扫描 ----------
API_IDX=0
while IFS=$'\t' read -r _ _ IMG; do
  OUT="$SCAN_DIR/$(img_slug "$IMG").json"
  info "扫描 ${IMG} ..."
  ENCODED="$(jq -rn --arg v "$IMG" '$v|@uri')"
  RESP=""
  while [[ -z "$RESP" && "$API_IDX" -lt ${#APIS[@]} ]]; do
    API="${APIS[$API_IDX]}"
    URL="${API}/image/vulnerability/custom?image_full_address=${ENCODED}&trivy_db_date=latest&severity=low&vulnerability_type=os%2Clibrary&version=v4.4.0"
    for i in $(seq 1 "$MAX_ATTEMPTS"); do
      if RESP="$(curl -sS --fail --max-time "$SCAN_TIMEOUT" -H 'accept: application/json' "$URL")" \
         && jq -e 'has("os") and has("lang")' <<<"$RESP" >/dev/null 2>&1; then
        break
      fi
      RESP=""
      if [[ "$i" -lt "$MAX_ATTEMPTS" ]]; then
        warn "本次扫描失败，${RETRY_DELAY}s 后重试（$i/$MAX_ATTEMPTS）"
        sleep "$RETRY_DELAY"
      fi
    done
    if [[ -z "$RESP" ]]; then
      API_IDX=$((API_IDX + 1))   # 切换后持久生效，后续镜像直接用新服务
      if [[ "$API_IDX" -lt ${#APIS[@]} ]]; then
        warn "服务 $API 连续 $MAX_ATTEMPTS 次失败，切换到 ${APIS[$API_IDX]}"
      fi
    fi
  done
  [[ -n "$RESP" ]] || die "所有扫描服务均连续 $MAX_ATTEMPTS 次失败: $IMG"
  printf '%s\n' "$RESP" >"$OUT"

  # 提取为 TSV：分类 / 包 / 装机版本 / 修复候选(逗号分隔,去 v 前缀) / CVE / 严重度
  # 注：无修复版本时服务返回字符串 "null"，要当空处理，否则会算出 @vnull 的假目标
  ROWS="$(jq -r '
    def fixes: [(.FixedVersion // "") | split(",")[] | gsub("^\\s+|\\s+$";"") | sub("^v";"")
                | select(. != "" and . != "null")] | unique | join(",");
    def cat: if .__src == "os" then "OS_REPORT_ONLY"
             elif .PkgName == "stdlib" then "GO_STDLIB"
             elif (.Type == "gobinary" or .Class == "lang-pkgs") then "GO_MODULE"
             else "UNKNOWN" end;
    ( [(.os // [])[] | . + {__src:"os"}] + [(.lang // [])[] | . + {__src:"lang"}] )
    | .[] | [cat, .PkgName, (.InstalledVersion // "?"), fixes, .VulnerabilityID, (.Severity // "?")]
    | @tsv' "$OUT")"

  # 同一漏洞可能按 Target 重复出现，按行去重
  CNT=0
  if [[ -n "$ROWS" ]]; then
    ROWS="$(sort -u <<<"$ROWS")"
    printf '%s\n' "$ROWS" >>"$TSV"
    CNT="$(grep -c . <<<"$ROWS")"
  fi
  echo
  echo "--- ${IMG}（漏洞 ${CNT} 条）---"
  if [[ -n "$ROWS" ]]; then
    sort <<<"$ROWS" | awk -F'\t' \
      '{printf "  [%s] %s %s %s %s → %s\n", $1, $2, $5, $6, $3, ($4 == "" ? "（无修复版本）" : $4)}'
  fi
done <"$IMG_TSV"

sort -u "$TSV" -o "$TSV"
count_cat() { awk -F'\t' -v c="$1" '$1 == c' "$TSV" | grep -c . || true; }
TOTAL="$(grep -c . "$TSV" || true)"
GOMOD="$(count_cat GO_MODULE)"; STDLIB="$(count_cat GO_STDLIB)"
OSN="$(count_cat OS_REPORT_ONLY)"; UNK="$(count_cat UNKNOWN)"

# ---------- 聚合修复目标 ----------
if awk -F'\t' '$1=="GO_MODULE" || $1=="GO_STDLIB"' "$TSV" | grep -q .; then
  echo
  echo "--- 修复目标（当前分支 $(git branch --show-current)）---"
  echo "  当前 $WORKFLOW_FILE 的 go-version: $(extract_go_version "$WORKFLOW_FILE")"

  STDLIB_ROWS="$(awk -F'\t' '$1=="GO_STDLIB"' "$TSV" | cut -f2- | sort -u)"
  if [[ -n "$STDLIB_ROWS" ]]; then
    INST="$(head -1 <<<"$STDLIB_ROWS" | cut -f2)"
    CANDS="$(cut -f3 <<<"$STDLIB_ROWS" | tr ',' '\n' | grep -v '^$' | sort -uV | paste -sd'/' -)"
    echo "  [stdlib] 构建 go ${INST}  CVE×$(grep -c . <<<"$STDLIB_ROWS")  修复候选: ${CANDS:-（无）}"
    echo "           → update-go-version.sh X.Y.Z（优先同 minor 的 patch；跨 minor 要在最终报告着重说明）"
  fi

  while IFS= read -r PKG; do
    INST="$(awk -F'\t' -v p="$PKG" '$1=="GO_MODULE" && $2==p {print $3; exit}' "$TSV")"
    NFIX="$(awk -F'\t' -v p="$PKG" '$1=="GO_MODULE" && $2==p && $4!="" {print $5}' "$TSV" | sort -u | grep -c . || true)"
    NNOFIX="$(awk -F'\t' -v p="$PKG" '$1=="GO_MODULE" && $2==p && $4=="" {print $5}' "$TSV" | sort -u | grep -c . || true)"
    CANDS="$(awk -F'\t' -v p="$PKG" '$1=="GO_MODULE" && $2==p {print $4}' "$TSV" \
      | tr ',' '\n' | grep -v '^$' | sort -uV || true)"
    if [[ -n "$CANDS" ]]; then
      echo "  [go.mod] $PKG $INST  CVE×${NFIX}$([[ "$NNOFIX" -gt 0 ]] && echo "（另 ${NNOFIX} 个无修复版本）")  候选: $(paste -sd'/' - <<<"$CANDS")  → go get ${PKG}@v$(tail -1 <<<"$CANDS")"
    else
      echo "  [go.mod] $PKG $INST  CVE×${NNOFIX}  （无修复版本，升级修不了，最终汇报中如实说明）"
    fi
  done < <(awk -F'\t' '$1=="GO_MODULE" {print $2}' "$TSV" | sort -u)
fi

echo
echo "SUMMARY: ROUND=${N} TOTAL=${TOTAL} GO_MODULE=${GOMOD} GO_STDLIB=${STDLIB} OS_REPORT_ONLY=${OSN} UNKNOWN=${UNK}"
# 可执行修复 = 有修复候选的 GO_MODULE / GO_STDLIB，或需人工判断的 UNKNOWN
FIXABLE="$(awk -F'\t' '(($1=="GO_MODULE" || $1=="GO_STDLIB") && $4!="") || $1=="UNKNOWN"' "$TSV" | grep -c . || true)"
if [[ "$TOTAL" -eq 0 ]]; then
  echo "RESULT: CLEAN"
elif [[ "$FIXABLE" -gt 0 ]]; then
  echo "RESULT: FIX_NEEDED"
else
  echo "RESULT: REPORT_ONLY（剩余均为不修复项：os 级 / 无修复版本的条目）"
fi
echo "明细 TSV: $TSV"
