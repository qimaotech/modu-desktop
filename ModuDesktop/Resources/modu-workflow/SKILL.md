---
name: modu-workflow
description: Manage repositories and worktree groups in a Modu workspace through modu-cli. Use for Modu workspace management requests, excluding ordinary code edits and directories outside Modu.
---

# Modu workspace management

## Context and commands

- Run from the workspace root. Use `modu-cli workspace inspect --workspace <root> --json`, then `repo list` or `worktree list` to identify configured targets.
- Pass `--workspace <root> --json` on every management call. Use `modu-cli --help` and subcommand `--help` for current syntax.
- `worktree update` takes the complete desired member set, not just additions, and requires at least one `--repo`. To retain an empty group, remove individual members with `worktree remove <group> --repo <name>`.

## Destructive changes

- Before deletion or an update that removes members, run without `--execute` and review the returned plan, affected paths, branches, and risks.
- Repeat with `--execute` only when the user has explicitly authorized that scope and its risks; otherwise present the plan for approval. Existing authorization does not need reconfirmation.
- Worktree deletion permanently removes its files and current local branch, including reused or unmerged branches. A detached HEAD has no branch to delete. Repository removal also affects configured members; read the whole plan.

## Results and failures

- Read the final JSON even on nonzero exit. Report completed and unfinished items, warnings, and retained effects. Cancellation or partial success does not roll back completed work.
- Explain unavailable resources and stop dependent actions; unrelated available resources remain usable.
- Use the CLI for workspace management. Do not edit private Modu records or bypass rejected actions with Git or shell deletion.
- Do not promise restoration, automatic repair, or import continuation. Resolve the reported cause before using ordinary Add/Create/Edit workflows for unfinished items.
