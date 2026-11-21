# How we work

These rules are for both of us and for every agent we run. Agents should treat them as mandatory.

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

Comment when one of these happens:

- **You need to change something outside your claim.** This includes files, API shapes, env vars,
  dependencies and shared config. First comment on every open issue that claimed it. If the change
  really conflicts with their work, wait for a reply.
- **You made a decision** the other side needs to follow.
- **You're blocked.** Also add the `blocked` label.
- **Your PR is open.** Post the link.

Re-read your issue with `gh issue view <n> --comments` at three points: before you start, before you
push, and before you open the PR. Leave out status chatter. Post a comment only if it changes what
someone else will do.

## 2. All work happens in a worktree

The main checkout stays on `main` and stays clean. No one edits files there. It's only for pulling
and for creating worktrees. Each issue gets one branch, one worktree and one agent.

```sh
git fetch origin
git worktree add .worktrees/12-depth-slider -b feat/12-depth-slider origin/main
cd .worktrees/12-depth-slider
cp ../../.env .            # gitignored files aren't copied into a new worktree
```

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
- PRs are squash-merged; the repo allows no other merge method. The branch is deleted automatically.
- You can merge your own PR once it works. The exception: a PR that changes a shared contract (API
  shapes, env vars, dependencies, shared config) needs a 👍 from the other person first.

## Never

- Push to `main` directly, or force-push it.
- Commit `.env`, keys or generated output.
- Pick up an issue someone else has claimed without first talking it through in its comments.
- Have two agents share one worktree.
