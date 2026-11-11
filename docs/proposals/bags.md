# Bag land (proposal, the player, 2026-11-10: "we could go crazy on bag")

What the popular bag addons do, and what we take. Nothing here is built until the
player agrees how it feels (profile: no new bindings unasked, one focus).

## What they do

- **Baganator**: one combined view; categories from search terms (`#junk`, `#boe`,
  `#reagent`, item level); junk marking; item level on icons; alts' bags and bank
  offline; quick transfer to bank, mail and vendor.
- **BetterBags / AdiBags**: sections (new, quest, junk, gear, trade goods, food),
  custom sections from a search, pin or hide a section, stacking options, upgrade
  arrows (Pawn).
- **ArkInventory**: rule-based categories, any number of bars, per-character layouts.
- **Bagnon**: plain grid, quality borders, offline alts and bank, search by name.

## What we take (in order)

1. **Evaluate**: every item gets a verdict: equip (an upgrade, checked against what
   is worn and the class), keep (quest, tools for known professions, mats for known
   professions, consumables in use), vendor (grey, unusable gear, vendor beats AH),
   auction (Auctionator price clearly beats vendor). Shown as a corner mark on the
   slot and a line on the tooltip. Voice: "what should I sell".
2. **Sell list at the vendor**: the vendor verdicts listed when a merchant opens;
   one press of theirs sells them; Buyback still undoes.
3. **Sections**: new, equip, quest, profession mats, consumables, keep, sell,
   auction, in that order; sort within a section by the game's sort or by value.
   Rearranged out of combat only; positions freeze in combat.
4. **Filters by voice**: "show quest items", "show what I can sell": the window dims
   everything else. Saying a name finds it and moves focus there.
5. **Item level and quality on icons**, upgrade arrows from GearQuest.
6. **Later**: bank in the same window, alts' bags offline, quick mail and auction
   posting (the posting press is theirs).

## To agree before building

- Where verdicts show (corner glyph, tint, or only in sections).
- Whether the sell list opens itself at a vendor (profile: nothing of ours opens
  itself) or waits for a word or a menu entry.
- Sections on by default, or a toggle on the triangle menu.
