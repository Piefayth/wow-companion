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
| 2026-11-12 | settings controls, rounds 3-5 (sunk wells, leather, seven materials) | not committed (drawn before this log) | none: sunk buttons "funky", no-box dropdown rejected, lit well and lit socket tolerable, slate overused | none |
| 2026-11-12 | settings controls, round 6: six shapes from the window's pieces (cell between vines, curled cell, all choices in a row, raised slab, tab plaque, word on a vine) | ControlTrials.lua only, no new art | dropdowns: close to usable; buttons: the raised slab, not quite | (this commit) |
| 2026-11-12 | settings buttons, round 7: variations on the slab (Slab, Rimmed, Chamfer, Scrolls, Block, Corners, Pillow, Inlaid), Btn-*-7 | | | (this commit) |
