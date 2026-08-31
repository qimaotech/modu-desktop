# Modu Desktop PRD

- 日期：2026-09-01
- 状态：v0.1 产品与系统契约
- 目标版本：本地开发版

## 0. 文档职责

本文回答“产品和系统必须做什么”，是以下内容的唯一事实源：

- 产品范围、数据模型和业务不变量。
- 工作区、仓库、同步和 worktree 生命周期。
- 文件安全、并发、恢复、CLI 和核心技术契约。
- 测试范围、里程碑和功能验收。

用户如何看到和操作这些能力，由 [`DESIGN.md`](DESIGN.md) 定义；Figma 与 [`design/prototypes/`](../design/prototypes/) 只提供代表性视觉参考。本文不重复像素、布局、控件外观、菜单排版、焦点和 VoiceOver 规则，也不把示例数据当作业务约束。

文中的“必须”“不得”“只允许”为规范性要求；“例如”“示例”为非规范性说明。若文档、原型与实现不一致，先修正规则所属的事实源，再同步其他内容，不用后出现的材料静默覆盖前者。

## 1. 产品定义

### 1.1 背景与定位

跨仓库需求通常要求开发者在 Finder、终端、Git 工具、编辑器和 Agent 之间反复定位同一组目录，并自行维护多个 linked worktree。Modu 是这些工具之上的本地工程工作流层，负责：

- 在一个工作区内组织多个主仓库和跨仓库 Worktree Group。
- 为 Agent 提供稳定的 `modu-cli` 和内置 skill。
- 把当前工作区、主工作树或 linked worktree 安全地交给外部工具。
- 统一展示受管工作树的变更和相关提交。

Modu 不替代 Codex、Claude Code、Git GUI、编辑器或终端。

### 1.2 v0.1 目标

v0.1 完成以下闭环：

1. 安装 `modu-cli` 并选择一个当前工作区。
2. 初始化工作区结构与内置 skills 符号链接。
3. 通过 GUI 或 `.modu.yaml` 管理主仓库并执行声明式对账。
4. 通过 GUI、内置 skill 或 CLI 创建、编辑和删除跨仓库 Worktree Group。
5. 在主工作树和 linked worktree 间导航，并用外部工具打开当前上下文。
6. 查看当前工作树相对 Base 的差异文件和差异提交；主工作树与 linked worktree 使用同一套差异语义。

目标规模为 5–20 个主仓库、约 5 个活跃 Group、最多约 30 个 linked worktree。Git 历史按选择懒加载。

### 1.3 非目标

v0.1 不包含：

- 内置 AI 对话、Agent 编排或提示词生成系统。
- 任意指定 worktree 路径、分支或 document 的高级 GUI 表单。
- staging、commit、merge、rebase 或逐行 diff 等完整 Git GUI 能力。
- 多工作区、自定义外部工具或团队云同步。
- 对 linked worktree 执行 repositories 级全局 Fetch/Pull。
- 初始化或维护工作区自身的 Git、`.gitignore` 或提交策略。
- Developer ID 签名、公证、自动升级和正式分发验证。
- 量化性能验收指标。

### 1.4 产品原则

- **文件是事实源**：工作区配置属于用户，Modu 只按契约读取和编辑。
- **共享能力单一实现**：App 和 CLI 使用同一套 Core 逻辑。
- **补齐自动、删除审慎**：声明式配置可自动触发 additive 操作；cleanup 必须先形成当前计划并获得明确授权。
- **幂等可恢复**：多仓库操作保留已完成项，失败项可安全重试。
- **原生且克制**：优先复用 macOS 26 原生组件和行为，不构建卡片式仪表盘。
- **错误不伪装为安全**：未知身份、路径或风险进入错误或 conflict，不按空、clean 或成功处理。

### 1.5 领域术语

- **工作区（Workspace）**：用户选择的目录及其中两份配置、`repositories/`、`worktrees/` 和受管 skill 链接的整体；v0.1 同时只激活一个。
- **主仓库（Repository）**：由 `.modu.yaml` 声明、目录位于 `repositories/<repo-name>` 的 Git 仓库；其默认 checkout 称为**主工作树（main worktree）**。
- **Worktree Group（Group）**：围绕同一跨仓库需求组织的一组 linked worktree；Group 身份同时决定默认目录段与默认本地分支名。
- **linked worktree**：属于某个 Group、位于 `worktrees/<group>/<repo-name>` 的 Git linked worktree。
- **受管后代（managed descendant）**：通过规范化、身份和符号链接检查后，能证明位于当前工作区 `repositories/` 或 `worktrees/` 内且属于 Modu 记录的资源；路径位于目录下只是必要条件，不单独证明归属。
- **当前计划（current plan）**：在执行锁内根据最新配置、路径、Git 身份和风险重新计算的操作集合；旧预览、旧确认和应用重启前的计划都不能替代它。

### 1.6 操作授权模型

下表只定义“什么输入授权什么副作用”；风险字段、执行顺序和失败恢复由对应生命周期章节定义。

| 入口 | 可授权范围 | 授权方式 | 不授权的内容 |
| --- | --- | --- | --- |
| 有效声明的 additive 对账 | clone、origin 更新、补齐 Group 成员 | 有效配置或创建提交 | 任何 cleanup |
| Edit Worktree Group | 新增勾选项；移除除最后一个外的既有项 | 一次 `Save Changes`；存在 removal 时使用 destructive 样式 | Group 名变更、远端分支删除、未从 checked 改为 unchecked 的成员 |
| Delete Linked Worktree / Group | 当前确认计划中的 linked worktree 与记录本地分支 | 独立 destructive 确认；clean 也不能跳过 | 远端分支与计划外成员 |
| Delete Repository / 声明式 cleanup | 当前确认计划中的关联 worktree、本地分支与主仓库 Trash 移动 | 独立 destructive 确认 | 远端仓库、远端分支与新计划 |
| Doctor `--repair` | 能证明无数据损失的元数据或受管链接修复 | 显式 `--repair` | 分支、有内容目录和承载失败状态的记录删除 |

编辑配置、生成计划、旧预览、旧确认或 `--yes` 本身都不能扩大表中的授权范围。所有破坏性操作执行前仍须在锁内重算当前计划。

## 2. 系统边界

### 2.1 组件职责

```text
ModuDesktop ─┐
             ├─ ModuCore ── YAML / 文件系统 / Git / 外部应用
modu-cli ────┘
```

- `ModuDesktop`：SwiftUI macOS 薄客户端，负责窗口、展示状态、用户意图和全局偏好；不直接承载 Git、文件系统或 YAML 副作用。
- `modu-cli`：使用 Swift Argument Parser 的薄入口，负责工作区定位、参数校验、确认、人类可读/JSON 输出和稳定退出码。
- `ModuCore`：App 与 CLI 共享的业务层。

### 2.2 Core 责任域

`ModuCore` 按能力而非界面拆分责任：

- 工作区采用、配置解析/监听、路径验证与受管 CLI/skills 维护。
- 主仓库 clone、origin、Fetch、Pull、状态与 Trash cleanup。
- Group 与 linked worktree 创建、发现、幂等恢复、删除和配置记录。
- 无副作用的 reconciliation 规划，将差异互斥分类为 additive、cleanup 或 conflict。
- Git 分支、merge-base、Changes 与 Commits 数据加载。
- 外部工具检测、全局首选与经验证路径的启动。
- 操作 journal、跨进程锁、原子写入、文件监听、进程与 Trash 等平台副作用边界。

具体类型名可以随实现重构，但上述责任与后续章节的系统契约不变。YAML 使用 Yams；Git 统一调用系统 `git`，复用用户已有的 SSH、credential helper、hooks 和 Git 配置。

### 2.3 运行边界

- 最低系统版本为 macOS 26。
- 关闭 App Sandbox，以访问用户选择的工作区并启动外部工具。
- 当前阶段只要求本地构建和运行；签名、公证与升级渠道属于后续分发阶段。

## 3. 数据契约

### 3.1 工作区结构

```text
<workspace>/
├── .modu.yaml
├── .modu-worktrees.yaml
├── repositories/
├── worktrees/
└── .agents/skills/<modu-skill> -> Application Support/Modu/...
```

Modu 不对工作区根执行 Git 初始化、提交或 `.gitignore` 修改。

### 3.2 `.modu.yaml`

`.modu.yaml` 是主仓库声明的唯一事实源。

```yaml
version: 1

repositories:
  - url: git@github.com:team/frontend.git
    name: Web Console
    branch: main
  - url: git@github.com:team/order-service.git
```

字段与身份规则：

- `url` 必填。接受 SCP 风格 SSH、`ssh://`、`https://`、`http://`、`file://` 和本地绝对路径；拒绝内嵌密码或 token 的 URL。
- 去掉查询、fragment、末尾 `/` 和一个 `.git` 后缀，再取最后路径段作为仓库名。
- 仓库名匹配 `[A-Za-z0-9][A-Za-z0-9._-]*`，且不能是 `.` 或 `..`。
- 仓库身份按 Unicode 规范化并忽略大小写比较，在工作区内唯一。不同远端的同名仓库不受支持，不能用展示名或目录别名绕过。
- `name` 可选，只影响展示；目录、YAML 关联和文件操作始终使用仓库名。
- `branch` 可选；省略时从 `origin/HEAD` 解析默认分支。
- 显式或解析出的默认分支必须可作为字面量拼入 `refs/heads/<branch>` 并通过 `git check-ref-format`，且不能以前导 `-` 或 checkout shorthand 被 Git 重新解释。
- 显式 branch 非法时整份配置无效；格式合法但分支不存在，或 `origin/HEAD` 无法解析时标记仓库异常。不得猜测 `main` 或 `master`。
- GUI 只新增和删除声明，不编辑 URL 或默认分支；有效的手工修改重新解析后生效。

### 3.3 `.modu-worktrees.yaml`

```yaml
version: 1

groups:
  feature-report:
    document: docs/modu/2026-08-26-report.md
    created-at: 2026-08-26 10:30:00
    repositories:
      frontend:
        branch: feature-report
        main-worktree: repositories/frontend
        linked-worktree: worktrees/feature-report/frontend
```

字段与身份规则：

- group 默认同时作为 linked worktree 目录名和分支名。
- group 必须是合法单段目录名；拼入 `refs/heads/<group>` 后通过 `git check-ref-format`，且不能以 `-` 开头。
- group 身份按 Unicode 规范化及工作区文件系统的大小写规则比较，在配置内唯一；同一身份用于 YAML、目录、幂等判断和 group 锁。
- GUI 原样保存 Group Name，不自动 slug 化。合法示例包括 `feature-store-pickup`、`fix-overselling`。
- 单仓库可覆盖 `branch`；记录分支遵循相同安全 ref 规则，但不要求是单段目录名。
- 任一 group、记录分支非法或 group 身份碰撞时，整份配置无效。
- `document` 可选，保存工作区相对路径；规范化后必须仍位于工作区且不能经符号链接逃逸。Modu 只定位，不修改其内容。
- `created-at` 使用本地时间 `YYYY-MM-DD HH:MM:SS`，无时区；已有 group 的值不重写。
- `repositories` 使用仓库内部身份为键，工作区路径均保存为相对路径。
- dirty、ahead/behind、提交和同步状态实时派生，不写入配置。

### 3.4 应用私有数据

以下数据保存在 UserDefaults 或 Application Support，不写入工作区：

- 当前工作区 URL bookmark。
- Agent、Git GUI、编辑器和终端四类外部工具的全局首选。
- 每个主仓库最后一次成功 Fetch 时间。
- 窗口尺寸、侧栏宽度和展开状态。
- 临时进度、operation journal 和 Git 历史缓存。

### 3.5 配置读写与错误域

- 不支持的高版本、未知字段、语法或 schema 错误均视为配置错误，避免写回时静默丢失。
- 初始化完成后任一配置文件缺失都视为错误，不能解释为空配置或自动重建。
- 用户在 Modu 外部编辑、移动、重命名或删除配置、受管目录、Git worktree 注册或其他工作区文件时，由用户承担这些外部变更产生的数据与恢复后果。Modu 只继续处理能通过配置身份、规范化路径、Git 身份和 operation journal 明确识别并精确匹配的状态；无法识别或匹配时转为配置错误或 conflict，不猜测、不自动采用、不补建、不改名，也不执行清理。
- `.modu.yaml` 缺失、不可读或存在版本、语法、schema 错误时，视为关键工作区状态无法加载，冻结仓库对账、Add、Fetch 和 Pull；最后有效状态只留在内存，恢复前不渲染仓库或 worktree 导航。App 等待用户修复文件后重新加载，或重新选择工作区，不自动修复或重建该文件。
- `.modu-worktrees.yaml` 错误冻结 worktree 创建、删除、修复和依赖关联 worktree 的 repository cleanup；主仓库 Add、Fetch、Pull 与 additive 对账仍可用，最后有效 worktree 状态标记为 Stale。
- `.modu.yaml` 的 GUI Add/Remove 必须保留未改动条目的顺序和注释，并在提交前重新解析候选内容；无法证明 source-preserving 修改安全时拒绝写入并提供 Open Config。
- `.modu-worktrees.yaml` 可规范化输出，其手工注释不属于稳定数据。
- 写入使用工作区 advisory lock、同目录临时文件、候选校验和原子替换。App 与 CLI 在锁内重读并合并最新状态；监听父目录并防抖以识别原子替换。

## 4. 工作区生命周期

### 4.1 首次设置

首次设置必须依次完成：

1. 安装 `modu-cli`。
2. 选择当前工作区。

CLI 与内置 skills 同步到 `Application Support/Modu` 的稳定受管路径。CLI 安装只在登录 shell PATH 中选择当前用户拥有、非 group/world-writable 且可写的目录创建符号链接；已有目标只有在指向 Modu 受管 CLI 时才可更新。没有合适目录时使用 `~/.local/bin` 并给出一次性 PATH 说明，不修改 shell 配置。

安装失败可重试；安装成功后才允许选择工作区，工作区检查通过后才进入主窗口。不得跳过或带未完成状态继续。

首次设置完成前退出应用时，不进入主窗口，也不回滚已经成功的 CLI 安装；下次启动重新检查该安装并从已安装状态继续。用户选择的目录在点击 Continue 前仅为候选工作区；只有点击 Continue 且无副作用检查通过后，才允许初始化目录并提交为当前工作区。

### 4.2 采用与切换工作区

工作区可以是任意可写目录。初始化只创建缺失的标准结构，不覆盖既有文件，不修改工作区 Git。

首次采用必须先做无副作用检查：

- 目录为空或没有任何 Modu 配置与受管目录：允许初始化。
- 两份配置都存在且有效：按现有工作区载入。
- 只存在一份配置、任一配置无效，或配置缺失但受管目录/skill 目标已有内容：停止初始化，引导 Doctor 或选择其他目录；不得补建空配置后触发清理。

候选 `.modu.yaml` 无法解析时保持在设置流程，不进入主窗口或产生初始化副作用。切换工作区前取消可取消任务，并等待正在提交的原子文件替换或目录迁移完成。

### 4.3 受管资源

应用升级只更新 Application Support 中的受管 CLI/skills，工作区符号链接自动获得新版本。损坏链接仅在原路径为空或仍属于 Modu 时自动修复；其他同名文件或链接标记 conflict，不覆盖。

## 5. 主仓库生命周期

### 5.1 声明式对账

载入有效 `.modu.yaml` 后先生成完整计划，再执行：

1. 解析并校验 URL、仓库身份与默认分支。
2. 扫描 `repositories/` 直接子目录和 Git worktree 注册；只有与 operation journal 匹配的 staging 才按内部临时目录排除。
3. 将差异互斥地分类为 `additive`、`cleanup` 或 `conflict`；规划阶段不得产生副作用。
4. `additive` 包括缺失仓库 clone，以及仓库身份不变时的 origin 更新；校验后可自动执行。
5. `cleanup` 包括已移除声明及配置外可验证的 Git 主仓库；授权按第 1.6 节，必须先展示并确认当前风险计划。
6. 非 Git 目录、路径异常、origin 身份冲突或无法证明归属的 staging 为 `conflict`，不得覆盖或移动。
7. URL 变化导致仓库名变化时，拆为新仓库 additive 与旧仓库 cleanup；新 clone 不授权旧目录删除。

单仓库失败不阻断其他 additive 项。配置仍声明但 clone 失败的仓库只标记异常，不清理其 linked worktree。

### 5.2 Clone 与崩溃恢复

- clone 使用完整历史，不 shallow clone。
- 创建 staging 前先原子写入不含凭据的 operation journal；clone 到 `repositories/` 下本次操作独占的隐藏 staging，校验 Git 身份、origin 和默认分支后再同卷原子改名。
- 失败、取消或最终目录竞争时，只有 journal 和规范化路径共同证明 staging 属于当前操作，才把 staging 移入 Trash；最终路径不被污染。
- 崩溃后，匹配 journal 的遗留 staging 只报告待审查，不自动删除；两路径并存、身份不符、journal 缺失或符号链接异常均为 conflict。
- staging 不存在且最终目录已是有效声明仓库时，可清除已完成 journal；两者都不存在时可清除已中断 journal 并重试。
- 自动恢复只能清除 Application Support 中可证明已完成或中断的 journal 元数据，不能借机移动工作区数据。

### 5.3 Add Repository

GUI 只收集 Repository URL 与可选 Display Name。仓库身份、目标目录和默认分支按第 3.2 节派生；派生失败归因于 URL。提交后先原子加入声明，再按对账规则 clone。取消或失败保留有效声明和可重试状态，不留下半成品最终目录。

### 5.4 Delete Repository 与 cleanup

Delete Repository 和手工移除声明产生的 cleanup 共用第 1.6 节授权模型与同一风险计划，计划至少包含：

- 主仓库身份与受管路径。
- 关联 linked worktree 与本地分支。
- 主工作树及关联 worktree 的 dirty、ignored content、detached HEAD 和可检测的仅本地提交风险。
- 配置更新、强制移除、本地分支删除和主仓库 Trash 移动等将执行的动作。
- 远端仓库与远端分支不会删除。

以上字段用于锁内当前计划的安全校验；GUI 确认界面保持克制，可显示受影响路径和简洁的 Working Tree 状态，但不要求逐项展示风险明细，破坏性确认按钮统一使用 `Delete`。风险读取、计划变化检测和执行顺序仍不可省略。

从 GUI Delete Repository 发起时，确认后先原子移除 `.modu.yaml` 声明；写入失败不得执行任何后续删除。手工移除声明形成的 cleanup 不修改配置文件。

确认只授权本次未变化计划。执行前在锁内重算；计划变化、应用重启或稍后重试都要重新确认。随后按第 7.3 节移除全部关联 linked worktree；全部成功后才将主仓库移入 macOS Trash。任一步失败都保留可重试状态，不静默隐藏残留数据。

## 6. Fetch 与 Pull

Repositories 级 Fetch/Pull 只操作 `repositories/` 下的主仓库，不遍历 `worktrees/`。

### 6.1 Fetch

- 窗口激活时，距离上次成功 Fetch 超过 10 分钟的主仓库自动执行 `git fetch --prune origin`；手动 Fetch 忽略阈值并覆盖全部主仓库。
- 配置省略 `branch` 时，refs Fetch 后必须重新查询远端 HEAD；只有安全分支与对应 remote-tracking ref 都存在，才更新 `origin/HEAD`。
- refs Fetch 与 `origin/HEAD` 刷新都成功才记录成功时间。默认分支变化时，使依赖 Base 的缓存失效。
- 自动成功保持静默；失败进入去重的非模态异常状态。同一仓库和原因在状态改变前不重复打扰。

### 6.2 Pull

手动全局 Pull 逐仓库预检：

- working tree 必须 clean。
- 当前分支必须等于已解析的默认分支。
- 通过后执行 `git pull --ff-only origin <branch>`。
- dirty、非默认分支或 detached HEAD 为 `skipped`；分叉、认证、路径或 Git 错误为 `failed`。
- 不自动 checkout、merge 或 rebase。

### 6.3 调度与结果

- 批量 Git 最大并发数为 6；桌面端同一时刻只运行一个 repositories 级批量任务。
- 同一仓库的所有 Git/生命周期写操作互斥，并复用第 8.2 节跨进程锁。
- 手动操作全部成功时提供短暂成功反馈，不逐仓库重复；存在 skipped/failed 时显示一次汇总，并明确 linked worktree 未被修改。可见顺序统一遵循 DESIGN，不由配置顺序或结果类型改变。
- Fetch/Pull 不提供界面内 Stop；工作区切换和退出仍按取消契约收束，且不把旧工作区结果呈现到新上下文。
- 后台进程不从 stdin 读取凭据；认证不可用时快速失败并输出整理后的原因。

可见加载、成功文案和结果窗口结构由 DESIGN 定义。

## 7. Worktree 生命周期

### 7.1 创建 Group

创建必须满足：

- 使用第 3.3 节统一规则校验 group、分支、路径、document 和身份；CLI 与 GUI 不得各自发明规则。
- GUI 原样保存 Group Name，不自动 slug；至少选择一个仓库。空选择只禁用提交，不显示额外错误。
- 默认目录为 `worktrees/<group>/<repo-name>`，默认分支为 `<group>`。
- 已有 group 不重写 `created-at`；请求省略 `document` 时保留原值，相同规范化路径幂等，不同路径在 Git 副作用前 conflict。
- 每个仓库先 Fetch 默认分支；失败时不得使用过期 Base 创建。
- 新分支从最新 `origin/<default>` 创建；仅远端存在时创建 tracking branch；本地已存在时可复用，但不得 reset、merge 或 rebase，且不能已被其他 worktree 检出或存在 tracking 冲突。
- 目标路径、Git 注册、主仓库、分支和 YAML 记录完全匹配时幂等成功；任一身份不匹配则 conflict。
- `git worktree add` 成功但 YAML 写入失败时不反向强删。重试仅在路径、注册、仓库、分支和 group 元数据全部精确匹配时补写记录，否则 conflict。
- 每个 Git 成功项立即在配置锁内重读并原子记录。多仓库最大并发数 6，已成功项保留，Retry 只补齐缺失或精确可恢复项。

### 7.2 编辑 Group

- Group Name 只读；仓库列表覆盖当前声明中的全部主仓库。
- Checkbox 表示保存后的目标成员关系；Working Tree 表示保存前当前本地 linked worktree 的状态，两者相互独立。
- 新勾选项复用创建流程；removal 在一次 `Save Changes` 操作中按第 1.6 节授权，不另设确认页。
- 至少保留一个仓库；取消全部勾选时禁用提交且不显示提示。
- Working Tree 状态语义为：`Clean` 表示 staged/unstaged/untracked 均无变化；`Dirty` 表示存在其中任一变化；`Other` 表示已有项无法可靠归入 Clean/Dirty；`Unset` 表示保存前该 Group 尚未创建对应 linked worktree，与 Checkbox 是否勾选无关，并在创建成功前保持不变。
- Dirty 与 Other 都允许取消勾选。Clean 不代表不存在 ignored content 或仅本地提交。
- 存在 removal 时，确认按钮保持 `Save Changes` 文案并使用 destructive 样式。
- 提交前在 group/仓库锁内重读身份与 Working Tree 状态。状态与编辑列表不同的 removal 不执行并刷新对应行，其他不受影响项继续。
- 成功移除 worktree 并删除本地分支后才移除 YAML 记录；失败项保留并可 Retry。

### 7.3 独立删除 Linked Worktree 或 Group

独立删除的授权按第 1.6 节，无论 dirty 与否都必须二次确认。当前计划逐项包含：

- 仓库、worktree 路径和记录本地分支。
- dirty 状态。
- ignored content：`None`、`Present` 或无法读取时的 `Unknown`；Present 可查看路径摘要。
- 当前 HEAD 与记录分支的可检测仅本地提交风险；无法读取为 `Unknown`。
- detached HEAD 身份与风险。
- 远端分支永不删除。

dirty 包含 staged、unstaged 和 untracked，不包含 ignored content。仅本地提交风险是基于当前本地 remote-tracking refs 的保守判断，不声称代表服务器实时状态。worktree 附着到与记录不同的分支属于 identity conflict。

用户确认后获取 group/仓库锁，并重算路径、注册、分支和全部风险；任一项变化都不执行破坏性命令，而是更新计划并要求再次确认。未变化时依次执行：

```text
git worktree remove --force <path>
git branch -D <branch>
```

只有目录移除成功，且记录分支删除成功或在确认计划中已验证不存在，才删除 YAML 记录。分支删除失败时保留记录与可重试状态；重试只有在路径不存在、Git 无注册且分支身份仍匹配时才能从分支步骤继续。任何身份不一致转为 conflict。

删除 Group 对全部成员执行相同流程；单项失败不回滚成功项，最后给出逐项结果。最后一个成员删除后才移除空 Group。

### 7.4 Doctor

`doctor` 默认只诊断配置、目录、Git worktree 注册、operation journal、CLI 和 skills 链接。`--repair` 只执行可证明安全且不丢失恢复线索的修复，例如重建确认属于 Modu 的符号链接，或清除已完成/已中断 journal；不删除分支、有内容目录或仍承载失败状态的 YAML 记录。破坏性处理只输出计划与下一步命令。

## 8. 跨域安全与运行契约

### 8.1 路径与文件安全

- 文件、Git 和 cleanup 副作用只处理规范化后位于 `repositories/` 或 `worktrees/` 的受管后代。
- 拒绝工作区根、受管根、路径逃逸和异常符号链接。
- 配置编辑、配置移除或计划生成本身不构成 cleanup 或强制删除授权。
- 主仓库与声明式 cleanup 使用 macOS Trash，不执行递归永久删除。
- `git worktree remove --force` 只允许出现在第 7.2、7.3 节和经确认的 repository cleanup。

### 8.2 并发、锁与原子性

- 同一 Group 的 create/remove 使用跨 App/CLI group 操作锁。
- 同一仓库的 clone/staging 提交、origin 更新、Fetch、Pull、worktree add/remove、记录分支删除和 repository cleanup/Trash 移动使用同一跨进程仓库生命周期锁；目标目录不存在时也必须生效。
- 多锁按规范化标识排序获取；配置写入另使用工作区锁。
- 每次副作用前在锁内重读身份与计划，禁止用过期 UI 或 CLI 预览直接执行。

### 8.3 结果、取消与过期状态

- 批量操作逐项返回 `success`、`skipped`、`failed` 或 `cancelled`，附稳定原因；已完成项保留，未完成项不记成功。
- 用户发起的操作或当前可见状态读取失败时，只呈现能够可靠识别的结果信息与安全的下一步操作；无法可靠识别或匹配的状态保持 blocked/conflict，等待用户处理工作区文件或切换工作区，不以推测结果继续。
- 配置、批量 Git 和 worktree 生命周期错误分域维护，不无条件冻结其他安全能力。
- 用户取消先向子进程发送正常终止信号；不回滚已成功项。
- 退出时等待正在提交的原子文件替换或目录迁移完成。
- 工作区或选择变化后，丢弃携带旧 generation 的异步结果。
- 可重试错误提供 Retry；不可由应用修复的 conflict 提供 Reveal、Open Config 或经整理的详情。

### 8.4 日志与敏感信息

使用 `os.Logger` 按 Workspace、Git、CLI、Launcher 分类。日志、JSON 和 UI 不记录带凭据 URL、敏感环境变量或未经整理的完整 Git 输出。

## 9. 外部工具

内置类别与首版目标：

1. Agent：Codex、Claude Code。
2. Git GUI：Fork。
3. 编辑器：VS Code、Cursor。
4. 终端：Warp、Terminal。

业务契约：

- 只显示检测成功且适用于当前路径类型的内置目标；类别无可用目标时隐藏。
- 未选择节点时只允许 Agent 打开规范化后等于当前工作区根的路径。选择主仓库或 linked worktree 后，四类工具只接受当前工作区受管后代。
- 每类只保存一个全局默认目标，不按工作区、仓库或 worktree 拆分。
- 选择目标后立即尝试打开当前路径；只有启动成功才更新该类默认值。失败保留原默认。
- v0.1 不允许自定义 App 或命令模板。

启动契约：

- Codex：优先使用支持 `app` 子命令的 CLI 执行 `codex app <path>`；否则检测 Bundle ID `com.openai.codex` 并通过 `NSWorkspace` 打开。不得依赖可变的应用文件名或展示名。
- Claude Code：同时要求 `claude` CLI 与可用终端，并在目标目录启动。
- Fork、VS Code、Cursor：使用 Bundle ID 或官方 CLI 的目录打开能力。
- Warp、Terminal：在目标目录创建窗口或标签页。

所有启动使用结构化参数数组。启动前重新验证路径存在、边界和符号链接；工作区根例外只用于未选择状态的 Agent，不放宽其他文件或 Git 边界。Automation 权限拒绝或启动失败使用非模态错误反馈。

## 10. Git Browser 数据语义

- 主工作树与 linked worktree 复用同一详情模型。
- Path 为工作区相对路径：`repositories/<repo-name>` 或 `worktrees/<group>/<repo-name>`。
- Base branch 显示已解析默认分支对应的 remote-tracking ref（例如 `origin/main`）；Head branch 来自当前工作树。detached HEAD 表达为 `Detached at <short-sha>`。
- 摘要只提供当前工作树路径、Base branch 和 Head branch，不显示独立的 Status 计数。
- Changes 展示当前工作树（包含 HEAD 与未提交内容）相对 Base 的差异文件，同一路径只计一次；ignored 不计入。没有差异文件时隐藏 Changes，读取失败不能伪装为无差异。
- Changes 文件状态仍使用统一映射：`A`、`C`、untracked → Added；`R` → Moved；`M`、`T` → Modified；`D` → Deleted。冲突或未知状态为 Unknown，不引入未定义的第五类状态。
- Commits 展示 `Base..HEAD` 的差异提交；主工作树与 linked worktree 均使用该范围。没有差异提交时隐藏 Commits。
- 无可展示差异提交与读取失败是不同状态。Base 缺失、merge/rebase 未完成或 Git 错误应可恢复，且不冻结仍可用的外部工具入口或其他独立状态。
- 首批最多读取 100 条提交，按需加载更多；切换选择取消过期请求，缓存以 HEAD/base OID 失效。
- v0.1 不展示提交文件树或逐行 diff。

布局、颜色、行高、截断和无障碍表达由 DESIGN 定义。

## 11. CLI 契约

### 11.1 命令面

```text
modu-cli repo list [--json]
modu-cli repo reconcile [--apply] [--yes] [--json]
modu-cli worktree list [--json]
modu-cli worktree create <group> --repo <repo-name>... [--branch <repo>=<branch>] [--document <path>] [--json]
modu-cli worktree remove <group> [--repo <repo-name>] [--yes] [--json]
modu-cli doctor [--repair] [--json]
```

CLI 从当前目录向上查找 `.modu.yaml`，并支持全局 `--workspace <path>`。

### 11.2 Apply 与确认

- `repo reconcile` 默认只输出计划；`--apply` 执行 additive。
- 计划含 cleanup 时必须同时传 `--yes` 才执行；单独 `--yes` 无效。
- v0.1 不提供 plan-id。`--yes` 接受命令执行时在锁内生成并完成安全校验的当前计划，不绑定旧预览，也不跳过风险读取、身份或路径检查。
- `--json` 隐含非交互模式，永不读取 stdin；缺少确认时返回 `confirmation-required`。

### 11.3 JSON 与退出码

- stdout 只输出一个含 `schema-version`、`command`、总体 `status` 和逐项 `items` 的 JSON；item 包含稳定 `kind`、`status`、`reason-code` 和已整理 `message`。
- 进度与诊断写 stderr，不输出 ANSI，不混入 Git 原始输出。
- 退出码：`0` 表示全部请求动作完成或只读计划成功；`1` 表示存在 skipped、conflict、failed、confirmation-required；`2` 表示参数、工作区或配置预检失败；`130` 表示取消。
- 部分成功通常返回 `1`；用户中断导致的部分成功返回 `130`，逐项结果保留真实状态。

## 12. 内置 skill

`$create-worktree`：

- 根据需求和 `.modu.yaml` 选择仓库。
- 生成 group、分支与方案文档路径。
- 使用 `--json` 调用 `modu-cli worktree create` 并按 `schema-version` 解析。
- 解释全部成功、部分成功与失败。

skill 不直接拼接 `git worktree` shell 流程，不在提示词中复制易变实现细节。

## 13. 测试策略

当前阶段只验证本地开发构建。测试使用临时目录和本地 bare remote，不访问真实网络或用户仓库。

### 13.1 ModuCore 单元测试

- URL/仓库身份解析、凭据拒绝、大小写与 Unicode 碰撞、不同远端同名拒绝。
- YAML schema、版本、未知字段、时间、group 与分支字面量校验。
- `.modu.yaml` source-preserving 修改与拒绝路径。
- 首次采用、配置缺失、分域错误、路径安全、无副作用计划。
- 工具适用性、全局偏好与结果汇总。

### 13.2 Git 集成测试

- clone、Fetch、默认分支变化、`origin/HEAD` 刷新、fast-forward Pull。
- staging 失败/取消/目标竞争/崩溃恢复矩阵，确保最终路径不污染且数据不被静默删除。
- dirty、非默认分支、detached HEAD、分叉与 skipped/failed 分类。
- worktree 幂等创建、部分失败、精确补写恢复与 identity conflict。
- 分支复用、过期 Fetch、group 碰撞和 document 幂等。
- dirty、ignored content、仅本地提交、force remove、分支删除失败续跑。
- repository cleanup 的关联项顺序与 Trash 边界。
- App/CLI 的 group、仓库、配置锁与交叉并发。
- CLI JSON 隔离、退出码和 `--yes` 当前计划语义。

### 13.3 App 与 UI 测试

- 自动 Fetch 阈值、并发限制、手动结果与错误去重。
- 工作区切换/退出取消、过期结果丢弃和配置错误分域冻结。
- 未选择/已选择工具上下文、成功后保存默认值。
- 侧栏、仓库选择、风险/结果列表与 Changes 的统一自然排序、层级保留，以及选择、焦点、状态对实体身份的绑定。
- 首次初始化冲突、Add、Group 创建/编辑/删除、repository cleanup。
- 核心键盘路径（不含仅右键菜单操作）、VoiceOver、焦点恢复和状态不只依赖颜色。

### 13.4 本地冒烟

覆盖 `xcodebuild`、App 启动、CLI、符号链接可执行性和临时工作区端到端流程。

## 14. 实施里程碑

1. 建立 ModuCore、配置模型、原子存储、进程执行与测试基础。
2. 完成首次设置、CLI/skills 与主仓库对账。
3. 完成 Fetch/Pull 调度、结果与异常状态。
4. 完成 worktree CLI、Group 管理、删除确认与 Doctor。
5. 完成外部工具、Git Browser 和 macOS 原生视觉打磨。
6. 完成本地端到端冒烟和源码试用。

## 15. 功能验收

v0.1 满足以下条件即完成：

- 任意安全可采用的可写目录都能完成首次设置；部分初始化或无效配置不会产生副作用。
- 有效 `.modu.yaml` 能驱动 clone/origin additive，并为多余主仓库和关联 worktree 生成确认前无副作用的 cleanup。
- 配置缺失、无效、身份冲突或风险未知不会触发错误清理。
- 自动/手动 Fetch 与安全 Pull 符合范围、默认分支、并发和结果契约。
- GUI、CLI 和内置 skill 能幂等创建跨仓库 Group，并从部分失败恢复。
- Group 编辑可新增成员、移除任意非最后成员；removal 的授权、destructive Save Changes 与锁内重读符合第 7.2 节。
- linked worktree、Group 和 repository cleanup 的风险确认、执行顺序和部分失败续跑不会误报成功或删除远端分支。
- 未选择与已选择状态只启动适用于经验证目标路径的外部工具，且仅在成功后更新全局默认。
- Git Browser 正确展示 Path、Base branch、Head branch，以及相对 Base 的 Changes/Commits 空态和读取失败；主/linked worktree 使用统一差异范围。
- 核心流程（不含仅右键菜单操作）支持键盘与 VoiceOver，并适配系统外观。
- Core、Git 集成、关键 App 状态与本地端到端冒烟通过。

## 16. 参考资料

- [OpenAI：Codex CLI reference](https://developers.openai.com/codex/cli/reference/)
- [OpenAI：ChatGPT desktop app troubleshooting](https://learn.chatgpt.com/docs/reference/troubleshooting#feature-is-working-in-the-codex-cli-but-not-in-the-chatgpt-desktop-app)
- [Anthropic：Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference)
