# Agent instructions

You're one of several agents working in this repo at the same time, for two people. The coordination
rules are in [CONTRIBUTING.md](CONTRIBUTING.md). They're mandatory, so read them first. This file
covers how to do the work well.

## Coordination, in short

1. **Don't write code without a GitHub issue.** Check open issues and PRs first. Then claim an issue:
   assign yourself, add the `in-progress` label and post a comment naming your branch and the files
   you'll touch.
2. **Work only in your own worktree** under `.worktrees/`, on a branch named `<type>/<issue>-<desc>`.
   Never edit the main checkout, and never commit to `main`.
3. **Start every issue or PR comment with `[<agent> · <branch>]`.** For example:
   `[claude · feat/12-depth-slider]`.
4. **Watch for pings.** Run `scripts/gh-inbox` when you start, after each step you finish, before you
   push and before you open the PR. Deal with what it shows before you carry on. Before you touch
   anything outside your claim, comment on the issue that owns it.
5. **Use Conventional Commits.** The PR title uses the same format and the PR body includes
   `Closes #<issue>`. No approval is needed: merge your own PR once it's verified and rebased, unless
   the person running you asked you to wait.

## How to work

- **Understand before you change.** Read the code you'll touch and the code that calls it. For a bug,
  reproduce it first, then fix the root cause, not the symptom.
- **Post your plan on anything non-trivial.** A few lines in the issue before you start lets the other
  side object early.
- **Work in small steps.** Make one change, run it and commit. Every commit should build and pass the
  tests.
- **Stay in scope.** Don't refactor, rename or reformat anything outside your issue. If you spot
  something else worth fixing, open a new issue for it.
- **Match the codebase.** Follow the existing patterns, names and structure. Don't bring in a new
  library or pattern when an existing one does the job.
- **Treat dependencies as shared contracts.** Comment on the affected issues before you add or upgrade
  one.

## Tests and verification

- Get the test, lint and run commands from the README or the project files (`package.json`,
  `pyproject.toml`, `Makefile`). Don't invent them.
- **Fixing a bug:** first write a test that reproduces it and fails, then make it pass.
- **Adding behavior:** write tests for it, including the main way it can fail.
- Run the relevant tests before every push, and the full suite before you mark a PR ready.
- **Only call something done after you've run it.** Run the tests and use the feature for real: call
  the endpoint, load the page or run the command. Write what you ran and what you saw under "How I
  tested it" in the PR.
- Never delete, skip or weaken a test to get it passing. If a test is wrong, explain why in the PR.
- If the area you touched has no tests yet, say so in the PR and describe how you checked it instead.

## Do

- Act on your own within your issue's scope. Anything the issue covers doesn't need permission.
- Fail loudly. Report errors with context instead of swallowing them.
- Read secrets from the environment (`.env`) and never print or log them.
- Record decisions that others depend on in the issue.
- Leave your worktree clean when you stop: either committed and pushed, or with a comment explaining
  where things stand.

## Don't

- Edit another agent's files or guess what it meant. Ask in its issue.
- Keep retrying an approach that fails. After two or three failed attempts, stop and write what you
  tried and what you learned in the issue. Then change approach or ask.
- Leave debug prints or commented-out code, or a TODO without an issue number.
- Commit generated files, large binaries or anything that's gitignored.
- Run a destructive command unless you were asked to. That includes `git reset --hard`, force-pushing
  a branch that isn't yours and `rm -rf` outside your worktree.

## When you finish

1. The tests pass and you've checked the feature by running it.
2. You've rebased on `origin/main` and everything still passes.
3. The PR is marked ready, with `Closes #<issue>` and notes on how you tested it.
4. You've squash-merged it (`gh pr merge --squash`) and commented on the issue.
5. You've removed your worktree (see CONTRIBUTING.md).
