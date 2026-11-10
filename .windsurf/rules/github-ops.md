---
trigger: always_on
---

# Remote write operations

Never perform write operations against the repository unless the user
explicitly instructs it: no `git push`, no local `git commit`, no `gh`
writes (comments, closes, merges, releases, API mutations), no remote
branch or tag changes. Read operations, branch checkouts, stashing, and
requested worktree edits are always fine. When a task seems to imply a
write, confirm with the user rather than assuming — even when it feels
like implied consent.
