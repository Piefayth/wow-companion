-- Bags: a verdict for every item (docs/proposals/bags.md).
-- Loads before Bags.lua, which draws the verdicts (the junk coin, recoloured) and
-- groups slots by them in the Sections view.
--
-- WC.BagsEval.Of(bag, slot) -> section key, reason. Keys, in display order:
--   new, equip, quest, use, mats, keep, auction, sell, empty
-- "sell" and "auction" are the only ones a Sell all touches ("sell" only).

WC.BagsEval = WC.BagsEval or {}
local E = WC.BagsEval

E.ORDER = { "new", "equip", "quest", "use", "mats", "keep", "auction", "sell", "empty" }
E.TITLE = { new = "New", equip = "Upgrades", quest = "Quest", use = "Consumables",
	mats = "Profession goods", keep = "Keep", auction = "Auction", sell = "Sell", empty = "Empty" }
-- the junk coin's colour per verdict (only these three show it)
E.COIN = { sell = { 1, 0.82, 0 }, auction = { 0.35, 0.65, 1 }, equip = { 0.2, 1, 0.2 } }

-- never sold: hearthstone and gathering tools
local KEEP = { [6948] = true, [7005] = true, [2901] = true, [5956] = true, [6256] = true,
	[6365] = true, [12225] = true, [6219] = true, [10498] = true, [7189] = true }

-- inventory slots for an equip location
local SLOT = { INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 },
	INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 },
	INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 }, INVTYPE_FINGER = { 11, 12 },
	INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 }, INVTYPE_2HWEAPON = { 16 },
	INVTYPE_WEAPON = { 16, 17 }, INVTYPE_WEAPONMAINHAND = { 16 }, INVTYPE_WEAPONOFFHAND = { 17 },
	INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 }, INVTYPE_RANGED = { 18 },
	INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 } }

local function ilvl(link)
	local v = link and C_Item.GetDetailedItemLevelInfo and C_Item.GetDetailedItemLevelInfo(link)
	return v or (link and select(4, C_Item.GetItemInfo(link))) or 0
end

-- can this character wear it? The tooltip's red lines say so (class, armour or
-- weapon skill, level): the game's own answer, without a table of proficiencies
local tip
local function wearable(bag, slot)
	tip = tip or CreateFrame("GameTooltip", "WCBagsEvalTip", nil, "GameTooltipTemplate")
	tip:SetOwner(WorldFrame, "ANCHOR_NONE")
	tip:SetBagItem(bag, slot)
	local ok = true
	for i = 1, tip:NumLines() do
		for _, side in ipairs({ "Left", "Right" }) do
			local fs = _G["WCBagsEvalTip" .. "Text" .. side .. i]
			if fs and fs:IsShown() and (fs:GetText() or "") ~= "" then
				local r, g, b = fs:GetTextColor()
				if r > 0.9 and g < 0.2 and b < 0.2 then ok = false end
			end
		end
	end
	tip:Hide()
	return ok
end

-- worth to the player: vendor pay and auction (after the 5% cut), per item
local function prices(id)
	local p = WC.Use and WC.Use("price")
	local vendor = (p and p.vendor(id)) or select(11, C_Item.GetItemInfo(id)) or 0
	local ah = p and WC.Has("price", "auction") and p.auction(id)
	return vendor, ah and math.floor(ah * 0.95) or nil
end

local function smallestBag()
	local n
	for b = 1, 4 do
		local s = C_Container.GetContainerNumSlots(b) or 0
		if s == 0 then return 0 end
		n = math.min(n or s, s)
	end
	return n or 0
end

local function gearVerdict(bag, slot, info, loc)
	local slots = SLOT[loc]
	if not slots then return nil end
	if not wearable(bag, slot) then return "sell", "you cannot wear it" end
	local main = GetInventoryItemLink("player", 16)
	local twoHand = main and select(9, C_Item.GetItemInfo(main)) == "INVTYPE_2HWEAPON"
	local mine = ilvl(info.hyperlink)
	for _, s in ipairs(slots) do
		if not (s == 17 and twoHand) then
			local worn = GetInventoryItemLink("player", s)
			if not worn then return "equip", "the slot is empty" end
			if mine > ilvl(worn) then return "equip", ("item level %d over %d"):format(mine, ilvl(worn)) end
		end
	end
	return nil
end

function E.Of(bag, slot)
	local info = C_Container.GetContainerItemInfo(bag, slot)
	if not (info and info.itemID) then return "empty" end
	local id = info.itemID
	if KEEP[id] then return "keep", "a tool or your hearthstone" end
	local q = C_Container.GetContainerItemQuestInfo(bag, slot)
	if q and (q.isQuestItem or q.questID) then return "quest" end
	if C_NewItems and C_NewItems.IsNewItem and C_NewItems.IsNewItem(bag, slot) then return "new" end
	if info.quality == 0 then return "sell", "junk" end
	local _, _, _, loc, _, class = C_Item.GetItemInfoInstant(id)
	if class == 1 and loc == "INVTYPE_BAG" then
		-- a spare no bigger than the smallest bag worn gains nothing
		local n = WC.BagsEval.SlotsOf and WC.BagsEval.SlotsOf(bag, slot)
		if n and n <= smallestBag() then return "sell", "no bigger than the bags you wear" end
		return "keep", "a spare bag"
	end
	if class == 2 or class == 4 then
		local v, why = gearVerdict(bag, slot, info, loc)
		if v == "equip" then return v, why end
		if v == nil and SLOT[loc] then v, why = "sell", "no better than what you wear" end
		if v == "sell" and not info.isBound then
			local vendor, ah = prices(id)
			if ah and ah > vendor * 2 and ah >= 500 then return "auction", "sells better at auction" end
		end
		if v then return v, why end
	end
	if class == 0 then return "use" end
	if class == 7 or class == 9 then return "mats" end
	return "keep"
end

-- a bag item's slot count, from its tooltip ("10 Slot Bag")
function E.SlotsOf(bag, slot)
	tip = tip or CreateFrame("GameTooltip", "WCBagsEvalTip", nil, "GameTooltipTemplate")
	tip:SetOwner(WorldFrame, "ANCHOR_NONE")
	tip:SetBagItem(bag, slot)
	local n
	for i = 2, tip:NumLines() do
		local fs = _G["WCBagsEvalTipTextLeft" .. i]
		n = n or tonumber(((fs and fs:GetText()) or ""):match("^(%d+) Slot"))
	end
	tip:Hide()
	return n
end

-- every slot to sell at a vendor, now
function E.SellList()
	local out = {}
	for b = 0, 4 do
		for s = 1, C_Container.GetContainerNumSlots(b) or 0 do
			if E.Of(b, s) == "sell" then out[#out + 1] = { b, s } end
		end
	end
	return out
end
