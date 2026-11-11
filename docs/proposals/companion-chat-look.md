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
