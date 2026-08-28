# Modu Desktop Development Guide

## 项目定位

Modu Desktop 是面向多仓库、跨仓库需求开发的 macOS 原生工作区管理工具。它不替代 Codex、Claude Code、Git GUI、编辑器或终端，而是负责组织工作区、主仓库和 linked worktree，并将当前目录交给这些外部工具。

开始较大改动前先阅读：

- `docs/PRD.md`：产品范围、数据模型、技术架构和验收标准。
- `docs/DESIGN.md`：已确认的界面结构、交互规则和原型索引。

`docs/PRD.md` 是业务与安全规则事实源，`docs/DESIGN.md` 是交互规则事实源，原型图片只提供代表性视觉参考。三者或实现不一致时不要静默选择；先修正规则与原型，再同步实现。

## 当前工程结构

- `ModuDesktop/`：SwiftUI macOS 应用入口和界面。
- `ModuCLI/`：`modu-cli` 可执行目标。
- `ModuDesktopTests/`：单元与集成测试。
- `ModuDesktopUITests/`：关键桌面交互测试。
- `design/icons/`：已确认的界面图标。
- `design/prototypes/`：已确认的产品原型图。
- `script/build_and_run.sh`：本地构建、启动、调试和日志入口。

后续应建立共享的 `ModuCore`，让 App 和 CLI 复用配置、Git、文件系统、worktree 和外部工具逻辑。不要在两个 target 中分别实现同一业务规则。

## 架构约束

- `ModuDesktop` 和 `modu-cli` 都是薄入口，业务逻辑归属 `ModuCore`。
- SwiftUI View 只负责渲染和转发用户意图；进程、Git、文件系统和 YAML 操作不得直接写在 View 中。
- `AppModel` 及界面状态运行在 `@MainActor`；耗时操作使用结构化并发并支持取消。
- YAML 使用 Yams；CLI 参数使用 Swift Argument Parser；Git 统一调用系统 `git`。
- 所有外部命令使用可执行文件加参数数组，不拼接未经转义的 shell 字符串。
- 通过 `ProcessRunner`、`FileWatcher`、`TrashService`、`OperationJournal`、`Clock` 和 `ToolDetector` 等协议隔离副作用，以便测试替换。
- 同一组相关函数按自上而下顺序组织：入口/调用者在前，低层辅助函数在后。

## 产品不变量

### 工作区

- v0.1 只管理一个当前工作区。
- 首次设置必须依次完成 `modu-cli` 安装和工作区选择；任一步未完成都不能进入主窗口，不提供跳过或稍后处理入口。
- Modu 只读取和编辑工作区相关数据，不负责工作区自身的 Git 初始化、提交、`.gitignore` 或版本管理。
- 首次采用已有目录必须先做无副作用检查；配置缺失或无效但受管目录已有内容时停止初始化，不创建空配置、不触发清理。
- 工作区 skills 是指向 Application Support 中受管资源的符号链接；应用升级后更新受管资源，符号链接自动获得新版本。
- 不得把工作区内的 skills 复制成独立副本，也不得覆盖不属于 Modu 的同名文件或符号链接。

### 仓库配置

- `.modu.yaml` 是主仓库声明的唯一事实源。
- 仓库内部身份由 URL 最后一段去掉 `.git` 后得到，且在工作区内必须唯一；v0.1 不支持不同远端的同名仓库，也不提供 `id`、目录别名或展示名作为绕过方式。
- `name` 可选，只影响展示名；目录、YAML 键和文件操作始终使用仓库名。
- Add Repository sheet 只显示 `Repository URL` 和 `Display Name (Optional)` 两个字段及底部操作；仓库名、目标目录和默认分支仍按既有规则内部派生，不显示帮助文案、派生值或路径预览。
- `.modu.yaml` 显式 `branch` 及从 `origin/HEAD` 解析出的默认分支必须是可安全作为字面量使用的 Git 分支名；进入任何 Git 参数前拒绝非法 ref、前导 `-` 和 checkout shorthand。显式值非法视为配置错误，远端解析结果非法视为仓库异常。
- GUI 不提供 URL 和默认分支编辑；用户手工修改有效配置后，以最新配置重新解析。
- 缺少的主仓库自动 clone；配置移除和配置之外的有效 Git 仓库只生成 cleanup 计划，用户确认前不移动或删除。
- clone 必须先持久化不含凭据的 operation journal，再写入 `repositories/` 下本次操作独占的隐藏 staging，校验后同卷原子改名；失败或取消只把 journal 与规范化路径都证明属于当前操作的 staging 移入 Trash。崩溃恢复可清除已完成或已中断的 journal 元数据，但遗留 staging、双路径或身份不符交给 Doctor 审查，不能凭名称自动清理或污染最终路径。
- 仓库 cleanup 先按已确认的强制删除流程移除关联 linked worktree，全部成功后才把主仓库移入 macOS Trash；非 Git 目录始终标记冲突。
- 目标目录存在但不是有效 Git 仓库时，标记冲突，不覆盖、不清理。
- 初始化完成后 `.modu.yaml` 或 `.modu-worktrees.yaml` 缺失均视为错误，不能解释为空配置。

### Fetch 与 Pull

- repositories 级 Fetch/Pull 只操作 `repositories/` 下的主仓库，不操作 `worktrees/`。
- 批量 Git 操作采用最大并发数 6 的有界并发；同一仓库同时只允许一个写操作。
- 配置省略 `branch` 时，每次 Fetch 在更新 remote-tracking refs 后必须重新查询并安全更新 `origin/HEAD`；普通 `git fetch` 不视为已完成该步骤。默认分支刷新失败时该仓库 Fetch 失败且不更新成功时间，不能静默把旧 `origin/HEAD` 当作最新结果。
- 窗口激活时，如果某主仓库距离上次成功 Fetch 超过 10 分钟，执行自动 Fetch。
- 全局 Pull 仅处理 clean 且当前分支等于默认分支的仓库，并使用 `--ff-only`。
- 自动 Fetch 成功保持静默、失败使用去重的非模态异常状态；手动 Fetch/Pull 运行时只在标题栏以 spinner 和 `Fetch/Pull 'origin'` 替换工作区名称，不显示逐仓库同步状态、内容区进度或 Stop。
- 手动 Fetch/Pull 全部成功后，标题栏显示 `Already up to date` 3 秒再恢复工作区名称，不显示成功 toast；存在 skipped 或 failed 项时恢复工作区名称并显示一次汇总弹窗。结果列表只读且不显示选中态或行级操作，底部只保留 `Done` 关闭按钮。
- 桌面端同一时刻只运行一个 repositories 级批量任务；同一仓库所有 Git 写操作互斥。Fetch/Pull 不提供界面内 Stop，工作区切换和应用退出仍按统一任务取消契约收束。

### Worktree

- `.modu-worktrees.yaml` 按 group 管理 linked worktree。
- 无论由 CLI 生成还是手工写入，group 都必须是合法单段目录名和可安全作为字面量使用的 Git 分支名；group 的规范化身份在配置内唯一，并统一用于目录映射、幂等判断和 group 锁键。任一 group 或记录分支非法或碰撞时，整份 `.modu-worktrees.yaml` 无效，不能进入 worktree 生命周期操作。
- GUI 新建 group 时原样保存 Group Name，不自动 slug 化；新建和编辑都必须至少选择一个仓库。未选择仓库时只禁用提交，不显示额外错误提示。
- `created-at` 使用本地时间 `YYYY-MM-DD HH:MM:SS`，不附带时区。
- 已有 group 的 `created-at` 不重写；省略 `document` 保留原值，相同规范化路径幂等，不同路径在 Git 副作用前报冲突。
- 创建流程必须幂等、可重试，并保留多仓库操作中的成功项。
- `git worktree add` 已成功但 YAML 写入失败时，只有路径、Git 注册、主仓库、分支和 group 元数据都精确匹配才能补写记录；不匹配项必须标记冲突。
- 同一 group 的 create/remove 使用跨 App/CLI 的 group 操作锁；同一仓库的 clone/staging 提交、origin 更新、Fetch、Pull、worktree 创建/删除、记录分支删除和 repository cleanup/Trash 移动统一使用跨进程仓库生命周期锁。锁按规范化仓库身份生成，目标目录不存在时也必须生效；多锁按规范化标识排序获取。
- 从独立 Delete Linked Worktree 或 Delete Worktree Group 命令删除时，无论 dirty 与否都必须二次确认。Edit Worktree Group 中取消勾选已有仓库并提交，以本次 Save Changes 作为移除对应 linked worktree 和本地分支的明确授权，不再展示第二个确认页。
- Edit Worktree Group 的 Working Tree 列只显示 Clean、Dirty、Unknown 或 Not Created；Dirty 与 Unknown 都允许取消勾选并保存，且 Clean 不表示没有 ignored content 或未推送提交。执行前在 group/仓库锁内重读身份与 working tree 状态；状态变化的 removal 不执行并刷新对应行，其他不受影响项继续。
- 用户确认后先执行 `git worktree remove --force`，成功后再对仍存在的记录分支执行 `git branch -D`。
- 删除弹窗必须列出 worktree、对应本地分支、dirty 状态、ignored content 风险和可检测到的未推送提交风险。
- dirty 包含 staged、unstaged 和 untracked；ignored content 不计入 dirty，但会被 `git worktree remove --force` 一并删除，必须独立检测并在无法读取时显示 Unknown。未推送风险覆盖当前 worktree HEAD 与记录分支，detached HEAD 必须单独展示并纳入统计，无法读取时显示 Unknown。worktree 附着到不同于记录的分支属于 identity conflict。
- 确认后必须在 group/仓库锁内重算身份与风险；计划变化时不执行删除并要求重新确认。主仓库移入 Trash 前也要重新检查主工作树和本地分支风险。
- CLI 非交互破坏性操作保留 `--yes` 契约：它表示接受命令执行时在锁内生成并校验的当前计划，不与先前输出的计划绑定，也不能跳过风险读取、身份校验或路径边界检查。
- 只有 worktree 目录移除成功，且记录分支删除成功或在确认计划中已验证不存在，才移除 YAML 记录；部分失败保留可重试记录并汇总。
- 目录已移除但分支删除失败时，重试须重新确认风险并在验证目录不存在、Git 无注册且分支匹配后从分支步骤继续；身份不一致转为冲突。
- 永不删除远端分支。

## 文件与进程安全

- 只操作 `repositories/` 和 `worktrees/` 的受管后代；标准化路径后校验边界并拒绝路径逃逸和异常符号链接。
- 声明式对账清理必须移动到 macOS Trash，不执行递归永久删除。
- `git worktree remove --force` 仅可在用户明确确认的独立删除流程，或用户在 Edit Worktree Group 中取消勾选后提交 Save Changes 的成员移除流程中使用。
- 编辑或删除配置文件本身不构成 cleanup 或强制删除授权；规划阶段不得产生副作用。
- Delete Repository 确认后先原子更新 `.modu.yaml`；写入失败不得执行 worktree 删除或 Trash 操作，计划变化、重启或稍后重试都必须重新确认。
- YAML 写入采用工作区级 advisory lock、同目录临时文件、重新校验和原子替换。
- `.modu.yaml` 的 GUI Add/Remove 必须 source-preserving，保留未改动条目的顺序和注释并重新解析候选内容；无法安全修改时拒绝写入并提供 Open Config。`.modu-worktrees.yaml` 可规范化输出。
- `.modu.yaml` 错误冻结仓库对账和 repositories 操作；最后一次有效状态仅保留在内存中，错误解除前隐藏整个侧栏，并在标题栏下显示占满窗口主体的阻断恢复页。`.modu-worktrees.yaml` 错误冻结 worktree 创建、删除、修复和依赖关联 worktree 的 repository cleanup，但不冻结 Add、Fetch、Pull 或 additive 对账，并继续显示明确标记为 Stale 的最后一次有效 worktree 列表。
- 日志不得记录带凭据的 URL、敏感环境变量或未经整理的完整 Git 输出。

## 界面约束

- 使用原生 macOS 控件和 `NavigationSplitView`，保持紧凑、工作导向，避免卡片式仪表盘。
- 标题栏正常时居中显示当前工作区目录名；hover 有点击态，点击重新选择工作区；名称右侧不显示三角图标。手动 Fetch/Pull 期间同一位置仅显示 spinner 与 `Fetch/Pull 'origin'`，成功后显示 `Already up to date` 3 秒再恢复目录名。
- 左侧只显示 `Repositories` 和 `Worktrees`。两个分区标题左侧都依次显示 chevron 和 open/closed folder，二者共同表达展开状态；标题整行都可切换展开/折叠，但标题右侧操作区不触发折叠。`Repositories` 右侧提供 Add、Fetch、Pull，`Worktrees` 右侧提供 Create Worktree Group 的 plus 图标按钮。
- Repositories 的 Add、Fetch、Pull 分别使用简洁的 plus、clockwise refresh 和 down-to-line 图形；任一 Repositories 异步操作运行时三个按钮保持原尺寸并统一置灰禁用。Fetch/Pull 的 loading 与成功反馈只占用标题栏 workspace-title，不在按钮、仓库行或内容区重复表达。
- 主仓库和 linked worktree 使用固定蓝色的仓库/工作树图标；图标不支持自定义颜色，也不是独立操作入口。
- group 左侧依次显示 chevron 和 open/closed folder，整行点击展开或折叠；展开使用橙色 open-folder，折叠使用蓝色 closed-folder，不支持自定义颜色。
- 主仓库、group 和 linked worktree 侧栏行高统一为 32px。主工作树或 linked worktree 存在 staged、unstaged 或 untracked 变化时，在行尾固定槽位显示 `#AAAAAA` 的 6px 圆点；ignored content 不触发圆点，圆点不得替代可访问状态描述。
- 点击主仓库或 linked worktree 行执行选择；路径和删除等低频操作放入右键菜单，右侧详情不重复 Reveal。经边界和符号链接校验后，Copy Path 复制规范化绝对路径；路径异常时不显示 Copy Path。Reveal in Finder 无法执行时保留但禁用，并说明原因。
- group 右键菜单固定为 Copy Path、Reveal in Finder、Edit Worktree Group、Delete Worktree Group，始终不显示方案文档相关操作且文案不带省略号。主仓库右键菜单固定为 Copy Path、Reveal in Finder、Delete Repository；linked worktree 右键菜单提供 Copy Path、Reveal in Finder、Delete Linked Worktree。
- Create Worktree Group sheet 只显示 Group Name、32px 仓库 checkbox 列表及底部操作，不显示选择数量、路径/分支预览、document 或帮助文案。Edit Worktree Group 中名称只读，列表增加 Working Tree 状态列；存在 removal 时 Save Changes 使用 destructive 样式，但不再二次确认。
- Delete Worktree Group 确认页标题固定为 `Delete Worktree Group?`，不包含 group 名称；Delete Repository 必须先展示 cleanup 计划。
- 顶部四类分裂按钮为 Agent、Git GUI、编辑器、终端，只展示检测成功的内置目标。点击主要区域时使用当前类别的全局默认软件打开当前选中的主工作树或 linked worktree 路径；点击右侧 chevron 只打开目标菜单。菜单不显示 check 图标或选中态，仅在 hover 时显示浅灰背景；点击菜单项后立即尝试用该软件打开当前路径，只有启动成功才更新默认软件。
- 未选择主仓库或 linked worktree 时，右侧正常状态只显示居中的静态图标和 `What should we build?`，不显示工作区概览、统计、列表、操作按钮或外部工具入口；阻断性配置错误和必须处理的安全流程可覆盖该静态状态。只有选中主仓库或 linked worktree 后，才显示适用于当前受管目录的 Agent、Git GUI、编辑器和终端入口。
- 四类默认软件保存在应用私有数据中的同一份全局偏好配置内，不按工作区、仓库或 worktree 分别保存。外部工具只有启动成功后才更新对应类别的默认值；启动前重新验证目标仍是当前工作区的受管仓库/worktree，且没有符号链接逃逸。
- 主工作树和 linked worktree 复用相同的 Git Browser 卡片骨架：Worktrees 摘要卡首行显示当前工作树相对工作区根目录的路径，再显示 `Base`、`Branch`、`Status`；主工作树路径为 `repositories/<repo-name>`，linked worktree 路径为 `worktrees/<group>/<repo-name>`。界面不显示绝对路径；长路径中部截断，并通过 tooltip 和 accessibility value 提供完整值。
- 非 clean 时显示 Changes 卡；存在可展示提交时显示 Commits 卡。Status 仅以图标和数字展示 Added、Moved、Modified、Deleted；图标使用状态色，数字只有达到 4.5:1 对比度时才可同色，否则使用系统主文字色；Moved 浅色图标使用 `#B262ED`。
- Changes 文件行和 Commits 提交行的高度统一固定为 28px；长内容、焦点态、状态图标和 Moved 旧路径都不得撑高列表项，完整信息通过 tooltip 和 accessibility value 提供。
- detached HEAD 的 Branch 显示 `Detached at <short-sha>`；Pull 将其跳过，Git 浏览仍以 HEAD 计算。
- Git 状态统一映射为 `A/C/untracked → Added`、`R → Moved`、`M/T → Modified`、`D → Deleted`；rename 显示新路径与旧路径，冲突或未知状态使用中性 Unknown，禁止出现未定义的第五种状态图标。
- 主工作树的 Commits 显示当前分支历史；linked worktree 的 Commits 显示相对 Base 的独有提交。clean 时隐藏 Changes；提交卡只使用 `Commits` 标题，每行仅含提交信息、提交人、提交时间和短哈希，不显示提交文件树或逐行 diff。
- 核心流程必须支持键盘和 VoiceOver；折叠状态、无文字状态、标题栏 spinner/暂态文案和异步结果必须有可访问 label/value 或 announcement，并支持浅色与深色外观。

## 本地构建与测试

```bash
./script/build_and_run.sh --verify
```

调试和日志：

```bash
./script/build_and_run.sh --debug
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
```

运行测试时使用临时目录和本地 bare remote，不访问真实网络或用户仓库。测试重点覆盖配置解析、首次采用安全、无副作用对账计划、路径安全、跨进程锁、clone staging 与失败恢复、原子写入、Fetch/Pull 条件、worktree 幂等创建、Git 已创建但 YAML 写入失败的恢复、风险检测、强制删除确认与部分失败续跑。

当前仅做本地开发，不要求 Developer ID 签名、公证、正式分发验证或性能验收。不要因为缺少开发者账号把这些内容加入当前完成条件。

## 变更要求

- 保持改动范围贴合当前里程碑，不提前实现内置 AI 对话、完整 Git GUI、多工作区或自定义工具注册。
- 业务规则变化时同步更新 `docs/PRD.md`；交互和视觉规则变化时同步更新 `docs/DESIGN.md`。
- 新增或修改共享行为时，优先增加与风险相匹配的 Core 单元测试或 Git 集成测试。
- 不要提交生成目录、DerivedData、临时工作区、真实仓库数据或凭据。
