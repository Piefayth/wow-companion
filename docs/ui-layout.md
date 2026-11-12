# UI layout: how a well is put together

The Companion window (addon/WowCompanion_Agent/Window.lua) is one Blizzard
panel (`ButtonFrameTemplate`) holding insets (`InsetFrameTemplate`). Things went
wrong in one way all day on 2026-11-11: each piece was placed with its own
offsets, so backings, shadows and the scroll bar drifted a few pixels apart
(stone short of the top, stone under the scroll bar, a border drawn twice).
The rule that ended it:

**Inside an inset there are rects, and everything anchors to a rect.** No piece
gets a number of its own.

The chat well, for example:

- `EDGE` (3): the inset's border. Nothing is drawn inside it.
- Inside it, two rects that touch:
  - the **transcript** (`messages.scroll`), from the border's top left to the
    column's bottom left. The turns' backings and dividers fill its width
    (Transcript.lua); text keeps `PAD_L`/`PAD_R`/`PAD_TOP` margins inside it.
    The top shadow (`lip`) spans its top.
  - the **scroll column** (`WCChatScrollColumn`, `BAR` wide, the trough's own
    width), inside the border on the right: Blizzard's classic scroll trough
    as `WowClassicScrollBar` draws it (TrimScrollBar.xml), its end cap atlases
    at their size and, since its centre atlas is not in this client, the top
    cap's rails-only rows stretched between them. The player's darker stone
    fills between the rails (the gutter), the arrows sit inside the caps, the
    thumb's track between them.
- A border is Blizzard's own border art at its own size, never a rotated
  strip or a piece of a border stretched past its corners (a lone inset edge
  stretched to full height ended abruptly at the top): `SetRotation` turns a
  texture inside its rect without turning the rect, and files from other
  clients may not exist in this one (`UI-Character-ScrollBar` does not; check
  an atlas with `C_Texture.GetAtlasInfo` first).

To add a piece: decide which rect it belongs to and anchor it to that rect's
points. To change the bar's width or the border, change `BAR` or `EDGE`;
nothing else moves on its own. Check the result at full resolution
(`ImageGrab.grab()` after `SetProcessDPIAware()`, not tools/shot.ps1, which
halves the screen), around every edge the change touches.
