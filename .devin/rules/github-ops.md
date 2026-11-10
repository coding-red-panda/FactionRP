---
trigger: always_on
---

# Remote write operations

Core rule for this project: never perform write operations against the
repository's remote state unless the user explicitly instructs it.

This covers, at minimum:

- `git push`, force-push, branch/tag deletion on the remote
- `gh` write calls: issue/PR comments, closes, labels, merges, reviews,
  releases, `gh api` mutations (POST/PATCH/PUT/DELETE)
- Local `git commit` and any other repository mutation
- Any other command or API call that changes GitHub state

Read and local working-state operations are always fine: `gh` reads,
`git fetch`/`log`/`status`/`diff`, `git checkout`/`switch`/`restore`,
and `git stash`/`stash pop`. Worktree file edits requested by the task
follow the normal flow; anything that writes a commit or changes
remote/GitHub state needs an explicit instruction.

When a task seems to imply a write (e.g. "close the ticket", "commit
this"), confirm with the user rather than assuming intent — even when
the interpretation feels like implied consent. Offer the command or the
draft; let the user run or approve it.
