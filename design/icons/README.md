# Git 文件状态图标

从 [Modu 设计稿的 Components/Icons](https://www.figma.com/design/eK0CqTm1y4jk6thzqBdUV5/Modu-Desktop?node-id=229-324) 导出，源文件与应用资源保持一致。

| 状态 | Figma 节点 | SVG 源文件 | 应用资源名称 |
| --- | --- | --- | --- |
| Added | [109:174](https://www.figma.com/design/eK0CqTm1y4jk6thzqBdUV5/Modu-Desktop?node-id=109-174) | [git-status-added.svg](svg/git-status-added.svg) | `GitFileStatus/Added` |
| Moved | [109:179](https://www.figma.com/design/eK0CqTm1y4jk6thzqBdUV5/Modu-Desktop?node-id=109-179) | [git-status-moved.svg](svg/git-status-moved.svg) | `GitFileStatus/Moved` |
| Modified | [109:184](https://www.figma.com/design/eK0CqTm1y4jk6thzqBdUV5/Modu-Desktop?node-id=109-184) | [git-status-modified.svg](svg/git-status-modified.svg) | `GitFileStatus/Modified` |
| Deleted | [109:189](https://www.figma.com/design/eK0CqTm1y4jk6thzqBdUV5/Modu-Desktop?node-id=109-189) | [git-status-deleted.svg](svg/git-status-deleted.svg) | `GitFileStatus/Deleted` |

应用资源位于 [GitFileStatus](../../ModuDesktop/Assets.xcassets/GitFileStatus)，使用原色渲染并保留矢量数据。画布为 16×16，背景透明，Modified 的 M 已转为路径，不依赖字体文件。

这些导出保留 Figma 原始浅色配色，尚不包含深色或提高对比度变体。接入 Changes 界面时，按 [DESIGN 第 5.1 节](../../docs/DESIGN.md#51-changes) 完成外观适配与对比度验收。

## 界面图标

[DesignIcons](../../ModuDesktop/Assets.xcassets/DesignIcons) 使用 Figma MCP 从 [主窗口](https://www.figma.com/design/eK0CqTm1y4jk6thzqBdUV5/Modu-Desktop?node-id=62-76)、[工作树详情](https://www.figma.com/design/eK0CqTm1y4jk6thzqBdUV5/Modu-Desktop?node-id=65-301)、[编辑分组](https://www.figma.com/design/eK0CqTm1y4jk6thzqBdUV5/Modu-Desktop?node-id=845-7522) 和 [首次设置](https://www.figma.com/design/eK0CqTm1y4jk6thzqBdUV5/Modu-Desktop?node-id=765-3966) 返回的原始素材。SVG 保留原画布和矢量内容；Finder 使用原始 PNG。

- FolderOpen / FolderGit / FolderGroup / FolderClosed：16×16。
- Plus / Update：16×16；Disclosure：10×6，放在 16×16 命中区域；Chevron：18×18。
- Update 使用 [Icon/Action/Fetch（243:339）](https://www.figma.com/design/eK0CqTm1y4jk6thzqBdUV5/Modu-Desktop?node-id=243-339) 的原始 Glyph/Refresh Clockwise SVG，居中放在 24×24 按钮区域，位于 Add 左侧。
- Cancel 使用 [Icon/Action/Cancel（1362:4644）](https://www.figma.com/design/eK0CqTm1y4jk6thzqBdUV5/Modu-Desktop?node-id=1362-4644) 的原始 SVG，20×20，保留原色，用于标题栏取消更新。
- BaseBranch / HeadBranch / Warning / Unset / Success：20×20。
- CommitLane：24×84，按首行、中间行、末行裁切复用，适应真实提交数量。

Plus、Update 与 chevron 使用 template 渲染以跟随外观，其余保留原色。工具启动图标继续复用 ToolIcons 资源。
