# Agent Instructions

## 业务边界

- 工作区根目录是工作区仓库的主工作树；分组根工作树和成员工作树分别是工作区仓库和所选业务仓库的关联工作树。
- Git Browser 查看本地更改、独有提交和落后提交，业务开发、提交和合并通过外部工具完成；MonoDeck 会按需自动提交工作区的 `.gitignore` 和内置工作流文件。
- 取消或部分失败可能保留已完成的效果；反馈区分已完成、未完成和保留数据，不承诺整体回滚。

## 目录结构

| 入口 | 内容 |
| --- | --- |
| [MonoDeckCore/](MonoDeckCore/) | App 与 CLI 共享的领域模型、业务流程和基础设施 |
| [MonoDeck/](MonoDeck/) | App 协调、功能模型与界面、平台适配及资源 |
| [MonoDeckCLI/](MonoDeckCLI/) | CLI 命令与参数解析 |
| [MonoDeckTests/](MonoDeckTests/) | 单元、Git 集成与 CLI 测试及夹具 |
| [Taskfile.yml](Taskfile.yml)、[script/](script/) | 构建、启动、测试、打包与临时场景入口 |

## 工程约定

- Before implementing business logic, consult [GLOSSARY.md](GLOSSARY.md) for domain terminology and semantics. If a new business concept is introduced, propose an update to GLOSSARY.md.
- 修改前阅读相关实现与必要测试；业务规则、数据格式和命令参数以代码为准。
- `MonoDeck` 与 `MonoDeckCLI` 复用 `MonoDeckCore`，Core 不依赖界面，业务与副作用放在 Core，View 只渲染状态与转发意图；保持现有 target 边界，不新增 framework/package。
- `AppModel` 负责依赖组装、启动、工作区切换、外部工具与退出协调；功能状态放在 `Features/` 下的模型中。
- 界面状态运行在 `@MainActor`，异步任务支持取消，发布结果前检查生命周期标识和当前功能上下文。
- Git 与外部命令复用 [CommandRunner.swift](MonoDeckCore/Infrastructure/Process/CommandRunner.swift)。
- 界面沿用现有 SwiftUI/AppKit 组件、系统语义字体和材质；资源维护在 App 资源目录中。
- 产品版本与构建号只改 `Version.xcconfig`，不修改生成的 `MonoDeckVersion`；工作区 YAML、CLI JSON schema 与依赖版本独立维护。

## 验证与交付

- 交付前 review 最终 diff，检查业务正确性、边界条件、错误与取消处理、异步上下文，以及相关代码和文档是否需同步。
- 测试仅保护核心业务、用户数据、关键失败与取消路径、对外契约及难以 review 的并发；仅在明确回归风险且现有覆盖不足时补充用例。
- 一般功能改动不自动要求新增测试或运行全量测试；优先复用或调整现有用例，从最小相关范围运行，跨流程改动、失败或未解决风险时再扩大。
- 不为文案样式、简单映射、实现细节或覆盖率补测试；可合并或移除重复、过时和低价值用例。
- 测试使用临时目录、本地 bare remote 和可控替身，不访问真实网络或用户仓库。
- 不引入 UI 测试 target 或持久化 UI 自动化用例。
- 交付时报告 review 结论、实际检查及收尾结果，未完成项说明原因。

## 关键风险

- 不带 mock 的 run、debug、logs、telemetry 会先停止已有 MonoDeck 实例；Debug 虽有独立偏好，但与正式版共享工作区数据、锁和 CLI，临时验证优先使用 mock 隔离。
- 临时验证须确认本次实例退出并清理本次数据与辅助进程，失败或中断也适用；用户要求保留的实例除外。
- 只处理确认归属本次验证的进程与数据；禁止按进程名批量退出、按目录前缀清理或清理既有实例、共享缓存与外部工具。
- 推送 `v*` tag 会触发 CI 发布；授权边界见[版本打包与发布](DEVELOPMENT.md#版本打包与发布)。

## 按需读取

- 执行下列任务前读取对应章节，只展开当前任务需要的细则。

| 任务 | 入口 |
| --- | --- |
| 产品与使用方式 | [README.md](README.md) |
| 调整功能模型或异步协调 | [模型职责与生命周期](DEVELOPMENT.md#模型职责与生命周期) |
| 调整 Git 读取、调度或缓存 | [Git 读取与缓存](DEVELOPMENT.md#git-读取与缓存) |
| 调整工作区加载、启动或引导 | [工作区加载与维护](DEVELOPMENT.md#工作区加载与维护)、[启动与设置](DEVELOPMENT.md#启动与设置) |
| 调整自动更新 | [自动更新](DEVELOPMENT.md#自动更新) |
| 构建、启动或调试 App | [构建启动与调试](DEVELOPMENT.md#构建启动与调试)、[临时实例收尾](DEVELOPMENT.md#临时实例收尾) |
| 运行测试或诊断失败 | [测试执行与诊断](DEVELOPMENT.md#测试执行与诊断) |
| 退出或清理临时实例 | [临时实例收尾](DEVELOPMENT.md#临时实例收尾) |
| 修改版本、打包或发布 | [版本打包与发布](DEVELOPMENT.md#版本打包与发布) |
| 修改文档或提示词 | [文档与提示词维护](DEVELOPMENT.md#文档与提示词维护) |
