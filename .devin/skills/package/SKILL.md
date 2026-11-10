---
name: package
description: Package the addon for distribution per .pkgmeta (stage into .staging/, zip with the addon folder at the archive root). Trigger on "package", "stage", or "zip for release".
---

# Package FactionRP for distribution

Build a release zip that honors `.pkgmeta`. The archive contains a single
top-level `FactionRP/` folder so it unzips directly into AddOns; the zip
filename itself is free (convention: `FactionRP-<version>.zip`).

## Steps

1. Read `.pkgmeta`. `package-as` gives the folder name, `ignore:` lists
   paths to exclude. Also always exclude `.git/`, `.pkgmeta`,
   `.gitignore`, and `.staging/` itself.
2. Read `## Version` from `FactionRP.toc` for the zip name.
3. Stage into `.staging/FactionRP/`, copying everything not ignored:

   ```bash
   mkdir -p .staging/FactionRP
   cp -r src Libs FactionRP.toc CHANGELOG.md LICENSE .staging/FactionRP/
   ```

   (Adjust the copy list if new top-level files/dirs are added; ship what
   .pkgmeta does not ignore.)

4. Zip from inside `.staging/` so archive paths are `FactionRP/...`.
   No `zip` binary on Windows Git Bash; use Python:

   ```bash
   cd .staging && python -c "
   import os, zipfile
   with zipfile.ZipFile('FactionRP-<version>.zip', 'w', zipfile.ZIP_DEFLATED) as z:
       for root, dirs, files in os.walk('FactionRP'):
           for f in files:
               p = os.path.join(root, f)
               z.write(p, p.replace(os.sep, '/'))
   "
   ```

5. Verify: `python -c "import zipfile; print('\n'.join(zipfile.ZipFile('.staging/FactionRP-<version>.zip').namelist()))"`.
   Every entry must start with `FactionRP/`; every file the .toc loads must
   be present; no ignored or dotfile entries.

## Notes

- `.staging/` is gitignored; re-staging is cheap, wipe and rebuild freely.
- `CHANGELOG.md` ships intentionally (feeds `manual-changelog` release
  notes); `LICENSE` ships by convention.
- Syntax-check first if sources changed: `luac -p src/*.lua`.
