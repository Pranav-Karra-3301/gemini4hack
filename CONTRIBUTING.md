# How we work

These rules are for both of us and for every agent we run. Agents should treat them as mandatory.
[AGENTS.md](AGENTS.md) covers how agents do the work itself: tests, scope, and dos and don'ts.

## 1. Every piece of work starts with a GitHub issue

Issues are where our agents talk to each other, so no one starts coding without one.

1. **Check first.** Run `gh issue list --state open` and `gh pr list`. If the same work, or work in the
   same files, is already underway, comment on that issue. Don't start a parallel one.
2. **Open or claim the issue.** If there's no issue yet, open one using the Task template's sections.
   Assign yourself and add the `in-progress` label:
   ```sh
   gh issue create --title "Add depth slider" --body "..." --assignee @me --label in-progress
   ```
3. **Post a claim comment** that names your branch and the files or areas you expect to touch.

Our agents post under our own GitHub accounts, so the author name alone doesn't say which agent wrote
a comment. Start every agent comment with a tag naming the agent and its branch:

```
[claude · feat/12-depth-slider] Claiming. Touching web/src/controls.js, and server/app.py for a new /depth route.
```

**To ping an agent,** comment on its issue or PR, or write its branch name in your comment.
**To ping a person,** @mention them. Agents leave @mentions to the humans.

Comment when one of these happens:

- **You need to change something outside your claim.** This includes files, API shapes, env vars,
  dependencies and shared config. First comment on every open issue that claimed it. If the change
  really conflicts with their work, wait for a reply.
- **You made a decision** the other side needs to follow.
- **You're blocked.** Also add the `blocked` label.
- **Your PR is open.** Post the link.

Leave out status chatter. Post a comment only if it changes what someone else will do.

## 2. All work happens in a worktree

No one edits files in the main checkout. It stays on `main`, and it's only for pulling, creating
worktrees and running a coordinator session (see section 4). Each issue gets one branch, one worktree
and one agent.

```sh
git fetch origin
git worktree add .worktrees/12-depth-slider -b feat/12-depth-slider origin/main
cd .worktrees/12-depth-slider
cp ../../.env .            # gitignored files aren't copied into a new worktree
claude                     # start the agent here
```

The first time you push the branch, run `git push -u origin HEAD`.

`.worktrees/` is gitignored. `claude --worktree` is fine to use, but rename its branch to match the
convention before you push, e.g. `git branch -m feat/12-depth-slider`. If two worktrees run dev servers
at the same time, change the ports in one of them.

After your PR merges, run this from the main checkout:

```sh
git worktree remove .worktrees/12-depth-slider
git branch -D feat/12-depth-slider     # use -D: after a squash merge, git doesn't see the branch as merged
git pull
```

## 3. Branches, commits and pull requests

**Branches** are named `<type>/<issue>-<short-description>` in lowercase kebab-case. The types are
`feat`, `fix`, `refactor`, `docs`, `test` and `chore`.
For example: `feat/12-depth-slider`, `fix/15-mask-offset`, `chore/3-add-ci`.

**Commits** follow [Conventional Commits](https://www.conventionalcommits.org): `type(scope): summary`,
written in the imperative and kept to 72 characters or fewer.
For example: `feat(web): add depth slider`, `fix(server): clamp masks to image bounds`.

**Pull requests:**

- One issue per PR. Keep PRs small, and split big work into several issues.
- Write the title in the commit format. It becomes the squash commit on `main`.
- Fill in the template. The body must include `Closes #12` so the issue closes when the PR merges.
- After your first commit, push and open a **draft** PR (`gh pr create --draft`). That way the other
  side can see which files you're changing.
- Before you mark the PR ready, run `git fetch origin && git rebase origin/main`, fix any conflicts and
  check that it still runs. Then push with `git push --force-with-lease`.
- **PRs need no approvals.** Merge your own PR with `gh pr merge --squash` once it works and is
  rebased. If it changes a shared contract (API shapes, env vars, dependencies, shared config),
  comment on the affected issues first.
- `main` accepts only squash-merged PRs. Direct pushes and force-pushes are blocked, and the branch
  is deleted automatically after the merge.

## 4. Knowing when you're pinged

GitHub doesn't notify you about comments posted from your own account, and that's where your own
agents post. So pings come from `scripts/gh-inbox`, which reads the repo's comments directly.

- **In a worktree,** it shows comments by others on that branch's issue or PR, plus any comment that
  names the branch.
- **In the main checkout,** it shows any comment that @mentions you.

You need the GitHub CLI, logged in (`gh auth login`).

**With Claude Code there's almost nothing to set up.** The repo's `.claude/settings.json` runs
`scripts/gh-inbox --hook` when a session starts and on every prompt, so new pings land in the agent's
context. Approve the project's hooks the first time Claude Code asks. [CLAUDE.md](CLAUDE.md) also tells
each agent to start a background Monitor (`scripts/gh-inbox --watch 60`) once it claims an issue. That
way pings reach it in the middle of a task, not only when you type.

**For yourself:**

- Run a coordinator Claude session in the main checkout. Use it to triage issues and start agents; it
  sees anything that @mentions you. To keep it checking while you're away, run:
  ```
  /loop 10m Run scripts/gh-inbox and tell me about anything new.
  ```
- On GitHub, set the repo's **Watch** to at least "Participating and @mentions" and turn on GitHub
  Mobile notifications, so you also see the other person's @mentions on your phone.

Any other agent can call `scripts/gh-inbox` by hand. Use `scripts/gh-inbox --help` for the options.

## Never

- Push to `main` directly, or force-push it.
- Commit `.env`, keys or generated output.
- Pick up an issue someone else has claimed without first talking it through in its comments.
- Have two agents share one worktree.
