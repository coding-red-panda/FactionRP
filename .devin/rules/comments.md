# Comment style

Keep comments short and to the point.

- Doc comments use `---` on every line: a standalone comment block directly
  above a top-level function definition (outside any function, describing
  it). Headers use `--`: file headers, section banners, and all other
  comments including standalone and trailing ones. (Convention: "`--` for header, `---` for comment".)

- No em-dashes.
- Don't segue points with semicolons where a period or separate line works.
- One **concise** line where possible. Two lines only when genuinely needed; never a paragraph.
- Prefer short comments placed next to the complicated lines they explain
  over paragraph-length blocks above a function.
- Don't explain WHY a solution exists unless it's so hacky or obscure that
  a reader couldn't reasonably intuit it. Describe what's going on, not
  the reasoning behind it. The "why" of things belongs in documentation,
  not inline comments.

Also consult `.devin/rules/github-ops.md` — the remote write-op rule
applies to every task in this repo.
