---
name: modu-workflow
description: Manage repositories and worktree groups in a Modu workspace through modu-cli. Use when the user asks to inspect the workspace, add or remove repositories, or manage worktree groups.
---

# Modu workspace management

Do not edit this skill's workspace copies of `SKILL.md` or `agents/openai.yaml`: opening or manually reloading the workspace in the App discards their uncommitted working-tree and index changes and synchronizes the bundled content.

## Context and commands

- Start with `modu-cli workspace inspect --json` inside the workspace, or add `--workspace <root>` when known. Success returns the tree root directly, with `type`, `path`, and `children`: root `path` is absolute, child paths are relative to their direct parent, and worktree leaves have `children: null`.
- Tree types are `workspace`, `auxiliary-directory` (`repositories` and `worktrees`), `group`, `main-worktree`, and `linked-worktree`. Only valid registered resources appear; invalid ones are silently omitted, so absence does not imply unregistered.
- Queries read registration snapshots without acquiring the workspace lock, pruning records, or fetching repositories. Filesystem checks can observe concurrent changes; refresh the relevant list when needed before management actions.
- Use the root node's absolute `path` with `--workspace <root> --json` on management calls; group directories are not workspace roots. Consult subcommand `--help` for syntax.
- Read repository IDs from `repo list --json` (`items[].resource.repo`) and group names from `worktree list --json` (`items[].resource.group`). Both lists report resource status and errors; `resource.path` is workspace-relative, not a command argument. IDs derive from repository URLs and are unique ignoring case; `repo add --name` only changes display names and cannot resolve ID conflicts.
- `repo add` prepares new clones outside the workspace lock, then rechecks current registrations and paths under the lock before publishing. It automatically commits the entire workspace `.gitignore` when it differs from HEAD, including pre-existing manual edits.
- Workspace initialization, repository updates, local scanning, and YAML import/export require the App; do not invent CLI equivalents.

## Creating groups

- Preserve a valid user-supplied group name; otherwise propose `<type>-<task>` with a prefix such as `feature-` or `fix-` and a concise task description in the user's language.
- Names must be single directory names and valid Git branch names, without `/` or whitespace. Explain invalid names and confirm an alternative; do not silently rewrite them.
- Present the group name, workspace root, and complete member repository IDs, and wait for explicit confirmation before `worktree create`. Reuse confirmation for the same name and repository set; confirm again if either changes. Pass only member IDs as `--repo`; the workspace repository supplies the group root implicitly.
- Creation uses local refs without refreshing repositories. Group roots reuse an available same-named local branch or start from workspace HEAD. Report branch-reuse warnings; do not reset reused branches or claim they include the latest base commits.

## Editing groups

- For an existing group, `worktree create` only adds missing members. Include existing members in the scope presented for confirmation.
- `worktree update` requires the complete desired member set and at least one `--repo`. To retain an empty group, remove members individually with `worktree remove <group> --repo <id>`.
- Without `--execute`, updates removing members return a deletion plan before any changes; updates with only additions execute immediately. This is not a general dry run.

## Destructive changes

- Deletion previews are unlocked snapshots and do not reserve paths or branches. Before deletion or an update removing members, run without `--execute` and review the plan's paths, branches, and risks.
- `--execute` recomputes targets and is not bound to an earlier plan. Re-preview after a delay, external changes, or `confirmation-changed`. Execute only with explicit authorization for the current scope and risks; reuse it while both remain unchanged, otherwise obtain approval for the revised plan.
- Worktree deletion permanently removes its files and current local branch, including ignored files, reused branches, and unmerged commits. The current branch may differ from the group name; a detached HEAD has no branch to delete. Repository removal first deletes configured members, then moves the main repository to Trash.

## Results and failures

- Judge completion from stdout's final JSON even on nonzero exit; progress goes to stderr. `workspace inspect` errors and list/management responses use the operation-result envelope. `confirmation-required` means a pending plan. Report completed and unfinished items, warnings even on success, and effects as applied, reverted, or unknown. Cancellation and partial success retain completed effects.
- Workspace lock acquisition retries at 500 ms intervals, up to 10 retries per acquisition. Wait for the command to finish instead of launching duplicate writes. On `workspace-lock-timeout`, resolve contention and refresh current state and any deletion plan before retrying.
- Stop dependent actions on unavailable resources; unrelated resources remain usable. For `cleanup-failed` or `save-outcome-unknown`, report causes and retained paths or unknown effects, leaving that data untouched. Resolve causes before retrying; do not promise restoration, automatic repair, or import continuation.
- Manage through the CLI; do not edit private Modu records or bypass rejections with Git or shell deletion.

## Custom workflows

- For workspace-specific conventions or steps, recommend a separate `.agents/skills/modu-workflow-addon/SKILL.md` under the workspace root.
- Uncommitted addon changes are not copied into new groups; existing groups do not synchronize automatically. Commit custom workflow changes only with the user's authorization.
