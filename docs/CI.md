# GitHub CI 与本地打包

## 本地任务入口

开发命令统一定义在 [Taskfile.yml](../Taskfile.yml)，使用 [Task 3](https://taskfile.dev/docs/installation)。macOS 可通过 Homebrew 安装：

```bash
brew install go-task
task --version
task
```

`task` 或 `task --list` 列出任务；`task --dry <任务>` 只显示命令。需要向底层命令传参时放在 `--` 后，含空格的参数按正常 shell 规则加引号。

| 命令 | 用途 |
| --- | --- |
| `task test` | 隔离运行 `ModuDesktopTests`，清理本次环境，零用例失败 |
| `task test TEST_FILTER=ModuDesktopTests/BuildAndRunScriptTests` | 只运行指定测试类，也可指定到方法 |
| `task test:ui` | 单独运行 `ModuDesktopUITests` |
| `task package` | 构建、检查并打包 arm64 发布版 DMG |
| `task icon:previews -- "/tmp/Modu Icon Previews"` | 导出六种原生图标外观 PNG；省略目录时使用临时目录下的 `modu-app-icon-previews` |
| `task quit PID=<本次进程号>` | 请求指定 Modu 实例正常退出并等待结束 |
| `task mock:cleanup DIRECTORY="<本次临时目录>"` | 清理已确认退出或未启动的本次 mock 数据 |

构建、启动、打包、图标导出与 mock 清理继续复用 `script/` 中的实现；实例验证、进程识别和版本生成是内部辅助脚本，由开发脚本或 Xcode 构建阶段调用。

测试由 [测试运行脚本](../script/run_tests.py) 统一执行。每次运行自动创建独立的偏好域、支持目录、home、临时文件目录和默认结果包；外部传入的 `MODU_TEST_*` 不会替代本次隔离环境。单元测试宿主跳过应用自动启动和开窗，直接调用 `AppModel.start()` 的测试仍执行原有业务逻辑。用于布局测量的测试窗口保持透明，显式启动的测试 App 沿用无自动开窗模式；`task test:ui` 保留正常界面启动。

成功、测试失败、构建失败和中断都停止本次辅助进程，并核对宿主登记的 PID、可执行路径和启动时间后退出残留实例，再清理偏好域与临时数据，不关闭既有 App。无法确认退出时返回失败并报告保留目录。默认结果包也会清理；需要保留诊断时显式指定 `task test -- -resultBundlePath "/tmp/Modu Tests.xcresult"`。

执行成功还要求结果包中至少有一个实际运行的用例，全跳过或筛选无匹配均返回失败。Swift Testing 的方法标识包含括号，例如：

```bash
task test 'TEST_FILTER=ModuDesktopTests/WorkspaceLoadingTests/startupDoesNotReinitializeWorkspaceWhenRecordIsMissing(_:)'
```

可先用 `task test -- -enumerate-tests` 查看实际标识；该命令只枚举，不执行用例，因此跳过零用例检查。

## CI 与发布

[macOS CI](../.github/workflows/ci.yml) 在 `main` 分支 push、`v*` tag push、所有 PR 和手动运行时执行。需要仓库启用 GitHub Actions，无需配置 Secrets。

使用 [GitHub 的 `macos-26` runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) 和 [预装 Xcode 26.6](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)，通过官方 `go-task/setup-task` 安装 Task 3.48.0，按 `Package.resolved` 下载依赖：

CI 不执行单元测试或 UI 测试；需要时在本地运行 `task test` 或 `task test:ui`。

1. 通过 `task package` 调用 [打包脚本](../script/package_app.sh) 构建 Release App，App 和内嵌 `modu-cli` 都仅包含 `arm64`，面向 Apple Silicon。
2. 检查 App、CLI、内置 skill、架构与 ad-hoc 签名，并检查 CLI `--version` 与 App 版本一致。
3. 用系统 `hdiutil` 生成并校验 `Modu-<版本号>-arm64.dmg`，版本号取自构建后 App 的 `CFBundleShortVersionString`（由工程的 `MARKETING_VERSION` 生成），内含 `Modu.app` 和指向 Applications 的快捷方式；上传 DMG，保留 14 天。CI 的 Actions 产物名称、Release 下载和发布均沿用打包脚本生成的文件名。
4. `v*` tag push 触发的运行在打包成功后创建 GitHub Release，上传同一次运行的 DMG，并自动生成发布说明。独立的发布 job 使用 GitHub 自带 token 与 `contents: write` 权限。

在 GitHub 仓库的 **Actions → macOS CI → 对应运行 → Artifacts** 下载 DMG；打开后将 `Modu.app` 拖到 Applications。仅支持 Apple Silicon，最低系统版本沿用工程设置，当前为 **macOS 26.5**。

这是测试包，采用无需证书的 ad-hoc 签名，未做 Developer ID 签名或 Apple 公证，下载后可能需要在系统设置的“隐私与安全性”中允许打开。正式签名、公证和自动升级不在当前 [PRD 范围](PRD.md)；后续正式签名分发需提供 Developer ID Application 证书、私钥和公证凭据。GitHub Release 发布不会改变安装包的签名状态。

版本号和构建号只在 [Version.xcconfig](../Version.xcconfig) 中配置：`MARKETING_VERSION` 使用「主版本.次版本.修订版本」三段格式，例如 `1.0.0`；`CURRENT_PROJECT_VERSION` 是独立的构建号，例如 `1`，用于区分同一产品版本的不同构建。两个值都需手动更新，不会自动递增。

Xcode 的所有 target 与 Debug/Release 配置都继承它，构建时自动在 DerivedData 中生成 ModuCore 的 `ModuVersion` 常量。App 元数据、CLI `--version`、Application Support 下的 `versions/<版本号>/modu-cli` 安装目录和 DMG 文件名都从这里获取产品版本；修改构建号不会改变 CLI 版本、安装目录和 DMG 文件名，生成文件无需手动维护。

发布版本前，先更新该配置，将改动提交并推送到 `main`。在要发布的提交上，按配置中的产品版本创建并推送 tag：

```bash
release_version="$(sed -n 's/^MARKETING_VERSION = //p' Version.xcconfig)"
git tag "v$release_version"
git push origin "v$release_version"
```

成功后从仓库的 **Releases → 对应版本 → Assets** 下载 DMG。普通分支 push、PR 和手动运行只生成 Actions 产物；tag 不修改内部版本号，以 `Version.xcconfig` 为准。

每个版本 tag 只发布一次；已发布版本再次运行创建 Release 会失败，发布新版本时使用新 tag。

本地打包从仓库根目录运行：

```bash
task package
```

产物为 `build/package/Modu-<版本号>-arm64.dmg`，例如当前工程版本对应 `Modu-1.0.0-arm64.dmg`。可通过 `MODU_PACKAGE_DIR` 指定产物目录，通过 `MODU_DERIVED_DATA_PATH` 指定 Xcode 构建目录；CI 复用同一脚本。

## 构建与启动

[Codex 环境配置](../.codex/environments/environment.toml) 提供以下 Actions，统一调用 Task 任务，再复用 [构建与运行脚本](../script/build_and_run.sh)。mock 场景提供独立启动入口。

“开发版”指 Xcode 的 `Debug` 构建配置；`task package` 使用 `Release` 构建配置生成发布包。进入 LLDB 调试器使用 `task debug`。

| 命令 | 用途 | Codex Action |
| --- | --- | --- |
| `task run` | 构建并启动开发版 App | Modu Run |
| `task mock` | 并行构建开发版 App 与生成临时 Git 场景，完成后启动 | Modu Mock |
| `task verify` | 构建开发版 App 并验证本次实例启动，输出 PID 后保持运行 | Modu Verify |
| `task debug` | 构建开发版 App 并进入 LLDB 调试器，输入 `run` 启动 | Modu Debug |
| `task logs` | 构建并启动开发版 App，持续查看 Modu 进程日志 | Modu Logs |
| `task telemetry` | 构建并启动开发版 App，持续查看 `fun.armantang.ModuDesktop` subsystem 的统一日志 | Modu Telemetry |

Logs 与 Telemetry 可用终端的 Ctrl-C 停止日志流，App 继续运行。`task verify` 通过 [实例验证脚本](../script/verify_app.swift) 启动独立实例，输出该实例的 PID，检查完成 App 启动后保持运行；保留验证前已运行的实例，启动失败返回非零结果。验证只检查 App 启动，不代表工作区准备完成或行为测试通过。

临时 Git 场景可运行 `task mock`；组合 `task verify -- --mock linked-worktree-selected` 也保持本次开发版实例运行。`task debug`、`task logs`、`task telemetry` 同样可在 `--` 后传入 mock 参数。[生成脚本](../script/prepare_mock_workspace.py) 与 Debug 构建并行，两项都成功后才启动 App，并通过 `--mock-workspace <root>` 传入临时工作区。App 只校验、加载已准备的数据并显示 `feature-store-pickup/order-service` 的成员详情，完整数据见 [Debug mock 场景与数据](MOCK.md)；刷新和侧栏切换读取临时 Git 数据，外部工具真实打开临时目录。可在本次临时工作区验证仓库、Group、成员管理及 YAML 导入导出；Setup、工作区创建与切换同样可验证，工作区、CLI 安装及导出文件均限制在本次临时目录内。构建或生成失败、取消时停止本次辅助进程并清理数据；App 正常退出时清理本次临时目录与配置，不关闭已运行的普通 App。Release 不支持 mock。

验证完成、中断或退出 LLDB 后，脚本核对可执行路径与本次 `--mock-workspace` 参数；本次实例仍在运行时输出 PID、保留目录，继续按下述流程主动退出。LLDB 未执行 `run` 就退出、启动失败或目标已结束时，清理本次目录。进程状态无法确认时报告并保留数据，不自动退出验证实例或清理其他会话。

## Agent 开发验证流程

由 Agent 启动的临时 App、日志流、调试器和测试辅助进程，由 Agent 在检查结束后主动收尾。脚本返回、测试结束或停止日志流不代表对应 App 已退出；不得通过启动后自动退出代替实际检查与收尾。

1. 启动前记录已有实例的 PID、可执行路径、参数和启动时间，以及已有临时目录；启动后记录本次实际生成的临时目录、偏好配置域及辅助进程。优先使用 mock 或隔离的临时配置，不访问真实工作区。
2. 运行 `task verify`（可组合 mock），保存输出中的 `App instance PID`，例如记为 `modu_pid`。其他启动方式按启动前后差异、可执行路径、参数和启动时间确认本次实例，不能仅按进程名判断归属。不带 mock 的 Run、Logs、Telemetry、Debug 在构建前会按进程名停止已有 App，有已有实例时避免用这些入口开展临时验证。
3. 根据改动完成相关检查；检查 mock 行为时先确认夹具已准备完成。需要日志或调试时记录本次会话，停止日志流后仍需退出对应 App；被调试器暂停的 App 应先恢复执行，以便完成正常退出。
4. 检查结束后，对已确认属于本次验证的 Modu PID 显式运行以下命令，请求正常退出并等待退出完成。该命令不会构建或启动 App，也不会按进程名批量退出；用户明确要求保留的实例除外。

   ```bash
   task quit PID="$modu_pid"
   ```

5. 再检查该 PID 已结束，以及本次临时仓库、worktree、配置和一次性日志已清理。mock 正常退出会清理本次目录及偏好域；其他临时数据由 Agent 清理。停止自己启动的辅助进程，不关闭既有或共享的外部工具。不按目录前缀批量删除，也不删除共享构建缓存或来源不明的数据。
6. 检查失败、中断或需要切换任务时同样执行收尾，测试和自动化脚本应使用 `defer`、`finally` 或同等机制覆盖失败路径。正常退出失败时核实 PID 身份，必要时仅定向终止本次进程，再清理确认属于本次验证的数据。交付前报告验证结果和退出、清理结果；未确认完成的收尾应明确说明，不能把“已请求退出”当作“已退出”。
