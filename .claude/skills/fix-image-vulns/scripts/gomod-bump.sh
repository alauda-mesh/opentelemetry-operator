#!/usr/bin/env bash
# 步骤 2c：升级根 go.mod 的依赖版本并做本地构建验证。
#
# 用法: gomod-bump.sh <module@vX.Y.Z> [module@vX.Y.Z ...]
#       gomod-bump.sh --build-only        # 只做构建验证（例如本轮只改了 go-version）
#   例: gomod-bump.sh golang.org/x/text@v0.39.0 google.golang.org/grpc@v1.82.1
# 版本号必须带 v 前缀（扫描给出的修复候选没有 v，拼参数时要加上）。
#
# 有漏洞的库多半是 indirect 依赖：go get 会在 go.mod 写下显式 require 行，
# go mod tidy 会保留它（标 // indirect），这是强制抬升 indirect 依赖的标准做法。
#
# 构建验证跑 go build ./...，覆盖面比流水线的 make manager（只编 main.go）更大，
# 顺带能发现依赖升级把 cmd/otel-allocator、cmd/operator-opamp-bridge 编坏的情况。
#
# 退出码: 0=构建验证通过（RESULT: BUILD_OK） 非 0=某一步失败（保留现场供分析）
# 注意: go get 下载 + 全量编译可能好几分钟，Bash timeout 设 900000；
#       冷缓存首跑建议 run_in_background: true。

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state
need_cmd go

[[ $# -ge 1 ]] || die "用法: gomod-bump.sh <module@vX.Y.Z ...> | --build-only"

# go.mod 或新依赖要求的 go 版本可能高于本机默认，auto 允许按需拉取 toolchain；
# GOPROXY 与流水线（alauda-release.yaml 的 env）保持一致
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"

BUILD_ONLY=0
[[ "$1" == "--build-only" ]] && BUILD_ONLY=1

BEFORE_GO="$(sed -n 's/^go //p' go.mod | head -1)"

if [[ "$BUILD_ONLY" -eq 0 ]]; then
  for spec in "$@"; do
    [[ "$spec" == *@v* ]] || die "参数格式应为 module@vX.Y.Z（版本要带 v 前缀），收到: $spec"
  done
  info "go get $*"
  go get "$@"
  info "go mod tidy"
  go mod tidy
fi

info "构建验证: go build ./...（首次需下载依赖，可能几分钟）"
go build ./...

if [[ "$BUILD_ONLY" -eq 0 ]]; then
  echo
  echo "实际落位版本（依赖之间有约束，落位版本可能高于请求版本，属正常）:"
  for spec in "$@"; do
    MOD="${spec%@*}"
    echo "  $(go list -m "$MOD" 2>/dev/null || echo "$MOD （已不在依赖图中）")"
  done

  # apis/ 是被 replace 到本地的独立模块。镜像里的版本由根模块 MVS 决定（取两边的最大值），
  # 所以修镜像改根 go.mod 就够；但 apis 作为独立发布的模块自身仍留着低版本，这里如实提示。
  if [[ -f apis/go.mod ]]; then
    for spec in "$@"; do
      MOD="${spec%@*}"; WANT="${spec#*@}"
      CUR="$(cd apis && go list -m -f '{{.Version}}' "$MOD" 2>/dev/null || true)"
      [[ -n "$CUR" && "$CUR" != "$WANT" ]] || continue
      HIGHEST="$(printf '%s\n%s\n' "${CUR#v}" "${WANT#v}" | sort -V | tail -1)"
      [[ "$HIGHEST" == "${WANT#v}" ]] || continue
      echo "  NOTICE: apis/go.mod 里 $MOD 仍是 $CUR（低于 $WANT）。镜像不受影响（根模块 MVS 取高者），"
      echo "          若要让独立发布的 apis 模块也干净: (cd apis && go get $MOD@$WANT && go mod tidy)"
    done
  fi

  AFTER_GO="$(sed -n 's/^go //p' go.mod | head -1)"
  if [[ "$BEFORE_GO" != "$AFTER_GO" ]]; then
    warn "go.mod 的 go directive 被连带提升: $BEFORE_GO → $AFTER_GO（若高于 workflow 的 go-version，需执行 update-go-version.sh 并在 PR 里说明）"
  fi

  echo
  echo "变更文件（提交前用 git diff go.mod 审查连带升级面）:"
  git status --short
fi
echo "RESULT: BUILD_OK"
