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

## Agreed (the player, 2026-11-10)

- **Views, not storage**: the window draws items in any order, apart from where they
  are stored. Sections is one view, **on by default**; storage order and others are
  settings. Out of combat the view rearranges freely. In combat it freezes (the pad's
  grid is attributes of a protected frame): items stay usable, new loot shows where
  it lands, and the view catches up when the fight ends. Opened by Blizzard's radial
  in combat, ours mirrors their slots, so it shows storage order until then.
- **Verdicts**: the template's junk coin, recoloured per verdict (vendor, auction,
  equip); no new corner mark.
- **The vendor**: the bag already opens at a merchant. The sell list is part of it:
  a Sell section, and a "Sell all" entry the player presses (Buyback undoes).

## Still open

- Colours for the verdicts; which views besides sections and storage order.

## Combat: why it is hard, and the way through (2026-11-10)

Why: in a fight the bag radial opens Blizzard's bags, and the game's controller
cursor (SmartNavigation) focuses *their* frame. Insecure code may not take that
focus or bind the pad mid-fight, so ours could only lie over theirs in storage
order (mirror mode); our sections never applied. The invisible-focus moment is
theirs at alpha 0 keeping the cursor after ours went away.

The way through, from Blizzard's own code (Blizzard_GamepadSmartNavigation):
navigation is pure geometry over the focused frame's buttons (`IsButtonValid`
uses each button's centre), **unless a button has a custom cursor anchor**,
whose `relativeTo` frame's rect is used instead
(`SmartNavigation_SetCustomCursorAnchorPointForFrame`, used by Blizzard's
settings and dropdowns). It writes through SecureHelper, which allows insecure
callers out of combat and stores the value securely (no taint).
`SmartNavigation_SetNavigationOverride` likewise sets explicit neighbours.

Plan: out of combat, anchor each of Blizzard's bag item buttons to our slot for the
same bag and slot. In a fight their (invisible) frame keeps the native cursor, but
the cursor moves over and draws on our sectioned layout, and cross and square press
their own secure buttons: one focus, native, sorted. Their bag-bar cells are anchored
to ours or marked ignored. Re-anchored after bag changes, out of combat only. Our
secure pad stays for our own macro until the native path is proven.
