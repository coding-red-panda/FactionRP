#!/usr/bin/env python3
"""Scan shipped Lua for shadowed locals.

Flags any declaration (local, function parameter, for-loop variable, or
implicit method `self`) that re-binds a name still live in an enclosing
scope. File-level upvalues shadowed from inside a function are the
dangerous kind; block-level re-binds are usually benign but still listed.

Usage: python tools/find_shadows.py [src_dir]
"""

import re
import sys
from bisect import bisect_right
from pathlib import Path

TOKEN = re.compile(
    r"[A-Za-z_][A-Za-z0-9_]*"      # identifiers/keywords
    r"|\.\.\.|\.\.|::"             # varargs, concat, labels
    r"|==|~=|<=|>="                # comparisons
    r"|[=+*/%^#<>(){}\[\];:,.~\-]" # single-char tokens
)


def clean(src: str) -> str:
    """Blank comments and string literals, preserving newlines/columns."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("--", i):
            m = re.match(r"\[=*\[", src[i + 2:i + 12])
            if m:  # long comment
                end = "]" + "=" * m.group(0).count("=") + "]"
                k = src.find(end, i + 2 + m.end())
                k = n if k < 0 else k + len(end)
            else:  # line comment
                k = src.find("\n", i + 2)
                k = n if k < 0 else k
            out.append(re.sub(r"[^\n]", " ", src[i:k]))
            i = k
        elif c in "\"'":
            k = i + 1
            while k < n and src[k] != c and src[k] != "\n":
                k += 2 if src[k] == "\\" else 1
            out.append(re.sub(r"[^\n]", " ", src[i:k + 1]))
            i = k + 1
        elif c == "[" and re.match(r"\[=*\[", src[i:i + 12]):
            m = re.match(r"\[=*\[", src[i:i + 12])
            end = "]" + "=" * m.group(0).count("=") + "]"
            k = src.find(end, i + m.end())
            k = n if k < 0 else k + len(end)
            out.append(re.sub(r"[^\n]", " ", src[i:k]))
            i = k
        else:
            out.append(c)
            i += 1
    return "".join(out)


def scan(path: Path):
    src = clean(path.read_text(encoding="utf-8-sig"))
    nl = [i for i, c in enumerate(src) if c == "\n"]
    toks = [(bisect_right(nl, m.start()) + 1, m.group(0))
            for m in TOKEN.finditer(src)]

    scopes = [{}]  # stack[0] = file scope; each maps name -> decl line
    findings = []
    pending_for = []

    def declare(line, name, kind):
        for depth in range(len(scopes) - 1, -1, -1):
            if name in scopes[depth]:
                where = "file-local" if depth == 0 \
                    else f"outer local (scope depth {depth})"
                findings.append(
                    f"{path.name}:{line}: `{name}` ({kind}) shadows "
                    f"{where} from line {scopes[depth][name]}")
                return
        scopes[-1][name] = line

    i = 0
    while i < len(toks):
        line, t = toks[i]
        if t == "local":
            if i + 1 < len(toks) and toks[i + 1][1] == "function":
                declare(toks[i + 2][0], toks[i + 2][1], "local function")
                i += 1  # land on `function`; loop next iter handles it
                continue
            else:
                j = i + 1
                while j < len(toks):
                    lt = toks[j][1]
                    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", lt):
                        declare(toks[j][0], lt, "local")
                        j += 1
                        if j < len(toks) and toks[j][1] == ",":
                            j += 1
                            continue
                    break
                i = j - 1
        elif t == "function":
            scopes.append({})
            # skip the function name (ident, `.`, `:`) up to `(`
            j, method = i + 1, False
            while j < len(toks) and toks[j][1] != "(":
                method = method or toks[j][1] == ":"
                j += 1
            if method:
                declare(line, "self", "implicit self")
            j += 1
            while j < len(toks) and toks[j][1] != ")":
                pt = toks[j][1]
                if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", pt):
                    declare(toks[j][0], pt, "parameter")
                j += 1
            i = j
        elif t == "for":
            j = i + 1
            while j < len(toks):
                ft = toks[j][1]
                if ft in ("in", "=", "do"):
                    break
                if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", ft):
                    pending_for.append((toks[j][0], ft))
                j += 1
        elif t in ("then", "do", "repeat"):
            scopes.append({})
            for pline, pname in pending_for:
                declare(pline, pname, "loop variable")
            pending_for = []
        elif t == "elseif":
            if len(scopes) > 1:
                scopes.pop()
        elif t == "else":
            if len(scopes) > 1:
                scopes.pop()
            scopes.append({})
        elif t in ("end", "until"):
            if len(scopes) > 1:
                scopes.pop()
            else:
                findings.append(
                    f"{path.name}:{line}: UNBALANCED `{t}` (scope empty)")
        i += 1
    return findings


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 \
        else Path(__file__).resolve().parent.parent / "src"
    all_hits = []
    for lua in sorted(root.rglob("*.lua")):
        all_hits.extend(scan(lua))
    if not all_hits:
        print("No shadowed locals.")
        return
    for hit in all_hits:
        print(hit)
    print(f"\n{len(all_hits)} candidate(s). File-local shadows are the "
          f"ones worth fixing; block-level re-binds are usually fine.")


if __name__ == "__main__":
    main()
