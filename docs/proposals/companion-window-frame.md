# The Companion window's frame: no box, top tabs, a legend panel

The player, 2026-11-11 (shot `shots/companion-chat-1208.png`): remove the big
translucent black box around the whole window; give the legend ("Cancel newest"…)
its own small panel at the bottom; move the tabs to the top (or the side); find
the heading a place now that the box is gone. Keep the two wells, the scroll
arrows and trough, the close button. Look and layout only: how the window is
shown, hidden and focused does not change, and nothing new drags it.

Builds on, and must land after, the round-2 backings in
`companion-chat-look.md`. Paths below are under
`docs/wow-ui-source/Interface/AddOns/`.

## What the box is doing today, and what takes over each job

`Window.lua` `buildLog` (around line 437) makes `WowCompanionLog` a
`BackdropTemplate` frame with `UI-DialogBox-Background-Dark` and
`UI-DialogBox-Border`. Removing it leaves:

| Job of the box | Who does it after |
|---|---|
| Ground under the Chat tab | Already the two `InsetFrameTemplate` wells. Their `Bg` is tiled `UI-Background-Marble` (`Blizzard_SharedXML/Mainline/SharedUIPanelTemplates.xml:389`, Bg at ~396), opaque: they stand alone. |
| **Ground under Tools, Status, Errands** | **Nothing today: those pages are drawn straight on the box** (`buildTabs`, `p:SetPoint("TOPLEFT", 20, -42)` / `("BOTTOMRIGHT", -20, 34)`, line 15) while both wells hide. This is the one wall: without a ground they float on the world. Fix the native way, as every Blizzard tabbed panel does: **one more `InsetFrameTemplate`, the page well**, covering the area of both wells (`TOPLEFT` = chat well's `TOPLEFT`, `BOTTOMRIGHT` = conversation well's `BOTTOMRIGHT`), shown on tabs 2-4 only (it joins the set `SelectTab` shows/hides, the inverse of `chatParts`). The pages anchor inside it, (12, -10) / (-12, 10). |
| Holding the legend | The legend panel (below). |
| Holding the heading crest and close button | The top row (below). |
| Holding the resize grip | The bottom-right corner, under the conversation well (below). |

The frame itself stays the same named frame, same strata, size steps, scale,
clamp, `OnHide` → `WC.FrameHidden`, `CloseButton`; it is just created with no
template (drop `"BackdropTemplate"` and the `SetBackdrop` block). Clicks in the
few-pixel gaps between pieces fall through to the world; that is fine.

Removed with the box (rule: a replacement removes what it replaces):
- the `SetBackdrop` block and the `BackdropTemplate` pcall fallback;
- `UI-DialogBox-Header` crest texture;
- **the `pending` font string** (`Window.lua` ~487-496): `SelectTab` hides it on
  every tab ("its state shows in the chat itself"), so it is dead; remove it and
  the `pending` parameter of `buildTabs`;
- the stale anchors of `messages.scroll` to the frame (`Window.lua` ~499-500;
  overwritten by the chat-well anchors anyway);
- `applySize`'s "room for the tabs that hang under it" (`- 44`): nothing hangs
  under the window any more; the reserve becomes 0 (the legend is inside the
  frame).
- every comment naming the box, the "raised frame", or tabs "hanging under".

## Option A (recommended): tabs on the chat well, Blizzard's dialog header over the conversation list

**Picture:** two marble wells side by side with nothing around them; top-tabs
standing on the chat well's top edge on the left, the gold diamond-metal
"Companion" plate standing on the conversation well with the red close button
beside it, and a small dark tooltip-style plate under the chat well's right
corner carrying the button prompts.

Vertical budget (frame-relative, unchanged outer size): top row 0 to -40, wells
-40 to +36 from the bottom, legend row +36 to 0.

- **Wells.** Chat well `TOPLEFT` (16, -40) → `TOPLEFT` (0, -40); conversation
  well `TOPRIGHT` (-16, -40) → (0, -40); both bottoms 32 → 36 (room for the
  legend). The 16-px side margins existed only to clear the box's border; with
  the box gone the wells are the window's edge. Gap between the wells stays 6.
- **Tabs: `PanelTopTabButtonTemplate`** (`SharedUIPanelTemplates.xml:1006`,
  mixin `PanelTopTabButtonMixin`, `SharedUIPanelTemplates.lua:283-307`: the
  bottom-tab art flipped and cut to 75 % height, bottom-anchored). Same
  `PanelTemplates_SetNumTabs` / `PanelTemplates_SetTab` as today, so
  `SelectTab` is untouched; only the template name and anchors change.
  Blizzard uses it this way in the macro frame (`Blizzard_MacroUI/Blizzard_MacroUI.xml:183-195`)
  and the auction house (`Blizzard_AuctionHouseUI/Mainline/Blizzard_AuctionHouseTab.xml:10`).
  - Tab 1: `BOTTOMLEFT` = chat well `TOPLEFT` (+8, -2): the active tab's open
    bottom merges into the well's top border (tune ±1 px on the shot).
  - Tabs 2-4: `LEFT` = previous tab's `RIGHT` (0, 0), as `MacroFrameTab2`
    (`Blizzard_MacroUI.xml:194-196`).
  - Font: the template's own (`GameFontNormalSmall` / highlight). The couch size
    comes from the window scale (`frame.SetWindowScale`), which scales tabs too;
    no per-font overrides.
  - Still `WC.MarkFocusable(tab)`; picked with the cursor as now.
  - On tabs 2-4 the page well takes the chat well's place, so the tabs stand on
    it at the same x and y: nothing moves when switching.
- **Heading: `DialogHeaderTemplate`** (`Blizzard_SharedXML/Shared/Dialog/DialogTemplates.xml:11`,
  atlases `UI-Frame-DiamondMetal-Header-CornerLeft` / `-CornerRight` /
  `_UI-Frame-DiamondMetal-Header-Tile`, text `GameFontNormal`; `Setup(text)`
  sizes it to text + 64, `DialogTemplates.lua:10-22`). It is the modern
  replacement of the very crest we have now (the calendar's popups use it,
  `Blizzard_Calendar/Mainline/Blizzard_Calendar.xml:371`).
  - `header:Setup("Companion")`, then `header:SetHeaderFont(GameFontNormalLarge)`
    (TV) → about 160 wide, 39 tall.
  - Clear the template's own `TOP y=11` anchor; anchor `BOTTOMRIGHT` = close
    button's `BOTTOMLEFT` (-2, -4), so it stands on the conversation well's top
    edge and overlaps its border by 4 px, like the dialog header overlaps a
    dialog's.
  - It sits over the conversation list on every tab (on tabs 2-4, over the page
    well's right end). That is its natural home: the right column is "who you
    are talking to"; the left is "what you are looking at".
- **Close button: `UIPanelCloseButton`** (`SharedUIPanelTemplates.xml:148`), as
  now: `TOPRIGHT` (0, -6), i.e. its right edge flush with the wells, vertically
  centred on the header. `frame.CloseButton` unchanged.
- **Drag:** the existing drag (the header strip, `Window.lua` ~458-467) moves to
  the `DialogHeaderTemplate` frame, nothing else: the title is the handle, as
  before. (Aside for the player: `frame:SetPoint` is re-applied by the panel
  manager on every open, so the drag already lasts only until the window
  closes; if no one uses it, it can go entirely.)
- **Legend panel: `TooltipBackdropTemplate`** (`Blizzard_SharedXML/SharedTooltipTemplates.xml:111`,
  NineSlice `TooltipDefaultLayout`: near-black fill, thin grey-blue border, the
  game's highest-contrast small plate). Blizzard uses it as a plain panel under
  the macro icons: `MacroFrameTextBackground`, `Blizzard_MacroUI.xml:177`.
  - A child frame `frame.legendPanel`, height 28, width = legend text width + 24
    (set where `Jobs.lua` ~543 sets the text), `TOPRIGHT` = chat well's
    `BOTTOMRIGHT` (0, -4): it hangs from the chat well's lower right corner,
    since everything it names (cancel, send now, the offered press) is in the
    chat.
  - Shown exactly when the legend has parts (`Jobs.lua` ~544 shows the panel,
    not just the font string). The frame always reserves the 36-px row, so the
    wells never jump when it comes and goes.
  - Text: the legend's font string moves into the panel, `RIGHT` (-12, 0),
    `GameFontHighlight` (up from `GameFontHighlightSmall`: white, one step
    larger, for the couch), glyphs unchanged.
- **Resize grip:** `BOTTOMRIGHT` (0, 4) of the frame, i.e. under the
  conversation well's corner, the same click-to-cycle as now.

## Option B: one plain title row, the auction house's gold-edged legend bar

**Picture:** a single row along the top: "Companion" in large gold letters at
the left, the four top-tabs right after it, the close button at the far right;
the wells below; a full-width thin gold-edged bar along the bottom with the
prompts at its right.

- Wells, tabs (template, font, focus), page well, close, grip: as A.
- **Heading:** no art. A font string `GameFontNormalLarge` (gold),
  `BOTTOMLEFT` = chat well `TOPLEFT` (6, 8), text "Companion". Tab 1 anchors
  `LEFT` to its `RIGHT` (+14) and `BOTTOM` to the chat well's `TOP` (0, -2).
  This is how Blizzard's newer panels title themselves (gold text at the top
  left, no plate), but here without the title bar around it, so it is the
  least ornamented. The drag goes on a frame covering this font string only.
- **Legend: `ThinGoldEdgeTemplate`** (`Blizzard_UIPanelTemplates/Mainline/UIPanelTemplates.xml:1314`,
  `Interface\Common\Moneyframe` left/right/middle; the auction house's money
  bar, `Blizzard_AuctionHouseUI/Shared/Blizzard_AuctionHouseFrame.xml:17`).
  Height 20 is the art's own, `TOPLEFT` = chat well `BOTTOMLEFT` (0, -6) to
  `TOPRIGHT` = conversation well `BOTTOMRIGHT` (-20, -6); always shown; the
  legend text `RIGHT` (-10, 0), `GameFontHighlight`. The grip sits at the frame's
  `BOTTOMRIGHT` (0, -2), to the right of the bar (the bar ends 20 px short of the
  frame's right edge to leave it room).
- Weaker than A: the gold bar is a money bar (a reader may look for coins), it
  is the full width even when it says nothing, and 20 px is tight for
  `GameFontHighlight` with inline glyphs.

## Option C: side tabs down the left edge

**Picture:** the two wells with a column of Blizzard's square side tabs
(the spellbook/collections side tabs) standing off the chat well's left edge,
the dialog header and close button as in A, the tooltip legend plate as in A.

- **Tabs: `LargeSideTabButtonTemplate`** (`SharedUIPanelTemplates.xml:1008`,
  atlas `common-sidetab` with `common-sidetab-mask`, mixin
  `SidePanelTabButtonMixin`, `SharedUIPanelTemplates.lua:309`). They are icon
  tabs: each needs an icon (Chat: speech; Tools: a cog; Status: a heart or a
  scroll; Errands: a bag), name only in the tooltip. Tab 1 `TOPRIGHT` = chat
  well `TOPLEFT` (2, -8), each next 4 below. Selection is the template's own,
  not `PanelTemplates_SetTab`, so `SelectTab` has to drive `SetChecked`.
- The chat well gains the full top row's height (the tabs are no longer above
  it), which matters at the small size.
- Against: the player leans top; icon-only tabs hide the names, which is worse
  on a TV; four new icons to choose. Kept for completeness.

## Unchanged in every option

How the window is shown, hidden and focused (`UIPanelWindows`, `ShowUIPanel`,
`WC.MarkFocusable`, `OnHide` → `WC.FrameHidden`, `CloseButton`); the wells'
art (inset, `auctionhouse-background-categories`, the nav buttons); the scroll
arrows, trough and thumb inside the chat well; the size steps and scale.

## How to judge

Build A after the round-2 backings, reload, `tools/shot.ps1` the window on Chat
with a request running (legend showing) and on Tools: is there anything left of
the black box, does the active tab join its well, does the header read as the
title from the couch, is the legend legible, does anything float on the world.
If the dialog header crowds the conversation list at the small size, B's plain
title is the fallback.
