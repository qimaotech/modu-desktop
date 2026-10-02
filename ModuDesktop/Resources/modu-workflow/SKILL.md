---
name: modu-workflow
description: Manage repositories and worktree groups in a Modu workspace through modu-cli. Use for requested Modu workspace management; ordinary code edits and directories outside Modu do not trigger this skill.
---

Run from the workspace root. First use `modu-cli workspace inspect --workspace <root> --json` to verify context, then `repo list` or `worktree list` to identify configured targets. Keep `--json --workspace <root>` on every management call.

Use command help for syntax. Add repositories with `repo add`. Create groups with `worktree create <group> --repo <name>` (repeat `--repo` for multiple members). The group name determines initial branch names. Existing worktrees retain their actual checkout. Modu automatically commits workspace setup files and .gitignore changes after adding repositories; workspace YAML import clones repositories, commits .gitignore, then creates groups. These local commits preserve unrelated staged and unstaged files. Group roots belong to the workspace repository and require their starting commit to contain the necessary .gitignore rules. If an existing branch lacks those rules or an automatic commit fails, report the reason and ask the user to resolve it before retrying.

`worktree update` supplies the complete desired member set and requires at least one `--repo`. Use individual `worktree remove <group> --repo <name>` calls to leave an empty group. `worktree remove <group>` removes members and then the root. `repo remove <name>` removes configured members and moves the main repository to Trash.

For deletion or an update with removals, first run without `--execute` and read the returned plan. Obtain explicit authorization for its scope and risks unless the user already authorized that exact action. Then repeat with `--execute`. Deleting a worktree permanently deletes its current local branch, including reused or unmerged branches. Detached HEAD has no branch to delete. Authorization never bypasses unmanaged worktree, lock, path, or Git checks.

Read the final JSON even on nonzero exit. Report completed and unfinished items and retained effects accurately. Cancellation and partial success do not roll back completed work. Explain unavailable resources and stop actions depending on them; unrelated available resources remain usable.

Do not edit private Modu records or bypass rejected actions with Git or shell deletion. Do not promise restoration, automatic repair, or import continuation. After the cause of partial completion is resolved, use ordinary Add/Create/Edit workflows.
