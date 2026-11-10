# FactionRP — agent notes

WoW retail RP addon. Lua 5.1 semantics (WoW's runtime). `FactionRP.toc`
defines the load order.

## Info for Agents
- It is imperative that, if nothing else, you start with `README.md` and `/doc/protocol.md`
  These inform context, design and decision-making for the project, as well as structure and mechanics.
- Don't existence check Blizz API unless it is for feature discovery. Missing API should fail hard.
- Generally don't existence check anything unless it's intended to fail gracefully. (it makes debugging harder)
- We have self-tests that use the live pipeline for protocol tests. These are generally reliable indicators
  for whether something will work in a live env. Use them.
- Protocol is a sensitive area. FRP does a gigajillion checks everywhere to keep malformed envelopes treated sanely,
  BUT this is still an area prone to breakage from haphazard churn. Prefer treating protocol changes as last resort.

## Your job
- Be concise and informative when asked questions.
- Even if you're in bypass mode, always ask before editing code (unless directly instructed).
- Research answers, don't assume.
- Always verify API when writing WoW code, either through wow-ui-source locally, https://warcraft.wiki.gg/ or both.
- Make targeted changes; note discovered issues while working for the user, but don't drive-by code.
- Be efficient, but readable; shortest code possible to achieve the result. Func and var names need 
  to be descriptive of their roles, unless f.ex. "i = 1" ephemerals in loops and similar cases.

## Core rule

No write operations against the repository unless the user explicitly
instructs it: no `git push`, no local `git commit`, no `gh` writes
(comments, closes, merges, releases, API mutations). Reads and requested
worktree edits are always fine. When a task seems to imply a write,
confirm rather than assume — even if it feels like implied consent. See
`.devin/rules/github-ops.md`.

## Project rules (if this dir exists: `.devin/rules/`)

- `github-ops.md` — remote write-op gate (above).
- `comments.md` — comment style: `---` on every line for doc comments
  above top-level functions, `--` for headers/banners/inline. Short, no
  WHY-prose.
- `blizzard-api.md` — verify Blizzard API names against the local ui
  source before use.
- Always check rules at the start of a session. If the session drags on, re-check rules
  after compression.
- Unless there is a rule that states otherwise, under no circumstances are you to
  write or push to any repo autonomously. Always confirm, even if your interpretation
  is implied consent.

## Project rules (generally, if you are not devin)
- ALWAYS check the `/rules/` directory.
- Always check rules at the start of a session, as well as after compression.
- Unless there is a rule that states otherwise, under no circumstances are you to
  write or push to any repo autonomously. Always confirm, even if your interpretation
  is implied consent.

## Documentation rules
- Always keep `README.md` and `/doc/protocol.md` up to date.
  These are our lifeline for tracking the state of the project,
  and is considered critical.
- WHY explanations go into either README or protocol, or both,
  whichever is relevant for the work. If you would normally comment why
  code does what it does and it isn't obvious from simply reading it,
  update docs with it. Trivial explanations and/or easily deducable ones
  do not get docs.

## Verification

- `luac -p` syntax-check any edited `.lua` file.
- `tools/find_shadows.py`, `tools/find_orphans.py` — static analysis
  helpers; compare against baseline, they report pre-existing findings.
