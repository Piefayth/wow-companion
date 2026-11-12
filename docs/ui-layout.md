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
- Inside it, two rects, one over the other:
  - the **transcript** (`messages.scroll`), the whole inside of the border.
    The turns' stone and dividers fill its width, on behind the bar to the
    edge (Transcript.lua); text keeps `PAD_L`/`PAD_TOP` and `PAD_R` plus the
    bar's room (`WC.ChatBar.ROOM`) clear of it. The top shadow (`lip`) spans
    its top up to the bar, fading out sideways before it.
  - the **scroll column** (ChatBar.lua, 20 wide), over the transcript's right
    end, inside the border: a groove carved in the stone between bark
    borders, the arrows over its ends, the thumb riding in it; each divider's
    Joint scrolls with its turn and meets the groove's left border.
- A border is Blizzard's own border art at its own size, never a rotated
  strip or a piece of a border stretched past its corners (a lone inset edge
  stretched to full height ended abruptly at the top): `SetRotation` turns a
  texture inside its rect without turning the rect, and files from other
  clients may not exist in this one (`UI-Character-ScrollBar` does not; check
  an atlas with `C_Texture.GetAtlasInfo` first).

To add a piece: decide which rect it belongs to and anchor it to that rect's
points. To change the bar's width or the border, change ChatBar.lua's `WIDTH` or `EDGE`;
nothing else moves on its own. Check the result at full resolution
(`ImageGrab.grab()` after `SetProcessDPIAware()`, not tools/shot.ps1, which
halves the screen), around every edge the change touches.
