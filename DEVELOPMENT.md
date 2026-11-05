# 开发操作细则

## 功能模型与异步协调

### 模型职责与生命周期

| 模型 | 职责 |
| --- | --- |
| [WorkspaceModel](MonoDeck/Features/Workspace/WorkspaceModel.swift) | 工作区加载、侧栏与选择 |
| [ManagementModel](MonoDeck/Features/Management/ManagementModel.swift) | 管理表单、预览与增删操作 |
| [GitBrowserModel](MonoDeck/Features/GitBrowser/GitBrowserModel.swift) | Git 详情、状态缓存与后台预加载 |
| [GlobalShortcutModel](MonoDeck/Features/Settings/GlobalShortcutModel.swift) | 全局快捷键配置与录制 |
| [AppUpdateModel](MonoDeck/Features/Updates/AppUpdateModel.swift) | 更新检查、安装准备与重启交接 |

- 工作区与管理操作复用 [OperationLifecycle](MonoDeck/App/OperationLifecycle.swift) 和 [OperationPresentation](MonoDeck/App/OperationPresentation.swift)；详情与更新独立管理任务。异步结果发布前复核操作标识、生命周期和当前上下文。
- 取消请求与等待收尾分开处理；切换、写操作和退出覆盖读取、事件筛选、扫描、只读登记刷新及辅助进程。维护不能等待自身循环；旧后台任务收尾前保留需求，不派发新任务，前台详情可独立启动。
- 写操作和退出前停止相关监听与防抖，等待读取结束；退出再尽力保存缓存，最后清理 mock。取消或失败按实际效果反馈，不承诺整体回滚。

### Git 读取与缓存

- 前台与后台共享读取流程，与页面发布分离。完整详情包含本地更改、分支与基准摘要、独有提交（`base..HEAD`）和落后提交（`HEAD..base`），统一发布成功快照；刷新失败保留仍有效的旧成功结果，不用部分结果覆盖。
- 侧栏查询已展开的主仓库、分组根和成员，排除当前资源，不受滚动位置影响，有界并发 **4**；完整详情低优先级、串行预加载。顺序固定为当前完整详情（含历史）→ 本轮侧栏查询 → 后台完整详情。
- 启动维护结束、新展开和明确失效产生完整预加载需求；激活与空闲回调不新增完整预加载需求。侧栏查询与完整预加载无周期轮询。先补没有成功快照的资源，同级按资源 ID 排序并合并重复请求；收起移除需求并取消对应读取。
- 轻量状态与完整详情独立维护新鲜度、尝试时间和失效代际；轻量成功不解除详情失效。展开按各自尝试时间判断，明确失效绕过期限。成功或失败消费本轮需求，失败等待后续触发，取消不计时；读取中新失效需求仍须补齐。
- 切换或刷新立即取消后台读取并优先启动当前详情，不等待整个队列。后台、维护、写操作和退出暂停派发并取消、收尾；恢复后只处理仍在范围内的资源。后台成功只更新目标快照、侧栏状态和缓存，失败静默保留旧快照，不修改页面、加载状态、监听或弹窗。
- 切换资源先回显同一登记身份的成功内存快照，再核对文件身份；身份失效时丢弃旧缓存，仍新鲜且上下文有效的本进程结果可复用。磁盘恢复须先核对登记、仓库及 worktree 文件身份，再继续实时读取，不视为实时成功。每个异步阶段及缓存写入前复核取消、工作区、资源身份与失效代际，防止旧结果回流。
- 业务操作按共享 Git 仓库族失效并保留成功快照；登记删除或身份变化移除缓存，切换工作区清空内存。历史按仓库实体和 HEAD/base OID 复用；shallow、grafts、replace refs 等改变历史语义时绕过普通缓存，查询前后复核依赖。
- 磁盘仅保存完整成功详情与完整的独有提交与落后提交列表；损坏、版本不符、写入失败静默回退。原子写入、容量淘汰与多实例协调不得让旧观察覆盖新结果；失效移除待写项，切换不强制刷盘。容量、合并写入与清理期限以 [RepositoryDiskCache](MonoDeckCore/Infrastructure/Persistence/RepositoryDiskCache.swift) 为准，历史复用见 [RepositoryHistoryCache](MonoDeckCore/Workflows/RepositoryHistoryCache.swift)。正式启动注入缓存，直接构造模型默认禁用，mock 和测试使用本次临时目录。
- [ResourceReadSession](MonoDeckCore/Workflows/ResourceReadSession.swift) 只供 App 只读流程复用成功上下文，不跨轮共享可取消任务，也不用于 CLI 或写操作安全检查。登记、文件身份与有效 Git 配置依赖变化须重新验证；无法可靠确认时放弃复用，不修改用户 Git 配置。
- 文件监听覆盖[当前资源](MonoDeckCore/Infrastructure/FileSystem/ResourceChangeMonitor.swift)和[工作区登记](MonoDeckCore/Infrastructure/FileSystem/WorkspaceRecordChangeMonitor.swift)；后台保留失效，前台恢复处理，监听不可用时补查。普通事件可防抖并按真实 ignore 规则筛选，重要元数据或不确定事件直接刷新。前台失败提示须等待空闲并复核上下文；切换、取消或成功后丢弃，持续相同错误去重，手动刷新允许重试。
- Git 浏览与 CLI 查询只读本地数据，不 fetch。App 隐藏常规 submodule 内部及指针变化，仍保留 `.gitmodules`、类型转换和冲突；CLI 与业务安全检查读取完整状态，不能把普通嵌套仓库当子模块。

### 工作区加载与维护

- `refreshRecord` 只读同步，`maintainWorkspace` 执行目录修复、登记清理和内置工作流同步；自动刷新不得升级为维护。维护的用户影响见 [工作区文件与自动提交](README.md#工作区文件与自动提交)。
- 单个加载循环合并请求，当前批次与待处理批次分离；登记应用统一处理资源差异、选择、展开和缓存。等待者只等待所属批次，取消等待不取消共享任务；忙碌时保留请求。
- 写操作打断只读登记刷新时保留刷新意图，不重放旧回调；普通刷新不能降级维护。同一维护请求合并并保留已确定的选项；切换失败或取消继续原工作区需求，切换成功或退出清理旧需求。
- 登记监听覆盖原子替换；无关或内容未变的通知不重复读取 Git。激活按现有冷却规则合并，文件事件与手动刷新不受冷却限制。切换成功才重绑监听，登记缺失或损坏不自动初始化。同一工作区已有成功快照时，登记验证失败保留浏览内容，暂停 Git 读取并禁用管理操作；登记监听与重试仍可用，重新验证登记与工作区仓库成功后恢复读取和管理，独立的维护失败仍须维护成功才能解除。没有同一工作区快照时显示阻断错误。

### 启动与设置

- [AppModel](MonoDeck/App/AppModel.swift) 先检查 CLI，再只读恢复工作区与页面；当前首轮完整详情完成、失败或取消后才维护，维护结束且读取允许后再补齐后台队列。PATH 检查不阻塞页面；无当前选择时直接进入维护。
- 维护不提供用户取消入口；启动维护支持内部取消，手动维护期间阻止工作区切换，退出等待收尾。失败保留只读浏览、错误与重试入口，提示等待前台空闲；重试或切换成功清除旧失败。
- [SetupModel](MonoDeck/Features/Setup/SetupModel.swift) 展示前检查 CLI，复用启动检查结果并绑定工作区路径；回填旧路径不读取工作区登记或 Git。切换后重新准备，同次展示避免重复检查，关闭后重开重新检查；准备任务纳入启动取消与退出等待。
- 初始设置选择目录仅记录路径，点击“继续”后加锁检查并使用原登记，或在登记缺失时初始化或扫描恢复工作区，再执行原有维护。恢复策略及元数据限制见 [开始使用](README.md#开始使用)；启动自动加载、自动刷新和普通切换不启用接管。
- 恢复扫描依次检查主仓库、分组根和成员，每阶段最多并发 4 个资源，按目录顺序汇总结果；仓库上下文仅在本轮复用。取消停止派发并等待在途 Git 命令收尾后释放锁，扫描未完成不写登记。可选读取诊断包含 `recovery.scan`、各阶段耗时及有效资源数量。

### 自动更新

- [AppUpdateModel](MonoDeck/Features/Updates/AppUpdateModel.swift) 持久化自动检查开关和尝试时间，手动、失败或取消也计入自动间隔；已有待安装版本或窗口时不重复检查，mock 与测试不发起真实请求。
- 后台无新版或失败保持静默，新版等待启动就绪、前台且业务及提示结束后展示。手动检查可接替后台请求，关闭自动检查取消后台请求，过期结果不得发布；下载与安装须用户确认。
- [AppUpdateInstaller](MonoDeckCore/Infrastructure/AppUpdateInstaller.swift) 校验并在应用旁暂存新版，通过独立 CLI 安装进程接管退出后的替换与启动。App 先完成异步收尾、确认安装进程就绪再退出，避免 AppKit 延迟退出阻塞；退出超时回传失败并允许重试。
- 请求与安装标识隔离取消及回传，不修改工作区数据。成功准备、完整性失败、取消及退出清理本次下载；其他准备失败可保留供重试。替换后不自动回滚，部分失败保留实际效果与诊断；安装要求见[安装包契约](#ci-与安装包契约)。

### CLI 与领域契约

- CLI 仅解析参数、输出和交互确认；预览、成员变更、锁内复核及副作用放在 Core。`group create` 只创建新分组，`group member add` 扩展已有分组，`group edit` 替换完整成员集合。
- 所有写命令先生成计划，`--dry-run` 在任何工作区变更前返回；仅计划存在删除目标时请求确认，非交互执行通过 `--yes` 确认本次计划。创建计划和删除授权使用同一结果模型，计划动作与已发生的效果分开报告。
- 工作区登记、YAML 和 CLI JSON schema 均为版本 2，缓存条目及目录也为 v2，不提供旧命令、旧字段或旧格式解析。格式版本与 `Version.xcconfig` 的产品版本独立维护。
- CLI JSON 始终使用 `OperationResult`；目录树位于 `data.tree`，计划为 `plan.actions` 与 `plan.deletions`。新增命令须同步内置工作流、使用文档与实际 CLI 契约测试。

## 构建启动与调试

需要完整 Xcode（含命令行工具）和 Task 3，在仓库根目录执行。系统与 SDK 见 [Xcode 工程](MonoDeck.xcodeproj/project.pbxproj)，工具链见 [CI](.github/workflows/ci.yml)，依赖由 [Package.resolved](MonoDeck.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) 锁定。完整任务与参数见 [Taskfile.yml](Taskfile.yml) 和 [build_and_run.sh](script/build_and_run.sh)；`task --dry <任务>` 查看命令，`--` 后透传额外参数。

| 任务 | 命令 |
| --- | --- |
| 普通开发启动，恢复工作区与选择 | `task run` |
| 重新选择开发工作区 | `task run -- --reset` |
| 构建并激活隔离 Git 场景 | `task mock` |
| 隔离构建与启动验证，输出 PID 后保持运行 | `task verify -- --mock linked-worktree-selected` |
| 隔离 LLDB 调试，输入 run 启动 | `task debug -- --mock linked-worktree-selected` |
| 本次隔离实例的进程日志 | `task logs -- --mock linked-worktree-selected` |
| 本次隔离实例的 MonoDeck subsystem 日志 | `task telemetry -- --mock linked-worktree-selected` |

- 构建或启动改动优先用 mock verify；它只证明启动完成，不代表工作区加载或界面验证通过。浏览器验证仅在用户明确要求时执行。
- mock 每次创建新场景，复用开发构建产物；需要独立产物时指定本次专用 `MONO_DECK_DERIVED_DATA_PATH`。场景准备见 [prepare_mock_workspace.py](script/prepare_mock_workspace.py)，启动验证见 [verify_app.swift](script/verify_app.swift)，验证后按[临时实例收尾](#临时实例收尾)退出并清理。

### 偏好与工作区选择

- Debug 使用 `fun.armantang.MonoDeck.development` 偏好域，不迁移正式版偏好；`MONO_DECK_TEST_DEFAULTS` 与 mock 配置优先。数据、锁和 CLI 的共享风险见 [AGENTS.md](AGENTS.md#关键风险)。
- 页面选择与展开状态按工作区、本地更改树折叠按资源保存，临时加载失败不覆盖选择。窗口几何与布局在当前偏好域保存；恢复限制在可用屏幕内，全屏期间不覆盖普通窗口记录。实现见 [AppPreferences](MonoDeck/App/AppPreferences.swift) 与 [AppDelegate](MonoDeck/App/AppDelegate.swift)。
- `--reset` 仅支持不带 mock 的 run，构建成功后只清除工作区选择，保留浏览偏好、CLI 和工作区数据；使用测试偏好域时清除对应键，并取消 `MONO_DECK_TEST_WORKSPACE` 覆盖。

### 构建与日志诊断

- 启动任务追加 `-- --verbose` 查看完整构建日志，如 `task mock -- --verbose`。
- logs 与 telemetry 启动验证后按本次 PID 收集，失败不进入日志流，可能遗漏最早启动日志；Ctrl-C 只停止日志，App 继续运行。
- `MONO_DECK_READ_DIAGNOSTICS=1` 向标准错误输出本地 JSON 读取诊断，包含阶段、命令量和缓存统计，不记录命令参数或仓库路径。

## 测试执行与诊断

测试取舍遵循 [AGENTS.md](AGENTS.md#验证与交付)，执行入口为 [run_tests.py](script/run_tests.py)。

| 任务 | 命令 |
| --- | --- |
| 最小范围测试 | `task test TEST_FILTER='MonoDeckTests/<测试类或方法>'` |
| 枚举方法标识（Swift Testing 含括号） | `task test -- -enumerate-tests` |
| 保留结果包 | `task test TEST_FILTER='MonoDeckTests/<测试类或方法>' -- -resultBundlePath "/tmp/MonoDeck Tests.xcresult"` |
| 实时完整日志 | `task test TEST_FILTER='MonoDeckTests/<测试类或方法>' -- --verbose` |
| 明确需要时运行全量测试 | `task test` |

- 沙箱执行前只读核对用户级 SwiftPM 缓存写入权限；已有日志确认需提权时首次即申请，不重复已知失败的普通执行，权限变化后重新评估。
- 按输出的精确路径读取或删除完整日志，不按目录前缀清理。测试环境隔离，默认删除结果包；退出或清理无法确认时保留环境并返回失败。
- 零用例或全跳过不算通过，枚举除外；筛选失败先核对方法标识与 `TEST_FILTER`。
- mock 测试关注场景准备、外部工具目标和隔离；业务行为复用已有测试。读取性能比较按需运行 `MONO_DECK_READ_BENCHMARK=1 TEST_RUNNER_MONO_DECK_READ_BENCHMARK=1 task test TEST_FILTER='MonoDeckTests/RepositoryReadPerformanceTests'`；确定性断言使用次数或调度条件，耗时只作比较。
- Git 夹具复用 [Fixture](MonoDeckTests/MonoDeckTests.swift)：已有状态用 `Fixture(template:)`，未初始化目录用 `Fixture(createRemote: false)`；被测初始化、添加与创建流程仍现场执行。模板仅在本轮测试环境内共享，各用例独立复制并重建记录和远端映射；直接从 Xcode 运行不共享模板。
- 超时与取消测试使用可控等待和可注入时限；观察中间状态时用可取消替身阻塞并显式放行。保留真实文件锁、进程组清理及底层锁超时覆盖，不改变生产默认策略。

## 临时实例收尾

1. 启动前记录已有实例；启动后保存本次 PID、可执行路径、参数、启动时间、临时目录及辅助进程，用于确认归属。
2. 先恢复被调试器暂停的 App，再执行 `task quit PID=<本次进程号>`，等待并确认该 PID 退出；实现见 [quit_app.swift](script/quit_app.swift)。
3. mock 正常退出会清理数据；核对本次仓库、worktree、偏好域与日志，停止本次辅助进程并移除临时验证脚本。遗留数据在确认退出后用 `task mock:cleanup DIRECTORY="<本次临时目录>"` 定向清理。
4. 正常退出失败时，核实身份后仅终止本次进程；归属不明则保留并报告。[find_mock_app.py](script/find_mock_app.py) 可辅助核对。用户要求保留的实例除外。

## 版本打包与发布

### 版本生成与本地准备

- 版本只改 [Version.xcconfig](Version.xcconfig)，[generate_version.sh](script/generate_version.sh) 生成 App、CLI 共用的 `MonoDeckVersion`。完整版本准备流程仅在显式调用[发布 skill](.agents/skills/release-mono-deck/SKILL.md)时执行。
- 修改代码或文档不隐含暂存、提交或发布授权。显式请求完整发布流程仅授权 `Version.xcconfig`、`CHANGELOG.md` 暂存、提交及对应本地 tag；推送分支、tag 和创建 GitHub Release 仍需单独授权。推送 `v*` tag 会触发 CI 发布。

| 任务 | 命令 |
| --- | --- |
| 修改版本后、提交前核对 App 与 CLI 版本 | `task test TEST_FILTER=MonoDeckTests/VersionTests` |
| 校验并预览当前版本发布说明 | `python3 script/release_notes.py v<版本号>` |
| 打包 arm64 发布 DMG，本地完成后自动打开 | `task package` |

打包检查、参数与输出目录见 [package_app.sh](script/package_app.sh)；发布说明收录与格式只在发布 skill 中维护。

### CI 与安装包契约

- [CI](.github/workflows/ci.yml) 的 `v*` tag 流程校验版本与 CHANGELOG，打包和串行全量测试均通过后才发布；测试失败时上传结果包。PR 和手动触发仅构建打包，main push 不触发。
- tag、产品版本、发布说明与 `MonoDeck-<版本号>-arm64.dmg` 必须一致；[更新检查](MonoDeckCore/Infrastructure/AppUpdateService.swift) 只接受更高版本的最新正式 Release。
- 自动安装要求附件元数据提供有效 SHA-256 `digest`，下载后核对文件大小和摘要，缺失或不匹配拒绝安装。

## 文档与提示词维护

- 产品文档介绍核心功能、用法和用户风险；开发文档记录职责、关键设计与操作入口。业务规则、数据格式和参数以代码为准，避免罗列实现分支、调优常量和界面布局细节。
- 规则保留单一来源，其他入口引用；完整参数查 CLI `--help` 或脚本。纯文档改动检查路径、命令、章节引用及 `git diff --check`。

| 提示词 | 实现核对入口 |
| --- | --- |
| [内置工作流](MonoDeck/Resources/mono-deck-workflow/SKILL.md)、[调用配置](MonoDeck/Resources/mono-deck-workflow/agents/openai.yaml) | [CLI 命令](MonoDeckCLI/Commands/)与 [Core](MonoDeckCore/Workflows/) 操作结果 |
| [发布流程](.agents/skills/release-mono-deck/SKILL.md)、[调用配置](.agents/skills/release-mono-deck/agents/openai.yaml) | `Version.xcconfig`、[发布说明脚本](script/release_notes.py)与 CI |
| [手动自检](.agents/skills/check-mono-deck/SKILL.md)、[调用配置](.agents/skills/check-mono-deck/agents/openai.yaml) | 检查范围、测试取舍与交付约束 |

- 内置工作流在 App 资源目录维护，工作区副本的覆盖与自定义规则见 [README](README.md#工作区文件与自动提交)，同步实现见 [WorkspaceService](MonoDeckCore/Workflows/WorkspaceService.swift)。
- 内置工作流允许自动调用，发布和自检仅手动调用；修改 skill 时同步核对 description、`agents/openai.yaml` 的 default_prompt 与调用策略。
