---
name: sync-upstream
description: 把 alauda-mesh/opentelemetry-operator 升级到指定的上游 OpenTelemetry Operator tag（如 v0.156.0）。完成六件事：基于 main 建 upgrade/<tag> 分支并 merge 上游 tag、把 alauda-release 流水线的 bundle_version 与 collector_tag 默认值更新到位、本地轻量构建校验、对比 openshift/community bundle CSV 并给出 alauda-csv.yaml 的跟进建议（等用户 review）、创建 PR、触发并监控 Alauda Release 流水线（失败时分析原因）。仅限用户显式通过 /sync-upstream 调用。
argument-hint: "[上游 tag]，例如: v0.156.0"
disable-model-invocation: true
---

# 升级 OpenTelemetry Operator 版本

把本仓库升级到 <https://github.com/open-telemetry/opentelemetry-operator> 的指定 tag，
跟进 bundle CSV 该同步的内容，最后建 PR、触发 Alauda Release 流水线并盯完结果。
下文的 `$SKILL_DIR` 指本 skill 的根目录（即调用时提示的 Base directory）。

## 参数

- 上游 tag：`$0`（形如 `v0.156.0`）

为空时先列出上游最近的正式 tag，再用 AskUserQuestion 让用户选（推荐最新的那个），不要自行猜测：

```bash
git fetch upstream --tags --quiet 2>/dev/null; git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -6
```

## 背景知识

- 本仓库是 `open-telemetry/opentelemetry-operator` 的 fork，**ACP 的定制面极小**——只有 9 个文件与上游不同：
  `.claude/`、`.github/workflows/alauda-release.yaml`、`.gitignore`、`Dockerfile.alauda`、`Makefile`（只在首行加了
  `-include Makefile.alauda.mk`）、`Makefile.alauda.mk`、`alauda/README.md`、`alauda/alauda-csv.yaml`、`hack/alauda-patch.sh`。
  其中真正与上游共享、可能产生合并冲突的只有 `Makefile` 和 `.gitignore`，而且都属于"两边都要"。
  这意味着升级本身通常很顺，**真正需要动脑的是 bundle CSV 的跟进（步骤 4）**。
- ACP 的 OLM bundle 走 **community** 变体：流水线执行 `make bundle -e BUNDLE_VARIANT=community`，
  再用 `make alauda-patch` 把 `alauda/alauda-csv.yaml` 合并进
  `bundle/community/manifests/opentelemetry-operator.clusterserviceversion.yaml`。
  **openshift 变体的内容不会自动进入 ACP 产物**，所以每次升级都要看一眼 openshift 那边多做了什么、值不值得跟进。
- `hack/alauda-patch.sh` 的合并语义决定了跟进成本，判断时必须清楚：
  - `spec.install.spec.deployments` **以外**的部分用 yq 的 `. *=` 深合并 —— 想加什么直接写进 `alauda/alauda-csv.yaml` 即可；
  - `deployments` 里**只做 `.env += ...`（追加环境变量）** —— 所以跟进 env 是零成本的；
    而 `volumeMounts` / `volumes` / `args` / 探针这类改动，光改 `alauda/alauda-csv.yaml` 不会生效，
    还得改 `hack/alauda-patch.sh` 增加对应的 yq 逻辑。**评估建议时要把这条成本说清楚。**
- 流水线 `.github/workflows/alauda-release.yaml` 是 **`workflow_dispatch` 触发**的，
  PR 本身不会触发任何构建，所以建完 PR 还要单独触发一次做构建验证。
- 触发时用 `-rc.<n>` 后缀 + `is_draft_release=true`：产物是 draft release，不会污染正式版本；
  `--draft` 的 release 在 publish 之前不会真的创建 git tag。
- 各脚本的中间产物（merge 日志、构建日志、CSV diff、步骤间状态）都放在 `.git/otel-op-sync/` 下，
  不会污染工作区，需要翻原始数据时去那里找。
- 全程禁止 `git commit --amend`，一律创建新 commit，message 里不要带 `Co-Authored-By`。
  步骤 5 之前不要 push、不要建 PR。
- **步骤编号是决策顺序，不是必须串行等待的顺序**。`verify.sh` 首次跑要下载工具链、拉 Go 依赖，
  通常 5~15 分钟；`csv-diff.sh` 是纯只读的，不依赖构建结果。正确做法是 `verify.sh` 后台跑起来的同时
  就去做步骤 4 的 CSV 分析，把报告先抛给用户 review，否则这十几分钟纯属干等。
- 但 **`verify.sh` 运行期间不要 commit、也不要改 `bundle/` 和 `config/` 下的文件**：
  `make ensure-update-is-noop` 会调用 `make update` 重新生成这两个目录，中途 commit 可能把生成到一半的状态提交进去。
  步骤 4 的分析是只读的，照常做；分析结论产生的实际修改等 `verify.sh` 结束后再落地。

## 步骤 1：合并上游 tag

```bash
bash "$SKILL_DIR/scripts/sync.sh" <上游tag>
```

脚本会：校验 tag 格式与工作区干净 → 确保 upstream remote 存在并 fetch → 校验 tag 确实存在 →
基于 `origin/main` 创建 `upgrade/<tag>` 分支 → 读取基线版本（`versions.txt` 的 `operator=`）→
`git merge <tag>`。按退出结果处理：

- **MERGED（0）**：合并成功（merge 提交已自动产生），继续步骤 2。
- **CONFLICT（2）**：脚本已列出冲突文件。参考背景知识，冲突基本只会出现在 `Makefile`（保留首行
  `-include Makefile.alauda.mk`，同时合入上游新增内容）和 `.gitignore`（两边的 ignore 行都保留）。
  若冲突出现在别的文件，说明该文件的 ACP 定制超出了已知的 9 个文件范围，**停下来向用户确认**再解决。
  解决后 `git add <文件> && git commit --no-edit` 完成合并（禁止 amend），然后继续步骤 2。
- **失败（1）**：前置条件问题（工作区不干净、分支已存在、tag 不存在）。把脚本报错原样告知用户并询问如何处理，
  不要擅自 stash、删分支或换 tag。

## 步骤 2：更新流水线默认参数

```bash
bash "$SKILL_DIR/scripts/update-defaults.sh"
```

脚本改写 `.github/workflows/alauda-release.yaml` 的两个 `workflow_dispatch` 默认值（不 commit，便于 review diff）：

- `bundle_version` → `<目标版本>-r0`（如 `0.156.0-r0`）；
- `collector_tag` → `alauda-mesh/alauda-opentelemetry-collector` 最新的 `v*-r*` tag 去掉 `v` 前缀
  （如仓库最新是 `v0.158.0-r0`，则填 `0.158.0-r0`）。脚本会同时列出最近 5 个 tag，**核对一下取到的确实是最新的那个**。

若 gh 不可用导致 `collector_tag` 保持原值（脚本会 WARN），手动查
<https://github.com/alauda-mesh/alauda-opentelemetry-collector/tags> 后用 Edit 修改。
**PATTERN_MISMATCH（2）** 表示 workflow 结构变了、脚本没匹配上，按输出里的 FAIL 项用 Edit 手动补齐。

## 步骤 3：本地轻量校验

**必须用后台方式运行**（Bash 工具的 `run_in_background: true`），然后立刻去做步骤 4，别干等：

```bash
bash "$SKILL_DIR/scripts/verify.sh"
```

脚本依次跑三项检查（实测 v0.147.0 → v0.156.0 全程约 10 分钟）：

1. `make manager` —— 编译 operator 二进制；
2. `make ensure-update-is-noop` —— 校验 `zz_generated.*.go` / `bundle` / `config` / `docs/api` 与源码一致；
3. `make alauda-patch` —— 校验 `hack/alauda-patch.sh` 仍然可用（它写死了 bundle 路径和 yq 表达式，
   上游改动 bundle 布局时会失效）。跑完自动 `git checkout -- bundle/` 还原临时改动；本地没有 yq
   或 `bundle/` 有未提交改动时会自动跳过。

- **VERIFY_OK（0）**：继续。输出末尾的「CSV patch 校验」是 OK 还是 SKIPPED 要记进最终汇报。
- **VERIFY_FAILED（2）**：脚本已标明失败阶段并附错误相关行。上游 tag 自身一定是自洽的，所以
  前两项失败**几乎总是合并冲突解错了**——重点看 `apis/` 与 `config/` 的冲突解决结果；
  第三项失败则是上游动了 bundle 布局，要同步改 `hack/alauda-patch.sh`。修好后重跑；拿不准就停下来问用户。

校验通过后，把步骤 2 的流水线默认值改动提交为一个新 commit：

```bash
git add .github/workflows/alauda-release.yaml && git commit -m "chore: update alauda-release defaults for <tag>"
```

## 步骤 4：bundle CSV 差异分析与跟进（用户 review 入口）

这是整个升级里唯一需要真正做判断的环节。

```bash
bash "$SKILL_DIR/scripts/csv-diff.sh"
```

脚本输出四块数据（完整 diff 在 `.git/otel-op-sync/` 下，被截断时可加 `--full` 重跑）：

- **A. 当前工作区 community → openshift 的差异**：openshift 变体独有的内容（额外 env、metrics TLS 证书卷等）。
  这些不会进 ACP 产物，是"要不要跟进"的候选池。
- **B. openshift CSV 在 基线tag → 目标tag 之间的变化**：上游这一版在 openshift 侧做了什么。
- **C. community CSV 在 同一区间的变化**：ACP 已经随 merge 自然继承的部分。
  **B 减去 C 才是真正需要单独决策的增量**——只在 B 里出现的才要评估，B 和 C 都有的已经白拿了。
- **D. `alauda/alauda-csv.yaml` 现状**：ACP 实际 patch 进 bundle 的内容，以及已 patch 的 env 名单。

逐条判断时考虑这几件事：

1. **ACP 是否已经有了**——对照 D 的 env 名单和 patch 内容，已有的直接标注"已覆盖"，不要让用户重复 review；
2. **是否 OpenShift 专属**——依赖 OpenShift 特有资源（console dashboard、`service.beta.openshift.io` 证书注入、
   OpenShift 监控栈等）的内容，ACP 环境上不成立，一般不跟进；
3. **跟进成本**——是纯 env（改 `alauda/alauda-csv.yaml` 即可，零成本），还是涉及 volumes/volumeMounts/args
   （必须同时改 `hack/alauda-patch.sh` 的 yq 逻辑）。成本高的要在建议里如实写出来。

然后输出**编号报告**给用户 review：

```markdown
| # | 内容 | 来源 | ACP 现状 | 跟进成本 | 建议 | 理由 |
|---|-----|------|---------|---------|------|------|
| 1 | ENABLE_GO_AUTO_INSTRUMENTATION=true | A / B | 已在 alauda-csv.yaml | - | 无需跟进 | 已覆盖 |
| 2 | METRICS_TLS_CERT_FILE + 证书卷挂载 | A | 未包含 | 高（需改 alauda-patch.sh 支持 volumes） | 不建议 | 依赖 OpenShift 证书注入 |
```

表格下面附一行：
`请回复要跟进的编号（如 1,3）；全部跟进回 all，都不跟进回 none；也可以直接说你的想法。`

表格给完整信息，然后再用 **AskUserQuestion** 把它收敛成几个可点选的方案（把推荐项放第一个并标"（推荐）"，
用户仍可选 Other 自由输入）。表格负责讲清楚，选项负责好点。

**然后停下来等用户回复**，不要自作主张先改。这一步是用户 review 的入口，抢跑会让整件事失去意义。

拿到回复后按选中项修改 `alauda/alauda-csv.yaml`（必要时连带改 `hack/alauda-patch.sh`）。
改完**必须重新校验一次 patch 逻辑**——写坏的 YAML 或错位的 yq 路径在这里最容易出现，
而流水线要 20 分钟后才会告诉你：

```bash
bash "$SKILL_DIR/scripts/verify.sh" --patch-only
```

这个模式只跑 `make alauda-patch` 那一项（几秒钟），并自动还原 `bundle/`。
通过后单独提交一个 commit（如 `chore: follow up upstream CSV changes`）。用户回 none 就跳过修改与校验。

## 步骤 5：创建 PR

先把 PR 描述写进 scratchpad 下的临时文件（如 `pr-body.md`）：内容取最终汇报的精简版（版本变更、
流水线默认值、本地校验结果、CSV 跟进结论），结尾加一行
`🤖 Generated with [Claude Code](https://claude.com/claude-code)`。然后：

```bash
bash "$SKILL_DIR/scripts/create-pr.sh" <PR正文文件>
```

脚本会 push 升级分支并创建 PR（分支已有 open PR 时幂等复用），输出 `PR_NUMBER=` 与 `PR_URL=`。
若报 gh 未认证，提示用户执行 `! gh auth login` 后重试。

## 步骤 6：触发并监控 Alauda Release 流水线

PR 不会触发构建，要显式触发一次做验证。先算参数：

```bash
bash "$SKILL_DIR/scripts/trigger-release.sh" --dry-run
```

脚本从 workflow 默认值和历史 run 标题推出本次参数：`release_version` = 默认值 + `-rc.<下一个序号>`、
`bundle_version` = `<目标版本>-rc.<下一个序号>`、`collector_tag` = 步骤 2 写好的默认值，
外加 `is_draft_release=true`、`is_pre_release=false`。

**用 AskUserQuestion 把参数交给用户确认后再正式触发**——触发会产生一个 draft GitHub Release，
参数错了要手工清理。确认后：

```bash
bash "$SKILL_DIR/scripts/trigger-release.sh"
# 需要覆盖某个参数时：trigger-release.sh --release-version 2.0.0-rc.11 --bundle-version 0.156.0-rc.0
```

然后监控。self-hosted runner 上的双平台镜像构建通常 10~40 分钟，
**必须用后台方式运行**（`run_in_background: true`），完成后会收到通知：

```bash
bash "$SKILL_DIR/scripts/watch-release.sh"
```

按退出结果处理：

- **PIPELINE_SUCCESS（0）**：把输出里的两个镜像名和 draft release 链接加入最终汇报；
- **PIPELINE_FAILED（2）**：脚本已附失败概览与日志摘要。定位失败 step，判断是本次升级引入的
  （上游新版本编译/生成不兼容、bundle 校验失败、CSV patch 写错）还是环境问题（runner 离线、
  harbor 登录、yq 版本、基础镜像拉取）。需要更多日志时用
  `gh run view <run-id> --repo alauda-mesh/opentelemetry-operator --log-failed`。
  **属于本次升级引入的问题最多尝试修复 2 次**：修复 → 新 commit → `git push origin HEAD` →
  重新执行 `trigger-release.sh` 并后台运行 `watch-release.sh`。两次仍失败，或原因是环境问题、
  或修复方案拿不准，就停下来把分析结论交给用户，不要继续盲改；
- **PIPELINE_TIMEOUT（3）**：告知用户流水线仍在运行并附 run 链接，之后可用 `gh run view <run-id>` 查看。

不要自行 merge PR，也不要把 draft release 改成 publish —— 那是用户 review 之后的事
（见 `alauda/README.md` 的「版本发版」章节）。

## 最终汇报

用清晰的列表汇报下面这些，这是用户验收的依据：

1. **分支与版本**：分支名、`OLD → NEW` 版本、合入的上游提交数、冲突及解决方式；
2. **流水线默认值**：`bundle_version` 和 `collector_tag` 的新旧值，collector tag 的来源；
3. **本地校验**：VERIFY_OK/FAILED，失败过则说明修了什么；
4. **CSV 跟进**：逐条结论（跟进了什么 / 为什么跳过），改了哪些文件；
5. **PR**：链接与提交列表；
6. **流水线**：run 链接与结果，成功则给出
   `build-harbor.alauda.cn/asm/opentelemetry-operator2:<bundle_version>` 与
   `...-bundle:v<bundle_version>` 两个镜像名和 draft release 链接，失败则给出原因分析与已尝试的修复。

到此流程结束，等用户 review 与合并。
