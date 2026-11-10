---
trigger: always_on
---

# Blizzard API verification

Verify every Blizzard API reference against the local ui source before
writing or editing it. Never assert an API name, signature, or patch
history from memory.

Source of truth (12.x client): a local checkout of the extracted Blizzard
UI source (e.g. github.com/Gethe/wow-ui-source). Inside it, the generated
API docs live at:

    Interface/AddOns/Blizzard_APIDocumentationGenerated/*.lua

How to check:

- `C_*` namespaced functions: grep the generated docs for `Name = "<fn>"`.
- Older globals (`BN*`, `Unit*`, `Get*`, chat functions): grep the ui
  source for Blizzard's own usage, then check warcraft.wiki.gg
  `API_<name>` game-type ranges for removal patches.
- Removed names may exist via `Blizzard_Deprecated*` shims gated on the
  `loadDeprecationFallbacks` CVar (default on for release, off on some
  test builds). Prefer the documented replacement over the shimmed
  global.
- Events and enums: same docs files, `LiteralName` / `Enum.<name>`
  entries.
- When reporting whether an API exists or when it changed, cite the
  check that was run. Memory is not a citation.

Before writing or editing code, also consult `.devin/rules/comments.md`
for comment style. It is frequently missed.

Also consult `.devin/rules/github-ops.md` — the remote write-op rule
applies to every task in this repo.
