# 开发指南

本文提供代码导航与开发流程；业务规则、数据格式、界面和命令参数以对应实现为唯一事实源。

## 目录结构

```text
.
├── .agents/skills/               # 仓库开发 skill（版本更新等）
├── .codex/environments/          # Codex 本地任务入口配置
├── .github/workflows/            # GitHub CI 与发布流程
├── build/                        # 本地构建与打包产物（Git 忽略）
├── docs/                         # 按需读取的开发文档
├── ModuCLI/                      # modu-cli 入口与参数解析
│   ├── Commands/                # 工作区、仓库与分组命令
│   └── Support/                 # 公共选项、输出与参数归一化
├── ModuCore/                     # App 与 CLI 共享的业务
│   ├── Models/                  # 领域记录、资源标识与操作结果
│   ├── Workflows/               # 工作区、仓库、分组与 YAML 用例
│   ├── Infrastructure/          # Git、进程、文件系统、持久化与安装
│   └── Debug/                   # 隔离测试场景
├── ModuDesktop/                  # macOS App
│   ├── App/                     # 依赖组装、启动、命令与全局操作协调
│   ├── Features/                # Workspace、RepositoryBrowser、Management、Setup、Settings
│   ├── Platform/                # AppKit 桥接与外部工具
│   ├── SharedUI/                # 通用组件、样式与文案格式化
│   ├── AppIcon.icon/             # App 图标源文件
│   ├── Assets.xcassets/          # 界面图标与颜色资源
│   └── Resources/modu-workflow/  # 随 App 分发的工作流 skill
├── ModuDesktop.xcodeproj/        # Xcode target、scheme 与依赖配置
├── ModuDesktopTests/             # 单元、Git 集成与 CLI 测试及夹具
├── script/                       # 构建、启动、测试、打包与临时场景脚本
├── AGENTS.md                     # Agent 协作约定与文档索引
├── README.md                     # 面向使用者的项目介绍
├── Taskfile.yml                  # 本地开发命令入口
└── Version.xcconfig              # 产品版本与构建号
```

## 代码导航

| 需要了解 | 入口 |
| --- | --- |
| 工作区、仓库与 worktree 业务 | [Workflows/](../ModuCore/Workflows/)，从 [WorkspaceService.swift](../ModuCore/Workflows/WorkspaceService.swift) 开始 |
| 领域记录与操作结果 | [Models/](../ModuCore/Models/)，包括工作区、Git、资源与操作结果类型 |
| Git、进程、文件系统与持久化 | [Infrastructure/](../ModuCore/Infrastructure/)，命令统一使用 [CommandRunner.swift](../ModuCore/Infrastructure/Process/CommandRunner.swift) |
| App 启动与应用级协调 | [ModuDesktopApp.swift](../ModuDesktop/App/ModuDesktopApp.swift)、[AppModel.swift](../ModuDesktop/App/AppModel.swift)、[AppCommands.swift](../ModuDesktop/App/AppCommands.swift) |
| 全局操作与结果呈现 | [OperationLifecycle.swift](../ModuDesktop/App/OperationLifecycle.swift)、[OperationPresentation.swift](../ModuDesktop/App/OperationPresentation.swift)、[操作弹窗](../ModuDesktop/App/Operations/) |
| 工作区加载、侧栏与选择 | [Workspace/](../ModuDesktop/Features/Workspace/)、[WorkspaceModel.swift](../ModuDesktop/Features/Workspace/WorkspaceModel.swift) |
| Git 详情读取、缓存与分页 | [ResourceSnapshot.swift](../ModuCore/Models/ResourceSnapshot.swift)、[ResourceInspection.swift](../ModuCore/Workflows/ResourceInspection.swift)、[RepositoryBrowser/](../ModuDesktop/Features/RepositoryBrowser/) |
| 管理表单、预览与增删操作 | [Management/](../ModuDesktop/Features/Management/)、[ManagementModel.swift](../ModuDesktop/Features/Management/ManagementModel.swift) |
| 初始化与设置 | [Setup/](../ModuDesktop/Features/Setup/)、[Settings/](../ModuDesktop/Features/Settings/) |
| macOS 桥接与外部工具 | [Platform/](../ModuDesktop/Platform/) |
| CLI 与内置工作流提示词 | [main.swift](../ModuCLI/main.swift)、[Commands/](../ModuCLI/Commands/)、[modu-workflow/SKILL.md](../ModuDesktop/Resources/modu-workflow/SKILL.md)；用法查看 CLI 的 `--help` |
| 通用界面、样式与文案 | [SharedUI/](../ModuDesktop/SharedUI/)、[Assets.xcassets/](../ModuDesktop/Assets.xcassets/)、[AppIcon.icon/](../ModuDesktop/AppIcon.icon/) |
| 测试与夹具 | [ModuDesktopTests/](../ModuDesktopTests/) |
| 临时 Git 场景 | [prepare_mock_workspace.py](../script/prepare_mock_workspace.py)、[MockWorkspaceFixture.swift](../ModuCore/Debug/MockWorkspaceFixture.swift)、[MockWorkspace.swift](../ModuDesktop/App/Debug/MockWorkspace.swift) |
| 构建配置与依赖 | [ModuDesktop.xcodeproj/](../ModuDesktop.xcodeproj/)、[Package.resolved](../ModuDesktop.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)、[Version.xcconfig](../Version.xcconfig) |

三个产品 target 保持为 `ModuDesktop`、`ModuCore` 和 `ModuCLI`，另保留现有测试 target。Desktop 与 CLI 依赖 Core；Core 不依赖界面。功能目录用于组织源码，不增加 framework 或 package。

`AppModel` 负责组装依赖、启动、工作区切换、外部工具与退出协调。`WorkspaceModel` 管理当前工作区、侧栏选择和详情读取；`ManagementModel` 管理表单、预览与管理操作；`RepositoryDetailModel` 管理详情缓存和分页。工作区与管理模型共享 `OperationLifecycle` 与 `OperationPresentation`，通过生命周期标识和功能上下文检查阻止过期异步结果覆盖当前状态；详情读取保留自身的取消、缓存与分页上下文检查。Core 保留业务规则和副作用，View 渲染状态并转发操作。

## 本地开发

需要完整 Xcode（含命令行工具）和 Task 3。系统与 SDK 要求见 [Xcode 工程](../ModuDesktop.xcodeproj/project.pbxproj)，CI 工具链见 [ci.yml](../.github/workflows/ci.yml)。Swift Package 依赖由 Xcode 按锁文件解析。

```bash
brew install go-task
task
```

在仓库根目录运行任务。完整列表与参数见 [Taskfile.yml](../Taskfile.yml) 和 [script/](../script/)；`task --dry <任务>` 可只查看命令，底层参数放在 `--` 后。

| 命令 | 用途 |
| --- | --- |
| `task run` | 构建并启动 Debug App，使用本机工作区配置 |
| `task mock` | 构建并打开隔离的临时 Git 工作区 |
| `task verify -- --mock linked-worktree-selected` | 验证独立实例启动，输出 PID 后保持运行 |
| `task test` | 隔离运行单元测试并清理本次环境 |
| `task test TEST_FILTER=ModuDesktopTests/WorkflowTests` | 只运行指定测试类，也可筛选到方法 |
| `task package` | 生成发布版 DMG |

调试与日志使用 `task debug`、`task logs`、`task telemetry`，均可追加 `-- --mock linked-worktree-selected`。日志流的 Ctrl-C 只停止日志，App 继续运行。**不带 mock 的 run、debug、logs、telemetry 会先停止已有 Modu 实例**；临时验证优先使用上表的隔离 verify 命令。

## 验证与收尾

| 改动类型 | 验证方式 |
| --- | --- |
| 纯文档或提示词 | 检查路径、命令、交叉引用及 `git diff --check` |
| 代码 | 运行 `task verify -- --mock linked-worktree-selected` 检查构建与本次实例启动 |
| 业务或状态行为 | 在构建与启动检查之外，使用 `task test TEST_FILTER=<相关测试类或方法>` 验证变化的行为 |
| 原生窗口或交互 | 实现时按需临时执行 UI 自动化，完成后移除验证脚本并清理实例与数据 |

`task verify` 的启动成功不代表行为测试通过。Swift Testing 方法标识包含括号，可用 `task test -- -enumerate-tests` 查看。测试脚本默认清理结果包；需要保留诊断时传入 `task test -- -resultBundlePath "/tmp/Modu Tests.xcresult"`。

项目只维护单元、Git 集成和 CLI 测试，不引入 UI 测试 target、持久化用例或任务入口。UI 自动化仅用于实现界面改动时的临时验证；可独立验证的输入同步、匹配规则和业务状态继续由单元测试覆盖。布局、窗口定位和滚动通过实现时的临时验证与人工验收检查。

Mock 工作区测试聚焦场景加载、外部工具目标、临时安装与删除位置、目录边界和网络隔离；完整刷新、分组管理和 YAML 流程复用业务测试覆盖，避免在七仓库开发场景中重复执行。

Agent 临时验证按以下步骤收尾，失败或中断也适用；用户要求保留的实例除外：

1. 启动前记录已有实例与临时目录；启动后保存本次 PID、可执行路径、参数、启动时间、临时目录及辅助进程，核实归属。
2. 完成相关检查后，先让被调试器暂停的 App 恢复执行，再运行 `task quit PID=<本次进程号>`，等待并确认该 PID 已退出。
3. 确认本次临时仓库、worktree、偏好域与日志已清理，并停止本次辅助进程。mock 正常退出会清理数据；遗留数据在确认 App 退出后用 `task mock:cleanup DIRECTORY="<本次临时目录>"` 清理。
4. 正常退出失败时，核实身份后仅定向终止本次进程；归属不明时保留并报告。不要按进程名批量退出或按目录前缀批量删除，不清理既有实例、共享缓存或外部工具。

完成条件是对应检查通过、变化的行为得到验证、本次临时进程与数据已收尾；用户明确要求保留的实例除外。交付时说明实际执行的检查及退出、清理结果，未执行的检查或未完成的收尾说明原因。

## 打包与发布

产品版本与构建号统一在 [Version.xcconfig](../Version.xcconfig) 维护，Debug 和 Release 均继承该配置。[generate_version.sh](../script/generate_version.sh) 生成 Core 的 `ModuVersion`，App 的 Info.plist 和 CLI 的 `--version` 使用同一配置；CLI 安装目录和 DMG 文件名随产品版本生成，无需分别手动修改。工作区 YAML 的 `version`、CLI JSON 的 `schema-version` 和依赖版本独立于产品版本。

手动调用仓库 skill [`$modu-desktop-release`](../.agents/skills/modu-desktop-release/SKILL.md) 可检查工作区、确认版本、更新版本配置和 `CHANGELOG.md`，然后仅提交这两份文件并创建本地 `v<版本号>` tag。可指定版本，例如「请使用 `$modu-desktop-release` 更新到 `1.1.0`」；未指定时会根据最新发布 tag 以来的实际改动建议版本，并等待选择。此 skill 不自动推送。

发布流程采用 `X.Y.Z` 产品版本和每次加一的整数构建号；这是该流程的约定，底层版本生成脚本允许一到三段纯数字。版本提交前运行 `task test TEST_FILTER=ModuDesktopTests/VersionTests`，验证 App 的产品版本、构建号与生成值一致，且内置 CLI 返回相同产品版本。测试脚本负责隔离和清理测试环境。本地 `task package` 还会检查 App 与 CLI 的产品版本一致；输出目录与构建参数见 [package_app.sh](../script/package_app.sh)。

[GitHub CI](../.github/workflows/ci.yml) 定义触发条件、工具链和发布流程；仅在推送 `v*` tag 触发发布时运行测试，测试通过后打包并发布。测试失败时将 `.xcresult` 结果包作为 `test-results` 产物上传，保留 14 天。分支 push、PR 和手动触发仅构建打包。发布时在目标提交上推送与产品版本一致的 `v<版本号>` tag。

`CHANGELOG.md` 是版本变更说明的来源，发布章节统一使用 `## [X.Y.Z] - YYYY-MM-DD`，正文可按新增、改进、修复等分类。CI 在 tag 构建开始前使用 [release_notes.py](../script/release_notes.py) 校验 tag 与 `MARKETING_VERSION` 一致，且对应章节唯一、内容非空；校验失败即停止发布。普通分支构建不要求 CHANGELOG 发布章节。

发布 job 从同一 tag 的 CHANGELOG 提取对应章节，附加系统要求与签名说明，通过 `gh release create --notes-file` 作为 GitHub Release 正文。Unreleased 和其他版本的变更不会混入当前版本；Markdown 引用式链接的定义会保留。可以在提交版本前运行 `python3 script/release_notes.py v<版本号>` 预览实际变更说明。
