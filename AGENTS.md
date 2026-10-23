# Agent Instructions

## 业务边界

- 工作区根目录是 Git 主工作树，Group 根目录及成员分别是工作区仓库和所选业务仓库的 linked worktree。
- Git Browser 查看更改与提交，业务开发、提交和合并通过外部工具完成；Modu 会按需自动提交工作区的 `.gitignore` 和内置工作流文件。
- 取消或部分失败可能保留已完成的效果；反馈区分已完成、未完成和保留数据，不承诺整体回滚。

## 目录结构

```text
.
├── .agents/skills/               # 仓库开发流程（版本更新等）
├── .codex/environments/          # Codex 本地任务入口配置
├── .github/workflows/            # GitHub CI 与发布流程
├── build/                        # 本地打包产物（生成后存在，Git 忽略）
├── ModuCLI/                      # modu-cli 入口与参数解析
│   ├── Commands/                 # 工作区、仓库与分组命令
│   └── Support/                  # 公共选项、输出与参数归一化
├── ModuCore/                     # App 与 CLI 共享的业务
│   ├── Models/                   # 领域记录、资源标识与操作结果
│   ├── Workflows/                # 工作区、仓库、分组与 YAML 用例
│   ├── Infrastructure/           # Git、进程、文件系统、持久化与安装
│   └── Debug/                    # 隔离 Git 场景支持
├── ModuDesktop/                  # macOS App
│   ├── App/                      # 依赖组装、启动、命令与全局操作协调
│   ├── Features/                 # 各功能的状态模型与界面
│   ├── Platform/                 # AppKit 桥接与外部工具
│   ├── SharedUI/                 # 通用组件、样式与文案格式化
│   ├── AppIcon.icon/             # App 图标源文件
│   ├── Assets.xcassets/          # 界面图标与颜色资源
│   └── Resources/modu-workflow/  # 随 App 分发的工作流提示词与调用策略
├── ModuDesktop.xcodeproj/        # Xcode target、scheme 与依赖配置
├── ModuDesktopTests/             # 单元、Git 集成与 CLI 测试及夹具
├── script/                       # 构建、启动、测试、打包与临时场景脚本
├── Taskfile.yml                  # 本地开发命令入口
└── Version.xcconfig              # 产品版本与构建号
```

## 工程约定

- 修改前阅读相关实现与必要测试；业务规则、数据格式和命令参数以代码为准。
- `ModuDesktop` 与 `ModuCLI` 复用 `ModuCore`，Core 不依赖界面，业务与副作用放在 Core，View 只渲染状态与转发意图；保持现有 target 边界，不新增 framework/package。
- `AppModel` 负责依赖组装、启动、工作区切换、外部工具与退出协调；功能状态放在 `Features/` 下的模型中。
- 界面状态运行在 `@MainActor`，异步任务支持取消，发布结果前检查生命周期标识和当前功能上下文。
- Git 与外部命令复用 [CommandRunner.swift](ModuCore/Infrastructure/Process/CommandRunner.swift)。
- 界面沿用现有 SwiftUI/AppKit 组件、系统语义字体和材质；资源维护在 App 资源目录中。
- 产品版本与构建号只改 `Version.xcconfig`，不修改生成的 `ModuVersion`；工作区 YAML、CLI JSON schema 与依赖版本独立维护。

## 验证与交付

- 交付前 review 最终 diff，检查业务正确性、边界条件、错误与取消处理、异步上下文；一般功能改动不自动要求新增测试或运行全量测试。
- 测试仅保护核心业务、用户数据、关键失败与取消路径、对外契约及难以 review 的并发；仅在明确回归风险且现有覆盖不足时补充用例。
- 优先复用或调整现有用例，从最小相关范围运行；跨流程改动、失败或未解决风险时再扩大。
- 不为文案样式、简单映射、实现细节或覆盖率补测试；可合并或移除重复、过时和低价值用例。
- 测试使用临时目录、本地 bare remote 和可控替身，不访问真实网络或用户仓库。
- 不引入 UI 测试 target 或持久化 UI 自动化用例。
- 交付时报告 review 结论、实际检查及收尾结果，未完成项说明原因。

## 关键风险

- 不带 mock 的 run、debug、logs、telemetry 会先停止已有 Modu 实例。
- Debug 偏好独立，但与正式版共享工作区数据、锁和 CLI；临时验证优先使用 mock 隔离。
- 启动验证只确认 App 完成启动，不代表工作区加载或界面行为已通过验证。
- 临时验证须确认本次实例退出并清理本次数据与辅助进程，失败或中断也适用；用户要求保留的实例除外。
- 只处理确认归属本次验证的进程与数据；禁止按进程名批量退出、按目录前缀清理或清理既有实例、共享缓存与外部工具。
- 推送 `v*` tag 会触发 CI 发布流程。

## 按需读取

- 执行下列任务前读取对应章节，只展开当前任务需要的细则。

| 任务 | 入口 |
| --- | --- |
| 产品与使用方式 | [README.md](README.md) |
| 调整功能模型或异步协调 | [功能模型与异步协调](DEVELOPMENT.md#功能模型与异步协调) |
| 构建、启动或调试 App | [构建启动与调试](DEVELOPMENT.md#构建启动与调试)、[临时实例收尾](DEVELOPMENT.md#临时实例收尾) |
| 运行测试或诊断失败 | [测试执行与诊断](DEVELOPMENT.md#测试执行与诊断) |
| 退出或清理临时实例 | [临时实例收尾](DEVELOPMENT.md#临时实例收尾) |
| 修改版本、打包或发布 | [版本打包与发布](DEVELOPMENT.md#版本打包与发布) |
| 修改文档或提示词 | [文档与提示词维护](DEVELOPMENT.md#文档与提示词维护) |
