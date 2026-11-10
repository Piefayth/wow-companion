-- Full bags while looting (WC module): names the cheapest thing to drop for the
-- best thing on the corpse, on the board. Sends BAGS_FULL(worst, top).
local M = WC.Module('MakeRoom')
local A = Auctionator and Auctionator.API and Auctionator.API.v1
-- never suggested: hearthstone and profession tools
local KEEP = { [6948] = true, [7005] = true, [2901] = true, [5956] = true, [6256] = true, [6365] = true, [12225] = true, [6219] = true, [10498] = true, [7189] = true }
local function each(id)
  local sell = select(11, C_Item.GetItemInfo(id)) or 0
  local ah = 0
  if A then local ok, p = pcall(A.GetAuctionPriceByItemID, 'WowCompanion', id) if ok and p then ah = math.floor(p * 0.95) end end
  return math.max(sell, ah)
end
local function money(c) return GetCoinText and GetCoinText(c, ' ') or (c .. 'c') end
local function cheapest()
  local best
  for b = 0, 4 do
    for s = 1, (C_Container.GetContainerNumSlots(b) or 0) do
      local info = C_Container.GetContainerItemInfo(b, s)
      if info and info.itemID and not KEEP[info.itemID] then
        local q = C_Container.GetContainerItemQuestInfo(b, s)
        local class = select(6, C_Item.GetItemInfoInstant(info.itemID))
        if not (q and (q.isQuestItem or q.questID)) and class ~= 12 and class ~= 1 then
          local v = each(info.itemID) * (info.stackCount or 1)
          if not best or v < best.v then best = { v = v, name = info.itemName or C_Item.GetItemInfo(info.itemID) or '?' } end
        end
      end
    end
  end
  return best
end
local function free() local n = 0 for b = 0, 4 do n = n + (C_Container.GetContainerNumFreeSlots(b) or 0) end return n end
local function check()
  if free() > 0 then return end
  local worst = cheapest()
  if not worst then return end
  local top
  for i = 1, (GetNumLootItems() or 0) do
    local link = GetLootSlotLink(i)
    if link then
      local id = C_Item.GetItemInfoInstant(link)
      local qty = select(3, GetLootSlotInfo(i)) or 1
      local v = id and each(id) * qty or 0
      if not top or v > top.v then top = { v = v, name = link } end
    end
  end
  if top and top.v > worst.v * 1.5 and top.v > 0 then
    local text = ('Bags full: drop %s (%s) for %s (%s)'):format(worst.name, money(worst.v), top.name, money(top.v))
    WC.Board.Post('', text)
    WC.Send('BAGS_FULL', worst, top)
  end
end
function M:Enable()
  if WCMakeRoomFrame then WCMakeRoomFrame:UnregisterAllEvents() end
  self:Event('LOOT_OPENED', function() check() end)
  self:Event('UI_ERROR_MESSAGE', function(_, _, msg) if msg == ERR_INV_FULL then check() end end)
end
