@AGENTS.md

# Claude Code

## Use subagents by default

Keep your own context for orchestration: planning, deciding, talking in the issue and checking
results. Hand the rest of the work to subagents (the Agent tool) by default:

- **Searching or reading more than a few files:** use a subagent that returns a short summary with
  `file:line` references.
- **Independent pieces of work:** run parallel subagents, all launched in one message.
- **Long test runs or builds:** use a subagent that runs them and reports only the failures.
- **Review:** before you mark a PR ready, have a fresh subagent review the diff
  (`git diff origin/main...HEAD`). Give it the code, not your conclusions.

Give each subagent a single scoped task. Name the exact files, the goal and what "done" looks like,
and say what you want back, such as a summary or a list of findings. Never just say "look around".

Subagents work inside your issue. They don't open issues or PRs, and they don't post comments; you
do that, with your tag. If subagents edit files in parallel, they must either touch different files
or run with `isolation: "worktree"`, after which you merge their work into your branch.

Do small jobs yourself. A one-file edit, or a lookup where you already know where to look, is
quicker without a subagent.

## Watching for pings

Comments addressed to you reach you in two ways:

1. **Automatically.** `.claude/settings.json` runs `scripts/gh-inbox --hook` when the session starts
   and on every prompt. New comments on your issue or PR, or any that name your branch, are added to
   your context.
2. **While you work on your own.** As soon as you've claimed an issue, start a Monitor with these
   settings:
   - command: `scripts/gh-inbox --watch 60`
   - description: `GitHub pings for <branch>`
   - timeout_ms: `1800000`

   Monitors expire after 30 minutes, so re-arm it every time it expires, until your PR is merged.

When a ping arrives:

1. Read the whole thread with `gh issue view <n> --comments`.
2. Reply with your tag.
3. Change your plan if the ping requires it.
4. If only a human can answer it, say so in your reply and tell the person running you.
