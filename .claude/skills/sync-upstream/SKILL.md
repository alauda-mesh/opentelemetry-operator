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

- 本仓库是 `open-telemetry/opentelemetry-operator` 的 fork，**ACP 的定制面极小**——只有 9 个固定**路径**与上游不同：
  `.claude/`（整个目录，含本 skill）、`.github/workflows/alauda-release.yaml`、`.gitignore`、`Dockerfile.alauda`、
  `Makefile`（只在首行加了 `-include Makefile.alauda.mk`）、`Makefile.alauda.mk`、`alauda/README.md`、
  `alauda/alauda-csv.yaml`、`hack/alauda-patch.sh`。
  这意味着升级本身通常很顺，**真正需要动脑的是 bundle CSV 的跟进（步骤 4）**。

  但**定制面不止这 9 个**：`fix-image-vulns` skill 修 CVE 时会 bump `go.mod`/`go.sum`（含 `apis/`、
  `cmd/otel-allocator/integrationtest/` 子模块），这些改动同样是 ACP 定制，而且**恰恰是最容易冲突的**
  （上游每个 release 都在动依赖）。所以合并冲突的真实来源有两类：`Makefile`/`.gitignore`（"两边都要"）
  和 go 模块文件（比版本号高低，见步骤 1）。合并后这样核对定制面没被冲掉
  （注意 `.claude/` 会展开成十几个文件，所以行数远多于 9，别被吓到）：

  ```bash
  git diff --name-only <上游tag> HEAD | grep -v '^\.claude/'
  ```

  预期输出 = 上面除 `.claude/` 外的 8 个路径，**外加尚未被上游追平的 go 模块文件**。
  实测 v0.157.0 那次多出 `apis/go.mod`、`apis/go.sum`（上游的 `golang.org/x/text` 还停在 v0.37.0，
  低于 ACP 的 CVE 修复版本 v0.39.0，所以定制得留着）。
  多出**这两类以外**的文件才说明定制面变了，停下来问用户。
- ACP 的 OLM bundle 走 **community** 变体：流水线执行 `make bundle -e BUNDLE_VARIANT=community`，
  再用 `make alauda-patch` 把 `alauda/alauda-csv.yaml` 合并进
  `bundle/community/manifests/opentelemetry-operator.clusterserviceversion.yaml`。
  **openshift 变体的内容不会自动进入 ACP 产物**，所以每次升级都要看一眼 openshift 那边多做了什么、值不值得跟进。
- `hack/alauda-patch.sh` 的合并语义决定了跟进成本，判断时必须清楚（**别凭记忆，每次读一遍脚本**——
  它是会长的，`resources` 那条就是后加的）：
  - `spec.install.spec.deployments` **以外**的部分用 yq 的 `. *=` 深合并 —— 想加什么直接写进 `alauda/alauda-csv.yaml` 即可；
  - `deployments` 里目前只处理两样：`.env += ...`（追加环境变量）和 `.resources *= ...`（深合并资源配置，
    保留上游已有的 requests）—— 这两类跟进是零成本的；
    而 `volumeMounts` / `volumes` / `args` / 探针这类改动，光改 `alauda/alauda-csv.yaml` 不会生效，
    还得改 `hack/alauda-patch.sh` 增加对应的 yq 逻辑。**评估建议时要把这条成本说清楚。**
- **patch 有两种静默失效，都不会让 `make alauda-patch` 报错**，是整个升级里最隐蔽的风险，
  所以步骤 4 开头有两项强制核对（见下）：
  - `.env +=` 是纯追加，上游删掉/改名某个 env 时 CSV 里照样有这个 env，但 operator 根本不读它；
  - 两条 deployments 规则都靠 `with(... select(.name == "opentelemetry-operator-controller-manager")
    ... select(.name == "manager"); ...)` 定位，**yq 的 `with` 选不中目标时是静默 no-op**。
    上游一旦改了 deployment 名或容器名（例如把 webhook 拆成独立 Deployment 时顺手重命名 manager），
    patch 就什么都不做，退出码依然是 0，bundle 里悄悄少了全部 ACP 配置。
- 流水线 `.github/workflows/alauda-release.yaml` 是 **`workflow_dispatch` 触发**的，
  PR 本身不会触发任何构建，所以建完 PR 还要单独触发一次做构建验证。
- 触发时用 `-rc.<n>` 后缀 + `is_draft_release=true`：产物是 draft release，不会污染正式版本；
  `--draft` 的 release 在 publish 之前不会真的创建 git tag。
- 各脚本的中间产物（merge 日志、构建日志、CSV diff、步骤间状态）都放在 `.git/otel-op-sync/` 下，
  不会污染工作区，需要翻原始数据时去那里找。
- 全程禁止 `git commit --amend`，一律创建新 commit，message 里不要带 `Co-Authored-By`。
  步骤 5 之前不要 push、不要建 PR。
- **步骤编号是决策顺序，不是必须串行等待的顺序**。`verify.sh` 要下载工具链、拉 Go 依赖，
  通常 5~15 分钟；`csv-diff.sh` 是纯只读的，不依赖构建结果。正确做法是 `verify.sh` 后台跑起来的同时
  就去做步骤 4 的 CSV 分析，把报告先抛给用户 review，否则这十几分钟纯属干等。
  实测 v0.147.0 → v0.156.0 这一趟，从 `verify.sh` 起跑到用户看到 CSV 报告只花了几分钟，
  等于把整个校验时间藏进了 review 环节。
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
- **CONFLICT（2）**：脚本已列出冲突文件。已知的冲突只有三类，都不必问用户，按下面解：
  `Makefile`（保留首行 `-include Makefile.alauda.mk`，同时合入上游新增内容）、
  `.gitignore`（两边的 ignore 行都保留）、**go 模块文件**（`go.mod`/`go.sum` 及 `apis/`、
  `cmd/otel-allocator/integrationtest/` 子模块的同名文件，见下面一小节）。
  冲突出现在**这三类以外**的文件，才说明 ACP 定制超出了已知范围，**停下来向用户确认**再解决。
  解决后 `git add <文件> && git commit --no-edit` 完成合并（禁止 amend），然后继续步骤 2。

  Makefile 的冲突形态要有心理准备：**上游也会往第 1 行塞东西**。v0.156.0 就把 `e2e-httproute`
  目标加在了 `# Current Operator version` 之前，正好和 ACP 的 include 同址，冲突块长这样：

  ```
  <<<<<<< HEAD
  -include Makefile.alauda.mk

  =======
  # Run e2e tests for httpRoute
  .PHONY: e2e-httproute
  ...
  >>>>>>> v0.156.0
  ```

  解法是 ACP 的 include 留在第 1 行、上游块紧随其后。**解完必须验证 include 仍然生效**，
  肉眼看 `head` 不算数（缩进/位置错了照样"看着对"）。**两条命令要分开跑，别用 `&&` 串起来**——
  `grep -c` 数出 0 个匹配时退出码是 1，会把后面的检查整个短路掉，看上去像"没输出所以没问题"：

  ```bash
  grep -c '<<<<<<<\|>>>>>>>' Makefile          # 必须是 0
  make -n alauda-patch >/dev/null && echo OK   # 能解析出 alauda-* 目标才说明 include 生效
  ```

### go.mod / go.sum 冲突（最常见，v0.157.0 那次 4 个文件全是它）

成因是固定的：`fix-image-vulns` skill 为修 CVE 手动 bump 过间接依赖，而上游每个 release 也在 bump
同一批依赖，于是同一行两边都改 → 冲突。**处理原则是比版本号高低，而不是无脑选一边**：

1. 先弄清 ACP 那侧到底为什么改。看提交消息，CVE 编号一般写得很清楚：

   ```bash
   git log --oneline <基线tag>..origin/main -- go.mod go.sum '*/go.mod' '*/go.sum'
   git show <那个commit>          # 消息里通常列了 CVE/GHSA 编号与目标版本
   ```

2. 逐个比较冲突依赖的两侧版本：
   - **上游 ≥ ACP 修复版本**（绝大多数情况，上游 bump 得比我们勤）→ 取上游，CVE 修复被自然覆盖；
   - **上游 < ACP 修复版本** → **必须保留 ACP 的版本**，否则这次升级会把已修的漏洞放回去。
     子模块尤其要留神：v0.157.0 那次上游 `apis/go.mod` 的 `golang.org/x/text` 还停在 v0.37.0，
     比 ACP 的 v0.39.0 低，幸好那个文件自动合并保留了 ours——**自动合并成功 ≠ 结果正确，要点开确认**。

3. 取上游用 `git checkout --theirs`，**它只改工作区、不改 index**，之后必须 `git add`，
   否则文件一直是 `UU`（unmerged）状态，`git commit` 会拒绝：

   ```bash
   git checkout --theirs go.mod go.sum cmd/otel-allocator/integrationtest/go.mod cmd/otel-allocator/integrationtest/go.sum
   ```

4. **go.sum 不要手工解冲突**，删掉冲突标记后跑上游自带的 `make tidy`（v0.157.0 起有这个目标，
   会遍历仓库里每个 go module 跑 `go mod tidy`）重建，几分钟，需要联网拉依赖：

   ```bash
   make tidy      # 老版本没有这个目标时，逐个模块 cd 进去 go mod tidy
   ```

5. 落地前验证一遍关键版本，确认 CVE 没被回退（把依赖名换成第 1 步查到的）：

   ```bash
   grep -E 'golang.org/x/text|google.golang.org/grpc |github.com/google/cel-go' go.mod apis/go.mod
   ```

   然后 `git add` 全部冲突文件 + `git commit --no-edit`，并确认 `git diff --name-only --diff-filter=U` 为空。
   这几条结论（哪些取了上游、哪些保留了 ACP、对应 CVE 是否仍被覆盖）要写进 PR 正文和最终汇报——
   这是评审者最关心的部分。
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

脚本依次跑三项检查，全程 5~8 分钟。**前两项谁是瓶颈取决于缓存状态，别按固定印象预估**：

1. `make manager` —— 编译 operator 二进制。Go 依赖有缓存时 26 秒；上游大改依赖时要重编大量包，
   实测 v0.156.0 → v0.157.0 用了 3 分 36 秒；
2. `make ensure-update-is-noop` —— 校验 `zz_generated.*.go` / `bundle` / `config` / `docs/api` 与源码一致。
   首次要下载 operator-sdk（83.8MB）和 kustomize，实测 7 分钟；工具链已缓存时只要 1 分 40 秒；
3. `make alauda-patch` —— 校验 `hack/alauda-patch.sh` 仍然可用（它写死了 bundle 路径和 yq 表达式，
   上游改动 bundle 布局时会失效）。几秒钟。跑完自动 `git checkout -- bundle/` 还原临时改动；
   本地没有 yq 或 `bundle/` 有未提交改动时会自动跳过。
   **注意它只能发现"脚本跑不起来"，发现不了"选择器没选中"**（见背景知识的静默 no-op），后者靠步骤 4 的核对。

看进度就 tail **后台任务的 output 文件**（只有干净的阶段行）。
**不要直接 tail `.git/otel-op-sync/verify.log`** —— operator-sdk 用不带 `-s` 的 curl 下载，
几百行进度条（单行数万字符）全写进去了，会直接刷屏。非看 verify.log 不可时先过滤：

```bash
grep -vE '^\s*[0-9]+\s+[0-9.]+[MGk]?\s' .git/otel-op-sync/verify.log | tail -20
```

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

**先做两项强制核对，对应背景知识里的两种静默失效。**

**核对一：patch 的 yq 选择器还能不能选中目标。** 脚本靠 deployment 名 + 容器名定位，
上游改名就变成静默 no-op、退出码照样是 0：

```bash
yq '.spec.install.spec.deployments[].name' bundle/community/manifests/opentelemetry-operator.clusterserviceversion.yaml
yq '.spec.install.spec.deployments[] | select(.name=="opentelemetry-operator-controller-manager").spec.template.spec.containers[].name' \
   bundle/community/manifests/opentelemetry-operator.clusterserviceversion.yaml
```

必须分别出现 `opentelemetry-operator-controller-manager` 和 `manager`（与 `hack/alauda-patch.sh`
里写死的两个 `select` 一致）。对不上就得同步改 patch 脚本的选择器，并停下来告诉用户。
顺带 `grep -o "deploymentName: .*" ... | sort -u` 看一眼 webhook 指向，这个结果在步骤 4 的判断里还要复用。

**核对二：ACP 已 patch 的 env 在新版本源码里是否还被读取。**
`.env +=` 只追加不校验，上游删掉或改名任何一个 env，patch 都会静默失效（见背景知识）。
从 `alauda/alauda-csv.yaml` 里取出 env 名单逐个查 `internal/config/env.go`：

```bash
for e in $(yq '.spec.install.spec.deployments[].spec.template.spec.containers[].env[].name' alauda/alauda-csv.yaml); do
  grep -q "LookupEnv(\"$e\")" internal/config/env.go && echo "  OK   $e" || echo "  !!!! $e 在源码中已找不到"
done
```

**这条命令输出为空就是路径写错了，不是"没有 env"**——`alauda-csv.yaml` 里 env 至少有 4 个，
空输出说明 yq 表达式没匹配上（漏掉顶层 `.spec` 是最常见的写法错误），别把空输出当成通过。
没有 yq 就把名单手抄下来遍历。上游若挪走了 `internal/config/env.go`，改成
`grep -rn "LookupEnv(\"$e\")" --include=*.go internal/ cmd/`。
出现 `!!!!` 就**停下来告诉用户**——这意味着该配置在新版本上已经失效，需要找替代方式，
不能当作"升级顺利"糊弄过去。全 OK 也要写进最终汇报，这是一条有价值的结论。

然后跑差异分析：

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

逐条判断时**按顺序**考虑这几件事：

1. **ACP 是否已经有了**——对照 D 的 env 名单和 patch 内容，已有的直接标注"已覆盖"，不要让用户重复 review；
2. **上游 community 变体自己做没做**——这条最省事，却最容易被忽略，**判断不下来时先查它**。
   ACP 的 bundle 基底就是 community 变体，凡是 community 自己都没采纳的东西，跟进就等于主动偏离基底，
   基本可以直接定性为"不跟进"，理由也现成。查法（以 v0.156.0 的 webhook 拆分为例）：

   ```bash
   grep -c "opentelemetry-operator-webhook" bundle/community/manifests/opentelemetry-operator.clusterserviceversion.yaml
   grep -o "deploymentName: .*" bundle/community/manifests/opentelemetry-operator.clusterserviceversion.yaml | sort -u
   ```

   实例：v0.156.0 上游把 webhook 从 manager 拆成了独立 Deployment，但**只在 openshift 变体里拆**，
   community 变体的 `deploymentName` 仍然是 `opentelemetry-operator-controller-manager`。
   这类改动表面上像是通用的 HA 改进（不带 OpenShift 字样），只看第 3 条会纠结很久，
   查一眼 community 就一锤定音了。
3. **是否 OpenShift 专属**——依赖 OpenShift 特有资源（console dashboard、`service.beta.openshift.io` 证书注入、
   `config.openshift.io/apiservers`、OpenShift 监控栈等）的内容，ACP 环境上不成立，一般不跟进。
   注意有些 env 名字看不出来（如 `TLS_CLUSTER_PROFILE`），要追到源码里看它读什么资源才能下结论；
4. **跟进成本**——是纯 env（改 `alauda/alauda-csv.yaml` 即可，零成本），还是涉及 volumes/volumeMounts/args
   （必须同时改 `hack/alauda-patch.sh` 的 yq 逻辑）。成本高的要在建议里如实写出来。
   **零成本 ≠ 该跟进**：alpha 阶段的 feature gate（如 `FEATURE_GATES=*.networkpolicy`）虽然只是一个 env，
   但会让 operator 开始自动创建 NetworkPolicy，属于行为变更，应该建议单独立项验证而不是随升级捎带。

另外，A 池里有不少是**历史遗留项**（上一版就存在、本次没变）。它们不属于"本次增量"，
但如果之前从没走过这个 review 流程，仍要列进表格让用户过一遍——只是要在表格里标明来源是
「A（历史）」还是「B 新增」，别让用户误以为都是这次上游刚改的。

**「B 减 C = 空」是很常见的结果，别硬找活干。** 上游多数 patch 版本在 openshift CSV 上只动四类字段：
`createdAt`、CSV `name`、镜像 tag、`version`——全是版本号，没有功能性新增（v0.156.0 → v0.157.0 就是如此，
B 的 diff 只有 47 行且全是这四类）。判断依据很直接：B 的 diff 里除了这四类还剩什么。
这种情况下照样把表格给全（A 池历史项 + 标注"上次已 review，结论不变"），
但开头一句话就要说清"本次增量为零"，AskUserQuestion 的推荐项直接给"都不跟进"，
别把历史项重新包装成新问题耗用户的时间。

然后输出**编号报告**给用户 review：

```markdown
| # | 内容 | 来源 | ACP 现状 | 跟进成本 | 建议 | 理由 |
|---|-----|------|---------|---------|------|------|
| 1 | webhook 拆为独立 Deployment | B 新增 | 未包含 | 极高（新增整个 deployment + 改 13 项 webhookdefinitions） | 不跟进 | 上游 community 变体自己也没拆 |
| 2 | METRICS_TLS_CERT_FILE + 证书卷挂载 | A（历史） | 未包含 | 高（需改 alauda-patch.sh 支持 volumes） | 不跟进 | 依赖 OpenShift 证书注入 |
| 3 | ENABLE_GO_AUTO_INSTRUMENTATION=true | A | 已在 alauda-csv.yaml | - | 无需跟进 | 已覆盖 |
```

表格前面先用一两句话交代**「B 减 C」的结论**（本次上游在 openshift 侧真正新增了什么）和
**已随 merge 白拿的部分**（RBAC 调整、镜像/版本号等），让用户一眼看出这次的决策面有多大。

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

**`release_version` 是产品版本线，脚本只会沿着历史往下顺延，猜不出用户的发版意图**
（实测：脚本算出 `2.0.0-rc.11`，用户实际要的是 `2.1.0-rc.1`——大版本升级配大版本号，这是人的决定）。
所以确认环节要把它当成一个**真正的问题**问出来，而不是让用户对一串参数点"确认"。

`update-defaults.sh` 不会改 workflow 里 `release_version` 的默认值（只会打印出来提醒）。
**用户一旦选了新版本线，触发完就要回头把默认值一起改掉并提交**，否则下次同步还会沿着旧版本线算：

```bash
# 例：用户选了 2.1.0-rc.1，就把默认值从 2.0.0 改成 2.1.0
git add .github/workflows/alauda-release.yaml && git commit -m "chore: bump release_version default to 2.1.0"
```

顺带核对一下 `collector_tag` 与目标版本的关系：ACP collector 有自己的发版节奏，
可能领先或落后 operator（本次 operator 0.156.0 配 collector 0.158.0-r0，因为 collector 仓库没有 0.156.x）。
这不是错误，但**要在确认时向用户说明**，别让人事后才发现版本对不上。

**用 AskUserQuestion 把参数交给用户确认后再正式触发**——触发会产生一个 draft GitHub Release，
参数错了要手工清理。确认后：

```bash
bash "$SKILL_DIR/scripts/trigger-release.sh"
# 需要覆盖某个参数时：trigger-release.sh --release-version 2.1.0-rc.1 --bundle-version 0.156.0-rc.0
```

然后监控。self-hosted runner 上的双平台镜像构建通常 10~40 分钟（v0.156.0 那次实测只用了 6 分钟，
runner 空闲时会快很多），**必须用后台方式运行**（`run_in_background: true`），完成后会收到通知：

```bash
bash "$SKILL_DIR/scripts/watch-release.sh"
```

**流水线运行期间往升级分支 push 是安全的**，不必干等：`workflow_dispatch` 在触发时就把 ref
解析成了固定 SHA，`actions/checkout` 默认取的正是这个 `github.sha`，后续提交不会被卷进正在跑的 run。
拿不准时核对一下 `gh run view <run-id> --json headSha` 与触发时的 HEAD 是否一致即可。
所以监控期间可以顺手做别的收尾工作（补文档、整理汇报），别浪费这段时间。

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

1. **分支与版本**：分支名、`OLD → NEW` 版本、合入的上游提交数、冲突及解决方式。
   go 模块冲突要逐个依赖说清"取了哪边、CVE 是否仍被覆盖"，别只写一句"解决了依赖冲突"；
2. **流水线默认值**：`bundle_version` 和 `collector_tag` 的新旧值，collector tag 的来源；
   若用户在步骤 6 换了 `release_version` 版本线，这里要提醒 workflow 里的默认值已过期；
3. **本地校验**：VERIFY_OK/FAILED，失败过则说明修了什么；外加步骤 4 那项 env 有效性核对的结论；
4. **CSV 跟进**：逐条结论（跟进了什么 / 为什么跳过），改了哪些文件；
5. **PR**：链接与提交列表；
6. **流水线**：run 链接与结果，成功则给出
   `build-harbor.alauda.cn/asm/opentelemetry-operator2:<bundle_version>` 与
   `...-bundle:v<bundle_version>` 两个镜像名和 draft release 链接，失败则给出原因分析与已尝试的修复。

到此流程结束，等用户 review 与合并。
