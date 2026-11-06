---
name: mono-deck-workflow
description: Manage repositories, worktree groups, and group members in a MonoDeck workspace through mono-deck. Use when the user asks to inspect the workspace, add or delete repositories, create or edit groups, or add or delete group members.
---

# MonoDeck workspace management

Do not edit this skill's workspace copies of `SKILL.md` or `agents/openai.yaml`: opening or manually reloading the workspace in the App discards their uncommitted working-tree and index changes and synchronizes the bundled content.

## Domain essentials

- **Workspace / Workspace repository:** The workspace root is the main worktree of the workspace repository, which holds shared documents and workflows. Business repositories and groups are managed under this root.
- **Main repository:** A registered business repository's main worktree at `repositories/<repository-id>`, separate from the workspace repository. “Main” describes the worktree role, not a branch name.
- **Worktree Group (group) / Group root worktree:** A task context containing selected members and a root at `worktrees/<group-name>`. The root is the workspace repository's linked worktree, included implicitly; `--repo` selects business repositories only.
- **Group member / Member worktree:** A business repository's linked worktree at `worktrees/<group-name>/<repository-id>`, identified by group name and repository ID. It shares Git data with its main repository but has its own checkout and index; members are not submodules.
- **Group name / Current branch:** The group name determines its directory and initial local branch names. Each worktree can later switch branches independently; deletion targets the current branch.
- **Workspace record / Git worktree registration:** MonoDeck's private repository and membership metadata is separate from Git's worktree registration and from on-disk files.

## Context and commands

- Start with `mono-deck workspace tree --json` inside the workspace, or add `--workspace <root>` when known. Reuse the tree root's absolute `path` with `--workspace <root> --json` on management calls; group directories are not workspace roots. Consult subcommand `--help` for syntax.
- Every JSON response uses the version 2 operation-result envelope. The tree is in `data.tree`, with `type`, `path`, and `children`: root `path` is absolute, child paths are relative to their direct parent, and leaves have `children: null`.
- Tree types are `workspace`, `auxiliary-directory` (`repositories` and `worktrees`), `group`, `main-worktree`, and `linked-worktree`. Registered resources appear when their directories and `.git` entry types exist as expected. Missing, mistyped, or symlink paths are omitted; absence does not imply unregistered, and presence does not certify Git health or ownership.
- Queries read workspace record snapshots without acquiring the workspace lock, removing record entries, or fetching repositories. `workspace tree` checks directory and `.git` entry types, not child Git health, remotes, or registration ownership; use the relevant details or operation to diagnose those issues. Filesystem checks can observe concurrent changes; refresh the relevant list before management actions when needed.
- Read repository IDs from `repo list --json` (`items[].resource["repository-id"]`) and group names from `group list --json` (`items[].resource["group-name"]`). Lists report per-resource status and errors; `resource.path` is workspace-relative, not a command argument. IDs are URL path basenames without a trailing `.git`, unique ignoring case. `repo add --display-name` sets a label without changing identity.
- Workspace records and exported YAML use version 2 with repository `display-name` and group `repository-ids` fields. Old commands, options, and field names are not accepted. Do not try legacy spellings after a failure.
- `repo add` prepares clones outside the workspace lock, then rechecks registration and paths under the lock before publishing. Its `maintain-workspace-ignore` plan action covers maintaining and automatically committing the entire workspace `.gitignore` when it differs from HEAD, including pre-existing manual edits.
- Workspace initialization, repository updates, local scanning, and YAML import/export require the App; do not invent CLI equivalents.

## Planning and execution

- Every write command accepts `--dry-run`, which takes precedence over `--yes`. It checks local prerequisites without changing workspace resources, cloning, or fetching; later network and file operations can still fail. Success has `status: "success"` and `dry-run: true`, with planned actions in `plan.actions` and deletion targets in `plan.deletions`. Plans are unlocked snapshots, not reservations or completed effects.
- Without `--dry-run`, non-destructive commands execute immediately. Destructive commands prompt only in an interactive terminal; JSON or non-interactive calls without `--yes` return `confirmation-required` without executing any changes, including additions in a membership replacement.
- `--yes` authorizes the current command's deletion targets, not an earlier dry run. `group delete <group-name> --yes` determines current targets under the workspace lock and executes without the unlocked risk and local-change preview; use `--dry-run` to preview first. Ownership, target, and current-branch checks still apply. Preview again after a delay, external changes, or `confirmation-changed`.
- Run a destructive command with `--yes` only when the user has authorized the current scope and risks. Reuse authorization while both remain unchanged; obtain approval for a revised scope. Do not treat the flag itself as authorization.

## Creating groups

- Preserve a valid user-supplied group name; otherwise propose `<type>-<task>` with a prefix such as `feature-` or `fix-` and a concise task description in the user's language.
- Names must be single directory names and valid Git branch names, without `/` or whitespace. Explain invalid names and confirm an alternative; do not silently rewrite them.
- Present the group name, workspace root, and complete member repository IDs, and wait for explicit confirmation before `group create <group-name> --repo <repository-id>...`. Reuse confirmation for the same name and repository set; confirm again if either changes.
- `group create` requires a new group name and at least one member. Creation and member addition check and create each resource in order; later failures keep completed roots and members and leave the rest unprocessed. Extend existing or partially created groups through `group member add`.
- Creation uses local refs without updating repositories. Group roots reuse an available same-named local branch or start from workspace HEAD. Report branch-reuse warnings; do not reset reused branches or claim they include the latest base commits.

## Editing membership

- `group edit <group-name> --repo <repository-id>...` replaces the complete member set. Omitted members are deleted with their current local branches; it does not rename the group or synchronize branches. Preview and review the entire replacement before authorizing deletions.
- `group edit <group-name> --clear-members` deletes all members while keeping the group root. It cannot be combined with `--repo`.
- `group member add <group-name> <repository-id>...` adds missing members and preserves the rest. `group member delete <group-name> <repository-id>...` deletes only the named member worktrees and their current local branches.

## Destructive changes

- `group delete <group-name>` deletes the group root and all members. `repo delete <repository-id>` deletes the repository's managed members, then moves its main repository directory to Trash.
- Before authorizing deletion, review target paths, current branches, and risks in `--dry-run` output.
- Unknown local-change status does not mean clean or prevent linked worktree deletion. The preview retains read failures as warnings and allows authorized cleanup when ownership and target checks pass; report those warnings when reviewing the preview.
- Linked worktree deletion permanently removes its files and current local branch, including ignored files, reused branches, and unmerged commits. Success completes original-path removal, Git deregistration, and current-branch handling; files and disk space may still await best-effort background cleanup. A detached HEAD has no branch to delete.
- When a worktree directory and its Git registration are missing, deletion may only remove the workspace record entry.

## Results and failures

- Judge completion from stdout's final JSON even on nonzero exit; progress goes to stderr.
- Report completed and unfinished items, warnings even on success, and observed effects as applied, reverted, or unknown. Cancellation and partial success can retain completed effects.
- Workspace lock acquisition retries at 500 ms intervals, up to 10 retries per acquisition. Wait for the command to finish instead of launching duplicate writes. On `workspace-lock-timeout`, resolve contention and refresh current state and the plan before retrying.
- Stop dependent actions on unavailable resources; unrelated resources remain usable. For `cleanup-failed` or `save-outcome-unknown`, report causes and retained paths or unknown effects, leaving that data untouched. Resolve causes before retrying; do not promise restoration, automatic repair, or import continuation.
- Manage through the CLI; do not edit private MonoDeck records or bypass rejections with Git or shell deletion.

## Custom workflows

- For workspace-specific conventions or steps, recommend a separate `.agents/skills/mono-deck-workflow-addon/SKILL.md` under the workspace root.
- Uncommitted addon changes are not copied into new groups; existing groups do not synchronize automatically. Commit custom workflow changes only with the user's authorization.
