# Alauda Build of OpenTelemetry v2

## 新版本发布

### Oauth2 Proxy 镜像更新

**注：该镜像暂时不需要自行构建。**

同步上游开源镜像（新版本或修复了安全漏洞的版本）：

```bash
crane index filter \
  quay.io/oauth2-proxy/oauth2-proxy:<version-tag> \
  -t build-harbor.alauda.cn/asm/oauth2-proxy:<version-tag>-r<n> \
  --platform linux/amd64 \
  --platform linux/arm64
# 示例：
crane index filter \
  quay.io/oauth2-proxy/oauth2-proxy:v7.15.1 \
  -t build-harbor.alauda.cn/asm/oauth2-proxy:v7.15.1-r0 \
  --platform linux/amd64 \
  --platform linux/arm64
```

### Jaeger 版本更新

详见：https://github.com/alauda-mesh/jaeger/tree/main/alauda

### OpenTelemetry Operator 版本更新

1. 同步上游新版本代码
2. 检查 `alauda/alauda-csv.yaml` 文件，是否有新内容需要 patch csv。
3. 执行 GitHub Action 的 `Alauda Release workflow` 流水线
   1. 选择 release 分支，如 `release-2.0`
   2. 填写 `Release version`，如 `2.0.0`（后续生成 github tag）
   3. 填写 `Bundle and Operator version`，如 `0.144.0-r0`
   4. 填写 `Collector tag`，如 `0.145.0-r0`
   5. 填写 `Jaeger tag`，如 `2.16.0-r1`
   6. 填写 `OAuth2 Proxy tag`，如 `v7.15.1-r0`
4. 流水线跑完后，在 GitHub Release 中将 Release 标记为 Publish
