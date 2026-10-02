# Modu Design Specification

- 日期：2026-09-30
- 状态：v0.1 核心工作流设计
- Figma：[Modu 设计稿](https://www.figma.com/design/eK0CqTm1y4jk6thzqBdUV5/Modu-Desktop?node-id=16-6)

## 0. 文档职责

本文定义窗口、布局、交互、文案、无障碍和原型索引。业务、数据、授权及失败处理以 [PRD.md](PRD.md) 为准，不在界面另建规则。

保留现有原生桌面布局和核心表单；资源异常使用 Unavailable 和明确原因，取消双向同步选择与覆盖导入确认。状态优先级为：**工作区根/配置错误 → 操作与收尾 → 当前选择加载 → 局部错误 → 内容/空状态**。局部读取失败不遮蔽其他可用区域。

## 1. 设计基础

### 1.1 原生方向与字体

- 优先使用 macOS 26 的 SwiftUI/AppKit Window、Sheet、Alert、Menu、Toolbar、NavigationSplitView、Outline/Table 和 SF Symbols，保持紧凑，不增加仪表盘或装饰性卡片。
- 原型普通文字使用 SF Pro，路径、分支、哈希使用 Roboto Mono；实现使用系统语义字体和系统 monospaced font。
- 界面以 Figma 的布局、尺寸、间距、字体层级、颜色和导出图标为视觉基准，目标还原率至少 95%；以同尺寸原生窗口截图复核。系统窗口阴影、动态数据和系统字体抗锯齿单独说明，不用静态截图替代真实控件与行为。
- 自定义 hover 渐变用于所有工具分裂按钮、开始页的 Add Repository / Create Worktree Group，以及图标操作按钮；背景从上到下为 `#E1E3E5` → `#F1F2F2`，移出恢复原背景，禁用时不显示高亮。渐变上使用深色文字与图标，保证浅色、深色模式下可读。其他按钮使用原生样式与交互状态，不在页面或 Sheet 外层统一覆盖；原生菜单和侧栏导航行沿用各自的高亮与选中规则。
- 管理表单、进度和结果 Sheet 使用 460pt 共用宽度与系统 body/headline，保持同一任务的横向布局与标题层级稳定；内容高度按任务适配，长列表与长错误在正文区域滚动，不挤走底部操作。

### 1.2 密度、图标与排序

| 行高基线 | 用途 |
| --- | --- |
| 28px | 侧栏节点、仓库选择、单行删除列表、Changes/Commits |
| 32px | 分区标题、摘要行 |
| 36px | 表单输入行和管理按钮 |

长内容使用截断、tooltip、可访问值和原生滚动，不因状态切换反复改变行高。较大字号下以内容可达为先。

仓库/linked worktree 使用橙色仓库或文件夹图标，分区/Group 使用蓝色 folder；状态使用系统语义色，不能只靠颜色。Git 文件状态复用现有 vector assets；应用图标使用 [AppIcon.icon](../ModuDesktop/AppIcon.icon)，说明见 [图标文档](../design/app-icon/README.md)。

文件系统实体按同级可见名称做 Finder 风格自然升序，忽略大小写，数字按数值比较；同名以完整相对路径稳定排序。Changes 同级节点先目录后文件，目录和文件各自遵循上述自然排序，根目录文件显示在目录树下方。Group 和 Changes 保留层级，不按 dirty、勾选或结果类型重排。选择与焦点绑定实体，不绑定行号。

## 2. 窗口与导航

应用菜单、Dock、关于窗口和应用包统一使用 **Modu**（`Modu.app`）。Window 菜单的主窗口入口为 Modu；主窗口标题显示当前工作区名，无工作区时显示 Modu。辅助窗口使用各自的用途名称。

### 2.1 Setup Window

窗口名称为 `Set Up Workspace` / `设置工作区`，由首次启动、启动检查失败、工作区恢复入口或 Window 菜单中的 `Modu Setup` / `Modu 设置` 打开；不在重启时自动恢复该窗口。已有工作区时 Cancel 保留当前工作区并返回主窗口；操作进行中禁用菜单入口。

主窗口每次启动重新打开，不恢复上次关闭状态，以确保启动检查执行。启动时静默检查 CLI；可用时直接打开已保存工作区，不显示成功提示。CLI 缺失或不可用时自动打开此引导窗口并关闭主窗口，不额外弹 Alert；保留工作区路径及记录，具体原因沿用 CLI 步骤的说明。

独立 720×520 原生窗口：CLI 检查 → 选择候选工作区 → Continue。CLI 必须通过 PRD 第 4.1 节的安装与可用性检查后才显示 Installed；未通过时禁用 Choose Workspace 和 Continue。安装、PATH 或运行检查失败均在原步骤说明原因；PATH 提示明确指出将 `~/.local/bin` 加入登录 shell 的 PATH，用户处理后可重试或退出，不提供跳过入口。已有 skill 冲突说明原因并允许 Continue Without Skill。

三个引导状态只保留 Install modu-cli 与 Choose Workspace 步骤标题，不重复解释按钮用途；选择后的路径和状态在右侧展示。Git 初始化与忽略规则检查沿用第 2.1 节的 Continue 流程。有有效历史记录时直接加载；无记录时要求标准资源目录为空或不存在，否则提示 `Choose a folder with empty repositories/ and worktrees/.`，不扫描恢复清单、不清空目录。满足条件的普通非 Git 目录确认打开后自动执行 `git init`，不要求额外确认。工作区嵌套时提示 `Workspaces can’t be nested.` 和冲突路径。候选是其他 Git 仓库的子目录、bare 仓库或 linked worktree 时说明需选择普通仓库根目录，禁用 Continue。可重新选择。

skill 仅在不可用时显示状态与原因，不显示 Ready 成功说明；从工作区根启动 Codex 的说明放在 Open Workspace in Codex 的帮助和无障碍提示中。点击 Continue 后才初始化/加载 Git、检查并补齐 `.gitignore`、创建标准目录和复制工作区 skill 文件，再自动提交变化的 `.gitignore` 与已成功安装的 skill；初始化期间在 Continue 按钮内显示小型 spinner 与 `Setting up…` / `正在设置…`，保持按钮尺寸并禁用重复触发，不再显示独立的初始化 spinner。失败后恢复 Continue 或 Continue Without Skill，允许重试；自动提交失败说明实际保留的变化和 Git 原因。不增加 Git 设置页或提交按钮。成功后进入主窗口。资源异常按第 6.2 节呈现，不进入同步选择。

首次设置的 Quit、关闭窗口和 Cmd-W 退出应用；已有工作区选择使用 Cancel，取消保留原工作区。由阻断错误进入设置时取消回到原提示。初始化失败留在当前流程说明原因。

### 2.2 主窗口

使用原生分隔视图，避免系统浮动侧栏附加边距偏离 Figma；标题栏居中显示工作区名或当前操作状态，不作为切换入口，不带 disclosure。更新仓库进行时，状态文本后显示第 6.1 节定义的取消图标按钮；按钮仅在仍可取消时可用，进入收尾阶段后禁用。主窗口常规参考为 1200×800，最小 900×600；侧栏默认宽 338px，可拖动，紧凑窗口为 240px。

- 左侧为 repositories 与 worktrees 两个分区；标题右侧管理按钮保持可见。
- 右侧从工具栏、摘要到 Changes/Commits。工具优先单行，空间不足使用原生 overflow 或自适应布局，不裁切按钮文字。
- Path 独占摘要首行，Base branch 与 Head branch 同一信息行；长路径中部截断并保留完整可访问值。
- 侧栏、Changes、Commits 使用原生滚动，遵循系统“显示滚动条”设置，不增加渐隐遮罩或强制 overlay indicator。

Changes/Commits 使用可调整的原生纵向分隔，命中区为两区域之间的 12px 间距：仅一个可见时可使用剩余高度；两个可见时初始为 Commits 保留标题和三行的 136px，Changes 区域可使用剩余高度，各至少容纳标题和三行。Changes 卡片顶部对齐，高度由标题、内边距和当前展开的目录/文件行撑开，不拉伸卡片填满空白；内容超出可用区域时在卡片内原生滚动，展开/折叠后同步调整卡片高度。用户拖动后分隔位置不随内容数量反复跳动；空间不足时允许详情整体滚动。两个区域首次读取时不显示空标题、卡片或分隔，具体规则见第 5.1、5.2 节。

### 2.3 侧栏与菜单

repositories 标题右侧依次为更新、Add，Add 位于最右侧；更新使用 Figma `Icon/Action/Fetch` 的 16×16 顺时针刷新图标，置于 24×24 按钮区域，tooltip/可访问标签为 `Update Repositories` / `更新仓库`，触发 PRD 第 6 节的手动批量 Pull。worktrees 标题右侧为 Create Worktree Group。各入口按自身操作条件判断可用性；单个 Base 缺失不禁用整个批量更新入口，主工作树 dirty 不单独禁用 Create。没有候选仓库时禁用相应入口；修改或切换期间禁用冲突操作，并保留按钮尺寸。更新期间仍可选择资源、浏览已有内容和打开外部工具，不整体禁用主窗口。

更新、Add 与 Create Worktree Group 图标按钮 hover 时，在各自 24×24 区域内显示第 1.1 节的圆形渐变背景。

分区标题 32px，chevron 与 folder 在左；点击标题展开/折叠，右侧按钮不触发折叠。主仓库、Group 和成员行均为 28px，相邻资源行之间保持 1px 间距，保证 hover 与 active 背景分开；点击行主体选择。点击未选中的 Group 行主体时选中并展开，已展开则保持展开；再次点击已选中的 Group 行主体才切换展开/折叠。Group 的 chevron 独立展开/折叠，不改变当前选择；折叠时若其成员已选中，则将选择切换到该 Group，避免详情指向隐藏行。主仓库、Group 和成员行 active（选中）或 hover 时，整行使用 `#EEEEEF` 背景，沿用 6px 圆角；移出未选中行恢复透明，选中行持续保留底色。浅色、深色模式下高亮行均使用深色文字与模板图标。侧栏按钮按下、松开时文字与图标颜色保持稳定，不叠加默认按压变淡效果。保留现有层级槽位：Group chevron 从 16px 开始，Group/成员 folder 对齐 38px，文字从 60px 开始；紧凑侧栏不改变层级。

repositories、worktrees 分区和 Group 展开/折叠使用 160ms easeInOut 动画：chevron 旋转 90°，子列表整体淡入/淡出，下方内容平滑让位。行高、文字大小和选中底色不参与过渡；连续点击直接反向过渡，不等待上一段动画结束。系统开启“减少动态效果”时立即切换。

展开/折叠状态按工作区保存，重新打开或切回时使用历史偏好；新工作区默认展开 repositories、worktrees，折叠各 Group。切换后返回工作区起始页，不清除其他工作区历史；重新打开旧工作区时按 PRD 第 4.1 节直接加载有效清单，不从磁盘扫描恢复仓库和 Group。

点击侧栏空白区域取消当前仓库或 Group 选择，回到以工作区根为目标的开始页；分区展开状态保持不变。点击资源行、分区标题或管理按钮只执行各自操作，不触发空白区域行为。

工作树行尾固定槽位显示 dirty 圆点、Creating 或 Unavailable。dirty 圆点提供 `Working tree has changes` 的 tooltip/可访问值；Group 只显示根工作树自身的 dirty 或不可用状态，不聚合成员状态。根 worktree 和记录保存成功后 Group 即可进入侧栏，零成员时仍可选择、编辑和删除。目录已缺失的资源在加载或刷新时从配置和侧栏移除；被移除的当前选择返回工作区起始页，并清除对应状态和详情缓存。目录尚存但不可用的配置资源仍可选择；失败且未保存的新增成员不留在列表。

| 实体 | 右键菜单与 Actions 菜单 |
| --- | --- |
| 主仓库 | Copy Path、Reveal in Finder、Delete Repository… |
| Group | Copy Path、Reveal in Finder、Edit Worktree Group…、Delete Worktree Group… |
| linked worktree | Copy Path、Reveal in Finder、Delete Linked Worktree… |

Actions 作用于聚焦/选择实体，目标不明确时禁用，保证键盘可达。Copy Path 复制安全校验后的绝对路径，目标不存在或越界时隐藏；Reveal 无法执行时禁用并说明原因。删除无单键快捷键；需确认的命令使用省略号。

File 菜单提供 Reload Workspace、Refresh Changes、Open Workspace in Codex。取消入口只出现在标题栏当前操作状态后，不重复放入菜单。工作区切换只在 Settings。无选择时禁用 Refresh Changes，Group 与成员均可刷新；根目录 Codex 入口不随选择变化，不可用时禁用并说明原因。

Reload Workspace、App 激活和操作完成后的隐式 Reload 均先执行与启动相同的根检查和初始化，补齐缺失的 Git、标准目录、skill 和 `.gitignore`，只提交有变化的文件，再刷新资源。初始化期间保留现有内容并禁用冲突操作，标题栏显示 Reloading workspace / 正在重新加载工作区，允许取消可中断步骤；成功不弹提示，保留仍有效的资源选择，已删除的选择返回工作区起始页。操作后的 Reload 保留完成提示与结果，继续按已保存结果选中新资源，不恢复已经关闭的管理 Sheet。失败按第 6.1、6.2 节显示原因及实际保留的效果。根目录或当前记录缺失、记录损坏时保持阻断。

### 2.4 Settings Window

独立 640×480 原生分组表单；入口为 `Modu → Settings…` 和 `⌘,`，再次打开聚焦已有窗口，`⌘W` 只关闭设置窗口。无侧栏、分页或 Save/Apply。

左右留白 32px，保留两组布局：

| 分组 | 控件与布局 |
| --- | --- |
| General | Language 原生 Pop-Up；一行 36px，组内上下 12px、左右 16px |
| Workspace | 64px 名称/路径行与 Change…；48px Configuration 行与 Import YAML…、Export YAML… |

语言为 English / 中文，修改立即保存，不显示自动保存页脚。设置中不提供自动抓取、自动更新或间隔控件，也不保留相应的禁用态与校验提示。

无工作区时显示 No workspace selected，Choose… 可用，导入/导出禁用。任务、切换和导入流程期间禁用冲突操作。路径中部截断，名称/路径区域弹性压缩，按钮文字保持完整。

Change/Choose 直接打开系统目录选择器，初始定位当前工作区，确认按钮为 Open / 打开。有有效历史记录时直接加载；无记录时只为标准资源目录为空或不存在的目录初始化，非空则说明原因并拒绝，不扫描恢复仓库和 Group。不打开 Setup、不再要求 Continue 或创建确认。选择当前目录不执行操作，取消保留原工作区。

切换期间保持旧名称、路径和主窗口内容，禁用冲突操作；超过 300ms 才在 Change 按钮旁显示小型 spinner 与 Opening workspace… / 正在打开工作区…，快速完成不闪现 loading，VoiceOver 保留忙状态说明。目标加载成功后一起更新名称、路径和主窗口，清除资源选择进入开始页，保持设置窗口焦点，不弹成功提示。失败在设置窗口展示目标路径、具体原因及实际保留效果，提供 Choose Another… / 重新选择… 与 Cancel / 取消，原工作区和选择保持不变。工作流 skill 安装失败在设置页显示一次可关闭说明，不阻止成功切换，也不覆盖已有文件。

**导入**：选择 YAML、校验、检查空工作区条件后直接进入创建进度，不显示覆盖确认。不满足空工作区条件时显示以下提示，只有 OK / 好，不引导用户删除现有内容：

| 语言 | 标题 | 正文（两段） |
| --- | --- | --- |
| English | Can’t import into this workspace | The workspace must have no registered repositories or worktree groups, and no content in its repositories or worktrees folders.<br><br>Choose another workspace in Settings, then try again. Your files and configuration have not been changed. |
| 中文 | 无法导入到当前工作区 | 工作区不能有已登记的仓库或工作树组，且 repositories 和 worktrees 文件夹中不能有任何内容。<br><br>请在设置中选择其他工作区后重试。现有文件和配置未作更改。 |

这里的文件夹可以不存在，根目录中的其他内容不影响判定；具体条件见 PRD 第 3.4 节。格式错误在设置窗口的结果 Sheet 显示 `Workspace import · Failed` / `导入工作区 · 失败` 和原因，不进入工作区配置错误界面。

导入先克隆并保存仓库，再自动提交变化的 `.gitignore`，最后检查并创建 Group；提交失败保留仓库并显示 Git 原因，不开始创建 Group。导入进度 Sheet 附着于设置窗口，保留所选文件名，显示当前仓库、Group 根或成员、完成数量及 Cancel；自动提交沿用不可取消的 Saving… / 正在保存… 阶段；全部成功自动关闭，不再要求确认。失败、跳过或取消后有保留效果时按第 6.1 节展示结果，并指引通过 Add Repository / Create Worktree Group / Edit Worktree Group 补齐；结果提示不提供重新导入或续跑按钮。Export 使用系统保存面板，成功后返回设置窗口。文件读取或导出错误在设置窗口使用原生 Alert，标题分别为 `Can’t read configuration file` / `无法读取配置文件`、`Can’t export configuration` / `无法导出配置`，不转交主窗口的通用提示。导入/导出的帮助文案为 `Only saves repository and group structure, not files, history, or current branch state.` / `仅保存仓库与分组结构，不备份文件、历史或当前分支状态。`；业务条件以 PRD 第 3.4 节为准。

键盘顺序为 Language → Change/Choose → Import → Export，跳过禁用控件；关闭面板/Sheet 后恢复触发控件焦点。

## 3. 详情与外部工具

### 3.1 未选择状态

右侧居中显示 `Let’s start`、以工作区根为目标的 Agent 分裂按钮，以及并排 Add Repository / Create Worktree Group。标题为 26px，纵向间距 24px，工具按钮高 44px、管理按钮高 36px。

无 Agent 时隐藏该类按钮，无仓库时 Create 禁用；不展示 Git GUI、编辑器、终端、统计或营销说明。

### 3.2 已选择仓库或成员

依次显示可用的四类工具、摘要 Group Box、Changes Outline、Commits Table。主仓库与 linked worktree 使用同一骨架，不增加 Type/Status 计数。

摘要为相对 Path、只读 Base branch、Head branch；未配置任何 remote 时隐藏 Base branch 及其分隔线，并隐藏 Commits。detached 显示 `Detached at <short-sha>`。Creating/Loading 不伪造空结果，Unavailable 保留路径并显示简短原因。已配置 remote 时的 Base 错误不影响可读取的 Changes 和可用工具。

### 3.3 已选择 Group

右侧复用成员详情骨架：顶部显示 Agent、Git GUI、编辑器、终端四类分裂按钮，下方显示路径、Base branch、Head branch 摘要、Changes 和 Commits，全部以所选 Group 根工作树为目标。Fork 打开工作区仓库的该根 worktree，不逐个打开成员。Changes 与 Commits 仅展示根仓库内容，不聚合成员；空区域隐藏，未配置任何 remote 时隐藏 Base branch 及其分隔线和 Commits，已配置 remote 但缺少本地 origin/HEAD 时按成员详情的不可用规则展示 Base 与 Commits，HEAD 和 Changes 仍可读取。

Group 使用与成员一致的整行选中底色，切换到成员时恢复对应 Git 详情。Group 目录不可用时保留选择，在 Git 详情区域显示简短原因并禁用启动；仅根 Git 状态异常时禁用 Fork，其他工具按目录可访问性判断。成员异常不禁用有效的 Group 目录。无已安装且适用的工具时隐藏工具栏。

### 3.4 分裂按钮

主区域显示默认工具图标和名称，点击直接打开；chevron 独立打开菜单，不同时启动。divider 固定在尾部命中区边界，压缩时不落入按钮间距。

开始页、仓库、Group 和成员详情中的所有工具分裂按钮左右侧分别响应 hover，仅当前侧显示第 1.1 节的渐变背景；渐变止于 divider，外边缘沿按钮整体圆角裁切，不同时高亮另一侧。

工具检测完成即显示或更新按钮，不等待工作区的 Git 状态检查完成。

工具按钮常规宽 180px、高 44px，紧凑窗口宽 140px；按钮间距 16px，图标 24px，菜单命中区宽 26px。详情外边距 24px，工具到摘要间距 16px，摘要与 Git 区域间距 12px；区域使用 8px 圆角和 1px 细边框。

展开菜单与整个分裂按钮等宽、左对齐，菜单外边缘距按钮底部 4px（不含菜单内部留白和投影）。菜单项高 38px，24px 工具图标与 13px 常规字重名称间距 8px；图标距菜单左侧 16px，高亮区域左右缩进 6px。菜单使用原生 `NSMenu`，背景材质（Liquid Glass）、圆角、边框、上下留白与投影由 macOS 管理，与侧栏右键菜单保持一致；菜单项保持透明，不覆盖不透明白底，不额外绘制阴影。悬停或键盘导航时仅高亮当前行；方向键、Return、Escape、点击外部关闭及屏幕边缘避让由原生菜单处理。

菜单只列当前可用目标，不显示 check、默认 badge 或持久选中态。Claude Code 仅在 Claude 桌面应用已安装时显示，点击进入桌面 Code 会话并传入当前目录，由 Claude 确认目录。点击目标立即尝试打开，成功后立即更新按钮图标、名称和默认，无需切换资源；失败保留原默认并提示。关闭菜单恢复 chevron 焦点，启动不改变当前实体选择。全部工具不可用时隐藏工具栏。

## 4. 管理表单

### 4.1 Add Repository

Sheet 标题下仅有 Repository URL 与 Display Name 两个 36px 输入行，不重复解释字段；后者 placeholder 为 Optional。底部左侧增加次要按钮 `Import YAML…` / `导入 YAML…`，右侧保持 Cancel / Add。不增加派生目录、分支预览或默认分支输入框。

错误就近关联字段。提交后原位显示 Checking repository… 与 clone 进度，提供 Cancel；资源和声明保存成功后才补齐工作区 `.gitignore` 中的仓库名规则并自动提交变化，Saving… 阶段包括这一步不可取消的收尾，完成后关闭并选中新仓库。远端检查、clone 或保存失败不写入仓库名规则。收尾失败保留已添加仓库，按第 6.1 节区分 `.gitignore` 未更新或自动提交失败，展示具体 Git 原因。不增加 Git 提交入口。

单个仓库添加失败且没有已完成效果时，返回原表单并保留 URL 与 Display Name，表单级提示使用 `Can’t add repository` / `无法添加仓库` 及一句原因和行动建议；不另开结果弹窗。仓库不存在或无权访问时显示 `Repository not found or access denied. Check the URL and your access permissions.` / `仓库不存在或无权访问，请检查地址和访问权限。`，不把远端拒绝访问断言为仓库不存在。认证失败、默认分支无效和其他 Git 失败使用对应短提示。原始脱敏错误默认收起在原生 Details / 详细信息中，展开后可滚动、复制；编辑 URL 清除旧错误，Add 可再次提交。

Import YAML 打开系统单文件选择器，仅选 `.yaml` / `.yml`，确认按钮为 Import / 导入；取消文件选择返回原表单并保留输入。选择文件后自动解析、去重并批量添加，不增加字段映射、仓库勾选或二次确认步骤。文件中的其他配置不影响当前表单输入，也不与手工 URL 合并提交；仓库提取与失败边界以 PRD 第 5.1.1 节为准。

解析和执行复用当前 Sheet 的进度布局：标题 `Importing repositories…` / `正在导入仓库…`，显示文件名、当前仓库和阶段，以及已处理/总数；跳过、失败数量仅在非零时附在计数后，不再重复显示已添加数量，完整分类保留在最终结果。尚未确定候选数量时使用不定进度条，不显示虚假计数。保留 Cancel，取消说明遵循第 6.1 节。不逐仓库弹窗；解析失败或没有合法 URL 时在原表单就近说明原因，保留重选入口。执行结束后按第 6.1 节一次汇总结果，区分已添加、已存在/重复、失败与未处理；需要结果提示时，在同一 Sheet 中直接从进度切换到结果，不先恢复 Add Repository，也不关闭后重新弹出。全部已存在时说明没有新增仓库，不显示导入成功。结果关闭后，有新增项则选中最后一个成功添加的仓库，否则保留原选择。

### 4.2 Create Worktree Group

正文保留 Group Name、Repositories 标题与 `<selected> / <total> selected`、原生搜索框、28px checkbox 列表、Cancel / Create，不增加常驻提示文本。搜索框固定在标题与列表之间，placeholder 为 `Search repositories` / `搜索仓库`，按展示名即时执行忽略大小写的包含匹配，忽略搜索词首尾空白；结果保持原有自然排序。搜索时标题另显示 `<count> matches` / `匹配 <count> 个`，选择计数始终基于全部仓库；切换或清空搜索不改变勾选，提交包含所有已选仓库。列表高度按全部候选仓库计算，最多完整显示 7 行，更多使用原生滚动，筛选时不收缩。无匹配时在列表区域显示 `No matching repositories` / `没有匹配的仓库` 和 `Clear Search` / `清除搜索`。每行仅 checkbox 与仓库展示名，不重复展示派生路径/分支。根 worktree 是固定创建项，不作为可取消勾选的仓库行。

创建 Sheet 初始聚焦 Group Name；`⌘F` 聚焦搜索框，Tab 按顺序访问搜索与复选框，Space 切换聚焦的复选框。搜索框聚焦时 Return 不提交表单；搜索框的原生清除按钮清空搜索，保留选择。支持系统焦点效果与 VoiceOver 搜索标签。

名称原样校验，不自动 slug 化；无仓库勾选时仅禁用 Create。创建使用本地已有的 Git 引用，不隐式联网或更新已有工作树；根分支不存在时从工作区当前 HEAD 创建。检查不到首次提交或所需的已提交忽略规则时，在原 Sheet 显示 `Commit the workspace .gitignore before creating this group.` / `请先提交工作区的 .gitignore，再创建此分组。`，附缺失规则或首次提交原因；保持表单，用户在外部处理后可重试。成员起点不可用时提示先更新主仓库，无法更新则在外部工具处理，不增加分支选择或提交入口。

通过预检后在原 Sheet 先显示 `Creating workspace worktree…` / `正在创建工作区工作树…`，再逐成员显示 Creating / Saving / Created。进度分别说明根 worktree 是否已创建和 `<completed> of <total> members created`，不把根计入成员数量；保存成功的根与成员才进入侧栏。取消说明遵循第 6.1 节。全部成功后关闭，最新清单加载完成即展开并选中 Group，不等待 Git 详情或其他资源的状态检查；优先读取根工作树的 Git 详情，后台继续检查其他资源。后续检查完成不覆盖用户的新选择。部分完成按真实列表反馈，包括根已创建但尚无成员的情况。

### 4.3 Edit Worktree Group

复用创建 Sheet 及搜索交互；Group Name 只读但可复制，勾选表示完整目标成员集合，筛选不会移除隐藏的已选成员；新增成员使用分组名作为初始分支名，已有成员保持当前 checkout。列表增加 Working Tree：Clean、Dirty、Other、Unset；Other 说明已登记成员的读取错误，Unset 仅表示仓库尚未加入当前 Group，不代表复选框状态。未改变的异常成员不阻止保存其他成员变更。排序不随勾选或状态改变。

仅无变更时禁用 Save Changes；允许取消全部勾选，移除确认说明 `The group workspace worktree will be kept.` / `将保留分组根工作树。`。纯新增直接提交；包含移除时，第一次点击在同一 Sheet 展示删除范围、工作树状态与待删除的当前本地分支，正文说明删除后果，不追加逐目标风险说明；destructive Save Changes 确认一次后执行，返回编辑保留勾选。

执行进度保留在 Sheet。再次打开 Edit 使用当前已保存成员，不呈现历史待续跑目标；新增、移除的顺序及失败边界以 PRD 第 7 节为准。

### 4.4 通用规则

URL 与 Group Name 的输入校验错误显示在对应字段下，编辑字段后清除旧输入错误；跨目标或执行错误留在 Sheet 的表单级区域。错误正文最多占 90pt，更多内容原生滚动并支持复制。编辑预检失败保留编辑 Sheet 与已选成员，不同时请求另一个结果 Sheet。执行中禁用重复提交并提供 Cancel；取消显示 Cancelling…，保存/必要清理期间暂时禁用取消，使用 Saving… / Cleaning up…。

取消表示停止后续工作，不暗示撤销全部结果。关闭 Sheet 恢复触发点焦点；成功创建按实体位置调整焦点，删除当前选中资源后回到工作区起始页，删除其他资源保持原选择。

执行结束后，原 Sheet 直接关闭或原位切换到结果；关闭动画及关闭后的旧视图仍保留最后的进度内容，不先恢复管理表单或删除确认。失败且没有保留效果、允许重试时才返回原表单；下一次打开管理 Sheet 时重置进度，从新的表单或删除确认开始。

## 5. Git Browser

### 5.1 Changes

使用 28px Outline 保留目录层级，每路径一行；标题显示 Staged / Unstaged，文件名前按暂存、未暂存的顺序仅展示有变化的状态图标，两侧都有变化时同时展示。无变化侧不显示短横线，也不占空白槽位；每个状态图标的 tooltip 和行的可访问值明确所属阶段，无变化语义保留于可访问值。

每级缩进统一为 16px，目录和文件共用 16px disclosure 槽位及其后的 4px 间距。目录图标和首个文件状态图标均为 16px、同级左边缘对齐；文件不再因空白状态额外缩进，子文件状态图标与父目录图标的水平距离等于父目录与上一级目录的距离。

文件名和目录名支持原生文本选择及复制；目录展开/折叠仍由 disclosure 按钮触发，行的右键 Reveal 操作保持可用。

Added、Moved、Modified、Deleted 使用现有状态图标；untracked 在 Unstaged 槽位复用 Added 的绿色容器和白色加号，不叠加额外字形，tooltip 和可访问值明确 Untracked。Conflict/Unknown 显示原始语义，不伪装 Modified。Moved 显示新路径，旧路径保留于 tooltip 和可访问值。

路径、两阶段状态和冲突原因均有完整可访问表达；Reveal 只对存在且可安全定位的路径可用。状态图标保留“状态色容器 + 白色字形”，Moved 浅色基准为 `#B262ED`，深色/高对比度适配。

没有当前节点快照时，首次读取 Changes 保持留白，不先显示标题、卡片或分隔区域；读到变更或读取错误后才显示，空结果继续隐藏，VoiceOver 保留更改加载状态。已有变更或错误在刷新时保持可见，直到新结果替换；读取失败显示 Unavailable，保留其他可用内容。范围和 dirty 语义仅由 PRD 第 10 节定义。

### 5.2 Commits

标题只显示 Commits，不显示计数或分支 badge。每条 28px，列依次为提交信息、提交人、时间、短哈希；紧凑窗口列间距 12px，后三列参考宽度 84/160/60px，提交信息获得剩余宽度。长内容截断，完整值通过 tooltip/无障碍读取。

卡片高度按标题、已加载的提交行及 Load More 适配，不用底部留白填满区域；Load More 占 28px，距提交列表 8px。内容超过当前可用高度时，卡片才占满该区域，列表在卡片内原生滚动，标题保持可见。与 Changes 同时显示时，可用高度由现有分隔条决定；只显示 Commits 时使用摘要下方的剩余高度。读取错误也按内容高度适配。

首次最多加载 30 条，更多使用 Load More，每次最多追加 30 条；未配置 remote 或空时隐藏，已配置 remote 但范围不可读时显示原因。merge/rebase 期间只要范围可读就展示，不因操作进行中一概禁用。不增加文件树或逐行 diff。

没有当前节点快照时，首次读取 Commits 保持留白，不先显示标题、卡片或分隔区域；读到差异提交或读取错误后才显示，未知状态不视为已确认无提交，VoiceOver 保留提交加载状态。已有提交或错误在刷新时保持可见，直到新结果替换，避免先清空再恢复。

### 5.3 选择与刷新

加载保持结构稳定，不闪现其他节点的数据。选择、App 激活、操作完成及 Refresh Changes 刷新本地状态；Refresh Changes 不联网、不 Pull 或创建资源。当前选中项的详情和 dirty 状态优先更新，其他资源随后在后台检查；Changes 读取完成即显示，不等待摘要、Commits 或外部工具检测。摘要、Changes、Commits 各自可加载或失败，不互相清空。

每个主仓库和 linked worktree 分别保留内存中的详情快照，工作区加载后在后台逐个预热。选择时立即显示该节点已有的摘要、Changes、Commits 和已加载分页，后台刷新期间不清空为 Loading；尚未预热完成时优先读取当前节点，保留目标路径、工具栏和摘要结构，Changes/Commits 按第 5.1、5.2 节保持留白，不显示加载文字或 spinner，不将未知状态伪造为空结果，VoiceOver 仍能读出加载状态。刷新失败显示该区域的真实错误；切换工作区、声明变化或修改操作完成后默认使旧快照失效，不跨工作区或节点复用。成功删除其他资源时，若当前选中资源仍存在且身份未变，摘要、Changes 和 Commits 保持显示，直到本地重新读取的结果替换；删除当前资源后清空选择与详情，回到工作区起始页。

启动已有工作区时，根目录与清单校验完成前主内容区保持窗口底色留白，不显示加载文字、spinner 或尚未选择提示；校验完成即显示侧栏与主内容，不等待仓库及 worktree 的 Git 状态或详情预加载，缓慢资源不阻止选择其他节点。VoiceOver 仍可读出加载状态。只有没有已保存的工作区路径时才进入设置引导。同一工作区的重叠刷新共用正在进行的读取；切换工作区后，旧读取的成功和失败都不得覆盖新状态。

## 6. 反馈与异常

### 6.1 操作进度与结果

可能保留已完成项的批量操作显示 `Completed items are kept when cancelled.` / `取消后保留已完成项。`，单个仓库添加不显示这段常驻说明；实际保留效果仍在结果中说明。

共用进度 Sheet 采用 460pt 宽、四周 24pt 留白的紧凑布局，高度随内容适配。按任务标题与次要上下文、当前目标与阶段、总体进度、底部操作四层组织：标题使用系统 headline；文件名/分组路径、阶段和计数使用系统 caption 与 secondary；当前目标使用系统 body 与 monospaced。当前目标旁保留小型 spinner，总体使用原生线性进度条；总数未知时使用同位置的不定进度条，并保留计数行高度，确定后显示已处理/总数。进度条只表达 Core 上报的处理数量，不表示克隆字节、剩余时间或额外推测的百分比，Group 根仍不计入成员数量。长目标中部截断，完整值通过 tooltip 和无障碍读取。

底部使用细分隔线，取消后保留已完成项的说明为次要 caption，Cancel 位于右侧。请求取消后禁用重复取消并显示 Cancelling…；进入不可取消的保存或清理阶段时优先显示实际的 Saving… / Cleaning up…，不让 Cancelling… 遮蔽收尾状态。数量未知、执行和收尾沿用同一容器与控件位置，不另开进度窗口。

Add/Create/Edit/Delete 的进度在原 Sheet；从 YAML 批量添加仓库的进度保留在 Add Repository Sheet，完整工作区 YAML 导入的进度 Sheet 附着于 Settings 窗口。更新仓库时，主窗口标题栏暂时显示原生 spinner、`Updating repositories · 1/3` / `正在更新仓库 · 1/3` 和尾部 Figma `Icon/Action/Cancel` 20×20 实心圆叉图标，替代工作区名称。计数为已完成处理数 / 仓库总数，成功、跳过和失败均计入；总数已知时从 0 开始，未知或为 0 时省略计数，数字等宽以避免更新时抖动。最多 6 个仓库并发更新，结果按配置顺序汇总，完成或失败后恢复工作区名称。点击取消后显示 `Cancelling… · 1/3` / `正在取消… · 1/3`，保留已完成计数，停止调度后续仓库、终止所有运行中的任务并等待收尾；进入不可取消的收尾阶段后按钮禁用。取消按钮提供 `Cancel Update` / `取消更新` 的可访问标签和 tooltip，不增加 File 菜单命令。

仓库更新全部成功（包括全部已是最新）后直接恢复工作区标题，不显示 check 图标、`Completed` 或 `Already up to date` 提示。其他主窗口操作全部成功时沿用短暂完成反馈。更新结果逐项区分已更新、已是最新、跳过和失败，全部跳过显示 `No repositories were updated` / `没有仓库被更新` 并列出原因，不显示成功反馈。失败、跳过、部分完成或有保留效果的取消使用一次结果 Sheet：目标 → 状态与原因 → 已完成/未完成 → 必要清理结果，只有 OK；正文过长时在 Sheet 内滚动，不建立任务中心。

网络错误说明具体步骤与时限，删除失败明确内容是否已删除、声明是否仍在、分支/Trash 的实际位置；不用 Rolled back 暗示整体恢复。初始化失败后保留的 Git 初始化、skill 与 `.gitignore` 修改和已完成的自动提交，以及创建失败后保留的 Group 根也属于需要说明的效果。添加仓库的忽略规则只在资源与声明保存成功后补齐并自动提交；收尾失败明确仓库已添加，并区分 `.gitignore` 未更新与变化未提交。无保留效果且清理成功的取消可静默。

所有结果 Sheet 沿用 460pt 共用宽度，不再仅按条目数选择 260pt 窄布局；历史原型的窄宽度与整行加粗不作为当前实现要求。标题说明具体任务与总体状态，使用系统 headline；取消使用中性停止图标，失败使用错误图标，跳过与部分完成使用提示/警告图标，图标只作补充，文本始终表达状态。多项结果在标题下展示非零的成功、跳过、失败、取消、未处理计数；仓库批量导入的成功项称为已添加，未处理项不计入普通跳过。

明细按原结果顺序排列：目标使用常规字重，状态与原因另起一行使用次要样式；实际保留效果仍明确展示。长目标完整换行且可复制，不截掉关键路径。只有 OK 的结果使用原生默认按钮，底部操作与正文之间使用细分隔线。

成功项使用已添加、已更新、已是最新等具体状态，合并重复的状态与原因。实际已完成、已清理、无法确认的效果摘要及 Trash 位置保持可见；完整效果路径和技术字段默认折叠在原生 Details / 详细信息中。

单个仓库添加失败且需要展示结果时，标题使用 `Can’t add repository` / `无法添加仓库`，不另起一行重复 Failed / 失败；原因沿用第 4.1 节的短提示，原始脱敏 Git 输出并入 Details。已保存仓库但忽略规则收尾失败时，标题改为 `Repository added with an issue` / `仓库已添加，但有一项问题`，正文说明实际效果，不暗示仓库未添加。

结果反馈结束后刷新真实状态，不立即弹出另一个修复流程。

### 6.2 工作区和资源错误

| 状态 | 界面与可用动作 |
| --- | --- |
| 根不存在 | 原生阻断 Alert：Workspace not found，显示完整根路径，Quit / Set Up Workspace |
| 当前配置不可用 | Workspace data couldn’t be loaded，显示实际文件与原因，Reload / Set Up Workspace / Quit |
| 某些资源不可用 | 侧栏状态槽位及详情显示 Unavailable 与具体原因，可用资源仍能浏览；无需每次激活弹窗 |

阻断状态遮蔽旧列表。Set Up Workspace 只进入正常选择流程，取消返回原提示，不承诺修复当前记录。锁忙暂缓刷新，不进入配置错误；保留已加载的内容，首次读取尚无内容时显示 `Workspace is busy` / `工作区正忙` 和 Reload，重新激活或 Reload 时重试。

显式 Reload 或 inspect 的资源结果可复用原生汇总 Sheet：标题 `Some resources are unavailable`，列出目标、路径和原因，说明 `Resolve these issues outside Modu, then reload the workspace.`，只有 OK。目录缺失按 PRD 第 3.3 节清理声明，不展示 Directory missing 或修复提示；其他权限、路径和 Git 异常继续显示 Unavailable。不提供同步方向或自动修复按钮。

### 6.3 删除确认

删除入口立即打开现有确认 Sheet，根据已加载配置立即列出目标路径，并异步预检。不显示分支行；每行固定 28px，右侧预留状态位置，保证预检前后的路径宽度和列表高度一致。预检期间不显示 Working Tree 状态或加载提示，Delete 保持禁用，Cancel 可用；通过后显示状态并启用 Delete，失败保留目标路径、在 Sheet 内显示原因，Delete 保持禁用。关闭 Sheet 取消预检，切换工作区或重新发起删除后不展示旧结果。

直接取消删除确认只关闭 Sheet 并取消未完成的预检，关闭回调清理删除目标与待保存的编辑选择。关闭期间及关闭后的旧视图使用独立的显示快照保留标题、目标列表和状态，清理操作数据不改变旧视图内容；下一次打开管理 Sheet 使用新的显示状态。从确认页返回编辑不关闭 Sheet，保留本次勾选。

仓库删除预检按 PRD 第 5.2 节检查 Git worktree 登记。存在配置外登记时，在当前 Sheet 中说明无法删除并列出可复制的登记路径，说明 `This repository is still used by worktrees outside Modu’s configuration. Resolve these worktrees and their Git registrations outside Modu, then try again. No resources or configuration have been changed.` / `此仓库仍被 Modu 配置外的工作树使用。请在外部处理这些工作树及其 Git 登记后重试。本次未删除任何资源，也未修改配置。`，不提供继续删除。登记读取失败显示具体原因，不伪报无外部依赖；确认后的执行前核对发现阻断时按第 6.1 节反馈。

复用现有紧凑 Sheet/Alert，列出目标路径和 Working Tree 状态。列表文本支持选择和复制。删除仓库时主仓库路径显示在首行，删除 Group 时根 worktree 显示在首行，关联成员保持预览中的相对顺序；显示顺序不改变成员先删除、主仓库或 Group 根最后删除的执行顺序。目标列表下方不再重复路径或展示 ignored、仅本地提交、detached 等逐目标风险说明；详细风险保留在 CLI 预览中。多资源列表超过 7 行滚动，长内容可展开或查看完整值。

| 删除对象 | 确认内容 |
| --- | --- |
| Linked Worktree | 目标路径和状态 |
| Group | 根 worktree 及所有配置成员，各自的路径和状态；成员先删除，根最后删除 |
| Repository | 主路径、配置内关联成员的路径和状态，主目录 Move to Trash |

明确 worktree 内容及当前本地分支（包括未合并提交）会永久删除，不区分新建或复用分支；主目录移入 Trash，远端不删除。这些通用后果只在确认正文说明一次，目标行保留路径及状态，不重复通用警告。Group 确认正文为 `The group workspace worktree, its members, and their current local branches (including unmerged commits) will be permanently deleted.` / `将永久删除分组根工作树、成员工作树及它们当前的本地分支（包括未合并提交）。`。根作为独立目标行展示，不只是路径标题；零成员 Group 仍展示根目标。单成员和仓库删除后即使没有剩余成员，也保留 Group 根。Cancel 为安全默认，destructive Delete 需明确激活，不追加第二次确认。确认后直接进入执行进度，复用已展示的风险结果，不再扫描工作树状态、ignored 文件或提交风险；执行前核对发现目标、当前分支或 detached 状态变化时停止，说明尚未开始删除，用户重新发起时展示最新目标。

删除过程中侧栏保留原有节点，Sheet 持续显示逐项执行进度；操作结束后按已保存结果一次更新侧栏，Group 及其成功删除的成员一起消失。编辑 Group 时新增成员仍逐项进入侧栏，移除成员统一等操作结束后更新。失败或取消也只在操作结束后应用实际已完成的删除结果。

删除后若当前选中的主仓库、Group 或成员已被移除，清空选择并回到工作区起始页，不自动选择相邻节点；当前选中资源仍存在时保留原选择。失败按第 6.1 节说明实际效果，列表使用已保存结果，不恢复已删除成员或提供专用续删入口。

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
| 07 | [Delete Repository](../design/prototypes/07-delete-repository.png) | 仓库删除确认布局；目标行只显示路径与状态，预检阻断在 Sheet 内说明 |
| 08 | [Create Group](../design/prototypes/08-create-worktree-group.png) | Group 创建表单；搜索与空结果布局以第 4.2 节为准 |
| 09 | [Edit Group](../design/prototypes/09-edit-worktree-group.png) | 目标成员与 Working Tree；搜索复用第 4.2 节，移除确认只显示路径与状态 |
| 10 | [Delete Group](../design/prototypes/10-delete-worktree-group.png) | 根 worktree 与成员的删除确认；目标单行显示路径与状态，加载行为以第 6.3 节为准 |
| 11 | [Delete Linked Worktree](../design/prototypes/11-delete-linked-worktree.png) | 单成员删除确认布局；目标行只显示路径与状态 |
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
| 25 | [Group Creation Progress](../design/prototypes/25-group-creation-progress.png) | 根 worktree 已创建、正在创建成员的状态参考；共用进度布局以第 6.1 节和 26 为准 |
| 26 | [Repository YAML Import Progress](../design/prototypes/26-repository-yaml-import-progress.png) | 原生组件渲染参考：目标、线性进度、计数与底部取消；非零异常计数按第 6.1 节展示 |

CLI/skill 安装状态、删除风险和 Git 两阶段状态按本文实现；19 的固定卡片高度、渐隐与强制 overlay 滚动条不作为验收要求。

原型的更新入口进入 13，示例运行 3 秒后进入 14，取消和 OK 返回 12；该跳转不代表真实更新耗时或取消保证。Group 行的图标/名称进入 15，选择成员返回 16；创建入口进入 25，真实创建完成后选中新 Group。06 的 Import YAML 进入 26，仅演示选定文件后的批量添加进度，真实文件选择使用系统面板。Settings 的非空导入提示为 22，24 仅作为显式资源检查结果。真实创建、取消、部分完成、工具启动和系统面板由实现承接，不以静态跳转替代验收。
