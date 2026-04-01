---
name: alauda-otel-upgrade
description: |
  Use this skill when the user wants to upgrade the alauda-mesh/opentelemetry-operator fork to a new upstream version.
  Triggers on phrases like: upgrade to v0.147.0, upgrade operator, sync upstream version, merge upstream tag,
  run alauda release pipeline, trigger release workflow, or any combination of upgrading the operator and
  triggering the Alauda Release workflow. Handles both the git merge step and the GitHub Actions workflow_dispatch trigger.
---

# Alauda OpenTelemetry Operator 升级 Skill

本 skill 负责将 `alauda-mesh/opentelemetry-operator` fork 升级到指定的 upstream 版本，并触发 Alauda Release 测试流水线。

## 环境信息

- **本地仓库路径**：`/Users/alan/go/src/github.com/alauda-mesh/opentelemetry-operator`
- **Origin remote**：`git@github.com:alauda-mesh/opentelemetry-operator.git`
- **Upstream remote**：`git@github.com:open-telemetry/opentelemetry-operator.git`
- **Alauda Release workflow 文件**：`.github/workflows/alauda-release.yaml`
- **GitHub 仓库**：`alauda-mesh/opentelemetry-operator`

## 执行流程

### 第一步：确认升级版本

1. 从用户输入中提取目标版本号（如 `v0.147.0`）。
2. 如果用户未指定版本，查询 upstream 最新 tag：
   ```bash
   git fetch upstream --tags
   git tag | grep '^v0\.' | sort -V | tail -5
   ```
3. 展示当前版本（读取 `versions.txt` 中的 `operator=` 行）和目标版本，请用户确认。

### 第二步：代码升级

> **确认后执行**，每步操作前说明将要做什么。

1. **同步 upstream 代码**：

   ```bash
   cd /Users/alan/go/src/github.com/alauda-mesh/opentelemetry-operator
   git fetch upstream --tags
   ```

2. **基于 main 创建升级分支**：

   ```bash
   git checkout main
   git pull origin main
   git checkout -b upgrade/<version>
   # 例如：git checkout -b upgrade/v0.147.0
   ```

3. **合并目标版本 tag**：

   ```bash
   git merge <version>
   # 例如：git merge v0.147.0
   ```

   - 如果有冲突，逐一分析并帮助解决，优先保留 alauda 定制内容。
   - 合并完成后展示变更摘要（`git diff --stat main`）。

4. **更新流水线默认参数**：
   更新 `.github/workflows/alauda-release.yaml` 中的 `bundle_version.default` 值为 `<version>-r<n>`，例如 `0.147.0-r0`。

5. **Push 分支到 origin**：
   ```bash
   git push origin upgrade/<version>
   ```

### 第三步：计算 Workflow 参数

在触发流水线前，需要通过 GitHub API 查询历史执行记录来确定参数中的递增序号。

**工具要求**：需要 `gh` CLI 已安装并已认证。如未安装，执行以下步骤：

```bash
# macOS 安装
brew install gh
# 认证
gh auth login
```

**读取 workflow 默认值**（从 `.github/workflows/alauda-release.yaml`）：

- `release_version` 默认值（如 `2.0.0`）
- `bundle_version` 默认值（如 `0.147.0-r0`）
- `collector_tag` 默认值（如 `0.148.0-r0`）

**查询历史 workflow runs**：

```bash
gh run list \
  --workflow=alauda-release.yaml \
  --limit=50 \
  --json databaseId,displayTitle,status,conclusion,createdAt,headBranch \
  --repo alauda-mesh/opentelemetry-operator
```

**计算参数**：

1. **`release_version`**（测试用，添加 `-rc.<n>` 后缀）：
   - 基础值 = workflow 默认的 `release_version`（如 `2.0.0`）
   - 筛选历史 runs 中 `displayTitle` 包含该基础值且包含 `-rc.` 的记录
   - 提取最大的 `n`，新值 = `n + 1`；若无历史记录，`n = 0`
   - 最终值示例：`2.0.0-rc.0`

2. **`bundle_version`**（`<target-version-without-v>-rc.<n>`）：
   - 目标版本去掉 `v` 前缀（如 `0.147.0`）
   - 筛选历史 runs 中 `displayTitle` 包含 `Operator 0.147.0-rc.` 的记录，提取最大 `n`
   - 新值 = `n + 1`；若无历史记录，`n = 0`
   - 最终值示例：`0.147.0-rc.0`

3. **`collector_tag`**：使用 workflow 中的默认值，无需修改。

4. **`jaeger_tag`**：使用 workflow 中的默认值，无需修改。

5. **`oauth2_proxy_tag`**：使用 workflow 中的默认值，无需修改。

6. **`bundle_channels`**：使用默认值 `stable`。

7. **`is_draft_release`**：`true`（测试用）

8. **`is_pre_release`**：`false`

**展示计算结果**，请用户确认参数后再触发。

### 第四步：触发 Alauda Release Workflow

```bash
gh workflow run alauda-release.yaml \
  --repo alauda-mesh/opentelemetry-operator \
  --ref upgrade/<version> \
  --field release_version=<release_version> \
  --field bundle_channels=stable \
  --field bundle_version=<bundle_version> \
  --field collector_tag=<collector_tag> \
  --field jaeger_tag=<jaeger_tag> \
  --field oauth2_proxy_tag=<oauth2_proxy_tag> \
  --field is_draft_release=true \
  --field is_pre_release=false
```

触发后立即查询 run ID：

```bash
sleep 5
gh run list \
  --workflow=alauda-release.yaml \
  --limit=3 \
  --repo alauda-mesh/opentelemetry-operator \
  --json databaseId,displayTitle,status,createdAt,url
```

### 第五步：等待流水线结果

每隔 60 秒轮询一次状态，最长等待 30 分钟：

```bash
gh run watch <run-id> \
  --repo alauda-mesh/opentelemetry-operator \
  --interval 60
```

或手动轮询：

```bash
gh run view <run-id> \
  --repo alauda-mesh/opentelemetry-operator \
  --json status,conclusion,url
```

**结果处理**：

- **成功（conclusion=success）**：通知用户流水线成功，提供 GitHub Release 链接。
- **失败（conclusion=failure）**：
  1. 获取失败 step 详情：`gh run view <run-id> --repo alauda-mesh/opentelemetry-operator --log-failed`
  2. 分析失败原因（构建失败、镜像推送失败、认证失败等）
  3. 向用户报告失败原因和建议的修复方式

## 注意事项

- 所有 git 操作前先确认当前工作目录干净（`git status`）
- 合并冲突时，`.github/workflows/alauda-release.yaml` 等 alauda 特有文件优先保留本地版本
- `versions.txt` 冲突时使用 upstream 版本（这是升级的目的）
- 每个重要步骤完成后都要向用户汇报进展
- 触发流水线前必须确认参数正确，避免产生错误的 GitHub Release
