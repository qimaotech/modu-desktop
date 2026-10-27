---
name: modu-workflow
description: Manage repositories and worktree groups in a Modu workspace through modu-cli. Use when the user asks to inspect the workspace, add or remove repositories, or manage worktree groups.
---

# Modu workspace management

Do not edit this skill's workspace copies of `SKILL.md` or `agents/openai.yaml`: opening or reloading discards their uncommitted working-tree and index changes and synchronizes the bundled content.

## Context and commands

- Start with `modu-cli workspace inspect --json` inside the workspace, or add `--workspace <root>` when known. Use the returned `workspace` root for subsequent calls; group directories are not workspace roots. Reuse current results; `repo list` and `worktree list` inspect their respective resources.
- All three inspection commands can prune records for missing directories across the workspace and may fetch `origin` when the `origin/HEAD` symbolic ref is missing.
- Pass `--workspace <root> --json` on subsequent management calls. Consult `modu-cli --help` and subcommand `--help` for syntax.
- Read repository IDs from `items[].resource.repo` and group names from `items[].resource.group`; `resource.path` is a relative filesystem path, not a command argument. IDs derive from repository URLs and are unique ignoring case; `repo add --name` changes only the display name and cannot resolve ID conflicts.
- `repo add` automatically commits the entire workspace `.gitignore` when it differs from HEAD, including pre-existing manual edits.
- CLI scope: workspace inspection, repository list/add/remove, and worktree list/create/update/remove. Workspace initialization, repository updates, local scanning, and YAML import/export require the App; do not invent CLI equivalents.

## Creating groups

- Preserve a valid user-supplied group name; otherwise propose `<type>-<task>` with a prefix such as `feature-` or `fix-` and a concise task description in the user's language.
- Names must be single directory names and valid Git branch names, without `/` or whitespace. Explain invalid names and confirm an alternative; do not silently rewrite them.
- Select needed repositories from the inspection. Present the group name, workspace root, and complete member repository IDs, and wait for explicit confirmation before `worktree create`. Reuse confirmation for the same name and repository set; confirm again if either changes. Pass only member IDs as `--repo`; the workspace repository supplies the group root implicitly.
- Creation uses local refs without refreshing repositories. Group roots reuse an available same-named local branch or start from workspace HEAD. Report branch-reuse warnings; do not reset reused branches or claim they include the latest base commits.

## Editing groups

- For an existing group, `worktree create` only adds missing members. Include existing members in the scope presented for confirmation.
- `worktree update` requires the complete desired member set and at least one `--repo`. To retain an empty group, remove members individually with `worktree remove <group> --repo <id>`.
- Without `--execute`, updates removing members return a deletion plan before any changes; updates with only additions execute immediately. This is not a general dry run.

## Destructive changes

- Before deletion or an update removing members, run without `--execute` and review the plan's paths, branches, and risks.
- `--execute` recomputes targets and is not bound to a previous invocation's plan. After a delay or external changes, preview again and compare against the authorized scope and risks. Execute only with explicit authorization for that scope and risks; reuse it while both remain unchanged, otherwise obtain approval for the revised plan.
- Worktree deletion permanently removes its files and current local branch, including ignored files, reused branches, and unmerged commits. The current branch may differ from the group name; a detached HEAD has no branch to delete. Repository removal first deletes configured members, then moves the main repository to Trash; read the whole plan.

## Results and failures

- Read stdout's final JSON even on nonzero exit; progress goes to stderr. `confirmation-required` means a pending plan. Report completed and unfinished items, warnings even on success, and effects as applied, reverted, or unknown. Cancellation and partial success retain completed effects.
- Explain unavailable resources and stop dependent actions; unrelated resources remain usable. Resolve reported causes before using ordinary Add/Create/Edit workflows for unfinished items; do not promise restoration, automatic repair, or import continuation.
- Manage through the CLI; do not edit private Modu records or bypass rejections with Git or shell deletion.

## Custom workflows

- For workspace-specific conventions or steps, recommend a separate `.agents/skills/modu-workflow-addon/SKILL.md` under the workspace root.
- Uncommitted addon changes are not copied into new groups; existing groups do not synchronize automatically. Commit custom workflow changes only with the user's authorization.
