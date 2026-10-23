---
name: modu-desktop-release
description: Update the Modu Desktop version and CHANGELOG, then create a local release commit and Git tag, only when explicitly invoked as $modu-desktop-release.
---

# Modu Desktop Release

## Scope and entry points

- Run from the Modu source repository root. Apply the repository instructions and their task-specific references, then review `Version.xcconfig` and `.github/workflows/ci.yml`.
- An explicit request to run the full workflow authorizes staging and committing `Version.xcconfig` and `CHANGELOG.md`, and creating the corresponding local tag. Viewing or editing this skill does not start a release.
- Pushing branches, pushing tags, and creating GitHub Releases are outside this workflow. Pushing a `v*` tag triggers the CI release pipeline.
- Update the product version and build number only in `Version.xcconfig`; do not edit the generated `ModuVersion`. Workspace YAML `version`, CLI JSON `schema-version`, and dependency versions are maintained independently.

## 1. Check the working tree and resume state

- For a new run, inspect staged, unstaged, and untracked files with `git status --porcelain=v1 --untracked-files=all`. The output must be empty. If any changes exist, list them and stop; do not automatically commit, stash, discard, or clean them.
- Confirm that the current branch is the intended release branch and no merge, rebase, or similar operation is in progress. Record the branch and starting HEAD. Keep all subsequent operations in this repository; do not operate on other repositories or worktrees managed by Modu.
- When resuming a failed step, first verify the previously recorded branch, starting HEAD, target version, changes to the two files, and any existing release commit or tag. Continue from the failed step, preserving verified results from this workflow. Do not increment the build number, commit, or tag again. Stop and explain if unrelated changes appear or ownership cannot be established.

## 2. Confirm the version and update configuration

- List local tags and use the highest semantic version among stable `vX.Y.Z` tags as the comparison baseline; do not sort by tag creation time. Verify that the tag is an ancestor of the starting HEAD. If it is outside the current history, explain and wait for the user to choose a baseline. If no release tag exists, explain that this is the first release and use all history through the starting HEAD.
- Read the commits, diff statistics, and relevant actual diffs from the baseline to the starting HEAD, for example `git log <tag>..<head>`, `git diff --stat <tag> <head>`, and `git diff <tag> <head> -- <relevant-paths>`. Summarize the resulting behavior rather than relying only on commit titles.
- If the user specifies `version`, use it directly, allowing one leading `v` to be removed. This workflow requires three nonnegative integer components without leading zeros (`X.Y.Z`) and an incrementing integer build number. The underlying generation script accepts one to three numeric components but no prerelease or build metadata suffixes. The target version must exceed the baseline and must not be lower than the current `MARKETING_VERSION`; an already configured target version without a release tag may proceed. The corresponding `vX.Y.Z` tag must not exist. Never overwrite or move an existing tag.
- If no version is specified, recommend a version with reasons and reasonable alternatives based on the actual changes: patch for compatible fixes, minor for compatible features, and major for incompatible behavior or interface changes. Increment from the baseline tag while accounting for the current configuration to avoid a downgrade. Ask the user to choose and wait for a reply; do not edit files, commit, or tag before receiving that choice.
- Once the version is settled, verify that the working tree is still clean and the branch and HEAD are unchanged. Stop and reassess if the context changed. Update `MARKETING_VERSION` and increment the current integer `CURRENT_PROJECT_VERSION` by one without resetting it. If the build number does not follow this format, explain and confirm how to proceed. Preserve all other configuration and formatting; do not edit generated version source or other Xcode project fields.

## 3. Update CHANGELOG.md

- Use release headings in the form `## [X.Y.Z] - YYYY-MM-DD`, with the user's local date. Preserve the existing language and categories. Place the new release after Unreleased, if present, and before historical releases. If the file does not exist, create `CHANGELOG.md` beginning with `# Changelog`.
- Include only completed, actual changes within the comparison range, focusing on user-visible behavior and information needed for usage or upgrade decisions. Include features, fixes, interaction changes, and substantiated changes to performance, stability, resource usage, or security. Do not infer unverified benefits from internal refactoring or dependency upgrades.
- By default, omit purely internal refactoring, tests, CI, developer tooling, and dependency, documentation, or skill changes without user impact. When such changes have clear user impact, describe that impact only. Judge the actual diff rather than mechanically filtering by commit types such as `feat`, `fix`, or `chore`.
- Write concise Chinese descriptions of the usage scenario and resulting behavior. Merge duplicate entries; do not copy the commit list, enumerate implementation details, or invent features or test results. Highlight installation, upgrade, and compatibility changes, especially CLI arguments, JSON output, workspace YAML, and minimum macOS requirements. Include migration or recovery steps when user action is required.
- If the comparison range contains only internal maintenance with no user-visible changes, write a single concise Chinese note stating that fact. This satisfies the nonempty-section requirement; do not invent improvements to fill the changelog.
- Preserve historical releases. Move only entries belonging to this release out of Unreleased, retaining anything not yet released. If a section for the same version already exists, verify its origin before editing to avoid duplication.
- Run `python3 script/release_notes.py v<version>` after editing. Verify that the tag matches the product version, the release section is unique and nonempty, and the extracted notes are correct. Fix failures before committing or creating a tag. CI reuses this script and combines the section with installer information for the GitHub Release body; no separate release notes are needed. This step only prepares the release locally; CI publishes after the tag is pushed.

## 4. Commit and create the tag

- Present the target version, build number change, CHANGELOG summary, and intended tag. If the user has already specified or selected the version and requested the full workflow, proceed without asking again for authorization to stage, commit, or create the local tag.
- Run `git diff --check` and review the full diff of both files. Verify that the branch and HEAD still match their starting values, the tag still does not exist, and the working tree contains only the expected changes to these two files. Stop immediately if unrelated changes appear.
- Before committing, run `task test TEST_FILTER=ModuDesktopTests/VersionTests`. Reuse the existing tests to verify that the App product version and build number match the generated values and that the bundled CLI reports the same product version. Confirm that the test environment exited and was cleaned up through `run_tests.py`. Stop without committing or creating a tag if tests or cleanup fail.
- Stage only the target files with `git add -- Version.xcconfig CHANGELOG.md`. Then use `git diff --cached --check`, `git diff --cached --name-only`, and the staged diff to confirm that the commit contains exactly these two files. Do not use `git add .` or `git commit -a`.
- Use a Conventional Commits message in the language of the five most recent commit messages, for example `chore(release): vX.Y.Z`. After committing, verify that the new commit's parent is the starting HEAD and its only changed files are `Version.xcconfig` and `CHANGELOG.md`.
- Create an annotated tag on the release commit: `git tag -a "v<version>" -m "v<version>" <release-commit>`. Verify that `git rev-parse "v<version>^{commit}"` equals the release commit SHA, the committed version fields and CHANGELOG heading match the tag, and the final working tree is clean.
- Report the version, build number, commit SHA, tag, and verification results, making clear that the commit and tag are local. If committing or tagging fails, stop subsequent steps, report completed and unfinished work, and preserve the current state. Before resuming, verify existing results and continue from the failed step; do not duplicate commits, automatically roll back, or delete tags.
