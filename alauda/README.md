# Alauda Build of OpenTelemetry v2

## 新版本发布

### Jaeger 与 OAuth2 Proxy 镜像

Jaeger（jaeger / jaeger-es-rollover / jaeger-es-index-cleaner）与 OAuth2 Proxy 镜像已从本仓库的 OLM bundle 中移除，改由 **Alauda Build of Jaeger v2 集群插件**分发（包括 oauth2-proxy 镜像的同步方式），详见：https://github.com/alauda-mesh/jaeger/tree/main/alauda

### OpenTelemetry Operator 版本更新

1. 同步上游新版本代码
2. 检查 `alauda/alauda-csv.yaml` 文件，是否有新内容需要 patch csv。
3. 执行 GitHub Action 的 `Alauda Release workflow` 流水线
   1. 选择 release 分支，如 `release-2.0`
   2. 填写 `Release version`，如 `2.0.0`（后续生成 github tag）
   3. 填写 `Bundle and Operator version`，如 `0.144.0-r0`
   4. 填写 `Collector tag`，如 `0.145.0-r0`
4. 流水线跑完后，在 GitHub Release 中将 Release 标记为 Publish
