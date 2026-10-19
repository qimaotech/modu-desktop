# Modu

Modu 是管理多仓库和跨仓库 Git worktree 的 macOS 原生工具。通过 Worktree Group，把同一开发任务涉及的多个仓库组织在一起，在不同任务之间切换。

## 主要功能

- 管理工作区中的多个 Git 仓库，支持批量添加与更新。
- 创建、编辑和删除跨仓库的 Worktree Group。
- 查看工作树更改与提交，在 Agent、编辑器、终端或 Git 工具中打开当前目录。
- 通过 YAML 导入导出工作区结构，支持中文与英文界面。
- 使用配套的 `modu-cli` 和工作流 skill 管理工作区。

## 开始使用

当前安装包适用于 Apple Silicon Mac。已发布版本可从本仓库的 Releases 下载，也可从 GitHub Actions 的构建产物获取 DMG；打开后将 `Modu.app` 拖入 Applications。系统要求见对应发布说明。

当前为测试包，采用 ad-hoc 签名，尚未做 Developer ID 签名与 Apple 公证。

若 App 因下载隔离标记而无法打开，确认安装包来源可信后，可在终端运行以下命令移除隔离标记，再重新打开 Modu：

```bash
xattr -dr com.apple.quarantine /Applications/Modu.app
```

1. 启动 Modu，按引导安装 CLI 并选择工作区目录。
2. 添加需要协作开发的 Git 仓库。
3. 创建 Worktree Group，选择本次任务涉及的仓库。
4. 在外部开发工具中打开分组或成员目录，完成开发后清理不再需要的分组。

命令行用法查看 `modu-cli --help` 及各子命令的 `--help`。从工作区根目录启动 Codex，通过 `$modu-workflow` 手动调用随工作区安装的工作流 skill。
