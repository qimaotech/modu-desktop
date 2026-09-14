# Modu Desktop PRD

- 日期：2026-09-22
- 状态：v0.1 核心工作流；本地开发版

## 0. 文档职责

本文定义产品范围、数据、业务行为、安全边界和验收。[DESIGN.md](DESIGN.md) 定义界面、交互、文案和原型索引；[AGENTS.md](../AGENTS.md) 只提供开发入口和工程约定，不重复业务规则。

优先实现正常使用的完整流程，以及应用自身操作失败时的安全停止和真实反馈。异常资源允许明确报错，不要求每种异常都有应用内修复入口。原型只提供视觉参考，不能扩展本文的功能范围。

## 1. 产品范围

Modu 是管理多仓库和跨仓库 linked worktree 的 macOS 原生工具。核心流程为：**选择工作区 → 添加仓库 → 创建 Group → 在外部工具中开发 → 查看状态 → 删除不再需要的 Group**。

### 1.1 保留的核心功能

| 能力 | v0.1 范围 |
| --- | --- |
| 工作区 | 首次设置、打开和切换；同时只激活一个 |
| 仓库 | 添加、删除、批量 Fetch 和只快进 Pull |
| Worktree Group | 跨仓库创建、编辑成员、删除 Group 或单个成员 |
| 外部工具 | Agent、Git GUI、编辑器、终端打开当前上下文 |
| Git Browser | 工作树摘要、未提交 Changes、相对 Base 的 Commits |
| 设置 | 中文/英文、自动 Fetch、选择与切换工作区、YAML 导入空工作区及导出 |
| 命令行 | 与 GUI 共用 Core 的 CLI，以及 Codex 工作区级 skill |

目标规模为 5–20 个主仓库、约 5 个活跃 Group、最多约 30 个 linked worktree。仅在选中仓库或 worktree 时加载其提交历史，每次最多加载 30 条。

### 1.2 明确不做

- 不替代 Agent、编辑器或完整 Git GUI；不提供 staging、commit、merge、rebase、逐行 diff 或 Agent 编排。
- 不提供配置与文件双向同步、缺失资源自动补齐、磁盘资源接管、目录迁移或覆盖式 YAML 导入。
- 不提供配置修复中心、跨重启任务续跑、操作 journal、整体回滚或 Git/index/工作文件备份。
- 不监测或修复用户在操作期间对目录、配置和 Git 登记的并发修改；不管理配置外资源。
- 不提供自定义工具、团队云同步、正式签名公证与自动升级。内置 skill 只保证 Codex，Claude Code 仅作为启动目标。

这些限制不妨碍正常代码编辑与 Git 开发。资源异常时保留现场并说明原因，用户处理后重新加载；不为消除报错扩大文件操作范围。

## 2. 系统边界

`ModuDesktop` 和 `modu-cli` 是薄入口，共享 `ModuCore` 的配置、Git、文件系统、worktree 和外部工具服务。GUI 负责展示与意图，CLI 负责参数与输出；业务规则只在 Core 实现一次。

- 使用 SwiftUI/AppKit；当前本地构建的最低系统版本以 Xcode 工程部署目标为准，使用 macOS 26 原生控件。
- 关闭 App Sandbox，访问用户选择的工作区；不隐式安装 Git 或开发工具。
- Git 调用系统 `git`；CLI 使用 Swift Argument Parser，YAML 使用 Yams，私有记录使用 JSON，不引入数据库或后台守护进程。
- 复用用户的 SSH、credential helper、hooks 和 Git 配置；认证、进程和输出边界见第 8 节。

| Git 场景 | 支持范围 |
| --- | --- |
| 有有效远端默认分支的普通非 bare 仓库 | 完整核心流程 |
| 空远端或无有效远端 HEAD | 添加/Fetch 失败，不猜测默认分支或提供手动 Base |
| submodule | clone 不递归初始化；显示父仓库摘要，不展开内部 Changes；不为含 submodule 的仓库创建 linked worktree |
| LFS / filter | 使用现有环境，失败如实报告，不安装或维护依赖 |
| locked worktree | 可读、可打开；修改/删除时失败，不自动解锁或加倍 force |
| sparse checkout | 不管理稀疏策略，按 Git 返回的真实状态读取 |

## 3. 数据与配置

### 3.1 工作区结构与私有记录

```text
<workspace>/
├── repositories/<repo-name>/
├── worktrees/<group>/<repo-name>/
└── .agents/skills/modu-workflow -> Application Support 中的受管 skill
```

工作区记录保存在当前用户的 `Application Support/Modu`，包含 `version: 1`、规范化绝对根路径 `root`、`repositories` 和 `groups`。它是管理清单的唯一事实源；路径由根、仓库身份和 Group 推导，不在成员中重复保存。工作区目录不存 Modu 配置或识别标记，不初始化根目录 Git。

App/CLI 按同一规范化根路径定位记录和工作区锁。根路径解析符号链接并遵循文件系统大小写语义；有效记录中的工作区根不能互相嵌套。不另建历史登记库；当前工作区引用的记录丢失属于配置错误，其他无记录目录按第 4 节的空目录条件决定能否初始化。

全局偏好保存当前工作区引用、语言、自动 Fetch、工具默认值及窗口偏好。Git 状态、缓存、Fetch 时间和操作进度只在内存中保存。

### 3.2 仓库与成员规则

- 仓库只保存 `url` 和可选展示名 `name`。URL 接受 HTTPS、SSH URL 或 SCP 风格 SSH；拒绝本地路径、其他协议及内嵌密码/token。非法输入在 Git 或文件操作前拒绝。
- 从 URL 最后路径段去除末尾 `/` 和一个 `.git` 后缀得到仓库名；查询与 fragment 不参与名称推导。仓库名匹配 `[A-Za-z0-9][A-Za-z0-9._-]*`，不能为 `.` 或 `..`，在工作区内忽略大小写唯一。不同远端的同名仓库不支持，展示名不改变身份或路径。
- GUI 常规表单只添加、删除仓库，不提供 URL 原位修改。Base 不写入配置，读取语义见第 10 节。
- Group Name 原样保存，必须是合法单段目录名，不能以 `-` 开头，作为 `refs/heads/<group>` 通过 Git ref 校验；按 Unicode 规范化及工作区文件系统的大小写语义唯一。
- Group 包含带时区的 RFC 3339 `created-at` 和非空成员集合；普通编辑保留创建时间。成员键引用已声明仓库，同一 Group 不重复引用。
- 成员记录 `branch`，默认等于 Group Name；CLI 可为新增成员指定其他合法分支。分支不得被解释为选项或 checkout shorthand。同一仓库的同一本地分支不能由两个配置成员占用。
- 私有成员另存 `branch-owner`：本次创建分支为 `modu`，复用已有分支为 `external`，缺失归属为 `unknown`。删除时只有 `modu` 分支随成员删除；该字段不接受 YAML 赋值。

### 3.3 加载与保存

配置的版本、类型、未知/重复字段、身份、成员引用及路径/ref 必须有效。已有记录不可读或无效时停止该工作区操作，不覆盖为空配置、不从目录反推清单；当前工作区引用的记录缺失也不自动初始化。

配置读写使用同一工作区锁；锁忙为 `workspace-busy`，不当作配置损坏。修改从读取到收尾持续持锁；每次保存校验完整候选，在记录同目录写临时文件后原子替换，保存成功才更新界面。资源的完成边界见第 8 节。

启动、打开、Reload 和 App 激活时重读配置并检查声明资源。检查只读，不联网、不自动修改声明或文件；忙时暂缓刷新。配置外目录和分支不展示、不接管、不清理。

### 3.4 YAML 导入与导出

YAML 是工作区清单交换格式，不是代码、Git 历史或未提交内容的备份。导入按目标机器已有的 Git 引用重新创建环境，不保证恢复原提交位置；未推送的分支提交不会随文件迁移。只包含以下字段，沿用第 3.2 节校验：

```yaml
version: 1
repositories:
  - url: git@github.com:team/frontend.git
    name: Web Console
groups:
  feature-report:
    created-at: "2026-08-26T10:30:00+08:00"
    repositories:
      frontend:
        branch: feature-report
```

- 导出当前有效配置，不包含 root、内部路径、归属、Base、全局偏好或运行状态；默认文件名 `<workspace-name>.yaml`，不保留注释和排版。
- 导入只允许当前有效工作区的清单为空，且 `repositories/`、`worktrees/` 都为空或不存在。隐藏/未受管条目也算非空；目录不可读、不是普通目录或为符号链接时拒绝，不移动已有内容。
- 先完整校验 YAML 和本地前置条件，创建缺失的标准目录，再按仓库→成员复用普通创建流程，逐项成功后保存；Group 的时间与分支取自 YAML，归属由实际动作决定。不预先保存整份目标清单。
- 失败或取消保留已完成项，未完成项不成为声明；结果列出未完成目标。用户可通过普通 Add/Create/Edit 完成剩余工作，或选择另一个空工作区导入；不为部分导入设计续跑协议。
- 文件选择、校验和执行固定同一工作区；期间禁用切换和重复提交。无有效工作区时导入/导出不可用。导出与校验失败不影响当前清单。

## 4. 工作区与设置

### 4.1 首次设置和切换

首次设置依次检查 CLI、选择候选目录、点击 Continue 初始化或加载工作区。CLI 或 skill 安装失败允许跳过，不阻断 GUI；目录选择和候选检查无副作用。

- 有对应记录的目录：有效记录加载成功后才切换；错误不改变当前工作区。
- 无记录的目录：仅在两个标准资源目录为空或不存在时，允许 Continue 创建缺失目录和空记录；其他根目录内容保留。现存仓库不能通过首次设置自动接管。
- 路径不可写、嵌套、标准目录类型不正确时拒绝初始化。失败报告实际结果，已创建的空目录可保留。
- 成功加载后保存当前工作区引用。取消候选选择保留原工作区；正常切换入口位于 Settings。

CLI/skill 的版本化内容位于 Application Support。CLI 只在登录 shell PATH 中的用户所有、可写且非 group/world-writable 目录安装受管链接；无合适位置时使用 `~/.local/bin` 并说明 PATH，不修改 shell 配置。已有非 Modu 同名目标不覆盖。

skill 只安装为当前工作区 `.agents/skills/modu-workflow` 链接；仅更新指向 Modu 的旧链接，不覆盖同名文件或第三方链接。不创建用户级链接，也不向主/linked worktree 注入文件。从工作区根启动 Codex 才保证发现该 skill。

### 4.2 资源不可用

| 情况 | 行为 |
| --- | --- |
| 工作区根不存在 | 阻断当前工作区，提供重新选择或退出，不自动创建原根或迁移路径 |
| 配置不可读、无效或当前引用的记录缺失 | 阻断并说明文件及原因，允许 Reload、选择其他工作区或退出，不覆盖记录 |
| 声明目录/记录分支缺失，或 Git 登记、origin、权限不符合要求 | 对应资源显示 Unavailable 和原因，独立可用资源仍可使用 |
| Base 不可用 | 只影响 Base 摘要和依赖它的操作/Commits，不隐藏可读取的 Changes |

不提供 Sync Configuration / Sync Files。用户在外部处理原因后 Reload；正常删除仅在第 7、8 节前置条件成立时可执行，不绕过损坏的 Git 登记。主仓库缺失时成员显示依赖不可用，不承诺重新 clone 能恢复现存 linked worktree。

不持续弹出资源修复选择，不自动移除缺失声明。配置修复、重新登记非空目录和历史记录恢复不属于 v0.1；错误说明当前限制与可用动作。

可用性按操作判断：Base 缺失不阻止 Fetch，主工作树 dirty 不阻止创建独立成员；仅新增分支需要的起点不可用时阻止该次创建。Group 编辑只预检新增和移除项，未改变的异常成员不阻止其他成员调整；不因某一项异常禁用整个工作区。

### 4.3 全局设置

- 语言仅中文和 English，首次按系统首选语言选择，之后使用保存值；立即更新界面，路径、分支和用户内容不翻译。
- 自动 Fetch 默认开启，间隔默认 10 分钟，接受 1–1440 整数分钟；只在 App 激活时判断是否到期，不设周期定时器。关闭后保留间隔；修改偏好不立即 Fetch 或取消任务。
- 操作、取消和收尾期间禁止切换工作区。Reload 或退出先取消可取消步骤、等待必要收尾；存在保留效果时先展示结果。

## 5. 添加与删除仓库

### 5.1 Add Repository

输入 URL 与可选 Display Name，校验名称冲突、支持范围和远端默认分支。完整历史 clone 到本次创建的临时目录，确保首次 checkout 有效远端默认分支及本地 origin/HEAD 正确，再改名到目标路径并保存声明；目标占用不覆盖。

资源与配置都完成才成功。失败清理本次未保存的新目录，不删除原有内容。重复 CLI add：同一 URL 且 name 未改变、资源有效时返回成功且无修改；资源不可用时报告错误，不解释为补齐。省略 name 保留已有值，其他同身份冲突报 `repository-conflict`。

### 5.2 Delete Repository

一次确认包含主目录、配置内关联成员、本地分支处置和风险。先按第 7.3 节逐个删除关联成员，再将主目录移入系统 Trash，最后移除仓库声明；任一步失败停止并保留已完成结果。

主目录已缺失且没有需处理的关联成员时，可明确确认移除声明；不可读或 Git 错误不能当作缺失。主目录移入 Trash 后保存失败，报告实际 Trash 位置和仍保留的声明，不自动移回或重建。配置外 linked worktree 可能失去 Git 连接，确认中说明，不盘点或修复它们。

## 6. Fetch 与 Pull

两项批量操作只针对配置内主仓库，不修改 linked worktree 的文件和 checkout；共享 refs 仍会变化。Fetch 对所有通过前置检查的主仓库一次性并发启动，Pull 仍串行处理；某仓库普通失败不影响其他独立仓库。

### 6.1 Fetch

先完成所有仓库的路径、配置和 Git 前置检查，再为每个可执行仓库启动独立 Fetch 进程。每个进程检查实际 origin 与声明一致，获取并裁剪 origin refs，查询远端 HEAD，验证对应远端跟踪分支有效后更新本地 origin/HEAD。Git 引用更新使用其原子能力，不手工备份或恢复 refs；单个进程失败不取消其他进程，保留已发生的更新并报告失败。

自动 Fetch 按仓库记录本次运行中的尝试时间，激活且到期才开始；首次视为到期，失败也受间隔限制，忙时跳过不记尝试。一次自动 Fetch 对到期仓库同时启动，未到期仓库不参与；已有显式用户操作优先于未开始的自动 Fetch。手动 Fetch 不受偏好限制；共享引用可能变化时，使同仓库主/linked worktree 的提交缓存失效，包括后续步骤失败的情况。

取消会向所有正在运行的 Fetch 进程发送终止请求，等待它们完成必要收尾后释放工作区锁；取消不回退已经更新的 refs。结果展示按配置中的仓库顺序排列，不按完成先后重排。

### 6.2 Pull

只更新 clean、非 detached 且当前分支为远端默认分支的主工作树。本地预检为 dirty、detached 或已确认缺失时直接 skipped；状态读取失败为 failed。当前默认分支以本次 Fetch 结果判定，不要求旧的 origin/HEAD 已经有效。

对 clean、非 detached 的候选主工作树完成一次第 6.1 节 Fetch，以该次确认的默认分支名称和 OID 判断当前分支并执行快进；名称不匹配则 skipped，已完成的 Fetch 在结果中保留。不反复联网确认远端之后是否又有变化，也不隐式再次 Fetch、stash、merge commit 或 rebase。

快进使用 Git 原生的 ignored 覆盖保护（`merge --ff-only --no-overwrite-ignore <OID>`）；clean 不表示 ignored 文件可以丢弃，发生覆盖冲突即失败，不另建文件备份。快进失败/取消保留已完成 Fetch 和实际工作树效果，不 reset 回退；重新读取并报告真实状态。

## 7. Worktree Group

### 7.1 创建

Group Name 与至少一个仓库组成创建请求，GUI 分支默认等于 Group Name；CLI 可覆盖新增成员分支。先校验整个请求中可提前判断的名称、路径、依赖、分支占用与 Git 条件，再顺序创建成员。

- 本地分支已存在且未被其他工作树检出时复用，归属为 external。
- 本地分支不存在时，优先从本地已有的同名 origin 远端跟踪分支建立 tracking branch，否则从有效 origin/HEAD 创建，归属为 modu。创建不隐式 Fetch；需要最新远端状态时先使用 Fetch，缺少所需起点时说明原因。
- 目标目录或不属于该有效配置成员的 Git 登记已存在时停止，不接管、覆盖或通过 force 修复。
- 每个 worktree 与分支就绪后立即保存成员；首个成功成员同时建立 Group。失败不保存该成员，停止后续成员，保留已成功项。
- 对已有 Group 的 create 只追加请求中的新成员；已有有效成员直接返回成功，不改变分支或 created-at；已有成员不可用则报错，不自动补齐。

实际 checkout 可以由用户在外部改变，Modu 展示真实 HEAD、不强制切回；记录分支仍用于成员声明和删除处置。

### 7.2 编辑

Group Name 只读，勾选列表表示完整目标成员集合，至少保留一个成员；已有成员不改分支。校验完整请求的结构与引用，仅对实际新增/移除项检查执行条件，包含移除时确认一次范围和风险。

先逐个新增并保存，全部新增成功才开始逐个移除。任一步失败或取消停止后续操作，已完成项保留；重新打开 Edit 显示当前已保存集合，不保留待续跑目标。

### 7.3 删除成员或 Group

删除只处理配置目标。确认前读取工作树、ignored 内容、detached HEAD，以及待删除记录分支的仅本地提交风险；仅本地提交依据本地已知远端跟踪 refs 判断，不额外联网。读取失败不当作无风险，locked 或待删除分支被其他工作树占用时停止。

确认一次后逐成员执行：

1. 使用 `git worktree remove --force` 移除工作树；目录和登记都已不存在时跳过资源移除。Git 错误不使用递归删除绕过。
2. 保存成员移除，最后一个成员移除时删除空 Group。保存失败即停止，不再删除该成员分支。
3. branch-owner 为 modu 时删除记录的本地分支；分支已不存在视为完成。external/unknown 保留，远端永不删除。

三步完成才算该成员成功，失败停止后续成员。已删除内容不重建，已移除声明不重新加入；残留分支与实际效果在结果中说明。Missing 不免除对尚存 Git 登记和待删除分支的检查。

最后一个成员移除后，仅尝试移除空的 Group 目录；有其他内容则保留，不递归清理。空的既有 Group 目录可用于后续同名创建，各成员目标仍不得占用；空目录清理失败只提示残留，不恢复已删除成员。

## 8. 安全、执行与失败处理

### 8.1 必须保留的安全边界

- 操作路径由有效配置和固定布局生成，检查存在性、类型和符号链接边界；工作区根、资源根及边界外路径不能成为删除目标。
- 新增不覆盖现存资源；主仓库及失败 clone 的清理使用 Trash，worktree 使用 Git 移除能力，不用永久递归删除绕过失败。
- 删除前展示目标与可读取风险并确认一次。确认只授权指定目标；执行时重新读取配置和预检，不依赖历史预览凭证。
- 外部命令使用可执行文件和参数数组；终端适配器传递目录参数并正确转义，不拼接未经转义的 shell 文本。
- 日志、JSON、UI 不暴露带凭据 URL、敏感环境变量或未经整理的完整 Git 输出。

### 8.2 一套执行规则

每个工作区 App/CLI 共用一把锁，配置加载短暂持锁，修改持锁直到进程退出和必要清理完成。预览后释放锁，不在等待用户确认时持锁。锁忙立即返回 `workspace-busy`，后台刷新暂缓；不引入分层锁、长队列或自动重试。

除 Fetch 外，批量请求逐项执行并保存。Fetch 不写配置，所有子进程同时完成或取消收尾后汇总结果；新增只有资源和配置均成功才发布；删除按第 5、7 节顺序保存。整个请求全部完成才成功；普通失败和取消保留已完成项，不要求跨文件系统、Git 和配置整体原子性。

失败时仅清理当前未完成项本次创建的新资源，不删除复用资源或已成功项。保存结果不确定时先重读，避免清理已提交资源；重读也失败时停止并保留现场，将结果标为无法确认，不能假定未保存后删除资源。清理失败停止后续工作，说明原始原因及残留路径/分支。各服务使用所需的小型清理函数，不建设通用补偿引擎。

| 失败发生点 | 必须表达的实际结果 |
| --- | --- |
| 新增资源后配置保存失败 | 新增未完成；说明清理是否成功，原配置是否保留 |
| worktree 已删除但声明移除失败 | 文件已删除、声明仍在、本次未删除记录分支；Reload 不会恢复内容 |
| 声明移除后分支删除失败 | 成员已移除、分支残留；不自动续删或重建成员 |
| 主目录 Trash 成功但保存失败 | 主目录实际 Trash 位置、声明仍在、资源不可用 |
| Fetch/Pull 中途失败 | 说明各仓库已更新的引用或工作树状态，不暗示完全未发生 |

取消停止后续工作，等待当前子进程退出和必要清理；短暂配置保存与清理不被再次取消打断。全部完成后的晚到取消仍为成功。取消无保留效果可静默，其余情况呈现实际结果。重启只加载当前记录，不恢复历史操作。

### 8.3 网络与进程

网络步骤共用执行器：clone 硬超时 30 分钟，其他网络子进程 60 秒，从启动到退出计时，不随输出重置；超时说明具体步骤，不自动重试或退化为 shallow clone。

认证非交互，不读取 stdin 密码或等待 host key 提示；缺少认证返回明确错误。Git 使用独立进程组，取消/超时先终止、等待 5 秒，仍未退出则强制终止并确认退出。异步读取输出，收尾不能因已脱离进程组的任务持有输出管道而无限等待。

用户 hook/filter/helper 主动脱离进程组的任务及其任意外部副作用不在恢复保证内；不建立全系统进程追踪。

## 9. 外部工具

内置目标：Agent 为 Codex、Claude Code；Git GUI 为 Fork；编辑器为 VS Code、Cursor；终端为 Warp、Terminal。不提供自定义命令模板。

只显示已检测到且适用于当前路径的目标。未选择资源时 Agent 打开工作区根；选中主仓库或 linked worktree 后，四类工具打开该路径。另提供始终可达的 Open Workspace in Codex，固定打开根目录以发现工作区 skill。

每类一个全局默认目标，启动成功后才更新；失败保留原值。通过受支持 CLI 或验证过的 Bundle ID/系统目录打开能力启动；Codex 必须先确认桌面应用已安装，不能借启动触发安装。Claude Code 需要 CLI 和可用终端。路径在启动前重新验证，权限或启动错误明确报告。

## 10. Git Browser

### 10.1 摘要与 Base

主工作树与 linked worktree 共用模型：Path、Base branch、Head branch。Base 从有效的本地 `refs/remotes/origin/HEAD` 读取，显示如 `origin/main`；确认 origin 与声明一致、引用有效且可解析为提交，缺失时显示不可用，不猜测 main/master、不联网或切换 checkout。detached HEAD 显示 `Detached at <short-sha>`。

### 10.2 Changes

Changes 只展示 staged、unstaged 和 untracked，不包含 ignored；已跟踪文件不因 ignore 规则被隐藏。读取 Git 机器状态并保留 NUL 路径边界，逐路径保存 index/worktree 两阶段状态，不用最终净 diff 替代。

每路径一行，重命名显示新路径并保留原路径；untracked、冲突和未知状态保持各自语义。`A/C` 为 Added、`R` 为 Moved、`M/T` 为 Modified、`D` 为 Deleted。两阶段相互抵消也保留该行，例如 staged Added + unstaged Deleted。

dirty 圆点来自同一次状态结果；读取失败为 Unavailable，不是 clean。Changes 不依赖 Base，merge/rebase 期间仍展示可读取状态。确认为空才隐藏。

### 10.3 Commits 与刷新

Commits 展示 `Base..HEAD`，首次及每次 Load More 最多读取 30 条；没有差异提交时隐藏，不能据此判断工作树是否 clean 或 HEAD 是否落后。Base 或范围不可读时只提示该区域不可用；merge/rebase 本身不构成禁用条件。

提交缓存绑定仓库、HEAD OID 与 Base OID；共享引用变化使相关缓存失效。Changes 在选择、App 激活、操作完成及 Refresh Changes 时重读，不依赖 HEAD 是否变化。不要求持续文件监听。

异步结果绑定工作区和 selection generation，切换选择取消旧读取，不把旧内容展示到新节点；各区域失败互不遮蔽。

## 11. CLI 与内置 skill

### 11.1 命令面

```text
modu-cli workspace inspect [--json]
modu-cli repo list [--json]
modu-cli repo add <url> [--name <display-name>] [--json]
modu-cli repo remove <repo-name> [--execute] [--json]
modu-cli worktree list [--json]
modu-cli worktree create <group> --repo <repo-name>... [--branch <repo>=<branch>] [--json]
modu-cli worktree update <group> --repo <repo-name>... [--branch <repo>=<branch>] [--execute] [--json]
modu-cli worktree remove <group> [--repo <repo-name>] [--execute] [--json]
```

全局 `--workspace <path>` 指定已有工作区根；省略时从规范化 cwd 向上匹配有效记录。App 未运行时 CLI 仍可用；首次初始化通过 App。未找到记录或根不存在明确报错，匹配记录无效不回退其他根。inspect/list 只读，无隐式创建或资源修复。

create 追加成员，update 表示完整目标集合。已有成员分支不能修改，传入不同分支在执行前拒绝。删除配置外目标返回 `target-not-configured`；不提供 workspace sync、导入、迁移或修复命令。

### 11.2 授权与输出

新增直接执行；删除和含移除的 update 在交互终端确认一次，`--execute` 直接授权。`--json` 或 stdin 非终端时不读取确认；未授权返回 `confirmation-required` 和含目标、路径、分支处置、风险的 plan，混合 update 的新增也不执行。

`--json` 的 stdout 只输出一个最终文档；进度与整理后的诊断写 stderr。统一外壳为 `schema-version: 1`、`command`、`workspace`、`status`、`reason-code`、`message`、`items`。未定位的 workspace、无请求级错误的 reason-code/message 为 null。

items 按仓库或成员列出 resource（kind、repo/group、相对 path）、status、reason-code/message 和 effects。effects 是动作的结构化摘要，含 action、target、state（applied / reverted / unknown），无动作为空数组；reverted 只描述实际清理，无法核实则标 unknown。已移入 Trash 的项附实际 trash-path。资源读取信息放在 data，读取失败不填伪空值。清理失败为 `cleanup-failed`，cause-code 保留原始原因；不提供整体 rollback 状态。

| 总体结果 | status / 退出码 |
| --- | --- |
| 全部目标完成，或只读空列表成功 | success / 0 |
| 有失败/跳过，同时有成功项 | partial-success / 1 |
| 无成功项且失败，或工作区忙 | failed / 1 |
| 全部跳过 | skipped / 1 |
| 缺少删除授权 | confirmation-required / 1 |
| 取消且有未完成项，收尾无失败 | cancelled / 130；已完成项仍为 success |
| 参数、工作区定位或配置加载错误 | failed / 2 |

单项失败可有保留效果，不能为了表达部分效果伪造成功项；取消收尾失败按 failed/partial-success 返回。资源缺失的 inspect 返回非零结果。

稳定 reason-code 按已实现能力定义，至少区分输入/配置错误、workspace-busy、资源缺失/不可用、路径或身份冲突、branch-in-use、worktree-locked、网络/认证失败、Git/Trash/配置写入失败、cleanup-failed 和取消。机器字段不随界面语言变化，命令实现时补充对应的契约测试。

### 11.3 modu-workflow

工作区级 skill 只负责调用 CLI：先 inspect 确认上下文，再 list 和执行用户要求的管理动作，统一传 `--json --workspace <root>`。资源异常说明原因并停止相关动作，可用资源不受无关项影响。

删除先预览范围和风险，有明确授权才传 `--execute`，不重复索取已有授权。按结果说明实际完成范围；不直接编辑私有记录、不用 Git/shell 绕过 CLI 的删除和支持边界，不承诺恢复数据。普通代码编辑和非 Modu 目录不触发此 skill。

## 12. 开发与验收

按可运行的纵向流程推进：先完成 Core 的工作区初始化/加载与最小 App 目录选择入口，再打通 Core/CLI 的添加仓库、创建与删除 Group；随后接主窗口和外部工具，最后完成 Git Browser、Fetch/Pull、完整设置和 YAML。初始化直接复用最终 Core 服务，不增设临时 CLI 初始化命令。每一步先验证正常路径及直接相关的失败，不以补齐所有异常修复场景作为开工条件。

测试使用临时目录、本地 bare remote 和故障替身，不访问用户仓库或真实网络；本地 remote 仅为 Git 测试夹具，业务输入仍遵循 URL 限制。优先验证：

1. 配置校验、路径边界、原子保存及 App/CLI 互斥；错误不变成空配置或 clean。
2. 仓库和 Group 正常创建/编辑/删除及同名重建；创建不隐式 Fetch，未改变的异常成员不阻止其他成员调整，部分成功不被后续失败覆盖。
3. 配置写入、Git、Trash、认证、超时和取消失败时的必要清理与真实反馈；保存和重读都失败时保留新资源，不误清理。
4. 空工作区 YAML 往返与部分导入；非空工作区拒绝且不触碰原内容。
5. Fetch 默认分支更新、Pull 只快进及 ignored 保护；Changes 两阶段抵消、特殊路径、冲突，以及 Commits 独立可用性。
6. GUI/CLI 结果一致，工具正确打开路径；键盘、VoiceOver、外观和 900×600 窗口可操作。

完成验收以“首次设置 → 添加仓库 → 创建/编辑 Group → 打开外部工具 → 查看 Changes/Commits → Fetch/Pull → 删除”的真实本地流程为主，再覆盖设置和 CLI。资源异常只要求安全阻断、清楚原因与 Reload，不验收自动修复。

代码改动运行 `./script/build_and_run.sh --verify`；该脚本只验证构建及 App 进程启动，行为需要相应单元、Git 集成、CLI 或 UI 测试。纯文档变更检查链接、规则一致性、原型索引和 `git diff --check`。

## 13. 参考资料

- [Git worktree](https://github.com/git/htmldocs/blob/gh-pages/git-worktree.adoc)
- [Git status](https://github.com/git/htmldocs/blob/gh-pages/git-status.adoc)
- [Codex CLI reference](https://developers.openai.com/codex/cli/reference/)
- [Codex skills](https://developers.openai.com/codex/skills/)
- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference)
