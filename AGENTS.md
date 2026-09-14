# Modu Desktop 项目指引

Modu Desktop 是 SwiftUI/AppKit macOS 工具。产品与界面规则集中在文档中，本文件只保留开发入口和工程约定。

## 按任务读取

- 修改功能、数据或安全行为前，阅读 [PRD](docs/PRD.md) 的相关章节。
- 修改界面、交互或文案前，再阅读 [DESIGN](docs/DESIGN.md) 的对应流程和原型索引。[原型](design/prototypes/) 只作视觉参考，不定义业务规则。
- 规则冲突先修正所属文档，再同步实现与设计资产；不要在本文件复制业务逻辑。

## 工程约定

- App 入口在 [ModuDesktop](ModuDesktop/)，CLI 在 [ModuCLI](ModuCLI/)，测试在 [ModuDesktopTests](ModuDesktopTests/) 和 [ModuDesktopUITests](ModuDesktopUITests/)。
- 按 PRD 的架构约定建设共享 ModuCore；App/CLI 保持薄入口，View 只渲染状态、转发意图，副作用放在 Core。
- AppModel 和界面状态运行在 `@MainActor`；耗时任务使用结构化并发、支持取消，异步界面结果检查当前上下文，避免过期结果覆盖。
- 外部命令使用可执行文件与参数数组，不拼接未经转义的 shell 文本。
- UI 优先使用原生控件、系统语义字体与材质，具体布局和无障碍要求见 DESIGN。

## 验证与交付

- 从仓库根目录运行 `./script/build_and_run.sh --verify` 验证代码改动；该脚本只检查构建与进程启动，行为变化另运行相关测试。可用 `--debug`、`--logs`、`--telemetry` 辅助定位。
- 测试使用临时目录、本地 bare remote 和可控替身，不访问真实网络或用户仓库；按 PRD 的验收范围选择测试。
- 纯文档或设计资产变更检查交叉引用、原型索引、文案一致性和 `git diff --check`，不运行无关代码测试。
- 不提交 DerivedData、临时工作区、真实仓库数据或凭据。
