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
| 2026-11-12 | settings controls, round 6: six shapes from the window's pieces (cell between vines, curled cell, all choices in a row, raised slab, tab plaque, word on a vine) | ControlTrials.lua only, no new art | dropdowns: close to usable; buttons: the raised slab, not quite | 08b03f2 |
| 2026-11-12 | settings buttons, round 7: variations on the slab (Slab, Rimmed, Chamfer, Scrolls, Block, Corners, Pillow, Inlaid), Btn-*-7 | 3 (Chamfer) most elegant but not buttony enough; try it with 5 (Block) or 7 (Pillow); 6 (Corners) a favourite to keep in mind | 08b03f2 |
| 2026-11-12 | settings buttons, round 8: the cut slab made a button, rest/lit/pressed (CutBlock, CutBlockRim, CutPillow, CutBlockPillow, Facets, Plinth, CutCorners, CornerScrolls), Btn-*-8 | 5 (Facets), demoed on the Errands buttons; its lit face (light stone) blends into the page | | 2756d08 |
| 2026-11-12 | conversation menu drawer, round 1: how it hooks into the window rim, and its legend panel (1 one rim/bay + rows in a well, 2 sweep + carved strip, 3 scroll brackets + rule over band, 4 sleeve + bronze plate, 5 tongue + vine, 6 knee braces + grey sill), DrawerTrial-*-1 | 3 (scroll brackets), joints to be truly seamless, legend smaller | d5d8e49 |
| 2026-11-12 | conversation list, round 2: whole looks, live (the settings page's Conversation list row, WC.Companion.ConvLook) | heartwood (plaques in the pad groups, lamp-lit), brass (nameplates, polished when open), spine (leather panels, gilt when open), cloisonne (enamel cells as the pad, lit from within), lantern (iron rails, the pane glows), stem (lacquer signs on a stem, red when open), Conv-*-3 | | 12a1329 |
| 2026-11-12 | settings button, round 9: Facets lit six ways (LitHalo, LitRim, LitHaloRim, LitInner, LitLamp, LitGilt), Btn-Facets-*-9; Errands shows LitHalo | | | f744ef1 |
