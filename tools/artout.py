"""The one way a drawing tool clears its old textures before writing new ones.

A texture shown to the player may be wanted again (docs/looks.md), so a tool
deletes only files git already holds unchanged: a commit is what keeps a look.
Anything not yet committed, or changed since, stops the tool with the list, so
the round is committed first.

    import artout
    artout.clear(OUT, "Conv-*.tga")
"""
import glob
import os
import subprocess
import sys


def _committed(path):
    """True when git tracks `path` and the working copy matches HEAD."""
    folder, name = os.path.split(os.path.abspath(path))
    tracked = subprocess.run(["git", "ls-files", "--error-unmatch", name], cwd=folder,
                             capture_output=True).returncode == 0
    if not tracked:
        return False
    return subprocess.run(["git", "diff", "--quiet", "HEAD", "--", name], cwd=folder).returncode == 0


def clear(folder, *patterns):
    old = [p for pat in patterns for p in glob.glob(os.path.join(folder, pat))]
    kept = [p for p in old if not _committed(p)]
    if kept:
        sys.exit("artout: not committed, so not replaced (commit the round first):\n  "
                 + "\n  ".join(sorted(kept)))
    for p in old:
        os.remove(p)
