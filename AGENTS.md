# Agent Rules

## Workspace
- All work happens inside `/workspace` (the repo checkout).
- Subagent worktrees live at `/workspace/.worktrees/<task-name>/`.
- Never read or write outside `/workspace`.

## Git Rules
- You are on a **feature branch**. Never push to or merge into `main`.
- Never use `git add -A` or `git add .` — always stage specific files by path.
- Always run `git status` before committing to confirm you are only staging
  files you modified in this session.
- Write clear, descriptive commit messages.

## Subagent Workflow

Orchestrator responsibilities:
1. Use the `spawn_subagent` tool to delegate a well-scoped task.
2. Provide complete, unambiguous instructions including acceptance criteria.
3. After the subagent finishes, report the PR URL to the user.
4. Do not merge PRs — the user reviews and merges.

Subagent responsibilities:
1. Work only inside your assigned worktree.
2. Commit only files you created or modified.
3. When done, open a PR against the **feature branch** (not `main`) using
   `gh pr create`.
4. Write a clear PR title and body explaining what was changed and why.
5. Write the PR URL to the designated file AND output it as the last line
   of your response.

## PR Format
- Base branch: the feature branch you were branched from (passed in instructions)
- Title: short imperative description (e.g. "Add integration tests for auth module")
- Body: what was done, why, how to test it, any caveats
- Use `--body-file` with a temp file for long PR bodies (avoids shell escaping issues)
