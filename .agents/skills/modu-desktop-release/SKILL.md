---
name: modu-desktop-release
description: 仅在用户显式调用 $modu-desktop-release 时，更新 Modu Desktop 版本与 CHANGELOG，创建本地版本提交和 Git tag。
---

# Modu Desktop Release

在 Modu 源码仓库根目录执行。先阅读 `AGENTS.md`、`docs/DEVELOPMENT.md` 的「打包与发布」、`Version.xcconfig` 和 `.github/workflows/ci.yml`，以当前实现为准。

`Version.xcconfig` 同时驱动 App 的 Info.plist、Core 生成的 `ModuVersion` 和 CLI 的 `--version`，CLI 安装目录与 DMG 文件名也随产品版本生成。只更新配置中的产品版本与构建号；工作区 YAML 的 `version`、CLI JSON 的 `schema-version` 和依赖版本不随产品版本变更。

用户手动调用此 skill 执行完整版本更新流程时，授权范围包含暂存并提交 `Version.xcconfig`、`CHANGELOG.md`，以及创建对应的本地 tag。只要求查看或修改 skill 时，不执行版本更新。推送分支、推送 tag 和创建 GitHub Release 不在此流程内；推送 `v*` tag 会触发 CI 发布。

## 1. 确认工作区干净

- 使用 `git status --porcelain=v1 --untracked-files=all` 检查暂存、未暂存和未跟踪文件；输出必须为空。有任何改动就列出并停止，不自动提交、stash、丢弃或清理。
- 确认当前处于待发布分支，且没有进行中的 merge、rebase 等操作；记录分支和起始 HEAD。后续操作始终针对这个仓库，不操作 Modu 管理的其他仓库或 worktree。

## 2. 确认版本号并更新配置

- 列出本地 tag，取符合 `vX.Y.Z` 的正式版本中语义版本号最大的 tag 为比较基线，不按 tag 创建时间排序。确认该 tag 是起始 HEAD 的祖先；若不属于当前历史，先说明情况并等待用户确定基线。没有发布 tag 时，说明这是首次发布，使用截至起始 HEAD 的全部历史。
- 阅读基线到起始 HEAD 的提交记录、差异统计和相关实际 diff，例如 `git log <tag>..<head>`、`git diff --stat <tag> <head>` 与 `git diff <tag> <head> -- <相关路径>`。根据最终行为归纳改动，不仅凭提交标题判断。
- 用户指定 `version` 时直接采用，允许去掉输入中的一个 `v` 前缀。发布流程约定产品版本使用无前导零的三段非负整数 `X.Y.Z`，构建号使用递增整数；底层生成脚本允许一到三段纯数字，但不支持预发布或构建元数据后缀。目标版本必须高于基线版本，且不能低于当前 `MARKETING_VERSION`；当前配置已等于尚未打 tag 的目标版本时可继续。对应 `vX.Y.Z` tag 必须不存在，禁止覆盖或移动已有 tag。
- 用户未指定版本时，根据实际改动给出推荐版本、理由及合理备选：兼容的修复用 patch，兼容的新功能用 minor，不兼容的行为或接口变化用 major。以最新 tag 为递增基准，同时考虑当前配置，避免建议降级。必须让用户选择并等待回复；未收到选择前不改文件、不提交、不打 tag。
- 版本确定后，重新确认工作区仍干净、分支和 HEAD 未变；若上下文变化，停止并重新评估。更新 `MARKETING_VERSION`，将当前整数 `CURRENT_PROJECT_VERSION` 加一且不重置；构建号格式不符合这一规则时先说明并确认处理方式。保留其他配置和格式，不修改生成的版本源码或 Xcode 工程中的其他字段。

## 3. 更新 CHANGELOG.md

- 发布章节统一使用 `## [X.Y.Z] - YYYY-MM-DD`，日期取用户本地日期；正文沿用已有语言和分类，新版本放在 Unreleased（若有）之后、历史版本之前。文件不存在时创建以 `# Changelog` 开头的 `CHANGELOG.md`。
- 仅记录比较范围内已完成的实际改动，以用户可感知的行为变化及使用、升级决策所需信息为收录标准。收录新增、修复、交互变化，以及有实际依据的性能、稳定性、资源占用改善和安全性变化；不得将内部重构或依赖升级推断为未经证实的收益。
- 默认不记录纯内部重构、测试、CI、开发工具及无用户影响的依赖、文档或 skill 调整；这些改动若产生明确的用户影响，只描述其影响。根据实际 diff 判断，不按 `feat`、`fix`、`chore` 等提交类型机械过滤。
- 用简明中文描述使用场景和变化结果，合并重复项，不照搬提交列表或罗列实现细节，不编造功能或测试结果。突出安装、升级及兼容性变化，尤其是 CLI 参数、JSON 输出、工作区 YAML 和最低 macOS 版本的变化；需要用户操作时写明迁移或处理步骤。
- 若比较范围内只有内部维护、没有用户可感知变化，可仅写“本版本仅包含内部维护，无用户可感知变化。”，满足章节非空要求，不为填充更新日志编造改进。
- 保留历史版本内容；有 Unreleased 条目时，只将属于本次发布的条目整理到新版本，保留尚未发布的内容。发现同版本条目时先核对来源，避免重复插入。
- 更新后运行 `python3 script/release_notes.py v<version>`，检查 tag 与产品版本一致、对应章节唯一且内容非空，并预览提取的变更说明；失败时先修正，不提交、不创建 tag。CI 复用此脚本，将该章节与安装包说明组合为 GitHub Release 正文；无需另写一份发布说明。此时只完成本地准备，推送 tag 后 CI 才会发布。

## 4. 提交并创建 tag

- 展示目标版本、构建号变化、CHANGELOG 摘要及拟创建的 tag。用户已经指定或选择版本，且已要求执行完整流程时，继续执行，不重复索取暂存、提交和创建本地 tag 的授权。
- 运行 `git diff --check` 并检查两份文件的完整差异。确认分支和 HEAD 仍与起始值一致、tag 仍不存在、工作区仅有这两份文件的预期改动；出现额外改动立即停止。
- 提交前运行 `task test TEST_FILTER=ModuDesktopTests/VersionTests`，复用现有测试验证 App 产品版本、构建号和内置 CLI 产品版本一致；检查测试环境已按 `run_tests.py` 的流程退出和清理。测试或清理失败时停止，不提交、不创建 tag。
- 仅运行 `git add -- Version.xcconfig CHANGELOG.md` 暂存目标文件，再用 `git diff --cached --check`、`git diff --cached --name-only` 和暂存差异确认提交恰好包含这两份文件。不要使用 `git add .` 或 `git commit -a`。
- 根据最近五条提交的语言使用 Conventional Commits 提交信息，例如 `chore(release): vX.Y.Z`。提交后核实新提交的父节点是起始 HEAD，且实际变更文件只有 `Version.xcconfig` 和 `CHANGELOG.md`。
- 在该版本提交上创建 annotated tag：`git tag -a "v<version>" -m "v<version>" <release-commit>`。核实 `git rev-parse "v<version>^{commit}"` 等于版本提交 SHA，并检查该提交的版本字段、CHANGELOG 标题和 tag 一致，最终工作区干净。
- 交付版本号、构建号、提交 SHA、tag 和检查结果，明确提交和 tag 均在本地。如提交或打 tag 失败，停止后续步骤，说明已完成与未完成的部分并保留现场；续跑前先核实已有结果，从失败步骤继续，不重复提交、不自动回滚或删除 tag。
