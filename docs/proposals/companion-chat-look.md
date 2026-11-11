# The Companion window's Chat tab: how turns look

The player, 2026-11-11: the transcript sat on plain black; they want two tones
alternating by whose message it is, still dark, textured like the rest of our
UI, and not stupid. The first try (screenshot `shots/companion-chat-1151.png`)
put the player's turns on `UI-Background-Rock` at vertex 0.62 and replies on
`UI-Background-Marble` at 0.2.

## What the first try taught

- **Darkening a texture with vertex colour erases it.** Marble at 0.2 is
  black: its veins drop below what a TV shows. Blizzard never dims these; every
  use in this build is at vertex 1 (or a tint near 1), e.g.
  `Blizzard_Communities/GuildNews.xml:362`,
  `Blizzard_Communities/CommunitiesMemberList.xml:351`,
  `Blizzard_ArtifactUI/Blizzard_ArtifactUI.xml:30`. Marble at 1 is already a
  dark blue-grey backing meant for white text.
- **Two different materials at two brightnesses read as "grey box / black
  box"**, not as texture. Rock's grain is fine and low-contrast; at 0.62 it
  averages to flat grey from the couch.
- So: **one material, two tints, at Blizzard's own brightness**, and let a
  Blizzard divider mark where a turn ends. Hue says whose it is; the divider
  says where it changes; brightness stays dark and even so text contrast is the
  same in both.

Common to every option below:

- The turn backing stays as built: one texture per turn, layer `BACKGROUND`
  sublevel -1, from halfway into the gap above to halfway into the gap below,
  `TOPLEFT` x = -6 to `TOPRIGHT` x = 0 of the content. Tiled both ways
  (`SetTexture(file, "REPEAT", "REPEAT")`, `SetHorizTile`, `SetVertTile`).
- The header ("You 11:50", "Claude 11:51") keeps `GameFontNormalSmall`, gold
  name, grey time.
- Body text stays `ChatFontNormal`, white / near-white. No change to fonts.
- **Step notes** (`›` lines, `GameFontHighlightSmall`, grey 0.62/0.65/0.70)
  stay without a backing of their own, indent 14, on the turn's backing; raise
  their grey to 0.72/0.74/0.78 so they hold on a lit marble (they were tuned on
  black).
- **Code blocks** lose the flat `SetColorTexture(1, 1, 1, 0.06)` (a flat colour
  box, against our standing term) and take
  `Interface\DialogFrame\UI-DialogBox-Background-Dark`, tiled, vertex 1, alpha
  0.75, layer `BACKGROUND` sublevel 0 (above the turn), same anchors as now
  (x = indent - 6 to the right edge, 3 px above and below the text). Blizzard
  tiles it as the ready check's backing:
  `Blizzard_FrameXML/Mainline/ReadyCheck.xml:27`. It reads as a recessed dark
  slot inside the turn, the way a quote sits in a letter; the code's green text
  stays.

## Option A (recommended): one marble, two tints, the quest log's divider

- **Replies**: `Interface\FrameGeneral\UI-Background-Marble`, vertex
  (1, 1, 1), alpha 1. Exactly Blizzard's guild-news / member-list backing
  (`GuildNews.xml:362`, `CommunitiesMemberList.xml:351`).
- **Yours**: the same marble, vertex (1, 0.86, 0.66), alpha 1: a warm, bronze
  cast on the same stone. The warm tint is Blizzard's own move on a tiled
  FrameGeneral stone: the achievement window tints rock (0.9, 0.8, 0.7)
  (`Blizzard_AchievementUI/Mainline/Blizzard_AchievementUI.xml:2605-2610`).
  Same brightness as the replies, so white text holds equally on both.
- **Edge of a turn**: atlas `QuestLog-frame-devider` (the gold filigree rule
  between sections of the quest log), layer `ARTWORK`, alpha 0.8, height 15,
  width the full content, centred on the boundary between two turns (the
  backing's top edge; none above the first turn). Blizzard: 
  `Blizzard_UIPanels_Game/Mainline/QuestMapFrame.xml:132` (height 15,
  `TOPLEFT`/`TOPRIGHT` y = 5, i.e. hanging over the edge as here).
- **Header**: unchanged; it sits 8 px under the divider.
- **Looks like**: the conversation as a stack of dark marble slabs, yours
  faintly bronze and the replies cool blue-grey, each joint capped by the quest
  log's thin gold filigree; still dark, the stone visible, nothing flat.
- Risk: the bronze may be too subtle on the TV. The one knob to turn is your
  tint's blue (0.66 → 0.55); never the brightness.

## Option B: the auction house's row stripes over one textured well

- **The well** (the `InsetFrameTemplate` behind the transcript, `Window.lua`
  around line 317) gets `Interface\FrameGeneral\UI-Background-Marble`, tiled,
  vertex 1, layer `BACKGROUND` sublevel 1, `TOPLEFT` (3, -3) to `BOTTOMRIGHT`
  (-3, 3) of the well, the inset its own border.
- **Turns**: alternating by owner, not by position: yours on atlas
  `auctionhouse-rowstripe-1`, replies on `auctionhouse-rowstripe-2`, stretched
  (not tiled) over the turn, layer `BACKGROUND` sublevel 2, alpha 1. This is
  exactly how Blizzard alternates entries in a list:
  `Blizzard_AuctionHouseUI/Shared/Blizzard_AuctionHouseItemList.lua:185`
  (`alternate and "auctionhouse-rowstripe-1" or "auctionhouse-rowstripe-2"`),
  base in `Mainline/Blizzard_AuctionHouseItemList.xml:23`.
- **Edge of a turn**: the stripe change itself, no divider.
- **Looks like**: one continuous marble well, with each turn a slightly
  lighter or darker translucent stripe across it, like auction house results;
  the most "Blizzard list" of the three and the quietest.
- Risk: the stripes are designed for 20-px rows; over a tall turn the
  difference may read as nothing at couch distance. If so it fails the ask
  (two tones) and A is the fix.

## Option C: two materials, both at full strength, settings-style dividers

- **Replies**: `UI-Background-Marble`, vertex 1 (as A).
- **Yours**: `Interface\FrameGeneral\UI-Background-Rock`, vertex
  (0.9, 0.8, 0.7), alpha 1, exactly the achievement window's tint
  (`Blizzard_AchievementUI.xml:2605-2610`); undimmed, as the friends list uses
  it (`Blizzard_FriendsFrame/Mainline/FriendsFrame.xml:145`).
- **Edge of a turn**: atlas `Options_HorizontalDivider` (the settings list's
  thin line), `useAtlasSize` height, alpha 1, layer `ARTWORK`, across the
  boundary. Blizzard: `Blizzard_Settings_Shared/Blizzard_SettingsList.xml:19`.
- **Looks like**: your words on warm brown stone, the replies on dark marble,
  plainer lines between; the strongest owner contrast of the three.
- Risk: rock at full strength is noticeably lighter than marble; check white
  text on it on the TV before keeping it. This is the first try done
  Blizzard's way (undimmed), so it is the fallback if A's tints are too close.

## How to judge

Build A, reload, `tools/shot.ps1` the Chat tab with at least two turns of each
and a code block, and look from the couch: can you tell whose turn it is
without reading the header, can you see stone, is every line easy to read. If
the tones are too close, move A's blue down; if marble itself feels wrong, C.

# Round 2, 2026-11-11 12:09

Where it stands (shot `companion-chat-1208.png`): marble with an additive lift
on every turn, yours tinted (1, 0.8, 0.55); `QuestLog-frame-devider` between
turns; the classic `UI-Character-ScrollBar` trough round the scroll bar. The
player: best so far; keep the dividers and the trough's border. Wanted: depth
in the gutter (it is pure black inside), the marble calmer, a better colour
pairing, and (optional) the trough's border in the dividers' art.

## Why brown on grey fails, and what to pair instead

The two backings differ in *hue* (warm vs cool) at the same low value and low
saturation; at that darkness two hues don't read as two colours, they read as
one colour gone muddy, and the eye goes to the clash rather than to the text.
Blizzard's lists never do that: alternate rows in one window differ in
*value* only (the auction house stripes, round 1's option B), and colour is
spent on the gold trim and the text. So: **one material for both owners,
your turns one step lighter**, the gold dividers doing the separating. The
material should be quieter than marble: marble's veins are large, high-contrast
shapes that compete with 16-px text on a TV; the lift made that worse by
raising exactly the veins.

## Option A (recommended): the modern neutral stone, one material, value steps

- **Replies**: atlas `UI-Frame-Neutral-BackgroundTile`, tiled
  (`SetHorizTile(true)`, `SetVertTile(true)`), vertex 1, alpha 1, blend
  `BLEND`, layer `BACKGROUND` sublevel 1, `TOPLEFT`/`BOTTOMRIGHT` of the turn
  (stopping at the gutter as today). Blizzard tiles it exactly so:
  `Blizzard_ChromieTimeUI/Blizzard_ChromieTimeUI.xml:72` and
  `Blizzard_CovenantPreviewUI/Blizzard_CovenantPreviewUI.xml:76`
  (`horizTile="true" vertTile="true" setAllPoints="true"`). It is the dark,
  fine-grained slate of the modern neutral frame: texture you can see, no
  large veins.
- **Yours**: the same texture, same settings, plus an additive copy of itself
  on top (layer `BACKGROUND` sublevel 2, blend `ADD`, alpha 0.25, untinted).
  This is the lift you already accept, used only to step your turns up in
  value, never down (no vertex dimming, so no flat box), and no hue at all.
  If the step is too small on the TV, raise the alpha (0.25 → 0.35); never tint.
- **Drop**: the marble, its lift on replies, and the (1, 0.8, 0.55) tint
  (`Transcript.lua` `MARBLE` and its comment, which then go stale).
- **Dividers**: unchanged (`QuestLog-frame-devider`, alpha 0.8, 15 tall).
- **Gutter (depth)**: inside the trough, behind arrows and thumb, the same
  `UI-Frame-Neutral-BackgroundTile` tiled (layer `BACKGROUND` sublevel 1,
  vertex 1), then Blizzard's inner shadow over it: a frame inheriting
  `ShadowOverlaySmallTemplate`
  (`Blizzard_UIPanelTemplates/Mainline/UIPanelTemplates.xml:1045`; the
  `Interface\Common\ShadowOverlay-Corner/-Top/-Bottom/-Left/-Right` pieces,
  24 px) set to all points of the trough's inside, frame level just above the
  stone and below the arrows/thumb. The edges fall into black and the middle
  shows stone: a carved channel rather than a void. The trough's own pieces
  stay on top as its border.
- **Trough border in the dividers' art (the wish)**: one vertical
  `QuestLog-frame-devider` down the gutter's left side, from the top arrow to
  the bottom arrow, alpha 0.8, layer `OVERLAY` of a frame above the turns.
  Blizzard turns a horizontal divider vertical exactly this way:
  `Blizzard_GroupFinder_VanillaStyle/Mainline/Blizzard_LFGVanilla_Listing.xml:292-305`
  (a frame sized to the line, the atlas with `rotation="90"`,
  `setAllPoints`); in Lua `SetAtlas` then `SetRotation(math.pi / 2)` on a
  texture whose unrotated size is (gutter height × 15), centred on the gutter's
  left edge. Each turn's horizontal divider already stops at the gutter, so
  its right flare now meets the vertical one: the T-joints the player
  described. The trough's left edge pieces are then hidden behind it (keep the
  top, bottom and right pieces: the border they liked). Check one shot: if the
  rotated atlas's flares sit at the wrong ends, flip with `SetTexCoord`
  rather than adding pieces.
- **Looks like**: one calm slate, your turns a shade lighter, gold filigree
  between every turn running into a gold rule beside a stone channel the
  scroll thumb rides in.

## Option B: plain black, given depth instead of texture

The history says plain black read best and only looked bare. Bareness here is
the absence of edges and depth, not of veins, so add those and keep black.

- **Both owners**: `Interface\DialogFrame\UI-DialogBox-Background-Dark`, tiled,
  vertex 1, alpha 1, layer `BACKGROUND` sublevel 1 (the file `Transcript.lua`
  already uses for `row.band`). Yours add the ADD lift as in A, alpha 0.3.
- **Depth per turn**: `ShadowOverlaySmallTemplate` over each turn's backing
  (cited above), so each slab has darkened edges and reads recessed between
  the gold dividers.
- **Gutter and border**: as A, with the dark dialog background in the gutter
  in place of the slate.
- **Looks like**: the old black, but each turn a recessed panel framed in
  gold; maximum text contrast. Risk: the ADD lift on near-black may be too
  small a step to tell owners apart; if so, A.

## Option C: a generated slate, only if A's tile reads wrong on the TV

Native art is preferred and A should be tried first; this exists for the case
where `UI-Frame-Neutral-BackgroundTile` turns out too light, too blue or too
patterned in this client.

- **File**: `addon/WowCompanion_Agent/Art/Slate.tga`, 256 × 256, 32-bit
  uncompressed TGA (alpha 255 everywhere), made by a script in `tools/`.
- **Depicts**: dark fine-grained stone, Blizzard's FrameGeneral style without
  veins. Base colour RGB (30, 28, 26) (warm charcoal). Two octaves of
  *periodic* value noise (periods 32 px and 8 px, so the tile wraps
  seamlessly), amplitude ±6 and ±3 levels on all three channels equally; a
  third sparse layer of 1-2 px specks at +10 levels, density 0.5%. No lines,
  no shapes larger than 32 px: nothing the eye can follow behind text.
- **Tiling**: `SetTexture(path, "REPEAT", "REPEAT")`, then
  `SetTexCoord(0, w/256, 0, h/256)` from the turn's size at each layout, so
  it tiles at 1:1 pixel scale.
- **Owners**: replies vertex 1; yours the ADD lift at 0.25 (as A). Gutter:
  the same file plus `ShadowOverlaySmallTemplate`; border as A.

## How to judge

Build A, reload, shot the Chat tab with two turns of each owner and the scroll
bar visible, and look from the couch: is the text easy, can you tell your
turns without reading the header, does the gutter look carved, do the
dividers' flares meet the vertical rule. Knobs, in order: the lift's alpha;
then B if the slate is wrong; C only if both native materials fail.
