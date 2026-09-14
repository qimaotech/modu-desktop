# Modu Desktop Design Specification

- 日期：2026-09-30
- 状态：v0.1 核心工作流设计
- Figma：[Modu Desktop](https://www.figma.com/design/eK0CqTm1y4jk6thzqBdUV5/Modu-Desktop?node-id=16-6)

## 0. 文档职责

本文定义窗口、布局、交互、文案、无障碍和原型索引。业务、数据、授权及失败处理以 [PRD.md](PRD.md) 为准，不在界面另建规则。

保留现有原生桌面布局和核心表单；资源异常使用 Unavailable 和明确原因，取消双向同步选择与覆盖导入确认。状态优先级为：**工作区根/配置错误 → 操作与收尾 → 当前选择加载 → 局部错误 → 内容/空状态**。局部读取失败不遮蔽其他可用区域。

## 1. 设计基础

### 1.1 原生方向与字体

- 优先使用 macOS 26 的 SwiftUI/AppKit Window、Sheet、Alert、Menu、Toolbar、NavigationSplitView、Outline/Table 和 SF Symbols，保持紧凑，不增加仪表盘或装饰性卡片。
- 原型普通文字使用 SF Pro，路径、分支、哈希使用 Roboto Mono；实现使用系统语义字体和系统 monospaced font。
- 原型用于信息架构、密度和层级参考，不逐像素复制系统材质、阴影或字体渲染。

### 1.2 密度、图标与排序

| 行高基线 | 用途 |
| --- | --- |
| 28px | 侧栏节点、仓库选择、单行删除列表、Changes/Commits |
| 50px | 同时展示路径和当前分支的双行删除目标 |
| 32px | 分区标题、摘要行 |
| 36px | 表单输入行和管理按钮 |

长内容使用截断、tooltip、可访问值和原生滚动，不因状态切换反复改变行高。较大字号下以内容可达为先。

仓库/linked worktree 使用橙色仓库或文件夹图标，分区/Group 使用蓝色 folder；状态使用系统语义色，不能只靠颜色。Git 文件状态复用现有 vector assets；应用图标使用 [AppIcon.icon](../ModuDesktop/AppIcon.icon)，说明见 [图标文档](../design/app-icon/README.md)。

文件系统实体按同级可见名称做 Finder 风格自然升序，忽略大小写，数字按数值比较；同名以完整相对路径稳定排序。Group 和 Changes 保留层级，不按 dirty、勾选或结果类型重排。选择与焦点绑定实体，不绑定行号。

## 2. 窗口与导航

### 2.1 Setup Window

独立 720×520 原生窗口：CLI 检查 → 选择候选工作区 → Continue。CLI 必须通过 PRD 第 4.1 节的安装与可用性检查后才显示 Installed；未通过时禁用 Choose Workspace 和 Continue。安装、PATH 或运行检查失败均在原步骤说明原因，用户处理后可重试或退出，不提供跳过入口。已有 skill 冲突说明原因并允许 Continue Without Skill。

三个引导状态的步骤提示保持一致，03 沿用 01、02 的 CLI 与工作区说明；工作区提示固定为 `Select a writable local directory` / `选择可写的本地目录`，选择后的路径和状态在右侧展示。Git 初始化与忽略规则检查沿用第 2.1 节的 Continue 流程，不替换步骤提示。未登记但资源目录非空时提示 `Choose a folder with empty repositories/ and worktrees/.`；工作区嵌套时提示 `Workspaces can’t be nested.` 和冲突路径。候选是其他 Git 仓库的子目录、bare 仓库或 linked worktree 时说明需选择普通仓库根目录，禁用 Continue。可重新选择。

skill 状态显示 Ready / Installed / Unavailable，并说明从工作区根启动 Codex 才保证发现。点击 Continue 后才初始化/加载 Git、检查并补齐 `.gitignore`、创建标准目录和安装工作区 skill 链接；沿用原位进度，不增加 Git 设置页或提交按钮。成功后进入主窗口；没有首次提交不阻止进入，创建 Group 时再提示。资源异常按第 6.2 节呈现，不进入同步选择。

首次设置的 Quit、关闭窗口和 Cmd-W 退出应用；已有工作区选择使用 Cancel，取消保留原工作区。由阻断错误进入设置时取消回到原提示。初始化失败留在当前流程说明原因。

### 2.2 主窗口

使用 NavigationSplitView，标题栏居中显示工作区名或当前操作状态，不作为切换入口，不带 disclosure。更新仓库进行时，状态文本后显示原生取消图标按钮；按钮仅在仍可取消时可用，进入收尾阶段后禁用。主窗口常规参考为 1200×800，最小 900×600；侧栏默认宽 320px，可拖动，紧凑窗口为 240px。

- 左侧为 repositories 与 worktrees 两个分区；标题右侧管理按钮保持可见。
- 右侧从工具栏、摘要到 Changes/Commits。工具优先单行，空间不足使用原生 overflow 或自适应布局，不裁切按钮文字。
- Path 独占摘要首行，Base branch 与 Head branch 同一信息行；长路径中部截断并保留完整可访问值。
- 侧栏、Changes、Commits 使用原生滚动，遵循系统“显示滚动条”设置，不增加渐隐遮罩或强制 overlay indicator。

Changes/Commits 使用可调整的原生纵向分隔：仅一个可见时占剩余高度；两个可见时初始 60%/40%，各至少容纳标题和三行。用户拖动后不随内容数量反复跳动；空间不足时允许详情整体滚动。加载/失败区域仍可见，只有确认无内容才隐藏。

### 2.3 侧栏与菜单

repositories 标题右侧仅保留 Add 和更新按钮；更新复用原 Pull 图标，tooltip/可访问标签为 `Update Repositories` / `更新仓库`，触发 PRD 第 6 节的手动批量 Pull。worktrees 标题右侧为 Create Worktree Group。各入口按自身操作条件判断可用性；Base 缺失不单独禁用更新，主工作树 dirty 不单独禁用 Create。没有候选仓库时禁用相应入口；修改或切换期间禁用冲突操作，并保留按钮尺寸。更新期间仍可选择资源、浏览已有内容和打开外部工具，不整体禁用主窗口。

分区标题 32px，chevron 与 folder 在左；点击标题展开/折叠，右侧按钮不触发折叠。主仓库、Group 和成员行均为 28px，点击行主体选择；Group 的 chevron 独立展开/折叠，不改变当前选择。折叠 Group 时若其成员已选中，则将选择切换到该 Group，避免详情指向隐藏行。保留现有层级槽位：Group chevron 从 16px 开始，Group/成员 folder 对齐 38px，文字从 60px 开始；紧凑侧栏不改变层级。

工作树行尾固定槽位显示 dirty 圆点、Creating 或 Unavailable。dirty 圆点提供 `Working tree has changes` 的 tooltip/可访问值；Group 不聚合成员状态，也不增加根工作树的 dirty 展示，只表达根资源不可用。根 worktree 和记录保存成功后 Group 即可进入侧栏，零成员时仍可选择、编辑和删除。配置中的不可用资源仍可选择；失败且未保存的新增成员不留在列表。

| 实体 | 右键菜单与 Actions 菜单 |
| --- | --- |
| 主仓库 | Copy Path、Reveal in Finder、Delete Repository… |
| Group | Copy Path、Reveal in Finder、Edit Worktree Group…、Delete Worktree Group… |
| linked worktree | Copy Path、Reveal in Finder、Delete Linked Worktree… |

Actions 作用于聚焦/选择实体，目标不明确时禁用，保证键盘可达。Copy Path 复制安全校验后的绝对路径，目标不存在或越界时隐藏；Reveal 无法执行时禁用并说明原因。删除无单键快捷键；需确认的命令使用省略号。

File 菜单提供 Reload Workspace、Refresh Changes、Open Workspace in Codex。取消入口只出现在标题栏当前操作状态后，不重复放入菜单。工作区切换只在 Settings。无选择或选择 Group 时禁用 Refresh Changes；根目录 Codex 入口不随选择变化，不可用时禁用并说明原因。

### 2.4 Settings Window

独立 640×480 原生分组表单；入口为 `Modu → Settings…` 和 `⌘,`，再次打开聚焦已有窗口，`⌘W` 只关闭设置窗口。无侧栏、分页或 Save/Apply。

左右留白 32px，保留两组布局：

| 分组 | 控件与布局 |
| --- | --- |
| General | Language 原生 Pop-Up；一行 36px，组内上下 12px、左右 16px |
| Workspace | 64px 名称/路径行与 Change…；48px Configuration 行与 Import YAML…、Export YAML… |
| 页脚 | `Preferences are saved automatically.` |

语言为 English / 中文。设置中不提供自动抓取、自动更新或间隔控件，也不保留相应的禁用态与校验提示。

无工作区时显示 No workspace selected，Choose… 可用，导入/导出禁用。任务、切换和导入流程期间禁用冲突操作。路径中部截断，名称/路径区域弹性压缩，按钮文字保持完整。

Change/Choose 打开系统目录选择器，随后复用 Setup 的候选检查和 Continue。取消保留当前工作区；加载显示 Opening workspace…，成功后更新主窗口，失败说明原因。

**导入**：选择 YAML、校验、检查空工作区条件后直接进入创建进度，不显示覆盖确认。不满足空工作区条件时显示以下提示，只有 OK / 好，不引导用户删除现有内容：

| 语言 | 标题 | 正文（两段） |
| --- | --- | --- |
| English | Can’t import into this workspace | The workspace must have no registered repositories or worktree groups, and no content in its repositories or worktrees folders.<br><br>Choose another workspace in Settings, then try again. Your files and configuration have not been changed. |
| 中文 | 无法导入到当前工作区 | 工作区不能有已登记的仓库或工作树组，且 repositories 和 worktrees 文件夹中不能有任何内容。<br><br>请在设置中选择其他工作区后重试。现有文件和配置未作更改。 |

这里的文件夹可以不存在，根目录中的其他内容不影响判定；具体条件见 PRD 第 3.4 节。格式错误显示 `Configuration couldn’t be imported` 和原因，不进入工作区配置错误界面。

导入包含 Group 但目标工作区的首次提交或已提交忽略规则不满足条件时，在执行前列出需准备的规则，提示在外部工具提交后重试。导入进度 Sheet 附着于设置窗口，显示当前仓库、Group 根或成员、完成数量及 Cancel；失败或取消后按第 6.1 节说明已完成及未完成项，并指引通过 Add Repository / Create Worktree Group / Edit Worktree Group 补齐；结果提示不提供重新导入或续跑按钮。Export 使用系统保存面板，成功后返回设置窗口。导入/导出的帮助文案说明 YAML 用于重建仓库与分组结构，根和成员初始分支名使用分组名，不备份工作区仓库的文件和历史，不恢复外部切换后的分支状态；业务条件以 PRD 第 3.4 节为准。

键盘顺序为 Language → Change/Choose → Import → Export，跳过禁用控件；关闭面板/Sheet 后恢复触发控件焦点。

## 3. 详情与外部工具

### 3.1 未选择状态

右侧居中显示 `Let’s start`、以工作区根为目标的 Agent 分裂按钮，以及并排 Add Repository / Create Worktree Group。保留现有 44px、24px 纵向间距及 36px 管理按钮。

无 Agent 时隐藏该类按钮，无仓库时 Create 禁用；不展示 Git GUI、编辑器、终端、统计或营销说明。

### 3.2 已选择仓库或成员

依次显示可用的四类工具、摘要 Group Box、Changes Outline、Commits Table。主仓库与 linked worktree 使用同一骨架，不增加 Type/Status 计数。

摘要为相对 Path、只读 Base branch、Head branch；detached 显示 `Detached at <short-sha>`。Creating/Loading 不伪造空结果，Unavailable 保留路径并显示简短原因。Base 错误不影响可读取的 Changes 和可用工具。

### 3.3 已选择 Group

右侧仅在顶部显示 Agent、Git GUI、编辑器、终端四类分裂按钮，复用成员详情工具栏的尺寸、顺序、间距和左上对齐方式，全部以所选 Group 根目录为目标。Fork 打开工作区仓库的该根 worktree，不逐个打开成员。不显示路径摘要、Changes、Commits、统计或额外引导文案；目录路径通过 Group 行的 tooltip/可访问值和 Copy Path 获取。

Group 使用与成员一致的整行选中底色，切换到成员时恢复对应 Git 详情。Group 目录不可用时保留选择，在工具区显示简短原因并禁用启动；仅根 Git 状态异常时禁用 Fork，其他工具按目录可访问性判断。成员异常不禁用有效的 Group 目录。无已安装且适用的工具时隐藏工具栏。

### 3.4 分裂按钮

主区域显示默认工具图标和名称，点击直接打开；chevron 独立打开菜单，不同时启动。divider 固定在尾部命中区边界，压缩时不落入按钮间距。

菜单只列当前可用目标，不显示 check、默认 badge 或持久选中态。点击目标立即尝试打开，成功才更新默认；失败保留原默认并提示。关闭菜单恢复 chevron 焦点，启动不改变当前实体选择。全部工具不可用时隐藏工具栏。

## 4. 管理表单

### 4.1 Add Repository

Sheet 提示 `Enter the repository URL and an optional display name.`，仅有 Repository URL 与 Display Name 两个 36px 输入行，后者 placeholder 为 Optional；底部左侧增加次要按钮 `Import YAML…` / `导入 YAML…`，右侧保持 Cancel / Add。不增加派生目录、分支预览或默认分支输入框。

错误就近关联字段。提交后检查并补齐工作区 `.gitignore` 中的仓库名规则，原位显示 Checking repository… 与 clone 进度，提供 Cancel；声明保存成功后关闭并选中新仓库。忽略规则由用户提交；失败或取消后有保留的 `.gitignore` 修改时按第 6.1 节一并说明。不增加 Git 提交入口。

Import YAML 打开系统单文件选择器，仅选 `.yaml` / `.yml`，确认按钮为 Import / 导入；取消文件选择返回原表单并保留输入。选择文件后自动解析、去重并批量添加，不增加字段映射、仓库勾选或二次确认步骤。文件中的其他配置不影响当前表单输入，也不与手工 URL 合并提交；仓库提取与失败边界以 PRD 第 5.1.1 节为准。

解析和执行复用当前 Sheet 的进度布局：标题 `Importing repositories…` / `正在导入仓库…`，显示文件名、当前仓库和阶段、已处理/待处理数量，以及已添加、跳过、失败数量；尚未确定候选数量时显示解析中，不显示虚假进度。保留 Cancel 和 `Added repositories will be kept if you cancel.` / `取消后将保留已添加的仓库。`。不逐仓库弹窗；解析失败或没有合法 URL 时在原表单就近说明原因，保留重选入口。执行结束后按第 6.1 节一次汇总结果，区分已添加、已存在/重复、失败与未处理；全部已存在时说明没有新增仓库，不显示导入成功。结果关闭后，有新增项则选中最后一个成功添加的仓库，否则保留原选择。

### 4.2 Create Worktree Group

正文仅保留 Group Name、Repositories 标题与 `<selected> / <total> selected`、28px checkbox 列表、Cancel / Create，不增加常驻提示文本。最多完整显示 7 行，更多使用原生滚动；每行仅 checkbox 与仓库展示名，不重复展示派生路径/分支。根 worktree 是固定创建项，不作为可取消勾选的仓库行。

名称原样校验，不自动 slug 化；无仓库勾选时仅禁用 Create。创建使用本地已有的 Git 引用，不隐式联网或更新已有工作树；根分支不存在时从工作区当前 HEAD 创建。检查不到首次提交或所需的已提交忽略规则时，在原 Sheet 显示 `Commit the workspace .gitignore before creating this group.` / `请先提交工作区的 .gitignore，再创建此分组。`，附缺失规则或首次提交原因；保持表单，用户在外部处理后可重试。成员起点不可用时提示先更新主仓库，无法更新则在外部工具处理，不增加分支选择或提交入口。

通过预检后在原 Sheet 先显示 `Creating workspace worktree…` / `正在创建工作区工作树…`，再逐成员显示 Creating / Saving / Created。进度分别说明根 worktree 是否已创建和 `<completed> of <total> members created`，不把根计入成员数量；保存成功的根与成员才进入侧栏。取消提示 `Created worktrees will be kept if you cancel.` / `取消后将保留已创建的工作树。`。全部成功后关闭、展开并选中 Group，进入仅含工具按钮的详情；部分完成按真实列表反馈，包括根已创建但尚无成员的情况。

### 4.3 Edit Worktree Group

复用创建 Sheet；Group Name 只读但可复制，勾选表示完整目标成员集合；新增成员使用分组名作为初始分支名，已有成员保持当前 checkout。列表增加 Working Tree：Clean、Dirty、Other、Unset；Other 说明已登记成员的缺失或读取错误，Unset 仅表示仓库尚未加入当前 Group，不代表复选框状态。未改变的异常成员不阻止保存其他成员变更。排序不随勾选或状态改变。

仅无变更时禁用 Save Changes；允许取消全部勾选，移除确认说明 `The group workspace worktree will be kept.` / `将保留分组根工作树。`。纯新增直接提交；包含移除时，第一次点击在同一 Sheet 展示删除范围、风险与待删除的当前本地分支（或不删除分支的原因），destructive Save Changes 确认一次后执行，返回编辑保留勾选。

执行进度保留在 Sheet。再次打开 Edit 使用当前已保存成员，不呈现历史待续跑目标；新增、移除的顺序及失败边界以 PRD 第 7 节为准。

### 4.4 通用规则

输入校验就近呈现，跨目标错误在 Sheet 或结果提示说明。执行中禁用重复提交并提供 Cancel；取消显示 Cancelling…，保存/必要清理期间暂时禁用取消，使用 Saving… / Cleaning up…。

取消表示停止后续工作，不暗示撤销全部结果。关闭 Sheet 恢复触发点焦点；成功创建和删除按实体位置调整焦点。

## 5. Git Browser

### 5.1 Changes

使用 28px Outline 保留目录层级，每路径一行；标题提供 Staged / Unstaged 两列，文件名前有两个固定状态槽位。无变化侧使用中性短横线，两侧都有变化同时展示。

Added、Moved、Modified、Deleted 使用现有状态图标；untracked 在 Unstaged 槽位使用 Added 图形加 `?` 并明确 Untracked，Conflict/Unknown 显示原始语义，不伪装 Modified。Moved 显示新路径，旧路径保留于 tooltip 和可访问值。

路径、两阶段状态和冲突原因均有完整可访问表达；Reveal 只对存在且可安全定位的路径可用。状态图标保留“状态色容器 + 白色字形”，Moved 浅色基准为 `#B262ED`，深色/高对比度适配。

确认无变更才隐藏区域；读取失败显示 Unavailable，保留其他可用内容。范围和 dirty 语义仅由 PRD 第 10 节定义。

### 5.2 Commits

标题只显示 Commits，不显示计数或分支 badge。每条 28px，列依次为提交信息、提交人、时间、短哈希；紧凑窗口列间距 12px，后三列参考宽度 84/160/60px，提交信息获得剩余宽度。长内容截断，完整值通过 tooltip/无障碍读取。

首次最多加载 30 条，更多使用 Load More，每次最多追加 30 条；空时隐藏，范围不可读时显示原因。merge/rebase 期间只要范围可读就展示，不因操作进行中一概禁用。不增加文件树或逐行 diff。

### 5.3 选择与刷新

加载保持结构稳定，不闪现其他节点的数据。选择、App 激活、操作完成及 Refresh Changes 刷新本地状态；Refresh Changes 不联网、不 Pull 或创建资源。摘要、Changes、Commits 各自可加载或失败，不互相清空。

## 6. 反馈与异常

### 6.1 操作进度与结果

Add/Create/Edit/Delete 的进度在原 Sheet；从 YAML 批量添加仓库的进度保留在 Add Repository Sheet，完整工作区 YAML 导入的进度 Sheet 附着于 Settings 窗口。更新仓库时，主窗口标题栏暂时显示原生 spinner、`Updating repositories` / `正在更新仓库` 和尾部取消图标，替代工作区名称；按仓库顺序执行并汇总，完成或失败后恢复工作区名称。点击取消后显示 `Cancelling…` / `正在取消…`，停止后续仓库、终止当前任务并等待收尾；进入不可取消的收尾阶段后按钮禁用。取消按钮提供 `Cancel Update` / `取消更新` 的可访问标签和 tooltip，不增加 File 菜单命令。

全部成功短暂显示完成反馈；所有仓库均已是最新时显示 `Already up to date` / `已是最新`。更新结果逐项区分已更新、已是最新、跳过和失败，全部跳过显示 `No repositories were updated` / `没有仓库被更新` 并列出原因，不显示成功反馈。失败、跳过、部分完成或有保留效果的取消使用一次结果 Alert：目标 → 原因 → 已完成/未完成 → 必要清理结果，只有 OK。多项结果过长时复用可滚动原生 Sheet，保持相同信息顺序，不建立任务中心。

网络错误说明具体步骤与时限，删除失败明确内容是否已删除、声明是否仍在、分支/Trash 的实际位置；不用 Rolled back 暗示整体恢复。初始化或添加失败后保留的 Git 初始化、`.gitignore` 修改，以及创建失败后保留的 Group 根也属于需要说明的效果。无保留效果且清理成功的取消可静默。

少量更新结果沿用紧凑纵向 Alert，原型参考宽度 260px：左对齐图标与文案、底部等宽 OK，高度随正文增长；仓库与状态加粗，原因和已完成效果分段展示。

结果反馈结束后刷新真实状态，不立即弹出另一个修复流程。

### 6.2 工作区和资源错误

| 状态 | 界面与可用动作 |
| --- | --- |
| 根不存在 | 原生阻断 Alert：Workspace not found，显示完整根路径，Quit / Set Up Workspace |
| 当前配置不可用 | Workspace data couldn’t be loaded，显示实际文件与原因，Reload / Set Up Workspace / Quit |
| 某些资源不可用 | 侧栏状态槽位及详情显示 Unavailable 与具体原因，可用资源仍能浏览；无需每次激活弹窗 |

阻断状态遮蔽旧列表。Set Up Workspace 只进入正常选择流程，取消返回原提示，不承诺修复当前记录。锁忙暂缓刷新，不进入配置错误。

显式 Reload 或 inspect 的资源结果可复用原生汇总 Sheet：标题 `Some resources are unavailable`，列出目标、路径和原因，说明 `Resolve these issues outside Modu, then reload the workspace.`，只有 OK。主仓库缺失的成员标记 Repository unavailable，不伪报分支丢失；不提供同步方向或自动修复按钮。

### 6.3 删除确认

仓库删除先按 PRD 第 5.2 节检查 Git worktree 登记。存在配置外登记时不进入删除确认，复用原生结果 Alert：标题 `Can’t delete repository` / `无法删除仓库`，列出可复制的登记路径，并说明 `This repository is still used by worktrees outside Modu’s configuration. Resolve these worktrees and their Git registrations outside Modu, then try again. No resources or configuration have been changed.` / `此仓库仍被 Modu 配置外的工作树使用。请在外部处理这些工作树及其 Git 登记后重试。本次未删除任何资源，也未修改配置。`。只有 OK / 好，不提供继续删除；多项内容沿用第 6.1 节的可滚动 Sheet。登记读取失败显示具体原因，不伪报无外部依赖；确认后的执行前检查发现阻断时使用同一反馈。

复用现有紧凑 Sheet/Alert，列出目标路径、Working Tree、待删除的当前本地分支，以及可读取的 ignored、仅本地提交、detached 风险。detached HEAD 显示 `Detached HEAD — no branch to delete` / `分离 HEAD，无本地分支可删除`；worktree 目录与 Git 登记均缺失时说明只移除成员声明，不删除分支。多资源列表超过 7 行滚动，长内容可展开或查看完整值。

| 删除对象 | 确认内容 |
| --- | --- |
| Linked Worktree | 目标路径、待删除的当前本地分支（或不删除分支的原因）、状态和风险 |
| Group | 根 worktree 及所有配置成员，各自的路径、当前分支、状态和风险；成员先删除，根最后删除 |
| Repository | 预检通过后显示主路径、配置内关联成员，主目录 Move to Trash |

明确 worktree 内容及当前本地分支会永久删除，不区分新建或复用分支；主目录移入 Trash，远端不删除。Group 确认正文为 `The group workspace worktree, its members, and their current local branches will be permanently deleted.` / `将永久删除分组根工作树、成员工作树及它们当前的本地分支。`。根作为独立目标行展示，不只是路径标题；零成员 Group 仍展示根目标。单成员和仓库删除后即使没有剩余成员，也保留 Group 根。Cancel 为安全默认，destructive Delete 需明确激活，不追加第二次确认。确认后执行前发现当前分支或 detached 状态变化时停止，说明尚未开始删除，用户重新发起时展示最新目标。

成功后选择相邻可见节点，无节点则回未选择状态。失败按第 6.1 节说明实际效果，列表使用已保存结果，不恢复已删除成员或提供专用续删入口。

## 7. 无障碍与系统适配

核心流程支持键盘和 VoiceOver：分区与 Group 使用 Left/Right 展开折叠，Group 行的选择与展开状态分别表达，Return 选择聚焦的资源；菜单和 Sheet 关闭恢复焦点，状态变化使用 announcement，不无故抢焦点。图标按钮提供 label/tooltip，完整路径和状态不只通过 hover 获得。

支持浅色、深色、提高对比度和减少透明度；非文本状态图形至少 3:1，正文与小字号数字至少 4.5:1。滚动条遵循系统偏好，较大字号或长内容时仍可到达所有操作和信息。

## 8. 原型索引与适用范围

保留现有核心窗口、表单与 Git Browser 的设计方向。原型代表特定状态，不模拟真实 Git/文件副作用；实现以本文和 PRD 为准。窗口阴影属于导出边界，PNG 像素尺寸不等于窗口逻辑尺寸。

| 编号 | 原型 | 当前用途 |
| --- | --- | --- |
| 01 | [Onboarding — CLI](../design/prototypes/01-onboarding-1.png) | CLI 必须安装并检查通过，才能选择工作区和继续 |
| 02 | [Onboarding — Choose Workspace](../design/prototypes/02-onboarding-2.png) | 工作区选择布局 |
| 03 | [Onboarding — Continue](../design/prototypes/03-onboarding-3.png) | 候选检查与 Continue；步骤提示与前两步一致 |
| 04 | [Workspace Data Error](../design/prototypes/04-workspace-data-error.png) | 私有记录错误与退出路径 |
| 05 | [Unselected State](../design/prototypes/05-unselected-state.png) | 根 Agent 与管理入口 |
| 06 | [Add Repository](../design/prototypes/06-add-repository.png) | 两字段添加表单与 Import YAML 入口 |
| 07 | [Delete Repository](../design/prototypes/07-delete-repository.png) | 预检通过后的仓库删除确认布局；阻断提示复用原生 Alert |
| 08 | [Create Group](../design/prototypes/08-create-worktree-group.png) | Group 创建表单 |
| 09 | [Edit Group](../design/prototypes/09-edit-worktree-group.png) | 目标成员与 Working Tree；移除确认按当前分支展示 |
| 10 | [Delete Group](../design/prototypes/10-delete-worktree-group.png) | 根 worktree 与成员的删除确认；分支目标以各自实际 HEAD 为准 |
| 11 | [Delete Linked Worktree](../design/prototypes/11-delete-linked-worktree.png) | 单成员删除确认布局；分支目标以实际 HEAD 为准 |
| 12 | [Repository Selected](../design/prototypes/12-repository-selected.png) | 主仓库详情布局 |
| 13 | [Update Running](../design/prototypes/13-update-running.png) | 更新进度与取消；复用标题栏布局 |
| 14 | [Update Result Issues](../design/prototypes/14-update-result-issues.png) | 更新结果汇总，展示失败/跳过原因与已完成效果 |
| 15 | [Worktree Group Selected](../design/prototypes/15-worktree-group-selected.png) | Group 选中态，右侧仅含 Agent、Fork、编辑器、终端分裂按钮 |
| 16 | [Linked Worktree Selected](../design/prototypes/16-linked-worktree-selected.png) | 成员详情布局 |
| 17 | [Context Menu](../design/prototypes/17-linked-worktree-context-menu.png) | 原生上下文菜单 |
| 18 | [Split Menu](../design/prototypes/18-split-menu-open.png) | 工具分裂按钮 |
| 19 | [Small Window](../design/prototypes/19-small-window-linked-worktree-selected.png) | 900×600 密度参考 |
| 20 | [Settings — General](../design/prototypes/20-settings-general.png) | 语言与工作区设置 |
| 21 | [Settings — No Workspace](../design/prototypes/21-settings-no-workspace.png) | 无工作区设置态，General 仅保留语言 |
| 22 | [Import Unavailable](../design/prototypes/22-settings-import-requires-empty-workspace.png) | 空工作区条件提示 |
| 23 | [Workspace Not Found](../design/prototypes/23-workspace-not-found.png) | 根缺失阻断 |
| 24 | [Resources Unavailable](../design/prototypes/24-workspace-resources-unavailable.png) | 只读异常汇总，无同步按钮 |
| 25 | [Group Creation Progress](../design/prototypes/25-group-creation-progress.png) | 根 worktree 已创建、正在创建成员的进度及取消，复用同一 Sheet |
| 26 | [Repository YAML Import Progress](../design/prototypes/26-repository-yaml-import-progress.png) | 从 YAML 批量添加仓库的进度与取消 |

CLI/skill 安装状态、删除风险和 Git 两阶段状态按本文实现；19 的固定卡片高度、渐隐与强制 overlay 滚动条不作为验收要求。

原型的更新入口进入 13，示例运行 3 秒后进入 14，取消和 OK 返回 12；该跳转不代表真实更新耗时或取消保证。Group 行的图标/名称进入 15，选择成员返回 16；创建入口进入 25，真实创建完成后选中新 Group。06 的 Import YAML 进入 26，仅演示选定文件后的批量添加进度，真实文件选择使用系统面板。Settings 的非空导入提示为 22，24 仅作为显式资源检查结果。真实创建、取消、部分完成、工具启动和系统面板由实现承接，不以静态跳转替代验收。
