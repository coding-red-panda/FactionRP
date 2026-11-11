#!/usr/bin/env python3
"""Stage FactionRP into the retail AddOns folder for in-game testing.

Mirrors the packaged file set (the inverse of .pkgmeta's ignore list) into
the installed addon directory, deleting files the package no longer ships.
The installed .toc then gets a "-dev" suffix on ## Version so the test
build stays quiet: Broadcast:broadcastVersion skips announcing on any
non-numeric version suffix.

The repo .toc keeps the real release version; only the installed copy is
stamped, so there is nothing to hand-edit before or after staging.

Usage: python tools/stage_retail.py [--dest PATH]
Default dest: the standard retail install's Interface\\AddOns\\FactionRP.
"""

import argparse
import re
import shutil
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

DEFAULT_DEST = Path(
    r"C:\Program Files (x86)\World of Warcraft"
    r"\_retail_\Interface\AddOns\FactionRP")

# Packaged top-level entries: repo minus .pkgmeta ignores (README.md,
# doc/, .gitignore, tools/, .devin/) minus agent-only files.
PACKAGED = ("FactionRP.toc", "CHANGELOG.md", "LICENSE", "Libs", "src")

VERSION_LINE = re.compile(r"^(## Version: )(.+?)\s*$", re.M)
RELEASE_VERSION = re.compile(r"^[0-9.]+$")


def stamp_dev_version(toc: Path):
    """Append -dev to a clean release version in the installed toc."""
    text = toc.read_text(encoding="utf-8-sig")
    m = VERSION_LINE.search(text)
    if not m:
        return "no ## Version line found"
    version = m.group(2)
    if not RELEASE_VERSION.match(version):
        return f"version already suffixed ({version})"
    toc.write_text(text[:m.start(2)] + version + "-dev" + text[m.end(2):],
                   encoding="utf-8")
    return f"version {version} -> {version}-dev"


def sync_tree(src_dir: Path, dst_dir: Path, stats):
    """Mirror src_dir into dst_dir, removing files absent from source."""
    dst_dir.mkdir(parents=True, exist_ok=True)
    wanted = set()
    for src_path in sorted(src_dir.rglob("*")):
        rel = src_path.relative_to(src_dir)
        wanted.add(rel)
        dst_path = dst_dir / rel
        if src_path.is_dir():
            dst_path.mkdir(exist_ok=True)
            continue
        if not dst_path.exists() \
                or dst_path.read_bytes() != src_path.read_bytes():
            dst_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src_path, dst_path)
            stats["updated"].append(str(rel))
    for dst_path in sorted(dst_dir.rglob("*"), reverse=True):
        rel = dst_path.relative_to(dst_dir)
        if rel not in wanted:
            if dst_path.is_file():
                dst_path.unlink()
                stats["removed"].append(str(rel))
            elif dst_path.is_dir() and not any(dst_path.iterdir()):
                dst_path.rmdir()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dest", type=Path, default=DEFAULT_DEST,
                    help=f"installed addon dir (default: {DEFAULT_DEST})")
    dest = ap.parse_args().dest

    stats = {"updated": [], "removed": []}
    for item in PACKAGED:
        src = REPO_ROOT / item
        if not src.exists():
            sys.exit(f"missing packaged item: {src}")
        if src.is_dir():
            sync_tree(src, dest / item, stats)
        else:
            dest.mkdir(parents=True, exist_ok=True)
            dst = dest / item
            if not dst.exists() or dst.read_bytes() != src.read_bytes():
                shutil.copy2(src, dst)
                stats["updated"].append(item)

    for stray in dest.iterdir():
        if stray.name not in PACKAGED:
            if stray.is_dir():
                shutil.rmtree(stray)
            else:
                stray.unlink()
            stats["removed"].append(stray.name + "/")

    print(stamp_dev_version(dest / "FactionRP.toc"))
    print(f"staged -> {dest}")
    print(f"{len(stats['updated'])} updated, {len(stats['removed'])} removed")
    for rel in stats["updated"] + stats["removed"]:
        print("  " + rel)


if __name__ == "__main__":
    main()
