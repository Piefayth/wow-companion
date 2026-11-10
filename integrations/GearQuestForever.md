# GearQuestForever

GearQuest Forever.

Its upgrade picks per slot, ranked for this class, level
and spec, with where each comes from:
- `GearQuest.Data:GetTopUpgradesForSlot(slot, 3)` returns entries (`itemId`,
  `sourceType` quest_reward/vendor/boss_drop/world_drop/profession, `zone`, `npc`,
  `questName`); slots from `GearQuest.Data:GetSlotsForClass(classFile)`;
  `GearQuest.Compare:GetEquippedItemLevel(slot)` for the gain. pcall each call.

Its off-hand picks ignore a two-hand weapon in the main hand: check what is equipped.
