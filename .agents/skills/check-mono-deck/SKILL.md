---
name: check-mono-deck
description: "Check and improve MonoDeck tests, documentation, and prompts, only when explicitly invoked as $check-mono-deck."
---

# Check MonoDeck

## Scope and changes

Determine this pass's scope before retrieving diffs:

1. Run `git status --short --untracked-files=all` to identify all uncommitted files. When changes exist, review tests, documentation, and prompts affected by them; otherwise review these areas across the repository.
2. After determining scope, run `git diff HEAD` only if tracked changes need inspection; it includes both staged and unstaged changes.
3. After determining scope, if untracked changes need inspection, run `git diff --no-index -- /dev/null <untracked-file>` separately for each `??` file reported in step 1, quoting the actual path as needed. Exit status 1 means differences were found, not that the command failed.

- Read related implementation, callers, and dependencies for context; limit edits to tests, documentation, and prompts. In change-scoped mode, modify related files only for fixes or synchronization required by the changes.
- Make minimal fixes for confirmed issues while preserving intended behavior and public contracts. Report implementation defects, unresolved risks, or product decisions instead of guessing. Preserve unrelated changes and the index; do not stage or commit.

## Tests

- Retain tests that meaningfully protect core behavior, user data, critical failure or cancellation paths, public contracts, or concurrency that is difficult to assess by review.
- Merge, simplify, or remove duplicate, obsolete, and low-value tests and unused test doubles or fixtures. Remove extreme, unusual, or rare scenarios that do not guard against meaningful regressions. Do not retain tests solely for wording, styling, trivial mappings, implementation details, or coverage numbers.
- Add tests only for a concrete regression risk missing from existing coverage; first reuse or adapt existing cases. A constructible scenario alone does not justify a new test or a larger parameter matrix.

## Documentation and prompts

- Use code as the source of truth for implemented behavior; do not weaken explicit requirements to match a defect. Correct stale, redundant, or conflicting descriptions and fill material gaps in usage, design, or maintenance guidance.
- Keep product documentation focused on users, core features, and essential usage. Keep development documentation focused on core logic, key design decisions, and constraints. Link to code or command help for details instead of cataloging every feature or implementation detail.
- Maintain one authoritative source for each rule and reference it briefly elsewhere. Do not turn isolated incidents into general requirements.

## Validation and delivery

- Reuse existing verification entry points, starting with the smallest relevant checks; expand only for failures, cross-workflow impact, or unresolved risk. For documentation-only or prompt-only changes, verify paths, commands, and references rather than adding tests.
- Review all in-scope staged and unstaged changes, including untracked files; run `git diff --check` and `git diff --cached --check`. Confirm cleanup of this pass's verification processes and temporary data. Report scope, fixes/removals, actual checks, and unresolved findings with locations and impact.
