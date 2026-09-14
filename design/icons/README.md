# Git 文件状态图标

从 [Modu Desktop 的 Components/Icons](https://www.figma.com/design/eK0CqTm1y4jk6thzqBdUV5/Modu-Desktop?node-id=229-324) 导出，源文件与应用资源保持一致。

| 状态 | Figma 节点 | SVG 源文件 | 应用资源名称 |
| --- | --- | --- | --- |
| Added | [109:174](https://www.figma.com/design/eK0CqTm1y4jk6thzqBdUV5/Modu-Desktop?node-id=109-174) | [git-status-added.svg](svg/git-status-added.svg) | `GitFileStatus/Added` |
| Moved | [109:179](https://www.figma.com/design/eK0CqTm1y4jk6thzqBdUV5/Modu-Desktop?node-id=109-179) | [git-status-moved.svg](svg/git-status-moved.svg) | `GitFileStatus/Moved` |
| Modified | [109:184](https://www.figma.com/design/eK0CqTm1y4jk6thzqBdUV5/Modu-Desktop?node-id=109-184) | [git-status-modified.svg](svg/git-status-modified.svg) | `GitFileStatus/Modified` |
| Deleted | [109:189](https://www.figma.com/design/eK0CqTm1y4jk6thzqBdUV5/Modu-Desktop?node-id=109-189) | [git-status-deleted.svg](svg/git-status-deleted.svg) | `GitFileStatus/Deleted` |

应用资源位于 [GitFileStatus](../../ModuDesktop/Assets.xcassets/GitFileStatus)，使用原色渲染并保留矢量数据。画布为 16×16，背景透明，Modified 的 M 已转为路径，不依赖字体文件。

这些导出保留 Figma 原始浅色配色，尚不包含深色或提高对比度变体。接入 Changes 界面时，按 [DESIGN 第 5.1 节](../../docs/DESIGN.md#51-changes) 完成外观适配与对比度验收。
