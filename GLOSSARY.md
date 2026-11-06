# Domain Glossary

Use these terms in product discussions, UI copy, documentation, and code. English terms are canonical; the Chinese column provides their Chinese names. Short forms are appropriate when the surrounding context is unambiguous.

Definitions describe the current domain. Use the canonical terms for UI copy, documentation, and internal code. The external contract below uses the same domain vocabulary and does not retain legacy command or field aliases. Business rules, serialized formats, and command arguments remain defined by the implementation. For workflows and operational details, see [README.md](README.md) and [DEVELOPMENT.md](DEVELOPMENT.md).

## Workspace structure

Sources: [workspace models](MonoDeckCore/Models/WorkspaceModels.swift), [resources](MonoDeckCore/Models/Resource.swift), and [workspace tree](MonoDeckCore/Workflows/WorkspaceTree.swift).

| English term | Chinese name | Definition and usage | Current code / path |
| --- | --- | --- | --- |
| Workspace | 工作区 | The root directory, its workspace Git repository, and the registered repositories and groups managed together by MonoDeck. A workspace is more than a collection of unrelated folders. | `WorkspaceRecord`; `WorkspaceService` |
| Workspace root | 工作区根目录 | The canonical absolute directory to which a workspace record is bound. It is the main worktree of the workspace repository. | `WorkspaceRecord.root`, `rootURL`; `Resource.workspace()` |
| Workspace repository | 工作区仓库 | The Git repository rooted at the workspace root. It holds shared documents, prompts, and workflow files; its linked worktrees provide group roots. It is separate from the registered business repositories. | Git repository at `WorkspaceRecord.rootURL` |
| Repository | 仓库 | A registered business Git repository with a remote URL and a local clone under `repositories/`. Use **main repository** when distinguishing this clone from its group members. The workspace repository is not an entry in this list. | `Repository`; `WorkspaceRecord.repositories`; `Resource.repository(id)` |
| Worktree | 工作树 | A Git working directory with its own checkout, index, and working files. Both main and linked worktrees are worktrees. Use the single word `worktree` for this domain concept; retain `working tree` in existing Git state labels and APIs. | Main worktrees and linked worktrees |
| Main worktree | 主工作树 | The original working directory of a Git repository, with a `.git` directory. Both the workspace root and each main repository are main worktrees. “Main” describes the worktree role, not a branch named `main`. | Workspace root; `repositories/<repositoryID>`; tree type `main-worktree` for repository leaves |
| Linked worktree | 关联工作树 | An additional worktree sharing Git data with its owning repository while keeping its own checkout and index. Both group roots and members are linked worktrees. | Git worktree registration; `WorktreeRegistration` |
| Worktree Group (Group) | 工作树分组（分组） | A named task context containing a group root worktree and the member worktrees selected for that task. Creation requires at least one member; removing members can leave an empty group with its root intact. A group is neither a Git repository nor a single branch shared across repositories. | `WorktreeGroup`; `WorkspaceRecord.groups`; `worktrees/<groupName>` |
| Group root worktree | 分组根工作树 | The workspace repository's linked worktree at a group root. Selecting a group operates on this worktree, not on all member repositories at once. | `Resource.group(name)`; `WorkspaceRecord.groupURL(name)` |
| Group member (Member worktree) | 分组成员（成员工作树） | A selected business repository's linked worktree inside a group. A member is identified by both group name and repository ID. The same repository may have members in multiple groups. | `Resource.member(groupName: groupName, repositoryID: repositoryID)`; `WorktreeGroup.repositoryIDs`; `worktrees/<groupName>/<repositoryID>` |
| Resource | 资源 | The common operation target or inspection identity. Workspace, CLI installation, main repository, group root, and group member are resource kinds. A resource does not imply a new repository or a visible sidebar row. | `Resource`; `Resource.Kind` |
| Auxiliary directory | 辅助目录 | A structural container for repositories or groups. The `repositories/` and `worktrees/` folders are not Git worktrees themselves. | `WorkspaceTreeNode.Kind.auxiliaryDirectory` |
| Workspace tree | 工作区目录树 | The structural view returned in `data.tree` by `workspace tree`: workspace root, auxiliary directories, and registered main repositories, groups, and members whose directories and `.git` entry types exist as expected. It does not certify child Git health, remotes, or registration ownership. It does not enumerate code files and is distinct from the local changes tree in Git Browser. | `WorkspaceTreeNode`; `workspaceTree`; CLI `workspace tree` |

```text
<workspace>/                         Workspace root: main worktree of the workspace repository
├── repositories/
│   ├── order-service/               Main worktree of a business repository
│   └── storefront-web/              Main worktree of another business repository
└── worktrees/
    └── feature-checkout/            Group root: linked worktree of the workspace repository
        ├── order-service/           Member: linked worktree of repositories/order-service
        └── storefront-web/          Member: linked worktree of repositories/storefront-web
```

Directory nesting organizes a task; it does not make members submodules of the workspace repository. Each member shares Git data with its own main repository. Group branches initially use the configured initial branch name in separate repositories, and each worktree can subsequently change its current branch independently.

## Identity and persisted structure

Sources: [repository identity](MonoDeckCore/Models/RepositoryIdentity.swift), [workspace store](MonoDeckCore/Infrastructure/Persistence/WorkspaceStore.swift), and [YAML workflows](MonoDeckCore/Workflows/YAMLService.swift).

| English term | Chinese name | Definition and usage | Current code / field |
| --- | --- | --- | --- |
| Repository ID | 仓库标识 | The final component of the repository URL path with a trailing `.git` removed. Used for directory names, member references, and CLI `--repo` values. IDs must be unique within a workspace, ignoring case. | `Repository.id`; `RepositoryIdentity.id`; `Resource.repositoryID` |
| Repository URL | 仓库 URL | The remote URL used to clone and validate a registered repository. It is distinct from the local repository path. | `Repository.url`; UI `Repository URL` |
| Display name | 显示名称 | An optional human-readable repository label. It falls back to the repository ID and does not change identity, paths, or CLI arguments. | `Repository.displayNameOverride`, `displayName`; CLI `repo add --display-name` |
| Group name | 分组名称 | The group key and directory name, also used as the default initial branch name when none is specified at creation. It must be a single directory component and a valid Git branch name. Editing membership does not rename the group. | Key in `WorkspaceRecord.groups`; UI `Group Name`; CLI `<group-name>` |
| Initial branch name | 初始分支名 | The literal local branch name used to create a group root and its members, and later members added to that group. Defaults to the group name, permits valid Git branch slashes, and is read-only after creation. It does not track subsequent checkout changes. Recovery uses the group root’s current branch, falling back to the group name for detached HEAD. | `WorktreeGroup.branchName`; JSON/YAML `branch-name`; CLI `group create --branch` |
| Workspace record | 工作区登记 | The local persisted registration binding a canonical workspace root to repository declarations and group membership. Stored in MonoDeck application support, outside the workspace Git repository. Keep this local registration distinct from portable workspace configuration. | `WorkspaceRecord`; `WorkspaceStore`; `WorkspaceDocumentValidation.validateRecordDocument` |
| Workspace record entry | 工作区登记项 | A repository declaration, group declaration, or member ID stored in the local workspace record. It is separate from Git worktree registration and from the files on disk. | `WorkspaceRecord`; `Resource`; effect `remove-record-entry` |
| Git worktree registration | Git 工作树注册 | Git's record associating a worktree path, HEAD, branch, and lock state with its owning repository. This is separate from MonoDeck's workspace record; a worktree may exist in Git without being managed by MonoDeck. | `WorktreeRegistration`; `Git.registrations` |
| Workspace configuration (YAML) | 工作区配置（YAML） | The portable repository declarations and group structure imported or exported as YAML. It omits the local workspace root and does not contain code, Git history, uncommitted changes, or current branch state. Use **record** for local registration and **configuration** for this portable structure. | `WorkspaceExport` in `YAMLService.swift`; `WorkspaceDocumentValidation.validateConfigurationDocument`; UI `Configuration` |

## Git inspection

Sources: [Git models](MonoDeckCore/Models/GitModels.swift), [Git inspection](MonoDeckCore/Infrastructure/Git/GitInspection.swift), and [detail view](MonoDeck/Features/GitBrowser/GitBrowserView.swift).

| English term | Chinese name | Definition and usage | Current code / UI |
| --- | --- | --- | --- |
| HEAD / Head branch | HEAD／当前分支 | HEAD identifies the selected worktree's current checkout; when attached, it points to the current local branch. A detached HEAD is displayed using a commit ID rather than a branch name. | `GitWorkingState.branch`, `head`, `headOID`; `GitSummary.head`; UI `Head branch` |
| Base branch | 基准分支 | The locally known remote-tracking branch referenced by `refs/remotes/origin/HEAD`, such as `origin/main`, used for Git Browser comparisons. It is not necessarily the current branch's upstream or a creation starting point. It may be unavailable. | `GitSummary.base`, `baseOID`; UI `Base branch` |
| Remote default branch | 远端默认分支 | The default branch advertised by the remote. Adding a repository checks it online; later browsing uses the local `origin/HEAD` record, which may be stale. Never assume its name is `main` or `master`. | `WorkspaceService.remoteDefault`; local `refs/remotes/origin/HEAD` |
| Local changes | 本地更改 | Uncommitted file changes in the selected worktree, including staged, unstaged, untracked, and conflicting entries. The App hides submodule-only changes; CLI inspection and operation safety checks use full Git status. | `[FileChange]`; `GitChangeVisibility`; UI `local changes` |
| Staged changes / Index | 已暂存更改／暂存区 | The staged side of a file's Git status, comparing the index with HEAD. Do not confuse staging with saving to a Git stash. | `FileChange.index`; UI `Staged` |
| Unstaged changes / Working tree | 未暂存更改／工作树 | The working-file side of a file's Git status, comparing working files with the index. Untracked files are represented on this side. | `FileChange.workingTree`; UI `Unstaged` |
| Unique commits | 独有提交 | Commits reachable from the selected worktree's HEAD but not from the base (`base..HEAD`). This list is neither all repository history nor a list of uncommitted changes. | `GitBrowserState.uniqueCommits`; UI `unique commits` |
| Behind commits | 落后提交 | Commits reachable from the base but not from the selected HEAD (`HEAD..base`). Shown through a behind-count button and popover, separately from unique commits. They do not necessarily correspond to commits never fetched locally. | `GitBrowserState.behindCommits`; `BehindCommitsButton`, `BehindCommitsPopover` |
| Starting commit | 分支起点提交 | The commit used to create a new group branch. For a group root it is the workspace HEAD; for a member it is the locally known same-name remote branch, falling back to the locally known remote default branch. Reusing an existing local branch preserves its tip instead. | `WorktreeCreation.oid`; `creationPlan`; distinct from `GitSummary.baseOID` |
| Branch reuse | 分支复用 | Checking out an available existing local branch with the configured initial branch name instead of creating a new branch. Its commits are kept; a comparison warning does not update or merge that branch. | `WorktreeCreation.reused`; result data `reused-branch` |
| Git details snapshot / Cache | Git 详情快照／缓存 | A previously read view of local changes, summary, and comparison commits, reused to display details quickly. It can be stale and is distinct from the workspace record or a backup. | `RepositoryDetailSnapshot`; `RepositoryDiskCache`; UI `Showing previous results.` |

## UI elements

These are names for discussing existing UI elements, including elements without a visible title. Literal English labels retain their current spelling and casing. Dialog titles use sentence case. Operation result titles describe outcomes; progress titles identify the action and target. Chinese names describe the element; where it has a localized label, they follow that label.

Sources: [workspace UI](MonoDeck/Features/Workspace/), [Git Browser UI](MonoDeck/Features/GitBrowser/), [management UI](MonoDeck/Features/Management/), and [localized copy](MonoDeck/Resources/Localizable.xcstrings).

| English term | Chinese name | Element and scope | Current implementation / label |
| --- | --- | --- | --- |
| Workspace sidebar | 工作区侧栏 | The resource navigation area. Its section headers are containers, not selectable workspace resources. | `WorkspaceSidebar` |
| Repositories section | 仓库区 | Sidebar collection of registered main repositories. | Literal sidebar header `repositories` |
| Worktrees section | 工作树区 | Sidebar collection of groups with nested member rows. Use **group row** and **member row** to distinguish the two levels. | Literal sidebar header `worktrees`; `Resource.group`, `.member` |
| Workspace home | 工作区首页 | The start view shown when no sidebar resource is selected. External tools opened here target the workspace root. It is not a group or Git Browser selection. | `ContentView` with `WorkspaceModel.selection == nil`; `Let’s start` |
| Git Browser (Resource details) | Git 浏览器（资源详情） | The detail pane for a selected main repository, group root, or member worktree. It reads local Git data; development, commits, and merges happen in external tools. | `GitBrowserView`; `GitBrowserModel` |
| Git summary | Git 摘要 | The card showing the resource path, base branch, current branch, and branch-comparison availability or behind count. | `GitBrowserView.summary`; `GitSummary` |
| Local changes tree | 本地更改树 | The file tree under `local changes`, with staged and unstaged status indicators. Directory rows group changed paths. | `ChangeNode`; `GitBrowserView.localChangesSection` |
| Unique commits list | 独有提交列表 | The list under `unique commits`, displaying subject, author, date, and abbreviated commit ID. | `GitBrowserView.uniqueCommitsSection` |
| Behind commits popover | 落后提交弹出面板 | The list opened from the behind-count button beside the branch summary. | `BehindCommitsPopover`; `N commits behind {base}` |
| External tool toolbar | 外部工具栏 | Tool buttons and their tool-selection menus. Categories are `Git GUI`, `Terminal`, `Editor`, and `Agent`; the target is the current directory. Opening the workspace explicitly targets its root. | `ToolBarView`; `ExternalTool`; `WorkspaceModel.currentURL` |
| Management sheet | 管理表单 | The sheet for adding or importing repositories, creating or editing groups, or previewing deletion. **Sheet** describes the presentation; use the operation's name in user-facing copy. | `ManagementView`; `ManagementSheet` |
| Repository filter | 仓库筛选 | Narrows the available repository list by display name in group creation and editing sheets. Filtering and clearing the filter preserve selected members. | `RepositoryFilterField`; UI `Filter repositories`, `Clear filter` |
| Operation progress / Result | 操作进度／操作结果 | Progress identifies the active phase and completed items; results describe per-resource outcomes, warnings, and effects. A result is not a promise that all resources changed together. | `OperationProgressView`; `ResultView`; `RepositoryUpdateResultsView` |
| Setup window | 初始设置窗口 | The `MonoDeck Setup` flow for CLI installation and workspace selection. Choosing a directory sets a candidate; `Continue` validates and opens, initializes, or recovers it. | `SetupView`; `SetupModel` |
| Settings window | 设置窗口 | The preferences window containing general preferences, global shortcut, workspace selection, and YAML configuration actions. Distinguish it from Setup. | `SettingsView`; `Settings`, `Configuration` |
| Software Update window | 软件更新窗口 | The flow for checking, downloading, and installing a new MonoDeck release. It is separate from updating Git repositories. | `AppUpdateView`; `AppUpdateModel`; `Software Update` |

## Operations and boundaries

Sources: [workspace workflows](MonoDeckCore/Workflows/WorkspaceService.swift), [repository workflows](MonoDeckCore/Workflows/RepositoryService.swift), [group workflows](MonoDeckCore/Workflows/WorktreeService.swift), [deletion](MonoDeckCore/Workflows/DeletionService.swift), and [YAML workflows](MonoDeckCore/Workflows/YAMLService.swift).

| English term | Chinese name | Meaning and boundary | Current code / UI / command |
| --- | --- | --- | --- |
| Add repository | 添加仓库 | Clone a remote repository into the workspace and register it. An optional display name does not change its ID. The operation also maintains the workspace ignore file and may automatically commit that file, including when the repository already exists. | `addRepository`; `Add Repository`; CLI `repo add` |
| Import repositories | 导入仓库 | Select remote URLs extracted from YAML or discovered by scanning local repositories, then clone them into the workspace. Local scanning does not move the source directories or import their uncommitted changes. | `importRepositories`; `Import repositories`; result command `repo.import` covers both import sources |
| Import / Export workspace configuration | 导入／导出工作区配置 | Recreate or share repository and group structure using YAML. Workspace import requires no registered resources and empty resource directories. Repository import in the Add Repository sheet is a separate operation. | `importWorkspaceYAML`, `exportYAML`; Settings `Import YAML…`, `Export YAML…` |
| Create group | 创建分组 | Create the group root and selected members using the configured initial branch name, reusing available local branches when present. The group name must not already exist; use member addition to extend an existing group. Creation uses locally known commits and does not fetch or update main repositories first. Resources are checked and created one at a time; later failures retain completed roots and members. | `createGroup(repositoryIDs:)`; `Create Worktree Group`; CLI `group create` |
| Add group members | 添加分组成员 | Add missing member worktrees to an existing group, preserving all current members and the group root. Existing members are validated and kept. | `addGroupMembers`; CLI `group member add` |
| Edit group | 编辑分组 | Change group membership by creating added members and deleting removed members. It keeps the group root and name; it does not synchronize branches or workspace documents. | `editGroup(repositoryIDs:)`; `Edit Worktree Group`; CLI `group edit` |
| Update repositories | 更新主仓库 | Fetch the branch recorded by local `origin/HEAD` and attempt a fast-forward-only merge in each main repository. Dirty checkouts and checkouts on another branch are skipped. Existing groups are not updated. | `updateRepositories`; UI `Update Repositories`; result command `repo.update` |
| Refresh Git details | 刷新 Git 详情 | Re-read local Git state for the current selection. It does not fetch, merge, or perform workspace maintenance. | `refreshDetail`; UI `Refresh Git Details` (`⌘R`) |
| Workspace maintenance / Reload | 工作区维护／重新加载 | Validate and clean local registration, maintain managed workspace files, and commit them when needed. Opening or manually reloading a workspace can perform maintenance; automatic record refresh is read-only. | `openWorkspaceWithRecord`; `maintainWorkspace`; `Reload`, `Retry Maintenance` |
| Workspace recovery | 工作区登记恢复 | Rebuild a missing local workspace record from recognized repositories and worktrees using local Git data during Setup or manual workspace selection in Settings. It preserves existing branches and changes; it is separate from YAML import or restoring a backup. | `recoverWorkspaceRecord`; Setup `Continue`; `AppModel.changeWorkspace` |
| Delete member / Group | 删除成员／分组 | Permanently remove the target linked worktrees and their current local branches, including reused branches and unmerged commits. Success completes original-path removal, Git deregistration, and current-branch handling; file cleanup and space reclamation may still await best-effort background cleanup. Deleting a member keeps the group root; deleting a group includes its root and members. | `DeleteRequest.member`, `.group`; CLI `group delete` or `group member delete` |
| Delete repository | 删除仓库 | Delete the repository's managed member worktrees and their current branches, then move its main repository directory to Trash. This has wider scope than deleting one member. | `DeleteRequest.repository`; CLI `repo delete` |
| Dry run / Operation plan | 预演／操作计划 | Validate local prerequisites and describe planned actions without applying effects. Deletion targets include their current branches, `git-registered` state, and risks. Git registration is separate from the workspace record entry. The plan is an unlocked snapshot, not a reservation. | `OperationPlan`; `PlannedAction`; `OperationResult.dryRun`; `--dry-run` |
| Deletion preview | 删除预览 | A snapshot of targets, current branches, status, and risks before destructive execution. Unreadable status remains unknown and does not block linked worktree deletion. Execution validates Git ownership and any authorized targets and branches; it does not require matching remotes or readable commits for linked worktrees. | `DeletionTarget`; `previewDelete`; `OperationResult.plan` |
| Remove workspace record entry | 移除工作区登记项 | Remove a resource's local registration entry. This describes a metadata effect and is distinct from deleting files or branches. | Effect action `remove-record-entry` |
| Workflow skill | 工作流技能 | The bundled `mono-deck-workflow` instructions installed into a workspace for an Agent to discover and use. Managed copies are maintained by MonoDeck. | `.agents/skills/mono-deck-workflow/`; `InstallationService` |
| Software update | 软件更新 | Install a newer version of MonoDeck and restart the application. Always qualify **update** with its target when repository updates could also be meant. | `AppUpdateService`; `Check for Updates…`, `Install and Restart` |

## Status and outcomes

Sources: [operation statuses](MonoDeckCore/Models/OperationStatus.swift), [operation results](MonoDeckCore/Models/OperationModels.swift), and [UI status mappings](MonoDeck/SharedUI/InterfaceText.swift).

| English term | Chinese name | Meaning | Current code / UI |
| --- | --- | --- | --- |
| Clean / Dirty | 无更改／有更改 | Whether the inspected worktree has uncommitted changes under the applicable visibility policy. Clean does not mean merged, pushed, or safe to delete. | `ResourceState.dirty`; `Clean`, `Dirty`; sidebar change dot |
| Unset | 未加入 | A repository is not currently a member of the group being edited. It does not mean the repository is missing or unconfigured. | Group editor `Unset` |
| Unavailable | 不可用 | A resource cannot be validated or its state cannot be read. Unknown status must not be treated as clean. | `ResourceState.available`; UI `Unavailable` |
| Operation result / Item result | 操作结果／单项结果 | The overall operation outcome and the outcome for an individual resource. Either may report completed effects even when its status is failed or cancelled. | `OperationResult`; `ItemResult` |
| Completed | 已完成 | A successful operation or item. Additional warnings may still be present. | `OperationStatus.success`; UI `Completed` |
| Partially completed | 部分完成 | A mix of successful items and failed or skipped items. Inspect item results to understand the actual effects. | `OperationStatus.partialSuccess`; JSON `partial-success` |
| Skipped / Not processed | 已跳过／未处理 | Skipped describes a resource action that was unnecessary or could not proceed; related maintenance effects may still be reported. Not processed identifies remaining work that was not attempted after the operation stopped. Inspect item effects separately from status. | `OperationStatus.skipped`; reason `not-processed`; UI `Skipped`, `Not processed` |
| Failed / Cancelled | 失败／已取消 | Failure reports an error; cancellation reports a stopped operation. Neither guarantees a rollback of completed effects. | `OperationStatus.failed`, `.cancelled` |
| Warning | 提示 | Additional information attached to a successful item, such as a reused branch being behind the base. It does not by itself change success into failure. | Item data `warning-code`; UI `Warnings`, `Completed with warnings` |
| Confirmation required | 需要确认 | A plan has been produced and destructive execution still requires authorization. No part of the pending mutation has executed. | `OperationStatus.confirmationRequired`; JSON `confirmation-required` |
| Effect | 操作效果 | A reported action and target with an observed state: applied, reverted, or unknown. Unknown means the outcome could not be confirmed; retained paths and completed effects must be reported accurately. | `Effect`; UI `Applied`, `Cleaned up`, `Unconfirmed` |

## External data and CLI contract

Workspace records, exported YAML, and CLI JSON use schema version 2. Cache entries and their storage directory also use v2. Old formats, fields, commands, and flags are not migrated or accepted as aliases. Format versions are independent of the product version.

| Canonical concept | Chinese name | External form | Meaning |
| --- | --- | --- | --- |
| Repository ID | 仓库标识 | Resource `repository-id`; `--repo <repository-id>`; member command arguments | Identifies a repository independently of its display name. |
| Display name | 显示名称 | Repository JSON/YAML `display-name`; `repo add --display-name` | Maps to `displayNameOverride`; `displayName` resolves the fallback. |
| Group name | 分组名称 | Resource `group-name`; CLI `<group-name>` | Identifies the group and its root worktree. |
| Initial branch name | 初始分支名 | Required group JSON/YAML `branch-name`; `group create --branch <branch-name>` | The creation and future-member default, independent of the current branch. |
| Group membership | 分组成员关系 | Group JSON/YAML `repository-ids` | Stores repository IDs. Workspace-level `repositories` contains repository declarations. |
| Unique commits | 独有提交 | Cache field `unique-commits` | Maps to `RepositoryDetailSnapshot.uniqueCommits`. |
| Workspace record persistence | 工作区登记持久化 | Effect `save-workspace-record`; errors `workspace-record-missing`, `invalid-workspace-record`, `workspace-record-write-failed` | Portable YAML validation uses `invalid-workspace-configuration` instead. |
| Resource entry removal | 资源登记项移除 | Effect `remove-record-entry` | Removes metadata from the workspace record, separately from deleting files or Git branches. |
| Group operations | 分组操作 | `group list/create/edit/delete`; `group member add/delete` | Creation requires a new name. Editing replaces the complete member set; member commands change only the named members. |
| Repository import | 仓库导入 | Result command `repo.import` | Covers repository imports from YAML and locally discovered remote URLs. |
| Operation result | 操作结果 | `schema-version`, `command`, `status`, `dry-run`, `data`, `items`, `plan` | Every CLI JSON response uses the same envelope, including errors. Directory trees are in `data.tree`. |
| Operation plan | 操作计划 | `plan.actions`, `plan.deletions` | Planned actions and deletion risks are separate from observed item effects. |

All write commands accept `--dry-run` and return a local plan without changing workspace resources, cloning, or fetching. A dry run does not guarantee later network or file operations will succeed. Destructive writes prompt in an interactive terminal; JSON and non-interactive calls require `--yes` or return `confirmation-required` without applying any changes. `--yes` authorizes the current command's deletion targets; it does not bind an earlier preview or bypass execution-time validation. `group delete --yes` determines and deletes the current targets under lock without an unlocked risk or status preview. `--dry-run` takes precedence over `--yes`.

## Naming and wording rules

- Use **workspace**, **repository**, **group**, and **member** for their distinct roles. Use **project** only when referring to an external tool's own concept.
- Use **Worktree Group** on first mention and **group** thereafter. The `worktrees` directory and sidebar header are physical collection names; they do not make a group and a member interchangeable.
- Use **group root worktree** when the physical checkout matters and **group** when discussing the task context or membership. Existing `Resource.group` represents that group's root as an operation target.
- Distinguish **repository ID**, **display name**, **group name**, and **branch** in new names and APIs. Use `repositoryID` for identity, `displayNameOverride` for the optional label, `displayName` for the resolved label, `groupName` for a group key, and `branchName` for the configured initial branch name.
- Name an operation by its target and effect: **edit group membership**, **update repositories**, **refresh Git details**, **reload workspace**, or **update MonoDeck**. Avoid an unqualified **sync** that could imply fetching, merging, or updating every group.
- Use the established Swift vocabulary and casing, such as `WorktreeGroup`, `Repository`, `member`, `baseOID`, and `headOID`. Use canonical CLI commands and serialized names; do not add legacy aliases when renaming internal symbols.
- When introducing a new business concept, propose its English term, Chinese name, semantics, and code mapping here. Keep operational procedures in README or DEVELOPMENT and implementation details in code.
