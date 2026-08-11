---
name: fix-image-vulns
description: 修复 alauda-mesh/opentelemetry-operator 的 Alauda Release 流水线构建出的 opentelemetry-operator2 镜像安全漏洞。输入一个流水线 run（ID/URL）或完整镜像地址，完成：解析待扫描镜像、调内网扫描服务（主备自动切换）扫描并按修复责任分类、修复（go stdlib → 升 alauda-release.yaml 的 go-version；依赖库 → 升根 go.mod）、本地构建验证、建 PR、触发并监控流水线、回归扫描（最多 3 轮修复）；os 级漏洞与 -bundle 镜像只报告不修复。仅限用户显式通过 /fix-image-vulns 调用。
argument-hint: "[RUN_ID | run URL | 镜像地址]，例如: /fix-image-vulns 31491109834"
disable-model-invocation: true
---

# 修复 opentelemetry-operator2 镜像漏洞

对 Alauda Release 流水线产出的 `opentelemetry-operator2` 镜像做漏洞扫描，按修复责任分类处理，
直到镜像干净或达到轮次上限。下文的 `$SKILL_DIR` 指本 skill 的根目录（调用时提示的 Base directory）。

## 参数

- `$ARGUMENTS`：**Alauda Release workflow** 的 run（纯数字 ID 或 run URL），或带 tag 的完整镜像地址
  （如 `build-harbor.alauda.cn/asm/opentelemetry-operator2:0.156.0-rc.0`）。两类可混用、可给多个。
- 参数里可能混有给助手的备注文字，只把 run/镜像部分传给脚本，备注按用户的附加要求执行。
- 参数为空时**不要猜**：先列出最近几次 run，再用 AskUserQuestion 让用户选（推荐最新的成功 run）：

  ```bash
  gh run list --workflow=alauda-release.yaml --repo alauda-mesh/opentelemetry-operator \
    --limit 6 --json databaseId,displayTitle,conclusion,createdAt \
    --jq '.[] | "\(.databaseId)  \(.conclusion)  \(.displayTitle)  \(.createdAt)"'
  ```

## 背景知识

**镜像与修复责任**（run 输入时从其 `Output images: ...` step 名提取清单）：

| 对象 | 内容 | 漏洞处理 |
| --- | --- | --- |
| `asm/opentelemetry-operator2` | 只装了一个 go 二进制 `manager`（`Dockerfile.alauda` 从 `mlops/static` 基础镜像拷入） | stdlib → 升 workflow go-version；依赖库 → 升根 `go.mod` |
| `asm/opentelemetry-operator2-bundle` | OLM 元数据镜像，没有可执行文件 | **不扫不修**（脚本自动跳过） |
| 基础镜像 `mlops/static` 里的 os 包 | distroless 基础层 | **不修复**，如实报告（换基础镜像不在本 skill 范围） |

- **go 版本 pin 机制**：`.github/workflows/alauda-release.yaml` 的 setup-go `go-version: "X.Y.Z"` 是全仓库
  **唯一**钉成精确版本的地方，镜像里的 `manager` 就是它编出来的，所以修 stdlib 漏洞就是升这一处。
  其他社区 workflow 用的是 `~1.26.5`（自动取该 minor 最新 patch），与发布镜像无关，**不要顺手改**。
  升级策略：优先当前 minor 内的 patch；patch 满足不了才跨 minor，跨了要在 PR 与最终报告里**着重强调**。
- **仓库有 4 个 go module**，升依赖前必须清楚它们的关系（2026-08 首次实跑就栽在这里）：

  | module | 与根模块的关系 | 依赖升级时 |
  | --- | --- | --- |
  | 根 `go.mod` | — | **要改**，镜像里的依赖版本由它的 MVS 决定 |
  | `apis/go.mod` | 被根模块 `replace` 到本地 | 不影响镜像；但它是独立发布的 module，建议顺带对齐（实测一行 diff、零风险） |
  | `cmd/otel-allocator/integrationtest/go.mod` | **`replace` 指回根模块和 `apis`** | **必须跟着 `go mod tidy`** |
  | `tests/test-e2e-apps/bridge-server/go.mod` | 完全独立，不引用根模块 | 不用动 |

  漏掉 `integrationtest` 的后果很硬：`make generate` 里的 controller-gen 以 `paths=./...` 加载包时
  会走进这个嵌套模块，报 `Error: load packages in root ".../integrationtest": go: updates to go.mod needed`，
  于是**流水线的「Build the operator binary」在开编之前就挂**，PR 的 `Unit tests`（`make ci`）也一起红。
  `gomod-bump.sh` 现在会自动 tidy「replace 了根模块」的嵌套模块，但你得认识这个报错才看得懂现场。
- 扫出来的漏洞库多半是 **indirect** 依赖。`go get` 会在 `go.mod` 写下显式 require 行，`go mod tidy`
  会保留它（标 `// indirect`）——这是强制抬升 indirect 依赖的标准做法，不要因为它是 indirect 就跳过。
- **流水线是 `workflow_dispatch` 触发的，PR 不会触发任何镜像构建**，所以建完 PR 必须显式触发一次
  才能拿到回归扫描用的新镜像（做法与 `.claude/skills/sync-upstream` 的步骤 6 相同）。
  每次触发会新建一个 **draft GitHub Release**，且 rc 序号必须递增：序号不变会覆盖同名镜像 tag
  （回归扫描可能扫到旧镜像），也会让 `gh release create` 撞 tag 直接失败。
- 修复基线 = 执行时**当前检出的分支**（通常 `main`）。修复在当前工作区切到 `fix/cve-<日期>` 分支进行
  （与 sync-upstream 一致），所以开工前工作区必须干净。
- git 规矩：**禁止 `git commit --amend`**，一律新建 commit；message 不带 `Co-Authored-By` / `Claude-Session`；
  本仓库不要求 DCO，不必加 `-s`。gh 命令必须显式 `--repo alauda-mesh/opentelemetry-operator`（脚本已内置）。
- 修复轮次上限 **3 轮**（首轮 + 回归后最多再修 2 次），修不完就如实汇报，别继续盲改。
- 状态目录 `.git/otel-op-fix-vulns/`（在 `.git/` 下，不入库），各脚本经 `state.env` 与若干 tsv 串联。

## 步骤 1：漏洞检测

```bash
bash "$SKILL_DIR/scripts/resolve-input.sh" <run|镜像 ...>   # 几秒
bash "$SKILL_DIR/scripts/scan-images.sh"                    # Bash timeout 设 600000（服务端要先拉镜像）
```

扫描服务优先用 `192.168.141.42:8888`，不可达时自动切备用 `192.168.25.100:8888`（备用地址常故障）。
扫描返回的 JSON 里 `Description` 字段极长，脚本已只输出紧凑行，**不要去 cat 原始 JSON**。

`resolve-input.sh` 若警告 run 所在分支与修复基线不一致，说明被扫的镜像和将要修的源码可能不是同一份。
**先自己查一下那条分支是否已合进基线**（feature 分支构建完就合进 main 是常态，不必上来就打断用户）：

```bash
git fetch origin main -q
git branch -a --contains "$(gh run view <RUN_ID> --repo alauda-mesh/opentelemetry-operator --json headSha --jq .headSha)"
```

输出里含基线分支（如 `main`）即已合入，说明源码一致，直接继续；**没合入才停下来**问用户该以哪条分支为基线。

**无论有没有漏洞，都先给用户一份扫描摘要**（镜像、每条漏洞的分类/包/CVE/严重度/当前版本→修复版本、
SUMMARY 分类计数、修复目标表）。然后按 `RESULT:` 分支：

- **CLEAN**：无漏洞，汇报后直接结束；
- **REPORT_ONLY**：剩余全是不修复项（os 级 / 无修复版本），列出明细与原因，结束；
- **FIX_NEEDED**：继续步骤 2～5。

## 步骤 2：修复

```bash
bash "$SKILL_DIR/scripts/create-fix-branch.sh"    # 输出 BRANCH= / BASE=
```

基线分支领先 origin 时脚本会终止（防止把未 push 的 commit 混进 PR），按提示与用户确认。

**go stdlib 漏洞**（版本取扫描输出的修复候选，格式 X.Y.Z 不带 go 前缀）：

```bash
bash "$SKILL_DIR/scripts/update-go-version.sh" <X.Y.Z>
```

输出 `CROSS_MINOR` 时说明跨了 minor，按提示确认影响面，并在 PR 正文与最终报告里着重说明。

**go.mod 依赖漏洞**（目标以扫描输出的「修复目标」表为准；候选没有 `v` 前缀，拼 `go get` 时要加上）：

```bash
bash "$SKILL_DIR/scripts/gomod-bump.sh" <module@vX.Y.Z> [...]   # 建议 run_in_background: true
```

本轮只改了 go-version、没动 go.mod 时，用 `gomod-bump.sh --build-only` 单做构建验证。
脚本会自动 tidy「replace 了根模块」的嵌套模块，然后跑**两步**验证：`go build ./...`
再加 `make generate`——后者是流水线编译前的必经步骤，也是唯一能提前暴露跨模块失配的本地手段，
**只看 `go build` 通过就提交 = 假的绿灯**。
构建验证实测：热 build cache 约 30 秒，**冷缓存（或依赖大面积升级后）约 7.5 分钟**——
后者后台跑起来之后就去写 PR 正文、顺手把 `trigger-release.sh --dry-run` 也跑掉，别干等。

修复注意事项：

- 库之间有版本约束，实际落位版本可能高于扫描给的修复候选，属正常，脚本会打印实际版本；
- `go get` 报 `A@vX requires B@vY, not B@vZ`：把 B 的目标提到 vY 重跑（vY 更高，CVE 覆盖不受影响）；
- 同一发布系列的包（`k8s.io/*`、`go.opentelemetry.io/collector/*`、`google.golang.org/grpc` 相关等）
  版本要成套对齐，编译报 API 不匹配就说明只升单个组件不够；变更面大时在 PR 正文里说明；
- 落位版本以扫描器给的修复候选为准，**别照 advisory 原文自行换用其他修复分支**——Go 漏洞库常只收录主线，
  换线会导致镜像扫描无法清零；
- 无修复版本的 CVE 升级修不了，记入最终汇报的「未修复项」；
- tidy 后**审查连带升级面**：`git diff go.mod` 看基础库（k8s.io、controller-runtime、collector 系列等）
  是否被大幅拉升，异常拉升要评估影响或回钉；
- 手工 `cd` 进子模块（如对齐 `apis/`）时注意 **Bash 工作目录会跨调用保留**：下一条命令仍在子目录里，
  `git diff -- apis/` 会报 ambiguous argument，更坑的是 `go build ./...` 验的其实是子模块，
  得出**假的"根模块构建通过"**。每条命令显式 `cd` 回仓库根，或用 `( cd apis && ... )` 子 shell；
- 构建失败时先分析原因（版本冲突、新版本要求更高 go、API 变更），能明确解决就解决，
  拿不准就带着报错向用户提问，不要凭猜测做大版本连锁升级。

**提交**（两类修复各自独立 commit，禁止 amend）：

- go.mod：`fix(deps): bump vulnerable go modules`
- go-version：`ci: bump go to X.Y.Z for <CVE编号>`

## 步骤 3：创建 PR

先把 PR 正文写进 scratchpad 临时文件：扫描摘要（镜像、分类计数）+ 修复清单（每项：包/模块、版本变化、
覆盖的 CVE）+ 本地构建验证结论 + 不修复项说明（os 级 / 无修复版本）+ 结尾一行
`🤖 Generated with [Claude Code](https://claude.com/claude-code)`。然后：

```bash
bash "$SKILL_DIR/scripts/create-pr.sh" <正文文件>    # 输出 PR_NUMBER= / PR_URL=
```

幂等：分支已有 open PR 时复用，回归轮追加 commit 后重跑即可（只 push，不重复建 PR）。

## 步骤 4：触发并监控流水线

PR 不触发构建，要显式触发一次。先算参数：

```bash
bash "$SKILL_DIR/scripts/trigger-release.sh" --dry-run
```

脚本从 workflow 默认值和历史 run 标题推出 `release_version` / `bundle_version` 的下一个 `-rc.<n>`，
`collector_tag` 用默认值，外加 `is_draft_release=true`、`is_pre_release=false`。
**触发会新建 draft GitHub Release，所以要用 AskUserQuestion 把参数交给用户确认后再正式触发**
（参数错了要手工清理）。确认后：

```bash
bash "$SKILL_DIR/scripts/trigger-release.sh"
# 需要覆盖时：trigger-release.sh --bundle-version 0.156.0-rc.3 --release-version 2.1.0-rc.3
```

然后监控。self-hosted runner 上的双平台构建通常 10~40 分钟，**必须后台运行**（`run_in_background: true`），
完成后会收到通知。好消息是**失败暴露得很快**：`make generate` / 编译类问题 1~2 分钟内就返回
（实测一次 59s 就挂在 `make generate`），所以短时间内返回八成是失败而不是构建飞快：

```bash
bash "$SKILL_DIR/scripts/watch-release.sh"
```

等待期间查进度就 Read 后台任务的输出文件；不要前台 `sleep` 轮询（harness 会拦截），
确需定时等待用 Monitor 工具。这段时间可以顺手做别的收尾工作（整理汇报、补文档），别浪费。

按退出结果处理：

- **PIPELINE_SUCCESS（0）**：ROUND 已 +1、新镜像清单已生成，进入步骤 5。输出里列出的 PR check 失败项要分析：
  与本次修复相关（依赖升级把 lint/test/e2e 弄挂）就修；fork 上的固有失败如实记入最终报告即可。
  **归因别靠猜，用两组对照**：`gh pr checks <上一个 PR 号>` 看同名 check 在别人的 PR 上是不是也红（红=fork 固有），
  以及 `gh run list --branch main --limit 15` 看 main 上的 CI 本来就什么状态。
  实测参考：`Check for Tag Pinned Actions` 在本 fork 恒红；`Govulncheck` 在修复前的 main 上是红的
  （红的正是这批 CVE），修完转绿，可当作修复生效的旁证；
- **PIPELINE_FAILED（2）**：脚本已附失败概览与日志摘要。**分析失败原因**：是本次修复引入的
  （依赖升级编译错、go-version 写错或 runner 下载不到）还是环境问题（runner 离线、harbor 登录、
  yq 版本、基础镜像拉取）。属于本次修复引入的**最多尝试修复 2 次**：追加 commit → `create-pr.sh` push →
  重新 `trigger-release.sh` → 后台 `watch-release.sh`。两次仍失败、或原因是环境问题、或方案拿不准，
  就停下来把分析交给用户，不要继续盲改；
- **PIPELINE_TIMEOUT（3）**：告知用户流水线仍在跑并附 run 链接，稍后可重跑本脚本继续等。

## 步骤 5：回归扫描与迭代

```bash
bash "$SKILL_DIR/scripts/scan-images.sh"    # ROUND 已 +1，自动扫本轮新镜像
```

- **CLEAN / REPORT_ONLY**：修复完成——先用 `gh pr comment --repo alauda-mesh/opentelemetry-operator`
  把回归扫描结论回填到 PR 供 review 参考，再进入最终汇报；
- **FIX_NEEDED**：先分析为什么还有漏洞（上轮目标版本本身仍带 CVE？升级没生效？新版本引入了新漏洞？），
  再回到步骤 2 继续修——**不新建分支**，在当前分支追加 commit → `create-pr.sh` push →
  `trigger-release.sh` → 后台 `watch-release.sh` → 再扫描。

**最多 3 轮修复**。到限仍未清零就停止，如实汇报剩余漏洞、已尝试的措施和失败原因，让用户决策。

## 最终汇报

用清晰列表汇报：

1. 输入（run / 镜像）与解析出的扫描清单；
2. 首轮扫描摘要（总数、分类计数）→ 修复清单（包/模块、版本变化、覆盖的 CVE、commit）→
   PR 链接 → 流水线 run 与结果 → 回归扫描结论；
3. 剩余不修复项：os 级漏洞明细、无修复版本或修不掉的项及原因（注明不在修复范围）；
4. PR 上失败的 check 及归因（fork 固有 / 本次修复引入）；
5. 若 go-version 跨了 minor/大版本，**着重强调**该变化及原因；
6. 本次触发流水线产生的 draft GitHub Release（tag 列表），提示用户按需清理。

不要自行 merge PR，也不要 publish draft release，等用户 review。
