-- Bag swap (WC module): reshuffles everything so a bag can be switched, and
-- says so if that is impossible. WCSwapBag(what, into, dry):
--   what  the spare bag in the bags: a name ("Linen Bag"), an item ID, or nil for
--         the biggest spare
--   into  which bag slot to replace (1-4), or nil: an empty bag slot first, else
--         the smallest ordinary bag smaller than the new one
--   dry   true: only say what it would do
-- It moves the old bag's items into free slots of the other ordinary bags, one
-- at a time, waiting for each to settle; equips the new bag (PutItemInBag, as
-- Blizzard's bag slot does), and puts the old bag where the new one was. Out of
-- combat only; a fight stops it and anything on the cursor goes back.
local M = WC.Module('BagSwap')

local function say(text)
  print('|cff7fbfffbags:|r ' .. text)
  if WC.Board and WC.Board.Post then pcall(WC.Board.Post, '', text) end
end

-- the slot count of a bag in the bags, from its tooltip ("10 Slot Bag")
local tip
local function sizeOf(bag, slot)
  tip = tip or CreateFrame('GameTooltip', 'WCBagSwapTip', nil, 'GameTooltipTemplate')
  tip:SetOwner(WorldFrame, 'ANCHOR_NONE')
  tip:SetBagItem(bag, slot)
  for i = 2, tip:NumLines() do
    local fs = _G['WCBagSwapTipTextLeft' .. i]
    local n = fs and (fs:GetText() or ''):match('^(%d+) Slot')
    if n then tip:Hide() return tonumber(n) end
  end
  tip:Hide()
end

local function isBag(id)
  local _, _, _, equipLoc, _, classID = C_Item.GetItemInfoInstant(id)
  return classID == 1 and equipLoc == 'INVTYPE_BAG'
end

-- spare bags in the bags: { bag, slot, id, name, size }
local function spares()
  local list = {}
  for b = 0, 4 do
    for s = 1, C_Container.GetContainerNumSlots(b) or 0 do
      local info = C_Container.GetContainerItemInfo(b, s)
      if info and info.itemID and isBag(info.itemID) then
        list[#list + 1] = { bag = b, slot = s, id = info.itemID,
          name = info.itemName or C_Item.GetItemInfo(info.itemID) or '?', size = sizeOf(b, s) or 0 }
      end
    end
  end
  return list
end

local function ordinary(b) local _, fam = C_Container.GetContainerNumFreeSlots(b) return (fam or 0) == 0 end
local function equipped(b) return GetInventoryItemID('player', C_Container.ContainerIDToInventoryID(b)) ~= nil end

local function plan(what, into)
  if InCombatLockdown() then return nil, 'not in a fight' end
  if CursorHasItem() then return nil, 'you are holding an item; put it down first' end
  local list = spares()
  if #list == 0 then return nil, 'no spare bag in your bags' end
  local new
  for _, e in ipairs(list) do
    local hit = what == nil or e.id == tonumber(what)
      or (type(what) == 'string' and e.name:lower():find(what:lower(), 1, true))
    if hit and (not new or e.size > new.size) then new = e end
  end
  if not new then return nil, ('no spare bag called %s; spares: %s'):format(tostring(what),
    table.concat((function() local t = {} for _, e in ipairs(list) do t[#t + 1] = e.name end return t end)(), ', ')) end
  -- the slot to fill
  local target
  if into then
    target = tonumber(into)
    if not target or target < 1 or target > 4 then return nil, 'bag slot must be 1 to 4' end
  else
    for b = 1, 4 do if not equipped(b) then target = b break end end
    if not target then
      for b = 1, 4 do
        local n = C_Container.GetContainerNumSlots(b) or 0
        if ordinary(b) and n < new.size and (not target or n < (C_Container.GetContainerNumSlots(target) or 0)) then target = b end
      end
    end
    if not target then return nil, ('%s (%d slots) is no bigger than any bag you wear'):format(new.name, new.size) end
  end
  local p = { new = new, target = target, moves = {} }
  if not equipped(target) then return p end
  -- the old bag's items, and where each goes (ordinary bags only, not the target)
  local free = {}
  for b = 0, 4 do
    if b ~= target and ordinary(b) then
      for s = 1, C_Container.GetContainerNumSlots(b) or 0 do
        if not C_Container.GetContainerItemInfo(b, s) then free[#free + 1] = { b, s } end
      end
    end
  end
  local items = 0
  for s = 1, C_Container.GetContainerNumSlots(target) or 0 do
    if C_Container.GetContainerItemInfo(target, s) then
      items = items + 1
      local to = free[items]
      if to then p.moves[#p.moves + 1] = { target, s, to[1], to[2] } end
    end
  end
  p.old = C_Container.GetBagName(target) or ('bag ' .. target)
  p.oldSize = C_Container.GetContainerNumSlots(target) or 0
  if items > #free then
    return nil, ('impossible: %s holds %d items and your other bags have %d free; make room for %d more'):format(
      p.old, items, #free, items - #free)
  end
  return p
end

-- the runner: one move per settle
local run
local driver = CreateFrame('Frame')
local function stop(why)
  driver:SetScript('OnUpdate', nil)
  if CursorHasItem() then ClearCursor() end
  if why then say(why) end
  run = nil
end
local function locked(b, s)
  local info = C_Container.GetContainerItemInfo(b, s)
  return info and info.isLocked
end
local function busy()
  if CursorHasItem() then return true end
  for b = 0, 4 do
    for s = 1, C_Container.GetContainerNumSlots(b) or 0 do if locked(b, s) then return true end end
  end
end
local function where(id, size)
  for b = 0, 4 do
    for s = 1, C_Container.GetContainerNumSlots(b) or 0 do
      local info = C_Container.GetContainerItemInfo(b, s)
      if info and info.itemID == id then return b, s end
    end
  end
end

local function step()
  if InCombatLockdown() then return stop('stopped: a fight began. Nothing is lost; ask again after.') end
  if GetTime() > run.deadline then return stop('stopped: the bags did not settle. Ask again to finish.') end
  if busy() and run.phase ~= 'drop' then return end
  local p = run.p
  if run.phase == 'move' then
    local m = p.moves[run.i]
    if not m then run.phase = 'equip' return end
    C_Container.PickupContainerItem(m[1], m[2])
    C_Container.PickupContainerItem(m[3], m[4])
    run.i = run.i + 1
  elseif run.phase == 'equip' then
    local b, s = where(p.new.id)
    if not b then return stop('stopped: the new bag moved out of reach.') end
    run.from = { b, s }
    C_Container.PickupContainerItem(b, s)
    PutItemInBag(C_Container.ContainerIDToInventoryID(p.target))
    run.phase = 'drop'
  elseif run.phase == 'drop' then
    -- the old bag, if one was swapped out, is on the cursor: where the new one was
    if CursorHasItem() then
      C_Container.PickupContainerItem(run.from[1], run.from[2])
      run.phase = 'done'
      return
    end
    run.phase = 'done'
  elseif run.phase == 'done' then
    local n = C_Container.GetContainerNumSlots(p.target) or 0
    stop(('done: bag %d is now %s, %d slots.'):format(p.target, C_Container.GetBagName(p.target) or p.new.name, n))
  end
end

function WCSwapBag(what, into, dry)
  if run then return say('a swap is already running') end
  local p, why = plan(what, into)
  if not p then return say(why) end
  local text = p.old
    and ('%s (%d) replaces %s (%d) in bag slot %d; %d items move to your other bags first.'):format(
      p.new.name, p.new.size, p.old, p.oldSize, p.target, #p.moves)
    or ('%s (%d) goes into the empty bag slot %d.'):format(p.new.name, p.new.size, p.target)
  if dry then return say('would do: ' .. text) end
  say(text)
  run = { p = p, i = 1, phase = 'move', deadline = GetTime() + 30 + #p.moves }
  local wait = 0
  driver:SetScript('OnUpdate', function(_, dt)
    wait = wait + dt
    if wait < 0.15 then return end
    wait = 0
    local ok, err = pcall(step)
    if not ok then stop('stopped: ' .. tostring(err)) end
  end)
end

function M:Enable() end
function M:Disable() stop() end
