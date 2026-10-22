#!/usr/bin/env python3
"""Find dangler candidates in FactionRP: symbols defined but never referenced
outside their own definition site(s). Adapted from WoW-Yapper's find_orphans.py.

Requires: Python 3.6+ (f-strings, pathlib-free; no third-party packages).

Usage (from the repo root):

    python tools/find_orphans.py          # scans src/ by default
    python tools/find_orphans.py src      # explicit scan directory

What it reports: a symbol whose total word occurrences never exceed its
definition-site count is a dangler candidate — e.g. a function defined once
and never called.

How it works: every identifier in every .lua file is counted as a word;
definitions are found by regex for local/member/assigned functions, local
variables (incl. multi-decl `local a, b =`), `C.*` constants, and `ns.*`
fields. Strings and comments (incl. --[[ ]] blocks) are stripped first.

Caveats: regex-based, so expect noise in BOTH directions — every candidate
needs a manual grep to confirm, and some dead code is invisible:
- Dynamic dispatch defeats it: `SECTIONS.mediums()` is alive via
  `SECTIONS[section]()`, but the word `mediums` never appears at a call
  site, so it reports as dead. Verify table-dispatched names especially.
- Shared names hide dead code: a dead `reset` in one file is masked by a
  live `reset` elsewhere — words are counted project-wide, not per-scope.
- Dead parameters and dead whole files (missing from the .toc) are not
  detected; check those separately.

It also reports `self.*` fields written but never read via `self.` — note
that reads on the instance through another name (`adapter.name`) still
count as dead to this check, so confirm those candidates too.
"""

import os
import re
import sys
from collections import defaultdict

SKIP_DIR_NAMES = {
    ".release", "backup", "scratch", "tools", "test", "tests",
    "testdata", "fixtures", "Libs", ".staging", "doc",
}

# Definition patterns. member_func catches `function X:name`/`function X.name`
# (method name only); member_const catches `C.FOO =` and `Util.x =` style field
# defs on capitalized module tables and `ns.*`; upvalue_func catches the
# `x = function` forward-decl pattern.
RE_DEFS = {
    'local_func': re.compile(r"\blocal\s+function\s+([a-zA-Z0-9_]+)"),
    'member_func': re.compile(r"\bfunction\s+[a-zA-Z0-9_]+[:.]([a-zA-Z0-9_]+)"),
    'assign_func': re.compile(r"\b(?:[a-zA-Z0-9_]+\.)*([a-zA-Z0-9_]+)\s*=\s*function"),
    'local_var': re.compile(r"\blocal\s+([a-zA-Z0-9_]+(?:\s*,\s*[a-zA-Z0-9_]+)*)\s*=[^=]"),
    'member_const': re.compile(r"\b(?:ns|C|[A-Z][a-zA-Z0-9_]*)\.([a-zA-Z0-9_]+)\s*=[^=]"),
}

IGNORE_WORDS = {
    "ns", "Util", "self", "this", "value", "text", "event", "data", "args",
    "i", "j", "k", "v", "x", "y", "z", "r", "g", "b", "a", "w", "h",
    "fs", "tex", "tbl", "cur", "prev", "str", "num", "key", "idx",
    "true", "false", "nil", "and", "not", "local", "end", "then",
    "function", "return", "elseif", "else", "for", "while", "do", "in",
    "repeat", "until", "break", "if", "or",
}

def clean_line(line):
    line = re.sub(r'\"[^\"]*\"', ' STR ', line)
    line = re.sub(r"'[^']*'", ' STR ', line)
    line = line.split('--')[0]
    return line

def strip_multiline(content):
    # Strip long strings/comments, preserving line numbers.
    return re.sub(
        r'--?\[\[.*?\]\]',
        lambda m: "\n" * m.group(0).count("\n"),
        content,
        flags=re.DOTALL,
    )

def analyze(src_dir):
    all_defs = defaultdict(list)
    word_counts = defaultdict(int)

    for root, dirs, files in os.walk(src_dir):
        dirs[:] = [d for d in dirs if d.lower() not in SKIP_DIR_NAMES]
        for fn in files:
            if not fn.endswith('.lua'):
                continue
            path = os.path.join(root, fn)
            with open(path, 'r', encoding='utf-8') as f:
                lines = strip_multiline(f.read()).splitlines()

            for i, raw in enumerate(lines, 1):
                cleaned = clean_line(raw)
                if not cleaned.strip():
                    continue
                for w in re.findall(r'\b([a-zA-Z0-9_]+)\b', cleaned):
                    word_counts[w] += 1

                for kind, regex in RE_DEFS.items():
                    m = regex.search(cleaned)
                    if not m:
                        continue
                    names = m.group(1)
                    for name in (n.strip() for n in names.split(',')):
                        if (name and name not in IGNORE_WORDS
                            and len(name) > 3
                            and (path, i) not in all_defs[name]):
                            all_defs[name].append((path, i))
    return all_defs, word_counts

def main():
    src_dir = sys.argv[1] if len(sys.argv) > 1 else 'src'
    all_defs, word_counts = analyze(src_dir)

    orphans = []
    for name, locs in all_defs.items():
        total = word_counts[name]
        if total <= len(locs):
            orphans.append((name, locs, total, len(locs)))

    orphans.sort(key=lambda x: (x[1][0][0], x[1][0][1]))
    print(f"{'Name':<34} | {'Refs':<4} | {'Defs':<4} | Location")
    print("-" * 70)
    for name, locs, total, defs in orphans:
        locs_str = ", ".join(f"{os.path.basename(p)}:{l}" for p, l in locs)
        print(f"{name:<34} | {total:<4} | {defs:<4} | {locs_str}")
    print(f"\n{len(orphans)} candidates. Verify each with grep before removing.")

    # Second pass: self.* fields written but never read via `self.`.
    # Reads through another name for the same instance (adapter.name)
    # are invisible here — verify before removing.
    print("\nWrite-only self.* fields:")
    found = 0
    for root, dirs, files in os.walk(src_dir):
        dirs[:] = [d for d in dirs if d.lower() not in SKIP_DIR_NAMES]
        for fn in files:
            if not fn.endswith('.lua'):
                continue
            path = os.path.join(root, fn)
            with open(path, 'r', encoding='utf-8') as f:
                lines = strip_multiline(f.read()).splitlines()
            fields = {}
            for i, raw in enumerate(lines, 1):
                for m in re.finditer(r'\bself\.(\w+)\s*=[^=]', clean_line(raw)):
                    fields.setdefault(m.group(1), []).append(i)
            for field, sites in sorted(fields.items()):
                uses = sum(
                    1 for i, raw in enumerate(lines, 1)
                    for _ in re.finditer(r'\bself\.' + field + r'\b', clean_line(raw))
                    if i not in sites
                )
                if uses == 0:
                    sites_str = ", ".join(str(s) for s in sites)
                    print(f"  {os.path.basename(path)}:{sites_str}  {field}")
                    found += 1
    print(f"  {found} candidates.")

if __name__ == "__main__":
    main()
