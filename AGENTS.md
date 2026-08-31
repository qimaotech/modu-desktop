# Modu Desktop Agent Guide

Modu Desktop 是管理多仓库与跨仓库 linked worktree 的 macOS 原生工具。它负责受管工作区生命周期和外部工具启动，不替代 Agent、Git GUI、编辑器或终端。

## 任务路由与事实源

- 产品范围、数据模型、生命周期、业务/安全规则和验收以 [`docs/PRD.md`](docs/PRD.md) 为准。
- 信息架构、用户可见交互、视觉、文案、可访问性和原型索引以 [`docs/DESIGN.md`](docs/DESIGN.md) 为准。
- [`design/prototypes/`](design/prototypes/) 只提供代表性视觉证据；未出图状态仍按 PRD/DESIGN 实现，不从截图反推新规则。
- 行为、数据或安全改动先读 PRD 相关章节；UI 改动再读 DESIGN 相关流程和原型。只读取任务需要的章节。
- 事实源、原型与实现冲突时不得静默择一：先确认正确规则并修正所属事实源，再同步受影响内容。
- 业务/安全规则只写入 PRD，交互/视觉规则只写入 DESIGN；其他文件链接引用，不复制完整规则。只有仓库级 Agent 协议或架构护栏变化才修改本文件。

## 实现边界

- App 与 CLI 共享 `ModuCore` 中的配置、Git、文件系统、worktree 和外部工具逻辑，不分别实现同一规则。
- SwiftUI View 只渲染状态并转发意图；Git、进程、文件系统和 YAML 副作用属于 Core 服务。
- `AppModel` 与界面状态运行在 `@MainActor`；耗时任务使用结构化并发，支持取消并丢弃过期 generation 的结果。
- 外部命令使用可执行文件与参数数组，禁止拼接未经转义的 shell 字符串；系统副作用通过可替换协议隔离。

## 不可违反的安全护栏

- 文件、Git 与清理副作用只作用于规范化后位于当前工作区 `repositories/` 或 `worktrees/` 下的受管后代；拒绝路径逃逸、异常符号链接、工作区根和受管根。
- 配置编辑或计划生成不构成删除授权。声明式 cleanup 必须展示并确认当前计划；主仓库移入 macOS Trash，强制 worktree 删除只用于 PRD 明确定义并已授权的流程。
- 身份、路径、配置或风险无法可靠读取时不得猜测为不存在、clean 或安全；按 PRD 冻结对应能力或转为 conflict。
- YAML 写入必须加锁、同目录生成候选文件、校验并原子替换；`.modu.yaml` 的 GUI 修改还须保留未改动条目的顺序和注释。App 与 CLI 遵循 PRD 的跨进程锁与统一锁顺序。
- 日志、JSON 与用户可见错误不得泄露带凭据 URL、敏感环境变量或未经整理的完整 Git 输出。

## UI 实现

- UI 以 DESIGN 的信息与密度规则为约束，优先使用 macOS 26 原生 SwiftUI/AppKit 控件、系统语义字体、system monospaced font、系统材质与 SF Symbols；不逐像素复制 Figma。
- 核心流程支持键盘、VoiceOver、浅色/深色、提高对比度和减少透明度；状态不能只依赖颜色。

## 验证与交付

- 行为变化增加与风险匹配的 Core 单元测试或本地 Git 集成测试；测试使用临时目录和本地 bare remote，不访问真实网络或用户仓库。
- 代码统一通过 `./script/build_and_run.sh --verify` 验证；按需使用 `--debug`、`--logs` 或 `--telemetry` 定位问题。
- 仅修改文档或设计资产时，校验交叉引用、原型索引、文案一致性和 `git diff --check`，不运行无关代码测试。
- 不提交 DerivedData、生成目录、临时工作区、真实仓库数据或凭据。
