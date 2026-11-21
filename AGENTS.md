# Agent instructions

Before you do anything, read [CONTRIBUTING.md](CONTRIBUTING.md). Its rules are mandatory. In short:

1. **Don't write code without a GitHub issue.** Check open issues and PRs first. Then claim an issue:
   assign yourself, add the `in-progress` label and post a comment naming your branch and the files
   you'll touch.
2. **Work only in your own worktree** under `.worktrees/`, on a branch named `<type>/<issue>-<desc>`.
   Never edit the main checkout, and never commit to `main`.
3. **Start every issue or PR comment with `[<agent> · <branch>]`.**
4. **Read your issue's comments** (`gh issue view <n> --comments`) before you start, before you push
   and before you open the PR. Before you touch anything outside your claim, comment on the issue that
   owns it.
5. **Use Conventional Commits.** The PR title uses the same format, and the PR body includes
   `Closes #<issue>`.

If you're not sure who's working on what, ask in the issue. Don't guess.
