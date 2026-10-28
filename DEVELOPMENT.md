# 开发操作细则

## 功能模型与异步协调

| 模型 | 职责 |
| --- | --- |
| `WorkspaceModel` | 工作区加载、侧栏与选择 |
| `ManagementModel` | 管理表单、预览与增删操作 |
| `RepositoryDetailModel` | Git 详情读取、缓存、预加载与分页 |
| `GlobalShortcutModel` | 全局快捷键配置与录制 |
| `AppUpdateModel` | 手动与自动检查更新、准备安装、请求取消与重启交接 |

- 工作区与管理操作复用 `OperationLifecycle` 和 `OperationPresentation`，通过操作标识与功能上下文阻止过期结果覆盖当前状态。
- 详情读取与更新检查各自维护任务取消、缓存或请求上下文，不并入管理操作的生命周期。

### 自动更新

- 自动检查默认开启，开关与最近一次检查尝试时间由 `AppPreferences` 持久化。启动完成或 App 重新激活时触发，距上次检查（含手动检查、失败或取消）至少 24 小时才发起后台请求；已有待安装版本或更新窗口可见时不重复自动检查。mock 与单元测试宿主不触发真实自动检查。
- 后台检查无新版或失败时不弹窗，发现新版后由 App 层等待启动窗口就绪、App 处于前台、业务操作与结果提示结束，再打开更新窗口。手动检查不受开关或间隔限制，并接替进行中的后台检查；关闭自动检查会取消本次后台请求，过期结果不能发布。自动检查不下载或安装，安装仍由用户确认。
- 更新窗口左下角为“自动检查更新”复选框；发现新版后，版本变化中的目标版本号作为链接打开该版本的发布说明。
- 更新窗口内容区固定为 460 × 200，各状态切换不调整主窗口尺寸；“详细信息”链接紧接错误说明，点击后在浮层中显示诊断信息；长错误正文在状态区内滚动。下载显示定量进度，其他处理阶段使用忙碌指示；等待退出时由 App 层提供当前操作或结果确认的等待原因，主操作按钮隐藏。
- DMG 缓存在 `~/Library/Caches/fun.armantang.ModuDesktop/Updates/` 下的独立目录。准备安装成功后立即清理，后续替换和重启不再依赖 DMG；下载完整性校验失败（`update-integrity-failed`）、取消、重新检查或退出时清理本次缓存，其余准备失败可保留供重试。
- 自动更新由 Core 准备并校验 DMG 中的应用，在当前应用旁暂存；退出准备期间先拒绝当前退出请求，异步清理完成并启动内置 CLI 的独立安装进程、确认就绪后，再次请求退出，避免 AppKit 的延迟退出模态循环阻塞主线程任务。安装器最多等待原进程退出 60 秒，超时通过本次安装的结果文件回传错误，原应用清除待退出状态并允许重试。
- 安装器验证应用身份后原子替换应用，清理被替换的旧应用，再通过系统 `open` 请求启动新版；成功后删除暂存目录。替换或启动请求失败时保留已完成的效果和诊断文件，安装后的应用不自动还原。
- 更新任务通过请求与安装标识隔离取消和过期回传，不修改工作区数据；CLI 链接随应用原路径替换指向新版，迁移与修复方式见 [CLI 与 Agent](README.md#cli-与-agent)。

## 构建启动与调试

- 需要完整 Xcode（含命令行工具）和 Task 3，在仓库根目录执行。系统与 SDK 配置见 [Xcode 工程](ModuDesktop.xcodeproj/project.pbxproj)，工具链见 [CI](.github/workflows/ci.yml)；Swift Package 依赖由 Xcode 按 [锁文件](ModuDesktop.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) 解析。
- 完整任务见 [Taskfile.yml](Taskfile.yml)，启动参数见 [build_and_run.sh](script/build_and_run.sh)；`task --dry <任务>` 只查看命令，额外参数通过 `--` 透传。

| 任务 | 命令 |
| --- | --- |
| 普通开发启动，恢复开发工作区 | `task run` |
| 重新选择开发工作区 | `task run -- --reset` |
| 构建并激活隔离 Git 场景，验证启动并输出 PID | `task mock` |
| 隔离工作区数据的构建与启动验证，不停止已有实例；输出 PID 后保持后台运行 | `task verify -- --mock linked-worktree-selected` |
| 隔离 LLDB 调试，输入 run 启动 | `task debug -- --mock linked-worktree-selected` |
| 本次隔离实例的进程日志 | `task logs -- --mock linked-worktree-selected` |
| 本次隔离实例的 Modu subsystem 日志 | `task telemetry -- --mock linked-worktree-selected` |

- 临时验证优先使用带 mock 的 verify；构建或启动相关改动用它检查构建与启动，原生窗口或交互改动按需临时执行 UI 自动化。
- mock 默认复用开发构建产物；需要独立构建产物时，为 `MODU_DERIVED_DATA_PATH` 指定本次专用目录。
- 调试与日志命令使用临时场景示例；普通开发模式可省略 mock 参数。
- mock 数据由 [prepare_mock_workspace.py](script/prepare_mock_workspace.py) 准备，启动验证由 [verify_app.swift](script/verify_app.swift) 执行。

### 偏好与工作区选择

- Debug 默认使用 `fun.armantang.ModuDesktop.development` 偏好域，独立保存工作区选择、语言、快捷键、更新检查和工具选择，不迁移正式版偏好；`MODU_TEST_DEFAULTS` 与 mock 配置优先。
- 工作区记录和锁位于 `~/Library/Application Support/Modu/`；`~/.local/bin/modu-cli` 直接链接当前 App 的 `Contents/Resources/modu-cli`，更新 App 无需重新安装 CLI。旧版 CLI 链接在重新安装时迁移，保留原版本目录；不带 mock 的 verify 使用当前开发偏好所选的工作区。
- `--reset` 仅用于不带 mock 的普通 run，在构建成功后只删除偏好的 `workspace` 键，保留其他偏好、CLI 安装与工作区数据。设置了 `MODU_TEST_DEFAULTS` 时清除该域中的选择，并取消传入 `MODU_TEST_WORKSPACE`，避免立即恢复选择。

### 构建与日志诊断

- 开发构建使用当前运行架构，默认显示阶段进度、耗时、警告和错误；启动任务追加 `-- --verbose` 可查看完整构建日志与耗时汇总，例如 `task mock -- --verbose`。
- mock 会报告数据准备耗时和并行构建总耗时；启动耗时包含验证脚本的编译与执行。
- logs 与 telemetry 验证启动后，按本次实例的 PID 收集日志；telemetry 额外筛选 Modu subsystem。启动失败或无法取得有效 PID 时返回失败，不进入日志流。监听从启动验证完成后开始，可能遗漏最早的启动日志。
- 日志流的 Ctrl-C 只停止日志，App 继续运行。

## 测试执行与诊断

| 任务 | 命令 |
| --- | --- |
| 最小范围测试 | `task test TEST_FILTER='ModuDesktopTests/<测试类或方法>'` |
| 运行一个发布测试分组 | `task test TEST_SHARD=1`（1–4，与 `TEST_FILTER` 互斥） |
| 枚举测试方法标识（Swift Testing 含括号） | `task test -- -enumerate-tests` |
| 保留测试结果包 | `task test TEST_FILTER='ModuDesktopTests/<测试类或方法>' -- -resultBundlePath "/tmp/Modu Tests.xcresult"` |
| 明确需要时运行全量测试 | `task test` |

- 在 Codex 沙箱中运行测试前，核对用户级 SwiftPM 缓存的写入权限。若缓存不在可写范围，且已有日志确认该测试入口需要提权，首次执行即申请所需权限，不重复尝试已知会失败的普通执行；权限配置变化后重新评估。
- [run_tests.py](script/run_tests.py) 隔离并清理本次测试环境，默认删除结果包；检查实际执行数量与清理结果，退出或清理无法确认时保留环境并返回失败。
- 发布测试按 suite 分成四组，组内串行，在独立 runner 上并行；分组配置位于 `run_tests.py`，第四组包含前三组之外的全部测试，新增 suite 自动纳入。调整分组时参考 CI 日志中的 suite 耗时。
- 零用例或全跳过不算通过，`-enumerate-tests` 除外；筛选失败时先核对方法标识与 `TEST_FILTER`。
- Mock 测试聚焦场景加载、外部工具目标及安装、删除、目录和网络隔离；完整刷新、分组管理与 YAML 流程复用 [业务测试](ModuDesktopTests/)，避免重复覆盖。

## 临时实例收尾

1. 启动前记录已有实例与临时目录；启动后核实并保存本次 PID、可执行路径、参数、启动时间、临时目录及辅助进程。
2. 先恢复被调试器暂停的 App，再执行 `task quit PID=<本次进程号>`，等待并确认该 PID 已退出；实现见 [quit_app.swift](script/quit_app.swift)。
3. mock 正常退出会清理数据；核对临时仓库、worktree、偏好域与日志，并停止本次辅助进程、移除临时 UI 验证脚本。遗留数据在确认 App 退出后用 `task mock:cleanup DIRECTORY="<本次临时目录>"` 定向清理。
4. 正常退出失败时，核实身份后仅定向终止本次进程；无法确认归属时保留现场并报告。[find_mock_app.py](script/find_mock_app.py) 可辅助核对 mock 实例归属。

## 版本打包与发布

### 版本生成与本地准备

- [generate_version.sh](script/generate_version.sh) 从 [Version.xcconfig](Version.xcconfig) 生成 Core 的 `ModuVersion`，App Info.plist 与 CLI 的 `--version` 使用同一配置；DMG 文件名随产品版本生成。
- 版本选择、格式、构建号递增、CHANGELOG 收录、暂存提交及 tag 授权、失败续跑按 [发布流程](.agents/skills/modu-desktop-release/SKILL.md) 执行，仅在用户显式调用该流程时运行完整步骤。

| 任务 | 命令 |
| --- | --- |
| 修改版本后、提交前核对 App 版本、构建号与内置 CLI | `task test TEST_FILTER=ModuDesktopTests/VersionTests` |
| 校验并预览当前版本的发布说明 | `python3 script/release_notes.py v<版本号>` |
| 打包 arm64 发布版 DMG，本地完成后自动打开 | `task package` |

- [package_app.sh](script/package_app.sh) 核对 App/CLI 版本、架构、签名、内置资源与 DMG 完整性；构建参数和输出目录以该脚本为准。

### CI 与安装包契约

- [CI](.github/workflows/ci.yml) 在 tag 构建中校验版本与 CHANGELOG，四组全量测试与 Release 打包并行；打包和全部测试通过后才创建 GitHub Release。任一组失败不取消其他组，各失败组上传独立命名的 `.xcresult`。main 分支 push、PR 和手动触发仅构建打包。
- Swift Package 源码缓存按系统、架构、Xcode 和 `Package.resolved` 区分，仅 main 分支 push 构建成功后保存，发布和 PR 可读取。缓存不包含 Debug/Release 编译产物；首次运行或缓存失效时照常解析锁定依赖。
- [release_notes.py](script/release_notes.py) 校验 tag 与产品版本一致、当前版本章节格式正确且唯一非空，并提取该章节供 Release 使用；CI 附加系统要求与签名说明。章节格式见发布流程，普通分支构建无需发布章节，Unreleased 与其他版本内容不会混入本次发布。
- 发布 tag、产品版本与 DMG 附件名必须匹配；[更新检查](ModuCore/Infrastructure/AppUpdateService.swift) 只提供更高产品版本的最新正式 Release，并要求包含 `Modu-<版本号>-arm64.dmg`。
- [自动安装](ModuCore/Infrastructure/AppUpdateInstaller.swift) 还要求 Release 附件元数据提供有效的 SHA-256 `digest`，并通过文件大小与摘要校验；缺失或不匹配时拒绝安装。

## 文档与提示词维护

| 提示词 | 实现核对入口 |
| --- | --- |
| [内置工作流 SKILL.md](ModuDesktop/Resources/modu-workflow/SKILL.md)、[openai.yaml](ModuDesktop/Resources/modu-workflow/agents/openai.yaml) | `ModuCLI/Commands/` 与 Core 的操作结果 |
| [发布 SKILL.md](.agents/skills/modu-desktop-release/SKILL.md)、[openai.yaml](.agents/skills/modu-desktop-release/agents/openai.yaml) | `Version.xcconfig`、`script/release_notes.py` 和 `.github/workflows/ci.yml` |

- 详细规则维护单一来源，其他入口保留摘要与引用；完整参数说明引用 CLI `--help` 或脚本，发布说明的收录标准维护在发布流程中。
- 纯文档或提示词改动检查路径、命令、交叉引用及 `git diff --check`。
- 内置工作流源文件位于 App 资源目录，工作区副本的覆盖规则与自定义方式见 [CLI 与 Agent](README.md#cli-与-agent)。同步实现见 [WorkspaceService.swift](ModuCore/Workflows/WorkspaceService.swift)：丢弃托管文件改动后，按需 stash 其他工作区文件，同步并自动提交内置内容，最后恢复其他改动。
- 内置工作流默认允许自动调用（`allow_implicit_invocation: true`），发布流程仅显式调用（`allow_implicit_invocation: false`）；修改时同步核对 `SKILL.md` 的 description，以及 `agents/openai.yaml` 的 default_prompt 与调用策略。
