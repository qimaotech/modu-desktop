# Modu Desktop PRD

- 日期：2026-08-28
- 状态：Git Browser Detail 路径属性与 Fetch/Pull 标题栏反馈已完成复审
- 目标版本：v0.1 本地开发版

## 0. 文档说明

本文同时定义 v0.1 的产品需求和技术落地方案，是业务规则、实现拆分和功能验收的事实源。客户端交互规则见 [`DESIGN.md`](DESIGN.md)，原型图片保存在仓库根目录的 [`design/prototypes/`](../design/prototypes/)；原型只表达代表性状态，不能覆盖或改写本文的产品与安全规则。三者不一致时必须先修正文档和原型，再进入实现。

Figma 原生设计保存在 [Modu Desktop](https://www.figma.com/design/eK0CqTm1y4jk6thzqBdUV5/Modu-Desktop)。Figma 原型主体使用 Inter，Git Browser Detail 文件树沿用设计文件中的 SF Pro typography token；这些原型字体差异不改变 SwiftUI 客户端必须使用 PingFang HK 的实现约束。当前设计范围仅包含浅色主题。

## 1. 背景与定位

团队的一个需求经常横跨多个前后端仓库。现有做法是在一个工作区仓库中维护所有子仓库，再用 Codex 打开工作区并完成跨仓库开发。随着仓库、需求和 linked worktree 增多，开发者需要频繁在 Finder、终端、Git 工具、编辑器和 Codex 项目之间定位目录，同时还要自行维护跨仓库 worktree 状态。

Modu 不尝试替代 Codex、Claude Code 或 Git GUI。它是位于这些工具之上的本地工程工作流层，负责：

- 组织一个工作区中的多个主仓库和跨仓库需求组。
- 为 Agent 提供稳定的 `modu-cli` 和内置 skill。
- 选中主仓库或 linked worktree 后，快速把当前受管目录交给适用的外部 Agent、Git GUI、编辑器和终端。
- 以统一的 Git Browser 详情查看主工作树或 linked worktree 的当前工作树变更；主工作树展示当前分支历史，linked worktree 展示相对默认分支的独有提交。

## 2. v0.1 目标与非目标

### 2.1 目标

v0.1 完成以下闭环：

1. 用户安装并启动 Modu，安装 `modu-cli`，选择一个当前工作区。
2. Modu 初始化工作区结构和内置 skills 符号链接。
3. 用户通过界面或 `.modu.yaml` 管理主仓库，Modu 自动完成声明式对账。
4. 用户用 Codex 分析需求并输出技术方案。
5. Codex 通过 `$create-worktree` 调用 `modu-cli`，为多个仓库创建同一需求组的 linked worktree。
6. Modu 实时展示需求组，允许开发者打开、检查和删除相关 worktree。
7. 用户选择主工作树或 linked worktree 后，可查看当前工作树变更文件；主工作树查看当前分支历史，linked worktree 查看相对默认分支的独有提交。

目标规模为 5–20 个主仓库、约 5 个活跃需求组、最多约 30 个 linked worktree。Git 历史按选择懒加载。

### 2.2 非目标

v0.1 不包含：

- 内置 AI 对话、Agent 编排或提示词生成系统。
- 桌面端创建 worktree 的表单。
- staging、commit、merge、rebase 或逐行 diff 等完整 Git GUI 能力。
- 多工作区、自定义外部工具或团队云同步。
- 对 linked worktree 执行 repositories 级全局 Fetch/Pull。
- 自动初始化或维护工作区自身的 Git 仓库、`.gitignore` 和提交策略。
- Developer ID 签名、公证、自动升级和正式分发验证。
- 量化性能验收指标。

## 3. 产品原则

- **文件是事实源**：工作区配置保存在用户目录内，Modu 只负责读取和编辑，不决定这些文件是否由 Git 管理。
- **共享能力不重复实现**：App 和 CLI 使用同一套配置、Git 和 worktree 逻辑。
- **声明式仓库管理**：有效 `.modu.yaml` 描述期望存在的主仓库集合；补齐操作自动执行，移除和强制删除必须先形成可审查计划并获得明确确认。
- **Agent 友好**：CLI 操作幂等、可重试，并提供稳定退出码和 JSON 输出。
- **原生且克制**：采用 macOS 原生窗口、菜单、列表和状态反馈，不做卡片式仪表盘。
- **破坏性操作明确**：worktree 强制删除始终二次确认；仓库配置对账清理先确认风险，再使用 macOS Trash，不能把编辑配置文件本身视为删除授权。

## 4. 总体架构

采用共享 Swift 核心库：

```text
ModuDesktop ─┐
             ├─ ModuCore ── YAML / 文件系统 / Git / 外部应用
modu-cli ────┘
```

### 4.1 ModuDesktop

SwiftUI macOS 应用，只负责：

- 首次启动与工作区选择。
- 主窗口、侧边栏、菜单、弹窗、toast 和 loading 状态。
- 用户全局偏好、窗口状态和通知。
- 把用户动作转换为 ModuCore 调用。

`AppModel` 在主线程维护展示状态。Git、文件系统和进程操作通过异步任务执行，不放入 SwiftUI View。

### 4.2 modu-cli

面向开发者和 Agent 的薄入口，使用 `swift-argument-parser` 处理参数，只负责：

- 工作区定位。
- 参数校验和交互确认。
- 人类可读输出、`--json` 输出和稳定退出码。
- 调用 ModuCore，不重复实现 Git 和配置逻辑。

### 4.3 ModuCore

ModuCore 由以下职责单一的服务组成：

- `WorkspaceService`：初始化、校验、路径解析、CLI 与 skills 链接维护。
- `WorkspaceStore`：YAML 解析、监听、加锁和原子写入。
- `RepositoryService`：clone、origin 更新、fetch、pull、状态检查和 Trash 清理。
- `WorktreeService`：创建、发现、幂等重试、强制删除和配置修复。
- `ReconciliationPlanner`：把配置差异拆分为可自动执行项、待确认清理项和冲突，不在规划阶段产生副作用。
- `GitHistoryService`：当前分支历史、merge-base 和独有提交读取。
- `ToolRegistry`：内置工具检测、全局首选和目录打开。
- `OperationJournal`：在副作用前持久化不含凭据的任务标识、规范化工作区与 staging 路径，用于崩溃后证明临时目录归属。
- `ProcessRunner`、`TrashService`、`FileWatcher`：封装系统副作用，支持测试替身。

YAML 使用 `Yams`。Git 统一调用系统 Git，不引入 libgit2，以复用用户已有的 SSH、credential helper、hooks 和 Git 配置。

### 4.4 运行与分发边界

- 最低系统版本为 macOS 26。
- 关闭 App Sandbox，以访问用户选择的任意工作区并启动外部工具。
- 当前阶段只做本地构建和运行，不要求开发者账号、Developer ID 签名或公证。
- Developer ID 签名、公证和升级渠道属于后续分发阶段。

## 5. 数据模型

### 5.1 `.modu.yaml`

`.modu.yaml` 是主仓库声明的唯一事实源。

```yaml
version: 1

repositories:
  - url: git@github.com:team/frontend.git
    name: Web Console
    branch: main
  - url: git@github.com:team/order-service.git
```

字段规则：

- `url` 必填。
- v0.1 接受 SCP 风格 SSH、`ssh://`、`https://`、`http://`、`file://` 和本地绝对路径；所有入口都拒绝内嵌密码或 token 的 URL，凭据交给 SSH agent 或 Git credential helper。
- 解析时先去掉查询、fragment 和末尾 `/`，再从最后一个路径段去掉一个 `.git` 后缀得到仓库名，例如 `order-service`。
- 仓库名必须匹配 `[A-Za-z0-9][A-Za-z0-9._-]*`，且不能是 `.` 或 `..`。仓库身份按 Unicode 标准化并忽略大小写比较，避免在默认不区分大小写的 APFS 上产生目录碰撞。
- 仓库名是内部身份，在工作区内必须唯一。v0.1 明确不支持不同 host、组织或路径下的同名仓库；这类配置直接报身份冲突，用户必须在远端侧调整其中一个仓库名后再添加。`name` 只影响展示，不能作为稳定 `id`、目录别名、YAML 键或 CLI `repo-name` 绕过冲突。
- `name` 可选，只影响左侧展示；省略时显示仓库名。
- `branch` 可选；省略时从 `origin/HEAD` 解析默认分支。
- 显式 `branch` 及从 `origin/HEAD` 解析出的名称都必须作为字面量拼接到 `refs/heads/<branch>` 后通过 `git check-ref-format`，且不能以 `-` 开头；禁止把 checkout shorthand 或其他可被 Git 重新解释的值带入 Fetch、Pull、diff 或 worktree 命令参数。
- 显式 `branch` 不满足上述格式时整份 `.modu.yaml` 视为配置错误；格式合法但分支不存在，或 `origin/HEAD` 无法解析为安全分支名时标记仓库异常。不猜测 `main` 或 `master`，也不允许基于未知 Base 创建 worktree。
- 图形界面不提供 URL 和默认分支的修改入口。用户手工修改有效 YAML 后，以最新配置为准重新解析。
- 仓库目录和所有文件操作始终使用仓库名，不使用展示名。

### 5.2 `.modu-worktrees.yaml`

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
      order-service:
        branch: feature-report
        main-worktree: repositories/order-service
        linked-worktree: worktrees/feature-report/order-service
```

字段规则：

- group 标识默认同时作为 linked worktree 分支名和需求目录名。
- 无论由 CLI 生成还是手工写入，group 标识都必须是合法单段目录名；作为字面量拼接到 `refs/heads/<group>` 后必须通过 `git check-ref-format`，且不能以 `-` 开头。
- group 身份按 Unicode 规范化及工作区所在文件系统的大小写规则比较，在 `groups` 内必须唯一；同一规范化身份必须用于 YAML 身份、目录映射、幂等判断和 group 锁键，不能让等价名称映射到不同操作对象。
- GUI 新建 group 时原样保存用户输入的 Group Name，不自动 slug 化。GUI 新建和编辑都必须至少选择一个仓库；空选择只禁用提交，不显示额外错误提示。CLI 删除完整 group 后仍按生命周期规则移除空 group 记录。
- 单仓库可覆盖 `branch`；记录分支同样必须能作为字面量 `refs/heads/<branch>` 通过 `git check-ref-format`，且不能以 `-` 开头，但不受 group 的单段目录名限制。
- 任一 group、记录分支非法或 group 身份碰撞时，整份 `.modu-worktrees.yaml` 视为配置错误并按 5.4 冻结相关操作，不能只在 CLI 创建入口校验。
- `document` 可选，保存工作区相对技术方案路径。
- `document` 标准化后必须仍位于工作区内，且不能通过符号链接逃逸；Modu 只打开或定位该文件，不写入其内容。
- `created-at` 使用本地时间格式 `YYYY-MM-DD HH:MM:SS`，不附带时区。
- `repositories` 使用 URL 解析出的仓库名作为键。
- 工作区内路径统一保存为相对路径。
- dirty、ahead/behind、提交和同步状态均实时派生，不写入 YAML。

### 5.3 应用私有数据

以下数据保存在 UserDefaults 或 Application Support，不写入工作区：

- 当前工作区 URL bookmark。
- 一份外部工具全局偏好配置，其中分别保存 Agent、Git GUI、编辑器和终端四类默认目标；不按工作区、仓库或 worktree 拆分。
- 每个主仓库最后一次成功 Fetch 时间。
- 窗口尺寸、边栏宽度和展开状态。
- 临时任务进度、崩溃恢复 operation journal 与 Git 历史缓存。

### 5.4 配置一致性

- `version` 用于未来迁移；不支持的高版本只读并提示升级。
- `.modu.yaml` 语法、schema 或版本错误时只在内存中保留最后一次有效状态，错误解除前不渲染仓库或 worktree 侧栏；标题栏保持显示，阻断恢复页占满标题栏下方的窗口主体。此时暂停 Add、Fetch、Pull 和仓库对账，不执行 clone、remote 修改或清理。
- `.modu-worktrees.yaml` 错误时冻结 worktree 创建、删除、记录修复，以及任何需要删除关联 worktree 的仓库 cleanup；主仓库 Add、Fetch、Pull 和不涉及删除的 additive 对账仍可使用。界面保留最后一次有效 worktree 状态并明确标记为陈旧。
- 初始化完成后任一配置文件缺失都视为错误，不能当作空配置重新创建；尤其不得因此把现有仓库或 worktree 视为多余项。
- 未知字段视为配置错误，避免图形化写回时静默丢失。
- `.modu.yaml` 的 GUI Add/Remove 必须保留未改动条目的顺序和手工注释，并用 Yams 重新解析候选内容后才提交；无法生成可证明安全的 source-preserving 修改时拒绝写入并提供 Open Config，不能静默整文件序列化。应用管理的 `.modu-worktrees.yaml` 可规范化输出，手工注释不属于稳定数据。
- 写入使用工作区级 advisory lock，并采用“同目录临时文件、校验、原子替换”。
- 文件监听器监听父目录并防抖，以正确处理原子替换。
- App 和 CLI 写入前都在锁内重新读取并合并最新状态。

## 6. 首次启动与受管资源

首次启动包含两个必须依次完成的步骤：

1. 安装 `modu-cli`。
2. 选择当前工作区。

应用将本地构建出的 CLI 和内置 skills 同步到 `Application Support/Modu` 下的稳定受管路径。CLI 安装只在用户登录 shell PATH 中选择当前用户拥有、非 group/world-writable 且可写的目录创建符号链接；已有目标只有在它是指向 Modu 受管 CLI 的符号链接时才可更新，不覆盖其他文件或可执行程序。没有合适目录时使用 `~/.local/bin`，并显示一次性 PATH 配置说明，不静默修改 shell 配置。安装失败时停留在当前步骤，提供 Retry 和错误详情；安装成功后才允许选择工作区，工作区检查通过后才进入主窗口。首次设置不提供跳过、稍后处理或带未完成状态继续使用的入口。

工作区选择接受任意可写目录。用户切换工作区前，应用先取消可取消任务，并等待正在进行的原子写入或目录迁移完成。初始化时只创建缺失的：

- `.modu.yaml`
- `.modu-worktrees.yaml`
- `repositories/`
- `worktrees/`
- `.agents/skills/<modu-skill>` 符号链接

Modu 不执行 `git init`，不修改 `.gitignore`。应用升级后更新 Application Support 中的受管资源，工作区符号链接自动指向新内容；链接损坏时仅在原路径为空或仍是 Modu 受管链接时自动修复，其他同名文件标记冲突，不覆盖。

首次采用已有目录时先执行无副作用检查：

- 目录为空或没有任何 Modu 配置和受管目录时，可按上述规则初始化。
- `.modu.yaml` 与 `.modu-worktrees.yaml` 都存在且有效时，按现有工作区载入，不覆盖文件。
- 只存在一个配置文件、任一配置无效，或配置缺失但 `repositories/`、`worktrees/` 或 skill 目标已有内容时，视为部分初始化或既有工作区异常，停止初始化并引导用户运行 Doctor 或选择其他目录；绝不补建空配置再触发清理。

## 7. 主仓库声明式对账

每次载入有效 `.modu.yaml` 后先生成完整对账计划，再分阶段执行：

1. 解析 URL、仓库名和默认分支。仓库名重复时整份配置无效。
2. 扫描 `repositories/` 的直接子目录，并读取 Git worktree 注册关系。只有同时匹配 Application Support 中 operation journal 的 staging 才作为内部临时目录排除；仅名称相似但无法证明归属的目录仍按普通目录进入 conflict。
3. 把差异分类为 `additive`、`cleanup` 或 `conflict`。规划阶段不得 clone、修改 remote、移动目录或写回 YAML。
4. `additive` 项包括缺失主仓库的完整 clone，以及变更前后都解析为同一仓库名时的 origin 更新；校验完成后可自动执行，不使用 shallow clone。clone 先写入 `repositories/` 下本次操作独占的隐藏 staging 目录，验证 Git 身份、origin 和默认分支后再同卷原子改名到最终目录，绝不直接把半成品写入最终路径。
5. `cleanup` 项包括配置中已移除的主仓库和其关联 linked worktree。应用必须展示路径、dirty、关联 linked worktree 的 ignored content、所有本地分支的仅本地提交风险和将执行的操作，用户明确确认后才执行。
6. `repositories/` 中未声明但可验证为 Git 主仓库的目录进入待确认 cleanup；无法验证为 Git 仓库的目录属于 conflict，Modu 不移动、不覆盖。
7. URL 变化导致仓库名变化时，将其视为新仓库 additive 与旧仓库 cleanup 两个独立计划，不能因新仓库 clone 成功而自动授权旧仓库清理。

App 和 CLI 执行每个 additive 或 cleanup 项前，都按规范化仓库身份获取同一把跨进程仓库生命周期锁并在锁内重新校验计划。锁从首次副作用前持有到该项的 journal/原子提交或清理边界完成，覆盖 clone 与 staging 提交、origin 更新、Fetch、Pull、worktree add/remove、记录分支删除和主仓库 Trash 移动；目标目录尚不存在时也使用同一身份锁，不能让 `repo reconcile` 绕过 worktree 命令使用的仓库锁。需要 group、仓库或工作区写锁时仍按规范化标识排序获取。

确认仓库 cleanup 后，先按 9.3 的规则逐个移除关联 linked worktree；只有全部关联 worktree 及其 YAML 记录都成功移除后，才把主仓库移入 macOS Trash。任一步失败都保留未完成的 worktree 记录和由当前文件状态重新派生的 cleanup 项供重试，并在 `Needs Attention` 中汇总，不把残留目录静默隐藏。

从主仓库右键菜单发起 Delete Repository 时，`Delete Repository?` 确认窗口展示的是锁内重新计算的当前计划。用户确认后先原子移除 `.modu.yaml` 中对应声明；配置写入失败则不执行任何 worktree 删除或 Trash 操作。配置写入成功后才执行上述 cleanup。对于用户已手工移除声明而产生的 cleanup，不再写配置。确认只授权当次未变化的计划；计划内容变化、应用重启或稍后重试都必须重新展示当前风险并再次确认。没有关联 linked worktree 时确认按钮为 `Delete Repository`；存在关联项时为 `Delete Repository & <N> Worktrees`。

单仓库失败不阻断其他仓库的 additive 项。若配置仍声明某主仓库但 clone 暂时失败，只标记异常，不清理它的 linked worktree。目标路径存在但不是预期 Git 仓库、符号链接异常或 origin 身份冲突时，标记 conflict 并等待用户处理。

clone 在创建 staging 前先原子写入不含凭据的 operation journal，并在成功提交或确认移入 Trash 后清除。失败、取消或最终目录在提交前被占用时，只把 journal 与规范化路径都证明属于当前操作的 staging 目录移入 Trash，最终路径保持不存在或保留其原内容，因此 Retry 可重新开始。应用崩溃后遗留的 staging 不自动删除；Doctor 通过 journal 将其与普通仓库目录区分，提供 Reveal 和经确认的 Move to Trash。journal 缺失、路径不匹配或符号链接异常一律视为 conflict，不能只凭文件名前缀清理。

崩溃恢复按可证明状态处理：staging 存在且匹配 journal 时只报告待审查；staging 不存在而最终目录已是声明的有效仓库时只清除已完成 journal；两者都不存在时清除已中断 journal 并允许重新 clone；staging 与最终目录同时存在、最终目录身份不符或任一路径异常时标记 conflict。自动恢复只能清除 Application Support 中的 journal 元数据，不能借机移动或删除工作区目录。

## 8. Fetch 与 Pull

Fetch/Pull 只操作 `repositories/` 下的主仓库，不遍历 `worktrees/`。

### 8.1 Fetch

- 窗口每次激活时，检查每个主仓库最后一次成功 Fetch 时间。
- 距离上次成功 Fetch 超过 10 分钟时，后台执行 `git fetch --prune origin`。
- 手动全局 Fetch 忽略时间阈值并覆盖所有主仓库。
- 配置省略 `branch` 时，refs Fetch 成功后还必须查询远端 HEAD，并仅在目标分支已安全校验且对应 `refs/remotes/origin/<branch>` 存在时更新 `refs/remotes/origin/HEAD`；普通 `git fetch` 不保证更新该 symbolic ref，不能据此继续把旧值当作远端当前默认分支。
- 省略 `branch` 的仓库只有 refs Fetch 与 `origin/HEAD` 刷新都成功才记录本次 Fetch 成功时间。HEAD 查询、格式校验或 symbolic ref 更新失败时，该仓库结果为 `failed`，保留上一次本地状态并按 Fetch 失败反馈；若默认分支发生变化，立即使依赖 Base 的 Status 和独有提交缓存失效并重新加载。显式配置 `branch` 的仓库不依赖该刷新步骤。
- 自动 Fetch 成功保持静默，不使用手动操作的标题栏暂态；失败时不弹窗打断用户，只更新可关联的非模态异常状态。相同仓库、相同原因在状态改变前只记录和呈现一次。

### 8.2 Pull

手动全局 Pull 对每个主仓库执行预检：

- 工作区必须 clean。
- 当前分支必须等于配置解析出的默认分支。
- 满足条件后执行 `git pull --ff-only origin <branch>`。
- dirty 或非默认分支归入 `skipped`；分叉、目录缺失、认证或 Git 执行错误归入 `failed`。不自动 merge、rebase 或 checkout。

### 8.3 调度与反馈

- Fetch、Pull 和批量 Git 操作采用最大并发数 6 的有界并发。
- 同一仓库同一时刻只执行一个 Git 或仓库生命周期写操作，并复用第 7 节的跨 App/CLI 仓库锁；桌面端同一时刻只启动一个 repositories 级批量任务，避免 Fetch 与 Pull 相互排队形成不可预测结果。
- 手动 Fetch/Pull 期间，Add、Fetch、Pull 三个全局按钮保持尺寸不变并统一禁用；标题栏 workspace-title 以 spinner 和 `Fetch 'origin'` 或 `Pull 'origin'` 替换工作区名称。界面不显示逐仓库同步状态、内容区进度、完成计数或 Stop。
- 手动操作全部成功时，标题栏显示 `Already up to date` 3 秒，再恢复工作区名称；不显示成功 toast。不存在主仓库时按钮禁用，不生成成功暂态。
- 手动操作存在 `skipped` 或 `failed` 非成功项时，先恢复工作区名称，再显示一次汇总弹窗。策略条件不满足归为 `skipped`，Git、认证、文件系统或进程错误归为 `failed`。汇总列表只读，不提供选中态或行级操作，底部只保留 `Done` 关闭按钮。
- Fetch/Pull 不提供界面内取消入口；工作区切换或应用退出触发的内部取消仍按第 14.3 节终止进程并保留已成功项，不显示 `Already up to date` 或旧工作区结果弹窗。
- 后台 Git 进程不从标准输入读取凭据；认证不可用时快速失败，并给出不含凭据和完整 Git 输出的可操作原因。

## 9. CLI 与 worktree 生命周期

### 9.1 命令面

```text
modu-cli repo list [--json]
modu-cli repo reconcile [--apply] [--yes] [--json]
modu-cli worktree list [--json]
modu-cli worktree create <group> --repo <repo-name>... [--branch <repo>=<branch>] [--document <path>] [--json]
modu-cli worktree remove <group> [--repo <repo-name>] [--yes] [--json]
modu-cli doctor [--repair] [--json]
```

CLI 从当前目录向上查找 `.modu.yaml`，并支持全局 `--workspace <path>`。

`repo reconcile` 默认只输出计划。`--apply` 执行 additive 项；计划包含 cleanup 时还必须同时传入 `--yes` 才执行 cleanup，否则 cleanup 保持待确认。单独传入 `--yes` 而没有 `--apply` 属于无效调用，避免让用户误以为已执行计划。v0.1 不提供 `plan-id` 或预览计划绑定：`--yes` 表示无条件接受命令执行时在锁内生成并完成全部安全校验的当前计划，而不是接受先前某次输出；它不能跳过风险读取、身份校验或路径边界检查。

所有命令的 `--json` 都只向 stdout 输出一个带 `schema-version`、`command`、总体 `status` 和逐项 `items` 的 JSON 对象；逐项包含稳定的 `kind`、`status`、`reason-code` 和经凭据清理的 `message`。进度与诊断只写 stderr，不输出 ANSI 控制字符，不把 Git 原始输出混入 JSON。`--json` 隐含非交互模式，永不读取 stdin；需要确认但缺少 `--yes` 时返回 `confirmation-required`，不静默执行。

退出码固定为：`0` 表示命令成功且所有请求的动作完成，或只读 list/plan 成功生成；`1` 表示命令完成但存在 skipped、conflict、failed、confirmation-required 或 Doctor 问题；`2` 表示参数、工作区或配置在执行前无效；`130` 表示命令被取消。部分成功返回 `1`，但由用户中断导致的部分成功仍返回 `130`；两者都由逐项 JSON 保留真实结果。

### 9.2 创建

1. 按 5.2 的统一 schema 校验 group、记录分支和规范化身份，拒绝与现有 group 碰撞；CLI 不使用比配置加载更宽松或更严格的另一套身份规则。
2. 校验目标仓库、主工作树、分支、document 和路径；已有 group 的 `created-at` 永不重写，请求省略 `document` 时保留原值，显式传入相同规范化路径视为幂等，传入不同路径则在任何 Git 副作用前报 conflict。同一 group 的一次 create/remove 命令持有跨 App/CLI 的 group 操作锁，同一仓库的 worktree 创建/删除和记录分支删除复用第 7 节定义的跨进程仓库生命周期锁。需要多个锁时按规范化标识排序获取，避免死锁。
3. Fetch 默认分支；Fetch 失败时该仓库失败，不使用可能过期的 `origin/<default-branch>` 创建新分支。
4. 目标路径、Git worktree 注册、主仓库和分支与现有 YAML 记录完全匹配时视为幂等成功。
5. 若 `git worktree add` 已成功而 YAML 写入因崩溃或 I/O 错误未完成，重试时只有在目标路径、Git 注册、主仓库和分支全部精确匹配请求，且 group 的 `document` 等元数据没有冲突时，才补写缺失记录并视为恢复成功；该恢复不得 reset、checkout 或改写现有 worktree。无法证明唯一匹配时标记 conflict。
6. 除上述可证明恢复外，目标路径、Git 注册、分支或 YAML 记录任一不匹配都标记 conflict，不移动、不覆盖、不重置分支。
7. 新分支在本地和远端都不存在时，从最新 `origin/<default-branch>` 创建；仅远端存在时创建 tracking 分支；本地已存在时复用本地分支，但若它已在其他 worktree 检出，或与同名远端的 tracking 关系冲突，则失败并说明原因。复用分支不执行 reset、merge 或 rebase。
8. 每个仓库完成 Git 创建后立即在配置写锁内重新读取并原子更新 `.modu-worktrees.yaml`；写入失败不反向强删刚创建的 worktree，而是保留上述可恢复状态并报告失败。
9. 首个成功项创建需求组并写入本地 `created-at`；最后一个 worktree 被移除后删除空 group。
10. 多仓库创建最大并发数为 6。成功项保留，再次执行同一命令只补齐缺失项或恢复第 5 项定义的完整匹配项。

默认目录为 `worktrees/<group>/<repo-name>`，默认分支为 `<group>`。

桌面端从 Worktrees 标题的 Add 按钮进入创建流程。Create Worktree Group 只接受 Group Name 和仓库多选列表；Group Name 按 5.2 原样校验并保存，仓库顺序沿用 `.modu.yaml`，列表行高固定为 32px，不展示选择数量、路径或分支预览、`document` 或帮助文案。提交后逐仓库执行既有幂等创建流程，保留成功项并允许重试失败项。

Edit Worktree Group 的 Group Name 只读，仓库列表增加 Working Tree 状态列：`Clean`、`Dirty`、`Unknown` 和新选仓库的 `Not Created`。状态只覆盖 staged、unstaged 和 untracked；`Clean` 不代表不存在 ignored content 或未推送提交。用户可以取消勾选 Dirty 或 Unknown 项；存在移除项时 `Save Changes` 使用 destructive 样式，但提交后不展示第二个确认页。新增项复用本节创建流程，移除项复用 9.3 的强制 worktree 移除和本地分支删除顺序。

### 9.3 删除

用户从独立 Delete Linked Worktree 或 Delete Worktree Group 命令发起删除时，无论是否 dirty，都必须二次确认。确认内容列出：

- 仓库名。
- worktree 路径。
- 本地分支。
- dirty 状态。
- ignored content 状态：`None`、`Present` 或无法确认时的 `Unknown`；存在时提供可展开的受影响路径摘要。
- 可检测到的未推送提交风险，或无法确认时的 `Unknown`；detached HEAD 必须单独标明。

dirty 统计包含 staged、unstaged 和 untracked 文件。Git 默认 dirty/status 不包含 ignored 文件，但 `git worktree remove --force` 会删除整个 linked worktree，因此 ignored content 必须作为独立的本地数据风险检测；`clean` 不能暗示没有本地内容，读取失败也不能按 `None` 处理。未推送风险以当前 worktree HEAD 和记录中的本地分支（若存在）为风险根，统计可达但任何本地 remote-tracking ref 都不可达的提交并去重；它是基于最近一次已知 refs 的保守检查，不声称代表服务器实时状态。detached HEAD 显示 `Detached at <short-sha>` 并纳入风险，不能只检查记录分支。若 worktree 附着到不同于记录的本地分支则标记 identity conflict，不执行删除；无法读取 refs、HEAD 或分支时必须显示 `Unknown`，不能按零风险处理。

独立删除流程在用户确认后先获取 group 与仓库锁，并立即重算路径、Git 注册、分支、dirty、ignored content 清单和未推送风险；任一项与确认页不同都不执行破坏性命令，而是返回更新后的计划要求再次确认。仓库 cleanup 在移动主仓库到 Trash 前也重新检查主工作树和所有本地分支风险；若风险变化则保留已完成的 worktree 删除结果，暂停主仓库移动并重新确认。

Edit Worktree Group 是明确例外：取消勾选已有成员并提交 `Save Changes` 即构成本次强制移除授权，不再展示 ignored content、未推送提交或第二个风险确认页。执行前仍必须在 group 与仓库锁内重新校验路径、Git 注册、记录分支和 working tree 状态；锁内状态与编辑列表不同的 removal 不执行并刷新对应行，其他不受影响项继续。Dirty 与 Unknown 不禁止取消勾选或保存。成功移除 worktree 并删除本地分支后才移除 YAML 记录；失败项保留并支持 Retry Failed。编辑流程不能移除最后一个成员。

确认后依次执行：

```text
git worktree remove --force <path>
git branch -D <branch>
```

只有 worktree 移除成功后才删除记录中的本地分支，远端分支永不删除。只有目录移除成功，且本地分支删除成功或在确认计划中已验证不存在，才删除该 YAML 记录；若分支删除失败，保留记录并标记为可重试的 cleanup 异常。再次确认并重试时，若可证明目标路径已不存在、Git 已无该 worktree 注册且记录中的本地分支仍匹配，则把目录移除视为已完成并从分支删除继续；若分支也已不存在，可在确认后移除残留记录。任何仍存在的路径、注册或身份不一致都转为 conflict，不把“找不到目录”直接当作成功。删除 group 时，确认窗口列出全部相关 worktree、本地分支、dirty、ignored content、detached HEAD 和未推送风险，再逐项执行相同流程。单项失败时保留其分支和配置，其他项继续，最后显示一次逐项结果汇总；全部成功后的选择与键盘焦点恢复按 `DESIGN.md` 执行，优先落到删除位置相邻的可见安全节点，没有可用节点时才回到未选择状态。

CLI 交互模式展示删除计划并要求确认；非交互模式必须显式传入 `--yes`。v0.1 的 `--yes` 不绑定先前预览，也不要求 `plan-id`；它无条件接受命令执行时在锁内生成并完成全部安全校验的当前计划。即使带 `--yes` 也不能跳过风险读取、身份校验或路径边界检查。仓库配置对账 cleanup 复用同一 worktree 风险检查和确认语义，不能绕过强制删除授权；关联 worktree 清理完成后，主仓库目录本身移入 Trash。

### 9.4 Doctor

`doctor` 默认只诊断配置、目录、Git worktree 注册、operation journal、CLI 和 skills 链接。`--repair` 只执行可证明安全且不丢失恢复线索的修复，例如重建确认属于 Modu 的符号链接，或按第 7 节恢复矩阵清除已完成/已中断 journal；不删除分支、有内容的目录或仍承载失败删除状态的 YAML 记录。需要破坏性处理时只输出计划和下一步命令。

## 10. 内置 skill

`$create-worktree` 负责：

- 根据需求上下文和 `.modu.yaml` 选择仓库。
- 生成 group、分支和方案文档路径。
- 使用 `--json` 调用稳定的 `modu-cli worktree create` 接口并按 `schema-version` 解析，不从人类可读文本猜测结果。
- 解释全部成功、部分成功和失败结果。

skill 不直接拼接 `git worktree` shell 流程，避免提示词承担易变的实现细节。

## 11. 主窗口信息架构

主窗口使用原生 `NavigationSplitView`。标题栏高度固定为 36px，不显示产品名。正常状态居中显示当前工作区目录名；手动 Fetch/Pull 运行时同一 workspace-title 区域显示 spinner 和 `Fetch/Pull 'origin'`，全部成功后显示 `Already up to date` 3 秒再恢复目录名。标题区域始终保留重新选择工作区的命中区和取消旧任务契约；名称或暂态文案右侧不显示三角、箭头或其他 disclosure 图标。

左侧默认宽度 320px，可拖动，只分为：

- `Repositories`：按仓库展示名列出主工作树，标题右侧固定提供 Add、全局 Fetch 和全局 Pull 三个无边框 SVG 图标按钮；三个图形分别为 plus、clockwise refresh 和 down-to-line，浅色外观默认图标色为 `#4D4D4D`。
- `Worktrees`：按 group 展开，再列出带缩进的仓库 linked worktree；标题右侧提供 Create Worktree Group 的无边框 plus 图标按钮。

`Repositories` 和 `Worktrees` 标题左侧都依次显示 chevron 和 open/closed folder。chevron 与 folder 共同表达 Expanded/Collapsed：展开时 chevron 向下并使用橙色 open-folder，折叠时 chevron 向右并使用蓝色 closed-folder。标题整行都是折叠命中区，但 `Repositories` 右侧 Add、Fetch、Pull 操作区只执行各自动作，不触发折叠。键盘焦点落在分区标题时，`Left/Right` 折叠或展开，`Return` 切换当前状态；VoiceOver label/value 必须同时读出分区名和 Expanded/Collapsed。

侧栏中的主仓库、group 和 linked worktree 行高统一为 32px。主工作树或 linked worktree 存在 staged、unstaged 或 untracked 变化时，在最右侧固定变化槽位显示直径 6px、颜色 `#AAAAAA` 的圆点；ignored content 不触发圆点，group 和分区标题不聚合圆点。圆点只作快速视觉提示，行的 accessibility value 和 tooltip 必须明确读出 `Working tree has changes`。Fetch/Pull 不在仓库行叠加同步状态或 spinner。

主仓库和 linked worktree 使用固定蓝色的仓库/工作树图标；图标不支持用户自定义颜色，也不承担独立点击动作。点击整行选择节点，右键菜单继续承载路径和删除等低频操作。

group 左侧依次显示 chevron 和 open/closed folder，使用与分区一致的状态映射：展开为向下 chevron 与橙色 open-folder，折叠为向右 chevron 与蓝色 closed-folder。group 整行点击切换展开/折叠，不提供自定义颜色或独立图标操作。路径、编辑和删除等低频操作通过右键菜单提供，不在行内增加操作按钮。状态异常、dirty 和缺失使用 32px 稳定行高内的固定状态槽位表达。

任一由 Repositories 标题操作组触发的异步操作运行时，Add、Fetch 和 Pull 三个按钮都保持原有 24px 命中尺寸并统一置灰禁用，不能再次触发。Fetch/Pull 的当前操作与完成反馈只占用标题栏 workspace-title；不在标题按钮、主仓库行或右侧内容区重复显示进度。

右侧内容区：

- 未选择节点：正常状态只显示居中的静态图标和 `What should we build?`，不显示工作区概览、仓库或 group 列表、统计、Add Repository 主操作或外部工具操作区；用户从侧栏 Repositories 标题的 Add 按钮进入添加流程。阻断性配置错误和必须处理的安全流程可覆盖静态内容。
- 选择主仓库或 linked worktree：顶部显示外部工具操作区；下方复用相同的 Git Browser 卡片骨架。`Worktrees` 摘要卡先显示当前工作树相对工作区根目录的路径，再显示 Base、Branch、Status；非 clean 时显示 `Changes` 卡，存在可展示提交时显示 `Commits` 卡。
- 主工作树的 `Commits` 卡显示当前分支历史；linked worktree 的 `Commits` 卡只显示相对默认分支的独有提交。两者只改变数据范围，不改变卡片顺序、行结构或交互模型。

右键菜单中的 `Copy Path` 复制经安全校验的规范化绝对路径；路径不存在、越过受管边界或存在符号链接逃逸时隐藏该命令。`Reveal in Finder` 无法执行时保留但禁用，并提供具体原因。group 菜单固定且均不带省略号：`Copy Path`、`Reveal in Finder`、`Edit Worktree Group`、`Delete Worktree Group`；无论 `document` 是否有效都不显示 Open Plan 或 Reveal Plan in Finder。主仓库菜单固定为 `Copy Path`、`Reveal in Finder`、`Delete Repository`，后者进入第 7 节 cleanup 确认流程。linked worktree 菜单提供 `Copy Path`、`Reveal in Finder`、`Delete Linked Worktree…`，其独立删除与 group 独立删除均进入第 9.3 节确认流程。右侧详情不重复提供 Reveal 按钮。

摘要卡中的定位与分支信息统一分为：

- `Path`：当前工作树相对工作区根目录的规范化路径。主工作树为 `repositories/<repo-name>`，linked worktree 为 `worktrees/<group>/<repo-name>`；使用仓库内部身份和 group 的规范化身份派生，不使用展示名，不包含工作区绝对路径、前导 `./` 或尾随 `/`。
- `Base`：配置解析出的默认分支。
- `Branch`：当前工作树分支。
- `Status`：统计当前分支相对 Base 的聚合文件变化，可由 `git diff --name-status origin/<base>...HEAD` 派生；仅使用图标和数字显示 Added、Moved、Modified、Deleted，不显示文字标签。Moved 图标对应 rename/move 状态，浅色外观使用紫色 `#B262ED`；数字只有达到 4.5:1 对比度时才可跟随状态色，否则使用系统主文字色。工作区 dirty 状态在仓库详情中单独展示，Status 不等同于未提交变更列表。

Path 只用于当前选择的定位与上下文确认，不是路径编辑或独立操作入口。空间不足时使用中部截断，tooltip 和 accessibility value 必须提供完整相对路径；不得为避免截断改为显示绝对路径。切换选择时 Path 与详情内容使用同一 selection generation 更新，禁止在新选择下短暂保留旧路径。

Git 文件状态到四类展示的映射必须唯一且在详情头、Changes 文件区和结果统计中复用：`A`、`C` 与 untracked 归入 Added，`R` 归入 Moved，`M` 与 `T` 归入 Modified，`D` 归入 Deleted。Moved 行同时显示新路径，并以次级文本显示 `from <old-path>`；冲突或未知状态显示可访问的 Unknown 占位并记录诊断，不能借用其他图标或颜色。

当前工作树为 detached HEAD 时，`Branch` 显示 `Detached at <short-sha>`，不伪造分支名。全局 Pull 将其归为 `skipped`；linked worktree 的独有提交和 Status 仍以 HEAD 计算，删除风险按第 9.3 节处理。

点击 Add 打开仓库添加 sheet。表单正文只包含 `Repository URL`、`Display Name (Optional)` 两个标签和对应输入框，不显示帮助文案、派生仓库名、目标目录、路径预览或默认分支说明。仓库名和目标目录仍从 URL 内部派生，默认分支仍在 clone 后从 origin 自动解析；由派生结果触发的校验错误关联回 URL 字段，不提供 URL 之外的目录或默认分支编辑。

## 12. 外部工具注册表

仓库或 linked worktree 上下文保留四个独立分裂按钮：

1. Agent：Codex、Claude Code。
2. Git GUI：Fork。
3. 编辑器：VS Code、Cursor。
4. 终端：Warp、Terminal。

规则：

- 先运行每个目标的 `detect()`，只展示检测成功的内置目标。
- 目标还要声明支持普通目录还是必须为 Git working tree。未选择状态不显示任何外部工具入口；只有选中主仓库或 linked worktree 后，才按当前受管目录展示全部适用类别。
- 某类别没有任何已检测且适用于当前路径的目标时隐藏整个按钮。
- 应用私有数据中只维护一份外部工具全局偏好配置，每个类别在该配置内保存一个默认目标；不提供工作区级、仓库级或 worktree 级偏好。
- 分裂按钮主要区域显示该类别当前默认目标的图标和名称；点击后直接使用该目标打开当前选中的主工作树或 linked worktree 路径。右侧 chevron 是独立命中区，点击只打开目标菜单，不同时启动默认目标。
- 目标菜单不显示 check 图标、选中态或其他持久默认标记；鼠标 hover 的菜单项仅使用浅灰背景表达交互态。键盘焦点使用原生菜单焦点反馈，但不得被保存或渲染为选中态。
- 点击菜单项后立即尝试用该目标打开当前路径，只有启动成功后才更新全局偏好配置中对应类别的默认目标；失败时保留原默认值。默认目标消失时临时选择该类别第一个可用内置目标，但同样只在成功打开目录后持久化。
- 首版不允许添加自定义 App 或命令模板。

启动契约：

- Codex：界面显示“Codex”。优先检测支持 `app` 子命令的 `codex` CLI 并执行 `codex app <path>`；CLI 不可用时检测 Bundle ID `com.openai.codex`，再通过 `NSWorkspace` 用该应用打开目录。官方当前称其为 ChatGPT desktop app，并保留 `Codex.app` 兼容 bundle 路径；实现不得依赖可变的文件名或展示名。
- Claude Code：同时检测 `claude` CLI 和至少一个可用终端；通过当前首选终端在目标目录启动 `claude`。缺少终端时不展示 Claude Code 目标。
- Fork、VS Code、Cursor：使用 Bundle ID 和应用/CLI 的目录打开能力。
- Warp、Terminal：在目标目录创建新窗口或标签页。

启动参数使用结构化参数数组，不拼接未经转义的 shell 字符串。启动前重新验证目录存在；外部工具入口只接受 `repositories/` 或 `worktrees/` 的受管后代，并拒绝符号链接逃逸。该能力不放宽文件、Git 或清理操作的受管路径边界。需要 Apple Events 时，由 macOS 正常请求 Automation 权限；权限拒绝或应用启动失败使用非模态错误反馈，并提供可复制的整理后原因。

## 13. Git Browser Detail

Git 浏览在左侧选中主工作树或 linked worktree 后显示，并复用同一组功能卡片：

- `Worktrees` 摘要卡始终位于顶部，首行显示当前选择的工作树相对工作区根目录的 Path，再显示 Base、Branch、Status。`Status` 下方的 `Changes` 卡展示当前工作树；计数包含 staged、unstaged 和 untracked 的不同路径，同一路径同时存在 staged 与 unstaged 变化时只计一次；ignored 文件不计入。工作树 clean 时整个 `Changes` 卡隐藏，不显示零计数或空状态。
- `Changes` 默认展开，以紧凑平铺列表显示仓库相对路径。文件名前使用 Added、Modified、Deleted、Moved 四类图标和颜色，最右侧不重复显示状态文字；Moved 使用紫色 `#B262ED` 并显示新旧路径。冲突或无法映射的状态使用中性 Unknown，不新增第五种状态图标。
- Changes 文件行和 Commits 提交行的高度统一固定为 28px。长路径、长提交信息、焦点态和状态图标不得改变行高；Moved 的新旧路径在同一行内表达，空间不足时截断，完整值通过 tooltip 和 accessibility value 提供。
- Changes 读取失败时显示 `Unavailable`、整理后的原因和 Retry，不能把读取失败当作 clean 而隐藏。
- `Commits` 卡按新到旧展示提交列表。主工作树读取当前分支可达历史；linked worktree 读取 `origin/<default>..HEAD` 的独有提交。卡片标题只显示 `Commits`，不增加 `unique from <base>` 说明、HEAD/分支 badge，也不通过提交选择展开文件树。
- 每个提交固定为一行 28px，只显示提交信息、提交人、提交时间和短哈希；长内容单行截断，完整值通过 tooltip 和 accessibility value 提供。没有可展示提交时隐藏整个 `Commits` 卡，不显示零提交空状态。
- linked worktree 的 Base ref 缺失、仓库处于未完成 merge/rebase 或 Git 读取失败时显示可恢复错误和 Retry，不能伪装成没有提交；主工作树历史读取失败使用相同错误框架，但不依赖 Base。Changes 的读取与展示均独立于提交历史。
- 首批提交最多显示 100 条，超过时按需加载更多；v0.1 不展示单个提交的文件树，也不实现逐行 diff。
- 切换节点时立即更新 Path，并取消过期请求。Changes 随工作树文件事件或显式刷新重新读取；主工作树历史按 HEAD OID 缓存，linked worktree 独有提交按 HEAD/base OID 缓存，相关 refs、HEAD 或 Base 改变后失效。

## 14. 异常、并发与安全

### 14.1 结果模型

所有批量操作返回逐仓库 `success`、`skipped`、`failed` 或 `cancelled` 结果，并附带面向用户的原因。已完成项保持有效，未完成项不写成功记录。

配置域、批量 Git 域、worktree 生命周期域分别维护错误状态，禁止一个域的错误无条件冻结其他安全能力。所有可重试错误提供 Retry；不可由应用修复的冲突提供 Reveal/Open Config 或 Copy Details。自动后台任务不弹模态结果，用户发起的危险操作和存在问题的手动批量操作只各显示一次汇总。

### 14.2 文件安全

- 只处理 `repositories/` 和 `worktrees/` 的受管后代。
- 文件操作前解析标准路径，拒绝工作区根、受管根、路径逃逸和异常符号链接目标。
- 仓库配置对账清理永远使用 macOS Trash，不执行递归永久删除。
- worktree 强制删除是用户明确确认后的例外，界面必须说明 dirty、ignored content 和仅本地提交可能永久丢失。

### 14.3 取消与退出

- 用户取消时先向子进程发送正常终止信号。
- 已成功项不回滚，未完成项不记为成功。
- clone 取消遵循第 7 节 staging 规则，不把半成品暴露为最终仓库；Add/clone 进度提供 Cancel。
- 应用退出时若正在提交原子文件替换或目录迁移，等待当前原子步骤完成。
- 工作区切换、节点切换和应用退出都必须丢弃带旧 workspace/repository generation 的异步结果，避免把迟到状态写入新选择。

### 14.4 日志

使用 `os.Logger` 按 Workspace、Git、CLI、Launcher 分类。日志不记录带凭据 URL、敏感环境变量或未经整理的完整 Git 输出。

## 15. 测试策略

当前阶段仅验证本地开发构建，不包含签名、公证或正式分发测试，也不设置性能验收指标。

### 15.1 ModuCore 单元测试

覆盖：

- SSH、HTTPS、file 和本地路径的仓库名解析，凭据 URL 拒绝、大小写/Unicode 碰撞、不同远端同名仓库拒绝和路径逃逸。
- YAML schema、版本、未知字段、时间格式和默认分支字面量校验。
- `.modu.yaml` GUI 修改保留未改动注释/顺序，无法安全修改时拒绝写入。
- 首次采用已有目录、配置缺失、分域配置错误、路径安全和无副作用对账计划。
- 工具选择、结果汇总和全局偏好。

### 15.2 Git 集成测试

在临时目录中创建本地 bare remote，覆盖：

- clone、fetch、远端默认分支变化后的 `origin/HEAD` 刷新与 Base 缓存失效，以及 fast-forward pull。
- clone 失败、取消、提交前目标竞争和崩溃遗留 staging，不得污染最终路径或被静默删除。
- clone 原子改名后崩溃、受控失败后 journal 残留、staging/final 同时存在的恢复矩阵。
- dirty、非默认分支、detached HEAD 和分叉跳过。
- worktree 幂等创建、部分失败和重试。
- Git worktree 已创建但 YAML 写入失败后的精确匹配恢复，以及不匹配 orphan 的 conflict。
- 现有本地/远端分支复用冲突、过期 Fetch 拒绝、group 规范化碰撞，以及既有 group 的 document 幂等与冲突。
- dirty/untracked、ignored content 与未推送风险计算，`worktree remove --force`，以及本地分支删除失败后的中间态续跑和 cleanup 重试。
- 仓库 cleanup 在关联 worktree 失败时不移动主仓库，成功时只把主仓库移入 Trash。
- App/CLI 的 group/仓库跨进程互斥，覆盖 reconcile clone/origin 更新/cleanup 与 Fetch/Pull/worktree 生命周期的交叉并发，以及并发写入和原子 YAML 更新。
- CLI JSON stdout/stderr 隔离、稳定退出码、`--yes` 接受执行时当前计划的非交互确认语义，以及逐项部分成功结果。

测试不访问真实网络或用户仓库。

### 15.3 App 与 UI 测试

通过可注入的 FileWatcher、Clock、ProcessRunner 和 ToolDetector 验证：

- 十分钟 Fetch 触发和最大并发数 6。
- Fetch/Pull 标题栏 running 状态、`Already up to date` 三秒恢复、问题汇总弹窗和错误去重。
- 工作区切换/退出取消、自动 Fetch 非模态失败、空工作区和 repo cleanup 确认。
- 未选中节点时隐藏工具入口、节点上下文适用性过滤，以及 `.modu-worktrees.yaml` 错误时阻止 repository cleanup。
- 过期 Git 请求取消。
- 首次初始化冲突、仓库添加验证、侧边栏键盘选择、分裂按钮成功后保存偏好、方案文档入口和删除二次确认。
- VoiceOver label/value、焦点恢复、状态不只依赖颜色和关键操作的完整键盘路径。

### 15.4 本地冒烟

覆盖本地 `xcodebuild`、App 启动、CLI 构建、符号链接可执行性，以及一个临时工作区的端到端流程。

## 16. 实施里程碑

1. 建立 ModuCore、配置模型、原子存储、进程执行与测试基础。
2. 完成首次启动、CLI/skills 链接和主仓库声明式对账。
3. 完成 Fetch/Pull 调度、仓库状态和结果反馈。
4. 完成 worktree CLI、侧边栏管理、强制删除确认和 Doctor。
5. 完成外部工具注册表、主工作树/linked worktree Git 浏览和视觉打磨。
6. 完成本地构建、临时工作区端到端冒烟和组内源码试用。

## 17. 功能验收

v0.1 满足以下条件即完成：

- 用户无需手工创建 Modu 文件即可初始化任意可写工作区。
- 有效 `.modu.yaml` 能驱动主仓库 clone、origin 更新，并为额外目录和关联 worktree 生成可审查的 cleanup；只有确认后才执行清理。
- 配置缺失或无效不会触发任何目录清理；配置移除只生成待确认 cleanup，确认前不移动或强制删除数据。
- 激活自动 Fetch、全局 Fetch 和安全 Pull 符合已定义规则，并提供正确状态反馈。
- Codex 能通过内置 skill 和 CLI 幂等创建跨仓库需求组，并从部分失败中重试。
- 桌面端能展示、打开和经二次确认删除 linked worktree 或整个 group。
- 删除或仓库 cleanup 的部分失败保留可重试记录，且不会误报全部成功。
- 各目录上下文只显示已安装且适用的工具目标，并在成功启动后正确记住全局首选。
- 选择 linked worktree 后，非 clean 工作树能看到 Changes 文件数和文件区，存在独有提交时能看到无说明标题的单行提交列表。
- clean/dirty Changes、无独有提交、缺失 Base、rename/type-change、冲突状态和 Git 读取失败都有确定展示结果。
- 关键流程可通过键盘和 VoiceOver 完成，动态状态提供可访问通知，浅色与深色外观均保持可辨识。
- Core、Git 集成、关键 App 状态测试和本地端到端冒烟通过。

## 18. 视觉设计后续

视觉方向与状态原型已经完成审查。v0.1 以本文业务规则和 `docs/DESIGN.md` 交互规则为准；仓库根目录的 `design/prototypes/` 是代表性视觉参考，不是穷举状态机。实现还必须覆盖空工作区、clone 失败、待确认仓库 cleanup、`.modu-worktrees.yaml` 错误、无独有提交、Base 缺失、取消和删除部分失败，即使这些状态没有独立图片。

## 19. 参考资料

- [OpenAI：ChatGPT desktop app](https://learn.chatgpt.com/docs/app)
- [OpenAI：ChatGPT desktop app troubleshooting](https://learn.chatgpt.com/docs/reference/troubleshooting#feature-is-working-in-the-codex-cli-but-not-in-the-chatgpt-desktop-app)
- [Anthropic：Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference)
