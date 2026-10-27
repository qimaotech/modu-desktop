---
name: modu-workflow
description: Manage repositories and worktree groups in a Modu workspace through modu-cli. Use when the user asks to inspect the workspace, add or remove repositories, or manage worktree groups.
---

# Modu workspace management

## Custom workflows

- Do not edit the workspace copies of this skill's `SKILL.md` or `agents/openai.yaml`. Modu manages these files, discards their uncommitted working-tree and index changes when opening or reloading the workspace, and synchronizes the bundled content.
- For workspace-specific conventions or additional workflow steps, recommend creating or maintaining a separate `modu-workflow-addon` skill at `.agents/skills/modu-workflow-addon/SKILL.md` under the workspace root.

## Context and commands

- Start with `modu-cli workspace inspect --json` from inside the workspace, or add `--workspace <root>` when its root is known. Use the returned `workspace` path for later calls; a group directory is not a workspace root. Reuse current inspection results; `repo list` and `worktree list` inspect their respective resources.
- All three inspection commands can remove records for missing resource directories across the workspace and may fetch `origin` when the `origin/HEAD` symbolic ref is missing.
- Pass `--workspace <root> --json` on every subsequent management call. Use `modu-cli --help` and subcommand `--help` for current syntax. Repository arguments use URL-derived IDs, unique ignoring case; `repo add --name` sets only a display name and cannot resolve ID conflicts.
- Read repository IDs from `items[].resource.repo` and group names from `items[].resource.group`; `resource.path` is a relative filesystem path, not a command argument.
- CLI commands cover workspace inspection, repository list/add/remove, and worktree list/create/update/remove. Workspace initialization, repository updates, local scanning, and YAML import/export are App operations; do not invent CLI equivalents.

## Creating groups

- Preserve a valid group name explicitly supplied by the user. Otherwise propose `<type>-<task>` based on the request: `feature-` for new features, `fix-` for bug fixes, or another suitable prefix such as `refactor-`, `docs-`, or `chore-`. Keep the task description concise and in the user's language, for example `feature-add-search`.
- Group names must be a single directory name and a valid Git branch name; `/` and whitespace are not allowed. If a supplied name is invalid, such as `feature/login`, explain why and propose a valid alternative for confirmation; do not silently rewrite it.
- Select the repositories needed for the request from the inspected workspace. Present the group name, workspace root path, and complete member repository IDs. The workspace repository supplies the group root implicitly; pass only member repository IDs as `--repo` arguments.
- Before running `worktree create`, explicitly ask whether the proposed group name and repository list are acceptable and wait for the user's confirmation. Reuse an explicit confirmation for the same name and repository set; if either changes, present the revised plan and obtain confirmation before creating.
- Creation uses available local refs and does not refresh repositories. Report branch-reuse warnings; do not reset a reused branch or claim it includes the latest base commits.

## Editing groups

- `worktree create` adds missing members when the named group already exists; it does not replace or remove existing members. Include existing members when presenting the complete group scope for confirmation.
- `worktree update` takes the complete desired member set, not just additions, and requires at least one `--repo`. To retain an empty group, remove individual members with `worktree remove <group> --repo <id>`.
- Without `--execute`, an update that removes members returns a deletion plan before making changes. An update with only additions executes immediately; omitting `--execute` is not a general dry run.

## Destructive changes

- Before deletion or an update that removes members, run without `--execute` and review the returned plan, affected paths, branches, and risks.
- `--execute` computes targets from current state and is not bound to a previous invocation's plan. After a delay or external changes, preview again and compare paths, branches, and risks with the authorized scope.
- Repeat with `--execute` only when the user has explicitly authorized the current scope and risks; otherwise present the revised plan for approval. Reuse authorization while that scope and its risks remain unchanged.
- Worktree deletion permanently removes its files and current local branch, including ignored files, reused branches, and unmerged commits. The current branch may differ from the group name; a detached HEAD has no branch to delete. Repository removal first deletes configured members, then moves the main repository to Trash; read the whole plan.

## Results and failures

- Read the final JSON from stdout even on nonzero exit; progress goes to stderr. `confirmation-required` is a pending plan, not a failed deletion. Success can still include warnings. Report completed and unfinished items, warnings, and retained effects; preserve distinctions between applied, reverted, and unknown effects. Cancellation or partial success does not roll back completed work.
- Explain unavailable resources and stop dependent actions; unrelated available resources remain usable.
- Use the CLI for workspace management. Do not edit private Modu records or bypass rejected actions with Git or shell deletion.
- Do not promise restoration, automatic repair, or import continuation. Resolve the reported cause before using ordinary Add/Create/Edit workflows for unfinished items.
