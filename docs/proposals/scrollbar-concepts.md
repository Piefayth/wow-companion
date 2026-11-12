# The chat's scroll bar: four concepts in words

Five art rounds, seen at full size: the four sheets in `target/` and the game's
own view of round 4 (`round4-ingame.png`, `round4-panes.png`). Nothing drawn here.
This is the talk-it-through step: pick a concept, or parts of two, and the
candidates come next.

## Why the rounds swung, and what is wrong with the arrows

**Too plain and too busy are different problems.** Busy came from ornament
repeated down the bar's length. In rounds 4 and 4.5 every divider got a bracket,
plate or clasp of its own, so three or more ornaments stack up next to the text.
They are as heavy as the end caps, and the thumb slides under them. Plain came
from 4.5 cutting the wrong part. It kept the solid masses (plates, rivets,
collars) and painted out the open curls, but the curls were the ornate part the
player liked. So: spend the ornament at the two ends, and spend it on line and
open space, not on mass. Keep the length quiet: stone, a groove, the thumb, and
dividers that end cleanly.

**The arrows.** At true size you see the outline and the weight, not the
detail. Four things are probably what "needs to be better" means:

1. **Two objects instead of one.** Every round-4 cap is a pointed lump sitting
   on a U-shaped clasp, so at a glance it reads as tongs holding a black stick
   with a hat on. The spearhead is one outline with one point, which is why it
   reads.
2. **Sitting on the stone, not set into it.** The clasps straddle the groove and
   cast their shadow onto the stone, while the groove runs straight on
   underneath. Nothing goes *into* the groove, so the metal floats. To look
   real, the groove has to stop against the metal: the metal's foot sits in the
   groove's end, with its shadow falling inside the cut.
3. **Too heavy.** The caps are about three times the groove's width and as tall
   as a chat turn, so they outweigh the text. The spearhead was about one and a
   half groove-widths.
4. **Pressing does nothing visible.** "Pushed" only darkens the art. A button
   seated in a socket should sink a pixel into it, and its point should stay
   lit as the one bright spot.

**The thumb has never been designed.** Every round reused Blizzard's flat brown
minimal thumb, which belongs to no set. It is the largest moving part, so it
should be made of the same material as the arrows.

## The four concepts

All four use one groove, about 8 wide, carved into the stone, with no frame. Each
spends its ornament at the two ends only, uses one metal, and has at most one
accent colour.

### 1. Spear in the groove

**The idea:** the groove is a sheath and the bar is a spear lying in it. **The
arrows:** the top end is the bronze spearhead from round 1, enlarged only to
about twice the groove's width. Below the blade, its socket narrows and plugs
straight into the groove's end, so the groove reads as the spear's own channel.
Two small barbs curl back from the blade's shoulders and lie on the groove's
lips; these are the only curls. The bottom end is a matching butt-spike pointing
down. Pressed, the head slides a pixel into its socket. **The thumb:** a length
of bronze shaft with one leather-wrapped grip band in its middle. **The
dividers:** Blizzard's own QuestLog divider, ending a few pixels short of the
groove. Where it would meet, the groove's lip has a small carved notch, so the
joint is cut into the stone with no metal on it. **Kept restrained by:** one
material, two ends, and nothing on the length except the thumb. **Carries
forward:** round 1's spearhead and round 4's wrapping round the groove's end.
**The risk:** too plain again. Everything rests on the barbs.

### 2. One twist of iron

**The idea:** a blacksmith's single gesture. An iron bar rises out of the
groove's end, takes one tight twist, and splits into two C-scrolls. **The
arrows:** the two scrolls curl outward and back down onto the stone like
shoulders, and the point forms between them. It is one outline, a short
fleur-de-lis with two curls instead of five, its stem seated in the groove's
end. It is painted in Blizzard's muted dark iron with one warm highlight on the
point. **The thumb:** a dark iron bar with the same twist in its centre, so the
moving part carries the motif. **The dividers:** its own. A plain hammered iron
rod, flush and thin, ends in a single small hook that curls over the groove's
lip and stops at the lip, so the thumb never passes under metal. All hooks curl
the same way. **Kept restrained by:** one curl per divider end, no plates, no
rivets, no collars. **Carries forward:** round 4's wrought-iron scrolls (the
liked ornate part) in 4.5's muted metal. **The risk:** the hooks repeat with
every turn. Judge it with six turns in view, not three.

### 3. Root and bud

**The idea:** a vine growing in the groove. It shows only where it leaves the
groove. **The arrows:** at the top, the vine climbs out of the groove's end and
closes into one pointed leaf-bud, the arrow. Two tendrils wind once round the
groove's end and tuck back into it. At the bottom, a root tip points down, with
two rootlets gripping the stone. The bark is brown and painted, and the green is
desaturated, used on the bud only. **The thumb:** a length of stem in the same
bark, with one node. **The dividers:** Blizzard's divider, ending short of the
groove. At each joint a tendril shows for a few pixels on the groove's lip,
emerging and going back in, so it reads as the same vine passing under the
stone. No leaves on the joints. **Kept restrained by:** the vine shows only
where it surfaces. The leaves on the dividers and the stacked leaves of round 4
are gone. **Carries forward:** round 4's vine, which the player named as an
example. **The risk:** cartoony. Leaves turn into clip art faster than metal
does, so it has to be painted like Blizzard's druid art, dark and soft-edged.

### 4. Engraved, not cast

**The idea:** nothing raised. Every piece is bronze inlaid flush into the stone,
and the ornament is engraved line, so it cannot look busy or cartoony. **The
arrows:** at each end of the groove, a pointed-arch plate of bronze is set flush
into the stone and capped by the groove's rounded end. Its point is the arrow.
Its face has a few engraved lines, scrolls that follow the outline. Pressed, the
engraving lights; disabled, the bronze dulls to grey. **The thumb:** a bronze
slider with one engraved line down its centre. **The dividers:** its own. A thin
bronze inlay line runs flush across the stone, and the groove is cut through it,
so a bright dot of bronze shows on the groove's wall where it was cut. Divider
and bar become one inlay system with no joint piece at all. **Kept restrained
by:** flatness. Nothing casts a shadow onto the text. **Carries forward:**
round 3's carved groove and 4.5's "groove carved through" idea, without its
sockets. **The risk:** single-pixel engraving vanishes at true size and on a TV.
The lines must be drawn at twice the size and checked in the game, not on the
sheet.

## Next

Pick one, or name the parts to take from two. The candidates for it are then
drawn as before (`tools/make_scrollbar_art.py`, the Scroll bars tab), checked at
true size, and checked against the six-turn count before the player sees them.
