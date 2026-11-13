# Looks shown to the player

One line per round of options shown in game: the date, what it was for, the
options by name, what the player picked, and the commit that holds them all.
A look not picked is deleted from the working tree after the pick, but stays
in that commit; to bring one back, check its files out of that commit (or its
tool's code, and redraw). Drawing tools clear their old textures only through
tools/artout.py, which refuses to delete anything not committed.

| date | for | options | picked | commit |
|---|---|---|---|---|
| 2026-11-12 | conversation list crests (head and foot) | v1 crests | v1 crests, kept as Crest-*.tga | ce72c22 |
