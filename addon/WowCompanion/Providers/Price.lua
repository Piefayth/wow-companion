-- The price capability (see Engine.lua, Capabilities): auction(itemID) and
-- vendor(itemID), copper per item.

-- Built in: the game knows what a vendor pays (C_Item.GetItemInfo's sell price;
-- nil until the item is cached, then the caller asks again).
WC.Provide("price", "builtin", {
	vendor = function(id)
		local sell = select(11, C_Item.GetItemInfo(id))
		if sell and sell > 0 then return sell end
	end,
}, { rank = 0 })

-- Auctionator: prices from the player's own auction house scans
-- (Auctionator/Source/API). Counts only while Auctionator is loaded.
local function api()
	local v1 = Auctionator and Auctionator.API and Auctionator.API.v1
	return type(v1) == "table" and v1 or nil
end
WC.Provide("price", "Auctionator", {
	auction = function(id)
		local A = api()
		if not (A and A.GetAuctionPriceByItemID) then return nil end
		local ok, p = pcall(A.GetAuctionPriceByItemID, "WowCompanion", id)
		if ok and type(p) == "number" and p > 0 then return p end
	end,
	vendor = function(id)
		local A = api()
		if not (A and A.GetVendorPriceByItemID) then return nil end
		local ok, p = pcall(A.GetVendorPriceByItemID, "WowCompanion", id)
		if ok and type(p) == "number" and p > 0 then return p end
	end,
}, { addon = "Auctionator", rank = 10 })
