# Alauda Build of OpenTelemetry v2

## 版本升级

升级到上游 [open-telemetry/opentelemetry-operator](https://github.com/open-telemetry/opentelemetry-operator)
的新版本，使用 `sync-upstream` skill（定义在 `.claude/skills/sync-upstream/`，只能显式调用，不会被自动触发）：

```
/sync-upstream v0.156.0
```

不带参数调用时，会列出上游最近的 tag 让你选。skill 依次完成：

1. 基于 `main` 创建 `upgrade/v0.156.0` 分支并 merge 上游 tag
   （ACP 定制面很小，冲突基本只会出现在 `Makefile` 和 `.gitignore`，且都是「两边都要」）
2. 更新 `.github/workflows/alauda-release.yaml` 的 workflow_dispatch 默认值：
   `bundle_version` → `0.156.0-r0`，`collector_tag` → [alauda-opentelemetry-collector](https://github.com/alauda-mesh/alauda-opentelemetry-collector/tags)
   最新的 `v*-r*` tag（去掉 `v` 前缀）
3. 本地跑 `make manager` + `make ensure-update-is-noop` 做轻量校验
4. 对比 openshift / community 两个 bundle CSV，以及它们在新旧版本之间的变化，
   列出建议 patch 进 `alauda/alauda-csv.yaml` 的内容，**等你 review 之后**再改
5. 创建 PR
6. 用 rc 参数 + draft release 触发一次 `Alauda Release workflow` 验证构建，并盯完结果

跑完后 review PR 并合并。注意 skill 不会自行 merge PR，也不会把 draft release 改成 publish。

### bundle CSV 的定制方式

ACP 的 OLM bundle 走 **community** 变体：流水线先 `make bundle -e BUNDLE_VARIANT=community` 生成，
再由 `make alauda-patch`（`hack/alauda-patch.sh`）把 `alauda/alauda-csv.yaml` 合并进去。合并语义：

- `spec.install.spec.deployments` **以外**的部分是 yq 深合并（`. *=`），写进 `alauda-csv.yaml` 即生效；
- `deployments` 里**只追加环境变量**（`.env += ...`），所以跟进 `volumeMounts` / `volumes` / `args`
  这类内容时，还需要同步修改 `hack/alauda-patch.sh`。

upstream 的 openshift 变体不会进入 ACP 产物，其内容是否跟进由步骤 4 逐条评估。

## 漏洞修复

修复 `Alauda Release workflow` 构建出的 `opentelemetry-operator2` 镜像漏洞，使用 `fix-image-vulns` skill
（定义在 `.claude/skills/fix-image-vulns/`，只能显式调用，不会被自动触发）：

```
/fix-image-vulns 31491109834                                        # 传流水线 run ID（或 run URL）
/fix-image-vulns build-harbor.alauda.cn/asm/opentelemetry-operator2:0.156.0-rc.0   # 或直接传镜像
```

不带参数调用时，会列出最近几次 run 让你选。skill 依次完成：

1. 调内网扫描服务扫描镜像，输出漏洞摘要（无漏洞则直接结束）
2. 基于当前分支创建 `fix/cve-<日期>` 分支并修复：
   - go 标准库漏洞 → 升 `.github/workflows/alauda-release.yaml` 的 `go-version`（跨 minor 会着重提示）
   - 依赖库漏洞 → 升根 `go.mod` 的版本，并用 `go build ./...` 做本地构建验证
3. 创建 PR，再触发一次 `Alauda Release workflow`（rc 参数 + draft release）产出新镜像
4. 对新镜像回归扫描，仍有漏洞就继续修，**最多 3 轮**，修不完如实汇报

只修 go 相关漏洞；**os 级漏洞**（来自 `mlops/static` 基础镜像）与 **`-bundle` 镜像**只报告不修复。
skill 不会自行 merge PR，也不会 publish 触发流水线产生的 draft release。

## 版本发版

升级 PR 合并之后正式发版：

1. 执行 GitHub Action 的 `Alauda Release workflow` 流水线
   1. 选择 release 分支，如 `release-2.0`
   2. 填写 `Release version`，如 `2.0.0`（后续生成 github tag）
   3. 填写 `Bundle and Operator version`，如 `0.156.0-r0`
   4. 填写 `Collector tag`，如 `0.158.0-r0`
   5. `Draft release` 保持勾选，`Pre-release` 按需选择
2. 流水线产出两个镜像：
   - `build-harbor.alauda.cn/asm/opentelemetry-operator2:<Bundle and Operator version>`
   - `build-harbor.alauda.cn/asm/opentelemetry-operator2-bundle:v<Bundle and Operator version>`
3. 流水线跑完后，在 GitHub Release 中将 Release 标记为 Publish

## Jaeger 与 OAuth2 Proxy 镜像

Jaeger（jaeger / jaeger-es-rollover / jaeger-es-index-cleaner）与 OAuth2 Proxy 镜像已从本仓库的 OLM bundle 中移除，
改由 **Alauda Build of Jaeger v2 集群插件**分发（包括 oauth2-proxy 镜像的同步方式），
详见：<https://github.com/alauda-mesh/jaeger/tree/main/alauda>
