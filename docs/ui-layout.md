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
  - the **scroll column** (`WCChatScrollColumn`, `BAR` wide, flush with the
    border's right): the channel's stone and inner shadow fill it, the upright
    divider is its left edge, the arrows sit at its ends, the thumb's track
    between them.

To add a piece: decide which rect it belongs to and anchor it to that rect's
points. To change the bar's width or the border, change `BAR` or `EDGE`;
nothing else moves on its own. Check the result at full resolution
(`ImageGrab.grab()` after `SetProcessDPIAware()`, not tools/shot.ps1, which
halves the screen), around every edge the change touches.
