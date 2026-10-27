---
name: modu-desktop-release
description: Update the Modu Desktop version and CHANGELOG, then create a local release commit and Git tag, only when explicitly invoked as $modu-desktop-release.
---

# Modu Desktop Release

## Scope and entry points

- Run from the Modu source repository root. Follow repository instructions and task-specific references; review `Version.xcconfig` and `.github/workflows/ci.yml`.
- An explicit request for the full workflow authorizes staging and committing only `Version.xcconfig` and `CHANGELOG.md`, and creating the corresponding local tag. Viewing or editing this skill does not start a release.
- Pushing branches or tags and creating GitHub Releases are outside this workflow. Pushing a `v*` tag triggers CI publication.
- Change product version and build number only in `Version.xcconfig`, not generated `ModuVersion`. Workspace YAML `version`, CLI JSON `schema-version`, and dependency versions are independent.

## 1. Check the working tree and resume state

- For a new run, `git status --porcelain=v1 --untracked-files=all` must be empty. Otherwise list the changes and stop; do not automatically commit, stash, discard, or clean them.
- Confirm the intended release branch and no merge, rebase, or similar operation in progress. Record the branch and starting HEAD; keep all operations in this repository, not Modu-managed repositories or worktrees.
- On failure, preserve state without automatic rollback or tag deletion. Before resuming, verify the recorded branch, starting HEAD, target version, changes to the two files, and any release commit or tag. Continue from the failed step without repeating completed build increments, commits, or tags. Stop and explain if unrelated changes appear or ownership is uncertain.

## 2. Confirm the version and update configuration

- Use the highest semantic version among local stable `vX.Y.Z` tags as the baseline, not tag creation time. It must be an ancestor of the starting HEAD; otherwise explain and wait for the user to choose a baseline. With no release tags, explain that this is the first release and use all history through the starting HEAD.
- Review commits, diff statistics, and relevant actual diffs from the baseline to the starting HEAD. Summarize resulting behavior, not just commit titles.
- Use a supplied version after removing an optional leading `v`. Require `X.Y.Z`: three nonnegative integers without leading zeros or suffixes. It must exceed the baseline and be at least the current `MARKETING_VERSION`; an already configured but untagged target may proceed. The corresponding tag must not exist; never overwrite or move a tag.
- If no version is supplied, recommend a version with reasons and reasonable alternatives from the actual changes: patch for compatible fixes, minor for compatible features, major for incompatible behavior or interfaces. Account for the current configuration to avoid downgrading. Wait for the user's choice before editing, committing, or tagging.
- Once settled, recheck that the working tree is clean and the branch and HEAD are unchanged; stop and reassess otherwise. Set `MARKETING_VERSION` and increment the current integer `CURRENT_PROJECT_VERSION` by one without resetting it. If the build number is not an integer, explain and confirm how to proceed. Preserve other configuration and formatting.

## 3. Update CHANGELOG.md

- Use `## [X.Y.Z] - YYYY-MM-DD` with the user's local date and existing language/categories. Insert after Unreleased, if present, before historical releases. If `CHANGELOG.md` is absent, create it beginning with `# Changelog`.
- Describe actual, completed changes from the comparison range in concise Chinese, focusing on user impact; merge duplicates. Judge actual diffs, not commit types. Omit internal refactoring, tests, CI, tooling, dependencies, documentation, and skill changes without user impact; do not copy commits, enumerate implementation details, or invent benefits or test results. Highlight installation, upgrade, and compatibility changes, including CLI arguments, JSON, workspace YAML, and minimum macOS requirements. Include migration or recovery steps when users must act.
- If the range contains only internal maintenance with no user impact, use one concise Chinese note stating that fact to keep the section nonempty.
- Move this release's entries out of Unreleased, retaining other entries and historical releases. Verify the origin of any existing target-version section before editing it to avoid duplication.
- Run `python3 script/release_notes.py v<version>` and review the extracted notes. Fix validation failures before committing or tagging; CI reuses the section, so no separate release notes are needed.

## 4. Commit and create the tag

- Present the version, build number change, CHANGELOG summary, and intended tag. Once the user has specified or selected the version and requested the full workflow, do not ask again to stage, commit, or create the local tag.
- Run `git diff --check` and review both files' full diff. Recheck the starting branch and HEAD, absence of the target tag, and that only the expected changes to these two files exist. Stop on unrelated changes.
- Before committing, run `task test TEST_FILTER=ModuDesktopTests/VersionTests`. Confirm test-environment exit and cleanup through `run_tests.py`; stop without committing or tagging if tests or cleanup fail.
- Stage only the two files with `git add -- Version.xcconfig CHANGELOG.md`. Check `git diff --cached --check`, `git diff --cached --name-only`, and the staged diff for exactly these two files. Never use `git add .` or `git commit -a`.
- Use a Conventional Commits message in the language of the five most recent commits, for example `chore(release): vX.Y.Z`. Verify that the release commit's parent is the starting HEAD and only the two target files changed.
- Create an annotated tag: `git tag -a "v<version>" -m "v<version>" <release-commit>`. Verify `git rev-parse "v<version>^{commit}"` equals the release commit SHA, committed version fields and CHANGELOG heading match the tag, and the working tree is clean.
- Report version, build number, local commit SHA and tag, and verification results. If committing or tagging fails, stop subsequent steps and report completed and unfinished work; follow the state-preservation and resume rules above.
